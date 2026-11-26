import Foundation
import XCTest
@testable import Vellum

final class ArchiveExchangeTests: XCTestCase {
    private func linuxExport() throws -> ImportedArchive {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "harbor-linux", withExtension: "vellumweb"))
        return try WebArchive.readArchive(at: url)
    }

    // Linux added a highlight to the package's pre-extraction Apple fixture.
    func testHostedImporterOpensLinuxExportWithAnchoredPencilStroke() throws {
        let archive = try linuxExport()
        XCTAssertEqual(archive.manifest.title, "Exchange 東京")
        XCTAssertTrue(archive.snapshotHtml.contains("Harbor café 東京"))
        XCTAssertEqual(archive.assets.map(\.0), ["sample.png"])
        XCTAssertEqual(archive.annotations.count, 1)
        let note = try XCTUnwrap(archive.annotations.first)
        XCTAssertEqual(note.id, "harbor-note")
        XCTAssertEqual(note.type, .highlight)
        XCTAssertEqual(note.pageNumber, 1)
        XCTAssertEqual(note.content, "Arrivée au port 東京")
        XCTAssertEqual(note.positionData?.selectedText, "Harbor café 東京")
        XCTAssertEqual(note.positionData?.startOffset, 0)
        XCTAssertEqual(note.positionData?.endOffset, 14)
        let ink = try XCTUnwrap(archive.inkRecord)
        XCTAssertEqual(try ink.validatedMergedDrawing().strokes.count, 1)
        XCTAssertEqual(ink.clusters.first?.anchor?.text, "Harbor café 東京")
    }

    func testImporterRejectsHashValidDamagedDrawing() throws {
        var ink = try XCTUnwrap(linuxExport().inkRecord)
        ink.clusters[0].drawing = Data("damaged drawing".utf8)
        let html = "<p>Ink</p>"
        let pages = try WebArchive.encodePagesJson([WebPageText(number: 1, text: "Ink")])
        let manifest = WebArchive.buildManifest(
            url: ink.url, title: nil, pageCount: 1, lastPage: 1, loadingPolicy: "snapshot-only",
            snapshotHtml: html, pagesJson: pages, assets: [], assetsSkipped: 0)
        let bytes = try WebArchive.encodeArchive(
            manifest: manifest, snapshotHtml: html, assets: [], pagesJson: pages, annotations: [],
            inkJson: WebLibrary.jsonEncoderPretty.encode(ink))
        XCTAssertThrowsError(try WebArchive.readArchive(data: bytes)) { error in
            guard case SessionServiceError.invalidDocument(let detail) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertTrue(detail.contains("Archive ink data could not be read"))
        }
    }
}

extension ArchiveExchangeTests {
    @MainActor
    func testEditAndReexportPreservesInstalledManifestAndInkFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let previous = WebLibrary.storeDirOverride
        WebLibrary.storeDirOverride = root
        defer {
            WebLibrary.storeDirOverride = previous
            try? FileManager.default.removeItem(at: root)
        }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "harbor-linux", withExtension: "vellumweb"))
        let archive = try WebArchive.readArchive(at: fixture)
        var manifest = archive.manifest
        // Closed loopback port exercises the installed-snapshot fallback.
        manifest.url = "https://127.0.0.1:1/article"
        manifest.canonicalUrl = manifest.url
        manifest.titleIsUserDefined = false
        manifest.unknownFields["future"] = .null
        manifest.hashes.unknownFields["algorithm"] = .string("next")
        manifest.assets[0].unknownFields["scale"] = .int(2)
        var ink = try XCTUnwrap(archive.inkRecord)
        ink.unknownFields["canvas"] = .int(7)
        ink.layout.unknownFields["dpi"] = .int(72)
        ink.clusters[0].unknownFields["label"] = .string("A")
        ink.clusters[0].bounds.unknownFields["unit"] = .string("px")
        ink.clusters[0].anchor?.unknownFields["direction"] = .string("right")
        ink.clusters[0].anchor?.rect.unknownFields["offset"] = .int(5)
        let key = WebLibrary.pageKey(try WebUrl.normalize(manifest.url))
        let input = WebLibrary.managedArchivePath(forKey: key)
        let pages = try WebArchive.encodePagesJson([])
        manifest.hashes.pageText = WebArchive.sha256Hex(pages)
        let asset = try XCTUnwrap(archive.assets.first)
        _ = try WebArchive.writeArchive(to: input, manifest: manifest, snapshotHtml: archive.snapshotHtml,
            assets: [.init(name: asset.0, url: manifest.assets[0].url,
                           contentType: manifest.assets[0].contentType, bytes: asset.1)],
            pagesJson: pages, annotations: archive.annotations, inkJson: JSONEncoder().encode(ink))
        // A peer's managed archive can arrive before this device has installed a snapshot.
        let previousManifest = try await WebLibraryStorage().previousManifest(forKey: key)
        XCTAssertEqual(previousManifest?.unknownFields, manifest.unknownFields)
        XCTAssertEqual(previousManifest?.hashes.unknownFields, manifest.hashes.unknownFields)
        XCTAssertEqual(previousManifest?.assets.first?.unknownFields, manifest.assets[0].unknownFields)
        let session = try await WebSessionBackend().openVellumwebFile(path: input.path, sessionId: "test")
        try FileManager.default.removeItem(at: input) // Exercise the installed copy on re-export.
        let original = try XCTUnwrap(WebInkStore.loadRecord(forKey: key))
        let fresh = WebInkRecord.snapshot(of: try original.validatedMergedDrawing(), url: session.url,
            layout: .init(contentWidth: 100, docHeight: 500), anchorFor: { _ in original.clusters[0].anchor })
        _ = try WebInkStore.applySnapshot(fresh, replacing: original, forKey: key)
        try await session.setMetadata(key: "title", value: "Edited after import")
        let output = root.appendingPathComponent("out.vellumweb")
        _ = try await session.exportVellumweb(destPath: output.path, pages: [])
        let exported = try WebArchive.readArchive(at: output)
        XCTAssertEqual(exported.manifest.title, "Edited after import")
        XCTAssertEqual(exported.manifest.unknownFields, manifest.unknownFields)
        XCTAssertEqual(exported.manifest.hashes.unknownFields, manifest.hashes.unknownFields)
        XCTAssertEqual(exported.manifest.assets[0].unknownFields, manifest.assets[0].unknownFields)
        XCTAssertEqual(exported.manifest.assets[0].url, "", "Offline exports retain their legacy asset descriptor")
        let restored = try XCTUnwrap(exported.inkRecord)
        XCTAssertEqual(restored.unknownFields, ink.unknownFields)
        XCTAssertEqual(restored.layout.unknownFields, ink.layout.unknownFields)
        XCTAssertEqual(restored.clusters[0].unknownFields, ink.clusters[0].unknownFields)
        XCTAssertEqual(restored.clusters[0].bounds.unknownFields, ink.clusters[0].bounds.unknownFields)
        XCTAssertEqual(restored.clusters[0].anchor?.unknownFields, ink.clusters[0].anchor?.unknownFields)
        XCTAssertEqual(restored.clusters[0].anchor?.rect.unknownFields, ink.clusters[0].anchor?.rect.unknownFields)
    }
}
