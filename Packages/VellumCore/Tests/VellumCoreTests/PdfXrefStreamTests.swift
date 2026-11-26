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
        XCTAssertThrowsError(try PdfClassicStructure(bytes, decodedLimit: 32).inspect(forEditing: false)) {
            XCTAssertEqual($0 as? PdfReadOnlyReason, .inspectionLimit)
        }
    }

    func testStampOutlineAndReplacementKeepEachPrefix() throws {
        let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("resume-stream-string"))
        let first = try ClassicPdfFile(data: original)
        let id = try XCTUnwrap(first.infoNumber)
        XCTAssertNil(first.objectOffsets[id]) // Info starts compressed.
        let stamped = try PdfInfoIncrement.setMetadataIncrement(
            normalizedData: original, entries: [("doc_id", stamp), ("title", "New title")])
        let marked = try PdfOutlineIncrement.createBookmarkIncrement(
            normalizedData: stamped, pageNumber: 2, id: "mark", content: "Page two", now: "t0")
        let pinned = try XCTUnwrap(PdfOutlineIncrement.updateBookmarkIncrement(
            normalizedData: marked, id: "mark", isPinned: true, now: "t1"))
        var previous = original
        for bytes in [stamped, marked, pinned] {
            XCTAssertTrue(bytes.starts(with: previous))
            let file = try ClassicPdfFile(data: bytes)
            XCTAssertEqual(file.trailer.name(forKey: "Type"), "XRef")
            XCTAssertEqual(file.trailer.integer(forKey: "Prev"), try ClassicPdfFile(data: previous).startXref)
            XCTAssertEqual(file.trailer.rawValue(forKey: "ID"), first.trailer.rawValue(forKey: "ID"))
            XCTAssertNotNil(file.objectOffsets[id])
            XCTAssertEqual(file.objectSource(id)?.textString(forKey: "Title"), "New title")
            XCTAssertEqual(identity(bytes), stamp)
            previous = bytes
        }
        let latest = try ClassicPdfFile(data: pinned)
        var replacement = PdfIncrement(file: latest)
        replacement.setObject(id, source: Array("<< /VellumDocId /\(stamp) >>".utf8))
        XCTAssertNil(identity(replacement.appended()))
        replacement.setObject(id, source: Array("<< /FT /Sig >>".utf8))
        let signed = replacement.appended()
        XCTAssertEqual(PdfEditEligibility.classify(signed), .readOnly(.signed))
        XCTAssertThrowsError(try PdfInfoIncrement.setMetadataIncrement(normalizedData: signed, key: "title", value: "x"))

        // Replacing that signature in a later, otherwise ordinary revision
        // cannot authorize a write to the previously signed document.
        var suffix = signed
        let prev = try XCTUnwrap(signed.range(of: Data("startxref\n".utf8), options: .backwards))
        let start = String(decoding: signed[prev.upperBound...].prefix(while: PdfBytes.isDigit), as: UTF8.self)
        let offset = suffix.count
        suffix.append(contentsOf: "\(id) 0 obj\n<< >>\nendobj\n".utf8)
        let xref = suffix.count
        suffix.append(contentsOf: "xref\n\(id) 1\n".utf8)
        suffix.append(contentsOf: String(format: "%010lld 00000 n \n", Int64(offset)).utf8)
        let old = try XCTUnwrap(signed.range(of: Data("/Size ".utf8), options: .backwards))
        let size = String(decoding: signed[old.upperBound...].prefix(while: PdfBytes.isDigit), as: UTF8.self)
        var trailer = latest.trailer
        trailer.setInteger(forKey: "Size", to: try XCTUnwrap(Int(size)))
        trailer.setInteger(forKey: "Prev", to: try XCTUnwrap(Int(start)))
        for key in ["Length", "W", "Index", "Type"] { trailer.removeEntry(forKey: key) }
        suffix.append(contentsOf: "trailer\n".utf8)
        suffix.append(contentsOf: trailer.sourceBytes)
        suffix.append(contentsOf: "\nstartxref\n\(xref)\n%%EOF\n".utf8)
        XCTAssertEqual(PdfEditEligibility.classify(suffix), .readOnly(.signed))
    }

    func testLaterCompressedRowMustNameTheSameMemberAndCannotReviveFreedInfo() throws {
        let bytes = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("resume-stream-string"))
        let file = try ClassicPdfFile(data: bytes)
        let info = try XCTUnwrap(file.infoNumber)
        // This fixture stores Info 10 in container 1 at slot 8.
        XCTAssertEqual(info, 10)
        let stream = file.size
        let offset = bytes.count
        func revision(row: [UInt8]) -> Data {
            var dict = file.trailer
            for key in ["Filter", "DecodeParms"] { dict.removeEntry(forKey: key) }
            dict.setValue(forKey: "W", raw: Array("[1 4 1]".utf8))
            dict.setValue(forKey: "Index", raw: Array("[10 1 \(stream) 1]".utf8))
            dict.setInteger(forKey: "Size", to: stream + 1)
            dict.setInteger(forKey: "Prev", to: file.startXref)
            dict.setInteger(forKey: "Length", to: 12)
            var data = bytes
            data.append(contentsOf: "\(stream) 0 obj\n".utf8)
            data.append(contentsOf: dict.sourceBytes)
            data.append(contentsOf: "\nstream\n".utf8)
            data.append(contentsOf: row)
            data.append(1)
            withUnsafeBytes(of: UInt32(offset).bigEndian) { data.append(contentsOf: $0) }
            data.append(0)
            data.append(contentsOf: "\nendstream\nendobj\nstartxref\n\(offset)\n%%EOF\n".utf8)
            return data
        }
        XCTAssertEqual(identity(revision(row: [2, 0, 0, 0, 1, 8])), stamp)
        for row: [UInt8] in [[2, 0, 0, 0, 1, 7], [2, 0, 0, 0, 1, 9], [0, 0, 0, 0, 0, 1]] {
            let changed = revision(row: row)
            XCTAssertNil(identity(changed))
            XCTAssertEqual(PdfEditEligibility.classify(changed), .readOnly(.malformed))
            XCTAssertThrowsError(try PdfInfoIncrement.setMetadataIncrement(normalizedData: changed, key: "title", value: "x"))
        }
    }

    func testPredictorsAndDecodeBudget() throws {
        func decode(_ compressed: [UInt8], predictor: Int, columns: Int,
                    colors: Int = 1, bits: Int = 8, limit: Int = 1024) throws -> [UInt8] {
            var decoder = PdfStreamDecoder(remaining: limit)
            return try decoder.decode(compressed[...], dictionary: [
                "Filter": .name("FlateDecode"), "DecodeParms": .dictionary([
                    "Predictor": .integer(predictor), "Columns": .integer(columns),
                    "Colors": .integer(colors), "BitsPerComponent": .integer(bits)
                ])
            ])
        }
        // None, Sub, Up, Average and Paeth on two-byte rows with distinct
        // left, above and upper-left values.
        let png: [UInt8] = [120, 156, 99, 96, 102, 103, 228, 100, 102, 98, 101, 103, 230, 229, 102, 225, 103, 5, 0, 2, 58, 0, 89]
        XCTAssertEqual(try decode(png, predictor: 15, columns: 2), [3, 7, 9, 12, 14, 19, 20, 30, 35, 40])
        // TIFF horizontal differencing wraps each component at its bit depth.
        XCTAssertEqual(try decode([120, 156, 139, 7, 0, 0, 96, 0, 96], predictor: 2, columns: 4, bits: 2), [0x64])
        XCTAssertEqual(try decode([120, 156, 99, 252, 199, 192, 4, 0, 3, 4, 1, 2], predictor: 2, columns: 2, bits: 16), [1, 254, 2, 0])
        XCTAssertEqual(try decode([120, 156, 99, 98, 103, 252, 15, 0, 1, 34, 1, 10], predictor: 2, columns: 2, colors: 2), [2, 7, 3, 6])
        XCTAssertThrowsError(try decode([120, 156, 99, 100, 28, 88, 0, 0, 32, 192, 0, 129], predictor: 1, columns: 1, limit: 32)) {
            XCTAssertEqual($0 as? PdfReadOnlyReason, .inspectionLimit)
        }
        XCTAssertThrowsError(try decode(png + [0], predictor: 15, columns: 2))
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
    func testStreamBudgetReservesOnlyTheNextRevision() throws {
        var bytes = PdfFixtureBuilder.xrefStreamPdf()
        for _ in 1..<63 {
            let file = try ClassicPdfFile(data: bytes)
            var increment = PdfIncrement(file: file)
            increment.setObject(4, source: try XCTUnwrap(file.rawObjectValue(4)))
            bytes = increment.appended()
        }
        XCTAssertEqual(PdfEditEligibility.classify(bytes), .editable)
        let last = try PdfAnnotationIncrement.applying(
            .create(.init(type: .note, pageNumber: 1, id: "last")), to: bytes, now: "2026-11-26T00:00:00Z")
        XCTAssertTrue(last.starts(with: bytes))
        try PdfEditEligibility.inspect(last, reservingRevision: false)
        XCTAssertEqual(PdfEditEligibility.classify(last), .readOnly(.inspectionLimit))
        XCTAssertThrowsError(try PdfAnnotationIncrement.applying(.delete(id: "last"), to: last, now: "2026-11-26T00:00:00Z")) {
            XCTAssertEqual($0 as? PdfReadOnlyReason, .inspectionLimit)
        }
    }

}
