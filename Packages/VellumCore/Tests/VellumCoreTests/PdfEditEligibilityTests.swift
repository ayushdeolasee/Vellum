import Foundation
import XCTest
@testable import VellumCore

final class PdfEditEligibilityTests: XCTestCase {
    private let catalog = "<< /Type /Catalog /Pages 2 0 R >>"
    private let pages = "<< /Type /Pages /Kids [3 0 R] /Count 1 /MediaBox [0 0 100 200] >>"
    private func page(_ entries: String = "") -> String {
        "<< /Type /Page /Parent 2 0 R \(entries) >>"
    }
    private func document(_ entries: String = "", extra: [String] = []) -> Data {
        PdfFixtureBuilder.classicObjects([catalog, pages, page(entries)] + extra)
    }
    private func replacing(_ text: String, with replacement: String, in data: Data) throws -> Data {
        let range = try XCTUnwrap(data.range(of: Data(text.utf8), options: .backwards))
        var result = data
        result.replaceSubrange(range, with: replacement.utf8)
        return result
    }
    private func classify(_ data: Data, _ expected: PdfEditEligibility,
                          file: StaticString = #filePath, line: UInt = #line) {
        let original = [UInt8](data)
        XCTAssertEqual(PdfEditEligibility.classify(data), expected, file: file, line: line)
        XCTAssertTrue(data.elementsEqual(original), file: file, line: line)
    }

    func testBundledOriginalBytes() throws {
        for (name, expected): (String, PdfEditEligibility) in [
            ("classic-two-column", .editable), ("rotated-all-angles", .editable),
            ("ipad-vellum-ink", .editable), ("pdf-ink-erased-full", .editable),
            ("pdf-ink-erased-partial", .editable), ("pdf-ink-marker", .editable), ("pdf-ink-rotated", .editable),
            ("foreign-annotations", .editable), ("xref-stream-objstm", .readOnly(.unsupportedXref)),
            ("encrypted-user-pass", .readOnly(.encrypted)), ("digitally-signed", .readOnly(.signed))
        ] {
            let bytes = try Data(contentsOf: PdfFixtureBuilder.fixtureURL(name))
            XCTAssertEqual(PdfEditEligibility.classify(bytes), expected, name)
        }
        for layout in [PdfFixtureBuilder.AnnotsLayout.absent, .inlineEmpty, .indirectEmpty, .withForeignInline] {
            classify(PdfFixtureBuilder.makeClassicPdf(pages: [.init()], annotsLayout: layout), .editable)
        }
    }

    func testPortableParserAndSuccessiveInMemoryIncrementsAgree() throws {
        let original = document("/Rotate 90 /CropBox 4 0 R", extra: ["[10 20 90 180]"])
        let stamped = try PdfInfoIncrement.setMetadataIncrement(normalizedData: original, key: "title", value: "Reading")
        let bookmark = try PdfOutlineIncrement.createBookmarkIncrement(normalizedData: stamped, pageNumber: 1, id: "one", now: "t0")
        for snapshot in [original, stamped, bookmark] {
            classify(snapshot, .editable)
            let file = try ClassicPdfFile(data: snapshot)
            let geometry = try PageGeometry(pageNumber: 1, in: file)
            XCTAssertEqual(geometry.displayWidth, 160)
            XCTAssertEqual(geometry.displayHeight, 80)
        }
    }

    func testSecurityChecksUseParsedValues() throws {
        for entry in ["/FT /Sig", "/Type /Sig", "/Type /DocTimeStamp", "/SigFlags 1",
                      "/ByteRange [0 8]", "/Perms << /DocMDP 3 0 R >>", "/F#54 /S#69g"] {
            classify(document(extra: ["<< /Nested [ << \(entry) >> ] >>"]), .readOnly(.signed))
        }
        let form = "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>"
        classify(PdfFixtureBuilder.classicObjects([form, pages, page(), "<< /FT 5 0 R /Kids [6 0 R] >>",
                                                   "/Sig", "<< /Parent 4 0 R >>"]), .readOnly(.signed))
        classify(document(extra: ["<< /Type 5 0 R /Length 0 >>\nstream\n\nendstream", "/ObjStm"]),
                 .readOnly(.unsupportedXref))
        let text = "/Type /Sig /ByteRange /Encrypt startxref"
        classify(document(extra: ["(\(text))", "<< /Length \(text.utf8.count) >>\nstream\n\(text)\nendstream"]), .editable)
    }

    func testEarlierRevisionsAreInspectedInTheirOwnObjectMap() throws {
        for entry in ["/FT /Sig", "/Perms << /UR3 3 0 R >>"] {
            let base = document(extra: ["<< \(entry) >>"])
            var increment = PdfIncrement(file: try ClassicPdfFile(data: base))
            increment.setObject(4, source: Array("<< >>".utf8))
            classify(increment.appended(), .readOnly(.signed))
        }

        for (key, reason): (String, PdfReadOnlyReason) in [("/Encrypt 3 0 R", .encrypted), ("/XRefStm 9", .unsupportedXref)] {
            let base = try replacing("/Size 4", with: "/Size 4 \(key)", in: document())
            let prev = try ClassicPdfFile(data: base).startXref
            // Write a fixture trailer that intentionally omits the historical
            // key, independent of which entries Vellum's writer carries over.
            let next = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Size 4 /Root 1 0 R /Prev \(prev) >>\nstartxref\n\(base.count)\n%%EOF\n"
            classify(base + Data(next.utf8), .readOnly(reason))
        }
        let base = document()
        var increment = PdfIncrement(file: try ClassicPdfFile(data: base))
        increment.setObject(3, source: Array(page().utf8))
        let final = increment.appended()
        let latest = try ClassicPdfFile(data: final)
        let prev = "/Prev \(try ClassicPdfFile(data: base).startXref)"
        for replacement in ["", "/Prev -1", "/Prev 1", "/Prev \(latest.startXref)", "/Prev null"] {
            classify(try replacing(prev, with: replacement, in: final), .readOnly(.malformed))
        }
        let xrefStream = PdfFixtureBuilder.xrefStreamPdf()
        let marker = try XCTUnwrap(xrefStream.range(of: Data("startxref\n".utf8), options: .backwards))
        let offset = String(decoding: xrefStream[marker.upperBound...], as: UTF8.self).prefix(while: { $0.isNumber })
        let suffix = "xref\n0 1\n0000000000 65535 f \ntrailer\n<< /Root 1 0 R /Size 8 /Prev \(offset) >>\nstartxref\n\(xrefStream.count)\n%%EOF\n"
        classify(xrefStream + Data(suffix.utf8), .readOnly(.unsupportedXref))
    }

    func testGenerationsFreeEntriesAndXrefBoundaries() throws {
        classify(PdfFixtureBuilder.makeClassicPdf(pages: [.init()], generation: 3), .readOnly(.nonzeroGeneration))
        classify(document("/Annots [4 2 R]", extra: ["<< /Subtype /Text >>"]), .readOnly(.nonzeroGeneration))
        let base = document("/Annots [4 0 R]", extra: ["<< /Subtype /Text >>"])
        let prev = try ClassicPdfFile(data: base).startXref
        let freeing = "xref\n4 1\n0000000000 00001 f \ntrailer\n<< /Size 5 /Root 1 0 R /Prev \(prev) >>\nstartxref\n\(base.count)\n%%EOF\n"
        classify(base + Data(freeing.utf8), .readOnly(.malformed))
        let unused = document(extra: ["null"])
        let unusedPrev = try ClassicPdfFile(data: unused).startXref
        let freeTable = "xref\n0 1\n0000000004 65535 f \n4 1\n0000000000 00001 f \ntrailer\n<< /Size 5 /Root 1 0 R /Prev \(unusedPrev) >>\nstartxref\n\(unused.count)\n%%EOF\n"
        classify(unused + Data(freeTable.utf8), .editable)
        for link in ["0000000003", "0000000004"] {
            let broken = freeTable.replacingOccurrences(of: "0000000000 00001 f", with: "\(link) 00001 f")
            classify(unused + Data(broken.utf8), .readOnly(.malformed))
        }
        for (from, to) in [("/Size 5", "/Size 1"), ("/Size 5", "/Size 9223372036854775807"),
                           ("xref\n0 5", "xref\n9223372036854775807 5"), ("0000000009 00000 n", "0000000010 00000 n"),
                           ("0000000009 00000 n", "0000000009 00003 n")] {
            classify(try replacing(from, with: to, in: base), .readOnly(to.contains("00003 n") ? .nonzeroGeneration : .malformed))
        }
    }

    func testGeometryAndPageOwnership() {
        for entries in ["/CropBox [1 2 3]", "/CropBox [0 0 0 40]", "/CropBox [0 0 101 200]",
                        "/MediaBox [10 10 0 0]", "/Rotate 45", "/UserUnit 0", "/UserUnit 2"] {
            classify(document(entries), .readOnly(.unsupportedGeometry))
        }
        classify(PdfFixtureBuilder.classicObjects([catalog, pages, "<< /Type /Page /Parent 3 0 R >>"]), .readOnly(.malformed))
        classify(PdfFixtureBuilder.classicObjects([catalog, "<< /Type /Pages /Kids [2 0 R] /Count 1 >>"]), .readOnly(.malformed))
    }

    func testAnnotationObjectAndIdentityAmbiguities() {
        let twoPages = "<< /Type /Pages /MediaBox [0 0 100 200] /Kids [3 0 R 4 0 R] /Count 2 >>"
        let annotation = "<< /Subtype /Text >>"
        for (a, b, extra) in [("5 0 R", "5 0 R", ["[]"]), ("[5 0 R]", "[5 0 R]", [annotation]),
                              ("[5 0 R 5 0 R]", "[]", [annotation]),
                              ("[null \(annotation)]", "[<< /Subtype /Text /NM (pdf-direct-1-1) >>]", []),
                              ("[<< /Subtype /Text /NM (one) >>]", "[<< /Subtype /Text /NM <6f6e65> >>]", []),
                              ("[<< /Subtype /Text /P 4 0 R >>]", "[]", [])] {
            classify(PdfFixtureBuilder.classicObjects([catalog, twoPages, page("/Annots \(a)"), page("/Annots \(b)")] + extra),
                     .readOnly(.ambiguousAnnotation))
        }
        classify(document("/Annots 4 0 R /Other 4 0 R", extra: ["[]"]), .readOnly(.ambiguousAnnotation))
        classify(document("/Annots [42]"), .readOnly(.ambiguousAnnotation))
    }

    func testMalformedAndBudgetedInputs() throws {
        let base = document()
        classify(try replacing("%PDF-1.7", with: "%PDF-2.9", in: base), .readOnly(.malformed))
        for n in [0, 1, 8, 12, base.count / 2, base.count - 4] {
            classify(base.prefix(n), .readOnly(.malformed))
        }
        classify(document(extra: [String(repeating: "[", count: 65) + String(repeating: "]", count: 65)]), .readOnly(.malformed))
        classify(document("/Rotate 0 /Rotate 90"), .readOnly(.malformed))
        classify(document(extra: ["<< /Type /Example /Nested [<01> << /Name (endobj) >>] >>"]), .readOnly(.malformed))
        var bytes = base
        for _ in 1..<64 {
            var increment = PdfIncrement(file: try ClassicPdfFile(data: bytes))
            increment.setObject(3, source: Array(page().utf8))
            bytes = increment.appended()
        }
        classify(bytes, .editable)
        var increment = PdfIncrement(file: try ClassicPdfFile(data: bytes))
        increment.setObject(3, source: Array(page().utf8))
        classify(increment.appended(), .readOnly(.malformed))
    }
}
