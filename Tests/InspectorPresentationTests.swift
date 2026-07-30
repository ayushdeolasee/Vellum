import Foundation
import Testing
@testable import Vellum

/// `.serialized` because `RecentFilesService.defaultsOverride` (installed by
/// `ScratchRecents` below) is process-global mutable state, and because every
/// test here drives a real `WorkspaceStore`.
@MainActor
@Suite(.serialized)
struct InspectorPresentationTests {
    /// Redirects the recents write that `AppStore.adoptOpenedDocument` performs
    /// into a throwaway domain. Opening a document is unavoidable here — it is
    /// the whole subject of these tests — and the test bundle is hosted, so
    /// without this the suite would rewrite the real app's recent-documents
    /// list with `/tmp` paths (exactly what `defaultsOverride` was added for).
    private let recents = ScratchRecents()

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

    /// What ⌥⌘1/2/3 do (issue #101). The commands are disabled without a
    /// document, so the interesting half is the reveal: selecting a panel while
    /// the inspector is closed has to open it, or the shortcut appears to do
    /// nothing at all.
    @Test("Revealing a panel selects it and opens a closed inspector")
    func revealSidebarTabOpensTheInspector() async {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        await workspace.focusedPane.app.openFile(path: "/tmp/inspector-test.pdf")
        workspace.setInspectorPresented(false)
        #expect(workspace.inspectorPresented == false)

        workspace.revealSidebarTab(.scratchpad)
        #expect(workspace.sidebarTab == .scratchpad)
        #expect(workspace.sidebarOpen)
        #expect(workspace.inspectorPresented)

        // Reveal, never toggle: pressing the same shortcut again must not close
        // the panel it just opened. ⌥⌘S is the toggle.
        workspace.revealSidebarTab(.scratchpad)
        #expect(workspace.inspectorPresented)
        #expect(workspace.sidebarTab == .scratchpad)
    }

    /// The belt-and-braces half of the gate. The menu items are disabled with
    /// no document; if one ever fired anyway it must not flip `sidebarOpen`,
    /// which is the preference the *next* document would open with.
    @Test("Revealing a panel does nothing without a document")
    func revealSidebarTabIsInertWithoutADocument() {
        let workspace = WorkspaceStore(sessions: InspectorSessionService())
        workspace.sidebarOpen = false
        #expect(workspace.focusedPane.app.document == nil)

        workspace.revealSidebarTab(.ai)
        #expect(workspace.sidebarOpen == false)
        #expect(workspace.sidebarTab == .annotations)
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

/// Scratch UserDefaults domain for the recents write, restored when the test
/// instance dies. A `class` with a `deinit` because Swift Testing has no
/// `tearDown` — mirrors `ScratchStores` in `DocumentRenameTests`.
private final class ScratchRecents {
    private let defaults: UserDefaults
    private let suiteName: String

    init() {
        suiteName = "vellum.inspector.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        RecentFilesService.defaultsOverride = defaults
    }

    deinit {
        RecentFilesService.defaultsOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
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
