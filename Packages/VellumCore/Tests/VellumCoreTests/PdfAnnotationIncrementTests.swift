import Foundation
import XCTest
@testable import VellumCore

final class PdfAnnotationIncrementTests: XCTestCase {
    private let now = "2026-11-26T12:34:56.000000+00:00"
    private let rect = AnnotationRect(x: 40, y: 60, width: 70, height: 12)

    private func apply(_ edit: PdfAnnotationEdit, _ original: Data) throws -> Data {
        let next = try PdfAnnotationIncrement.applying(edit, to: original, now: now)
        XCTAssertTrue(next.starts(with: original))
        return next
    }

    private func page(_ original: Data, _ index: Int = 1) throws -> (ClassicPdfFile, PdfAnnotationPage) {
        let file = try ClassicPdfFile(data: original)
        let catalog = try XCTUnwrap(file.objectSource(XCTUnwrap(file.rootNumber)))
        let n = try XCTUnwrap(PdfOutlineIncrement.pageObjectNumber(in: file, catalog: catalog, pageNumber: index))
        return (file, try PdfAnnotationPage(index: index, number: n, dictionary: XCTUnwrap(file.objectSource(n)), file: file))
    }

    private func read(_ original: Data, _ index: Int = 1) throws -> [Annotation] {
        try PdfAnnotationPureReader.annotations(on: index, in: original, now: now)
    }

    func testAllArrayFormsAndRotations() throws {
        for layout in [PdfFixtureBuilder.AnnotsLayout.absent, .inlineEmpty, .indirectEmpty] {
            let pages = [0, 90, 180, 270].map { PdfFixtureBuilder.Page(rotation: $0) }
            var data = PdfFixtureBuilder.makeClassicPdf(pages: pages, cropBox: (24, 36, 576, 744), annotsLayout: layout)
            for index in 1...4 {
                let g = try PageGeometry(pageNumber: index, in: ClassicPdfFile(data: data))
                let position = PositionData(rects: [rect], pageWidth: g.displayWidth, pageHeight: g.displayHeight, selectedText: "選択")
                for type in [AnnotationType.highlight, .note] {
                    let id = "new"
                    data = try apply(.create(.init(type: type, pageNumber: index, positionData: position, id: id)), data)
                    data = try apply(.update(.init(id: id, color: "#ab1234", content: "編集", isPinned: true)), data)
                    let record = try XCTUnwrap(read(data, index).first)
                    XCTAssertEqual(record.id, id)
                    XCTAssertEqual(record.color, "#ab1234")
                    XCTAssertEqual(record.content, "編集")
                    XCTAssertTrue(record.pinned)
                    XCTAssertEqual(record.positionData?.selectedText, "選択")
                    XCTAssertEqual(record.positionData?.rects, [type == .highlight ? rect : .init(x: 40, y: 60, width: 0, height: 0)])
                    let (file, page) = try page(data, index)
                    let dict = try XCTUnwrap(page.slot(0, file: file)?.dictionary)
                    XCTAssertEqual(dict.integer(forKey: "F"), 4)
                    XCTAssertEqual(dict.textString(forKey: "T"), "Vellum")
                    XCTAssertEqual(dict.textString(forKey: "M"), "D:20261126123456Z")
                    XCTAssertEqual(dict.textString(forKey: "VellumCreatedAt"), now)
                    XCTAssertEqual(dict.textString(forKey: "VellumUpdatedAt"), now)
                    if type == .highlight {
                        XCTAssertEqual(dict.rawValue(forKey: "CA"), Array("0.4".utf8))
                        let array = try XCTUnwrap(dict.inlineArray(forKey: "QuadPoints"))
                        let points = try XCTUnwrap(PdfArraySource.elementSpans(inArray: array)).compactMap { Double(String(decoding: array[$0], as: UTF8.self)) }
                        let expected = [(40,60),(110,60),(40,72),(110,72)].flatMap { x, y -> [Double] in
                            let point = g.uiToPdf(Double(x), Double(y), pageWidth: g.displayWidth, pageHeight: g.displayHeight)
                            return [point.x, point.y]
                        }
                        XCTAssertEqual(points, expected)
                    } else { XCTAssertEqual(dict.name(forKey: "Name"), "Note") }
                    let moved = PositionData(rects: [.init(x: 60, y: 80, width: 80, height: 12)],
                                             pageWidth: g.displayWidth * 2, pageHeight: g.displayHeight * 2,
                                             selectedText: "resized")
                    data = try apply(.update(.init(id: id, positionData: moved, isPinned: false)), data)
                    let result = try XCTUnwrap(read(data, index).first)
                    XCTAssertFalse(result.pinned)
                    XCTAssertEqual(result.positionData?.selectedText, "resized")
                    XCTAssertEqual(result.positionData?.rects, [.init(x: 30, y: 40, width: type == .highlight ? 40 : 0,
                                                                     height: type == .highlight ? 6 : 0)])
                    data = try apply(.delete(id: id), data)
                    XCTAssertTrue(try read(data, index).isEmpty)
                }
            }
        }
    }

    func testRawForeignSlotAndIdentitySurviveEarlierDeletion() throws {
        let original = PdfFixtureBuilder.foreignAnnotationsPdf()
        let (first, old) = try page(original)
        let freeText = try XCTUnwrap(old.slot(2, file: first))
        let link = try XCTUnwrap(old.slot(3, file: first))
        let removed = try apply(.delete(id: "pdf-direct-1-0"), original)
        let (next, slots) = try page(removed)
        XCTAssertEqual(slots.spans.count, 4)
        XCTAssertEqual(slots.slot(2, file: next)?.dictionary.sourceBytes, freeText.dictionary.sourceBytes)
        XCTAssertEqual(try read(removed).map(\.id), ["pdf-direct-1-2"])
        let changed = try apply(.update(.init(id: "pdf-direct-1-2", content: "改訂")), removed)
        let (file, updated) = try page(changed)
        let dict = try XCTUnwrap(updated.slot(2, file: file)?.dictionary)
        XCTAssertEqual(dict.textString(forKey: "NM"), "pdf-direct-1-2")
        XCTAssertEqual(dict.textString(forKey: "Contents"), "改訂")
        XCTAssertEqual(dict.rawValue(forKey: "DA"), freeText.dictionary.rawValue(forKey: "DA"))
        XCTAssertEqual(updated.slot(3, file: file)?.dictionary.sourceBytes, link.dictionary.sourceBytes)
        XCTAssertThrowsError(try apply(.delete(id: "pdf-direct-1-3"), changed))
        XCTAssertThrowsError(try apply(.create(.init(type: .note, pageNumber: 1, id: "pdf-direct-1-2")), changed))
    }

    func testDeletingAdjacentDirectDictionaryKeepsTokenBoundaries() throws {
        let data = PdfFixtureBuilder.classicObjects([
            "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Count 1 /Kids [3 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [4 0 R<</Subtype/Text/NM(remove)/Rect[0 0 1 1]>>5 0 R] >>",
            "<< /Subtype /Text /NM (before) /Rect [1 2 3 4] >>", "<< /Subtype /Text /Rect [4 5 6 7] >>"
        ])
        let deleted = try apply(.delete(id: "remove"), data)
        XCTAssertEqual(try read(deleted).map(\.id), ["before", "pdf-direct-1-2"])
    }

    // These two originals were written by macOS PDFKit and the hosted iPad
    // PdfInk.apply fixture exporter. Export once inside Linux, then compare
    // with the checked-in bytes in every ordinary test run.
    func testAppleSourcesAndLinuxExchangeBytes() throws {
        for (platform, source) in [("ipad", "ipad-vellum-ink"), ("mac", "mac-annotation-source")] {
            let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL(source))
            let (file, before) = try page(original)
            if platform == "mac" {
                let note = try XCTUnwrap(read(original).first)
                XCTAssertEqual(note.id, "mac-existing")
                XCTAssertEqual(note.content, "Mac source note")
            }
            let g = try PageGeometry(pageNumber: 1, in: file)
            let pos = PositionData(rects: [rect], pageWidth: g.displayWidth, pageHeight: g.displayHeight, selectedText: "Café 東京")
            let created = try apply(.create(.init(type: .highlight, pageNumber: 1, color: "#1256ab",
                                                  content: "Linux", positionData: pos, id: "exchange-highlight")), original)
            let pinned = try apply(.update(.init(id: "exchange-highlight", isPinned: true)), created)
            let output = try apply(.create(.init(type: .note, pageNumber: 1, content: "Linux note", positionData: pos,
                                                 id: "exchange-note")), pinned)
            let (latest, after) = try page(output)
            // Even a byte-identical prefix could be shadowed by a later xref.
            // Only the old /Annots owner may point to a new object definition.
            let arrayOwner = before.arrayNumber ?? before.number
            for (number, offset) in file.objectOffsets where number != arrayOwner {
                XCTAssertEqual(latest.objectOffsets[number], offset)
            }
            for index in before.spans.indices {
                XCTAssertEqual(before.array[before.spans[index]], after.array[after.spans[index]])
                XCTAssertEqual(before.slot(index, file: file)?.dictionary.sourceBytes, after.slot(index, file: latest)?.dictionary.sourceBytes)
            }
            if platform == "ipad" {
                XCTAssertThrowsError(try apply(.delete(id: "pdf-direct-1-1"), output))
                XCTAssertThrowsError(try apply(.update(.init(id: "pdf-direct-1-2", content: "x")), output))
            }
            let name = "linux-on-" + platform
            if let directory = ProcessInfo.processInfo.environment["VELLUM_ANNOTATION_FIXTURE_EXPORT"] {
                try output.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".pdf"))
            } else {
                XCTAssertEqual(output, try Data(contentsOf: PdfFixtureBuilder.fixtureURL(name)))
            }
        }
    }

    func testReadsMacHostedReplyToLinuxEdits() throws { try checkReply(from: "mac") }

    private func checkReply(from platform: String) throws {
        let reply = try Data(contentsOf: PdfFixtureBuilder.fixtureURL(platform + "-annotation-reply"))
        let records = try read(reply)
        XCTAssertEqual(records.map(\.id).sorted(), ["exchange-highlight", "exchange-note", "mac-existing"])
        let note = try XCTUnwrap(records.first { $0.id == "exchange-note" })
        XCTAssertEqual(note.type, .note)
        XCTAssertEqual(note.content, "Apple reply 東京")
        XCTAssertEqual(note.pinned, true)
        XCTAssertEqual(note.positionData?.rects, [.init(x: 40, y: 60, width: 0, height: 0)])
        let highlight = try XCTUnwrap(records.first { $0.id == "exchange-highlight" })
        XCTAssertEqual(highlight.positionData?.selectedText, "Café 東京")
        XCTAssertEqual(highlight.positionData?.rects, [rect])
        XCTAssertEqual(highlight.color, "#1256ab")
        XCTAssertEqual(highlight.content, "Linux")
        XCTAssertTrue(highlight.pinned)
        XCTAssertEqual(records.first { $0.id == "mac-existing" }?.content, "Mac source note")
    }

    func testIneligibleOriginalsAndInvalidEdits() throws {
        let edit = PdfAnnotationEdit.create(.init(type: .note, pageNumber: 1, id: "one"))
        for name in ["xref-stream-objstm", "digitally-signed", "encrypted-user-pass"] {
            let data = try Data(contentsOf: PdfFixtureBuilder.fixtureURL(name))
            XCTAssertThrowsError(try apply(edit, data))
        }
        let data = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
        XCTAssertThrowsError(try apply(.delete(id: "missing"), data))
        XCTAssertThrowsError(try apply(.create(.init(type: .bookmark, pageNumber: 1, id: "b")), data))
        let position = PositionData(rects: [.init(x: .nan, y: 0, width: 1, height: 1)], pageWidth: 1, pageHeight: 1)
        XCTAssertThrowsError(try apply(.create(.init(type: .highlight, pageNumber: 1, positionData: position, id: "x")), data))
    }
}
