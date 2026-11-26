import Foundation
import XCTest
@testable import Vellum

final class ArchiveExchangeTests: XCTestCase {
    // The Linux ArchiveCodec re-encoded the package's pre-extraction Apple fixture.
    func testHostedImporterOpensLinuxExportWithAnchoredPencilStroke() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "harbor-linux", withExtension: "vellumweb"))
        let archive = try WebArchive.readArchive(at: url)
        XCTAssertEqual(archive.manifest.title, "Exchange 東京")
        XCTAssertTrue(archive.snapshotHtml.contains("Harbor café 東京"))
        XCTAssertEqual(archive.assets.map(\.0), ["sample.png"])
        let ink = try XCTUnwrap(archive.inkRecord)
        XCTAssertEqual(try ink.validatedMergedDrawing().strokes.count, 1)
        XCTAssertEqual(ink.clusters.first?.anchor?.text, "Harbor café 東京")
    }
}
