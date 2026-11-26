import Foundation
import LinuxReader
import Testing
import VellumCore

@Test func catalogMetadataFollowsTheOpenedRootAndPreservesItsBytes() async throws {
    let fm = FileManager.default
    let scratch = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fm.removeItem(at: scratch) }
    let original = scratch.appendingPathComponent("library", isDirectory: true)
    let moved = scratch.appendingPathComponent("moved", isDirectory: true)
    let article = "https://fixture.test/article"
    let web = DocumentKey.web(normalizedURL: article)
    let other = DocumentKey.web(normalizedURL: "https://fixture.test/other")
    let legacyURL = "https://fixture.test/legacy"
    let legacy = DocumentKey.web(normalizedURL: legacyURL)
    let stamp = "aaabcde0-1234-4000-a456-abcdef012345"
    let pdf = DocumentKey.pdf(stableIdentifier: stamp)
    let anchor = ReadingPosition(page: 4, pageCount: 11, scrollFraction: 0.42,
                                 anchorPrefix: "before", anchorSuffix: "after", viewportOffset: 18)
    func peer(_ device: String, _ seconds: Int, _ position: ReadingPosition, version: Int = 1) throws -> Data {
        let at = Date(timeIntervalSince1970: Double(seconds))
        let entry = PositionDeviceRecord.DocumentEntry(readingPosition: .init(at: at, value: position),
                                                      title: .init(at: at, value: "Peer title"))
        return try PositionCoding.encoder.encode(PositionDeviceRecord(
            schemaVersion: version, deviceID: DeviceID(device), deviceName: device, devicePlatform: "macos",
            writtenAt: at, documents: [web: entry, pdf: entry, .pdfPath("/outside/book.pdf"): entry]))
    }

    // A real archive without embedded ink. Its filename and canonical_url deliberately
    // disagree with the Apple storage identity, which derives from normalized url.
    let html = "<p>article</p>"
    let pages = Data("[]".utf8)
    let manifest = ArchiveManifest(
        format: "vellumweb", version: 1, url: "HTTPS://Fixture.Test/article?utm_source=test#part",
        canonicalUrl: "https://fixture.test/other", title: "Archive title", titleIsUserDefined: false,
        capturedAt: "2026-01-01T00:00:00Z", generator: "test", loadingPolicy: "snapshot-only",
        pageCount: 8, lastPage: 2, hashes: .init(snapshotHtml: ArchiveCodec.sha256Hex(Data(html.utf8)),
                                                pageText: ArchiveCodec.sha256Hex(pages)),
        assets: [], assetsSkipped: 0)
    let archive = try ArchiveCodec.encode(manifest: manifest, snapshotHtml: html, assets: [],
                                         pagesJson: pages, annotations: [])
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let ink = try Data(contentsOf: repo.appendingPathComponent(
        "Packages/VellumCore/Tests/VellumCoreTests/Fixtures/Web/web-ink-v3.ink.json"))
    let records = ".vellum/records/"
    let positions = ".vellum/positions/"
    let archivePath = "Web Pages/Unrelated name.vellumweb"
    let corrupt = Data([0xff, 0x01])
    let rejected = try peer("impostor", 99, .init(page: 7))
    let files: [String: Data] = [
        archivePath: archive,
        records + web.hash + ".json": Data("""
            {"url":"\(article)","title":"My 東京 title","last_page":3,"page_count":7}
            """.utf8),
        records + web.hash + ".ink.json": ink,
        records + legacy.hash + ".json": Data("""
            {"url":"\(legacyURL)","title":"Saved title","title_is_user_defined":false,"last_page":3}
            """.utf8),
        records + other.hash + ".sync-conflict-copy.ink.json": ink,
        records + other.hash.uppercased() + ".ink.json": ink,
        records + other.hash + ".json": Data("""
            {"url":"\(article)","title":"Wrong record","last_page":7,"last_known_path":"/outside/book.pdf"}
            """.utf8),
        positions + "mac.v1.json": try peer("mac", 10, .init(page: 1)),
        positions + "ipad.v1.json": try peer("ipad", 20, anchor),
        positions + "newer.v1.json": try peer("newer", 30, .init(page: 8), version: 2),
        positions + "future.v2.json": try peer("future", 40, .init(page: 9), version: 2),
        positions + "wrong.v1.json": rejected,
        positions + "bad.v1.json": corrupt,
        positions + "invalid-page.v1.json": try peer("invalid-page", 50, .init(page: Int.max)),
        positions + "impostor.sync-conflict-copy.v1.json": rejected
    ]
    for (relative, data) in files {
        let path = original.appendingPathComponent(relative, isDirectory: false)
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: path)
    }
    let store = ReadOnlyLibraryFileStore(root: try await RootDirectory.open(original))
    try fm.moveItem(at: original, to: moved)
    // A path-based reopen would now see a different peer and miss the sidecar.
    try fm.createDirectory(at: original.appendingPathComponent(positions), withIntermediateDirectories: true)
    try peer("decoy", 100, .init(page: 10)).write(to: original.appendingPathComponent(positions + "decoy.v1.json"))

    let catalog = try await ReaderMetadataCatalog.load(in: store)
    let bytes = try #require(try await store.read(original.appendingPathComponent(archivePath)))
    let decoded = try ArchiveCodec.decode(bytes)
    #expect(decoded.inkJSON == nil)
    let selected = try await catalog.web(manifest: decoded.manifest, fallbackTitle: "Filename")
    #expect(selected.displayTitle == "My 東京 title")
    #expect(selected.position == anchor && selected.lastPage == 4 && selected.hasInkSidecar)
    let knownPDF = catalog.pdf(stableIdentifier: stamp, fallbackTitle: "book.pdf")
    #expect(knownPDF.position == anchor && knownPDF.displayTitle == "Peer title" && !knownPDF.hasInkSidecar)
    for id in [nil, "/outside/book.pdf", "ffffffff"] as [String?] {
        let unknown = catalog.pdf(stableIdentifier: id, fallbackTitle: "book.pdf")
        #expect(unknown.position == nil && unknown.displayTitle == "book.pdf" && !unknown.hasInkSidecar)
    }

    var otherManifest = decoded.manifest
    otherManifest.url = "https://fixture.test/other"
    let unmatched = try await catalog.web(manifest: otherManifest, fallbackTitle: "Filename")
    #expect(!unmatched.hasInkSidecar && unmatched.displayTitle == "Archive title")
    #expect(unmatched.position == ReadingPosition(page: 2, pageCount: 8))

    otherManifest.url = legacyURL
    let saved = try await catalog.web(manifest: otherManifest, fallbackTitle: "Filename")
    #expect(saved.displayTitle == "Saved title" && saved.position == ReadingPosition(page: 3))
    otherManifest.titleIsUserDefined = nil
    let protected = try await catalog.web(manifest: otherManifest, fallbackTitle: "Filename")
    #expect(protected.displayTitle == "Archive title")
    otherManifest.url = "file:///outside/book.pdf"
    otherManifest.lastPage = nil
    otherManifest.title = nil
    let unkeyed = try await catalog.web(manifest: otherManifest, fallbackTitle: "Filename")
    #expect(unkeyed.position == nil && unkeyed.displayTitle == "Filename" && !unkeyed.hasInkSidecar)

    let actual = try fm.subpathsOfDirectory(atPath: moved.path)
    let directories = [".vellum", ".vellum/records", ".vellum/positions", "Web Pages"]
    #expect(Set(actual) == Set(files.keys).union(directories))
    for (relative, bytes) in files {
        #expect(try Data(contentsOf: moved.appendingPathComponent(relative)) == bytes)
    }
}
