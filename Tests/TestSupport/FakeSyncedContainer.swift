import Foundation

@testable import Vellum

/// The scriptable stand-in for `ICloudSyncedContainer`. Entirely in memory: no
/// NSFileCoordinator, no ubiquity container, no device required — which is the
/// whole point of the seam.
///
/// The counters are evidence, in the `FakeKeychain(readCount/writeCount/
/// lockDepth)` idiom: `forReplacingWriteCount == coordinatedWriteCount` and
/// `maxAccessorDepth <= 1` turn "we coordinated correctly" from a claim into an
/// assertion, and `directoryEnumerationCount`/`existenceCheckCount` staying at
/// zero is the structural proof that discovery only ever goes through `list`.
final class FakeSyncedContainer: SyncedContainer, @unchecked Sendable {
    private struct Entry {
        var data: Data
        var readiness: ItemReadiness
        var modifiedAt: Date
        var uploaded: Bool
        var stalled: Bool
    }

    private struct Conflict {
        var versions: [ConflictVersion]
        var payloads: [String: Data]
        var detectedAt: Date
    }

    private let lock = NSLock()
    private var entries: [URL: Entry] = [:]
    private var conflictsByURL: [URL: Conflict] = [:]
    private var suspended = false
    private var pendingWriteError: SyncedContainerError?
    private var pendingListError: SyncedContainerError?

    private var reads = 0
    private var writes = 0
    private var replacingWrites = 0
    private var removals = 0
    private var queries = 0
    private var registrations = 1
    private var removalsOfPresenter = 0
    private var accessorDepth = 0
    private var deepestAccessor = 0
    private var delivered = 0
    private var materializations = 0
    private var queryRunning = true
    private var enumerations = 0
    private var existenceChecks = 0

    let conflicts: AsyncStream<ConflictEvent>
    private let sink: AsyncStream<ConflictEvent>.Continuation
    private let clock: PositionClock
    private var resolver: any ConflictResolver = PreserveLosersConflictResolver()

    init(resolver: (any ConflictResolver)? = nil, clock: PositionClock = SystemPositionClock()) {
        let (stream, sink) = AsyncStream<ConflictEvent>.makeStream()
        self.conflicts = stream
        self.sink = sink
        self.clock = clock
        self.resolver =
            resolver
            ?? PreserveLosersConflictResolver(archive: { [unowned self] url, data in
                try await self.replace(url, with: data)
            })
    }

    deinit { sink.finish() }

    // MARK: - Scripting

    func seed(_ url: URL, data: Data, readiness: ItemReadiness = .current) {
        lock.withLock {
            entries[url] = Entry(
                data: data, readiness: readiness, modifiedAt: clock.now(), uploaded: true, stalled: false)
        }
    }

    func setReadiness(_ readiness: ItemReadiness, at url: URL) {
        lock.withLock { entries[url]?.readiness = readiness }
    }

    /// The download never completes — a `.downloadIfNeeded` read times out
    /// rather than handing back the stale local copy.
    func stallMaterialization(at url: URL) {
        lock.withLock { entries[url]?.stalled = true }
    }

    func injectConflict(at url: URL, versions: [ConflictVersion], payloads: [String: Data] = [:]) {
        let event: ConflictEvent? = lock.withLock {
            let conflict = Conflict(versions: versions, payloads: payloads, detectedAt: clock.now())
            conflictsByURL[url] = conflict
            guard !suspended else { return nil }
            delivered += 1
            return ConflictEvent(url: url, detectedAt: conflict.detectedAt, versions: versions)
        }
        if let event { sink.yield(event) }
    }

    func clearConflict(at url: URL) {
        lock.withLock { conflictsByURL.removeValue(forKey: url) }
    }

    func failNextWrite(with error: SyncedContainerError) {
        lock.withLock { pendingWriteError = error }
    }

    func cancelNextWrite() {
        failNextWrite(with: .cancelled)
    }

    func failNextList(with error: SyncedContainerError) {
        lock.withLock { pendingListError = error }
    }

    /// Inspect bytes without recording a coordinated read.
    func peek(_ url: URL) -> Data? {
        lock.withLock { entries[url]?.data }
    }

    func hasUnresolvedConflict(at url: URL) -> Bool {
        lock.withLock { conflictsByURL[url] != nil }
    }

    // MARK: - Evidence

    var coordinatedReadCount: Int { lock.withLock { reads } }
    var coordinatedWriteCount: Int { lock.withLock { writes } }
    var forReplacingWriteCount: Int { lock.withLock { replacingWrites } }
    var coordinatedRemoveCount: Int { lock.withLock { removals } }
    var metadataQueryCount: Int { lock.withLock { queries } }
    /// Must always be 0: the seam offers no directory enumeration.
    ///
    /// Real state, not a literal `0`. A hardcoded constant would make every
    /// assertion built on it tautological — it could not fail no matter what
    /// the code under test did — so the counter is live and
    /// `noteDirectoryEnumeration()` is the one way to move it. Anything that
    /// reaches for `FileManager` against the synced root goes through there.
    var directoryEnumerationCount: Int { lock.withLock { enumerations } }
    /// Must always be 0: the seam offers no existence check. Live, for the same
    /// reason as `directoryEnumerationCount`.
    var existenceCheckCount: Int { lock.withLock { existenceChecks } }

    /// Records a directory enumeration the seam is not supposed to perform.
    /// Nothing in the shipping path calls this; it exists so the invariant is
    /// measured rather than asserted against a constant, and so a test can show
    /// the counter is capable of failing.
    func noteDirectoryEnumeration() { lock.withLock { enumerations += 1 } }

    /// Records an existence check (`fileExists(atPath:)` and friends), which
    /// materializes a ubiquitous file. Same contract as above.
    func noteExistenceCheck() { lock.withLock { existenceChecks += 1 } }
    var presenterRegistrations: Int { lock.withLock { registrations } }
    var presenterRemovals: Int { lock.withLock { removalsOfPresenter } }
    /// Must never exceed 1.
    var maxAccessorDepth: Int { lock.withLock { deepestAccessor } }
    var deliveredConflictCount: Int { lock.withLock { delivered } }
    var materializationCount: Int { lock.withLock { materializations } }
    var isMetadataQueryRunning: Bool { lock.withLock { queryRunning } }
    var isSuspended: Bool { lock.withLock { suspended } }

    // MARK: - SyncedContainer

    func read<T: Sendable>(
        _ url: URL,
        materializing: Materialization,
        _ body: @Sendable (Data) throws -> T
    ) async throws -> T {
        try await SyncedContainerAccessor.guarded(url) {
            enterAccessor()
            defer { exitAccessor() }
            let data = try materialize(url, materializing)
            lock.withLock { reads += 1 }
            return try body(data)
        }
    }

    func replace(_ url: URL, with data: Data) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            enterAccessor()
            defer { exitAccessor() }
            try lock.withLock {
                // Both counters move together because there is exactly one
                // write path and it is always `.forReplacing`.
                writes += 1
                replacingWrites += 1
                if let pendingWriteError {
                    self.pendingWriteError = nil
                    throw pendingWriteError
                }
                entries[url] = Entry(
                    data: data, readiness: .current, modifiedAt: clock.now(), uploaded: false,
                    stalled: false)
            }
        }
    }

    func remove(_ url: URL) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            enterAccessor()
            defer { exitAccessor() }
            lock.withLock {
                removals += 1
                entries.removeValue(forKey: url)
                conflictsByURL.removeValue(forKey: url)
            }
        }
    }

    func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem] {
        // Suspended means the metadata query is stopped, so there is nothing to
        // ask. The real adapter throws here; a fake that answered anyway would
        // certify caller code against an error path it never has to handle.
        try lock.withLock {
            if suspended { throw SyncedContainerError.unavailable }
            queries += 1
            if let pendingListError {
                self.pendingListError = nil
                throw pendingListError
            }
            let target = directory.standardizedFileURL
            return
                entries
                .filter { $0.key.deletingLastPathComponent().standardizedFileURL == target }
                .map { url, entry in
                    SyncedItem(
                        url: url,
                        name: url.lastPathComponent,
                        readiness: entry.readiness,
                        byteSize: Int64(entry.data.count),
                        contentModifiedAt: entry.modifiedAt,
                        hasUnresolvedConflicts: conflictsByURL[url] != nil,
                        uploadedToCloud: entry.uploaded)
                }
                .filter(filter.matches)
                .sorted { $0.name < $1.name }
        }
    }

    func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution {
        let resolution = try await resolver.resolve(event) { version in
            guard let data = self.payload(for: version, at: event.url) else {
                throw SyncedContainerError.io("no bytes for version \(version.id)")
            }
            return data
        }
        switch resolution {
        case .keptCurrent, .merged:
            clearConflict(at: event.url)
        case .deferred:
            break
        }
        return resolution
    }

    func suspend() async {
        lock.withLock {
            guard !suspended else { return }
            suspended = true
            removalsOfPresenter += 1
            queryRunning = false
        }
    }

    func resume() async {
        let pending: [ConflictEvent] = lock.withLock {
            guard suspended else { return [] }
            suspended = false
            registrations += 1
            queryRunning = true
            let events = conflictsByURL.map { url, conflict in
                ConflictEvent(url: url, detectedAt: conflict.detectedAt, versions: conflict.versions)
            }
            .sorted { $0.url.absoluteString < $1.url.absoluteString }
            delivered += events.count
            return events
        }
        for event in pending { sink.yield(event) }
    }

    // MARK: - Internals

    private func payload(for version: ConflictVersion, at url: URL) -> Data? {
        lock.withLock {
            if let data = conflictsByURL[url]?.payloads[version.id] { return data }
            return version.isCurrent ? entries[url]?.data : nil
        }
    }

    private func materialize(_ url: URL, _ materializing: Materialization) throws -> Data {
        try lock.withLock {
            guard let entry = entries[url] else {
                throw SyncedContainerError.io("no such item: \(url.lastPathComponent)")
            }
            if entry.readiness.isReady { return entry.data }
            switch materializing {
            case .requireCurrent:
                throw SyncedContainerError.notReady(url, entry.readiness)
            case .downloadIfNeeded:
                materializations += 1
                if entry.stalled { throw SyncedContainerError.timedOut(url) }
                entries[url]?.readiness = .current
                return entry.data
            }
        }
    }

    private func enterAccessor() {
        lock.withLock {
            accessorDepth += 1
            deepestAccessor = max(deepestAccessor, accessorDepth)
        }
    }

    private func exitAccessor() {
        lock.withLock { accessorDepth -= 1 }
    }
}
