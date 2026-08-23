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
///
/// **Scope on iPad (#129 packet 5 §4).** This file carries the `AppStore` half
/// only. Main's other three classes in this file — the web-composer dismissal
/// suites from #92 — are packet 7's, and land as their own
/// `Tests/WebNoteDraftTests.swift` in Stage F against the iOS
/// `WebViewerController`. Nobody ports them twice.
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
    ///
    /// Restored from main verbatim now that `WebNoteComposerState.initialContent`
    /// exists (#129 packet 7 §2.4a); it was the one case this file deferred.
    func testWebComposerStateDefaultsToEmptyContent() {
        let state = WebNoteComposerState(
            point: .zero,
            anchor: WebNoteAnchor(start: 0, end: 0, text: "", prefix: nil, suffix: nil, pageNumber: 1),
            openedAt: Date())
        XCTAssertEqual(state.initialContent, "")
    }
}
