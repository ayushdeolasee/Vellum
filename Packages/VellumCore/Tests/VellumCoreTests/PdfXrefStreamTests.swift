import Foundation
import XCTest
@testable import VellumCore

final class PdfXrefStreamTests: XCTestCase {
    private let stamp = "01234567-89ab-cdef-0123-456789abcdef"

    private func identity(_ data: Data) -> String? {
        ClassicPdfFile.currentInfoText(forKey: "VellumDocId", in: data)
    }

    func testCompressedInfoAndHybridPrecedence() throws {
        let bytes = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("resume-stream-string"))
        XCTAssertEqual(identity(bytes), stamp)
        XCTAssertNil(identity(try Data(contentsOf: PdfFixtureBuilder.fixtureURL("resume-stream-name"))))
        let footer = try XCTUnwrap(bytes.range(of: Data("startxref\n".utf8), options: .backwards))
        let xref = try XCTUnwrap(Int(String(decoding: bytes[footer.upperBound...].prefix(while: PdfBytes.isDigit), as: UTF8.self)))
        var hybrid = bytes[..<footer.lowerBound]
        // The table marks compressed Info object 10 free in this same revision.
        // The supplemental stream's type-2 row wins. Later revisions may free it.
        let parsed = PdfClassicStructure(bytes)
        try parsed.inspect()
        var trailer = parsed.latestTrailer
        for key in ["Type", "Filter", "DecodeParms", "W", "Length"] { trailer.removeEntry(forKey: key) }
        trailer.setInteger(forKey: "XRefStm", to: xref)
        let table = hybrid.count
        hybrid.append(contentsOf: "xref\n10 1\n0000000000 00000 f \ntrailer\n".utf8)
        hybrid.append(contentsOf: trailer.sourceBytes)
        hybrid.append(contentsOf: "\nstartxref\n\(table)\n%%EOF\n".utf8)
        XCTAssertEqual(identity(hybrid), stamp)
        trailer.removeEntry(forKey: "XRefStm")
        trailer.setInteger(forKey: "Prev", to: table)
        let last = hybrid.count
        hybrid.append(contentsOf: "xref\n10 1\n0000000000 00001 f \ntrailer\n".utf8)
        hybrid.append(contentsOf: trailer.sourceBytes)
        hybrid.append(contentsOf: "\nstartxref\n\(last)\n%%EOF\n".utf8)
        XCTAssertNil(identity(hybrid))
        XCTAssertThrowsError(try PdfClassicStructure(bytes, decodedLimit: 32).inspect(forEditing: false))
    }

    func testRowWidthsAndObjectIdentity() throws {
        let dict: [String: PdfStructuralValue] = [
            "Size": .integer(10), "W": .array([.integer(0), .integer(2), .integer(0)]),
            "Index": .array([.integer(4), .integer(1), .integer(8), .integer(1)])
        ]
        let rows = try PdfStreamDecoder.rows([0, 42, 1, 3], dictionary: dict, limit: 100)
        guard case .direct(42, 0) = rows[4], case .direct(259, 0) = rows[8] else { return XCTFail("Default type/offset") }
        XCTAssertThrowsError(try PdfStreamDecoder.rows([0, 42, 1], dictionary: dict, limit: 100))
        XCTAssertThrowsError(try PdfStreamDecoder.rows([0, 42, 1, 3, 4], dictionary: dict, limit: 100))
        var bytes = PdfFixtureBuilder.xrefStreamPdf()
        let header = try XCTUnwrap(bytes.range(of: Data("6 0 obj".utf8)))
        bytes[header.lowerBound] = 56
        XCTAssertThrowsError(try PdfClassicStructure(bytes).inspect())
    }
}
