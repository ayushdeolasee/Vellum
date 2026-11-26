import Foundation

/// The ZIP manifest identifies a page; the index can arrive before or after
/// its ZIP. All reads and mutations use the selected folder's checked store.
public actor SharedWebArchives {
    private let store: any FolderFileStore
    private let pages: URL
    private let index: URL
    private let pending: URL
    private var repairing = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(root: URL, store: any FolderFileStore) {
        self.store = store
        pages = root.appendingPathComponent("Web Pages", isDirectory: true)
        let metadata = root.appendingPathComponent(".vellum", isDirectory: true)
        index = metadata.appendingPathComponent("index.json")
        pending = metadata.appendingPathComponent("archive-repair", isDirectory: true)
    }

    private struct Copy {
        var path: URL
        let key: String
        let base: String
        let digest: String

        init(path: URL, bytes: Data) throws {
            let manifest = try ArchiveCodec.readManifest(data: bytes)
            let url = try WebURLNormalizer.normalize(manifest.url, httpsOnly: false)
            self.path = path
            key = DocumentIdentity.sha256Hex(url)
            base = WebArchiveNaming.base(title: manifest.title, url: url)
            digest = DocumentIdentity.byteHash(bytes)
        }
    }

    nonisolated func handles(_ url: URL) -> Bool {
        url == index || (url.deletingLastPathComponent() == pages && WebArchiveNaming.validLeaf(url.lastPathComponent))
    }

    /// The sibling can land before the canonical file. Seed an absent path
    /// without consuming the only copy, then let S5b resolve its exact bytes.
    func restoreMissingCanonical(_ path: URL, siblings: [URL]) async throws {
        guard handles(path) else { return }
        for url in siblings {
            guard let data = try await store.read(url) else { continue }
            if path == index {
                guard (try? WebArchiveIndexContents.checked(data)) != nil else { continue }
            } else if (try? Copy(path: path, bytes: data)) == nil { continue }
            _ = try await store.replace(path, with: data, ifCurrent: nil)
            return
        }
    }

    func decision(for event: ConflictEvent, reading: PreserveLosersConflictResolver.Reader) async throws
        -> PreserveLosersConflictResolver.Decision? {
        guard handles(event.url) else { return nil }
        if event.url == index {
            var inputs: [WebArchiveIndexContents] = []
            for version in event.versions {
                let data = try await reading(version)
                guard let value = try? WebArchiveIndexContents.checked(data) else { return .preserve }
                inputs.append(value)
            }
            return .merged(try WebArchiveIndexContents.merge(inputs).encoded())
        }
        // Journal before S5b can retire any sibling. Even if the current
        // version is unreadable, a valid losing ZIP can still become visible.
        var winner: Copy?
        var winnerBytes: Data?
        var hasOpaqueVersion = false
        for version in event.versions {
            let bytes = try await reading(version)
            guard let copy = try? Copy(path: event.url, bytes: bytes) else { hasOpaqueVersion = true; continue }
            let stage = pending.appendingPathComponent(copy.digest + WebArchiveNaming.ext)
            try await install(bytes, at: stage)
            if winner.map({ (copy.key, copy.digest) < ($0.key, $0.digest) }) ?? true {
                winner = copy
                winnerBytes = bytes
            }
        }
        if !hasOpaqueVersion, let winnerBytes { return .merged(winnerBytes) }
        return .preserve
    }

    private func install(_ bytes: Data, at path: URL) async throws {
        if try await store.replace(path, with: bytes, ifCurrent: nil) { return }
        guard try await store.read(path) == bytes else { throw LibraryFileError.retryable }
    }

    private func checkedBytes(_ copy: Copy) async throws -> Data {
        guard let bytes = try await store.read(copy.path), DocumentIdentity.byteHash(bytes) == copy.digest
        else { throw LibraryFileError.retryable }
        return bytes
    }

    private func readIndex() async throws -> (WebArchiveIndexContents, Data?) {
        let bytes = try await store.read(index)
        return (try bytes.map(WebArchiveIndexContents.checked) ?? WebArchiveIndexContents(), bytes)
    }

    private func unresolvedPaths(in directory: URL) throws -> Set<URL> {
        Set(try store.contents(of: directory).compactMap { file in
            guard !file.isDirectory else { return nil }
            return FolderSyncedContainer.parse(file.url)?.0
        })
    }

    private func commit(_ value: WebArchiveIndexContents, replacing previous: Data?) async throws {
        guard try !unresolvedPaths(in: index.deletingLastPathComponent()).contains(index)
        else { throw LibraryFileError.retryable }
        let encoded = try value.encoded()
        guard try await store.replace(index, with: encoded, ifCurrent: previous) else {
            throw LibraryFileError.retryable
        }
    }

    /// Complete an interrupted move even when the conflict that started it
    /// has already been resolved. Invalid/corrupt files still occupy names.
    func resumePending() async throws {
        if try !store.contents(of: pending).isEmpty { _ = try await repair() }
    }

    /// A filename is safe to expose only after verifying the bytes at that
    /// name. This also handles a sync write between index lookup and ZIP read.
    public func lookup(forKey key: String) async throws -> (name: String, bytes: Data)? {
        guard WebArchiveNaming.validKey(key) else { throw LibraryFileError.unavailable }
        let (current, _) = try await readIndex()
        if let name = current.entries[key], try store.contents(of: pending).isEmpty,
           let bytes = try await matchingBytes(key, name: name) { return (name, bytes) }
        guard let name = try await repair().entries[key],
              let bytes = try await matchingBytes(key, name: name) else { return nil }
        return (name, bytes)
    }

    private func matchingBytes(_ key: String, name: String) async throws -> Data? {
        let path = pages.appendingPathComponent(name)
        // Do not open a directory, symlink, FIFO or oversized file named by an index.
        guard try await archiveFiles(in: pages).contains(where: { $0.name.utf8.elementsEqual(name.utf8) }),
              let data = try await store.read(path),
              let manifest = try? ArchiveCodec.readManifest(data: data),
              let url = try? WebURLNormalizer.normalize(manifest.url, httpsOnly: false),
              DocumentIdentity.sha256Hex(url) == key else { return nil }
        return data
    }

    public func reserve(forKey key: String, title: String?, url: String) async throws -> String {
        guard WebArchiveNaming.validKey(key) else { throw LibraryFileError.unavailable }
        let reserved = try await repair(reserving: (key, WebArchiveNaming.base(title: title, url: url)))
        guard let name = reserved.entries[key] else { throw LibraryFileError.retryable }
        return name
    }

    public func save(_ data: Data, forKey key: String) async throws -> URL {
        let incoming = try Copy(path: pages, bytes: data)
        guard incoming.key == key else { throw ArchiveCodecError.invalidDocument("Archive URL does not match page key") }
        if let existing = try await lookup(forKey: key) {
            let path = pages.appendingPathComponent(existing.name)
            guard try !unresolvedPaths(in: pages).contains(path) else { throw LibraryFileError.retryable }
            let prior = try Copy(path: path, bytes: existing.bytes)
            guard try await store.replace(path, with: data, ifCurrent: existing.bytes) else {
                throw LibraryFileError.retryable
            }
            if prior.base == incoming.base { return path }
        } else {
            // A successful journal write makes even the first capture replayable
            // if the app stops before either the pretty ZIP or the index exists.
            try await install(data, at: pending.appendingPathComponent(incoming.digest + WebArchiveNaming.ext))
        }
        let repaired = try await repair()
        guard let name = repaired.entries[key], try await matchingBytes(key, name: name) == data else {
            throw LibraryFileError.retryable
        }
        return pages.appendingPathComponent(name)
    }

    public func remove(forKey key: String) async throws {
        _ = try await repair()
        let (contents, original) = try await readIndex()
        guard let name = contents.entries[key] else { return }
        if let data = try await matchingBytes(key, name: name) {
            let path = pages.appendingPathComponent(name)
            guard try !unresolvedPaths(in: pages).contains(path),
                  try await store.archiveSibling(path, expected: data, to: backup(DocumentIdentity.byteHash(data))) != nil
            else { throw LibraryFileError.retryable }
        }
        var updated = contents
        updated.entries.removeValue(forKey: key)
        try await commit(updated, replacing: original)
    }

    private func backup(_ digest: String) -> URL {
        pages.appendingPathComponent("conflicts", isDirectory: true).appendingPathComponent(digest + WebArchiveNaming.ext)
    }

    private func archiveFiles(in directory: URL) async throws -> [LibraryFileEntry] {
        let regular = try store.contents(of: directory).filter { !$0.isDirectory }
        let names = Set(regular.map { Data($0.url.lastPathComponent.utf8) })
        return try await store.list(directory, suffix: nil).filter {
            WebArchiveNaming.validLeaf($0.name) && names.contains(Data($0.name.utf8))
                && ($0.byteSize ?? 0) <= ArchiveCodec.maxArchiveBytes
        }
    }

    @discardableResult
    func repair(reserving claim: (key: String, base: String)? = nil) async throws -> WebArchiveIndexContents {
        // Actor methods reenter at every store call. Only one repair may
        // enumerate, move and retire these journal entries at a time.
        if repairing { await withCheckedContinuation { waiters.append($0) } }
        repairing = true
        defer {
            if waiters.isEmpty { repairing = false } else { waiters.removeFirst().resume() }
        }
        let (original, indexBytes) = try await readIndex()
        var copies: [Copy] = []
        let unresolved = try unresolvedPaths(in: pages)
        var occupied = Set(try store.occupiedNames(in: pages).map { Data($0.utf8) })
        for dir in [pages, pending] {
            for file in try await archiveFiles(in: dir) {
                guard let bytes = try await store.read(file.url) else { throw LibraryFileError.retryable }
                guard let copy = try? Copy(path: file.url, bytes: bytes) else { continue }
                copies.append(copy)
                if dir == pages { occupied.remove(Data(file.name.utf8)) }
            }
        }
        // Keep just the metadata in memory between reads. Distinct captures
        // of one identity use a stable live version; the rest go to conflicts.
        var selected: [String: Int] = [:]
        for (i, copy) in copies.enumerated() {
            if let previous = selected[copy.key], copies[previous].digest <= copy.digest { continue }
            selected[copy.key] = i
        }
        var bases = original.entries.mapValues { String($0.dropLast(WebArchiveNaming.ext.count)) }
        for (key, i) in selected { bases[key] = copies[i].base }
        if let claim { bases[claim.key] = claim.base }
        var updated = original
        updated.entries = WebArchiveNaming.names(bases: bases, occupied: occupied.map { String(decoding: $0, as: UTF8.self) })

        // Evacuate misplaced inodes FIRST, including case-only renames and
        // cycles. A crash leaves them enumerable in archive-repair on restart.
        for i in copies.indices {
            let copy = copies[i]
            guard copy.path.deletingLastPathComponent() == pages else { continue }
            let name = updated.entries[copy.key]!
            if copy.path.lastPathComponent.utf8.elementsEqual(name.utf8),
               copy.digest == copies[selected[copy.key]!].digest { continue }
            // Leave the current version present until S5b has journaled all
            // siblings. An unrelated or malformed sibling cannot block a save.
            guard !unresolved.contains(copy.path) else { throw LibraryFileError.retryable }
            let stage = pending.appendingPathComponent(copy.digest + WebArchiveNaming.ext)
            guard let moved = try await store.archiveSibling(copy.path, expected: checkedBytes(copy), to: stage)
            else { throw LibraryFileError.retryable }
            copies[i].path = moved
        }

        let visible = Set(copies.filter { $0.path.deletingLastPathComponent() == pages }.map(\.digest))
        for (key, i) in selected {
            let copy = copies[i]
            guard !visible.contains(copy.digest) else { continue }
            let target = pages.appendingPathComponent(updated.entries[key]!)
            // Publish by exclusive move. An archiveSibling collision saves
            // the inode under another name; rescan it on the next attempt.
            guard let moved = try await store.archiveSibling(copy.path, expected: checkedBytes(copy), to: target),
                  moved == target else { throw LibraryFileError.retryable }
            copies[i].path = moved
        }
        if updated != original { try await commit(updated, replacing: indexBytes) }

        // Remaining journal files are duplicate or divergent versions of a
        // published page. Preserve them after the index has committed.
        for copy in copies where copy.path.deletingLastPathComponent() == pending {
            guard try await store.archiveSibling(copy.path, expected: checkedBytes(copy), to: backup(copy.digest)) != nil
            else { throw LibraryFileError.retryable }
        }
        return updated
    }
}
