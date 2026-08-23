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
// Production resolves the fixed container authorized by the app's iCloud
// entitlement. Tests use `FakeSyncedContainer` through the established seam.
actor ICloudSyncedContainer: SyncedContainer {
    private let identifier: SyncedContainerIdentifier
    private let root: URL
    private let clock: PositionClock
    private let injectedResolver: (any ConflictResolver)?
    private let coordinationQueue: OperationQueue
    private nonisolated let registration: PresenterRegistration
    private nonisolated let watcher: UbiquitousMetadataWatcher
    /// The query start is asynchronous (it has to hop to the main actor), so a
    /// prompt `suspend()` has to be able to wait for it — otherwise stop() runs
    /// before start() and the container reports suspended with a live query.
    private nonisolated let startup: Task<Void, Never>

    nonisolated let conflicts: AsyncStream<ConflictEvent>
    private nonisolated let conflictSink: AsyncStream<ConflictEvent>.Continuation

    private var isSuspended = false
    /// URLs this container replaced whose bytes the metadata query has not
    /// reported yet. See `settledReadiness(of:)`.
    private var locallyCurrent: Set<URL> = []

    private nonisolated var presenter: DirectoryConflictPresenter { registration.presenter }

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
        self.registration = PresenterRegistration(
            presenter: DirectoryConflictPresenter(url: self.root, queue: queue, onConflict: emit))
        self.watcher = UbiquitousMetadataWatcher(onConflict: emit)

        self.registration.register()
        let watcher = self.watcher
        self.startup = Task { @MainActor in watcher.start() }
    }

    /// Everything registered in `init` has to come back out. A presenter left
    /// registered outlives its container — `NSFileCoordinator` holds a global
    /// strong reference to it — and keeps firing conflict callbacks into a dead
    /// object graph; Apple's deadlock-prevention kill is the other half of that
    /// mistake. The query has to be stopped for the same reason. Neither hop
    /// touches `self`, so nothing is resurrected here.
    deinit {
        conflictSink.finish()
        registration.unregister()
        let watcher = self.watcher
        let startup = self.startup
        Task { @MainActor in
            await startup.value
            watcher.stop()
        }
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
            // These bytes are current on local disk right now; the metadata
            // query won't say so for up to its batching interval.
            locallyCurrent.insert(url.standardizedFileURL)
        }
    }

    func remove(_ url: URL) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            try await coordinatedRemove(url)
            locallyCurrent.remove(url.standardizedFileURL)
        }
    }

    // MARK: Discovery

    func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem] {
        guard !isSuspended else { throw SyncedContainerError.unavailable }
        await startup.value
        let watcher = self.watcher
        let deadline = clock.now().addingTimeInterval(Self.gatheringGrace)
        while clock.now() < deadline,
              !(await MainActor.run { watcher.hasFinishedGathering }) {
            try? await Task.sleep(for: .milliseconds(50))
            guard !isSuspended else { throw SyncedContainerError.unavailable }
        }
        let snapshot = await MainActor.run {
            (isComplete: watcher.hasFinishedGathering, items: watcher.items(in: directory))
        }
        guard !isSuspended else { throw SyncedContainerError.unavailable }
        guard snapshot.isComplete else {
            throw SyncedContainerError.timedOut(directory)
        }
        return snapshot.items.filter(filter.matches).sorted { $0.name < $1.name }
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
        registration.unregister()
        // Let the construction-time start finish first: `suspend()` called
        // promptly after `init` would otherwise stop a query that has not
        // started, and the start would then win.
        await startup.value
        let watcher = self.watcher
        await MainActor.run { watcher.stop() }
    }

    func resume() async {
        guard isSuspended else { return }
        isSuspended = false
        registration.register()
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

    /// How long a read waits for the metadata query's first gathering pass
    /// before it is willing to call an unmentioned file not-downloaded.
    private static let gatheringGrace: TimeInterval = 2

    /// What the query knows about `url` right now, or nil when it has not
    /// mentioned it at all.
    ///
    /// "Not in the result set" is NOT "not downloaded". The query reports
    /// nothing until its first gathering pass finishes and batches updates at
    /// one second after that, so reading the absence as `.notDownloaded` fails
    /// every read in the first seconds after launch and every read of bytes
    /// this container itself just wrote. Hence the two fallbacks: our own
    /// replace marks the URL current until the query says otherwise, and an
    /// unknown URL waits out the gathering pass before being judged.
    private func reportedReadiness(of url: URL) async -> ItemReadiness? {
        let watcher = self.watcher
        let standardized = url.standardizedFileURL
        if let reported = await MainActor.run(body: { watcher.readiness(of: url) }) {
            // The query is authoritative from the moment it has an opinion —
            // a peer's newer version must be able to make this stale again.
            locallyCurrent.remove(standardized)
            return reported
        }
        return locallyCurrent.contains(standardized) ? .current : nil
    }

    private func settledReadiness(of url: URL) async -> ItemReadiness {
        if let readiness = await reportedReadiness(of: url) { return readiness }
        let watcher = self.watcher
        let deadline = clock.now().addingTimeInterval(Self.gatheringGrace)
        while clock.now() < deadline {
            if await MainActor.run(body: { watcher.hasFinishedGathering }) { break }
            try? await Task.sleep(for: .milliseconds(50))
            if let readiness = await reportedReadiness(of: url) { return readiness }
        }
        return await reportedReadiness(of: url) ?? .notDownloaded
    }

    private func ensureReady(_ url: URL, _ materializing: Materialization) async throws {
        let readiness = await settledReadiness(of: url)
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
                if await reportedReadiness(of: url)?.isReady == true { return }
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

    private static func containerRoot(for identifier: SyncedContainerIdentifier) -> URL? {
        VellumUbiquityContainerRoot.root(for: identifier)
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

/// Owns the registered/unregistered state of one presenter behind a lock, so
/// `deinit` can unregister without hopping to the actor's isolation (it can't)
/// and without racing `suspend()`/`resume()`. Both verbs are idempotent.
private final class PresenterRegistration: @unchecked Sendable {
    let presenter: DirectoryConflictPresenter
    private let lock = NSLock()
    private var isRegistered = false

    init(presenter: DirectoryConflictPresenter) {
        self.presenter = presenter
    }

    func register() {
        let shouldAdd = lock.withLock {
            guard !isRegistered else { return false }
            isRegistered = true
            return true
        }
        if shouldAdd { NSFileCoordinator.addFilePresenter(presenter) }
    }

    func unregister() {
        let shouldRemove = lock.withLock {
            guard isRegistered else { return false }
            isRegistered = false
            return true
        }
        if shouldRemove { NSFileCoordinator.removeFilePresenter(presenter) }
    }
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
    /// False until the first `DidFinishGathering`. Until then an empty result
    /// set means "we haven't looked yet", not "the file isn't there".
    private(set) var hasFinishedGathering = false

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
                MainActor.assumeIsolated {
                    self?.hasFinishedGathering = true
                    self?.reportConflicts()
                }
            }
            observers.append(token)
        }
        isRunning = query.start()
    }

    func stop() {
        guard isRunning else { return }
        query.stop()
        hasFinishedGathering = false
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

    /// nil means "the query has no opinion yet", which is not the same as
    /// `.notDownloaded` — see `ICloudSyncedContainer.reportedReadiness(of:)`.
    func readiness(of url: URL) -> ItemReadiness? {
        withResults { results in
            for result in results {
                guard let item = Self.item(from: result) else { continue }
                if item.url.standardizedFileURL == url.standardizedFileURL { return item.readiness }
            }
            return nil
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
