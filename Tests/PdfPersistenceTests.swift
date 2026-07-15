import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import Vellum

/// MainActor-isolated box for sampling the largest scheduling gap observed while
/// a write runs (Task closures are `@Sendable` and can't capture a mutable var).
@MainActor
private final class GapTracker {
    var maxGap: Double = 0
    func record(_ gap: Double) { maxGap = max(maxGap, gap) }
}

@MainActor
final class HighlightResizeTests: XCTestCase {
    private func textPage(_ string: String = "The quick brown fox jumps over the lazy dog") -> PDFPage {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributed = CFAttributedStringCreate(
            nil,
            string as CFString,
            [kCTFontAttributeName: font] as CFDictionary)!
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)!.page(at: 0)!
    }

    private func position(for range: NSRange, on page: PDFPage) -> PositionData {
        let selection = page.selection(for: range)!
        let rects = selection.selectionsByLine().compactMap { line -> AnnotationRect? in
            guard let linePage = line.pages.first else { return nil }
            return PdfTextLocator.uiRect(
                fromPageSpace: line.bounds(for: linePage), page: linePage)
        }
        let dimensions = PdfTextLocator.displayDimensions(of: page)
        return PositionData(
            rects: PdfTextLocator.mergeLineRects(rects),
            pageWidth: Double(dimensions.width),
            pageHeight: Double(dimensions.height),
            selectedText: selection.string,
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil)
    }

    private func midpointY(_ position: PositionData) -> Double {
        let rect = position.rects.first!
        return rect.y + rect.height / 2
    }

    func testDragEndPastTextEndDoesNotCrash() {
        let page = textPage()
        let current = position(for: NSRange(location: 4, length: 11), on: page)
        let result = PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: .end,
            toDisplayPoint: CGPoint(x: current.pageWidth + 1_000, y: midpointY(current)))

        XCTAssertTrue(result?.selectedText?.hasPrefix("quick") == true)
        XCTAssertTrue(result?.selectedText?.hasSuffix("dog") == true)
    }

    func testDragEndPastStartHoldsLastFrame() {
        let page = textPage()
        let current = position(for: NSRange(location: 4, length: 11), on: page)
        let targetCharacter = position(for: NSRange(location: 1, length: 1), on: page)
        let targetRect = targetCharacter.rects.first!

        XCTAssertNil(PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: .end,
            toDisplayPoint: CGPoint(x: targetRect.x + targetRect.width / 2, y: midpointY(current))))
    }

    func testDragEndIntoLeftMarginHoldsLastFrame() {
        let page = textPage()
        let current = position(for: NSRange(location: 4, length: 11), on: page)

        XCTAssertNil(PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: .end,
            toDisplayPoint: CGPoint(x: 0, y: midpointY(current))))
    }

    func testDragEndExtendsWhileStartStaysPinned() {
        let page = textPage()
        let current = position(for: NSRange(location: 4, length: 11), on: page)
        let targetWord = position(for: NSRange(location: 20, length: 5), on: page)
        let targetRect = targetWord.rects.first!
        let result = PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: .end,
            toDisplayPoint: CGPoint(x: targetRect.x + targetRect.width / 2, y: midpointY(current)))

        XCTAssertTrue(result?.selectedText?.hasPrefix("quick") == true)
        XCTAssertTrue(result?.selectedText?.contains("fox") == true)
    }

    func testDragStartExtendsWhileEndStaysPinned() {
        let page = textPage()
        let current = position(for: NSRange(location: 16, length: 3), on: page)
        let targetWord = position(for: NSRange(location: 0, length: 3), on: page)
        let targetRect = targetWord.rects.first!
        let result = PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: .start,
            toDisplayPoint: CGPoint(x: targetRect.x + targetRect.width / 2, y: midpointY(current)))

        XCTAssertTrue(result?.selectedText?.hasSuffix("fox") == true)
        let text = result?.selectedText ?? ""
        XCTAssertTrue(text.contains("The") || text.hasPrefix("he"))
    }

    func testResizeOnEmptyPageReturnsNil() {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        let page = PDFDocument(data: data as Data)!.page(at: 0)!
        let current = PositionData(
            rects: [AnnotationRect(x: 10, y: 10, width: 50, height: 12)],
            pageWidth: 612,
            pageHeight: 792,
            selectedText: "x",
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil)

        XCTAssertNil(PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: .end,
            toDisplayPoint: CGPoint(x: 100, y: 16)))
    }
}

// Round-trip tests for the PDF persistence engine (Services/Pdf/*). These
// mirror the Rust tests in src-tauri/src/pdf_annotations.rs and additionally
// verify the raw dictionary format via CGPDF, including interop with files in
// the exact shape the Rust (lopdf) writer produces.

@MainActor
final class PdfPersistenceTests: XCTestCase {
    private var tempDir: URL!
    /// CGPDF dictionaries are interior pointers — the owning documents must
    /// stay alive while raw assertions run.
    private var retainedDocuments: [CGPDFDocument] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-pdf-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        retainedDocuments.removeAll()
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - Fixtures

    /// Multi-page PDF via CoreGraphics (arbitrary third-party-ish producer).
    private func makeTestPdf(name: String, pages: Int = 3) -> String {
        let url = tempDir.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let text = CFAttributedStringCreate(nil, "Page \(index + 1) hello world" as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(text)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url.path
    }

    /// Hand-written classic-xref PDF — the shape lopdf (the Rust writer)
    /// produces. `objects` maps object number → source; numbering must be
    /// 1...N contiguous with object 1 as the catalog.
    private func makeClassicPdf(name: String, objects: [Int: String]) -> String {
        let url = tempDir.appendingPathComponent("\(name).pdf")
        var body = "%PDF-1.7\n"
        var offsets: [Int: Int] = [:]
        let numbers = objects.keys.sorted()
        for number in numbers {
            offsets[number] = body.utf8.count
            body += "\(number) 0 obj\n\(objects[number]!)\nendobj\n"
        }
        let xrefStart = body.utf8.count
        body += "xref\n0 \(numbers.count + 1)\n0000000000 65535 f \n"
        for number in numbers {
            body += String(format: "%010d 00000 n \n", offsets[number]!)
        }
        body += "trailer\n<< /Size \(numbers.count + 1) /Root 1 0 R >>\nstartxref\n\(xrefStart)\n%%EOF\n"
        try! Data(body.utf8).write(to: url)
        return url.path
    }

    /// Single rotated page, 612×792 media box.
    private func makeRotatedPdf(name: String, rotation: Int) -> String {
        makeClassicPdf(name: name, objects: [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Rotate \(rotation) /Contents 4 0 R /Resources << >> >>",
            4: "<< /Length 0 >>\nstream\n\nendstream",
        ])
    }

    private func openSession(_ path: String) async throws -> PdfDocumentSession {
        try await PdfSessionBackend().open(path: path, sessionId: UUID().uuidString)
    }

    /// A deliberately heavy PDF: every page carries a UNIQUE full-page noise
    /// image (noise defeats both compression and CGPDFContext's image dedup),
    /// yielding a file in the hundreds-of-megabytes class. A mutation pays the
    /// full pipeline over that file — read, double parse (CGPDFDocument +
    /// PDFDocument), `dataRepresentation()`, the byte-patch scan, and the
    /// atomic rewrite — which is the cost the main thread used to eat
    /// synchronously on textbook-size documents.
    private func makeLargePdf(name: String, pages: Int, imageSide: Int) -> String {
        let url = tempDir.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        for _ in 0..<pages {
            // arc4random_buf fills at C speed, so fixture generation stays
            // fast even in unoptimized Debug test builds.
            var pixels = [UInt8](repeating: 0, count: imageSide * imageSide * 4)
            pixels.withUnsafeMutableBytes { arc4random_buf($0.baseAddress, $0.count) }
            let image: CGImage = pixels.withUnsafeMutableBytes { raw in
                let bitmap = CGContext(
                    data: raw.baseAddress, width: imageSide, height: imageSide,
                    bitsPerComponent: 8, bytesPerRow: imageSide * 4, space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
                return bitmap.makeImage()!
            }
            context.beginPDFPage(nil)
            context.draw(image, in: CGRect(x: 0, y: 0, width: 612, height: 792))
            context.endPDFPage()
        }
        context.closePDF()
        return url.path
    }

    private func position(_ rect: AnnotationRect, pageWidth: Double = 612, pageHeight: Double = 792, selectedText: String? = "selected text") -> PositionData {
        PositionData(
            rects: [rect],
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            selectedText: selectedText,
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil)
    }

    // MARK: - Raw CGPDF inspection helpers

    private func rawDocument(_ path: String) -> CGPDFDocument {
        let document = CGPDFDocument(URL(fileURLWithPath: path) as CFURL)!
        retainedDocuments.append(document)
        return document
    }

    private func rawAnnotations(_ path: String, page: Int) -> [CGPDFDictionaryRef] {
        let document = rawDocument(path)
        guard let pageDictionary = document.page(at: page)?.dictionary,
              let annots = CgPdf.array(pageDictionary, "Annots")
        else { return [] }
        return (0..<CgPdf.count(annots)).compactMap { CgPdf.dictionaryAt(annots, $0) }
    }

    private func rawAnnotation(_ path: String, page: Int, nm: String) -> CGPDFDictionaryRef? {
        rawAnnotations(path, page: page).first { CgPdf.string($0, "NM") == nm }
    }

    /// Root-level outline items in sibling order.
    private func rawOutlineItems(_ path: String) -> [CGPDFDictionaryRef] {
        let document = rawDocument(path)
        guard let catalog = document.catalog,
              let outlines = CgPdf.dictionary(catalog, "Outlines")
        else { return [] }
        var items: [CGPDFDictionaryRef] = []
        var current = CgPdf.dictionary(outlines, "First")
        while let item = current, items.count < 64 {
            items.append(item)
            current = CgPdf.dictionary(item, "Next")
        }
        return items
    }

    private func rawOutlineCount(_ path: String) -> Int? {
        let document = rawDocument(path)
        guard let catalog = document.catalog,
              let outlines = CgPdf.dictionary(catalog, "Outlines")
        else { return nil }
        return CgPdf.integer(outlines, "Count")
    }

    private func numbers(_ array: CGPDFArrayRef) -> [Double] {
        (0..<CgPdf.count(array)).compactMap { CgPdf.numberAt(array, $0) }
    }

    private func assertClose(_ actual: Double, _ expected: Double, tolerance: Double = 0.5,
                             _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, accuracy: tolerance, message, file: file, line: line)
    }

    // MARK: - Tests

    func testHighlightRoundTripAndRawFormat() async throws {
        let path = makeTestPdf(name: "highlight")
        let session = try await openSession(path)

        let created = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight,
            pageNumber: 1,
            color: "#fef08a",
            content: nil,
            positionData: position(AnnotationRect(x: 72, y: 100, width: 180, height: 16))))

        XCTAssertEqual(created.type, .highlight)
        XCTAssertEqual(created.color, "#fef08a")

        // Fresh session, fresh read.
        let reopened = try await openSession(path)
        let annotations = try await reopened.annotations(pageNumber: nil)
        let highlight = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(highlight.type, .highlight)
        XCTAssertEqual(highlight.pageNumber, 1)
        XCTAssertEqual(highlight.color, "#fef08a")
        XCTAssertEqual(highlight.createdAt, created.createdAt)
        let positionData = try XCTUnwrap(highlight.positionData)
        XCTAssertEqual(positionData.selectedText, "selected text")
        assertClose(positionData.pageWidth, 612)
        assertClose(positionData.pageHeight, 792)
        let rect = try XCTUnwrap(positionData.rects.first)
        assertClose(rect.x, 72)
        assertClose(rect.y, 100)
        assertClose(rect.width, 180)
        assertClose(rect.height, 16)

        // Raw dictionary contract (what the Rust reader expects to find).
        let dictionary = try XCTUnwrap(rawAnnotation(path, page: 1, nm: created.id))
        XCTAssertEqual(CgPdf.name(dictionary, "Subtype"), "Highlight")
        XCTAssertEqual(CgPdf.string(dictionary, "T"), "Vellum")
        XCTAssertEqual(CgPdf.integer(dictionary, "F"), 4)
        XCTAssertEqual(CgPdf.string(dictionary, "VellumSelectedText"), "selected text")
        XCTAssertEqual(CgPdf.string(dictionary, "VellumCreatedAt"), created.createdAt)
        XCTAssertNotNil(CgPdf.string(dictionary, "M"))
        XCTAssertTrue(CgPdf.string(dictionary, "M")?.hasPrefix("D:") ?? false)

        var caValue: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(dictionary, "CA", &caValue), "highlight must carry /CA")
        assertClose(Double(caValue), 0.4, tolerance: 0.001)

        // QuadPoints: TL TR BL BR in absolute page coordinates.
        let quadPoints = try XCTUnwrap(CgPdf.array(dictionary, "QuadPoints"))
        let quads = numbers(quadPoints)
        XCTAssertEqual(quads.count, 8)
        let expected: [Double] = [72, 692, 252, 692, 72, 676, 252, 676]
        for (actual, wanted) in zip(quads, expected) {
            assertClose(actual, wanted)
        }
        let rectArray = try XCTUnwrap(CgPdf.array(dictionary, "Rect"))
        let rectValues = numbers(rectArray)
        for (actual, wanted) in zip(rectValues, [72.0, 676.0, 252.0, 692.0]) {
            assertClose(actual, wanted)
        }

        // /C written as channel/255.
        let colorArray = try XCTUnwrap(CgPdf.array(dictionary, "C"))
        let channels = numbers(colorArray)
        XCTAssertEqual(channels.count, 3)
        assertClose(channels[0], 254.0 / 255.0, tolerance: 0.002)
        assertClose(channels[1], 240.0 / 255.0, tolerance: 0.002)
        assertClose(channels[2], 138.0 / 255.0, tolerance: 0.002)
    }

    func testNoteRoundTripAndContentEdit() async throws {
        let path = makeTestPdf(name: "note")
        let session = try await openSession(path)

        let created = try await session.createAnnotation(CreateAnnotationInput(
            type: .note,
            pageNumber: 2,
            color: nil,
            content: "First note",
            positionData: position(AnnotationRect(x: 300, y: 400, width: 0, height: 0), selectedText: nil)))
        XCTAssertEqual(created.color, "#fde68a", "default note color")

        let reopened = try await openSession(path)
        var annotations = try await reopened.annotations(pageNumber: nil)
        var note = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(note.type, .note)
        XCTAssertEqual(note.pageNumber, 2)
        XCTAssertEqual(note.content, "First note")
        var rect = try XCTUnwrap(note.positionData?.rects.first)
        assertClose(rect.x, 300)
        assertClose(rect.y, 400)
        XCTAssertEqual(rect.width, 0)
        XCTAssertEqual(rect.height, 0)

        // Raw: /Text with a real /Name /Note name object and an 18pt rect.
        let dictionary = try XCTUnwrap(rawAnnotation(path, page: 2, nm: created.id))
        XCTAssertEqual(CgPdf.name(dictionary, "Subtype"), "Text")
        XCTAssertEqual(CgPdf.name(dictionary, "Name"), "Note", "/Name must be a name object, not a string")
        let rectValues = numbers(try XCTUnwrap(CgPdf.array(dictionary, "Rect")))
        assertClose(rectValues[2] - rectValues[0], 18)
        assertClose(rectValues[3] - rectValues[1], 18)

        // Content edit through update_annotation.
        let updated = try await reopened.updateAnnotation(UpdateAnnotationInput(
            id: created.id, color: nil, content: "Edited note", positionData: nil))
        XCTAssertTrue(updated)

        let final = try await openSession(path)
        annotations = try await final.annotations(pageNumber: nil)
        note = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(note.content, "Edited note")
        XCTAssertEqual(note.createdAt, created.createdAt, "created_at must not change on update")
        XCTAssertGreaterThanOrEqual(note.updatedAt, note.createdAt)
        rect = try XCTUnwrap(note.positionData?.rects.first)
        assertClose(rect.x, 300)
        assertClose(rect.y, 400)
    }

    func testBookmarkCreateReadDelete() async throws {
        let path = makeTestPdf(name: "bookmark")
        let session = try await openSession(path)

        let bookmark = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 2, color: nil, content: nil, positionData: nil))
        XCTAssertEqual(bookmark.type, .bookmark)
        XCTAssertNil(bookmark.color)
        XCTAssertNil(bookmark.content)
        XCTAssertNil(bookmark.positionData)

        // Raw: a standard outline item with Vellum keys, linked from the root.
        var items = rawOutlineItems(path)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(CgPdf.string(item, "Title"), "Bookmark - page 2")
        XCTAssertEqual(CgPdf.name(item, "VellumType"), "Bookmark")
        XCTAssertEqual(CgPdf.string(item, "VellumNM"), bookmark.id)
        XCTAssertEqual(CgPdf.string(item, "VellumCreatedAt"), bookmark.createdAt)
        XCTAssertFalse(CgPdf.has(item, "Subtype"))
        XCTAssertEqual(rawOutlineCount(path), 1)
        // /Dest = [pageRef /Fit]
        let dest = try XCTUnwrap(CgPdf.array(item, "Dest"))
        XCTAssertNotNil(CgPdf.dictionaryAt(dest, 0))
        var fitName: UnsafePointer<CChar>?
        XCTAssertTrue(CGPDFArrayGetName(dest, 1, &fitName))
        XCTAssertEqual(String(cString: fitName!), "Fit")

        // Read back through a fresh session.
        let reopened = try await openSession(path)
        var annotations = try await reopened.annotations(pageNumber: nil)
        let read = try XCTUnwrap(annotations.first { $0.id == bookmark.id })
        XCTAssertEqual(read.type, .bookmark)
        XCTAssertEqual(read.pageNumber, 2)
        XCTAssertEqual(read.createdAt, bookmark.createdAt)

        // Second bookmark on page 1 sorts before the page-2 one.
        let second = try await reopened.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 1, color: nil, content: nil, positionData: nil))
        items = rawOutlineItems(path)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(rawOutlineCount(path), 2)
        annotations = try await reopened.annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [second.id, bookmark.id])

        // Page filter.
        let filtered = try await reopened.annotations(pageNumber: 2)
        XCTAssertEqual(filtered.map(\.id), [bookmark.id])

        // Delete the first bookmark; sibling chain and count must recover.
        let deleted = try await reopened.deleteAnnotation(id: bookmark.id)
        XCTAssertTrue(deleted)
        items = rawOutlineItems(path)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(CgPdf.string(items[0], "VellumNM"), second.id)
        XCTAssertEqual(rawOutlineCount(path), 1)
        annotations = try await reopened.annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [second.id])

        let unknown = try await reopened.deleteAnnotation(id: "missing-id")
        XCTAssertFalse(unknown)
    }

    func testMetadataLastPageTitleAndCustomKeys() async throws {
        let path = makeTestPdf(name: "metadata")
        let session = try await openSession(path)
        XCTAssertEqual(session.info.pageCount, 3)
        XCTAssertEqual(session.info.title, "metadata", "title falls back to the file stem")
        XCTAssertNil(session.info.lastPage)

        try await session.setMetadata(key: "page_count", value: "999") // no-op
        try await session.setMetadata(key: "last_page", value: "2")
        try await session.setMetadata(key: "title", value: "My Book")
        try await session.setMetadata(key: "reading_theme", value: "sepia")

        let reopened = try await openSession(path)
        XCTAssertEqual(reopened.info.lastPage, 2)
        XCTAssertEqual(reopened.info.title, "My Book")
        XCTAssertEqual(reopened.info.pageCount, 3)

        // Raw Info entries: integer /VellumLastPage, PascalCase custom key.
        let info = try XCTUnwrap(rawDocument(path).info)
        XCTAssertEqual(CgPdf.integer(info, "VellumLastPage"), 2)
        XCTAssertEqual(CgPdf.string(info, "VellumReadingTheme"), "sepia")
        XCTAssertEqual(CgPdf.string(info, "Title"), "My Book")

        // Metadata must survive later annotation saves (PDFKit rewrites).
        _ = try await reopened.createAnnotation(CreateAnnotationInput(
            type: .highlight,
            pageNumber: 1,
            color: nil,
            content: nil,
            positionData: position(AnnotationRect(x: 10, y: 10, width: 40, height: 10))))
        let after = try await openSession(path)
        XCTAssertEqual(after.info.lastPage, 2)
        XCTAssertEqual(after.info.title, "My Book")

        do {
            try await session.setMetadata(key: "last_page", value: "not-a-number")
            XCTFail("invalid last_page must throw")
        } catch {
            XCTAssertTrue("\(error.localizedDescription)".contains("Invalid last_page value"))
        }
    }

    func testUpdateHighlightColorAndPosition() async throws {
        let path = makeTestPdf(name: "update")
        let session = try await openSession(path)
        let created = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight,
            pageNumber: 1,
            color: "#fef08a",
            content: nil,
            positionData: position(AnnotationRect(x: 72, y: 100, width: 180, height: 16))))

        // Color update — must round-trip to the exact HIGHLIGHT_COLORS hex.
        let colorUpdated = try await session.updateAnnotation(UpdateAnnotationInput(
            id: created.id, color: "#bbf7d0", content: nil, positionData: nil))
        XCTAssertTrue(colorUpdated)
        var annotations = try await openSession(path).annotations(pageNumber: nil)
        var highlight = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(highlight.color, "#bbf7d0")

        // Position update — exercises the bounds-then-quads write order.
        let positionUpdated = try await session.updateAnnotation(UpdateAnnotationInput(
            id: created.id,
            color: nil,
            content: nil,
            positionData: position(AnnotationRect(x: 10, y: 20, width: 50, height: 12), selectedText: "moved")))
        XCTAssertTrue(positionUpdated)
        annotations = try await openSession(path).annotations(pageNumber: nil)
        highlight = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(highlight.color, "#bbf7d0", "unchanged fields survive position updates")
        XCTAssertEqual(highlight.positionData?.selectedText, "moved")
        let rect = try XCTUnwrap(highlight.positionData?.rects.first)
        assertClose(rect.x, 10)
        assertClose(rect.y, 20)
        assertClose(rect.width, 50)
        assertClose(rect.height, 12)

        // Raw quad check after update.
        let dictionary = try XCTUnwrap(rawAnnotation(path, page: 1, nm: created.id))
        let quads = numbers(try XCTUnwrap(CgPdf.array(dictionary, "QuadPoints")))
        let expected: [Double] = [10, 772, 60, 772, 10, 760, 60, 760]
        for (actual, wanted) in zip(quads, expected) {
            assertClose(actual, wanted)
        }

        // Unknown id → false.
        let missing = try await session.updateAnnotation(UpdateAnnotationInput(
            id: "nope", color: "#fef08a", content: nil, positionData: nil))
        XCTAssertFalse(missing)
    }

    func testDeleteHighlight() async throws {
        let path = makeTestPdf(name: "delete")
        let session = try await openSession(path)
        let first = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: nil, content: nil,
            positionData: position(AnnotationRect(x: 72, y: 100, width: 180, height: 16))))
        let second = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: nil, content: nil,
            positionData: position(AnnotationRect(x: 72, y: 140, width: 100, height: 16))))

        let firstDelete = try await session.deleteAnnotation(id: first.id)
        XCTAssertTrue(firstDelete)
        let annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertNil(annotations.first { $0.id == first.id })
        XCTAssertNotNil(annotations.first { $0.id == second.id })
        let secondDelete = try await session.deleteAnnotation(id: first.id)
        XCTAssertFalse(secondDelete, "second delete returns false")
    }

    func testForeignAnnotationDerivedIdAndUpdate() async throws {
        // A third-party highlight with no /NM: id derives from page + index,
        // stays stable across reads, and update stamps it into /NM.
        let path = makeClassicPdf(name: "foreign", objects: [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>",
            4: "<< /Length 0 >>\nstream\n\nendstream",
            5: "<< /Type /Annot /Subtype /Highlight /Rect [72 676 252 692] /QuadPoints [72 692 252 692 72 676 252 676] /C [1 1 0] /Contents (External comment) >>",
        ])

        let session = try await openSession(path)
        var annotations = try await session.annotations(pageNumber: nil)
        XCTAssertEqual(annotations.count, 1)
        let foreign = annotations[0]
        XCTAssertEqual(foreign.id, "pdf-direct-1-0")
        XCTAssertEqual(foreign.type, .highlight)
        XCTAssertEqual(foreign.color, "#ffff00")
        XCTAssertEqual(foreign.content, "External comment")
        let rect = try XCTUnwrap(foreign.positionData?.rects.first)
        assertClose(rect.x, 72)
        assertClose(rect.y, 100)
        assertClose(rect.width, 180)
        assertClose(rect.height, 16)

        let foreignUpdated = try await session.updateAnnotation(UpdateAnnotationInput(
            id: foreign.id, color: "#bbf7d0", content: "Edited in Vellum", positionData: nil))
        XCTAssertTrue(foreignUpdated)

        annotations = try await openSession(path).annotations(pageNumber: nil)
        let edited = try XCTUnwrap(annotations.first { $0.id == "pdf-direct-1-0" })
        XCTAssertEqual(edited.color, "#bbf7d0")
        XCTAssertEqual(edited.content, "Edited in Vellum")
        // /NM stamped with the derived id on first update.
        let dictionary = try XCTUnwrap(rawAnnotation(path, page: 1, nm: "pdf-direct-1-0"))
        XCTAssertEqual(CgPdf.string(dictionary, "NM"), "pdf-direct-1-0")
    }

    func testUnrelatedCreateDoesNotClaimForeignAnnotation() async throws {
        let path = makeClassicPdf(name: "foreign-preserved", objects: [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [5 0 R] >>",
            4: "<< /Length 0 >>\nstream\n\nendstream",
            5: "<< /Type /Annot /Subtype /Highlight /Rect [72 676 252 692] /QuadPoints [72 692 252 692 72 676 252 676] /C [1 1 0] /T (Vellum) /Contents (External comment) >>",
        ])

        let session = try await openSession(path)
        _ = try await session.createAnnotation(CreateAnnotationInput(
            type: .note,
            pageNumber: 1,
            color: nil,
            content: "Vellum note",
            positionData: position(AnnotationRect(x: 300, y: 400, width: 0, height: 0))))

        let foreign = try XCTUnwrap(rawAnnotations(path, page: 1).first {
            CgPdf.string($0, "Contents") == "External comment"
        })
        XCTAssertNil(CgPdf.string(foreign, "NM"))
        XCTAssertEqual(CgPdf.string(foreign, "T"), "Vellum")
        XCTAssertFalse(CgPdf.has(foreign, "VellumCreatedAt"))
        XCTAssertFalse(CgPdf.has(foreign, "VellumUpdatedAt"))
    }

    func testForeignAnnotationDerivedIdSkipsNonDictionarySlots() async throws {
        // /Annots with a null slot before the real annotation: the reader
        // derives the id from the RAW slot index (pdf-direct-1-1), while
        // PDFKit's page.annotations omits the null entry — update/delete must
        // resolve against the raw-slot domain, not PDFKit's filtered index.
        let path = makeClassicPdf(name: "foreign-null-slot", objects: [
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << >> /Annots [null 5 0 R] >>",
            4: "<< /Length 0 >>\nstream\n\nendstream",
            5: "<< /Type /Annot /Subtype /Highlight /Rect [72 676 252 692] /QuadPoints [72 692 252 692 72 676 252 676] /C [1 1 0] >>",
        ])

        let session = try await openSession(path)
        let annotations = try await session.annotations(pageNumber: nil)
        XCTAssertEqual(annotations.count, 1)
        XCTAssertEqual(annotations[0].id, "pdf-direct-1-1", "id derives from the raw /Annots slot")

        // Update through the derived id must hit the highlight (not miss, and
        // not resolve slot 1 against PDFKit's filtered array).
        let updated = try await session.updateAnnotation(UpdateAnnotationInput(
            id: "pdf-direct-1-1", color: "#bbf7d0", content: "Edited", positionData: nil))
        XCTAssertTrue(updated)
        let after = try await openSession(path).annotations(pageNumber: nil)
        let edited = try XCTUnwrap(after.first { $0.id == "pdf-direct-1-1" })
        XCTAssertEqual(edited.color, "#bbf7d0")
        XCTAssertEqual(edited.content, "Edited")

        // Delete through the derived id.
        let deleted = try await session.deleteAnnotation(id: "pdf-direct-1-1")
        XCTAssertTrue(deleted)
        let final = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertTrue(final.isEmpty)
    }

    func testAnnotatedFileRendersThroughViewerLoadPath() async throws {
        // Regression for the "blank viewport on reopen" QA report: a file
        // rewritten by the persistence engine (embedded annotations with /AP
        // appearance streams from PDFKit's serializer) must still render page
        // content through the viewer's exact load path — raw bytes →
        // PDFDocument(data:) → strip embedded annotations → draw.
        let path = makeTestPdf(name: "render-check")
        let session = try await openSession(path)
        _ = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: nil, content: nil,
            positionData: position(AnnotationRect(x: 72, y: 80, width: 180, height: 16))))
        _ = try await session.createAnnotation(CreateAnnotationInput(
            type: .note, pageNumber: 1, color: nil, content: "note",
            positionData: position(AnnotationRect(x: 300, y: 400, width: 0, height: 0), selectedText: nil)))
        try await session.setMetadata(key: "last_page", value: "1")

        let data = try await session.readPdfBytes()
        let document = try XCTUnwrap(PDFDocument(data: data), "viewer parse of rewritten bytes")
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertFalse(page.annotations.isEmpty, "annotations embedded after rewrite")
        // The viewer's display-copy strip (PdfViewerController.adopt).
        for index in 0..<document.pageCount {
            guard let stripPage = document.page(at: index) else { continue }
            for annotation in stripPage.annotations {
                stripPage.removeAnnotation(annotation)
            }
        }
        XCTAssertTrue(page.annotations.isEmpty)

        // Render page 1 like the viewer does and require non-blank pixels.
        // CoreGraphics (page.draw + CGBitmapContext) is cross-platform, so the
        // same round-trip test runs on both the macOS and iPad builds.
        let box = page.bounds(for: .cropBox)
        let width = Int(box.width), height = Int(box.height)
        let bytesPerRow = width * 4
        var buffer = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(buffer.withUnsafeMutableBytes { raw in
            CGContext(
                data: raw.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        })
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Map the crop box to the context origin before drawing the page.
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .cropBox, to: context)

        var sum = 0.0, sumSq = 0.0, count = 0.0
        for y in stride(from: 0, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let offset = y * bytesPerRow + x * 4
                let luma = 0.299 * Double(buffer[offset])
                    + 0.587 * Double(buffer[offset + 1])
                    + 0.114 * Double(buffer[offset + 2])
                sum += luma
                sumSq += luma * luma
                count += 1
            }
        }
        let mean = sum / count
        let variance = sumSq / count - mean * mean
        XCTAssertGreaterThan(variance, 1.0, "page 1 must render content, not a blank fill")
    }

    func testRotatedPagesRoundTrip() async throws {
        for rotation in [90, 180, 270] {
            let path = makeRotatedPdf(name: "rotated-\(rotation)", rotation: rotation)
            let (pageWidth, pageHeight) = rotation == 90 || rotation == 270
                ? (792.0, 612.0)
                : (612.0, 792.0)

            let session = try await openSession(path)
            let created = try await session.createAnnotation(CreateAnnotationInput(
                type: .highlight,
                pageNumber: 1,
                color: nil,
                content: nil,
                positionData: position(
                    AnnotationRect(x: 50, y: 60, width: 120, height: 14),
                    pageWidth: pageWidth, pageHeight: pageHeight)))

            let annotations = try await openSession(path).annotations(pageNumber: nil)
            let highlight = try XCTUnwrap(annotations.first { $0.id == created.id })
            let positionData = try XCTUnwrap(highlight.positionData)
            assertClose(positionData.pageWidth, pageWidth, "rotation \(rotation)")
            assertClose(positionData.pageHeight, pageHeight, "rotation \(rotation)")
            let rect = try XCTUnwrap(positionData.rects.first)
            assertClose(rect.x, 50, "rotation \(rotation)")
            assertClose(rect.y, 60, "rotation \(rotation)")
            assertClose(rect.width, 120, "rotation \(rotation)")
            assertClose(rect.height, 14, "rotation \(rotation)")
        }
    }

    func testRustWrittenFileInteropAndPreservation() async throws {
        // A file in the exact shape the Rust app writes: /Highlight and /Text
        // annotations with Vellum keys, plus an outline bookmark with
        // /VellumType /Bookmark and /VellumNM.
        let path = makeClassicPdf(name: "rust-interop", objects: [
            1: "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << >> /Annots [9 0 R 10 0 R] >>",
            4: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << >> >>",
            5: "<< /Length 0 >>\nstream\n\nendstream",
            6: "<< /Length 0 >>\nstream\n\nendstream",
            7: "<< /Type /Outlines /Count 1 /First 8 0 R /Last 8 0 R >>",
            8: "<< /Title (Bookmark - page 2) /Parent 7 0 R /Dest [4 0 R /Fit] /VellumType /Bookmark /VellumNM (rust-bm-1) /VellumCreatedAt (2026-07-01T10:00:00.000000+00:00) /VellumUpdatedAt (2026-07-01T10:00:00.000000+00:00) >>",
            9: "<< /Type /Annot /Subtype /Highlight /NM (rust-hl-1) /M (D:20260701090000Z) /F 4 /T (Vellum) /C [0.996078431 0.941176471 0.541176471] /CA 0.4 /QuadPoints [72 692 252 692 72 676 252 676] /Rect [72 676 252 692] /VellumCreatedAt (2026-07-01T09:00:00.000000+00:00) /VellumUpdatedAt (2026-07-01T09:00:00.000000+00:00) /VellumSelectedText (some text) >>",
            10: "<< /Type /Annot /Subtype /Text /Name /Note /NM (rust-note-1) /M (D:20260701093000Z) /F 4 /T (Vellum) /C [0.992156863 0.905882353 0.541176471] /Rect [300 374 318 392] /Contents (a rust note) /VellumCreatedAt (2026-07-01T09:30:00.000000+00:00) /VellumUpdatedAt (2026-07-01T09:30:00.000000+00:00) >>",
        ])

        let session = try await openSession(path)
        let annotations = try await session.annotations(pageNumber: nil)
        // Sorted: page 1 by created_at (highlight 09:00, note 09:30), then page 2 bookmark.
        XCTAssertEqual(annotations.map(\.id), ["rust-hl-1", "rust-note-1", "rust-bm-1"])
        XCTAssertEqual(annotations[0].color, "#fef08a", "Rust /C values map back to the exact palette hex")
        XCTAssertEqual(annotations[0].positionData?.selectedText, "some text")
        XCTAssertEqual(annotations[1].content, "a rust note")
        XCTAssertEqual(annotations[2].type, .bookmark)
        XCTAssertEqual(annotations[2].pageNumber, 2)
        XCTAssertEqual(annotations[2].createdAt, "2026-07-01T10:00:00.000000+00:00")

        // A Swift-side save must preserve every Rust-written byte that matters:
        // outline custom keys, annotation custom keys, /CA.
        _ = try await session.createAnnotation(CreateAnnotationInput(
            type: .note,
            pageNumber: 1,
            color: nil,
            content: "Added by Swift",
            positionData: position(AnnotationRect(x: 40, y: 40, width: 0, height: 0), selectedText: nil)))

        let after = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(after.count, 4)
        let bookmark = try XCTUnwrap(after.first { $0.id == "rust-bm-1" })
        XCTAssertEqual(bookmark.createdAt, "2026-07-01T10:00:00.000000+00:00")
        let rustHighlight = try XCTUnwrap(after.first { $0.id == "rust-hl-1" })
        XCTAssertEqual(rustHighlight.createdAt, "2026-07-01T09:00:00.000000+00:00")
        let rawHighlight = try XCTUnwrap(rawAnnotation(path, page: 1, nm: "rust-hl-1"))
        var caValue: CGPDFReal = 0
        XCTAssertTrue(CGPDFDictionaryGetNumber(rawHighlight, "CA", &caValue))
        assertClose(Double(caValue), 0.4, tolerance: 0.001)
        let rawNote = try XCTUnwrap(rawAnnotation(path, page: 1, nm: "rust-note-1"))
        XCTAssertEqual(CgPdf.name(rawNote, "Name"), "Note")

        // Deleting the Rust-written outline bookmark.
        let bookmarkDeleted = try await session.deleteAnnotation(id: "rust-bm-1")
        XCTAssertTrue(bookmarkDeleted)
        let final = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertNil(final.first { $0.id == "rust-bm-1" })
        XCTAssertNotNil(final.first { $0.id == "rust-hl-1" })
        XCTAssertNotNil(final.first { $0.id == "rust-note-1" })
        XCTAssertEqual(rawOutlineItems(path).count, 0)
    }

    func testOpenValidation() async throws {
        let backend = PdfSessionBackend()

        // Wrong extension.
        do {
            _ = try await backend.open(path: "/tmp/whatever.txt", sessionId: "s1")
            XCTFail("must reject non-pdf extensions")
        } catch {
            XCTAssertEqual(error.localizedDescription, "Unsupported file type: .txt")
        }

        // Missing file.
        do {
            _ = try await backend.open(path: tempDir.appendingPathComponent("missing.pdf").path, sessionId: "s2")
            XCTFail("must reject missing files")
        } catch {
            XCTAssertTrue(error.localizedDescription.hasPrefix("Failed to resolve PDF path "))
        }

        // Valid open returns canonical path info.
        let path = makeTestPdf(name: "open-ok", pages: 2)
        let session = try await backend.open(path: path, sessionId: "s3")
        XCTAssertEqual(session.info.kind, .pdf)
        XCTAssertEqual(session.info.pageCount, 2)
        XCTAssertEqual(session.info.title, "open-ok")

        // read_pdf_bytes returns the current file contents.
        let bytes = try await session.readPdfBytes()
        XCTAssertEqual(bytes, try Data(contentsOf: URL(fileURLWithPath: session.path)))

        // save/close are no-ops.
        try await session.save()
        try await session.close()
    }

    /// The freeze regression: creating an annotation on a textbook-size PDF must
    /// not block the MainActor. We create a note on a heavy document while a
    /// MainActor loop samples its own scheduling latency every 50ms; if the
    /// write ran on the main thread (the old behavior) the sampler would stall
    /// for the whole multi-second rewrite.
    func testCreateAnnotationKeepsMainActorResponsiveOnLargePdf() async throws {
        // ~55 pages x unique 1024x1024 noise image ≈ 170MB on disk. Note:
        // `dataRepresentation()` alone is NOT the heaviness gauge — PDFKit
        // stream-copies at memcpy speed (a 470MB file serializes in ~0.2s) —
        // so the fixture check below gates on the wall-clock cost of the FULL
        // createAnnotation pipeline (read + double parse + serialize +
        // byte-patch scan + atomic rewrite), which is exactly the work the
        // main thread used to do synchronously.
        let path = makeLargePdf(name: "responsive", pages: 55, imageSide: 1024)

        let session = try await openSession(path)

        // Sample MainActor scheduling latency continuously.
        let tracker = GapTracker()
        let sampler = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                let now = Date()
                tracker.record(now.timeIntervalSince(last) - 0.050)
                last = now
            }
        }
        // Let the sampler establish a baseline before the write starts.
        try await Task.sleep(for: .milliseconds(120))

        let writeStart = Date()
        let created = try await session.createAnnotation(CreateAnnotationInput(
            type: .note,
            pageNumber: 1,
            color: nil,
            content: "responsiveness note",
            positionData: position(AnnotationRect(x: 100, y: 100, width: 0, height: 0), selectedText: nil)))
        let writeSeconds = Date().timeIntervalSince(writeStart)

        sampler.cancel()
        let maxGap = tracker.maxGap

        // The mutation must be genuinely expensive, or a passing gap assertion
        // proves nothing. On the old main-thread code path this entire
        // duration WAS a MainActor stall.
        XCTAssertGreaterThan(
            writeSeconds, 0.5,
            "fixture too cheap (createAnnotation took \(writeSeconds)s) to exercise the freeze; scale up pages")

        // The annotation must actually have landed on disk.
        let annotations = try await openSession(path).annotations(pageNumber: nil)
        let note = try XCTUnwrap(annotations.first { $0.id == created.id })
        XCTAssertEqual(note.content, "responsiveness note")

        XCTAssertLessThan(
            maxGap, 0.5,
            "MainActor stalled \(maxGap)s during a \(writeSeconds)s write — the write is blocking main")
    }
}
