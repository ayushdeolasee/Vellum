import Foundation

/// App-level owner of coordinated storage. Local and custom-folder modes stay
/// on the existing direct filesystem path; only iCloud installs a
/// `SyncedContainer`, starts the conflict consumer, and accepts coordinated
/// operations.
///
/// C3 intentionally does not migrate the broad synchronous `WebLibrary` call
/// surface through this gate. Until C4 wires those adapters and production iCloud
/// entitlements, direct iCloud path reads/writes are not protected by the
/// coordinator; only callers that enter `runCoordinatedOperation`/`withContainer`
/// get lifecycle admission and drain behavior.
actor StorageCoordinator {
    enum Availability: Sendable, Equatable {
        case direct
        case coordinated
        case degradedToLocal(DegradedReason)
        case unavailable(DegradedReason)
    }

    enum DegradedReason: String, Sendable, Equatable {
        case noStorageChoice
        case iCloudUnavailable
        case customFolderUnavailable
        case coordinatorStopped
    }

    enum Lifecycle: String, Sendable, Equatable {
        case idle
        case starting
        case active
        case backgrounding
        case suspended
        case stopped
    }

    enum OperationError: Error, Sendable, Equatable {
        case unavailable
        case suspended
    }

    struct Status: Sendable, Equatable {
        var chosenMode: WebStorageMode?
        var effectiveMode: WebStorageMode
        var lifecycle: Lifecycle
        var availability: Availability
        var acceptsCoordinatedOperations: Bool
        var pendingConflicts: Int
        var inFlightConflicts: Int
        var inFlightOperations: Int
        var lastError: String?
    }

    struct BackgroundDrainOutcome: Sendable, Equatable {
        var drained: Bool
        var timedOut: Bool
        var pendingConflicts: Int
        var inFlightConflicts: Int
        var inFlightOperations: Int
    }

    /// A losing synced-file version that Vellum preserved instead of merging.
    /// The URL is descriptive only; callers recover or delete it through this
    /// coordinator so an iCloud URL never escapes into direct FileManager I/O.
    struct ArchivedConflict: Identifiable, Sendable, Equatable, Codable {
        var archiveURL: URL
        var originalURL: URL
        var detectedAt: Date

        var id: URL { archiveURL.standardizedFileURL }
        var displayName: String { originalURL.lastPathComponent }
        var archiveName: String { archiveURL.lastPathComponent }
    }

    enum ArchivedConflictError: Error, Sendable, Equatable {
        case noLongerAvailable
    }

    struct ConflictArchiveRegistry: Sendable {
        var load: @Sendable () -> [ArchivedConflict]
        var save: @Sendable ([ArchivedConflict]) -> Void

        static let live = ConflictArchiveRegistry(
            load: {
                guard let data = UserDefaults.standard.data(
                    forKey: "vellum.storage.conflictArchives.v1")
                else { return [] }
                return (try? JSONDecoder().decode([ArchivedConflict].self, from: data)) ?? []
            },
            save: { conflicts in
                if conflicts.isEmpty {
                    UserDefaults.standard.removeObject(
                        forKey: "vellum.storage.conflictArchives.v1")
                } else if let data = try? JSONEncoder().encode(conflicts) {
                    UserDefaults.standard.set(
                        data,
                        forKey: "vellum.storage.conflictArchives.v1")
                }
            })
    }

    enum StorageContext: Sendable {
        case direct(layout: WebStorageLayout)
        case coordinated(container: any SyncedContainer, layout: WebStorageLayout)

        var layout: WebStorageLayout {
            switch self {
            case .direct(let layout), .coordinated(_, let layout):
                return layout
            }
        }
    }

    private enum QuiescenceWaitResult: Sendable {
        case quiescent
        case timedOut
        case invalidated
    }

    private struct ConflictKey: Hashable, Sendable {
        var url: URL
        var versions: [String]

        init(_ event: ConflictEvent) {
            url = event.url.standardizedFileURL
            versions = event.versions
                .map { "\($0.isCurrent ? "current" : "other"):\($0.id)" }
                .sorted()
        }
    }

    private let storeDir: URL
    private let modeProvider: @Sendable () -> WebStorageMode?
    private let effectiveModeProvider: @Sendable () -> WebStorageMode
    private struct ResolvedConfiguration: Sendable {
        var chosenMode: WebStorageMode?
        var effectiveMode: WebStorageMode
        var access: StorageAccess
        var layout: WebStorageLayout
        var availability: Availability
    }

    private let rootResolver: @Sendable () async -> URL?
    private let containerFactory: @Sendable () async -> (any SyncedContainer)?
    private let conflictArchiveRegistry: ConflictArchiveRegistry

    private var chosenMode: WebStorageMode?
    private var effectiveMode: WebStorageMode = .local
    private var lifecycle: Lifecycle = .idle
    private var availability: Availability = .direct
    private var access: StorageAccess = .unavailable
    private var layout: WebStorageLayout
    private var acceptsCoordinatedOperations = false
    private var acceptsConflictResolution = false
    private var containerIsSuspended = false

    private var consumerTask: Task<Void, Never>?
    private var consumerGeneration = 0
    private var conflictDrainTask: Task<Void, Never>?
    private var conflictDrainGeneration = 0
    private var storageGeneration = 0
    private var lifecycleTail: Task<Void, Never>?
    private var lifecycleSequence = 0
    private var transitionGeneration = 0

    private var pendingConflicts: [ConflictKey: ConflictEvent] = [:]
    private var pendingOrder: [ConflictKey] = []
    private var inFlightConflict: ConflictKey?
    private var resolvedConflictKeys: Set<ConflictKey> = []
    private struct ArchivedConflictRecord: Sendable, Equatable {
        var descriptor: ArchivedConflict
        var generation: Int
    }
    private var archivedConflictRecords: [URL: ArchivedConflictRecord] = [:]

    private var inFlightOperations = 0
    private struct QuiescenceWaiter {
        var generation: Int?
        var continuation: CheckedContinuation<QuiescenceWaitResult, Never>
        var timeoutTask: Task<Void, Never>?
    }

    private var nextQuiescenceWaiterID = 0
    private var quiescenceWaiters: [Int: QuiescenceWaiter] = [:]
    private var lastError: String?

    init(
        storeDir: URL = WebLibrary.storeDir,
        modeProvider: @escaping @Sendable () -> WebStorageMode? = { WebStorageSettings.chosenMode },
        effectiveModeProvider: @escaping @Sendable () -> WebStorageMode = { WebStorageSettings.effectiveMode },
        rootResolver: @escaping @Sendable () async -> URL? = {
            await Task.detached(priority: .utility) {
                WebStorageSettings.resolveICloudRoot()
                return WebStorageSettings.icloudVellumRoot
            }.value
        },
        containerFactory: @escaping @Sendable () async -> (any SyncedContainer)? = {
            await Task.detached(priority: .utility) { ICloudSyncedContainer() }.value
        },
        conflictArchiveRegistry: ConflictArchiveRegistry = .live
    ) {
        self.storeDir = storeDir
        self.modeProvider = modeProvider
        self.effectiveModeProvider = effectiveModeProvider
        self.rootResolver = rootResolver
        self.containerFactory = containerFactory
        self.conflictArchiveRegistry = conflictArchiveRegistry
        self.layout = .local(storeDir: storeDir)
    }

    func currentStatus() -> Status {
        status()
    }

    /// Preserved versions validated through the current container's metadata
    /// query. Descriptor URLs are persisted locally so a later coordinator can
    /// rediscover their synced items without recursively walking iCloud Drive.
    func archivedConflicts() -> [ArchivedConflict] {
        archivedConflictRecords.values
            .filter { $0.generation == storageGeneration }
            .map(\.descriptor).sorted {
            if $0.detectedAt != $1.detectedAt { return $0.detectedAt > $1.detectedAt }
            return $0.archiveURL.absoluteString < $1.archiveURL.absoluteString
        }
    }

    /// Make a local recovery copy suitable for the iOS Files export picker.
    /// Reading the archived bytes remains coordinated; only the new temporary
    /// destination uses the direct store.
    func exportArchivedConflict(_ conflict: ArchivedConflict) async throws -> URL {
        guard let record = archivedConflictRecords[conflict.id],
              record.generation == storageGeneration,
              let container = access.container
        else {
            throw ArchivedConflictError.noLongerAvailable
        }
        try beginOperation(requiresContainer: true)
        do {
            let data = try await container.data(
                at: record.descriptor.archiveURL,
                materializing: .downloadIfNeeded(timeout: 10))
            let destination = FileManager.default.temporaryDirectory
                .appendingPathComponent("Vellum Conflict \(UUID().uuidString)", isDirectory: true)
                .appendingPathComponent(record.descriptor.archiveName)
            try await DirectLibraryFileStore().replace(destination, with: data)
            finishOperation()
            return destination
        } catch {
            finishOperation()
            throw error
        }
    }

    /// Permanently remove a preserved version through its originating synced
    /// container. The row disappears only after the coordinated remove succeeds.
    func deleteArchivedConflict(_ conflict: ArchivedConflict) async throws {
        guard let record = archivedConflictRecords[conflict.id],
              record.generation == storageGeneration,
              let container = access.container
        else {
            throw ArchivedConflictError.noLongerAvailable
        }
        try beginOperation(requiresContainer: true)
        do {
            try await container.remove(record.descriptor.archiveURL)
            archivedConflictRecords.removeValue(forKey: conflict.id)
            forgetArchivedConflict(conflict.id)
            NotificationCenter.default.post(
                name: .vellumStorageConflictArchivesChanged,
                object: nil)
            finishOperation()
        } catch {
            finishOperation()
            throw error
        }
    }

    /// Join the operation/conflict pass that is active right now. Pending
    /// deferred conflicts are intentionally not counted: they remain parked
    /// until the next foreground retry instead of making this barrier hang.
    func awaitQuiescence() async {
        await waitForQuiescenceUnbounded()
    }

    func start() async {
        await enqueueLifecycle { await self.startImpl() }
    }

    func foreground() async {
        // Invalidate a background drain immediately so its quiescence waiter
        // wakes, but still serialize the actual foreground transition behind
        // any suspend/reconfigure already in flight. Reopening admission while
        // `container.suspend()` is suspended would lend callers a retiring
        // container for a brief but data-loss-prone window.
        invalidateBackgroundLifecycle()
        await enqueueLifecycle { await self.foregroundImpl() }
    }

    func reconfigure() async {
        await enqueueLifecycle { await self.reconfigureImpl() }
    }

    /// Run a store-wide relocation with normal operations and conflict delivery
    /// stopped. When `reconfigureAfter` is true, the mode preference is assumed
    /// to have changed already; the new container/layout is installed before
    /// admission reopens, leaving no old-root/new-root race window.
    func performExclusiveStorageOperation<T: Sendable>(
        reconfigureAfter: Bool = false,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T {
        await enqueueLifecycle {
            await self.performExclusiveStorageOperationImpl(
                reconfigureAfter: reconfigureAfter,
                operation)
        }
    }

    /// Lend both sides of a relocation while normal storage admission and
    /// conflict delivery are closed. Either side may be the coordinated iCloud
    /// layout; local/custom sides receive the direct adapter. A nil context
    /// means the requested iCloud container is unavailable, so the caller must
    /// leave its pending marker intact for a later retry.
    func performExclusiveStorageRelocation<T: Sendable>(
        from source: WebStorageLayout,
        to destination: WebStorageLayout,
        reconfigureAfter: Bool = false,
        _ operation: @escaping @Sendable (
            StorageContext?, StorageContext?
        ) async -> T
    ) async -> T {
        await performExclusiveStorageOperation(reconfigureAfter: reconfigureAfter) {
            let contexts = await self.relocationContexts(
                source: source, destination: destination)
            let result = await operation(contexts.source, contexts.destination)
            for container in contexts.transientContainers {
                await container.suspend()
            }
            return result
        }
    }

    /// Import the old macOS iCloud Drive folder into the active layout while
    /// normal storage traffic is stopped. The source is deliberately direct:
    /// older Vellum builds addressed that Finder-managed folder without a
    /// ubiquity-container identity. The destination still receives the normal
    /// coordinated adapter when it is the shared iCloud container.
    func performExclusiveDirectStorageImport<T: Sendable>(
        from source: WebStorageLayout,
        to destination: WebStorageLayout,
        _ operation: @escaping @Sendable (
            StorageContext, StorageContext?
        ) async -> T
    ) async -> T {
        await performExclusiveStorageOperation {
            let destinationResult = await self.storageContext(for: destination)
            let result = await operation(
                .direct(layout: source), destinationResult.context)
            for container in destinationResult.transientContainers {
                await container.suspend()
            }
            return result
        }
    }

    @discardableResult
    func background(
        timeout: TimeInterval? = nil,
        finalSuspensionAllowed: @escaping @Sendable () async -> Bool = { true }
    ) async -> BackgroundDrainOutcome {
        await enqueueLifecycle {
            await self.backgroundImpl(
                timeout: timeout,
                finalSuspensionAllowed: finalSuspensionAllowed)
        }
    }

    func stop(timeout: TimeInterval? = nil) async {
        await enqueueLifecycle { await self.stopImpl(timeout: timeout) }
    }

    /// Future coordinated adapters can wrap their work in this gate. The gate
    /// gives background/termination a join point without exposing root URLs or
    /// asking callers to manage presenter/query lifecycle themselves.
    func runCoordinatedOperation<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try beginOperation(requiresContainer: false)
        do {
            let value = try await operation()
            finishOperation()
            return value
        } catch {
            finishOperation()
            throw error
        }
    }

    /// C4 storage adapters enter here for every async web-library operation.
    /// The returned layout is the one installed with the current lifecycle
    /// generation, so a reconfigure cannot lend a container from one root while
    /// the caller derives paths from another.
    func withStorageContext<T: Sendable>(
        _ operation: @Sendable (StorageContext) async throws -> T
    ) async throws -> T {
        try beginOperation(requiresContainer: false)
        let context: StorageContext
        if let container = access.container {
            context = .coordinated(container: container, layout: layout)
        } else {
            context = .direct(layout: layout)
        }
        do {
            let value = try await operation(context)
            finishOperation()
            return value
        } catch {
            finishOperation()
            throw error
        }
    }

    /// Narrow escape hatch for the future async WebLibrary adapter migration:
    /// the coordinator lends the active container only for the duration of the
    /// operation, and the operation is still drainable on background.
    func withContainer<T: Sendable>(
        _ operation: @Sendable (any SyncedContainer) async throws -> T
    ) async throws -> T {
        guard let container = access.container else { throw OperationError.unavailable }
        try beginOperation(requiresContainer: true)
        do {
            let value = try await operation(container)
            finishOperation()
            return value
        } catch {
            finishOperation()
            throw error
        }
    }

    // MARK: - Lifecycle

    @discardableResult
    private func enqueueLifecycle<T: Sendable>(_ operation: @escaping @Sendable () async -> T) async -> T {
        let previous = lifecycleTail
        lifecycleSequence += 1
        let sequence = lifecycleSequence
        let resultTask = Task {
            await previous?.value
            return await operation()
        }
        let tail = Task {
            _ = await resultTask.value
        }
        lifecycleTail = tail
        let result = await resultTask.value
        if lifecycleSequence == sequence {
            lifecycleTail = nil
        }
        return result
    }

    private func startImpl() async {
        guard lifecycle != .active, lifecycle != .starting else { return }
        if lifecycle == .suspended {
            await foregroundImpl()
            return
        }
        lifecycle = .starting
        let configuration = await resolveConfiguration(chosenMode: modeProvider())
        install(configuration)
        await rediscoverArchivedConflicts()
    }

    private func resolveConfiguration(chosenMode: WebStorageMode?) async -> ResolvedConfiguration {
        switch chosenMode {
        case .icloud:
            let root = await rootResolver()
            let container = root == nil ? nil : await containerFactory()
            let access = StorageAccess.resolve(
                mode: .icloud, storeDir: storeDir, icloudRoot: root) { container }
            switch access {
            case .coordinated:
                guard let root else {
                    return ResolvedConfiguration(
                        chosenMode: chosenMode,
                        effectiveMode: .local,
                        access: access,
                        layout: .local(storeDir: storeDir),
                        availability: .degradedToLocal(.iCloudUnavailable))
                }
                let layout = WebStorageLayout.pretty(
                    root: root, recordsInRoot: true, localStoreDir: storeDir)
                return ResolvedConfiguration(
                    chosenMode: chosenMode,
                    effectiveMode: .icloud,
                    access: access,
                    layout: layout,
                    availability: .coordinated)
            case .direct:
                let layout = WebStorageLayout.resolve(mode: .icloud, storeDir: storeDir)
                return ResolvedConfiguration(
                    chosenMode: chosenMode,
                    effectiveMode: .icloud,
                    access: access,
                    layout: layout,
                    availability: .direct)
            case .unavailable:
                return ResolvedConfiguration(
                    chosenMode: chosenMode,
                    effectiveMode: .local,
                    access: access,
                    layout: .local(storeDir: storeDir),
                    availability: .degradedToLocal(.iCloudUnavailable))
            }
        case .custom:
            let access = StorageAccess.resolve(
                mode: .custom, storeDir: storeDir, icloudRoot: nil) { nil }
            let effectiveMode = effectiveModeProvider()
            let layout = WebStorageLayout.resolve(mode: effectiveMode, storeDir: storeDir)
            return ResolvedConfiguration(
                chosenMode: chosenMode,
                effectiveMode: effectiveMode,
                access: access,
                layout: layout,
                availability: effectiveMode == .custom
                    ? .direct : .degradedToLocal(.customFolderUnavailable))
        case .local:
            return ResolvedConfiguration(
                chosenMode: chosenMode,
                effectiveMode: .local,
                access: StorageAccess.resolve(
                    mode: .local, storeDir: storeDir, icloudRoot: nil) { nil },
                layout: .local(storeDir: storeDir),
                availability: .direct)
        case nil:
            return ResolvedConfiguration(
                chosenMode: chosenMode,
                effectiveMode: .local,
                access: StorageAccess.resolve(
                    mode: .local, storeDir: storeDir, icloudRoot: nil) { nil },
                layout: .local(storeDir: storeDir),
                availability: .degradedToLocal(.noStorageChoice))
        }
    }

    private func foregroundImpl() async {
        if lifecycle == .idle || lifecycle == .stopped {
            await startImpl()
            return
        }
        guard let container = access.container else {
            acceptsCoordinatedOperations = false
            lifecycle = .active
            return
        }
        lifecycle = .starting
        if containerIsSuspended {
            await container.resume()
            containerIsSuspended = false
        }
        acceptsCoordinatedOperations = true
        acceptsConflictResolution = true
        lifecycle = .active
        await rediscoverArchivedConflicts()
        launchConflictDrainIfNeeded()
    }

    private func backgroundImpl(
        timeout: TimeInterval?,
        finalSuspensionAllowed: @Sendable () async -> Bool
    ) async -> BackgroundDrainOutcome {
        let generation = beginBackgroundLifecycle()
        lifecycle = .backgrounding
        acceptsCoordinatedOperations = false
        acceptsConflictResolution = false
        let drain = await waitForQuiescence(timeout: timeout, generation: generation)
        guard drain == .quiescent else {
            lastError = drain == .timedOut
                ? "Storage coordination background drain timed out"
                : "Storage coordination background drain was invalidated before suspend"
            let snapshot = status()
            return BackgroundDrainOutcome(
                drained: false,
                timedOut: drain == .timedOut,
                pendingConflicts: snapshot.pendingConflicts,
                inFlightConflicts: snapshot.inFlightConflicts,
                inFlightOperations: snapshot.inFlightOperations)
        }
        guard isCurrentBackgroundLifecycle(generation),
              await finalSuspensionAllowed(),
              isCurrentBackgroundLifecycle(generation)
        else {
            lastError = "Storage coordination background drain was invalidated before suspend"
            let snapshot = status()
            return BackgroundDrainOutcome(
                drained: false,
                timedOut: false,
                pendingConflicts: snapshot.pendingConflicts,
                inFlightConflicts: snapshot.inFlightConflicts,
                inFlightOperations: snapshot.inFlightOperations)
        }
        if let container = access.container {
            guard isCurrentBackgroundLifecycle(generation) else {
                lastError = "Storage coordination background drain was invalidated before suspend"
                let snapshot = status()
                return BackgroundDrainOutcome(
                    drained: false,
                    timedOut: false,
                    pendingConflicts: snapshot.pendingConflicts,
                    inFlightConflicts: snapshot.inFlightConflicts,
                    inFlightOperations: snapshot.inFlightOperations)
            }
            await container.suspend()
            guard isCurrentBackgroundLifecycle(generation) else {
                await container.resume()
                containerIsSuspended = false
                acceptsCoordinatedOperations = true
                acceptsConflictResolution = true
                lifecycle = .active
                lastError = "Storage coordination background drain was invalidated before suspend"
                launchConflictDrainIfNeeded()
                let snapshot = status()
                return BackgroundDrainOutcome(
                    drained: false,
                    timedOut: false,
                    pendingConflicts: snapshot.pendingConflicts,
                    inFlightConflicts: snapshot.inFlightConflicts,
                    inFlightOperations: snapshot.inFlightOperations)
            }
            containerIsSuspended = true
        }
        lifecycle = .suspended
        let snapshot = status()
        return BackgroundDrainOutcome(
            drained: true,
            timedOut: false,
            pendingConflicts: snapshot.pendingConflicts,
            inFlightConflicts: snapshot.inFlightConflicts,
            inFlightOperations: snapshot.inFlightOperations)
    }

    private func stopImpl(timeout: TimeInterval?) async {
        acceptsCoordinatedOperations = false
        acceptsConflictResolution = false
        lifecycle = .backgrounding
        guard await waitForQuiescence(timeout: timeout) == .quiescent else {
            lastError = "Storage coordination stop timed out"
            return
        }
        await cancelAndJoinRuntimeTasks()
        if let container = access.container {
            await container.suspend()
            containerIsSuspended = true
        }
        access = .unavailable
        lifecycle = .stopped
        availability = .unavailable(.coordinatorStopped)
        notifyQuiescenceIfNeeded()
    }

    private func reconfigureImpl() async {
        if lifecycle == .idle || lifecycle == .stopped {
            await startImpl()
            return
        }

        let nextChosenMode = modeProvider()
        guard !(await isAlreadyConfiguredFor(chosenMode: nextChosenMode)) else { return }

        let next = await resolveConfiguration(chosenMode: nextChosenMode)
        guard !isSameEffectiveAccess(as: next) else { return }

        acceptsCoordinatedOperations = false
        acceptsConflictResolution = false
        lifecycle = .starting
        await waitForQuiescenceUnbounded()
        await cancelAndJoinRuntimeTasks()
        if let container = access.container, !containerIsSuspended {
            await container.suspend()
        }
        install(next)
        await rediscoverArchivedConflicts()
    }

    private func relocationContexts(
        source: WebStorageLayout,
        destination: WebStorageLayout
    ) async -> (
        source: StorageContext?,
        destination: StorageContext?,
        transientContainers: [any SyncedContainer]
    ) {
        let sourceResult = await storageContext(for: source)
        if source == destination {
            return (sourceResult.context, sourceResult.context, sourceResult.transientContainers)
        }
        let destinationResult = await storageContext(for: destination)
        return (
            sourceResult.context,
            destinationResult.context,
            sourceResult.transientContainers + destinationResult.transientContainers)
    }

    private func storageContext(
        for requestedLayout: WebStorageLayout
    ) async -> (context: StorageContext?, transientContainers: [any SyncedContainer]) {
        guard requestedLayout.requiresCoordination else {
            return (.direct(layout: requestedLayout), [])
        }
        if requestedLayout == layout, let container = access.container {
            return (.coordinated(container: container, layout: requestedLayout), [])
        }
        guard let container = await containerFactory() else { return (nil, []) }
        return (
            .coordinated(container: container, layout: requestedLayout),
            [container])
    }

    private func performExclusiveStorageOperationImpl<T: Sendable>(
        reconfigureAfter: Bool,
        _ operation: @Sendable () async -> T
    ) async -> T {
        if lifecycle == .idle || lifecycle == .stopped {
            await startImpl()
        } else if lifecycle == .suspended {
            await foregroundImpl()
        }

        acceptsCoordinatedOperations = false
        acceptsConflictResolution = false
        lifecycle = .starting
        await waitForQuiescenceUnbounded()
        await cancelAndJoinRuntimeTasks()

        let result = await operation()

        if reconfigureAfter {
            let next = await resolveConfiguration(chosenMode: modeProvider())
            if let container = access.container, !containerIsSuspended {
                await container.suspend()
            }
            install(next)
            await rediscoverArchivedConflicts()
        } else {
            lifecycle = .active
            switch access {
            case .coordinated(let container, _):
                acceptsCoordinatedOperations = true
                acceptsConflictResolution = true
                startConflictConsumer(container)
                launchConflictDrainIfNeeded()
            case .direct, .unavailable:
                acceptsCoordinatedOperations = false
                acceptsConflictResolution = false
            }
        }
        return result
    }

    private func install(_ configuration: ResolvedConfiguration) {
        chosenMode = configuration.chosenMode
        effectiveMode = configuration.effectiveMode
        access = configuration.access
        layout = configuration.layout
        availability = configuration.availability
        lastError = nil
        switch configuration.access {
        case .coordinated(let container, _):
            acceptsCoordinatedOperations = true
            acceptsConflictResolution = true
            containerIsSuspended = false
            lifecycle = .active
            startConflictConsumer(container)
            launchConflictDrainIfNeeded()
        case .direct:
            acceptsCoordinatedOperations = false
            acceptsConflictResolution = false
            containerIsSuspended = false
            lifecycle = .active
        case .unavailable:
            acceptsCoordinatedOperations = false
            acceptsConflictResolution = false
            containerIsSuspended = false
            lifecycle = .active
        }
    }

    private func isSameEffectiveAccess(as configuration: ResolvedConfiguration) -> Bool {
        chosenMode == configuration.chosenMode
            && effectiveMode == configuration.effectiveMode
            && availability == configuration.availability
            && access.root == configuration.access.root
            && access.isCoordinated == configuration.access.isCoordinated
            && layout == configuration.layout
    }

    private func cancelAndJoinRuntimeTasks() async {
        storageGeneration += 1
        let hadArchivedConflicts = archivedConflictRecords.isEmpty == false
        archivedConflictRecords.removeAll()
        if hadArchivedConflicts {
            NotificationCenter.default.post(
                name: .vellumStorageConflictArchivesChanged,
                object: nil)
        }
        let consumer = consumerTask
        let drain = conflictDrainTask
        consumerTask?.cancel()
        conflictDrainTask?.cancel()
        consumerTask = nil
        conflictDrainTask = nil
        inFlightConflict = nil
        await consumer?.value
        await drain?.value
        notifyQuiescenceIfNeeded()
    }

    // MARK: - Operations

    private func beginOperation(requiresContainer: Bool) throws {
        if requiresContainer || access.isCoordinated {
            guard acceptsCoordinatedOperations else {
                throw lifecycle == .suspended || lifecycle == .backgrounding
                    ? OperationError.suspended : OperationError.unavailable
            }
        } else {
            guard lifecycle == .active else {
                throw lifecycle == .suspended || lifecycle == .backgrounding
                    ? OperationError.suspended : OperationError.unavailable
            }
        }
        if requiresContainer, access.container == nil {
            throw OperationError.unavailable
        }
        inFlightOperations += 1
    }

    private func finishOperation() {
        inFlightOperations = max(0, inFlightOperations - 1)
        notifyQuiescenceIfNeeded()
    }

    // MARK: - Conflicts

    private func startConflictConsumer(_ container: any SyncedContainer) {
        guard consumerTask == nil else { return }
        let generation = storageGeneration
        consumerGeneration = generation
        consumerTask = Task { [weak self] in
            for await event in container.conflicts {
                guard !Task.isCancelled else { break }
                await self?.enqueueConflict(event, generation: generation)
            }
            await self?.consumerDidFinish(generation: generation)
        }
    }

    private func consumerDidFinish(generation: Int) {
        guard generation == storageGeneration, generation == consumerGeneration else { return }
        consumerTask = nil
        notifyQuiescenceIfNeeded()
    }

    private func enqueueConflict(_ event: ConflictEvent, generation: Int) {
        guard generation == storageGeneration else { return }
        let key = ConflictKey(event)
        guard !resolvedConflictKeys.contains(key),
              pendingConflicts[key] == nil,
              inFlightConflict != key
        else { return }
        pendingConflicts[key] = event
        pendingOrder.append(key)
        if acceptsConflictResolution {
            launchConflictDrainIfNeeded()
        } else {
            notifyQuiescenceIfNeeded()
        }
    }

    private func isAlreadyConfiguredFor(chosenMode nextChosenMode: WebStorageMode?) async -> Bool {
        guard chosenMode == nextChosenMode else { return false }
        switch nextChosenMode {
        case .icloud:
            let root = await rootResolver()
            let nextEffectiveMode: WebStorageMode = root == nil ? .local : .icloud
            let nextRecordsRoot = root.map {
                WebStorageLayout.pretty(
                    root: $0, recordsInRoot: true, localStoreDir: storeDir).recordsDir
            }
            guard effectiveMode == nextEffectiveMode,
                  access.root == nextRecordsRoot
            else { return false }
            return root == nil ? access.container == nil : access.container != nil
        case .custom:
            let nextAccess = StorageAccess.resolve(
                mode: .custom, storeDir: storeDir, icloudRoot: nil) { nil }
            let nextEffectiveMode = effectiveModeProvider()
            let nextLayout = WebStorageLayout.resolve(
                mode: nextEffectiveMode, storeDir: storeDir)
            return effectiveMode == nextEffectiveMode
                && access.root == nextAccess.root
                && access.isCoordinated == nextAccess.isCoordinated
                && layout == nextLayout
        case .local:
            let nextAccess = StorageAccess.resolve(
                mode: .local, storeDir: storeDir, icloudRoot: nil) { nil }
            return effectiveMode == .local
                && access.root == nextAccess.root
                && access.isCoordinated == nextAccess.isCoordinated
        case nil:
            let nextAccess = StorageAccess.resolve(
                mode: .local, storeDir: storeDir, icloudRoot: nil) { nil }
            return effectiveMode == .local
                && access.root == nextAccess.root
                && access.isCoordinated == nextAccess.isCoordinated
        }
    }
    private func launchConflictDrainIfNeeded() {
        guard acceptsConflictResolution, conflictDrainTask == nil, access.container != nil else {
            notifyQuiescenceIfNeeded()
            return
        }
        let generation = storageGeneration
        conflictDrainGeneration = generation
        conflictDrainTask = Task { [weak self] in
            await self?.conflictDrainLoop(generation: generation)
        }
    }

    private func conflictDrainLoop(generation: Int) async {
        while !Task.isCancelled {
            guard let work = takeNextConflict(generation: generation) else { break }
            let resolution: Result<ConflictResolution, any Error>
            do {
                let resolved = try await work.container.resolveConflict(work.event)
                resolution = .success(resolved)
            } catch {
                resolution = .failure(error)
            }
            if !completeConflict(
                key: work.key,
                event: work.event,
                generation: generation,
                resolution: resolution
            ) {
                break
            }
        }
        drainDidFinish(generation: generation)
    }

    private func drainDidFinish(generation: Int) {
        guard generation == storageGeneration, generation == conflictDrainGeneration else { return }
        conflictDrainTask = nil
        notifyQuiescenceIfNeeded()
    }

    private func takeNextConflict(generation: Int) -> (
        key: ConflictKey, event: ConflictEvent, container: any SyncedContainer
    )? {
        guard generation == storageGeneration,
              acceptsConflictResolution,
              let container = access.container
        else { return nil }
        while !pendingOrder.isEmpty {
            let key = pendingOrder.removeFirst()
            guard let event = pendingConflicts.removeValue(forKey: key) else { continue }
            inFlightConflict = key
            return (key, event, container)
        }
        return nil
    }

    /// Returns true when the drain may continue. Retryable failures and
    /// explicit deferrals stay pending but stop this pass, so a bad resolver or
    /// not-ready file cannot busy-spin on the actor.
    private func completeConflict(
        key: ConflictKey,
        event: ConflictEvent,
        generation: Int,
        resolution: Result<ConflictResolution, any Error>
    ) -> Bool {
        guard generation == storageGeneration else { return false }
        if case .success(.keptCurrent(let archivedLosers)) = resolution {
            for archiveURL in archivedLosers {
                let descriptor = ArchivedConflict(
                    archiveURL: archiveURL,
                    originalURL: event.url,
                    detectedAt: event.detectedAt)
                archivedConflictRecords[descriptor.id] = ArchivedConflictRecord(
                    descriptor: descriptor,
                    generation: generation)
            }
            if archivedLosers.isEmpty == false {
                rememberArchivedConflicts(archivedLosers.map { archiveURL in
                    ArchivedConflict(
                        archiveURL: archiveURL,
                        originalURL: event.url,
                        detectedAt: event.detectedAt)
                })
                NotificationCenter.default.post(
                    name: .vellumStorageConflictArchivesChanged,
                    object: nil)
            }
        }
        inFlightConflict = nil
        switch resolution {
        case .success(.deferred):
            pendingConflicts[key] = event
            pendingOrder.append(key)
            lastError = "Conflict resolution deferred for \(event.url.lastPathComponent)"
            notifyQuiescenceIfNeeded()
            return false
        case .success:
            resolvedConflictKeys.insert(key)
            lastError = nil
            notifyQuiescenceIfNeeded()
            return true
        case .failure(let error):
            pendingConflicts[key] = event
            pendingOrder.append(key)
            lastError = describe(error)
            notifyQuiescenceIfNeeded()
            return false
        }
    }

    // MARK: - Drain

    private func beginBackgroundLifecycle() -> Int {
        transitionGeneration += 1
        return transitionGeneration
    }

    private func invalidateBackgroundLifecycle() {
        transitionGeneration += 1
        resumeInvalidatedQuiescenceWaiters()
    }

    private func isCurrentBackgroundLifecycle(_ generation: Int) -> Bool {
        transitionGeneration == generation && lifecycle == .backgrounding
    }

    private func waitForQuiescence(
        timeout: TimeInterval?,
        generation: Int? = nil
    ) async -> QuiescenceWaitResult {
        if isQuiescent { return .quiescent }
        if let generation, generation != transitionGeneration { return .invalidated }
        if let timeout, timeout <= 0 { return .timedOut }

        nextQuiescenceWaiterID += 1
        let id = nextQuiescenceWaiterID
        return await withCheckedContinuation { continuation in
            let timeoutTask = makeQuiescenceTimeoutTask(id: id, timeout: timeout)
            quiescenceWaiters[id] = QuiescenceWaiter(
                generation: generation,
                continuation: continuation,
                timeoutTask: timeoutTask)
            notifyQuiescenceIfNeeded()
            resumeInvalidatedQuiescenceWaiters()
        }
    }

    private func waitForQuiescenceUnbounded() async {
        while !isQuiescent {
            if await waitForQuiescence(timeout: nil) == .quiescent { return }
        }
    }

    private var isQuiescent: Bool {
        inFlightOperations == 0 && inFlightConflict == nil && conflictDrainTask == nil
    }

    private func notifyQuiescenceIfNeeded() {
        guard isQuiescent else { return }
        resumeQuiescenceWaiters(result: .quiescent) { _ in true }
    }

    private func resumeInvalidatedQuiescenceWaiters() {
        resumeQuiescenceWaiters(result: .invalidated) { waiter in
            if let generation = waiter.generation {
                return generation != transitionGeneration
            }
            return false
        }
    }

    private func quiescenceWaitTimedOut(id: Int) {
        resumeQuiescenceWaiter(id: id, result: .timedOut)
    }

    private func makeQuiescenceTimeoutTask(id: Int, timeout: TimeInterval?) -> Task<Void, Never>? {
        guard let timeout, timeout > 0 else { return nil }
        let nanoseconds = UInt64(min(
            Double(UInt64.max),
            (timeout * 1_000_000_000).rounded(.up)))
        return Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.quiescenceWaitTimedOut(id: id)
            } catch {}
        }
    }

    private func resumeQuiescenceWaiters(
        result: QuiescenceWaitResult,
        matching predicate: (QuiescenceWaiter) -> Bool
    ) {
        let ids = quiescenceWaiters.compactMap { id, waiter in
            predicate(waiter) ? id : nil
        }
        for id in ids {
            resumeQuiescenceWaiter(id: id, result: result)
        }
    }

    private func resumeQuiescenceWaiter(id: Int, result: QuiescenceWaitResult) {
        guard let waiter = quiescenceWaiters.removeValue(forKey: id) else { return }
        waiter.timeoutTask?.cancel()
        waiter.continuation.resume(returning: result)
    }

    // MARK: - Status

    private func status() -> Status {
        Status(
            chosenMode: chosenMode,
            effectiveMode: effectiveMode,
            lifecycle: lifecycle,
            availability: availability,
            acceptsCoordinatedOperations: acceptsCoordinatedOperations,
            pendingConflicts: pendingConflicts.count,
            inFlightConflicts: inFlightConflict == nil ? 0 : 1,
            inFlightOperations: inFlightOperations,
            lastError: lastError)
    }

    private func describe(_ error: any Error) -> String {
        if let synced = error as? SyncedContainerError {
            switch synced {
            case .cancelled:
                return "Coordinated storage was cancelled and will retry"
            case .notReady(let url, let readiness):
                return "\(url.lastPathComponent) is \(readiness.rawValue) and will retry"
            case .unavailable:
                return "Coordinated storage is unavailable"
            case .timedOut(let url):
                return "\(url.lastPathComponent) timed out and will retry"
            case .nestedCoordination(let url):
                return "Nested coordination refused for \(url.lastPathComponent)"
            case .io(let message):
                return message
            }
        }
        return String(describing: error)
    }

    // MARK: - Conflict archive rediscovery

    private func rediscoverArchivedConflicts() async {
        guard layout.requiresCoordination,
              let container = access.container
        else { return }
        let candidates = conflictArchiveRegistry.load().filter {
            Self.isLegitimateConflictArchive($0, in: layout)
        }
        var discovered: [URL: ArchivedConflictRecord] = [:]
        for descriptor in candidates {
            do {
                let items = try await container.list(
                    descriptor.archiveURL.deletingLastPathComponent(),
                    matching: SyncedItemFilter(namePrefix: descriptor.archiveName))
                guard items.contains(where: {
                    $0.url.standardizedFileURL == descriptor.archiveURL.standardizedFileURL
                }) else { continue }
                discovered[descriptor.id] = ArchivedConflictRecord(
                    descriptor: descriptor,
                    generation: storageGeneration)
            } catch {
                // Metadata may be temporarily unavailable. Keep the durable
                // descriptor and retry on the next foreground/reconfigure.
                continue
            }
        }
        guard discovered != archivedConflictRecords else { return }
        archivedConflictRecords = discovered
        NotificationCenter.default.post(
            name: .vellumStorageConflictArchivesChanged,
            object: nil)
    }

    private func rememberArchivedConflicts(_ conflicts: [ArchivedConflict]) {
        var persisted: [URL: ArchivedConflict] = [:]
        for conflict in conflictArchiveRegistry.load() {
            persisted[conflict.id] = conflict
        }
        for conflict in conflicts { persisted[conflict.id] = conflict }
        conflictArchiveRegistry.save(Array(persisted.values))
    }

    private func forgetArchivedConflict(_ id: URL) {
        conflictArchiveRegistry.save(
            conflictArchiveRegistry.load().filter { $0.id != id })
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootComponents = root.standardizedFileURL.pathComponents
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        guard candidateComponents.count > rootComponents.count else { return false }
        return candidateComponents.prefix(rootComponents.count).elementsEqual(rootComponents)
    }

    private static func isLegitimateConflictArchive(
        _ conflict: ArchivedConflict,
        in layout: WebStorageLayout
    ) -> Bool {
        let archiveURL = conflict.archiveURL.standardizedFileURL
        let originalURL = conflict.originalURL.standardizedFileURL
        let conflictsDirectory = archiveURL.deletingLastPathComponent()
        guard conflictsDirectory.lastPathComponent == "conflicts",
              conflictsDirectory.deletingLastPathComponent().standardizedFileURL
                == originalURL.deletingLastPathComponent().standardizedFileURL,
              archiveURL.lastPathComponent.hasPrefix(
                originalURL.deletingPathExtension().lastPathComponent + ".")
        else { return false }

        if let indexPath = layout.indexPath,
           originalURL == indexPath.standardizedFileURL {
            return true
        }
        return [layout.recordsDir, layout.archivesDir, layout.documentsDir, layout.positionsDir]
            .contains { isDescendant(originalURL, of: $0) }
    }
}

extension Notification.Name {
    static let vellumStorageConflictArchivesChanged = Notification.Name(
        "vellumStorageConflictArchivesChanged")
}
