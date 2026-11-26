import Foundation

public actor FolderSyncedContainer: SyncedContainer {
    public nonisolated let webArchives: SharedWebArchives
    private let root: URL
    private let store: any FolderFileStore
    private let watcher: any FolderDirectoryWatching
    private let merge: PreserveLosersConflictResolver.Merge
    private let interval: Duration
    public nonisolated let conflicts: AsyncStream<ConflictEvent>
    private let output: AsyncStream<ConflictEvent>.Continuation
    private var changes: AsyncStream<Bool>.Continuation?
    private var watchTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var generation = 0
    private var versions: [URL: [ConflictVersion: URL]] = [:]
    private var resolving: Set<URL> = []

    public init(root: URL, store: any FolderFileStore, watcher: any FolderDirectoryWatching,
                rescanInterval: Duration = .seconds(30),
                merge: @escaping PreserveLosersConflictResolver.Merge = { _, _ in .preserve }) {
        self.root = root.standardizedFileURL
        webArchives = SharedWebArchives(root: self.root, store: store)
        self.store = store
        self.watcher = watcher
        self.interval = rescanInterval
        self.merge = merge
        (conflicts, output) = AsyncStream.makeStream()
    }

    public func read<T: Sendable>(_ url: URL, materializing: Materialization,
                                  _ body: @Sendable (Data) throws -> T) async throws -> T {
        try await SyncedContainerAccessor.guarded(url) {
            guard let data = try await store.read(url) else { throw CocoaError(.fileReadNoSuchFile) }
            return try body(data)
        }
    }

    public func replace(_ url: URL, with data: Data) async throws {
        try await SyncedContainerAccessor.guarded(url) { try await store.replace(url, with: data) }
    }

    public func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool {
        try await SyncedContainerAccessor.guarded(url) {
            try await store.replace(url, with: data, ifCurrent: expected)
        }
    }

    public func remove(_ url: URL) async throws {
        try await SyncedContainerAccessor.guarded(url) { try await store.remove(url) }
    }

    public func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem] {
        guard changes != nil else { throw SyncedContainerError.unavailable }
        return try await store.list(directory, suffix: nil).map {
            SyncedItem(url: $0.url, name: $0.name, readiness: $0.readiness, byteSize: $0.byteSize,
                       contentModifiedAt: $0.contentModifiedAt, hasUnresolvedConflicts: versions[$0.url] != nil)
        }.filter(filter.matches)
    }

    public func resume() async {
        guard changes == nil else { return }
        generation += 1
        let epoch = generation
        let (stream, signal) = AsyncStream<Bool>.makeStream(bufferingPolicy: .bufferingNewest(1))
        changes = signal
        // Attach before the initial scan, and buffer events during discovery.
        watcher.update(directories: [root]) { signal.yield(false) }
        await scan(epoch: epoch, signal: signal, retry: false, initial: true)
        guard generation == epoch else { return }
        watchTask = Task { [weak self] in
            for await retry in stream { await self?.scan(epoch: epoch, signal: signal, retry: retry) }
        }
        timer = Task { [interval] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                signal.yield(true)
            }
        }
    }

    public func suspend() async {
        generation += 1
        watcher.stop()
        changes?.finish()
        changes = nil
        let previous = watchTask
        watchTask = nil
        let previousTimer = timer
        timer = nil
        previous?.cancel()
        previousTimer?.cancel()
        versions.removeAll()
        await previous?.value
        await previousTimer?.value
    }

    deinit {
        watcher.stop()
        changes?.finish()
        watchTask?.cancel()
        timer?.cancel()
        output.finish()
    }

    struct Sibling {
        let url: URL
        let peer: String
    }

    // Syncthing inserts the token before the final extension (or at the end
    // for extensionless files). Reject malformed lookalikes and never walk
    // outside the selected directory to reconstruct a canonical path.
    private static let naming = try! NSRegularExpression(
        pattern: #"^(.+)\.sync-conflict-([0-9]{8}-[0-9]{6})-([A-Za-z0-9-]+)(\.[^/]*)?$"#)

    static func parse(_ url: URL) -> (URL, Sibling)? {
        let name = url.lastPathComponent as NSString
        guard let match = Self.naming.firstMatch(in: name as String, range: NSRange(location: 0, length: name.length))
        else { return nil }
        var canonical = name.substring(with: match.range(at: 1))
        if match.range(at: 4).location != NSNotFound { canonical += name.substring(with: match.range(at: 4)) }
        guard canonical != ".", canonical != "..", !SyncArtifact.matches(canonical) else { return nil }
        return (url.deletingLastPathComponent().appendingPathComponent(canonical),
                Sibling(url: url, peer: name.substring(with: match.range(at: 3))))
    }

    private func scan(epoch: Int, signal: AsyncStream<Bool>.Continuation, retry: Bool, initial: Bool = false) async {
        guard generation == epoch else { return }
        var directories: Set<URL> = [root]
        var pending = [".vellum", "PDFs", "Web Pages"].map { root.appendingPathComponent($0, isDirectory: true) }
        var groups: [URL: [Sibling]] = [:]
        while let dir = pending.popLast() {
            directories.insert(dir)
            guard let entries = try? store.contents(of: dir) else { continue }
            for entry in entries {
                let name = entry.url.lastPathComponent
                if entry.isDirectory {
                    // Only the sidecar tree has managed trash, but every file
                    // type can have a sibling recovery directory.
                    let trash = root.appendingPathComponent(".vellum/trash", isDirectory: true)
                    if name != "conflicts", entry.url != trash, !SyncArtifact.matches(name) {
                        pending.append(entry.url)
                    }
                } else if name.contains(".sync-conflict-"), let (canonical, sibling) = Self.parse(entry.url) {
                    groups[canonical, default: []].append(sibling)
                }
            }
        }
        if resolving.isEmpty {
            if initial { _ = try? await webArchives.repair() }
            else { try? await webArchives.resumePending() }
        }
        watcher.update(directories: directories) { signal.yield(false) }
        var found: [URL: [ConflictVersion: URL]] = [:]
        for (canonical, siblings) in groups {
            do {
                var canonicalBytes = try await store.read(canonical)
                if canonicalBytes == nil, webArchives.handles(canonical) {
                    try await webArchives.restoreMissingCanonical(canonical, siblings: siblings.map(\.url))
                    canonicalBytes = try await store.read(canonical)
                }
                guard let current = canonicalBytes else { continue }
                var paths = [Self.version(at: canonical, bytes: current, peer: nil): canonical]
                for sibling in siblings {
                    guard let bytes = try await store.read(sibling.url) else { continue }
                    paths[Self.version(at: sibling.url, bytes: bytes, peer: sibling.peer)] = sibling.url
                }
                if paths.count > 1 { found[canonical] = paths }
            } catch { continue }
        }
        guard generation == epoch else { return }
        for (canonical, paths) in found where retry || versions[canonical] != paths {
            let ordered = paths.keys.sorted { lhs, rhs in
                if lhs.isCurrent != rhs.isCurrent { return lhs.isCurrent }
                return lhs.id < rhs.id
            }
            output.yield(ConflictEvent(url: canonical, detectedAt: .now, versions: ordered))
        }
        versions = found
    }

    private static func version(at url: URL, bytes: Data, peer: String?) -> ConflictVersion {
        let digest = DocumentIdentity.byteHash(bytes)
        let id = DocumentIdentity.sha256Hex(url.lastPathComponent + "/" + digest)
        return ConflictVersion(id: id, originatingDeviceName: peer, isCurrent: peer == nil)
    }

    public func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution {
        let epoch = generation
        guard let paths = versions[event.url], let current = event.currentVersion,
              Set(event.versions) == Set(paths.keys), resolving.insert(event.url).inserted
        else { return .deferred }
        defer { resolving.remove(event.url) }
        var snapshot: [ConflictVersion: Data] = [:]
        for (version, path) in paths {
            guard let data = try await store.read(path),
                  Self.version(at: path, bytes: data, peer: version.originatingDeviceName) == version
            else { return .deferred }
            snapshot[version] = data
        }
        let bytes = snapshot
        let read: PreserveLosersConflictResolver.Reader = { version in
            guard let data = bytes[version] else { throw LibraryFileError.retryable }
            return data
        }
        let decision: PreserveLosersConflictResolver.Decision
        if let typed = try await webArchives.decision(for: event, reading: read) {
            decision = typed
        } else {
            decision = try await merge(event, read)
        }
        // The merge is an injection point and may suspend for an arbitrary time.
        for (version, path) in paths {
            guard try await store.read(path) == bytes[version] else { return .deferred }
        }
        guard generation == epoch, let original = bytes[current] else { return .deferred }
        var winner = original
        do {
            let resolution = try await PreserveLosersConflictResolver.apply(
                decision, to: event, archiveOnMerge: true,
                replace: { merged in
                    guard merged != original else { return }
                    let backup = PreserveLosersConflictResolver.archiveURL(for: event.url, version: current)
                    if try await !store.replace(backup, with: original, ifCurrent: nil) {
                        guard try await store.read(backup) == original else { throw LibraryFileError.retryable }
                    }
                    guard generation == epoch,
                          try await store.replace(event.url, with: merged, ifCurrent: original)
                    else { throw LibraryFileError.retryable }
                    winner = merged
                }, preserve: { version in
                    guard generation == epoch, try await store.read(event.url) == winner,
                          let path = paths[version], let data = bytes[version],
                          let archive = try await store.archiveSibling(path, expected: data,
                              to: PreserveLosersConflictResolver.archiveURL(for: event.url, version: version))
                    else { throw LibraryFileError.retryable }
                    return archive
                })
            if webArchives.handles(event.url) {
                do {
                    if case .merged = resolution { try await webArchives.repair() }
                    else { try await webArchives.resumePending() }
                } catch LibraryFileError.retryable {
                    // The conflict itself is committed. Remaining placements
                    // are replayable on the next event, resume, or lookup.
                }
            }
            return resolution
        } catch LibraryFileError.retryable { return .deferred }
    }
}
