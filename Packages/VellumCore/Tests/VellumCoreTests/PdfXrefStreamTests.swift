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

    func testReadOnlyIdentityChecksForwardIndirectLengthsAgainstPhysicalObjects() throws {
        let base = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("resume-stream-string"))
        let source = PdfClassicStructure(base)
        try source.inspect()
        var trailer = source.latestTrailer
        let marker = try XCTUnwrap(base.range(of: Data("startxref\n".utf8), options: .backwards))
        let previous = try XCTUnwrap(Int(String(decoding: base[marker.upperBound...].prefix(while: PdfBytes.isDigit), as: UTF8.self)))
        let first = try XCTUnwrap(trailer.integer(forKey: "Size"))
        for key in ["Filter", "DecodeParms"] { trailer.removeEntry(forKey: key) }
        trailer.setInteger(forKey: "Prev", to: previous)
        trailer.setInteger(forKey: "Size", to: first + 3)
        trailer.setInteger(forKey: "Length", to: 18)
        trailer.setValue(forKey: "W", raw: Array("[1 4 1]".utf8))
        trailer.setValue(forKey: "Index", raw: Array("[\(first) 3]".utf8))
        var bytes = base
        bytes.append(contentsOf: "\(first) 0 obj\n<< /Length \(first + 1) 0 R >>\nstream\n".utf8)
        // This opaque content makes the file larger than the classic identity window.
        let count = 8 * 1024 * 1024
        bytes.append(Data(repeating: 0, count: count))
        bytes.append(contentsOf: "\nendstream\nendobj\n".utf8)
        let lengthObject = bytes.count
        bytes.append(contentsOf: "\(first + 1) 0 obj\n\(count)\nendobj\n".utf8)
        let xref = bytes.count
        bytes.append(contentsOf: "\(first + 2) 0 obj\n".utf8)
        bytes.append(contentsOf: trailer.sourceBytes)
        bytes.append(contentsOf: "\nstream\n".utf8)
        for offset in [base.count, lengthObject, xref] {
            bytes.append(1)
            withUnsafeBytes(of: UInt32(offset).bigEndian) { bytes.append(contentsOf: $0) }
            bytes.append(0)
        }
        bytes.append(contentsOf: "\nendstream\nendobj\nstartxref\n\(xref)\n%%EOF\n".utf8)
        XCTAssertEqual(identity(bytes), stamp)
        XCTAssertNotEqual(PdfEditEligibility.classify(bytes), .editable)
        let length = try XCTUnwrap(bytes.range(of: Data(String(count).utf8), options: .backwards))
        bytes[length.lowerBound] = 49
        XCTAssertNil(identity(bytes))
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
