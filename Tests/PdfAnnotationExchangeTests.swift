import CoreGraphics
import PDFKit
import VellumCore
import XCTest
@testable import Vellum
#if os(iOS)
import PencilKit
#endif

@MainActor
final class PdfAnnotationExchangeTests: XCTestCase {
    func testHostedReaderPreservesModernLinuxExchangeAcrossDeletions() async throws {
        let (original, exchange) = try await Task.detached {
            let source = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("xref-stream-objstm"))
            let result = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("linux-modern-exchange"))
            return (source, result)
        }.value
        XCTAssertTrue(exchange.starts(with: original))
        XCTAssertEqual(VellumCore.DocumentIdentity.byteHash(exchange), "0affacfdd2b60f79ef96c569e161ecf55f6ee91dee96324d14bb5e11d8b312ba")

        // Each prefix ends after a complete Linux revision and opens independently.
        let revisions = [(4734, ["mark-highlight", "mark-note"]), (5067, ["mark-note"]), (5395, [])]
        for (length, ids) in revisions {
            let bytes = exchange.prefix(length)
            let doc = try XCTUnwrap(PDFDocument(data: bytes))
            let raw = try XCTUnwrap(doc.documentRef)
            defer { withExtendedLifetime(raw) {} }
            let info = try XCTUnwrap(raw.info)
            let stamp = SharedPDFIdentity.stamp(in: bytes, readerID: CgPdf.string(info, "VellumDocId"))
            XCTAssertEqual(stamp, "aaabcde0-1234-4000-a456-abcdef012345")
            XCTAssertEqual(CgPdf.string(info, "Title"), "Final title")
            XCTAssertEqual(CgPdf.integer(info, "VellumLastPage"), 1)
            XCTAssertEqual(doc.pageCount, 1)
            let page = try XCTUnwrap(doc.page(at: 0))
            let root = try XCTUnwrap(doc.outlineRoot)
            XCTAssertEqual(root.numberOfChildren, 1)
            let bookmark = try XCTUnwrap(root.child(at: 0))
            XCTAssertEqual(bookmark.label, "Final mark")
            XCTAssertEqual(bookmark.destination?.page, page)
            let text = await PdfTextReader(data: bytes).text(pageNumber: 1)
            XCTAssertEqual(text, "Compressed page dictionary")

            let dictionary = try XCTUnwrap(raw.page(at: 1)?.dictionary)
            let geometry = try PageGeometry(pageDictionary: dictionary)
            let records = PdfAnnotationReader.annotations(onPage: dictionary, pageNumber: 1, geometry: geometry)
            XCTAssertEqual(records.map(\.id), ids)
            XCTAssertEqual(page.annotations.map(\.contents), records.map(\.content))
            for record in records {
                XCTAssertEqual(record.positionData?.selectedText, "selection")
                if record.id == "mark-highlight" {
                    XCTAssertEqual(record.type, .highlight)
                    XCTAssertEqual(record.content, "highlight")
                    XCTAssertEqual(record.color, "#1256ab")
                    XCTAssertTrue(record.pinned)
                    XCTAssertEqual(record.positionData?.rects, [.init(x: 10, y: 12, width: 48, height: 10)])
                    XCTAssertEqual(page.annotations.first?.quadrilateralPoints?.count, 4)
                } else {
                    XCTAssertEqual(record.type, .note)
                    XCTAssertEqual(record.content, "updated")
                    XCTAssertEqual(record.color, "#fde68a")
                    XCTAssertEqual(record.positionData?.rects, [.init(x: 10, y: 12, width: 0, height: 0)])
                }
            }
        }
    }

    func testHostedReaderOpensLinuxEditsAndExportsAppleReply() async throws {
        for platform in ["ipad", "mac"] {
            let url = try PdfFixtureBuilder.fixtureURL("linux-on-" + platform)
            let doc = try XCTUnwrap(PDFDocument(url: url))
            let page = try XCTUnwrap(doc.page(at: 0))
            let raw = try XCTUnwrap(CGPDFDocument(url as CFURL))
            defer { withExtendedLifetime(raw) {} }
            let dictionary = try XCTUnwrap(raw.page(at: 1)?.dictionary)
            let geometry = try PageGeometry(pageDictionary: dictionary)
            let records = PdfAnnotationReader.annotations(onPage: dictionary, pageNumber: 1, geometry: geometry)
            let highlight = try XCTUnwrap(records.first { $0.id == "exchange-highlight" })
            XCTAssertEqual(highlight.type, .highlight)
            XCTAssertEqual(highlight.color, "#1256ab")
            XCTAssertEqual(highlight.content, "Linux")
            XCTAssertEqual(highlight.positionData?.rects, [.init(x: 40, y: 60, width: 70, height: 12)])
            XCTAssertEqual(highlight.positionData?.selectedText, "Café 東京")
            XCTAssertTrue(highlight.pinned)
            XCTAssertEqual(highlight.createdAt, "2026-11-26T12:34:56.000000+00:00")
            XCTAssertEqual(highlight.updatedAt, highlight.createdAt)
            let note = try XCTUnwrap(records.first { $0.id == "exchange-note" })
            XCTAssertEqual(note.type, .note)
            XCTAssertEqual(note.content, "Linux note")
            XCTAssertEqual(note.positionData?.rects, [.init(x: 40, y: 60, width: 0, height: 0)])
            let entries = try XCTUnwrap(CgPdf.array(dictionary, "Annots"))
            let count = CgPdf.count(entries)
            let h = try XCTUnwrap(CgPdf.dictionaryAt(entries, count - 2))
            let n = try XCTUnwrap(CgPdf.dictionaryAt(entries, count - 1))
            let opacity = try XCTUnwrap(CgPdf.object(h, "CA"))
            XCTAssertEqual(CGPDFObjectGetType(opacity), .real)
            XCTAssertEqual(CgPdf.objectNumber(opacity), 0.4)
            XCTAssertEqual(CgPdf.integer(h, "VellumPinned"), 1)
            XCTAssertEqual(CgPdf.name(n, "Name"), "Note")
            XCTAssertEqual(CgPdf.integer(n, "F"), 4)
            XCTAssertEqual(CgPdf.string(n, "T"), "Vellum")
            XCTAssertEqual(CgPdf.string(n, "M"), "D:20261126123456Z")
            if platform == "ipad" {
                let original = try PdfFixtureBuilder.fixtureURL("ipad-vellum-ink")
                let ink = try XCTUnwrap(PDFDocument(url: original)?.page(at: 0))
                let key = PDFAnnotationKey(rawValue: "VellumInk")
                let payload = try XCTUnwrap(ink.annotations[1].value(forAnnotationKey: key) as? String)
                XCTAssertEqual(page.annotations.count, 5)
                XCTAssertEqual(page.annotations[1].value(forAnnotationKey: key) as? String, payload)
                XCTAssertEqual(page.annotations[2].value(forAnnotationKey: key) as? String, "1")
                #if os(iOS)
                XCTAssertEqual(try XCTUnwrap(PdfInk.drawing(on: page)).strokes.count, 2)
                #endif
            } else {
                XCTAssertEqual(page.rotation, 90)
                XCTAssertEqual(page.bounds(for: .cropBox), CGRect(x: 24, y: 36, width: 552, height: 708))
                XCTAssertEqual(records.first?.id, "mac-existing")
                XCTAssertEqual(records.first?.content, "Mac source note")

                // Send a fresh Apple-app edit back across the boundary. Each
                // host exports its own reply as a retained XCTest attachment.
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
                try FileManager.default.copyItem(at: url, to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }
                let session = try await PdfSessionBackend().open(path: copy.path, sessionId: UUID().uuidString)
                let updated = try await session.updateAnnotation(.init(id: note.id, content: "Apple reply 東京", isPinned: true))
                XCTAssertTrue(updated)
                let reply = try await session.readPdfBytes()
                try await session.close()
                let attachment = XCTAttachment(data: reply, uniformTypeIdentifier: "com.adobe.pdf")
                attachment.name = "apple-annotation-reply.pdf"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }
}
