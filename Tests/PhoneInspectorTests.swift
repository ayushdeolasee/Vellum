#if os(iOS)
import Foundation
import SwiftUI
import Testing

@testable import Vellum

// The phone's inspector sheet (#153 P6).
//
// Store-level plus one geometry assertion, deliberately. The three panels the
// sheet hosts are `SidebarContent_iOS` **unchanged** — the same view the iPad
// mounts in its inspector column — so their behaviour is already covered by the
// iPad suites, and re-testing them here would only assert that a `.sheet` is a
// container.
//
// What is genuinely new on this idiom, and therefore what is tested here:
//
//   * the presentation rule the sheet binds to (D2), from the sheet's own side:
//     the reveal paths must open it and SwiftUI's dismissal write-back must not
//     destroy the user's chosen panel;
//   * where the Handwriting section's ink comes from — the live tab's runtime,
//     not `InkRegistry_iOS`, and never with tools armed;
//   * that the *shared* switcher, handed a phone-width sheet instead of an iPad
//     column, still resolves to `.fullLabels`. That one is a derivability
//     assertion rather than a layout test: `InspectorLayout` has a `.menu`
//     fallback written for a column squeezed past its own stated minimum, and
//     nothing but this test stops the phone from silently landing in it.
//
// `.scratchDefaults` gives each test its own defaults domain for the recents
// write `AppStore.adoptOpenedDocument` performs; opening a document is
// unavoidable here, since every inspector rule is conditioned on one.

/// The widths this shell claims, matching `PhoneChromeLayoutTests`: iPhone
/// SE/13 mini (375), the 6.1" class (390), the 6.3" class (402) and the
/// Max/Plus class (430).
///
/// File-scope because `@Test(arguments:)` evaluates its argument list outside
/// the suite's isolation.
private let supportedWidths: [CGFloat] = [375, 390, 402, 430]

@MainActor
@Suite(.serialized, .scratchDefaults)
struct PhoneInspectorTests {

    // MARK: - The shared switcher at phone width

    @Test(
        "The inspector switcher shows full labels at every phone width",
        arguments: supportedWidths)
    func switcherKeepsFullLabels(width: CGFloat) {
        let contentWidth = PhoneInspectorSheet_iOS.contentWidth(at: width)
        #expect(
            InspectorLayout.presentation(for: contentWidth) == .fullLabels,
            """
            At \(Int(width))pt the switcher is handed \(Int(contentWidth))pt and resolved to \
            something other than .fullLabels. The `.icons` and `.menu` branches exist for an \
            inspector COLUMN squeezed below InspectorLayout.minimumWidth; a full-width sheet on \
            a phone is not that case, and degrading here would hide the panel titles for no \
            reason.
            """)
    }

    /// The sheet is full-width on a compact screen, so the only thing between
    /// the screen edge and the switcher is `SidebarContent_iOS`'s own inset.
    /// Stated once, here, so the constant above cannot drift from the view.
    @Test("Sheet content width is the screen minus the switcher's inset")
    func contentWidthIsScreenMinusInset() {
        #expect(
            PhoneInspectorSheet_iOS.contentWidth(at: 390)
                == 390 - InspectorLayout.switcherHorizontalPadding * 2)
    }

    // MARK: - Detents

    @Test("The sheet offers a half and a full height, and only the half keeps the reader live")
    func detentsAreMediumAndLarge() {
        #expect(PhoneInspectorSheet_iOS.detents == [.medium, .large])
        // `presentationBackgroundInteraction(.enabled(upThrough:))` is what lets
        // the document scroll under a half-height sheet. Pinned to `.medium`:
        // at `.large` the document is not visible, so there is nothing to
        // interact with and the sheet should own the screen.
        #expect(PhoneInspectorSheet_iOS.interactiveDetent == .medium)
        #expect(PhoneInspectorSheet_iOS.detents.contains(PhoneInspectorSheet_iOS.interactiveDetent))
    }

    // MARK: - Presentation (D2)

    @Test("The sheet is not presented until there is a document and the user asks")
    func notPresentedByDefault() async throws {
        let fixture = InspectorFixture()
        // D3: WorkspaceStore defaults `sidebarOpen` to true, which is right for
        // a column beside a document and wrong for a sheet over one.
        #expect(fixture.shell.inspectorPresented == false)

        try await fixture.openPdf()
        #expect(fixture.shell.inspectorPresented == false)

        fixture.shell.setInspectorPresented(true)
        #expect(fixture.shell.inspectorPresented)
    }

    @Test("Every reveal path opens the sheet on the panel it asked for")
    func revealPathsPresentTheSheet() async throws {
        let fixture = InspectorFixture()
        try await fixture.openPdf()

        // The shape `AiStore.addReference` writes when the user quotes a
        // selection into the chat: pick the panel, then ask for it.
        fixture.workspace.revealSidebarTab(.ai)
        #expect(fixture.shell.inspectorPresented)
        #expect(fixture.shell.inspectorTab == .ai)

        // ⌥⌘3 / the More menu's "Contents & Notes" go through the shell.
        fixture.shell.revealInspector(.scratchpad)
        #expect(fixture.shell.inspectorPresented)
        #expect(fixture.shell.inspectorTab == .scratchpad)
    }

    @Test(
        "Selecting a tab changes only the visible panel",
        .bug("https://github.com/ayushdeolasee/Vellum/issues/185"))
    func tabSelectionIsIndependentOfPresentation() async throws {
        let fixture = InspectorFixture()
        try await fixture.openPdf()

        fixture.shell.selectInspectorTab(.ai)
        #expect(fixture.shell.inspectorTab == .ai)
        #expect(fixture.shell.inspectorPresented == false)

        fixture.shell.setInspectorPresented(true)

        for tab in WorkspaceStore.SidebarTab.allCases {
            fixture.shell.selectInspectorTab(tab)
            #expect(fixture.shell.inspectorTab == tab)
            #expect(fixture.shell.inspectorPresented)
        }
    }

    @Test("SwiftUI's dismissal write-back on the way to Home preserves the chosen panel")
    func dismissalWriteBackIsIgnoredOffTheReader() async throws {
        let fixture = InspectorFixture()
        try await fixture.openPdf()
        fixture.shell.revealInspector(.ai)

        fixture.shell.showHome()
        #expect(fixture.shell.inspectorPresented == false)
        // This is the write SwiftUI performs as a CONSEQUENCE of the sheet
        // going away with the route. Landing it would flip the window-level
        // preference off and lose the panel for good.
        fixture.shell.setInspectorPresented(false)

        fixture.shell.showReader()
        #expect(fixture.shell.inspectorPresented)
        #expect(fixture.shell.inspectorTab == .ai)
    }

    @Test("Dragging the sheet away on the reader really does close it")
    func dismissalOnTheReaderCloses() async throws {
        let fixture = InspectorFixture()
        try await fixture.openPdf()
        fixture.shell.setInspectorPresented(true)

        fixture.shell.setInspectorPresented(false)
        #expect(fixture.shell.inspectorPresented == false)
        // Still the panel the user last chose, ready for the next reveal.
        #expect(fixture.shell.inspectorTab == .annotations)
    }

    // MARK: - Ink

    @Test("Handwriting reads the live tab's own ink, with no tools armed")
    func inkComesFromTheLiveTabRuntime() async throws {
        let fixture = InspectorFixture()
        // No document, no tab, no runtime to ask.
        #expect(fixture.shell.inspectorInk == nil)

        let tabId = try await fixture.openPdf()
        let ink = try #require(fixture.shell.inspectorInk)
        #expect(ink === fixture.workspace.liveTabRuntime(for: tabId).ink)
        // Ink CREATION is out of scope on this idiom: nothing in the phone
        // chrome exposes a tool, so the palette must never be armed.
        #expect(ink.isActive == false)
    }

    @Test("Switching the active tab retargets the Handwriting section")
    func inkFollowsTheActiveTab() async throws {
        let fixture = InspectorFixture()
        let first = try await fixture.openPdf(named: "phone-ink-a")
        let second = try await fixture.openPdf(named: "phone-ink-b")
        #expect(first != second)

        #expect(fixture.shell.inspectorInk === fixture.workspace.liveTabRuntime(for: second).ink)

        fixture.app.activateTab(first)
        #expect(fixture.shell.inspectorInk === fixture.workspace.liveTabRuntime(for: first).ink)
    }

}

// MARK: - Fixture

/// Workspace + shell + the one pane, built the way `PhoneShell_iOS` builds them:
/// `.singlePane`, because the ink rule above is only correct on an idiom that
/// cannot split. File-scope and `@MainActor`, matching `ChromeFixture` — a type
/// nested in a `@MainActor` suite does not inherit its isolation.
@MainActor
private struct InspectorFixture {
    let workspace: WorkspaceStore
    let shell: PhoneShellStore

    var app: AppStore { workspace.focusedPane.app }

    init() {
        workspace = WorkspaceStore(sessions: PhoneInspectorSessionService(), layout: .singlePane)
        shell = PhoneShellStore(workspace: workspace)
    }

    /// Opens a PDF and returns its tab id, leaving the shell on the reader.
    @discardableResult
    func openPdf(named name: String = "phone-inspector") async throws -> String {
        await app.openFile(path: "/tmp/\(name).pdf")
        shell.didOpenDocument()
        return try #require(app.activeTabId)
    }
}

/// Opens documents without touching the backend. Same shape as the fakes in
/// `PhoneShellStateTests` and `InspectorPresentationTests`, kept local for the
/// same reason: a test double shared between suites becomes a second
/// implementation to keep honest.
@MainActor
private final class PhoneInspectorSessionService: SessionService {
    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: "Inspector PDF", pageCount: 1, lastPage: 1)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .web, pdfPath: url, title: "Inspector Webpage", pageCount: 1, lastPage: 1,
            docId: "inspector-web")
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
        sessionId: String, destPath: String, pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(path: destPath, bytes: 0, assetCount: 0, assetsSkipped: 0)
    }

    func archiveWebpageDefault(
        sessionId: String, pages: [WebPageText], expectedUrl: String
    ) async throws -> Bool {
        false
    }

    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }

    func createAnnotation(
        sessionId: String, input: CreateAnnotationInput
    ) async throws -> Annotation {
        throw SessionServiceError.invalidDocument("Unused in phone inspector tests")
    }

    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool {
        false
    }

    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String { sessionId }
}
#endif
