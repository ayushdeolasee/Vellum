#if os(macOS)
import Foundation
import PDFKit
import Testing

@testable import Vellum

// Links inside a document (article or PDF) open in the sidebar browser rather
// than replacing the document or leaving the app. These cover the routing a
// click goes through, from the scheme filter down to the workspace hand-off
// the Browser panel consumes. The click itself (PDFKit's link hit-test, the
// content script's interceptor) needs a real event stream and is not driven here.

@MainActor
@Suite("Document links open in the sidebar browser", .serialized, .scratchDefaults)
struct DocumentLinkRoutingTests {

    @Test("Only absolute http(s) URLs from a page bridge are accepted")
    func bridgeURLFilter() {
        #expect(DocumentLinkActions.browsableURL(from: "https://example.com/a?b=1")?.host == "example.com")
        #expect(DocumentLinkActions.browsableURL(from: "http://example.com") != nil)
        #expect(DocumentLinkActions.browsableURL(from: "javascript:alert(1)") == nil)
        #expect(DocumentLinkActions.browsableURL(from: "file:///etc/passwd") == nil)
        #expect(DocumentLinkActions.browsableURL(from: "mailto:a@example.com") == nil)
        #expect(DocumentLinkActions.browsableURL(from: "/relative/path") == nil)
        #expect(DocumentLinkActions.browsableURL(from: "https://") == nil)
        #expect(DocumentLinkActions.browsableURL(from: nil) == nil)
    }

    @Test("A clicked link reveals the Browser panel and queues the URL once")
    func clickRevealsBrowser() async throws {
        let workspace = WorkspaceStore(sessions: LinkRoutingSessionService())
        await workspace.focusedPane.app.openFile(path: "/tmp/link-routing-test.pdf")
        workspace.sidebarOpen = false
        workspace.sidebarTab = .annotations

        let url = try #require(URL(string: "https://example.com/paper"))
        #expect(DocumentLinkActions.activate(url, workspace: workspace))

        #expect(workspace.sidebarOpen)
        #expect(workspace.sidebarTab == .browser)
        #expect(workspace.takeBrowserOpenRequest() == url)
        // Consumed: a remount of the panel must not reload it a second time.
        #expect(workspace.takeBrowserOpenRequest() == nil)
    }

    @Test("Clicking the same link twice produces two distinct requests")
    func repeatedClickIsDistinct() async throws {
        let workspace = WorkspaceStore(sessions: LinkRoutingSessionService())
        await workspace.focusedPane.app.openFile(path: "/tmp/link-routing-test.pdf")
        let url = try #require(URL(string: "https://example.com"))

        workspace.openInSidebarBrowser(url)
        let first = try #require(workspace.browserOpenRequest)
        workspace.openInSidebarBrowser(url)
        let second = try #require(workspace.browserOpenRequest)
        #expect(first != second)
    }

    @Test("Non-web schemes never reach the sidebar browser")
    func nonWebSchemesIgnored() async throws {
        let workspace = WorkspaceStore(sessions: LinkRoutingSessionService())
        await workspace.focusedPane.app.openFile(path: "/tmp/link-routing-test.pdf")
        workspace.sidebarTab = .annotations

        workspace.openInSidebarBrowser(try #require(URL(string: "file:///tmp/x")))
        #expect(workspace.browserOpenRequest == nil)
        #expect(workspace.sidebarTab == .annotations)
        // A custom app scheme embedded in a PDF is neither browsed nor launched.
        #expect(DocumentLinkActions.activate(
            try #require(URL(string: "someapp://do-thing")), workspace: workspace) == false)
        #expect(workspace.browserOpenRequest == nil)
    }

    @Test("Without a document the request is dropped, not queued for later")
    func noDocumentNoRequest() throws {
        let workspace = WorkspaceStore(sessions: LinkRoutingSessionService())
        workspace.openInSidebarBrowser(try #require(URL(string: "https://example.com")))
        #expect(workspace.browserOpenRequest == nil)
    }

    @Test("PDFView link clicks are routed through the viewer's delegate")
    func pdfDelegateRoutesLinks() async throws {
        let workspace = WorkspaceStore(sessions: LinkRoutingSessionService())
        let app = workspace.focusedPane.app
        await app.openFile(path: "/tmp/link-routing-test.pdf")

        let controller = PdfViewerController()
        controller.app = app
        let coordinator = PdfKitView.Coordinator(controller: controller)
        let view = PDFView()
        coordinator.attach(to: view)
        defer { coordinator.detach(from: view) }
        #expect(view.delegate === coordinator)

        let url = try #require(URL(string: "https://example.com/cited"))
        view.delegate?.pdfViewWillClick?(onLink: view, with: url)
        #expect(workspace.sidebarTab == .browser)
        #expect(workspace.takeBrowserOpenRequest() == url)

        coordinator.detach(from: view)
        #expect(view.delegate == nil)
    }
}

@MainActor
private final class LinkRoutingSessionService: SessionService {
    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .pdf,
            pdfPath: path,
            title: "Link Routing PDF",
            pageCount: 1,
            lastPage: 1
        )
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .web,
            pdfPath: url,
            title: "Link Routing Webpage",
            pageCount: 1,
            lastPage: 1,
            docId: "link-routing-web"
        )
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        try await openWebDocument(url: path, sessionId: sessionId)
    }

    func saveFile(sessionId: String) async throws {}
    func closeFile(sessionId: String) async throws {}
    func readPdfBytes(sessionId: String) async throws -> Data { Data() }
    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}

    func exportVellumweb(
        sessionId: String,
        destPath: String,
        pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(
            path: destPath,
            bytes: 0,
            assetCount: 0,
            assetsSkipped: 0
        )
    }

    func archiveWebpageDefault(
        sessionId: String,
        pages: [WebPageText],
        expectedUrl: String
    ) async throws -> Bool {
        false
    }

    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }

    func createAnnotation(
        sessionId: String,
        input: CreateAnnotationInput
    ) async throws -> Annotation {
        throw SessionServiceError.invalidDocument("Unused in link routing tests")
    }

    func updateAnnotation(
        sessionId: String,
        input: UpdateAnnotationInput
    ) async throws -> Bool {
        false
    }

    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String { sessionId }
}
#endif
