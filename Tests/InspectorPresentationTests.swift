import Foundation
import Testing
@testable import Vellum

/// `.scratchDefaults` gives each test its own domain for the recents write that
/// `AppStore.adoptOpenedDocument` performs — opening a document is unavoidable
/// here, it is the whole subject of these tests. `.serialized` remains only
/// because every test drives a real `WorkspaceStore`; the recents redirect is
/// no longer process-global, so it is not a reason to serialize (#102).
@MainActor
@Suite(.serialized, .scratchDefaults)
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

    @Test(
        "Opening an already-tabbed document from Home preserves a closed inspector",
        arguments: [DocumentKind.pdf, .web]
    )
    func reopeningExistingDocumentPreservesClosedInspector(
        kind: DocumentKind
    ) async throws {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        let app = workspace.focusedPane.app
        let location: String

        switch kind {
        case .pdf:
            location = "/tmp/inspector-test.pdf"
            await app.openFile(path: location)
        case .web:
            location = "https://example.com"
            await app.openUrl(location)
        }

        let originalTabId = try #require(app.activeTabId)
        workspace.sidebarTab = .scratchpad
        workspace.setInspectorPresented(false)
        app.newStartTab()

        switch kind {
        case .pdf:
            await app.openFile(path: location)
        case .web:
            await app.openUrl(location)
        }

        #expect(app.activeTabId == originalTabId)
        #expect(app.tabs.count == 1)
        #expect(workspace.sidebarOpen == false)
        #expect(workspace.inspectorPresented == false)
        #expect(workspace.sidebarTab == .scratchpad)
    }

    /// The other half of the rule above, and the one nothing else pins: a
    /// document that is NOT already tabbed is a fresh open, so it still reveals
    /// the panel even if the user closed it on the previous document. Without
    /// this, deleting `adoptOpenedDocument`'s `sidebarOpen = true` — or sliding
    /// it back above the already-tabbed early return — would pass the suite.
    @Test("Opening a genuinely new document reveals the inspector")
    func newDocumentRevealsInspector() async throws {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        let app = workspace.focusedPane.app

        await app.openFile(path: "/tmp/inspector-first.pdf")
        workspace.setInspectorPresented(false)
        #expect(workspace.sidebarOpen == false)

        await app.openFile(path: "/tmp/inspector-second.pdf")
        #expect(app.tabs.count == 2)
        #expect(workspace.sidebarOpen)
        #expect(workspace.inspectorPresented)
    }

    @Test("Remembered inspector width ignores out-of-range and suppressed geometry")
    func rememberSidebarWidthRejectsUnusableMeasurements() async throws {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        let app = workspace.focusedPane.app
        #expect(workspace.sidebarWidth == InspectorLayout.idealWidth)

        await app.openFile(path: "/tmp/inspector-test.pdf")
        workspace.sidebarOpen = true

        // The resize envelope is inclusive at both ends.
        workspace.rememberSidebarWidth(InspectorLayout.minimumWidth)
        #expect(workspace.sidebarWidth == InspectorLayout.minimumWidth)
        workspace.rememberSidebarWidth(InspectorLayout.maximumWidth)
        #expect(workspace.sidebarWidth == InspectorLayout.maximumWidth)

        // Anything outside it is AppKit mid-transition, not a user choice.
        workspace.rememberSidebarWidth(InspectorLayout.minimumWidth - 1)
        workspace.rememberSidebarWidth(InspectorLayout.maximumWidth + 1)
        #expect(workspace.sidebarWidth == InspectorLayout.maximumWidth)

        // In-range, but measured while a start tab suppresses the inspector —
        // the collapse must not overwrite the user's width.
        workspace.rememberSidebarWidth(400)
        #expect(workspace.sidebarWidth == 400)
        app.newStartTab()
        workspace.rememberSidebarWidth(InspectorLayout.minimumWidth)
        #expect(workspace.sidebarWidth == 400)
    }

    @Test("Splitting and returning preserves a closed inspector")
    func splitAndReturnPreservesClosedInspector() async {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        let originalPane = workspace.focusedPane
        await originalPane.app.openFile(path: "/tmp/inspector-test.pdf")
        workspace.sidebarTab = .ai
        workspace.setInspectorPresented(false)

        workspace.splitFocused(.horizontal)
        #expect(workspace.focusedPane.id != originalPane.id)
        #expect(workspace.focusedPane.app.document == nil)
        #expect(workspace.sidebarOpen == false)
        #expect(workspace.inspectorPresented == false)

        workspace.focus(originalPane.id)
        #expect(workspace.sidebarOpen == false)
        #expect(workspace.inspectorPresented == false)
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
