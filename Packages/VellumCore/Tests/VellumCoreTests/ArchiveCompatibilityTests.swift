import Foundation
import VellumCore
import XCTest

final class ArchiveCompatibilityTests: XCTestCase {
    // A real WebArchive.writeArchive export from the pre-extraction Apple app.
    // The PNG and the one PencilKit stroke were created solely for this fixture.
    private func appleExport() throws -> Data {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "harbor", withExtension: "vellumweb", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func zip(_ bytes: Data) throws -> MiniZip {
        try MiniZip(data: bytes, maxBytes: 32 * 1024, maxEntries: 8, maxUncompressedBytes: 32 * 1024)
    }

    func testAppleExportAndCoreReexport() throws {
        let original = try appleExport()
        let source = try zip(original)
        let decoded = try ArchiveCodec.decode(original)
        let manifest = decoded.manifest
        XCTAssertEqual(try ArchiveCodec.readManifest(data: original).title, "Exchange 東京")
        XCTAssertEqual(manifest.loadingPolicy, "snapshot-only")
        XCTAssertTrue(decoded.snapshotHtml.contains("Harbor café 東京"))
        XCTAssertTrue(decoded.snapshotHtml.contains("__VELLUM_ASSET__/sample.png"))
        XCTAssertEqual(decoded.assets.map(\.0), ["sample.png"])
        let asset = try XCTUnwrap(decoded.assets.first)
        let meta = try XCTUnwrap(manifest.assets.first)
        XCTAssertEqual(meta.sha256, ArchiveCodec.sha256Hex(asset.1))
        let pages = try source.readCapped("text/pages.json", cap: 1024)
        XCTAssertEqual(manifest.hashes.pageText, ArchiveCodec.sha256Hex(pages))
        let ink = try XCTUnwrap(decoded.inkJSON)
        XCTAssertEqual(ink, try source.readCapped("ink.json", cap: 4096))
        XCTAssertEqual(manifest.hashes.ink, ArchiveCodec.sha256Hex(ink))

        let encoded = try ArchiveCodec.encode(
            manifest: manifest, snapshotHtml: decoded.snapshotHtml,
            assets: [CapturedAsset(name: asset.0, url: meta.url, contentType: meta.contentType, bytes: asset.1)],
            pagesJson: pages, annotations: decoded.annotations, inkJson: ink)
        let result = try zip(encoded)
        XCTAssertEqual(Set(result.entryNames), Set(source.entryNames))
        for name in source.entryNames {
            let expected = try source.readCapped(name, cap: 4096)
            let actual = try result.readCapped(name, cap: 4096)
            if name == "manifest.json" {
                XCTAssertEqual(try JSONSerialization.jsonObject(with: actual) as? NSDictionary,
                               try JSONSerialization.jsonObject(with: expected) as? NSDictionary)
            } else {
                XCTAssertEqual(actual, expected, name)
            }
        }
    }

    func testOpaqueInkAndLegacyOptionalMembers() throws {
        let bytes = try appleExport()
        let source = try zip(bytes)
        let archive = try ArchiveCodec.decode(bytes)
        let opaqueInk = Data([0xff, 0, 0x80])
        var manifest = archive.manifest
        manifest.hashes.ink = ArchiveCodec.sha256Hex(opaqueInk)
        let manifestEntry = MiniZip.Entry(name: "manifest.json", data: try JSONEncoder().encode(manifest), stored: true)
        let snapshot = MiniZip.Entry(name: "snapshot/index.html",
                                     data: try source.readCapped("snapshot/index.html", cap: 4096), stored: true)
        let entries = [manifestEntry, snapshot]
        // Import has always allowed absent page text, annotations, and listed assets.
        // Declared ink, unlike those members, must be present and hash-valid.
        XCTAssertThrowsError(try ArchiveCodec.decode(MiniZip.write(entries: entries)))
        let wrongInk = MiniZip.Entry(name: "ink.json", data: Data(), stored: false)
        XCTAssertThrowsError(try ArchiveCodec.decode(MiniZip.write(entries: entries + [wrongInk])))
        let ink = MiniZip.Entry(name: "ink.json", data: opaqueInk, stored: false)
        XCTAssertEqual(try ArchiveCodec.decode(MiniZip.write(entries: entries + [ink])).inkJSON, opaqueInk)

        let corrupt = MiniZip.Entry(name: "snapshot/index.html", data: Data(), stored: true)
        XCTAssertThrowsError(try ArchiveCodec.decode(MiniZip.write(entries: [manifestEntry, corrupt, ink])))
    }

    #if os(Linux)
    func testSparseFileRejectedBeforeParsing() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(ArchiveCodec.maxArchiveBytes + 1))
        for read in [{ _ = try ArchiveCodec.readManifest(at: file) }, { _ = try ArchiveCodec.decode(at: file) }] {
            XCTAssertThrowsError(try read()) { error in
                XCTAssertTrue(error.localizedDescription.contains("archive exceeds its size limit"))
            }
        }
    }
    #endif

    func testBoundedReadsAndStreamTermination() throws {
        let plain = Data(repeating: 0x2a, count: 1024)
        let entries = [
            MiniZip.Entry(name: "text", data: plain, stored: false),
            MiniZip.Entry(name: "empty", data: Data(), stored: false),
            MiniZip.Entry(name: "stored", data: Data([42]), stored: true),
        ]
        let bytes = try MiniZip.write(entries: entries)
        XCTAssertThrowsError(try MiniZip(data: bytes, maxBytes: bytes.count - 1, maxEntries: 3, maxUncompressedBytes: 1025))
        XCTAssertThrowsError(try MiniZip(data: bytes, maxBytes: bytes.count, maxEntries: 2, maxUncompressedBytes: 1025))
        XCTAssertThrowsError(try MiniZip(data: bytes, maxBytes: bytes.count, maxEntries: 3, maxUncompressedBytes: 1024))
        let valid = try zip(bytes)
        XCTAssertEqual(try valid.readCapped("text", cap: 1024), plain)
        XCTAssertEqual(try valid.readCapped("empty", cap: 0), Data())
        XCTAssertEqual(try valid.readCapped("stored", cap: 1), Data([42]))

        // Small local fixture: exercise the inflater itself with a 7-byte budget.
        let central = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        var underdeclared = bytes
        underdeclared.replaceSubrange(central + 24..<central + 28, with: [7, 0, 0, 0])
        XCTAssertThrowsError(try zip(underdeclared).readCapped("text", cap: 7)) { error in
            XCTAssertTrue(error.localizedDescription.contains("exceeds its size limit"))
        }

        var truncated = bytes
        truncated[central + 20] -= 1 // one byte short of the final DEFLATE block
        XCTAssertThrowsError(try zip(truncated).readCapped("text", cap: 1024))
    }
}
