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

    func testAnnotationRevisionPreservesOnlyTheVerifiedStorageKey() throws {
        let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
        let key = DocumentIdentity.byteHash(original)
        let note = PdfAnnotationEdit.create(.init(type: .note, pageNumber: 1, content: "Saved", id: "note"))
        let stamped = try PdfAnnotationIncrement.applying(note, to: original, now: now, preservingStorageKey: key)
        XCTAssertTrue(stamped.starts(with: original))
        XCTAssertEqual(SharedPDFIdentity.stamp(in: stamped, readerID: key), key)
        XCTAssertEqual(try read(stamped).first?.content, "Saved")
        let update = PdfAnnotationEdit.update(.init(id: "note", content: "Updated"))
        let next = try PdfAnnotationIncrement.applying(update, to: stamped, now: now, preservingStorageKey: key)
        let info = try XCTUnwrap(ClassicPdfFile(data: stamped).infoNumber)
        XCTAssertEqual(try ClassicPdfFile(data: next).objectOffsets[info], try ClassicPdfFile(data: stamped).objectOffsets[info])
        XCTAssertThrowsError(try PdfAnnotationIncrement.applying(note, to: original, now: now, preservingStorageKey: "12345678"))
        XCTAssertThrowsError(try PdfAnnotationIncrement.applying(update, to: stamped, now: now,
                                                                  preservingStorageKey: DocumentIdentity.byteHash(stamped)))
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

    func testForeignRichNoteEditsAndPDFTextEncodings() throws {
        for subtype in ["Text", "FreeText", "Highlight"] {
            let original = PdfFixtureBuilder.classicObjects([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [null 4 0 R] >>",
                "<< /Subtype /\(subtype) /Rect [0 0 20 20] /Contents <188093A0> /RC 5 0 R /VellumSelectedText <EFBBBFE69DB1E4BAAC> >>",
                "(old rich contents)"
            ])
            let foreign = try XCTUnwrap(read(original).first)
            XCTAssertEqual(foreign.content, "˘•ﬁ€")
            XCTAssertEqual(foreign.positionData?.selectedText, "東京")
            XCTAssertEqual(foreign.id, "pdf-direct-1-1")
            let pinned = try apply(.update(.init(id: foreign.id, isPinned: true)), original)
            let (pinnedFile, pinnedPage) = try page(pinned)
            XCTAssertEqual(pinnedPage.slot(1, file: pinnedFile)?.dictionary.reference(forKey: "RC"), 5)
            let changed = try apply(.update(.init(id: foreign.id, content: "new Ω")), pinned)
            let (file, edited) = try page(changed)
            XCTAssertFalse(try XCTUnwrap(edited.slot(1, file: file)).dictionary.hasKey("RC"))
            XCTAssertEqual(try read(changed).first?.content, "new Ω")
            XCTAssertEqual(file.rawObjectValue(5), pinnedFile.rawObjectValue(5))
            let deleted = try apply(.delete(id: foreign.id), changed)
            XCTAssertTrue(try read(deleted).isEmpty)
            XCTAssertNotNil(deleted.range(of: Data("(old rich contents)".utf8)))
            XCTAssertNotNil(deleted.range(of: Data(PdfTextString.encode("new Ω"))))
        }
        XCTAssertEqual(PdfDictSource.decodeTextString(Array(#"(\204)"#.utf8)), "—")
        for invalid in ["/NotAString", "<< /Fake (id) >>", "<not-hex>", "<EFBBBF80>"] {
            XCTAssertNil(PdfDictSource.decodeTextString(Array(invalid.utf8)))
        }
    }

    func testLiteralEndobjInAnnotationContentSurvivesAnotherEdit() throws {
        let original = PdfFixtureBuilder.twoColumnPdf()
        let content = #"Private note: (endobj) followed by \ and more text."#
        let literal = Array(#"(Private note: \(endobj\) followed by \\ and more text.)"#.utf8)
        XCTAssertEqual(PdfEditEligibility.classify(original), .editable)
        let created = try apply(.create(.init(type: .note, pageNumber: 1, content: content, id: "note")), original)
        let pinned = try apply(.update(.init(id: "note", isPinned: true)), created)
        for bytes in [created, pinned] {
            let (file, annotations) = try page(bytes)
            let slot = try XCTUnwrap(annotations.slot(0, file: file))
            XCTAssertEqual(file.rawObjectValue(try XCTUnwrap(slot.object)), slot.dictionary.sourceBytes)
            XCTAssertEqual(slot.dictionary.rawValue(forKey: "Contents"), literal)
            XCTAssertEqual(try read(bytes).first?.content, content)
        }
        XCTAssertEqual(try read(pinned).first?.isPinned, true)
    }

    func testUTF8BOMIsDisplayTextButCannotIdentifyAnAnnotation() throws {
        func fixture(nm: String) -> Data {
            PdfFixtureBuilder.classicObjects([
                "<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 100 100] /Annots [4 0 R] >>",
                "<< /Subtype /Text /Rect [1 2 3 4] /Contents <EFBBBF616263> /NM \(nm) >>"
            ])
        }
        for raw in ["<EFBBBF616263>", #"(\357\273\277abc)"#] {
            let pdf = fixture(nm: raw)
            XCTAssertEqual(PdfEditEligibility.classify(pdf), .readOnly(.ambiguousAnnotation))
            XCTAssertThrowsError(try read(pdf)) { XCTAssertEqual($0 as? PdfReadOnlyReason, .ambiguousAnnotation) }
            for id in ["abc", "ï»¿abc", "pdf-direct-1-0"] {
                XCTAssertThrowsError(try apply(.update(.init(id: id, content: "replacement")), pdf))
            }
        }
        for nm in ["(abc)", "<FEFF006100620063>"] {
            let record = try XCTUnwrap(read(fixture(nm: nm)).first)
            XCTAssertEqual(record.id, "abc")
            XCTAssertEqual(record.content, "abc")
        }
    }

    func testTinyCoordinatesReportGeometryInsteadOfAProofLimit() throws {
        let data = PdfFixtureBuilder.makeClassicPdf(pages: [.init()])
        func edit(x: Double) -> PdfAnnotationEdit {
            let position = PositionData(rects: [.init(x: x, y: 5, width: 1, height: 1)], pageWidth: 612, pageHeight: 792)
            return .create(.init(type: .note, pageNumber: 1, positionData: position, id: "tiny"))
        }
        XCTAssertThrowsError(try apply(edit(x: 1e-300), data)) {
            XCTAssertEqual($0 as? PdfReadOnlyReason, .unsupportedGeometry)
        }
        let result = try apply(edit(x: 1e-8), data)
        let anchor = try XCTUnwrap(read(result).first?.positionData?.rects.first)
        XCTAssertEqual(anchor.x, 1e-8, accuracy: 1e-20)
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
                let deleted = try apply(.delete(id: "exchange-note"), output)
                let (final, survivors) = try page(deleted)
                XCTAssertEqual(survivors.spans.count, before.spans.count + 1)
                for index in before.spans.indices {
                    let object = try XCTUnwrap(before.slot(index, file: file)?.object)
                    XCTAssertEqual(survivors.slot(index, file: final)?.object, object)
                    XCTAssertEqual(final.objectOffsets[object], file.objectOffsets[object])
                }
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
        XCTAssertThrowsError(try apply(.create(.init(type: .note, pageNumber: 1)), data))
        XCTAssertThrowsError(try apply(.create(.init(type: .bookmark, pageNumber: 1, id: "b")), data))
        let position = PositionData(rects: [.init(x: .nan, y: 0, width: 1, height: 1)], pageWidth: 1, pageHeight: 1)
        XCTAssertThrowsError(try apply(.create(.init(type: .highlight, pageNumber: 1, positionData: position, id: "x")), data))
    }
}
