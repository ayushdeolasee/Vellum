import UIKit
import XCTest
@testable import Vellum

// The iOS sheet-presence gate (packet 4 §2.13 / §4.5). NOT a port of main's
// `Tests/SheetPresenceTests.swift` — that file and the AppKit
// `SheetPresenceMonitor` it covers are dropped by decision: every assertion in
// it is about `NSWindow.attachedSheet` / `willBeginSheet` / `didEndSheet`, and
// iOS has no attached-sheet contract to preserve.
//
// What this covers instead: `SheetPresence_iOS` asked of real UIKit, and the
// one router behaviour the gate exists for (issue #98) — ⌘W behind a modal must
// not close the tab underneath, while Escape must still close the modal.
//
// WHAT IS DELIBERATELY NOT COVERED HERE:
//
//  * "A SwiftUI `Commands` key equivalent never reaches us behind a modal."
//    It does. AppKit validates menu items and a disabled item declines its key
//    equivalent; iPadOS has no equivalent validation, so this gate is a
//    ROUTER-LEVEL suppression, not a "the chord never arrives" guarantee. That
//    asymmetry is the reason `.dismiss` has to be handled rather than
//    suppressed: a matched `UIKeyCommand` is consumed unconditionally, so a
//    no-op Escape would make the sheet stop responding to Escape entirely.
//  * `testGateIgnoresNonForegroundScenes`. An XCTest host has exactly one
//    scene and faking `activationState` is not worth the machinery. The scene
//    filter in `SheetPresence_iOS.topPresented` is unexercised by design.

@MainActor
final class SheetPresenceIOSTests: XCTestCase {
    /// This suite runs against its OWN key window, not the host app's.
    ///
    /// Both halves of that matter, and both were learned the hard way:
    ///
    ///  * `SheetPresence_iOS.topPresented` walks from the foreground-active
    ///    scene's `keyWindow`, so the window a test presents into must be the
    ///    key one or every assertion reads someone else's (empty) presentation.
    ///    `setUp` therefore WAITS for `makeKeyAndVisible` to actually land —
    ///    without that wait the first test in the suite ran while the host's
    ///    window was still key and `testCloseTabIsSuppressedWhileAModalIsUp`
    ///    failed about half the time.
    ///  * It must not be the HOST's window either. Presenting over the running
    ///    app's root controller makes "nothing is presented" untrue whenever the
    ///    app has a modal of its own up, and `testNoPresentationMeansNoGate`
    ///    starts failing for reasons that have nothing to do with the gate.
    private var window: UIWindow!
    private var root: UIViewController!

    private static var foregroundScene: UIWindowScene? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
    }

    // Async for the same isolation reason as `tearDown` below: the synchronous
    // `setUp()` is a nonisolated override and cannot call into this main-actor
    // state, while the async overload inherits the class's isolation.
    override func setUp() async throws {
        try await super.setUp()
        let scene = Self.foregroundScene
        window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        waitUntil { Self.foregroundScene?.keyWindow === self.window }
    }

    // The ASYNC teardown, deliberately: `XCTestCase.tearDown()` is nonisolated,
    // so overriding the synchronous one inside a `@MainActor` class yields a
    // nonisolated override that cannot touch any of this state. The async
    // overload inherits the class's isolation.
    override func tearDown() async throws {
        // Tear the presentation down explicitly. A case that ends with a modal
        // still up — or with a dismissal still animating — would otherwise leave
        // `topPresented` answering for the NEXT test: every one of these reads
        // the same process-wide scene.
        if root?.presentedViewController != nil {
            root.dismiss(animated: false)
            waitUntil(timeout: 1) { self.root.presentedViewController == nil }
        }
        window.isHidden = true
        window.rootViewController = nil
        window = nil
        root = nil
        try await super.tearDown()
    }

    /// Spin the runloop until `condition` holds, or give up.
    ///
    /// A fixed sleep is not enough and never was: the router dismisses
    /// `animated: true` (that is the real behaviour — an Escape that snapped the
    /// sheet away would look broken), so the gate closes a transition later, not
    /// a runloop turn later.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 3, _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }

    /// Present and wait for UIKit to publish it, so a test never asserts against
    /// a transition that has not landed.
    private func present(_ controller: UIViewController, from presenter: UIViewController) {
        presenter.present(controller, animated: false)
        waitUntil { presenter.presentedViewController === controller }
    }

    func testNoPresentationMeansNoGate() {
        XCTAssertFalse(SheetPresence_iOS.isPresenting)
        XCTAssertNil(SheetPresence_iOS.topPresented)
    }

    func testPresentedControllerIsSeen() {
        let presented = UIViewController()
        present(presented, from: root)
        XCTAssertTrue(SheetPresence_iOS.isPresenting)
        XCTAssertTrue(SheetPresence_iOS.topPresented === presented)
    }

    func testNestedPresentationReportsTheFrontmost() {
        let first = UIViewController()
        present(first, from: root)
        let second = UIViewController()
        present(second, from: first)
        XCTAssertTrue(
            SheetPresence_iOS.topPresented === second,
            "the dismissal target must be the modal actually on top")
    }

    func testDismissalClosesTheGate() {
        let presented = UIViewController()
        present(presented, from: root)
        XCTAssertTrue(SheetPresence_iOS.isPresenting)
        root.dismiss(animated: false)
        waitUntil { !SheetPresence_iOS.isPresenting }
        XCTAssertFalse(SheetPresence_iOS.isPresenting)
    }

    // MARK: - Router gating (issue #98)

    private func makeWorkspace() -> WorkspaceStore {
        WorkspaceStore(sessions: DocumentSessionManager())
    }

    /// The behaviour §2.13.2 exists for: ⌘W behind a modal acts on the sheet's
    /// context, never on the document underneath.
    func testCloseTabIsSuppressedWhileAModalIsUp() {
        let workspace = makeWorkspace()
        let app = workspace.focusedPane.app
        app.newStartTab()
        app.newStartTab()
        XCTAssertEqual(app.tabs.count, 2)

        present(UIViewController(), from: root)

        VellumShortcutRouter.perform(.closeTab, workspace: workspace)
        // `closeTab` is async work kicked off from the router, so a pass has to
        // mean suppression rather than slowness: spin until the tab count WOULD
        // have changed, then assert it did not.
        waitUntil(timeout: 0.3) { app.tabs.count != 2 }
        XCTAssertEqual(
            app.tabs.count, 2,
            "⌘W behind a sheet closed the tab underneath it — this is issue #98.")
    }

    func testDismissActionClosesTheTopmostPresentationInsteadOfNoOping() {
        let workspace = makeWorkspace()
        present(UIViewController(), from: root)
        XCTAssertTrue(SheetPresence_iOS.isPresenting)

        VellumShortcutRouter.perform(.dismiss, workspace: workspace)
        waitUntil { !SheetPresence_iOS.isPresenting }
        XCTAssertFalse(
            SheetPresence_iOS.isPresenting,
            "Escape must close the modal; suppressing it would make a matched "
                + "UIKeyCommand swallow the only key that dismisses the sheet.")
    }

    func testCloseTabStillWorksWithNoModalUp() {
        let workspace = makeWorkspace()
        let app = workspace.focusedPane.app
        app.newStartTab()
        app.newStartTab()
        let before = app.tabs.count

        VellumShortcutRouter.perform(.closeTab, workspace: workspace)
        waitUntil { app.tabs.count == before - 1 }
        XCTAssertEqual(
            app.tabs.count, before - 1,
            "the gate must only suppress while something is actually presented")
    }
}
