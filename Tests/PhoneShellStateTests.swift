#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Vellum

// The phone shell's state machine (#153 P3): routes, chrome, the tab switcher,
// and — the reason this suite is the load-bearing one of the phase — the two
// rules that keep the inspector's window-global state from being destroyed by
// the phone's own routing.
//
// Nothing here mounts a view. `PhoneShellStore` imports no SwiftUI precisely so
// that the sheet-dismissal trap below is decidable without one: the trap is a
// write SwiftUI performs as a CONSEQUENCE of the route changing, and a test
// that had to drive a real sheet to observe it would be a screenshot test of a
// state bug.
//
// `.scratchDefaults` gives each test its own defaults domain for the recents
// write `AppStore.adoptOpenedDocument` performs — opening a document is
// unavoidable here, since every inspector rule is conditioned on one being
// open (D1: on Home the document is still open, which is exactly why the iPad's
// guard does not cover the phone).

@MainActor
@Suite(.serialized, .scratchDefaults)
struct PhoneShellStateTests {

    // MARK: - Routing

    @Test("The shell starts on Home, and open / back / forward move between the two routes")
    func routeMovesBetweenHomeAndReader() async throws {
        let (shell, app) = try await makeShell()
        // Nothing open yet is not the condition for Home — being ON Home is.
        #expect(shell.route == .home)

        await app.openFile(path: "/tmp/phone-route.pdf")
        shell.didOpenDocument()
        #expect(shell.route == .reader)

        shell.showHome()
        #expect(shell.route == .home)
        // D1: Home is a route, so the document is still open and still active
        // behind it. That is what keeps its residency pin and makes the trip
        // back a re-parent rather than a reopen.
        #expect(app.document != nil)
        #expect(app.activeTabId != nil)

        shell.showReader()
        #expect(shell.route == .reader)
    }

    @Test("Closing the last tab falls back to Home; closing one of several does not")
    func closingTheLastTabRoutesHome() async throws {
        let (shell, app) = try await makeShell()
        await app.openFile(path: "/tmp/phone-close-a.pdf")
        let first = try #require(app.activeTabId)
        await app.openFile(path: "/tmp/phone-close-b.pdf")
        shell.didOpenDocument()

        await app.closeTab(first)
        shell.didCloseTab()
        // One document left: the reader still has something to render.
        #expect(shell.route == .reader)

        let last = try #require(app.activeTabId)
        await app.closeTab(last)
        shell.didCloseTab()
        // The phone never mints a start tab (D1), so an empty pane has no
        // reader surface at all — Home is the only honest destination.
        #expect(app.tabs.isEmpty)
        #expect(shell.route == .home)
    }

    // MARK: - The tab switcher and the chrome

    @Test("Opening a document from the switcher closes the switcher")
    func openingFromTheSwitcherClosesIt() async throws {
        let (shell, app) = try await makeShell()
        await app.openFile(path: "/tmp/phone-switcher.pdf")
        shell.didOpenDocument()

        shell.switcherPresented = true
        shell.didOpenDocument()
        #expect(shell.switcherPresented == false)

        // And leaving for Home closes it too: a full-screen cover left up
        // would stack over the screen that replaced the one it covered.
        shell.switcherPresented = true
        shell.showHome()
        #expect(shell.switcherPresented == false)
    }

    @Test(
        "Chrome has explicit hide and reveal actions and resets on reader arrival",
        .bug("https://github.com/ayushdeolasee/Vellum/issues/187"))
    func chromeResetsVisibleOnEveryRouteChangeToReader() async throws {
        let (shell, app) = try await makeShell()
        await app.openFile(path: "/tmp/phone-chrome.pdf")
        shell.didOpenDocument()
        #expect(shell.chromeVisible)

        shell.hideChrome()
        #expect(shell.chromeVisible == false)
        shell.showChrome()
        #expect(shell.chromeVisible)
        shell.setChrome(false)

        // Immersive is per-visit, not a preference: arriving at a document with
        // no chrome leaves only the compact reveal handle and no visible way
        // back to Home.
        shell.showHome()
        shell.showReader()
        #expect(shell.chromeVisible)

        shell.setChrome(false)
        shell.showHome()
        shell.didOpenDocument()
        #expect(shell.chromeVisible)
    }

    // MARK: - The inspector (D2 / D3)

    @Test("The compact default for the inspector is closed")
    func theInspectorStartsClosedOnThePhone() async throws {
        let workspace = makeWorkspace()
        // The iPad default, which is right for a column beside the document and
        // wrong for a sheet over it.
        #expect(workspace.sidebarOpen)
        _ = PhoneShellStore(workspace: workspace)
        #expect(workspace.sidebarOpen == false)
    }

    @Test("The inspector cannot present without a document")
    func theInspectorNeedsADocument() async throws {
        let workspace = makeWorkspace()
        let shell = PhoneShellStore(workspace: workspace)
        shell.showReader()

        // The guard is the workspace's own — no document, no panel — and the
        // reveal must not silently flip the user's preference on for whenever
        // they next open one either.
        shell.setInspectorPresented(true)
        #expect(shell.inspectorPresented == false)
        shell.revealInspector(.ai)
        #expect(shell.inspectorPresented == false)
        #expect(workspace.sidebarOpen == false)
    }

    @Test("Inspector state survives a trip through Home")
    func inspectorStateIsPreservedAcrossHome() async throws {
        let (shell, app) = try await makeShell()
        await app.openFile(path: "/tmp/phone-inspector.pdf")
        shell.didOpenDocument()

        shell.revealInspector(.scratchpad)
        #expect(shell.inspectorPresented)
        #expect(shell.inspectorTab == .scratchpad)

        shell.showHome()
        // The sheet belongs over the document, so it is not presented on Home —
        // but the PREFERENCE behind it is untouched.
        #expect(shell.inspectorPresented == false)

        shell.showReader()
        #expect(shell.inspectorPresented)
        #expect(shell.inspectorTab == .scratchpad)
    }

    @Test("A dismissal write arriving off the reader route is ignored")
    func theSheetDismissalTrapIsClosed() async throws {
        let (shell, app) = try await makeShell()
        await app.openFile(path: "/tmp/phone-dismissal.pdf")
        shell.didOpenDocument()
        shell.revealInspector(.ai)
        #expect(shell.inspectorPresented)

        shell.showHome()
        // THE TRAP. SwiftUI dismisses the sheet because `inspectorPresented`
        // went false, then writes that false back through the binding.
        // `WorkspaceStore.setInspectorPresented`'s own guard does not catch it:
        // that guard only ignores writes made with no document, and on Home the
        // document is still open (D1). Landed, it would flip the user's
        // window-level preference off and the reader would come back bare.
        shell.setInspectorPresented(false)
        #expect(app.document != nil, "the trap only exists because this is true")

        shell.showReader()
        #expect(shell.inspectorPresented)
        #expect(shell.inspectorTab == .ai)

        // The same call from the route that OWNS the sheet is the user closing
        // it, and must be obeyed.
        shell.setInspectorPresented(false)
        #expect(shell.inspectorPresented == false)
        // Reopening from the sheet's own binding works the same way.
        shell.setInspectorPresented(true)
        #expect(shell.inspectorPresented)
    }

    @Test("Every existing reveal path selects its panel and shows it")
    func revealSelectsAPanelAndPresentsIt() async throws {
        let (shell, app) = try await makeShell()
        await app.openFile(path: "/tmp/phone-reveal.pdf")
        shell.didOpenDocument()
        shell.setInspectorPresented(false)

        // `AiStore`'s "quote this in AI" writes `sidebarTab` + `sidebarOpen`
        // through `revealSidebarTab`; the phone routes the same call here and
        // gets the sheet for free.
        shell.revealInspector(.ai)
        #expect(shell.inspectorTab == .ai)
        #expect(shell.inspectorPresented)

        // A reveal from Home (a hardware ⌥⌘1/2/3 is reachable there) means
        // "show me this panel for the document", so it brings the reader with
        // it rather than being a dead shortcut.
        shell.showHome()
        shell.revealInspector(.annotations)
        #expect(shell.route == .reader)
        #expect(shell.inspectorTab == .annotations)
        #expect(shell.inspectorPresented)
    }

    // MARK: - Fixtures

    private func makeWorkspace() -> WorkspaceStore {
        WorkspaceStore(sessions: PhoneShellSessionService(), layout: .singlePane)
    }

    /// A shell over a single-pane workspace, plus that pane's `AppStore`.
    private func makeShell() async throws -> (PhoneShellStore, AppStore) {
        let workspace = makeWorkspace()
        let shell = PhoneShellStore(workspace: workspace)
        return (shell, workspace.focusedPane.app)
    }
}

@MainActor
@Suite("Phone reader chrome hit testing")
struct PhoneReaderChromeHitTestingTests {
    @Test("The immersive reveal control only owns its visible button")
    func revealControlLeavesTheDocumentTouchable() {
        let host = UIHostingController(rootView: ChromeRevealControl_iOS(
            isActive: true,
            chromeVisible: false,
            action: {}))
        host.loadViewIfNeeded()
        host.view.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        host.view.layoutIfNeeded()

        #expect(host.view.hitTest(CGPoint(x: 100, y: 422), with: nil) == nil)
        #expect(host.view.hitTest(CGPoint(x: 352, y: 422), with: nil) != nil)
    }
}

/// Opens documents without touching the backend. Same shape as the fake in
/// `InspectorPresentationTests`, kept local because a test double shared
/// between suites becomes a second implementation to keep honest.
@MainActor
private final class PhoneShellSessionService: SessionService {
    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: "Phone PDF", pageCount: 1, lastPage: 1)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(
            kind: .web, pdfPath: url, title: "Phone Webpage", pageCount: 1, lastPage: 1,
            docId: "phone-web")
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
        throw SessionServiceError.invalidDocument("Unused in phone shell tests")
    }

    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool {
        false
    }

    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String { sessionId }
}
#endif
