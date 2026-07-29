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

    /// Cancel (or Escape, or a completed submit) never routes through
    /// `restorePendingNote` — a discard the user asked for stays a discard.
    func testExplicitCancelLeavesNothingQueued() {
        let app = makePaneWithTab()
        _ = placeNote(app, content: "The answer.")

        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
        XCTAssertNil(app.tabs.first(where: { $0.id == app.activeTabId })?.pendingNoteContent)
    }

    /// The draft handed back is the composer's live text, so edits made before
    /// the misclick survive too — not just the reply it opened with.
    func testEditsMadeInTheComposerSurviveTheDismissal() {
        let app = makePaneWithTab()
        let session = app.activeTabId!
        _ = placeNote(app, content: "The answer.")

        app.restorePendingNote("The answer. — check this", forSessionId: session)

        XCTAssertEqual(app.pendingNoteContent, "The answer. — check this")
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
