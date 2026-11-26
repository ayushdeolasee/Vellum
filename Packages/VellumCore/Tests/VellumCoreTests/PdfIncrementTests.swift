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
}
