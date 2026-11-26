import Foundation
import XCTest
#if canImport(PDFKit)
import PDFKit
#endif

final class PdfFixturesSanityTests: XCTestCase {
    func testBundledNonInkFixtures() throws {
        let generated = [
            "classic-two-column": PdfFixtureBuilder.twoColumnPdf(),
            "xref-stream-objstm": PdfFixtureBuilder.xrefStreamPdf(),
            "rotated-all-angles": PdfFixtureBuilder.rotatedPdf(),
            "foreign-annotations": PdfFixtureBuilder.foreignAnnotationsPdf()
        ]
        for (name, expected) in generated {
            XCTAssertEqual(try Data(contentsOf: PdfFixtureBuilder.fixtureURL(name)), expected, name)
        }
        for name in ["encrypted-user-pass", "digitally-signed"] {
            XCTAssertFalse(try Data(contentsOf: PdfFixtureBuilder.fixtureURL(name)).isEmpty, name)
        }
    }

    #if canImport(PDFKit)
    func testNonInkFixturesInPDFKit() throws {
        for name in ["classic-two-column", "xref-stream-objstm", "encrypted-user-pass",
                     "digitally-signed", "rotated-all-angles", "foreign-annotations"] {
            let url = try PdfFixtureBuilder.fixtureURL(name)
            let document = try XCTUnwrap(PDFDocument(url: url), name)
            if name == "encrypted-user-pass" {
                XCTAssertTrue(document.isLocked)
                XCTAssertFalse(document.unlock(withPassword: ""))
                XCTAssertFalse(document.unlock(withPassword: "wrong"))
                XCTAssertTrue(document.unlock(withPassword: "vellum"))
            }
            XCTAssertEqual(document.pageCount, name == "rotated-all-angles" ? 4 : 1, name)
            for index in 0..<document.pageCount {
                let page = try XCTUnwrap(document.page(at: index), name)
                if name == "rotated-all-angles" {
                    XCTAssertEqual(page.rotation, index * 90)
                    XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 24, y: 36, width: 552, height: 708))
                }
                if name == "foreign-annotations" {
                    XCTAssertEqual(page.annotations.compactMap(\.type), ["Highlight", "FreeText", "Link"])
                }
            }
        }
    }

    func testGeneratedAnnotationLayoutsAndNonzeroGenerationOpen() throws {
        for layout in [PdfFixtureBuilder.AnnotsLayout.absent, .inlineEmpty, .indirectEmpty, .withForeignInline] {
            let data = PdfFixtureBuilder.makeClassicPdf(pages: [.init()], annotsLayout: layout, generation: 3)
            let document = try XCTUnwrap(PDFDocument(data: data))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(page.annotations.count, layout == .withForeignInline ? 3 : 0)
        }
    }
    #endif
}
