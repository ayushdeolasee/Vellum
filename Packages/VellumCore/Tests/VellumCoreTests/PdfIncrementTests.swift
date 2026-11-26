import Foundation
import XCTest
@testable import VellumCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif

final class PdfIncrementTests: XCTestCase {
    func testDirectInfoPromotionAndSuccessiveIndirectUpdates() throws {
        let fixture = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
        // Only the trailer changes, after startxref's target.
        var original = fixture
        let root = try XCTUnwrap(original.range(of: Data("/Root 1 0 R".utf8)))
        original.insert(contentsOf: " /Info << /Producer (fixture) >>".utf8, at: root.upperBound)
        let title = "Café (読書) 📚"
        // An intervening outline edit must carry the direct Info unchanged.
        let bookmarked = try PdfOutlineIncrement.createBookmarkIncrement(
            normalizedData: original, pageNumber: 1, id: "one", now: "t0")
        let direct = try XCTUnwrap(ClassicPdfFile(data: bookmarked).trailer.inlineDictionary(forKey: "Info"))
        XCTAssertEqual(PdfDictSource(direct).textString(forKey: "Producer"), "fixture")
        let first = try PdfInfoIncrement.setMetadataIncrement(
            normalizedData: bookmarked, entries: [("title", title), ("last_page", "+17")])
        let second = try PdfInfoIncrement.setMetadataIncrement(
            normalizedData: first, key: "reading_theme", value: "Dark")
        XCTAssertTrue(first.starts(with: original))
        XCTAssertTrue(second.starts(with: first))
        let file = try ClassicPdfFile(data: second)
        let infoNumber = try XCTUnwrap(file.infoNumber)
        XCTAssertEqual(try ClassicPdfFile(data: first).infoNumber, infoNumber)
        let info = try XCTUnwrap(file.objectSource(infoNumber))
        XCTAssertEqual(info.textString(forKey: "Producer"), "fixture")
        XCTAssertEqual(info.textString(forKey: "Title"), title)
        XCTAssertEqual(info.integer(forKey: "VellumLastPage"), 17)
        XCTAssertEqual(info.textString(forKey: "VellumReadingTheme"), "Dark")
        XCTAssertThrowsError(try PdfInfoIncrement.setMetadataIncrement(normalizedData: second, key: "last_page", value: "-1")) {
            XCTAssertEqual($0 as? PdfCoreError, .invalidDocument("Invalid last_page value: invalid digit found in string"))
        }
        #if canImport(CoreGraphics)
        let provider = try XCTUnwrap(CGDataProvider(data: second as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        var text: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(document.info), "Title", &text))
        XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(text)) as String?, title)
        #endif
    }

    func testBookmarkLinksCountsAndUnrelatedPageObjectsAcrossRevisions() throws {
        let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("foreign-annotations"))
        func adding(_ id: String, to data: Data) throws -> Data {
            try PdfOutlineIncrement.createBookmarkIncrement(normalizedData: data, pageNumber: 1, id: id, now: "t0")
        }
        let first = try adding("one", to: original)
        let second = try adding("二", to: first)
        let renamed = try XCTUnwrap(PdfOutlineIncrement.updateBookmarkIncrement(
            normalizedData: second, id: "二", content: "章 (two)", defaultTitle: "unused", now: "t1"))
        let pinned = try XCTUnwrap(PdfOutlineIncrement.updateBookmarkIncrement(normalizedData: renamed, id: "二", isPinned: true, now: "t2"))
        let file = try ClassicPdfFile(data: pinned)
        let catalog = try XCTUnwrap(file.rootNumber.flatMap(file.objectSource))
        let outlineNumber = try XCTUnwrap(catalog.reference(forKey: "Outlines"))
        let outline = try XCTUnwrap(file.objectSource(outlineNumber))
        let head = try XCTUnwrap(outline.reference(forKey: "First"))
        let tail = try XCTUnwrap(outline.reference(forKey: "Last"))
        let bookmark = try XCTUnwrap(file.objectSource(tail))
        XCTAssertEqual(outline.integer(forKey: "Count"), 2)
        XCTAssertEqual(file.objectSource(head)?.reference(forKey: "Next"), tail)
        XCTAssertEqual(bookmark.reference(forKey: "Prev"), head)
        XCTAssertEqual(bookmark.textString(forKey: "Title"), "章 (two)")
        XCTAssertEqual(bookmark.textString(forKey: "VellumNM"), "二")
        XCTAssertEqual(bookmark.textString(forKey: "VellumUpdatedAt"), "t2")
        XCTAssertEqual(bookmark.integer(forKey: "VellumPinned"), 1)

        let deleted = try XCTUnwrap(PdfOutlineIncrement.deleteBookmarkIncrement(normalizedData: pinned, id: "one"))
        let latest = try ClassicPdfFile(data: deleted)
        let remaining = try XCTUnwrap(latest.objectSource(outlineNumber))
        XCTAssertEqual(remaining.integer(forKey: "Count"), 1)
        XCTAssertEqual(remaining.reference(forKey: "First"), tail)
        XCTAssertEqual(remaining.reference(forKey: "Last"), tail)
        XCTAssertNil(latest.objectSource(tail)?.reference(forKey: "Prev"))
        XCTAssertNil(try PdfOutlineIncrement.deleteBookmarkIncrement(normalizedData: deleted, id: "one"))
        let originalFile = try ClassicPdfFile(data: original)
        for number in 2..<originalFile.size {
            XCTAssertEqual(latest.rawObjectValue(number), originalFile.rawObjectValue(number), "object \(number)")
        }
    }

    func testNumericGeometryOnRotatedCorpus() throws {
        let bytes = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("rotated-all-angles"))
        let file = try ClassicPdfFile(data: bytes)
        // PDF (42, 714) relative to crop [24, 36, 576, 744].
        let expected = [(18.0, 30.0), (678, 18), (534, 678), (30, 534)]
        for (index, point) in expected.enumerated() {
            let page = try PageGeometry(pageNumber: index + 1, in: file)
            XCTAssertEqual(page.rotation, index * 90)
            XCTAssertEqual(page.displayWidth, index.isMultiple(of: 2) ? 552 : 708)
            XCTAssertEqual(page.displayHeight, index.isMultiple(of: 2) ? 708 : 552)
            let ui = page.pdfToUi(42, 714)
            XCTAssertEqual(ui.x, point.0)
            XCTAssertEqual(ui.y, point.1)
            let pdf = page.uiToPdf(point.0 * 2, point.1 * 2, pageWidth: page.displayWidth * 2, pageHeight: page.displayHeight * 2)
            XCTAssertEqual(pdf.x, 42)
            XCTAssertEqual(pdf.y, 714)
        }
    }

    func testIndirectInheritedGeometryAndNearestOverrides() throws {
        let bytes = PdfFixtureBuilder.classicObjects([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids 4 0 R /Count 1 /MediaBox 5 0 R /UserUnit 6 0 R /Rotate -90 >>",
            "<< /Type /Page /Parent 2 0 R /Resources << /CropBox [0 0 3 3] >> >>",
            "[3 0 R]", "[-20.5 7 7 0 R 107]", "2.5", "29.5"
        ])
        let file = try ClassicPdfFile(data: bytes)
        let page = try PageGeometry(pageNumber: 1, in: file)
        XCTAssertEqual(page.rotation, 270)
        XCTAssertEqual(page.displayWidth, 250)
        XCTAssertEqual(page.displayHeight, 125)
        let ui = page.pdfToUi(-18.5, 10)
        XCTAssertEqual(ui.x, 242.5)
        XCTAssertEqual(ui.y, 120)
        XCTAssertThrowsError(try PageGeometry(pageNumber: 2, in: file))
    }

    func testHybridIncrementKeepsRevisionLocalXrefStreamInOriginalTrailer() throws {
        // The hybrid's stream supplies a type-1 entry for the original Info.
        // The new hybrid revision replaces that same object.
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>", "<< /Title (old) >>"]
        let base = PdfFixtureBuilder.classicObjects(objects)
        let infoOffset = try XCTUnwrap(base.range(of: Data("4 0 obj".utf8))).lowerBound
        let row = String(format: "01%08X0000>", UInt32(infoOffset))
        let stream = "<< /Type /XRef /Size 6 /W [1 4 2] /Index [4 1] /Filter /ASCIIHexDecode /Length 15 >>\nstream\n\(row)\nendstream"
        var original = PdfFixtureBuilder.classicObjects(objects + [stream])
        let streamOffset = try XCTUnwrap(original.range(of: Data("5 0 obj".utf8))).lowerBound
        let root = try XCTUnwrap(original.range(of: Data("/Root 1 0 R".utf8)))
        original.insert(contentsOf: " /Info 4 0 R /ID [<1234><1234>] /XRefSt#6D \(streamOffset)".utf8, at: root.upperBound)
        let first = try ClassicPdfFile(data: original)
        XCTAssertEqual(first.trailer.integer(forKey: "XRefStm"), streamOffset)
        let updated = try PdfInfoIncrement.setMetadataIncrement(normalizedData: original, key: "title", value: "new")
        let file = try ClassicPdfFile(data: updated)
        XCTAssertTrue(updated.starts(with: original))
        XCTAssertGreaterThan(try XCTUnwrap(file.trailer.integer(forKey: "XRefStm")), first.startXref)
        XCTAssertEqual(file.trailer.integer(forKey: "Prev"), first.startXref)
        XCTAssertEqual(file.trailer.rawValue(forKey: "ID"), first.trailer.rawValue(forKey: "ID"))
        XCTAssertEqual(file.infoNumber.flatMap(file.objectSource)?.textString(forKey: "Title"), "new")
        #if canImport(CoreGraphics)
        let provider = try XCTUnwrap(CGDataProvider(data: updated as CFData))
        let document = try XCTUnwrap(CGPDFDocument(provider))
        var title: CGPDFStringRef?
        XCTAssertTrue(CGPDFDictionaryGetString(try XCTUnwrap(document.info), "Title", &title))
        XCTAssertEqual(CGPDFStringCopyTextString(try XCTUnwrap(title)) as String?, "new")
        #endif
    }

    func testNewestFreeEntryMasksOlderObjectAndCountsTowardSize() throws {
        let base = PdfFixtureBuilder.classicObjects(["<< >>", "<< /Title (old) >>"])
        let original = try ClassicPdfFile(data: base)
        func revision(size: String, previous: Int) -> Data {
            var data = base
            data.append(contentsOf: """
                xref
                0 1
                0000000002 65535 f \n2 1
                0000000000 00001 f \ntrailer
                << \(size) /Prev \(previous) /Root 1 0 R >>
                startxref
                \(base.count)
                %%EOF

                """.utf8)
            return data
        }
        let file = try ClassicPdfFile(data: revision(size: "/Size 3", previous: original.startXref))
        XCTAssertNotNil(file.objectSource(1))
        XCTAssertNil(file.objectSource(2))
        XCTAssertNil(file.rawObjectValue(2))
        var update = PdfIncrement(file: file)
        XCTAssertEqual(update.allocateObjectNumber(), 3)
        for size in ["", "/Size 0", "/Size -1", "/Size 2", "/Size 3.5", "/Size (3)", "/Size \(Int.max)"] {
            XCTAssertThrowsError(try ClassicPdfFile(data: revision(size: size, previous: original.startXref)), size)
        }
        XCTAssertThrowsError(try ClassicPdfFile(data: revision(size: "/Size 3", previous: base.count)))
    }

    func testNestedPdfValuesAndCommentedIndirectGeometry() throws {
        let array = "[null << /Contents (endobj >> \\(x\\) [) /Dict << /Hex <4142>>> >> % [ <<\r\n 8 % ]\n 0 R]"
        let bytes = PdfFixtureBuilder.classicObjects([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /Resources << /Nested << /Empty <>>>>> % ] >> (\n /MediaBox [100 +200 4 0 R -20.] /UserUnit 5 0 R /Annots 6 0 R /Rotate 7 0 R >>",
            "% >> endobj\n+.5 % endobj", "% comment\r1.5 % a comment", array, "% angle\n-90", "<< >>"
        ])
        let file = try ClassicPdfFile(data: bytes)
        let page = try PageGeometry(pageNumber: 1, in: file)
        XCTAssertEqual(page.left, 0.5)
        XCTAssertEqual(page.bottom, -20)
        XCTAssertEqual(page.rotation, 270)
        XCTAssertEqual(page.displayWidth, 330)
        XCTAssertEqual(page.displayHeight, 149.25)
        let raw = try XCTUnwrap(file.rawObjectValue(6))
        XCTAssertEqual(raw, Array(array.utf8))
        XCTAssertEqual(PdfArraySource.references(inArray: raw), [8])
        let pruned = try XCTUnwrap(PdfArraySource.removingElement(at: 1, fromArray: raw))
        XCTAssertEqual(PdfArraySource.elementSpans(inArray: pruned)?.count, 2)
        XCTAssertEqual(PdfArraySource.references(inArray: pruned), [8])
    }

    func testGeometryUsesPerCoordinateAndUnitDefaultsForNonPdfNumbers() throws {
        for invalid in ["inf", "nan", "-inf", "0x1p4", "1e3", "+.", "--1", String(repeating: "9", count: 400)] {
            let data = PdfFixtureBuilder.classicObjects([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [\(invalid) -5 \(invalid) 7] /UserUnit \(invalid) >>"
            ])
            let page = try PageGeometry(pageNumber: 1, in: ClassicPdfFile(data: data))
            XCTAssertEqual(page.left, 0, invalid)
            XCTAssertEqual(page.bottom, -5, invalid)
            XCTAssertEqual(page.displayWidth, 612, invalid)
            XCTAssertEqual(page.displayHeight, 12, invalid)
            XCTAssertEqual(page.userUnit, 1, invalid)
        }
    }
}
