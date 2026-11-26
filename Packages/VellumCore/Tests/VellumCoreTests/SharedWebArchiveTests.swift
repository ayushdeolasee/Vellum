import Foundation
import Testing
@testable import VellumCore

@Suite("Shared web archive placement")
struct SharedWebArchiveTests {
    struct Article {
        let key: String
        let bytes: Data

        init(_ id: String, title: String = "Paper") throws {
            let url = "https://example.org/" + id
            key = DocumentIdentity.sha256Hex(url)
            // Keep an opaque future member in a real ZIP. The page key comes
            // from the normalized url, independently of the canonical_url.
            let html = Data(id.utf8)
            var manifest = ArchiveManifest(format: ArchiveCodec.formatName, version: 1, url: url + "#fragment",
                canonicalUrl: "https://example.org/other", title: title, capturedAt: "2026-10-01T00:00:00Z",
                generator: "fixture", loadingPolicy: "snapshot-only", pageCount: 1, lastPage: nil,
                hashes: ManifestHashes(snapshotHtml: ArchiveCodec.sha256Hex(html), pageText: ArchiveCodec.sha256Hex(Data())),
                assets: [], assetsSkipped: 0)
            manifest.unknownFields["future"] = .object(["id": .string(id)])
            bytes = try MiniZip.write(entries: [
                .init(name: "manifest.json", data: JSONEncoder().encode(manifest), stored: false),
                .init(name: "snapshot/index.html", data: html, stored: false),
                .init(name: "future/blob", data: Data([0, 255]) + html, stored: true)
            ])
        }

        var index: WebArchiveIndexContents {
            var value = WebArchiveIndexContents()
            value.entries[key] = "Paper.vellumweb"
            value.unknownFields["future"] = .object([key: .null])
            return value
        }
    }

    private func fixture(_ body: (URL, LocalFolderFileStore, FolderSyncedContainer) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalFolderFileStore(root: root)
        let container = FolderSyncedContainer(root: root, store: store, watcher: FolderDirectoryWatcher())
        do { try await body(root, store, container) } catch { await container.suspend(); throw error }
        await container.suspend()
    }

    // Resume performs a synchronous discovery pass. A rescan gives us the
    // current event even if a preceding index merge changed its version ID.
    private func resolve(_ url: URL, on container: FolderSyncedContainer) async throws {
        await container.resume()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await event in container.conflicts where event.url == url {
                    if try await container.resolveConflict(event) != .deferred { return }
                }
                throw LibraryFileError.retryable
            }
            group.addTask {
                try await Task.sleep(for: .seconds(3))
                throw LibraryFileError.retryable
            }
            defer { group.cancelAll() }
            try await group.next()
        }
        await container.suspend()
    }

    @Test("ZIP and index conflicts converge with either peer current and either event first",
          arguments: [false, true], [false, true])
    func peers(reverse: Bool, indexFirst: Bool) async throws {
        let articles = try [Article("one"), Article("two")].sorted { $0.key < $1.key }
        let high = articles[1], low = articles[0]
        let current = reverse ? high : low, sibling = reverse ? low : high
        try await fixture { root, store, container in
            let page = root.appendingPathComponent("Web Pages/Paper.vellumweb")
            let idx = root.appendingPathComponent(".vellum/index.json")
            func conflict(_ path: URL) -> URL {
                path.deletingPathExtension().appendingPathExtension("sync-conflict-20261126-145959-PEER")
                    .appendingPathExtension(path.pathExtension)
            }
            try await store.replace(page, with: current.bytes)
            try await store.replace(conflict(page), with: sibling.bytes)
            try await store.replace(idx, with: current.index.encoded())
            try await store.replace(conflict(idx), with: sibling.index.encoded())
            for path in (indexFirst ? [idx, page] : [page, idx]) { try await resolve(path, on: container) }
            let expected = [low.key: "Paper.vellumweb", high.key: "Paper (\(high.key.prefix(6))).vellumweb"]
            let index = try WebArchiveIndexContents.checked(#require(await store.read(idx)))
            #expect(index.entries == expected)
            #expect(index.unknownFields["future"] == .object([low.key: .null, high.key: .null]))
            for article in articles {
                let found = try #require(await container.webArchives.lookup(forKey: article.key))
                #expect(found.name == expected[article.key])
                #expect(found.bytes == article.bytes)
            }
            #expect(try await store.read(conflict(page)) == nil)
            #expect(try await store.read(conflict(idx)) == nil)
        }
    }

    @Test("Names reserve natural titles and extend equal key prefixes across filesystem aliases")
    func allocation() async throws {
        try await fixture { root, store, container in
            let bare = try Article("bare-0", title: "Café")
            // These two normalized URLs have the SHA-256 prefix 88454c.
            let b = try Article("alias-572", title: "CAFE\u{301}")
            let c = try Article("alias-8676", title: "café")
            let natural = try Article("literal", title: "café (88454c)")
            let occupied = root.appendingPathComponent("Web Pages/CAFÉ (88454CB).vellumweb")
            let opaque = Data([255, 0])
            try await store.replace(occupied, with: opaque)
            for article in [c, b, natural, bare] {
                _ = try await container.webArchives.save(article.bytes, forKey: article.key)
            }
            for (article, name) in [(bare, "Café"), (b, "CAFÉ (88454cb8)"), (c, "café (88454cc)"),
                                    (natural, "café (88454c)")] {
                let found = try #require(await container.webArchives.lookup(forKey: article.key))
                #expect(found.name == name + ".vellumweb")
                #expect(found.bytes == article.bytes)
            }
            #expect(try await store.read(occupied) == opaque)
        }
    }

    @Test("Restart repairs staged bytes, wrong index owners and occupied names without following a symlink")
    func restart() async throws {
        try await fixture { root, store, container in
            let article = try Article("safe", title: "../Paper")
            let pageDir = root.appendingPathComponent("Web Pages", isDirectory: true)
            let index = root.appendingPathComponent(".vellum/index.json")
            let stage = root.appendingPathComponent(".vellum/archive-repair/staged.vellumweb")
            try await store.replace(stage, with: article.bytes)
            let opaque = Data("user file".utf8)
            try await store.replace(pageDir.appendingPathComponent("-Paper.vellumweb"), with: opaque)
            let link = pageDir.appendingPathComponent("-Paper (\(article.key.prefix(6))).vellumweb")
            let sentinel = root.appendingPathComponent("sentinel")
            try await store.replace(sentinel, with: opaque)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
            await container.resume()
            let found = try #require(await container.webArchives.lookup(forKey: article.key))
            #expect(found.name == "-Paper (\(article.key.prefix(7))).vellumweb")
            #expect(found.bytes == article.bytes)
            #expect(try await store.read(sentinel) == opaque)
            #expect(try await store.read(stage) == nil)
            // An unsafe foreign mapping is never interpreted as a path, even
            // if another file under the selected root has that name.
            var unsafe = article.index
            unsafe.entries[article.key] = "../sentinel.vellumweb"
            let bytes = try unsafe.encoded()
            try await store.replace(index, with: bytes)
            await #expect(throws: ArchiveCodecError.self) {
                try await container.webArchives.save(article.bytes, forKey: article.key)
            }
            #expect(try await store.read(index) == bytes)
        }
    }

    /// Interrupt immediately AFTER a successful filesystem operation, like a
    /// process that never receives the result. Restart uses an ordinary store.
    private final class InterruptedStore: FolderFileStore, @unchecked Sendable {
        let base: LocalFolderFileStore
        let isCoordinated = false
        private let lock = NSLock()
        private var remaining: Int
        init(_ base: LocalFolderFileStore, after writes: Int) { self.base = base; remaining = writes }
        private func written() throws {
            try lock.withLock {
                remaining -= 1
                if remaining == 0 { throw LibraryFileError.retryable }
            }
        }
        func contents(of dir: URL) throws -> [FolderEntry] { try base.contents(of: dir) }
        func occupiedNames(in dir: URL) throws -> [String] { try base.occupiedNames(in: dir) }
        func list(_ dir: URL, suffix: String?) async throws -> [LibraryFileEntry] { try await base.list(dir, suffix: suffix) }
        func read(_ url: URL) async throws -> Data? { try await base.read(url) }
        func remove(_ url: URL) async throws { try await base.remove(url); try written() }
        func replace(_ url: URL, with data: Data) async throws { try await base.replace(url, with: data); try written() }
        func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool {
            let changed = try await base.replace(url, with: data, ifCurrent: expected)
            if changed { try written() }
            return changed
        }
        func archiveSibling(_ source: URL, expected: Data, to dest: URL) async throws -> URL? {
            let moved = try await base.archiveSibling(source, expected: expected, to: dest)
            if moved != nil { try written() }
            return moved
        }
    }

    @Test("Restart completes a same-title save interrupted after each durable write", arguments: 1...5)
    func interruptedSave(after writes: Int) async throws {
        try await fixture { root, store, container in
            let sorted = try [Article("one"), Article("two")].sorted { $0.key < $1.key }
            let low = sorted[0], high = sorted[1]
            _ = try await container.webArchives.save(high.bytes, forKey: high.key)
            let interrupted = SharedWebArchives(root: root, store: InterruptedStore(store, after: writes))
            await #expect(throws: LibraryFileError.retryable) { try await interrupted.save(low.bytes, forKey: low.key) }
            await container.resume()
            let idx = root.appendingPathComponent(".vellum/index.json")
            let restored = try WebArchiveIndexContents.checked(#require(await store.read(idx)))
            #expect(restored.entries == [low.key: "Paper.vellumweb", high.key: "Paper (\(high.key.prefix(6))).vellumweb"])
            for article in sorted {
                #expect(try await container.webArchives.lookup(forKey: article.key)?.bytes == article.bytes)
            }
        }
    }

    @Test("An orphan ZIP sibling and an unreadable index conflict survive out-of-order arrival")
    func orphanAndMalformedIndex() async throws {
        try await fixture { root, store, container in
            let article = try Article("orphan")
            let page = root.appendingPathComponent("Web Pages/Paper.vellumweb")
            let sibling = root.appendingPathComponent("Web Pages/Paper.sync-conflict-20261126-145959-A.vellumweb")
            try await store.replace(sibling, with: article.bytes)
            try await resolve(page, on: container)
            #expect(try await store.read(page) == article.bytes)
            let idx = root.appendingPathComponent(".vellum/index.json")
            let bad = Data([0xff, 0])
            try await store.replace(root.appendingPathComponent(".vellum/index.sync-conflict-20261126-145959-A.json"), with: bad)
            try await resolve(idx, on: container)
            let backups = try store.contents(of: idx.deletingLastPathComponent().appendingPathComponent("conflicts"))
            #expect(try backups.contains { try Data(contentsOf: $0.url) == bad })
            #expect(try await container.webArchives.lookup(forKey: article.key)?.bytes == article.bytes)
        }
    }

    @Test("Offline saves and late index lookup use manifest ownership on disk")
    func saveAndLookup() async throws {
        try await fixture { root, store, container in
            let articles = try [Article("early"), Article("late")].sorted { $0.key > $1.key }
            let library = container.webArchives
            for article in articles { _ = try await library.save(article.bytes, forKey: article.key) }
            let high = articles[0], low = articles[1]
            #expect(try await library.lookup(forKey: low.key)?.name == "Paper.vellumweb")
            let idx = root.appendingPathComponent(".vellum/index.json")
            try await store.replace(idx, with: high.index.encoded())
            let repaired = try #require(await library.lookup(forKey: high.key))
            #expect(repaired.name == "Paper (\(high.key.prefix(6))).vellumweb")
            #expect(repaired.bytes == high.bytes)
            #expect(try await library.lookup(forKey: low.key)?.bytes == low.bytes)
        }
    }
}
