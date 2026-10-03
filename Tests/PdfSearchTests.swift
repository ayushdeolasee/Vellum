import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import Vellum

@MainActor
final class PdfSearchTests: XCTestCase {
    func testPrivateSearchFindsCaseInsensitiveUTF16RangesAndCancels() async throws {
        let data = try pdfData("Café needle NEEDLE")
        let result = try await PdfSearch(data: data).matches(query: "needle")
        XCTAssertEqual(result.matches.count, 2)
        let document = try XCTUnwrap(PDFDocument(data: data))
        for match in result.matches {
            XCTAssertEqual(document.page(at: match.page)?.selection(for: match.range)?.string?.lowercased(), "needle")
        }
        let cancelled = Task { try await PdfSearch(data: data).matches(query: "needle") }
        cancelled.cancel()
        let empty = try await cancelled.value
        XCTAssertTrue(empty.matches.isEmpty)
    }

    func testNativeUnlockCredentialsUnlockPrivateFindAndAIReaders() async throws {
        let password = "synthetic-test-password"
        let data = try pdfData("Synthetic needle", password: password)
        let document = try XCTUnwrap(PdfViewerDocument(data: data))
        XCTAssertTrue(document.isLocked)
        XCTAssertFalse(document.unlock(withPassword: "incorrect"))
        XCTAssertNil(document.privateCopyPassword)
        do {
            _ = try await PdfSearch(data: data).matches(query: "needle")
            XCTFail("A locked copy must report failure rather than an empty search")
        } catch PdfViewerPreparation.PrivateDocumentError.locked { }
        let lockedText = await PdfTextReader(data: data).text(pageNumber: 1)
        XCTAssertNil(lockedText)
        let wrongPasswordText = await PdfTextReader(data: data, password: "incorrect").text(pageNumber: 1)
        XCTAssertNil(wrongPasswordText)

        let info = DocumentInfo(kind: .pdf, pdfPath: "/isolated-encrypted-fixture.pdf", title: "Encrypted",
                                pageCount: 1, lastPage: 1, docId: UUID().uuidString)
        let app = AppStore(sessions: DocumentSessionManager())
        app.attachTab(PdfTab(id: "encrypted", document: info, currentPage: 1, numPages: 1, zoom: 1,
                             visiblePages: [], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view))
        let annotations = AnnotationStore(app: app)
        let ai = AiStore(settings: AiSettings())
        let runtime = LiveTabRuntime(tabId: "encrypted")
        runtime.adoptPreparedPdf(document, byteCount: data.count, sourceData: data)
        let controller = runtime.pdfController
        controller.adopt(document: document, app: app, annotationStore: annotations, ai: ai,
                         initialPage: 1, tabId: "encrypted", runtime: runtime)
        controller.pdfView = PDFView()
        controller.pdfView?.document = document
        controller.findQuery("needle")
        XCTAssertEqual(app.error, "Unlock this PDF before searching.")
        XCTAssertTrue(document.unlock(withPassword: password))
        // PDFKit returns true for any subsequent password once unlocked.
        _ = document.unlock(withPassword: "incorrect")
        XCTAssertEqual(document.privateCopyPassword, password)
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: data)).isLocked,
                      "The retained source must remain encrypted")
        controller.findQuery("needle")
        await controller.awaitPendingSearch()
        XCTAssertEqual(app.findMatchCount, 1)
        XCTAssertFalse(app.findIsSearching)
        XCTAssertNil(app.error)
        app.error = "Unrelated save failure"
        controller.findQuery("needle")
        await controller.awaitPendingSearch()
        XCTAssertEqual(app.error, "Unrelated save failure")
        let count = await controller.ensureExtracted(pages: [1])
        XCTAssertEqual(count, 1)
        XCTAssertTrue(ai.pageTexts[1]?.contains("Synthetic needle") == true)
        let located = await controller.locateText(pageNumber: 1, query: "needle")
        XCTAssertFalse(located?.positionData.rects.isEmpty ?? true)
        controller.reset()
        runtime.invalidateLoadedPdf()
        XCTAssertNil(runtime.preparedDocument)
        XCTAssertNil(runtime.preparedSourceData)
    }

    func testClearAndRebindingRejectOldQueryAndSnapshotIsBudgeted() async throws {
        let data = try pdfData("needle needle")
        let document = try XCTUnwrap(PDFDocument(data: data))
        let info = DocumentInfo(kind: .pdf, pdfPath: "/isolated-search-fixture.pdf", title: "Search",
                                pageCount: 1, lastPage: 1, docId: UUID().uuidString)
        let app = AppStore(sessions: DocumentSessionManager())
        let tab = PdfTab(id: "search", document: info, currentPage: 1, numPages: 1, zoom: 1,
                         visiblePages: [], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view)
        app.attachTab(tab)
        let annotations = AnnotationStore(app: app)
        let ai = AiStore(settings: AiSettings())
        let runtime = LiveTabRuntime(tabId: "search")
        let costBefore = runtime.residencyCostBytes
        runtime.adoptPreparedPdf(document, byteCount: data.count, sourceData: data)
        XCTAssertEqual(runtime.residencyCostBytes - costBefore, data.count * 2)
        let controller = runtime.pdfController
        controller.adopt(document: document, app: app, annotationStore: annotations, ai: ai,
                         initialPage: 1, tabId: "search", runtime: runtime)
        controller.pdfView = PDFView()
        controller.pdfView?.document = document
        let extracted = await controller.ensureExtracted(pages: [1])
        XCTAssertEqual(extracted, 1)
        XCTAssertTrue(ai.pageTexts[1]?.contains("needle") == true)
        let located = await controller.locateText(pageNumber: 1, query: "NEEDLE")
        XCTAssertEqual(located?.pageNumber, 1)
        XCTAssertFalse(located?.positionData.rects.isEmpty ?? true)
        controller.findQuery("needle")
        XCTAssertTrue(app.findIsSearching)
        controller.findClear()
        XCTAssertFalse(app.findIsSearching)
        await controller.awaitPendingSearch()
        XCTAssertEqual(app.findMatchCount, 0)
        controller.findQuery("needle")
        controller.findQuery("NEEDLE")
        await Task.yield()
        XCTAssertTrue(app.findIsSearching, "A cancelled predecessor cannot finish the replacement's pending status")
        await controller.awaitPendingSearch()
        XCTAssertFalse(app.findIsSearching)
        XCTAssertEqual(app.findMatchCount, 2)
        controller.findQuery("needle")
        XCTAssertTrue(app.findIsSearching)
        var replacement = tab
        replacement.id = "replacement"
        replacement.document = DocumentInfo(kind: .web, pdfPath: "https://example.invalid/", title: nil, pageCount: 1, lastPage: 1)
        app.attachTab(replacement)
        XCTAssertFalse(app.findIsSearching)
        let staleLocation = await controller.locateText(pageNumber: 1, query: "needle")
        XCTAssertNil(staleLocation)
        let staleExtraction = await controller.ensureExtracted(pages: [1])
        XCTAssertEqual(staleExtraction, 0)
        await controller.awaitPendingSearch()
        XCTAssertFalse(app.findIsSearching)
        XCTAssertEqual(app.findMatchCount, 0)
        controller.findClear()
        await controller.awaitPendingSearch()
        runtime.invalidateLoadedPdf()
        XCTAssertNil(runtime.preparedSourceData)
        XCTAssertEqual(runtime.residencyCostBytes, costBefore)
    }

    func testUntrustedRegexAndOversizeQueriesAreRejectedBeforeExtraction() async {
        let document = DocumentInfo(kind: .web, pdfPath: "https://example.invalid/", title: nil, pageCount: 1, lastPage: 1)
        let binding = DocumentBinding(tabId: "search", docId: nil, storageKey: "fixture", generation: UUID())
        var extractions = 0
        let context = AiToolExecutionContext(binding: binding, document: document, currentPage: 1,
            pageCount: 1, pageTexts: [:], annotations: [], isCurrent: { true }, setActivity: { _ in },
            extract: { _ in extractions += 1; return [1: "ordinary literal match"] },
            locate: { _, _ in nil }, createAnnotation: { _ in throw CancellationError() }, navigate: { _ in })
        let engine = AiToolEngine(context: context)
        for query in ["(a+)+$", "(a|aa)*$", "[invalid"] {
            let result = await engine.run(AiToolAction(tool: "searchDocument", args: AiToolArguments(text: query, isRegex: true)),
                                          sessionIdAtStart: "search", actionCount: 0)
            XCTAssertTrue(result.contains("regular expressions are not supported"))
        }
        let rejected = await engine.run(AiToolAction(tool: "searchDocument", args: AiToolArguments(text: String(repeating: "x", count: 513))),
                                         sessionIdAtStart: "search", actionCount: 0)
        XCTAssertTrue(rejected.contains("512"))
        XCTAssertEqual(extractions, 0)
        let literal = await engine.run(AiToolAction(tool: "searchDocument", args: AiToolArguments(text: "LITERAL")),
                                       sessionIdAtStart: "search", actionCount: 0)
        XCTAssertTrue(literal.contains("page 1"))
        XCTAssertEqual(extractions, 1)
    }

    private func pdfData(_ text: String, password: String? = nil) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let options = password.map {
            [kCGPDFContextUserPassword: $0, kCGPDFContextOwnerPassword: $0 + "-owner"] as CFDictionary
        }
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, options))
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        context.textPosition = CGPoint(x: 40, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return bytes as Data
    }
}
