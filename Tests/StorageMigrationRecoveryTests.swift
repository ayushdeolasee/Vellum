import Foundation
import PencilKit
import Testing

@testable import Vellum

@Suite("Storage migration recovery", .isolatedStorage, .serialized)
struct StorageMigrationRecoveryTests {
    private let url = "https://example.com/recovered"

    private func fixture() throws -> (URL, WebStorageLayout, WebStorageLayout, FakeSyncedContainer) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-migration-recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let local = root.appendingPathComponent("local/web")
        return (root,
                .pretty(root: root.appendingPathComponent("custom"), recordsInRoot: false, localStoreDir: local),
                .pretty(root: root.appendingPathComponent("cloud"), recordsInRoot: true, localStoreDir: local),
                FakeSyncedContainer())
    }

    private func archive() throws -> (Data, WebInkRecord) {
        let points = (0..<3).map {
            PKStrokePoint(location: CGPoint(x: 10 + $0 * 10, y: 20),
                          timeOffset: Double($0) * 0.01, size: CGSize(width: 3, height: 3),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        let ink = WebInkRecord.snapshot(
            of: PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: path)]),
            url: url, layout: .init(contentWidth: 980, docHeight: 1000))
        let annotations = [Annotation(
            id: "recovered-highlight", type: .highlight, pageNumber: 1, color: "#fde68a",
            content: "kept", positionData: nil,
            createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z")]
        let html = "<html><body>Recovery fixture</body></html>"
        let pages = try WebArchive.encodePagesJson([WebPageText(number: 1, text: "Recovery fixture")])
        var manifest = WebArchive.buildManifest(
            url: url, title: "Recovered Page", pageCount: 3, lastPage: 2,
            loadingPolicy: "snapshot-only", snapshotHtml: html, pagesJson: pages,
            assets: [], assetsSkipped: 0)
        manifest.titleIsUserDefined = true
        return (try WebArchive.encodeArchive(
            manifest: manifest, snapshotHtml: html, assets: [], pagesJson: pages,
            annotations: annotations, inkJson: WebLibrary.jsonEncoderPretty.encode(ink)), ink)
    }

    @Test("Unindexed archives recover their saved state, highlights and ink", arguments: [false, true])
    func recoverArchive(coordinated: Bool) async throws {
        let (root, source, cloud, container) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = coordinated ? cloud : WebStorageLayout.local(storeDir: source.recordsDir)
        let direct = DirectLibraryFileStore()
        let target: any LibraryFileStore = coordinated
            ? CoordinatedLibraryFileStore(container: container) : direct
        let (bytes, ink) = try archive()
        let sourceURL = source.archivesDir.appendingPathComponent("Unindexed.vellumweb")
        try await direct.replace(sourceURL, with: bytes)
        let key = WebLibrary.pageKey(url)
        let note = destination.documentsDir.appendingPathComponent("\(key)/scratchpad.md")
        try await direct.replace(
            source.documentsDir.appendingPathComponent("\(key)/scratchpad.md"), with: Data("note".utf8))

        #expect(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct, destinationStore: target))
        #expect(try await direct.read(sourceURL) == nil)
        let recordData = try #require(try await target.read(
            destination.recordsDir.appendingPathComponent("\(key).json")))
        let record = try JSONDecoder().decode(WebPageRecord.self, from: recordData)
        #expect(record.saved)
        #expect(record.savedAt != nil)
        #expect(record.title == "Recovered Page")
        #expect(record.titleIsUserDefined)
        #expect(record.lastPage == 2)
        #expect(record.pageCount == 3)
        #expect(record.loadingPolicy == "snapshot-only")
        #expect(record.annotations.map(\.id) == ["recovered-highlight"])
        let inkData = try #require(try await target.read(
            destination.recordsDir.appendingPathComponent("\(key).ink.json")))
        #expect(try JSONDecoder().decode(WebInkRecord.self, from: inkData) == ink)
        #expect(try await target.read(note) == Data("note".utf8))
        let name: String
        if let indexPath = destination.indexPath {
            let data = try #require(try await target.read(indexPath))
            name = try #require(JSONDecoder().decode(WebArchiveIndex.Contents.self, from: data).entries[key])
        } else {
            name = "\(key).vellumweb"
        }
        #expect(try await target.read(destination.archivesDir.appendingPathComponent(name)) == bytes)
        #expect(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct, destinationStore: target))
    }

    @Test("Index recovery keeps existing unsaved and erased annotation state authoritative")
    func preserveExistingSidecars() async throws {
        let (root, source, destination, container) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = DirectLibraryFileStore()
        let target = CoordinatedLibraryFileStore(container: container)
        let key = WebLibrary.pageKey(url)
        let (bytes, _) = try archive()
        try await direct.replace(source.archivesDir.appendingPathComponent("Unindexed.vellumweb"), with: bytes)
        var record = WebPageRecord(url: url)
        record.title = "Current Title"
        record.lastPage = 1
        let recordData = try WebLibrary.jsonEncoderPretty.encode(record)
        try await direct.replace(source.recordsDir.appendingPathComponent("\(key).json"), with: recordData)
        let erasedInk = WebInkRecord.snapshot(
            of: PKDrawing(), url: url, layout: .init(contentWidth: 980, docHeight: 1000))
        let inkData = try WebLibrary.jsonEncoderPretty.encode(erasedInk)
        try await direct.replace(source.recordsDir.appendingPathComponent("\(key).ink.json"), with: inkData)

        #expect(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct, destinationStore: target))
        #expect(try await target.read(destination.recordsDir.appendingPathComponent("\(key).json")) == recordData)
        #expect(try await target.read(destination.recordsDir.appendingPathComponent("\(key).ink.json")) == inkData)
    }

    @Test("Corrupt, ambiguous and evicted archives remain at the source", arguments: ["corrupt", "duplicate", "evicted"])
    func preserveUnrecoverableArchives(kind: String) async throws {
        let (root, source, destination, container) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = DirectLibraryFileStore()
        let sourceURL = source.archivesDir.appendingPathComponent("Unindexed.vellumweb")
        var bytes = try archive().0
        if kind == "corrupt" {
            // Keep a readable manifest but violate the snapshot hash. Merely
            // parsing the manifest must never authorize destructive recovery.
            let zip = try MiniZip(data: bytes, maxBytes: WebArchive.maxArchiveBytes,
                                  maxEntries: WebArchive.maxEntries,
                                  maxUncompressedBytes: WebArchive.maxTotalUncompressedBytes)
            bytes = try MiniZip.write(entries: zip.entryNames.map {
                MiniZip.Entry(name: $0,
                              data: $0 == "snapshot/index.html" ? Data("corrupt snapshot".utf8)
                                : try zip.readCapped($0, cap: WebArchive.maxTotalUncompressedBytes),
                              stored: false)
            })
        }
        let fileURL = kind == "evicted" ? WebICloud.placeholderURL(for: sourceURL) : sourceURL
        try await direct.replace(fileURL, with: bytes)
        if kind == "duplicate" {
            try await direct.replace(source.archivesDir.appendingPathComponent("Duplicate.vellumweb"), with: bytes)
        }
        #expect(!(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct,
            destinationStore: CoordinatedLibraryFileStore(container: container))))
        #expect(try await direct.read(fileURL) == bytes)
        #expect(container.peek(destination.recordsDir.appendingPathComponent("\(WebLibrary.pageKey(url)).json")) == nil)
        #expect(container.peek(try #require(destination.indexPath)) == nil)
    }

    @Test("Destination conflicts preserve both archive versions")
    func preserveDestinationConflict() async throws {
        let (root, source, destination, container) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = DirectLibraryFileStore()
        let (bytes, _) = try archive()
        let sourceURL = source.archivesDir.appendingPathComponent("Unindexed.vellumweb")
        try await direct.replace(sourceURL, with: bytes)
        let key = WebLibrary.pageKey(url)
        var index = WebArchiveIndex.Contents()
        index.entries[key] = "Existing.vellumweb"
        container.seed(try #require(destination.indexPath), data: try WebLibrary.jsonEncoderPretty.encode(index))
        let destinationURL = destination.archivesDir.appendingPathComponent("Existing.vellumweb")
        let existing = Data("different capture".utf8)
        container.seed(destinationURL, data: existing)
        #expect(!(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct,
            destinationStore: CoordinatedLibraryFileStore(container: container))))
        #expect(try await direct.read(sourceURL) == bytes)
        #expect(container.peek(destinationURL) == existing)
        #expect(container.peek(destination.recordsDir.appendingPathComponent("\(key).json")) == nil)
        #expect(container.peek(destination.recordsDir.appendingPathComponent("\(key).ink.json")) == nil)
    }

    @Test("Failed recovery writes leave the source intact and the next attempt succeeds")
    func retryFailedWrite() async throws {
        let (root, source, destination, container) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let direct = DirectLibraryFileStore()
        let target = CoordinatedLibraryFileStore(container: container)
        let (bytes, _) = try archive()
        let sourceURL = source.archivesDir.appendingPathComponent("Unindexed.vellumweb")
        try await direct.replace(sourceURL, with: bytes)
        container.failNextWrite(with: .io("fixture failure"))
        #expect(!(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct, destinationStore: target)))
        #expect(try await direct.read(sourceURL) == bytes)
        #expect(await WebStorageMigrator.relocate(
            from: source, to: destination, sourceStore: direct, destinationStore: target))
        #expect(try await direct.read(sourceURL) == nil)
    }
}
