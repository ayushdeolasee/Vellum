import Foundation
import Glibc
import Testing
import VellumCore
@testable import LinuxReader

@Suite(.serialized)
struct ReadOnlyLibraryFileStoreTests {
    private let fm = FileManager.default

    private func withLibrary(_ body: (URL, ReadOnlyLibraryFileStore) async throws -> Void) async throws {
        let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = scratch.appendingPathComponent("library", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let root = try await RootDirectory.open(url)
        try await body(url, ReadOnlyLibraryFileStore(root: root))
    }

    @Test func listsAndReadsWithoutMutating() async throws {
        try await withLibrary { url, store in
            let positions = url.appendingPathComponent(".vellum/positions", isDirectory: true)
            try fm.createDirectory(at: positions, withIntermediateDirectories: true)
            let record = positions.appendingPathComponent("a b#%.json", isDirectory: false)
            let bytes = Data("{malformed".utf8)
            try bytes.write(to: record)
            let siblings = ["b.json", "notes.txt", ".hidden.json", "b.sync-conflict-1.json", ".syncthing.note.tmp"]
            for name in siblings { try bytes.write(to: positions.appendingPathComponent(name)) }

            let files: any LibraryFileStore = store
            #expect(!files.isCoordinated)
            let entries = try await files.list(positions, suffix: ".json")
            #expect(entries.map(\.name) == [record.lastPathComponent, "b.json"])
            let entry = try #require(entries.first)
            #expect(entry.url == record && entry.readiness.isReady)
            #expect(entry.byteSize == Int64(bytes.count) && entry.contentModifiedAt != nil)
            #expect(try await files.read(entry.url) == bytes)
            let missing = positions.appendingPathComponent("missing")
            #expect(try await files.read(missing) == nil)
            #expect(try await files.list(missing, suffix: nil).isEmpty)
            await #expect(throws: ReaderFileError.readOnly) { try await files.replace(record, with: Data()) }
            await #expect(throws: ReaderFileError.readOnly) { try await files.remove(record) }
            #expect(try fm.contentsOfDirectory(atPath: positions.path).sorted() == (siblings + [record.lastPathComponent]).sorted())
            #expect(try Data(contentsOf: record) == bytes)
        }
    }

    @Test func rejectsEscapesAndSpecialFiles() async throws {
        try await withLibrary { url, store in
            let sibling = url.deletingLastPathComponent().appendingPathComponent("library-other", isDirectory: true)
            try fm.createDirectory(at: sibling, withIntermediateDirectories: false)
            let outside = sibling.appendingPathComponent("out")
            try Data("private".utf8).write(to: outside)
            let link = url.appendingPathComponent("link")
            let directoryLink = url.appendingPathComponent("folder", isDirectory: true)
            try fm.createSymbolicLink(at: link, withDestinationURL: outside)
            try fm.createSymbolicLink(at: directoryLink, withDestinationURL: sibling)
            let fifo = url.appendingPathComponent("fifo")
            #expect(mkfifo(fifo.path, 0o600) == 0)

            await #expect(throws: LibraryFileError.outsideAllowedRoot(outside)) { try await store.read(outside) }
            await #expect(throws: LibraryFileError.outsideAllowedRoot(sibling)) { try await store.list(sibling, suffix: nil) }
            for path in ["./foo", "../library-other/out", "%2e%2e/out", "a%2Fb", "a%00b"] {
                let escaped = try #require(URL(string: url.absoluteString + path))
                await #expect(throws: LibraryFileError.outsideAllowedRoot(escaped)) { try await store.read(escaped) }
            }
            for refused in [link, directoryLink.appendingPathComponent("out"), fifo, url] {
                await #expect(throws: LibraryFileError.self) { try await store.read(refused) }
            }
            await #expect(throws: LibraryFileError.self) { try await store.list(directoryLink, suffix: nil) }
            await #expect(throws: LibraryFileError.self) { try await RootDirectory.open(directoryLink) }
            #expect(try await store.list(url, suffix: nil).isEmpty)
        }
    }

    @Test func readsAndEnumeratesTheOriginallyOpenedDirectory() async throws {
        try await withLibrary { url, store in
            let file = url.appendingPathComponent("original")
            let bytes = Data("original bytes".utf8)
            try bytes.write(to: file)
            let moved = url.deletingLastPathComponent().appendingPathComponent("moved")
            try fm.moveItem(at: url, to: moved)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            try Data("replacement".utf8).write(to: file)
            try Data().write(to: url.appendingPathComponent("other"))
            #expect(try await store.read(file) == bytes)
            for _ in 0..<2 {
                #expect(try await store.list(url, suffix: nil).map(\.name) == ["original"])
            }
        }
    }

    @Test func enforcesSizeBeforeAndDuringRead() async throws {
        try await withLibrary { url, store in
            // Sparse oversized fixtures exercise each policy without storing the payloads.
            for (name, limit) in [("a.JSON", 32 << 20), ("b.PDF", PdfiumDocument.maxInputBytes), ("c.vellumweb", 315 << 20)] {
                let file = url.appendingPathComponent(name)
                try Data().write(to: file)
                #expect(truncate(file.path, limit + 1) == 0)
                await #expect(throws: ReaderFileError.fileTooLarge) { try await store.read(file) }
            }
            let archive = url.appendingPathComponent("small.vellumweb")
            let archiveStore = ReadOnlyLibraryFileStore(root: store.root, maxArchiveBytes: 2)
            try Data([1, 2]).write(to: archive)
            #expect(try await archiveStore.read(archive) == Data([1, 2]))
            try Data([1, 2, 3]).write(to: archive)
            await #expect(throws: ReaderFileError.fileTooLarge) { try await archiveStore.read(archive) }
            #expect(throws: LibraryFileError.io(POSIXError(.EBADF).localizedDescription)) {
                try RootDirectory.readBytes(from: -1, byteLimit: 16)
            }
            let file = url.appendingPathComponent("changes")
            let bytes = Data(repeating: 42, count: 128 * 1024)
            try bytes.write(to: file)
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            #expect(try RootDirectory.readBytes(from: handle.fileDescriptor, byteLimit: bytes.count) == bytes)
            // Grow the same inode after observing its original size.
            try handle.seek(toOffset: 0)
            #expect(truncate(file.path, bytes.count + 1) == 0)
            #expect(throws: ReaderFileError.fileTooLarge) {
                try RootDirectory.readBytes(from: handle.fileDescriptor, byteLimit: bytes.count)
            }
        }
    }

    @Test func listsDirectChildrenThroughAliasedAncestor() async throws {
        try await withLibrary { url, _ in
            let parent = url.deletingLastPathComponent()
            let alias = parent.appendingPathComponent("home", isDirectory: true)
            try fm.createSymbolicLink(at: alias, withDestinationURL: parent)
            let selected = alias.appendingPathComponent("library", isDirectory: true)
            let pdfs = selected.appendingPathComponent("PDFs", isDirectory: true)
            let nested = pdfs.appendingPathComponent("2026", isDirectory: true)
            let web = selected.appendingPathComponent("Web Pages", isDirectory: true)
            let records = selected.appendingPathComponent(".vellum/records", isDirectory: true)
            for dir in [nested, web, records] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let pdf = nested.appendingPathComponent("notes.pdf", isDirectory: false)
            try Data([42]).write(to: pdf)
            try Data().write(to: web.appendingPathComponent("article.vellumweb"))
            try Data().write(to: records.appendingPathComponent("item.json"))

            let root = try await RootDirectory.open(selected)
            let store = ReadOnlyLibraryFileStore(root: root)
            let top = try await store.list(selected, suffix: nil)
            #expect(top.map(\.url) == [pdfs, web])
            #expect(top.allSatisfy { $0.url.hasDirectoryPath })
            #expect(try await store.list(pdfs, suffix: nil).map(\.url) == [nested])
            #expect(try await store.list(pdfs, suffix: ".pdf").isEmpty)
            #expect(try await store.list(nested, suffix: ".pdf").map(\.url) == [pdf])
            #expect(try await store.read(pdf) == Data([42]))
            #expect(try await store.list(records, suffix: ".json").map(\.name) == ["item.json"])
            #expect(try await store.list(web, suffix: ".vellumweb").map(\.name) == ["article.vellumweb"])
        }
    }

    @Test func slowWorkerAllowsIndependentReadsAndQueuedCancellation() async throws {
        try await withLibrary { url, store in
            let file = url.appendingPathComponent("record.json")
            try Data([42]).write(to: file)
            let (started, signal) = AsyncStream<Void>.makeStream()
            var starts = started.makeAsyncIterator()
            let release = DispatchSemaphore(value: 0)
            func occupyWorker() -> Task<Void, Error> {
                Task {
                    try await LibraryIO.run { checkCancellation in
                        #expect(OperationQueue.current === LibraryIO.queue)
                        signal.yield(())
                        // The deadline also prevents a scheduler regression from hanging the suite.
                        #expect(release.wait(timeout: .now() + 5) == .success)
                        try checkCancellation()
                    }
                }
            }
            let first = occupyWorker()
            _ = await starts.next()
            #expect(try await store.read(file) == Data([42]))
            let second = occupyWorker()
            _ = await starts.next()
            let queued = Task { try await store.read(file) }
            let deadline = ContinuousClock.now + .seconds(2)
            while LibraryIO.queue.operationCount < 3 && ContinuousClock.now < deadline {
                await Task.yield()
            }
            #expect(LibraryIO.queue.operationCount >= 3)
            queued.cancel()
            await #expect(throws: CancellationError.self) { try await queued.value }
            first.cancel()
            release.signal()
            release.signal()
            await #expect(throws: CancellationError.self) { try await first.value }
            try await second.value
            #expect(try await store.read(file) == Data([42]))
        }
    }
}
