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
/// `attach` ends in a `WKWebView` page load. `post` would materialise that web
/// view (only the `push*` helpers are gated on the content script reporting
/// in), but the dismissal branches reach it solely via `clearSelection()`,
/// which they only call when a selection exists, and nothing here makes one.
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
        XCTAssertNil(
            controller.noteComposer,
            "no composer at all: annotationStore is pane-scoped, so a background mount now "
                + "points at another document and a submit would file the note against it")
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

/// The five incidental dismissals are all bridge-message branches, driven here
/// exactly as the content script drives them — including the literal repro in
/// issue #92's title, a stray click on the page, which arrives as
/// `"selection-cleared"`. Without these, reverting any one branch to
/// `noteComposer = nil` leaves the suite green.
@MainActor
final class WebNoteComposerBridgeDismissalTests: XCTestCase {
    private func makePaneWithTab() -> AppStore {
        let app = WorkspaceStore(sessions: DocumentSessionManager()).focusedPane.app
        app.newStartTab()
        return app
    }

    /// Post-placement state, with the composer aged past the `clickOutside`
    /// grace period so the next page event counts as a real dismissal.
    private func agedComposer(
        holding content: String, on app: AppStore, annotations: AnnotationStore? = nil
    ) -> WebViewerController {
        app.beginNoteWithContent(content)
        _ = app.consumePendingNoteContent()
        app.finishNotePlacement(forSessionId: app.activeTabId!)
        let controller = WebViewerController()
        controller.bindForTesting(
            app: app, tabId: app.activeTabId!, annotationStore: annotations)
        controller.openNoteComposerForTesting(
            content: content, openedAt: Date().addingTimeInterval(-1))
        return controller
    }

    func testAStrayClickOnThePageHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "The answer.", on: app)

        controller.handleBridgeMessageForTesting("selection-cleared")

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        XCTAssertEqual(app.mode, .note)
    }

    /// The grace period is load-bearing in the other direction: the placement
    /// click's own event arrives milliseconds after the composer opens, so too
    /// short a window would make every placement instantly self-dismiss.
    func testThePlacementClicksOwnEventDoesNotDismissTheComposer() {
        let app = makePaneWithTab()
        app.beginNoteWithContent("The answer.")
        _ = app.consumePendingNoteContent()
        app.finishNotePlacement(forSessionId: app.activeTabId!)
        let controller = WebViewerController()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openNoteComposerForTesting(content: "The answer.")

        controller.handleBridgeMessageForTesting("selection-cleared")

        XCTAssertNotNil(controller.noteComposer, "a composer this young is not dismissed")
        XCTAssertNil(app.pendingNoteContent, "and nothing is re-queued behind it")
    }

    func testScrollingThePageHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "The answer.", on: app)

        controller.handleBridgeMessageForTesting("viewport-scrolled")

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
    }

    func testAFreshComposerSurvivesTheScrollThePlacementClickCauses() {
        let app = makePaneWithTab()
        app.beginNoteWithContent("The answer.")
        _ = app.consumePendingNoteContent()
        app.finishNotePlacement(forSessionId: app.activeTabId!)
        let controller = WebViewerController()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openNoteComposerForTesting(content: "The answer.")

        controller.handleBridgeMessageForTesting("viewport-scrolled")

        XCTAssertNotNil(controller.noteComposer)
        XCTAssertNil(app.pendingNoteContent)
    }

    func testRightClickingThePageHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "The answer.", on: app)

        controller.handleBridgeMessageForTesting("context-menu", ["found": false])

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        // The branch installs a real NSEvent monitor; take it back down.
        controller.hideContextMenu()
    }

    func testClickingAnExistingNoteHandsTheReplyBack() async {
        let app = makePaneWithTab()
        let annotations = AnnotationStore(app: app)
        let note = await annotations.addNote(
            CreateAnnotationInput(
                type: .note, pageNumber: 1, color: nil, content: "existing",
                positionData: nil))
        let controller = agedComposer(holding: "The answer.", on: app, annotations: annotations)

        controller.handleBridgeMessageForTesting("annotation-click", ["id": note?.id ?? ""])

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
    }

    func testClickingAnExistingHighlightHandsTheReplyBack() async {
        let app = makePaneWithTab()
        let annotations = AnnotationStore(app: app)
        let highlight = await annotations.addHighlight(
            CreateAnnotationInput(
                type: .highlight, pageNumber: 1, color: nil, content: nil,
                positionData: nil))
        let controller = agedComposer(holding: "The answer.", on: app, annotations: annotations)

        controller.handleBridgeMessageForTesting("annotation-click", ["id": highlight?.id ?? ""])

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
    }

    /// A second "Add as note" while a composer is still open. The panel's
    /// button is not gated on one, so the placement click that follows used to
    /// overwrite the first reply with the second and lose it outright.
    func testASecondPlacementRescuesTheComposerItReplaces() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "First reply.", on: app)

        // The user picks "Add as note" on a second reply, then clicks the page.
        app.beginNoteWithContent("Second reply.")
        controller.handleBridgeMessageForTesting(
            "note-placed",
            ["start": 0, "end": 4, "text": "word", "pageNumber": 1, "x": 0, "y": 0])

        XCTAssertEqual(
            controller.noteComposer?.initialContent, "Second reply.",
            "the composer shows the reply that was just placed")
        XCTAssertEqual(
            app.pendingNoteContent, "First reply.",
            "and the one it displaced goes back on the queue rather than vanishing")
        XCTAssertEqual(app.mode, .note)
    }
}
