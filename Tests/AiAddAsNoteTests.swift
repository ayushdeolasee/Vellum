import XCTest
@testable import Vellum

/// The "Add as note" hand-off out of the AI panel: `beginNoteWithContent`
/// queues the reply on `AppStore` and arms note mode, then the viewer that
/// places the note consumes it.
///
/// Issue #57: the PDF viewer consumed the payload
/// (`PdfSelectionBridge.placeNote`), the web viewer never did — its
/// `"note-placed"` handler went straight to `setMode(.view)`, which discards
/// anything unconsumed — so on a webpage the button just opened an empty "new
/// note" composer and the reply was silently thrown away. These pin the
/// contract both placement paths have to honor.
@MainActor
final class AiAddAsNoteTests: XCTestCase {
    /// `DocumentSessionManager()` is inert until a document is opened, so it is
    /// a usable stand-in for the real session service here.
    private func makeStore() -> AppStore { AppStore(sessions: DocumentSessionManager()) }

    func testBeginNoteWithContentArmsNoteModeCarryingTheReply() {
        let store = makeStore()
        store.beginNoteWithContent("The answer.")
        XCTAssertEqual(store.mode, .note)
        XCTAssertEqual(store.pendingNoteContent, "The answer.")
    }

    func testConsumingReturnsTheReplyExactlyOnce() {
        let store = makeStore()
        store.beginNoteWithContent("The answer.")
        XCTAssertEqual(store.consumePendingNoteContent(), "The answer.")
        XCTAssertNil(store.consumePendingNoteContent(), "the queued reply is single-use")
    }

    /// The exact trap the web viewer fell into: leaving note mode destroys the
    /// payload, so a placement handler MUST consume it *before* it calls
    /// `setMode`. Reordering those two lines is the regression this catches.
    func testLeavingNoteModeBeforeConsumingDropsTheReply() {
        let store = makeStore()
        store.beginNoteWithContent("The answer.")
        store.setMode(.view)
        XCTAssertNil(
            store.consumePendingNoteContent(),
            "returning to view mode must clear the queued reply — placement handlers consume first")
    }

    /// The plain sticky-note toolbar tool queues nothing, so a placement made
    /// with it still opens an empty note to type into.
    func testPlainNoteToolQueuesNoContent() {
        let store = makeStore()
        store.setMode(.note)
        XCTAssertNil(store.consumePendingNoteContent())
    }

    /// The web composer opens pre-filled from this field; it defaults to empty
    /// so a plain note-tool placement is unchanged.
    func testWebComposerStateDefaultsToEmptyContent() {
        let state = WebNoteComposerState(
            point: .zero,
            anchor: WebNoteAnchor(start: 0, end: 0, text: "", prefix: nil, suffix: nil, pageNumber: 1),
            openedAt: Date())
        XCTAssertEqual(state.initialContent, "")
    }
}

/// Issue #92: on the web path the placement click only *opens* a composer, so
/// between the click and the submit the composer holds the sole copy of the
/// queued reply — `consumePendingNoteContent` has already emptied the store. A
/// stray click on the page unmounted that composer and the reply went with it.
/// `restorePendingNote` is the recovery seam the viewer calls for every
/// dismissal the user did not explicitly ask for.
@MainActor
final class WebNoteComposerDismissalTests: XCTestCase {
    /// A pane with one real tab — `restorePendingNote` is tab-scoped, so the
    /// bare `AppStore` used above (no tabs) is not enough here.
    private func makePaneWithTab() -> AppStore {
        let app = WorkspaceStore(sessions: DocumentSessionManager()).focusedPane.app
        app.newStartTab()
        return app
    }

    /// Walks the real placement sequence: arm, click (consume + leave note
    /// mode), then a stray click dismisses the composer.
    private func placeNote(_ app: AppStore, content: String) -> String? {
        app.beginNoteWithContent(content)
        let consumed = app.consumePendingNoteContent()
        app.finishNotePlacement(forSessionId: app.activeTabId!)
        return consumed
    }

    func testStrayDismissalReturnsTheReplyAndTheNextPlacementUsesIt() {
        let app = makePaneWithTab()
        let session = app.activeTabId!
        XCTAssertEqual(placeNote(app, content: "The answer."), "The answer.")
        // Post-placement, pre-dismissal: the store is empty, which is why the
        // old code lost the reply outright.
        XCTAssertNil(app.pendingNoteContent)

        app.restorePendingNote("The answer.", forSessionId: session)

        XCTAssertEqual(app.mode, .note, "placement re-arms, so one more click re-offers the note")
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        XCTAssertEqual(
            app.consumePendingNoteContent(), "The answer.",
            "the next placement click gets the reply back")
    }

    /// A plain note-tool placement clicked away from has nothing to preserve;
    /// re-arming note mode there would be friction with no payoff.
    func testEmptyDraftDoesNotReArmNoteMode() {
        let app = makePaneWithTab()
        let session = app.activeTabId!
        app.setMode(.note)
        XCTAssertNil(app.consumePendingNoteContent())
        app.finishNotePlacement(forSessionId: session)

        app.restorePendingNote("   \n ", forSessionId: session)

        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
    }

    /// The draft belongs to the tab that was composing it. Switching tabs also
    /// unmounts the composer, so the restore must land on the origin tab and
    /// leave the tab now on screen completely alone.
    func testDraftIsRestoredOntoItsOwnTabNotTheOneOnScreen() {
        let app = makePaneWithTab()
        let origin = app.activeTabId!
        _ = placeNote(app, content: "The answer.")
        app.newStartTab()
        let other = app.activeTabId!

        app.restorePendingNote("The answer.", forSessionId: origin)

        XCTAssertEqual(app.activeTabId, other)
        XCTAssertEqual(app.mode, .view, "the foreground tab must not be dragged into note mode")
        XCTAssertNil(app.pendingNoteContent)

        app.activateTab(origin)
        XCTAssertEqual(app.mode, .note)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
    }

    /// A dismissal reported after its tab is gone has nowhere to land.
    func testRestoringForAnUnknownTabIsIgnored() {
        let app = makePaneWithTab()
        _ = placeNote(app, content: "The answer.")

        app.restorePendingNote("The answer.", forSessionId: "closed-tab")

        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
    }

    /// Restoring must not strand the tab in a half-armed state: note mode and
    /// region capture are mutually exclusive everywhere else in `AppStore`.
    func testRestoringClearsAnyArmedRegionCapture() {
        let app = makePaneWithTab()
        let session = app.activeTabId!
        _ = placeNote(app, content: "The answer.")
        app.beginRegionCapture(target: .scratchpad)

        app.restorePendingNote("The answer.", forSessionId: session)

        XCTAssertEqual(app.mode, .note)
        XCTAssertEqual(app.regionCaptureTarget, .ai)
        XCTAssertNil(app.tabs.first(where: { $0.id == session })?.regionCaptureTarget)
    }
}

/// The half of issue #92 that lives in the viewer: which composer dismissals
/// hand the draft back and which discard it.
///
/// `WebViewerController.bindForTesting` and friends are the seam — the real
/// `attach` ends in a `WKWebView` page load, and none of the dismissal paths
/// touch the web view (every `post` is gated on the content script having
/// reported in, which it never does here).
@MainActor
final class WebNoteComposerControllerTests: XCTestCase {
    private func makePaneWithTab() -> AppStore {
        let app = WorkspaceStore(sessions: DocumentSessionManager()).focusedPane.app
        app.newStartTab()
        return app
    }

    /// Leaves the store in the exact post-placement-click state the bug lived
    /// in: note mode finished, the queue emptied by the placement, and the only
    /// copy of the reply now inside the composer.
    private func composerHolding(_ content: String, on app: AppStore) -> WebViewerController {
        app.beginNoteWithContent(content)
        _ = app.consumePendingNoteContent()
        app.finishNotePlacement(forSessionId: app.activeTabId!)
        XCTAssertNil(app.pendingNoteContent, "precondition: the composer holds the only copy")

        let controller = WebViewerController()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openNoteComposerForTesting(content: content)
        return controller
    }

    /// A stray click on a link, an SPA soft-navigation, or a tab switch all
    /// land here. This is the path the first cut of the fix missed.
    func testIncidentalTeardownHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)

        controller.closeNotePopovers()

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        XCTAssertEqual(app.mode, .note, "one more click re-offers the note")
    }

    /// Switching tabs goes through `deactivate`, which must not be a discard
    /// either — the draft waits on the tab the user is coming back to.
    func testDeactivatingTheTabHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)

        controller.deactivate()

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
    }

    /// Cancel, Escape, and a completed submit all route through
    /// `closeNoteComposer`. Wiring that one to the restore path would make the
    /// note queue impossible to empty, so this is the guard on the guard.
    func testExplicitCloseDiscardsTheDraft() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)

        controller.closeNoteComposer()

        XCTAssertNil(controller.noteComposer)
        XCTAssertNil(app.pendingNoteContent, "a discard the user asked for stays a discard")
        XCTAssertEqual(app.mode, .view)
    }

    /// What comes back is the composer's live text, not the reply it opened
    /// with — edits made before the misclick survive too.
    func testEditsMadeInTheComposerAreWhatComesBack() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)

        controller.updateNoteComposerDraft("The answer. — check this")
        controller.closeNotePopovers()

        XCTAssertEqual(app.pendingNoteContent, "The answer. — check this")
    }

    /// A plain note-tool placement holds nothing worth preserving, so clicking
    /// away from it is unchanged — no queue, no re-armed note mode.
    func testDismissingAnEmptyComposerArmsNothing() {
        let app = makePaneWithTab()
        let controller = WebViewerController()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openNoteComposerForTesting(content: "")

        controller.closeNotePopovers()

        XCTAssertNil(app.pendingNoteContent)
        XCTAssertEqual(app.mode, .view)
    }

    /// The draft mirror is reseeded per placement. Without that, a second
    /// composer would inherit the first one's text and dismissing it would
    /// re-queue a reply the user already dealt with.
    func testTheDraftMirrorDoesNotLeakBetweenPlacements() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)
        controller.updateNoteComposerDraft("edited")

        // A second placement on the same controller, this time a plain one.
        controller.openNoteComposerForTesting(content: "")
        controller.closeNotePopovers()

        XCTAssertNil(app.pendingNoteContent)
        XCTAssertEqual(app.mode, .view)
    }

    /// "Add note here" is the other door into a composer, and it now takes the
    /// queued reply with it — matching `PdfSelectionBridge.addNoteFromContextMenu`.
    /// Leaving it empty while a reply sat armed was the stranding case.
    func testContextMenuAddNoteCarriesTheQueuedReply() {
        let app = makePaneWithTab()
        let controller = WebViewerController()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openContextMenuForTesting()
        app.beginNoteWithContent("The answer.")

        controller.contextMenuAddNote()

        XCTAssertEqual(controller.noteComposer?.initialContent, "The answer.")
        XCTAssertNil(app.pendingNoteContent, "consumed, not duplicated")
        XCTAssertEqual(app.mode, .view, "placing a note leaves note mode, as on the PDF path")
    }

    /// `consumePendingNoteContent` reads the ACTIVE tab's queue, so a menu still
    /// mounted on a tab the user has left would otherwise steal the reply armed
    /// for the tab now on screen. The bridge-message path guards this; this one
    /// is a button action and has to guard it itself.
    func testContextMenuAddNoteOnABackgroundTabCannotStealTheForegroundReply() {
        let app = makePaneWithTab()
        let controller = WebViewerController()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openContextMenuForTesting()

        app.newStartTab()
        app.beginNoteWithContent("Reply for the tab now on screen")

        controller.contextMenuAddNote()

        XCTAssertEqual(app.pendingNoteContent, "Reply for the tab now on screen")
        XCTAssertEqual(app.mode, .note, "the foreground tab stays armed")
        XCTAssertEqual(controller.noteComposer?.initialContent, "")
    }

    /// The controller belongs to one tab. A teardown it reports after the user
    /// has moved on must land on its own tab's record and leave the tab now on
    /// screen alone.
    func testTeardownOnABackgroundTabDoesNotArmTheForegroundOne() {
        let app = makePaneWithTab()
        let origin = app.activeTabId!
        let controller = composerHolding("The answer.", on: app)
        app.newStartTab()

        controller.closeNotePopovers()

        XCTAssertEqual(app.mode, .view, "the foreground tab must not be dragged into note mode")
        XCTAssertNil(app.pendingNoteContent)
        XCTAssertEqual(app.tabs.first(where: { $0.id == origin })?.pendingNoteContent, "The answer.")
    }
}
