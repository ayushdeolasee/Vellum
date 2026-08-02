import XCTest
@testable import Vellum

// Issue #92 — the web note composer's draft must survive dismissals the user
// did not ask for.
//
// On the web path the placement tap only *opens* a composer; the note is not
// written until the user submits. Between those two steps the composer holds
// the sole copy of a queued AI reply, because `consumePendingNoteContent` has
// already emptied the store. A stray tap on the page, a scroll, a link, a
// context menu or a tab switch all unmounted that composer and the reply went
// with it. `AppStore.restorePendingNote` is the recovery seam the viewer calls
// on every one of those paths.
//
// **Where this file comes from (#129 packet 7 §4.3).** Main keeps these suites
// in `Tests/AiAddAsNoteTests.swift` alongside the AI-panel half of the feature.
// On the iPad the two halves land in different packets, so the AppStore half
// stays in `AiAddAsNoteTests` (packet 5's) and the #92 half lives here. Nobody
// ports the file twice.
//
// **The controller under test is the iOS one** — `WebViewerController_iOS`, from
// `Vellum/Platform/iOS/WebViewerView_iOS.swift`. Main's class is plain
// `WebViewerController` and a reader diffing the two files will expect that
// name; the iPad's is suffixed because `Vellum/Views/Web/WebViewerView.swift`
// still carries the macOS one in the shared tree.
//
// **Gesture vocabulary.** Test *names and comments* say "tap" and "long press"
// where main says "click" and "right-click". The bridge message **type strings**
// (`"selection-cleared"`, `"context-menu"`, `"note-placed"`, …) are the content
// script's wire protocol and stay byte-identical.
//
// **Mutation check (main's commit message is explicit that its first two cuts
// were green with the whole viewer-side fix reverted).** Revert each of the six
// `returnNoteComposerDraft()` call sites in `WebViewerView_iOS` to a bare
// `noteComposer = nil`, one at a time, and exactly one test here must fail each
// time. See the map above `WebNoteDraftBridgeTests`.

/// The store-level half: `restorePendingNote` re-arms placement and puts the
/// draft back on the queue.
@MainActor
final class WebNoteDraftStoreTests: XCTestCase {
    /// A pane with one real tab — `restorePendingNote` is tab-scoped, so a bare
    /// `AppStore` with no tabs is not enough here.
    private func makePaneWithTab() -> AppStore {
        let app = WorkspaceStore(sessions: DocumentSessionManager()).focusedPane.app
        app.newStartTab()
        return app
    }

    /// Walks the real placement sequence: arm, tap (consume, then leave note
    /// mode), leaving the composer holding the only copy.
    ///
    /// Main calls `app.finishNotePlacement(forSessionId:)` for the second step.
    /// The iPad has no such method — `WebViewerController_iOS
    /// .presentNoteComposer` calls `setMode(.view)` directly — so this walks the
    /// same two state changes the viewer actually makes.
    @discardableResult
    private func placeNote(_ app: AppStore, content: String) -> String? {
        app.beginNoteWithContent(content)
        let consumed = app.consumePendingNoteContent()
        app.setMode(.view)
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

        XCTAssertEqual(app.mode, .note, "placement re-arms, so one more tap re-offers the note")
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        XCTAssertEqual(
            app.consumePendingNoteContent(), "The answer.",
            "the next placement tap gets the reply back")
    }

    /// A plain note-tool placement tapped away from has nothing to preserve;
    /// re-arming note mode there would be friction with no payoff.
    func testEmptyDraftDoesNotReArmNoteMode() {
        let app = makePaneWithTab()
        let session = app.activeTabId!
        app.setMode(.note)
        XCTAssertNil(app.consumePendingNoteContent())
        app.setMode(.view)

        app.restorePendingNote("   \n ", forSessionId: session)

        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
    }

    /// A dismissal reported after its tab is gone has nowhere to land.
    func testRestoringForAnUnknownTabIsIgnored() {
        let app = makePaneWithTab()
        placeNote(app, content: "The answer.")

        app.restorePendingNote("The answer.", forSessionId: "closed-tab")

        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
    }

    /// The iPad's documented degradation: a restore aimed at a tab that is no
    /// longer on screen is dropped rather than mis-filed onto the tab that is.
    /// This pins the *safe* half of that gap — the foreground tab is untouched —
    /// which is the property that must survive the eventual fix.
    ///
    /// TODO(#129 packet 4): main's two background-tab cases,
    /// `testDraftIsRestoredOntoItsOwnTabNotTheOneOnScreen` and
    /// `testRestoringClearsAnyArmedRegionCapture`, are deferred with the
    /// tab-residency port. Both write into the origin tab's record, and `PdfTab`
    /// (Vellum/Models/Models.swift) carries neither `pendingNoteContent` nor
    /// `regionCaptureTarget` yet. Restore them from main's
    /// `Tests/AiAddAsNoteTests.swift:125` and `:156` the moment those fields
    /// land, and replace this case with the first of them.
    func testRestoringOntoABackgroundTabDropsTheDraftRatherThanMisfilingIt() {
        let app = makePaneWithTab()
        let origin = app.activeTabId!
        placeNote(app, content: "The answer.")
        app.newStartTab()
        let other = app.activeTabId!

        app.restorePendingNote("The answer.", forSessionId: origin)

        XCTAssertEqual(app.activeTabId, other)
        XCTAssertEqual(app.mode, .view, "the foreground tab must not be dragged into note mode")
        XCTAssertNil(app.pendingNoteContent, "and must not inherit another tab's reply")
    }
}

/// The half that lives in the viewer: which composer dismissals hand the draft
/// back and which discard it.
///
/// `bindForTesting` and friends are the seam — the real `attach` ends in a
/// `WKWebView` page load. `post` would materialise that web view (only the
/// `push*` helpers are gated on the content script reporting in), but the
/// dismissal branches reach it solely via `clearSelection()`, which they only
/// call when a selection exists, and nothing here makes one.
@MainActor
final class WebNoteDraftControllerTests: XCTestCase {
    private func makePaneWithTab() -> AppStore {
        let app = WorkspaceStore(sessions: DocumentSessionManager()).focusedPane.app
        app.newStartTab()
        return app
    }

    /// Leaves the store in the exact post-placement-tap state the bug lived in:
    /// note mode finished, the queue emptied by the placement, and the only copy
    /// of the reply now inside the composer.
    private func composerHolding(_ content: String, on app: AppStore) -> WebViewerController_iOS {
        app.beginNoteWithContent(content)
        _ = app.consumePendingNoteContent()
        app.setMode(.view)
        XCTAssertNil(app.pendingNoteContent, "precondition: the composer holds the only copy")

        let controller = WebViewerController_iOS()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openNoteComposerForTesting(content: content)
        return controller
    }

    /// A stray tap on a link, an SPA soft-navigation, or a tab switch all land
    /// here. This is the path the first cut of the fix missed.
    func testIncidentalTeardownHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)

        controller.closeNotePopovers()

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        XCTAssertEqual(app.mode, .note, "one more tap re-offers the note")
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
    /// with — edits made before the mis-tap survive too.
    func testEditsMadeInTheComposerAreWhatComesBack() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)

        controller.updateNoteComposerDraft("The answer. — check this")
        controller.closeNotePopovers()

        XCTAssertEqual(app.pendingNoteContent, "The answer. — check this")
    }

    /// A plain note-tool placement holds nothing worth preserving, so tapping
    /// away from it is unchanged — no queue, no re-armed note mode.
    func testDismissingAnEmptyComposerArmsNothing() {
        let app = makePaneWithTab()
        let controller = WebViewerController_iOS()
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
    /// queued reply with it — matching the PDF placement path. Leaving it empty
    /// while a reply sat armed was the stranding case.
    func testContextMenuAddNoteCarriesTheQueuedReply() {
        let app = makePaneWithTab()
        let controller = WebViewerController_iOS()
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
    /// for the tab now on screen. The bridge-message path guards this in
    /// `handleMessage`; this one is a button action and has to guard it itself.
    func testContextMenuAddNoteOnABackgroundTabCannotStealTheForegroundReply() {
        let app = makePaneWithTab()
        let controller = WebViewerController_iOS()
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
    /// has moved on must leave the tab now on screen alone.
    ///
    /// Main additionally asserts the draft lands on the origin tab's record;
    /// see the deferral note on `WebNoteDraftStoreTests`. On the iPad it is
    /// dropped, so only the no-collateral-damage half is asserted here.
    func testTeardownOnABackgroundTabDoesNotArmTheForegroundOne() {
        let app = makePaneWithTab()
        let controller = composerHolding("The answer.", on: app)
        app.newStartTab()

        controller.closeNotePopovers()

        XCTAssertEqual(app.mode, .view, "the foreground tab must not be dragged into note mode")
        XCTAssertNil(app.pendingNoteContent)
    }
}

/// The incidental dismissals are all bridge-message branches, driven here
/// exactly as the content script drives them — including the literal repro in
/// issue #92's title, a stray tap on the page, which arrives as
/// `"selection-cleared"`. Without these, reverting any one branch to
/// `noteComposer = nil` leaves the suite green.
///
/// Mutation map — which `returnNoteComposerDraft()` call site each case pins:
///
/// | call site (`WebViewerView_iOS`)          | case |
/// |---|---|
/// | `closeNotePopovers()`                    | `testIncidentalTeardownHandsTheReplyBack` |
/// | `"selection-cleared"` + `clickOutside`   | `testAStrayTapOnThePageHandsTheReplyBack` |
/// | `"context-menu"`                         | `testLongPressingThePageHandsTheReplyBack` |
/// | `"annotation-click"` note branch         | `testTappingAnExistingNoteHandsTheReplyBack` |
/// | `"annotation-click"` highlight branch    | `testTappingAnExistingHighlightHandsTheReplyBack` |
/// | `"viewport-scrolled"` + 0.4 s grace      | `testScrollingThePageHandsTheReplyBack` |
@MainActor
final class WebNoteDraftBridgeTests: XCTestCase {
    private func makePaneWithTab() -> AppStore {
        let app = WorkspaceStore(sessions: DocumentSessionManager()).focusedPane.app
        app.newStartTab()
        return app
    }

    /// Post-placement state, with the composer aged past the `clickOutside`
    /// grace period so the next page event counts as a real dismissal.
    private func agedComposer(
        holding content: String, on app: AppStore, annotations: AnnotationStore? = nil
    ) -> WebViewerController_iOS {
        app.beginNoteWithContent(content)
        _ = app.consumePendingNoteContent()
        app.setMode(.view)
        let controller = WebViewerController_iOS()
        controller.bindForTesting(
            app: app, tabId: app.activeTabId!, annotationStore: annotations)
        controller.openNoteComposerForTesting(
            content: content, openedAt: Date().addingTimeInterval(-1))
        return controller
    }

    func testAStrayTapOnThePageHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "The answer.", on: app)

        controller.handleBridgeMessageForTesting("selection-cleared")

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
        XCTAssertEqual(app.mode, .note)
    }

    /// The grace period is load-bearing in the other direction: the placement
    /// tap's own event arrives milliseconds after the composer opens, so too
    /// short a window would make every placement instantly self-dismiss.
    func testThePlacementTapsOwnEventDoesNotDismissTheComposer() {
        let app = makePaneWithTab()
        app.beginNoteWithContent("The answer.")
        _ = app.consumePendingNoteContent()
        app.setMode(.view)
        let controller = WebViewerController_iOS()
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

    func testAFreshComposerSurvivesTheScrollThePlacementTapCauses() {
        let app = makePaneWithTab()
        app.beginNoteWithContent("The answer.")
        _ = app.consumePendingNoteContent()
        app.setMode(.view)
        let controller = WebViewerController_iOS()
        controller.bindForTesting(app: app, tabId: app.activeTabId!)
        controller.openNoteComposerForTesting(content: "The answer.")

        controller.handleBridgeMessageForTesting("viewport-scrolled")

        XCTAssertNotNil(controller.noteComposer)
        XCTAssertNil(app.pendingNoteContent)
    }

    /// Main's `testRightClickingThePageHandsTheReplyBack`. The gesture is a long
    /// press on iPadOS, but the wire message is the same `"context-menu"`.
    /// No teardown call is needed afterwards either: the macOS branch installs a
    /// real `NSEvent` monitor that has to be taken back down, and the iOS one
    /// just assigns `contextMenu`.
    func testLongPressingThePageHandsTheReplyBack() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "The answer.", on: app)

        controller.handleBridgeMessageForTesting("context-menu", ["found": false])

        XCTAssertNil(controller.noteComposer)
        XCTAssertEqual(app.pendingNoteContent, "The answer.")
    }

    func testTappingAnExistingNoteHandsTheReplyBack() async {
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

    func testTappingAnExistingHighlightHandsTheReplyBack() async {
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

    /// A second "Add as note" while a composer is still open. The panel's button
    /// is not gated on one, so the placement tap that follows used to overwrite
    /// the first reply with the second and lose it outright.
    ///
    /// This is the one dismissal that cannot call `returnNoteComposerDraft()`
    /// first — the incoming reply has already been consumed off the queue — so
    /// `presentNoteComposer` rescues the outgoing draft by hand, after
    /// `setMode(.view)`. Both halves of that ordering are asserted below.
    func testASecondPlacementRescuesTheComposerItReplaces() {
        let app = makePaneWithTab()
        let controller = agedComposer(holding: "First reply.", on: app)

        // The user picks "Add as note" on a second reply, then taps the page.
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
