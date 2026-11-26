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
                let documentID = "3ad19a84-fd80-47e6-af2f-b0ee0b8e5757"
                let stamped = try PdfInfoIncrement.setMetadataIncrement(
                    normalizedData: Data(contentsOf: url), key: "doc_id", value: documentID)
                try stamped.write(to: copy)
                defer { try? FileManager.default.removeItem(at: copy) }
                let session = try await PdfSessionBackend().open(path: copy.path, sessionId: UUID().uuidString)
                let updated = try await session.updateAnnotation(.init(id: note.id, content: "Apple reply 東京", isPinned: true))
                XCTAssertTrue(updated)
                let reply = try await session.readPdfBytes()
                try await session.close()
                let returned = try XCTUnwrap(PdfDocumentLoader.cgDocument(from: reply))
                defer { withExtendedLifetime(returned) {} }
                XCTAssertEqual(SharedPDFIdentity.stamp(in: reply, readerID: PdfMetadata.documentId(returned)), documentID)
                let returnedPage = try XCTUnwrap(returned.page(at: 1)?.dictionary)
                let returnedSlots = try XCTUnwrap(CgPdf.array(returnedPage, "Annots"))
                XCTAssertEqual(CgPdf.count(returnedSlots), 3)
                let foreign = try XCTUnwrap(CgPdf.dictionaryAt(returnedSlots, 0))
                let originalForeign = try XCTUnwrap(CgPdf.dictionaryAt(entries, 0))
                XCTAssertEqual(CgPdf.string(foreign, "NM"), "mac-existing")
                XCTAssertEqual(CgPdf.string(foreign, "Contents"), "Mac source note")
                XCTAssertEqual(CgPdf.string(foreign, "T"), CgPdf.string(originalForeign, "T"))
                for key in ["VellumCreatedAt", "VellumUpdatedAt", "VellumSelectedText", "VellumPinned"] {
                    XCTAssertFalse(CgPdf.has(foreign, key), key)
                }
                XCTAssertEqual(try coordinates(foreign), [50, 63, 68, 81])
                let returnedNote = try XCTUnwrap(CgPdf.dictionaryAt(returnedSlots, 2))
                XCTAssertEqual(try coordinates(returnedNote), [84, 76, 102, 94])
                let readback = PdfAnnotationReader.annotations(onPage: returnedPage, pageNumber: 1, geometry: geometry)
                XCTAssertEqual(readback.map(\.id), ["mac-existing", "exchange-highlight", "exchange-note"])
                XCTAssertEqual(readback.first { $0.id == highlight.id }, highlight)
                let editedNote = try XCTUnwrap(readback.first { $0.id == note.id })
                XCTAssertEqual(editedNote.positionData, note.positionData)
                XCTAssertEqual(editedNote.content, "Apple reply 東京")
                XCTAssertTrue(editedNote.pinned)
                let attachment = XCTAttachment(data: reply, uniformTypeIdentifier: "com.adobe.pdf")
                attachment.name = "apple-annotation-reply.pdf"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    private func coordinates(_ dictionary: CGPDFDictionaryRef) throws -> [Double] {
        let array = try XCTUnwrap(CgPdf.array(dictionary, "Rect"))
        return try (0..<CgPdf.count(array)).map { try XCTUnwrap(CgPdf.numberAt(array, $0)) }
    }

    func testSessionMatchesSameContentAndHonorsRequestedNoteMove() async throws {
        // The first note's literal name looks derived. The second really is unnamed.
        let bytes = PdfFixtureBuilder.classicObjects([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /CropBox [24 36 576 744] /Rotate 90 /Annots [4 0 R 5 0 R] >>",
            "<< /Type /Annot /Subtype /Text /Rect [50.5 63.25 68.5 81.25] /NM (pdf-direct-1-0) /T (A) /Contents (same) >>",
            "<< /Type /Annot /Subtype /Text /Rect [84 76 102 94] /T (B) /Contents (same) >>"
        ])
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try bytes.write(to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }
        let session = try await PdfSessionBackend().open(path: copy.path, sessionId: UUID().uuidString)
        let pinned = try await session.updateAnnotation(.init(id: "pdf-direct-1-0", isPinned: true))
        XCTAssertTrue(pinned)
        let firstSave = try await session.readPdfBytes()
        let first = try XCTUnwrap(PdfDocumentLoader.cgDocument(from: firstSave))
        defer { withExtendedLifetime(first) {} }
        let entries = try XCTUnwrap(CgPdf.array(XCTUnwrap(first.page(at: 1)?.dictionary), "Annots"))
        let named = try XCTUnwrap(CgPdf.dictionaryAt(entries, 0))
        let unnamed = try XCTUnwrap(CgPdf.dictionaryAt(entries, 1))
        XCTAssertEqual(CgPdf.string(named, "NM"), "pdf-direct-1-0")
        XCTAssertEqual(CgPdf.string(named, "T"), "A")
        XCTAssertEqual(CgPdf.integer(named, "VellumPinned"), 1)
        XCTAssertEqual(try coordinates(named), [50.5, 63.25, 68.5, 81.25])
        XCTAssertFalse(CgPdf.has(unnamed, "NM"))
        XCTAssertFalse(CgPdf.has(unnamed, "VellumPinned"))
        XCTAssertEqual(CgPdf.string(unnamed, "T"), "B")
        XCTAssertEqual(try coordinates(unnamed), [84, 76, 102, 94])

        let moved = try await session.updateAnnotation(.init(id: "pdf-direct-1-1", positionData:
            .init(rects: [.init(x: 100, y: 80, width: 0, height: 0)], pageWidth: 708, pageHeight: 552)))
        XCTAssertTrue(moved)
        let secondSave = try await session.readPdfBytes()
        try await session.close()
        let second = try XCTUnwrap(PdfDocumentLoader.cgDocument(from: secondSave))
        defer { withExtendedLifetime(second) {} }
        let final = try XCTUnwrap(CgPdf.array(XCTUnwrap(second.page(at: 1)?.dictionary), "Annots"))
        let edited = try XCTUnwrap(CgPdf.dictionaryAt(final, 1))
        XCTAssertEqual(CgPdf.string(edited, "NM"), "pdf-direct-1-1")
        XCTAssertEqual(CgPdf.string(edited, "T"), "B")
        XCTAssertEqual(try coordinates(edited), [104, 136, 122, 154])
        XCTAssertEqual(try coordinates(XCTUnwrap(CgPdf.dictionaryAt(final, 0))), [50.5, 63.25, 68.5, 81.25])

        if pdfKitDropsCustomKeys {
            // Force the ambiguous output deterministically, independent of whether
            // this runtime happens to retain /NM for a particular source PDF.
            func twins(named: Bool) -> Data {
                let page = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R 5 0 R] >>"
                let notes = ["one", "two"].map { id in
                    let name = named ? "/NM (\(id))" : ""
                    return "<< /Type /Annot /Subtype /Text /Rect [10 20 34 44] /Contents (same) \(name) >>"
                }
                return PdfFixtureBuilder.classicObjects([
                    "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>", page
                ] + notes)
            }
            let source = twins(named: true)
            try source.write(to: copy)
            XCTAssertThrowsError(try PdfDocumentSession.persistPdfKitRewrite(
                twins(named: false), preservingMetadataFrom: source, path: copy.path))
            XCTAssertEqual(try Data(contentsOf: copy), source)
        }
    }
}
