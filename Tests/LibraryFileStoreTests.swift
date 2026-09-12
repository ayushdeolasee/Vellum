import Foundation
import Testing

@testable import Vellum

@Suite("Library file-store seam", .serialized)
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

    @Test("Rooted storage requests hidden iCloud placeholders by logical name")
    func rootedStorageDiscoversICloudPlaceholder() async throws {
        let root = PositionFixtures.scratchDirectory("rooted-placeholder-store")
        defer { PositionFixtures.remove(root) }
        let logical = root.appendingPathComponent("evicted.json").standardizedFileURL
        let placeholder = WebICloud.placeholderURL(for: logical)
        try Data("placeholder".utf8).write(to: placeholder)
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".unrelated.json"))
        try Data("other".utf8).write(
            to: WebICloud.placeholderURL(
                for: root.appendingPathComponent("unrelated.txt")))
        let requests = MaterializationRequests()
        WebICloud.materializeOverride = { url in
            requests.record(url.standardizedFileURL)
            return false
        }
        defer { WebICloud.materializeOverride = nil }
        let store = DirectLibraryFileStore(allowedRoot: root)

        let pending = try await store.list(root, suffix: ".json")
        #expect(pending.map(\.name) == ["evicted.json"])
        #expect(pending.first?.url == logical)
        #expect(pending.first?.readiness == .notDownloaded)
        await #expect(throws: LibraryFileError.notDownloaded(logical, .notDownloaded)) {
            _ = try await store.read(logical)
        }
        #expect(requests.urls == [logical, logical])
        #expect(FileManager.default.fileExists(atPath: placeholder.path))

        let bytes = Data("current".utf8)
        try bytes.write(to: logical)
        let current = try await store.list(root, suffix: ".json")
        #expect(current.map(\.name) == ["evicted.json"])
        #expect(current.first?.readiness == .current)
        #expect(try await store.read(logical) == bytes)
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

private final class MaterializationRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URL] = []

    var urls: [URL] { lock.withLock { recorded } }

    func record(_ url: URL) {
        lock.withLock { recorded.append(url) }
    }
}
