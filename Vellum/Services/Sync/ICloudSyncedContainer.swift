import Foundation

// The ONLY file in the repo that touches NSFileCoordinator, NSFilePresenter,
// NSMetadataQuery or NSFileVersion. Everything else holds `any SyncedContainer`.
//
// Constraints this adapter is required to keep (callers depend on them):
//   * only the async `coordinate(with:queue:byAccessor:)` form — the
//     synchronous `coordinate(readingItemAt:)`/`coordinate(writingItemAt:)`
//     forms appear nowhere;
//   * one presenter per DIRECTORY, using `presentedSubitem(at:didGain:)`, so
//     one presenter on `records/` covers every sidecar;
//   * NSMetadataQuery is the only discovery mechanism — no directory
//     enumeration, no `fileExists(atPath:)`;
//   * a nested coordinated access throws instead of deadlocking;
//   * `NSUserCancelledError` maps to `.cancelled`, a normal retryable outcome;
//   * `url(forUbiquityContainerIdentifier:)` is called once, with the explicit
//     identifier (never nil), off the main thread, and the result is cached.
//
// On this branch the iCloud entitlement is deliberately not wired into
// project.yml (free signing team can't provision it — Vellum#149), so
// `init?` returns nil and every test runs against `FakeSyncedContainer`.
actor ICloudSyncedContainer: SyncedContainer {
    private let identifier: SyncedContainerIdentifier
    private let root: URL
    private let clock: PositionClock
    private let injectedResolver: (any ConflictResolver)?
    private let coordinationQueue: OperationQueue
    private let presenter: DirectoryConflictPresenter
    private let watcher: UbiquitousMetadataWatcher

    nonisolated let conflicts: AsyncStream<ConflictEvent>
    private nonisolated let conflictSink: AsyncStream<ConflictEvent>.Continuation

    private var isSuspended = false
    private var presenterIsRegistered = true

    /// Blocking on first call (the ubiquity lookup), so construct this off the
    /// main thread. Returns nil when the container is unavailable.
    init?(
        identifier: SyncedContainerIdentifier = .vellum,
        subpath: String = "Documents",
        resolver: (any ConflictResolver)? = nil,
        clock: PositionClock = SystemPositionClock()
    ) {
        guard let containerRoot = Self.containerRoot(for: identifier) else { return nil }
        self.identifier = identifier
        self.root =
            subpath.isEmpty
            ? containerRoot : containerRoot.appendingPathComponent(subpath, isDirectory: true)
        self.clock = clock
        self.injectedResolver = resolver

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "com.ayushdeolasee.vellum.coordination"
        self.coordinationQueue = queue

        let (stream, sink) = AsyncStream<ConflictEvent>.makeStream()
        self.conflicts = stream
        self.conflictSink = sink

        let now = clock
        let emit: @Sendable (URL) -> Void = { url in
            guard let event = Self.conflictEvent(at: url, detectedAt: now.now()) else { return }
            sink.yield(event)
        }
        self.presenter = DirectoryConflictPresenter(url: self.root, queue: queue, onConflict: emit)
        self.watcher = UbiquitousMetadataWatcher(onConflict: emit)

        NSFileCoordinator.addFilePresenter(presenter)
        let watcher = self.watcher
        Task { @MainActor in watcher.start() }
    }

    deinit {
        conflictSink.finish()
    }

    // MARK: Reads

    func read<T: Sendable>(
        _ url: URL,
        materializing: Materialization,
        _ body: @Sendable (Data) throws -> T
    ) async throws -> T {
        try await SyncedContainerAccessor.guarded(url) {
            try await ensureReady(url, materializing)
            let data = try await coordinatedRead(url)
            return try body(data)
        }
    }

    // MARK: Writes

    func replace(_ url: URL, with data: Data) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            try await coordinatedReplace(url, with: data)
        }
    }

    func remove(_ url: URL) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            try await coordinatedRemove(url)
        }
    }

    // MARK: Discovery

    func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem] {
        guard !isSuspended else { throw SyncedContainerError.unavailable }
        let watcher = self.watcher
        let items = await MainActor.run { watcher.items(in: directory) }
        return items.filter(filter.matches).sorted { $0.name < $1.name }
    }

    // MARK: Conflicts

    func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution {
        let url = event.url
        let resolution = try await resolver.resolve(event) { version in
            guard let match = Self.fileVersion(matching: version, at: url) else {
                throw SyncedContainerError.io("Conflict version \(version.id) is gone")
            }
            return try await self.coordinatedRead(match.url)
        }
        switch resolution {
        case .keptCurrent, .merged:
            Self.markLosersResolved(at: url)
        case .deferred:
            break
        }
        return resolution
    }

    private var resolver: any ConflictResolver {
        if let injectedResolver { return injectedResolver }
        return PreserveLosersConflictResolver { [self] destination, data in
            try await self.replace(destination, with: data)
        }
    }

    // MARK: Lifecycle

    func suspend() async {
        guard !isSuspended else { return }
        isSuspended = true
        if presenterIsRegistered {
            NSFileCoordinator.removeFilePresenter(presenter)
            presenterIsRegistered = false
        }
        let watcher = self.watcher
        await MainActor.run { watcher.stop() }
    }

    func resume() async {
        guard isSuspended else { return }
        isSuspended = false
        if !presenterIsRegistered {
            NSFileCoordinator.addFilePresenter(presenter)
            presenterIsRegistered = true
        }
        let watcher = self.watcher
        await MainActor.run { watcher.start() }
        // No replay buffer: `unresolvedConflictVersionsOfItem` is authoritative
        // and cheap to re-ask, so a fresh scan beats state that can be wrong.
        for url in await MainActor.run(body: { watcher.conflictedURLs() }) {
            if let event = Self.conflictEvent(at: url, detectedAt: clock.now()) {
                conflictSink.yield(event)
            }
        }
    }

    // MARK: Coordinated primitives

    private func ensureReady(_ url: URL, _ materializing: Materialization) async throws {
        let watcher = self.watcher
        let readiness = await MainActor.run { watcher.readiness(of: url) }
        if readiness.isReady { return }
        switch materializing {
        case .requireCurrent:
            throw SyncedContainerError.notReady(url, readiness)
        case .downloadIfNeeded(let timeout):
            do {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            } catch {
                throw Self.mapped(error, url: url)
            }
            let deadline = clock.now().addingTimeInterval(timeout)
            while clock.now() < deadline {
                if await MainActor.run(body: { watcher.readiness(of: url) }).isReady { return }
                try? await Task.sleep(for: .milliseconds(100))
            }
            throw SyncedContainerError.timedOut(url)
        }
    }

    private func coordinatedRead(_ url: URL) async throws -> Data {
        let presenter = self.presenter
        let queue = self.coordinationQueue
        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = NSFileCoordinator(filePresenter: presenter)
            let intent = NSFileAccessIntent.readingIntent(with: url, options: [.withoutChanges])
            let box = UncheckedBox(intent)
            coordinator.coordinate(with: [intent], queue: queue) { error in
                if let error {
                    continuation.resume(throwing: Self.mapped(error, url: url))
                    return
                }
                do {
                    continuation.resume(returning: try Data(contentsOf: box.value.url))
                } catch {
                    continuation.resume(throwing: Self.mapped(error, url: url))
                }
            }
        }
    }

    private func coordinatedReplace(_ url: URL, with data: Data) async throws {
        let presenter = self.presenter
        let queue = self.coordinationQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let coordinator = NSFileCoordinator(filePresenter: presenter)
            // `.forReplacing` is the only option this adapter ever uses: every
            // Vellum write is a tmp+rename onto the destination, never an
            // in-place update of existing contents.
            let intent = NSFileAccessIntent.writingIntent(with: url, options: [.forReplacing])
            let box = UncheckedBox(intent)
            coordinator.coordinate(with: [intent], queue: queue) { error in
                if let error {
                    continuation.resume(throwing: Self.mapped(error, url: url))
                    return
                }
                let destination = box.value.url
                let fileManager = FileManager.default
                let tmp = destination.appendingPathExtension("tmp")
                do {
                    try fileManager.createDirectory(
                        at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: tmp)
                } catch {
                    continuation.resume(throwing: Self.mapped(error, url: url))
                    return
                }
                guard rename(tmp.path, destination.path) == 0 else {
                    try? fileManager.removeItem(at: tmp)
                    continuation.resume(throwing: SyncedContainerError.io("rename failed for \(destination.path)"))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func coordinatedRemove(_ url: URL) async throws {
        let presenter = self.presenter
        let queue = self.coordinationQueue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let coordinator = NSFileCoordinator(filePresenter: presenter)
            let intent = NSFileAccessIntent.writingIntent(with: url, options: [.forDeleting])
            let box = UncheckedBox(intent)
            coordinator.coordinate(with: [intent], queue: queue) { error in
                if let error {
                    continuation.resume(throwing: Self.mapped(error, url: url))
                    return
                }
                do {
                    try FileManager.default.removeItem(at: box.value.url)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: Self.mapped(error, url: url))
                }
            }
        }
    }

    // MARK: Version plumbing

    private static func conflictEvent(at url: URL, detectedAt: Date) -> ConflictEvent? {
        let unresolved = NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? []
        guard !unresolved.isEmpty else { return nil }
        var versions: [ConflictVersion] = []
        if let current = NSFileVersion.currentVersionOfItem(at: url) {
            versions.append(describe(current, isCurrent: true))
        }
        versions.append(contentsOf: unresolved.map { describe($0, isCurrent: false) })
        guard versions.count >= 2 else { return nil }
        return ConflictEvent(url: url, detectedAt: detectedAt, versions: versions)
    }

    private static func describe(_ version: NSFileVersion, isCurrent: Bool) -> ConflictVersion {
        ConflictVersion(
            id: String(describing: version.persistentIdentifier),
            modifiedAt: version.modificationDate,
            originatingDeviceName: version.localizedNameOfSavingComputer,
            isCurrent: isCurrent)
    }

    private static func fileVersion(matching version: ConflictVersion, at url: URL) -> NSFileVersion? {
        if version.isCurrent { return NSFileVersion.currentVersionOfItem(at: url) }
        return (NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [])
            .first { String(describing: $0.persistentIdentifier) == version.id }
    }

    private static func markLosersResolved(at url: URL) {
        for version in NSFileVersion.unresolvedConflictVersionsOfItem(at: url) ?? [] {
            version.isResolved = true
        }
    }

    // MARK: Container root

    private nonisolated(unsafe) static var cachedRoots: [String: URL] = [:]
    private nonisolated(unsafe) static var resolvedIdentifiers: Set<String> = []
    private static let rootLock = NSLock()

    /// Called exactly once per identifier and cached — including the nil
    /// answer, so an unavailable container isn't re-probed on every access.
    private static func containerRoot(for identifier: SyncedContainerIdentifier) -> URL? {
        rootLock.lock()
        if resolvedIdentifiers.contains(identifier.rawValue) {
            let cached = cachedRoots[identifier.rawValue]
            rootLock.unlock()
            return cached
        }
        rootLock.unlock()
        let url = FileManager.default.url(forUbiquityContainerIdentifier: identifier.rawValue)
        rootLock.lock()
        resolvedIdentifiers.insert(identifier.rawValue)
        cachedRoots[identifier.rawValue] = url
        rootLock.unlock()
        return url
    }

    private static func mapped(_ error: any Error, url: URL) -> SyncedContainerError {
        if let already = error as? SyncedContainerError { return already }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return .cancelled
        }
        return .io(nsError.localizedDescription)
    }
}

/// Foundation's coordination types predate `Sendable`; the accessor block runs
/// on our own serial queue, so hopping the intent across is safe in practice.
private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// One presenter for a whole DIRECTORY. `presentedSubitem(at:didGain:)` is what
/// makes that possible — one presenter on `records/` sees a conflict on every
/// sidecar inside it, so there is never one presenter per file.
private final class DirectoryConflictPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue
    private let onConflict: @Sendable (URL) -> Void

    init(url: URL, queue: OperationQueue, onConflict: @escaping @Sendable (URL) -> Void) {
        self.presentedItemURL = url
        self.presentedItemOperationQueue = queue
        self.onConflict = onConflict
    }

    func presentedSubitem(at url: URL, didGain version: NSFileVersion) {
        onConflict(url)
    }

    func presentedItemDidGain(_ version: NSFileVersion) {
        guard let presentedItemURL else { return }
        onConflict(presentedItemURL)
    }
}

/// The discovery half. Configured the way the API docs ask for: batched
/// notifications, both ubiquitous scopes, `DidFinishGathering` then `DidUpdate`,
/// and every result access bracketed by `disableUpdates()`/`enableUpdates()`.
@MainActor
private final class UbiquitousMetadataWatcher {
    private let query = NSMetadataQuery()
    private var observers: [any NSObjectProtocol] = []
    private let onConflict: @Sendable (URL) -> Void
    private(set) var isRunning = false

    nonisolated init(onConflict: @escaping @Sendable (URL) -> Void) {
        self.onConflict = onConflict
    }

    func start() {
        guard !isRunning else { return }
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope, NSMetadataQueryUbiquitousDocumentsScope]
        query.notificationBatchingInterval = 1
        query.predicate = NSPredicate(format: "%K LIKE %@", NSMetadataItemFSNameKey, "*")
        let center = NotificationCenter.default
        for name in [Notification.Name.NSMetadataQueryDidFinishGathering, .NSMetadataQueryDidUpdate] {
            let token = center.addObserver(forName: name, object: query, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportConflicts() }
            }
            observers.append(token)
        }
        isRunning = query.start()
    }

    func stop() {
        guard isRunning else { return }
        query.stop()
        let center = NotificationCenter.default
        for token in observers { center.removeObserver(token) }
        observers.removeAll()
        isRunning = false
    }

    func items(in directory: URL) -> [SyncedItem] {
        withResults { results in
            results.compactMap(Self.item(from:))
                .filter { $0.url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL }
        }
    }

    func readiness(of url: URL) -> ItemReadiness {
        withResults { results in
            for result in results {
                guard let item = Self.item(from: result) else { continue }
                if item.url.standardizedFileURL == url.standardizedFileURL { return item.readiness }
            }
            return .notDownloaded
        }
    }

    func conflictedURLs() -> [URL] {
        withResults { results in
            results.compactMap(Self.item(from:)).filter(\.hasUnresolvedConflicts).map(\.url)
        }
    }

    private func reportConflicts() {
        for url in conflictedURLs() { onConflict(url) }
    }

    private func withResults<T>(_ body: ([NSMetadataItem]) -> T) -> T {
        query.disableUpdates()
        defer { query.enableUpdates() }
        let results = (query.results as? [NSMetadataItem]) ?? []
        return body(results)
    }

    private static func item(from metadata: NSMetadataItem) -> SyncedItem? {
        guard let url = metadata.value(forAttribute: NSMetadataItemURLKey) as? URL else { return nil }
        let name =
            metadata.value(forAttribute: NSMetadataItemFSNameKey) as? String ?? url.lastPathComponent
        let status = metadata.value(forAttribute: NSMetadataUbiquitousItemDownloadingStatusKey) as? String
        return SyncedItem(
            url: url,
            name: name,
            readiness: readiness(from: status),
            byteSize: (metadata.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber)?.int64Value,
            contentModifiedAt: metadata.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date,
            hasUnresolvedConflicts: (metadata.value(
                forAttribute: NSMetadataUbiquitousItemHasUnresolvedConflictsKey) as? Bool) ?? false,
            uploadedToCloud: (metadata.value(forAttribute: NSMetadataUbiquitousItemIsUploadedKey) as? Bool)
                ?? false)
    }

    private static func readiness(from status: String?) -> ItemReadiness {
        switch status {
        case NSMetadataUbiquitousItemDownloadingStatusCurrent: return .current
        case NSMetadataUbiquitousItemDownloadingStatusDownloaded: return .downloaded
        default: return .notDownloaded
        }
    }
}
