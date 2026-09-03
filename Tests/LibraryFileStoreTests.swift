import Foundation
import Testing

@testable import Vellum

@Suite("Library file-store seam")
struct LibraryFileStoreTests {
    @Test("Direct storage round-trips atomically without leaving temporary files")
    func directRoundTrip() async throws {
        let root = PositionFixtures.scratchDirectory("library-file-store")
        defer { PositionFixtures.remove(root) }
        let target = root.appendingPathComponent("record.json")
        let store = DirectLibraryFileStore()

        #expect(try await store.read(target) == nil)
        try await store.replace(target, with: Data("one".utf8))
        try await store.replace(target, with: Data("two".utf8))

        #expect(try await store.read(target) == Data("two".utf8))
        #expect(try await store.list(root, suffix: ".json").map(\.name) == ["record.json"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["record.json"])
        try await store.remove(target)
        #expect(try await store.read(target) == nil)
    }

    @Test("Rooted direct storage rejects symlinks and paths outside its root")
    func rootedDirectStorageStaysInsideRoot() async throws {
        let root = PositionFixtures.scratchDirectory("rooted-file-store")
        let outside = PositionFixtures.scratchDirectory("outside-file-store")
        defer {
            PositionFixtures.remove(root)
            PositionFixtures.remove(outside)
        }
        let outsideFile = outside.appendingPathComponent("outside.json")
        let link = root.appendingPathComponent("linked.json")
        try Data("keep".utf8).write(to: outsideFile)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideFile)
        let store = DirectLibraryFileStore(allowedRoot: root)

        await #expect(throws: LibraryFileError.symbolicLink(link.standardizedFileURL)) {
            _ = try await store.list(root, suffix: nil)
        }
        await #expect(
            throws: LibraryFileError.outsideAllowedRoot(outsideFile.standardizedFileURL)
        ) {
            _ = try await store.read(outsideFile)
        }
        #expect(try Data(contentsOf: outsideFile) == Data("keep".utf8))
    }

    @Test("Coordinated storage uses metadata and coordinated primitives only")
    func coordinatedRoundTrip() async throws {
        let root = URL(fileURLWithPath: "/Vellum/.vellum/records", isDirectory: true)
        let target = root.appendingPathComponent("record.json")
        let container = FakeSyncedContainer()
        let store = CoordinatedLibraryFileStore(container: container)

        #expect(try await store.read(target) == nil)
        try await store.replace(target, with: Data("bytes".utf8))
        #expect(try await store.read(target) == Data("bytes".utf8))
        #expect(try await store.list(root, suffix: ".json").map(\.name) == ["record.json"])
        try await store.remove(target)

        #expect(container.coordinatedReadCount == 1)
        #expect(container.coordinatedWriteCount == 1)
        #expect(container.forReplacingWriteCount == 1)
        #expect(container.coordinatedRemoveCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    @Test("A stale coordinated item is refused rather than served")
    func staleItemIsRefused() async throws {
        let root = URL(fileURLWithPath: "/Vellum/.vellum/records", isDirectory: true)
        let target = root.appendingPathComponent("record.json")
        let container = FakeSyncedContainer()
        container.seed(target, data: Data("stale".utf8), readiness: .downloaded)
        let store = CoordinatedLibraryFileStore(container: container)

        await #expect(throws: LibraryFileError.notDownloaded(target, .downloaded)) {
            _ = try await store.read(target)
        }
        #expect(container.coordinatedReadCount == 0)
    }

    @Test("A cancelled coordinated write is retryable")
    func cancelledWriteIsRetryable() async {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/records/record.json")
        let container = FakeSyncedContainer()
        container.cancelNextWrite()
        let store = CoordinatedLibraryFileStore(container: container)

        await #expect(throws: LibraryFileError.retryable) {
            try await store.replace(target, with: Data("bytes".utf8))
        }
    }
}
