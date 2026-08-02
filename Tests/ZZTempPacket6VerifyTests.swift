import XCTest
import PDFKit
import CoreGraphics
import CoreText
@testable import Vellum

// TEMPORARY scratch verification for packet 6 §2.5–§2.8. DELETE AFTER RUNNING.

@MainActor
final class ZZTempPacket6VerifyTests: XCTestCase {
    private var tempDir: URL!
    private var webDir: URL!
    private var retainedDocuments: [CGPDFDocument] = []

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-p6-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        webDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-p6-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: webDir, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = webDir
    }

    override func tearDown() async throws {
        retainedDocuments.removeAll()
        WebLibrary.storeDirOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        if let webDir { try? FileManager.default.removeItem(at: webDir) }
    }

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

    private func openSession(_ path: String) async throws -> PdfDocumentSession {
        try await PdfSessionBackend().open(path: path, sessionId: UUID().uuidString)
    }

    private func position(_ rect: AnnotationRect) -> PositionData {
        PositionData(
            rects: [rect], pageWidth: 612, pageHeight: 792, selectedText: "selected text",
            startOffset: nil, endOffset: nil, prefix: nil, suffix: nil, viewportOffset: nil)
    }

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

    // MARK: - §4.1 tests, verbatim from main

    func testBookmarkTitleCreateUpdateClear() async throws {
        let path = makeTestPdf(name: "bookmark-title")
        let session = try await openSession(path)

        let bookmark = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 2, color: nil, content: nil, positionData: nil))
        XCTAssertNil(bookmark.content)

        let title = "Key derivation — proof"
        let titled = try await session.updateAnnotation(UpdateAnnotationInput(
            id: bookmark.id, color: nil, content: title, positionData: nil))
        XCTAssertTrue(titled)
        var items = rawOutlineItems(path)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(CgPdf.string(items[0], "Title"), title)
        XCTAssertEqual(CgPdf.string(items[0], "VellumContent"), title)
        XCTAssertEqual(CgPdf.string(items[0], "VellumNM"), bookmark.id)

        var reopened = try await openSession(path)
        var annotations = try await reopened.annotations(pageNumber: nil)
        var read = try XCTUnwrap(annotations.first { $0.id == bookmark.id })
        XCTAssertEqual(read.content, title)
        XCTAssertEqual(read.createdAt, bookmark.createdAt, "created_at must not change on update")
        XCTAssertGreaterThanOrEqual(read.updatedAt, read.createdAt)

        let cleared = try await reopened.updateAnnotation(UpdateAnnotationInput(
            id: bookmark.id, color: nil, content: "", positionData: nil))
        XCTAssertTrue(cleared)
        items = rawOutlineItems(path)
        XCTAssertEqual(CgPdf.string(items[0], "Title"), "Bookmark - page 2")
        XCTAssertFalse(CgPdf.has(items[0], "VellumContent"))

        reopened = try await openSession(path)
        annotations = try await reopened.annotations(pageNumber: nil)
        read = try XCTUnwrap(annotations.first { $0.id == bookmark.id })
        XCTAssertNil(read.content)

        let titledCreate = try await reopened.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 1, color: nil, content: "Intro", positionData: nil))
        XCTAssertEqual(titledCreate.content, "Intro")
        items = rawOutlineItems(path)
        let created = try XCTUnwrap(items.first { CgPdf.string($0, "VellumNM") == titledCreate.id })
        XCTAssertEqual(CgPdf.string(created, "Title"), "Intro")
        XCTAssertEqual(CgPdf.string(created, "VellumContent"), "Intro")
        annotations = try await reopened.annotations(pageNumber: nil)
        read = try XCTUnwrap(annotations.first { $0.id == titledCreate.id })
        XCTAssertEqual(read.content, "Intro")

        let missing = try await reopened.updateAnnotation(UpdateAnnotationInput(
            id: "missing-id", color: nil, content: "x", positionData: nil))
        XCTAssertFalse(missing)
    }

    func testPinHighlightPersistsAndSortsFirst() async throws {
        let path = makeTestPdf(name: "pin-highlight")
        let session = try await openSession(path)
        let early = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: "#fef08a", content: nil,
            positionData: position(AnnotationRect(x: 72, y: 100, width: 100, height: 16))))
        let late = try await session.createAnnotation(CreateAnnotationInput(
            type: .note, pageNumber: 2, color: nil, content: "later note",
            positionData: position(AnnotationRect(x: 40, y: 40, width: 0, height: 0))))

        var annotations = try await session.annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [early.id, late.id], "unpinned order is page then create")

        let pinned = try await session.updateAnnotation(UpdateAnnotationInput(
            id: late.id, color: nil, content: nil, positionData: nil, isPinned: true))
        XCTAssertTrue(pinned)

        let dictionary = try XCTUnwrap(rawAnnotation(path, page: 2, nm: late.id))
        XCTAssertEqual(CgPdf.integer(dictionary, "VellumPinned"), 1)

        annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [late.id, early.id])
        let read = try XCTUnwrap(annotations.first { $0.id == late.id })
        XCTAssertTrue(read.pinned)

        let unpinned = try await openSession(path).updateAnnotation(UpdateAnnotationInput(
            id: late.id, color: nil, content: nil, positionData: nil, isPinned: false))
        XCTAssertTrue(unpinned)
        annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [early.id, late.id])
        XCTAssertFalse(try XCTUnwrap(annotations.first { $0.id == late.id }).pinned)
    }

    func testPinBookmarkPersistsAndSortsFirst() async throws {
        let path = makeTestPdf(name: "pin-bookmark")
        let session = try await openSession(path)
        let page2 = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 2, color: nil, content: nil, positionData: nil))
        let page1 = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 1, color: nil, content: nil, positionData: nil))

        var annotations = try await session.annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [page1.id, page2.id])

        let pinned = try await session.updateAnnotation(UpdateAnnotationInput(
            id: page2.id, color: nil, content: nil, positionData: nil, isPinned: true))
        XCTAssertTrue(pinned)

        let items = rawOutlineItems(path)
        let item = try XCTUnwrap(items.first { CgPdf.string($0, "VellumNM") == page2.id })
        XCTAssertEqual(CgPdf.integer(item, "VellumPinned"), 1)

        annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [page2.id, page1.id])
        XCTAssertTrue(try XCTUnwrap(annotations.first { $0.id == page2.id }).pinned)

        let unpinned = try await openSession(path).updateAnnotation(UpdateAnnotationInput(
            id: page2.id, color: nil, content: nil, positionData: nil, isPinned: false))
        XCTAssertTrue(unpinned)

        let clearedItems = rawOutlineItems(path)
        let cleared = try XCTUnwrap(clearedItems.first { CgPdf.string($0, "VellumNM") == page2.id })
        XCTAssertEqual(CgPdf.integer(cleared, "VellumPinned"), 0)

        annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [page1.id, page2.id], "unpin restores page order")
        XCTAssertFalse(try XCTUnwrap(annotations.first { $0.id == page2.id }).pinned)
    }

    /// Packet 6 §5.3 risk 1: a titled bookmark must not block later highlight
    /// creates (the rehydrateBookmarkMetadata title-matcher regression).
    func testTitledBookmarkDoesNotBlockLaterAnnotationWrites() async throws {
        let path = makeTestPdf(name: "titled-then-highlight")
        let session = try await openSession(path)
        let bookmark = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 2, color: nil, content: nil, positionData: nil))
        let retitled = try await session.updateAnnotation(UpdateAnnotationInput(
            id: bookmark.id, color: nil, content: "Chapter 1 — intro", positionData: nil))
        XCTAssertTrue(retitled)

        let fresh = try await openSession(path)
        let highlight = try await fresh.createAnnotation(CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: "#fef08a", content: nil,
            positionData: position(AnnotationRect(x: 72, y: 100, width: 100, height: 16))))

        let annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(annotations.count, 2)
        XCTAssertEqual(
            annotations.first { $0.id == bookmark.id }?.content, "Chapter 1 — intro",
            "the title must survive the rewrite triggered by the highlight create")
        XCTAssertNotNil(annotations.first { $0.id == highlight.id })
    }

    /// Packet 6 §5.3 risk 3: retitle + pin in ONE input rewrites twice; the
    /// second increment must build on the just-written bytes.
    func testBookmarkRetitleAndPinInOneUpdate() async throws {
        let path = makeTestPdf(name: "retitle-and-pin")
        let session = try await openSession(path)
        let page2 = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 2, color: nil, content: nil, positionData: nil))
        let page1 = try await session.createAnnotation(CreateAnnotationInput(
            type: .bookmark, pageNumber: 1, color: nil, content: nil, positionData: nil))

        let both = try await session.updateAnnotation(UpdateAnnotationInput(
            id: page2.id, color: nil, content: "Pinned & titled",
            positionData: nil, isPinned: true))
        XCTAssertTrue(both)

        let items = rawOutlineItems(path)
        let item = try XCTUnwrap(items.first { CgPdf.string($0, "VellumNM") == page2.id })
        XCTAssertEqual(CgPdf.integer(item, "VellumPinned"), 1)
        XCTAssertEqual(CgPdf.string(item, "Title"), "Pinned & titled")
        XCTAssertEqual(CgPdf.string(item, "VellumContent"), "Pinned & titled")

        let annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertEqual(annotations.map(\.id), [page2.id, page1.id])
        XCTAssertEqual(annotations.first?.content, "Pinned & titled")
        XCTAssertTrue(try XCTUnwrap(annotations.first).pinned)
    }

    /// Packet 6 §5.3 risk 2: a pinned highlight must survive an UNRELATED
    /// mutation that forces a full PDFKit rewrite.
    func testPinnedHighlightSurvivesUnrelatedRewrite() async throws {
        let path = makeTestPdf(name: "pin-survives")
        let session = try await openSession(path)
        let highlight = try await session.createAnnotation(CreateAnnotationInput(
            type: .highlight, pageNumber: 1, color: "#fef08a", content: nil,
            positionData: position(AnnotationRect(x: 72, y: 100, width: 100, height: 16))))
        let pinnedOk = try await session.updateAnnotation(UpdateAnnotationInput(
            id: highlight.id, color: nil, content: nil, positionData: nil, isPinned: true))
        XCTAssertTrue(pinnedOk)

        _ = try await openSession(path).createAnnotation(CreateAnnotationInput(
            type: .note, pageNumber: 3, color: nil, content: "unrelated",
            positionData: position(AnnotationRect(x: 40, y: 40, width: 0, height: 0))))

        let annotations = try await openSession(path).annotations(pageNumber: nil)
        XCTAssertTrue(
            try XCTUnwrap(annotations.first { $0.id == highlight.id }).pinned,
            "pin must survive the rewrite caused by an unrelated create")
        XCTAssertEqual(annotations.first?.id, highlight.id)
    }

    // MARK: - §4.2 web test, verbatim from main

    func testPinAnnotationPersistsAndSortsFirst() async throws {
        let url = "https://example.com/pin-me"
        let key = WebLibrary.pageKey(url)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: WebLibrary.recordPath(forKey: key))
        let io = WebDocumentIO(url: url, key: key)

        let first = try await io.createAnnotation(
            CreateAnnotationInput(type: .highlight, pageNumber: 1, content: "a"),
            storedHighlightColor: "#fde68a")
        let second = try await io.createAnnotation(
            CreateAnnotationInput(type: .note, pageNumber: 2, content: "b"),
            storedHighlightColor: "#fde68a")

        var list = await io.annotations(pageNumber: nil)
        XCTAssertEqual(list.map(\.id), [first.id, second.id])

        let updated = try await io.updateAnnotation(UpdateAnnotationInput(
            id: second.id, color: nil, content: nil, positionData: nil, isPinned: true))
        XCTAssertTrue(updated)

        list = await io.annotations(pageNumber: nil)
        XCTAssertEqual(list.map(\.id), [second.id, first.id])
        XCTAssertTrue(try XCTUnwrap(list.first).pinned)

        let record = try XCTUnwrap(WebLibrary.loadRecord(forKey: key))
        let stored = try XCTUnwrap(record.annotations.first { $0.id == second.id })
        XCTAssertEqual(stored.isPinned, true)

        let data = try Data(contentsOf: WebLibrary.recordPath(forKey: key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawAnnotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        let raw = try XCTUnwrap(rawAnnotations.first { ($0["id"] as? String) == second.id })
        XCTAssertEqual(raw["is_pinned"] as? Bool, true)
    }

    /// Byte compatibility: an unpinned annotation must NOT emit `is_pinned`.
    func testUnpinnedWebAnnotationOmitsKey() async throws {
        let url = "https://example.com/no-pin"
        let key = WebLibrary.pageKey(url)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: WebLibrary.recordPath(forKey: key))
        let io = WebDocumentIO(url: url, key: key)
        let created = try await io.createAnnotation(
            CreateAnnotationInput(type: .highlight, pageNumber: 1, content: "a"),
            storedHighlightColor: "#fde68a")

        let data = try Data(contentsOf: WebLibrary.recordPath(forKey: key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawAnnotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        let raw = try XCTUnwrap(rawAnnotations.first { ($0["id"] as? String) == created.id })
        XCTAssertNil(raw["is_pinned"], "unpinned records stay byte-compatible with pre-pin sidecars")
    }
}
