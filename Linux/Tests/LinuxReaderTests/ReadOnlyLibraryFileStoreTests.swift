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
            let conflict = "b.sync-conflict-20261126-174000-ABCDEFG.json"
            let siblings = [
                "b.json", "notes.txt", "notes.tmp-draft.pdf", ".hidden.json", conflict,
                ".syncthing.note.tmp", ".b.json.tmp-123-abc", ".notes.pdf.vellum-abc.tmp", "b.json.tmp",
            ]
            for name in siblings { try bytes.write(to: positions.appendingPathComponent(name)) }

            let files: any LibraryFileStore = store
            #expect(!files.isCoordinated)
            let entries = try await files.list(positions, suffix: ".json")
            #expect(entries.map(\.name) == [record.lastPathComponent, "b.json"])
            #expect(try await files.list(positions, suffix: nil).map(\.name) ==
                [record.lastPathComponent, "b.json", "notes.tmp-draft.pdf", "notes.txt"])
            let entry = try #require(entries.first)
            #expect(entry.url == record && entry.readiness.isReady)
            #expect(entry.byteSize == Int64(bytes.count) && entry.contentModifiedAt != nil)
            #expect(try await files.read(entry.url) == bytes)
            #expect(try await files.read(positions.appendingPathComponent(conflict)) == bytes)
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
            for (name, limitMiB) in [("a.JSON", 32), ("b.PDF", 250), ("c.vellumweb", 315)] {
                let file = url.appendingPathComponent(name)
                try Data().write(to: file)
                #expect(truncate(file.path, (limitMiB << 20) + 1) == 0)
                await #expect(throws: ReaderFileError.fileTooLarge) { try await store.read(file) }
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
}
