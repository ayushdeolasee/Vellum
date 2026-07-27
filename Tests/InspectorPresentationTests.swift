import Foundation
import Testing
@testable import Vellum

@MainActor
struct InspectorPresentationTests {
    @Test("PDF to New Tab to PDF preserves inspector state")
    func pdfNewTabPdf() async throws {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        let app = workspace.focusedPane.app

        await app.openFile(path: "/tmp/inspector-test.pdf")
        let pdfTabId = try #require(app.activeTabId)
        workspace.sidebarOpen = true
        workspace.sidebarTab = .scratchpad
        workspace.rememberSidebarWidth(512)

        #expect(workspace.inspectorPresented)
        #expect(workspace.sidebarWidth == 512)

        app.newStartTab()
        #expect(workspace.inspectorPresented == false)

        // SwiftUI's conditional inspector writes false as the document goes
        // away. It must not turn the temporary suppression into user intent.
        workspace.setInspectorPresented(false)
        workspace.rememberSidebarWidth(0)
        #expect(workspace.sidebarOpen)
        #expect(workspace.sidebarTab == .scratchpad)
        #expect(workspace.sidebarWidth == 512)

        app.activateTab(pdfTabId)
        #expect(workspace.inspectorPresented)
        #expect(workspace.sidebarTab == .scratchpad)
        #expect(workspace.sidebarWidth == 512)
    }

    @Test("PDF to Web to PDF preserves open and selected inspector state")
    func pdfWebPdf() async throws {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        let app = workspace.focusedPane.app

        await app.openFile(path: "/tmp/inspector-test.pdf")
        let pdfTabId = try #require(app.activeTabId)
        workspace.sidebarOpen = true
        workspace.sidebarTab = .ai

        await app.openUrl("https://example.com")
        let webTabId = try #require(app.activeTabId)
        #expect(webTabId != pdfTabId)
        #expect(workspace.inspectorPresented)
        #expect(workspace.sidebarTab == .ai)

        app.activateTab(pdfTabId)
        #expect(workspace.inspectorPresented)
        #expect(workspace.sidebarTab == .ai)

        // An explicit close on a document remains authoritative across tabs.
        workspace.setInspectorPresented(false)
        app.activateTab(webTabId)
        app.activateTab(pdfTabId)
        #expect(workspace.inspectorPresented == false)
        #expect(workspace.sidebarOpen == false)
        #expect(workspace.sidebarTab == .ai)
    }
}

@MainActor
private final class InspectorSessionService: SessionService {
    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .pdf,
            pdfPath: path,
            title: "Inspector PDF",
            pageCount: 1,
            lastPage: 1
        )
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .web,
            pdfPath: url,
            title: "Inspector Webpage",
            pageCount: 1,
            lastPage: 1,
            docId: "inspector-web"
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
        throw SessionServiceError.invalidDocument("Unused in inspector tests")
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
