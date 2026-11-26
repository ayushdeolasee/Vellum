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
