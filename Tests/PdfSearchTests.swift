import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import Vellum

@MainActor
final class PdfSearchTests: XCTestCase {
    func testPrivateSearchFindsCaseInsensitiveUTF16RangesAndCancels() async throws {
        let data = try pdfData("Café needle NEEDLE")
        let result = await PdfSearch(data: data).matches(query: "needle")
        XCTAssertEqual(result.matches.count, 2)
        let document = try XCTUnwrap(PDFDocument(data: data))
        for match in result.matches {
            XCTAssertEqual(document.page(at: match.page)?.selection(for: match.range)?.string?.lowercased(), "needle")
        }
        let cancelled = Task { await PdfSearch(data: data).matches(query: "needle") }
        cancelled.cancel()
        let empty = await cancelled.value
        XCTAssertTrue(empty.matches.isEmpty)
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
        controller.findQuery("needle")
        controller.findClear()
        await controller.awaitPendingSearch()
        XCTAssertEqual(app.findMatchCount, 0)
        controller.findQuery("needle")
        await controller.awaitPendingSearch()
        XCTAssertEqual(app.findMatchCount, 2)
        controller.findQuery("needle")
        var replacement = tab
        replacement.id = "replacement"
        replacement.document = DocumentInfo(kind: .web, pdfPath: "https://example.invalid/", title: nil, pageCount: 1, lastPage: 1)
        app.attachTab(replacement)
        await controller.awaitPendingSearch()
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

    private func pdfData(_ text: String) throws -> Data {
        let bytes = NSMutableData()
        let consumer = try XCTUnwrap(CGDataConsumer(data: bytes))
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
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
