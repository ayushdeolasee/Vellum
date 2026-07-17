import AppKit
import WebKit
import XCTest
@testable import Vellum

// Probe for the "invisible ScratchpadWebView still wins Finder drops onto the
// AI panel" bug. `ScratchpadWebView.acceptsDrops` unregisters dragged types
// when the scratchpad tab is hidden (see ScratchpadPanel.swift), on the theory
// that AppKit then lets the drag fall through to whatever real view is under
// the cursor (the AI panel). The theory only holds if WebKit never re-registers
// its own dragged types behind our back after a navigation/content-process
// event. This suite drives a *real* WKWebView through a *real* navigation
// (the actual bundled editor.html, the same template ScratchpadLiveEditor
// loads) and inspects `registeredDraggedTypes` afterward — something the
// FakeDraggingInfo harness in AttachmentDropTests can never see, since it
// feeds a drag directly to the view without going through AppKit's live
// drag-destination registration at all.
@MainActor
final class ScratchpadDropRegistrationTests: XCTestCase {

    /// The real template ScratchpadLiveEditor.makeNSView loads, or a minimal
    /// inline fallback if the test bundle can't see the app bundle's resource
    /// (what matters for this probe is a *real* navigation completing, not
    /// the specific HTML).
    private func loadRealOrFallbackTemplate(into webView: WKWebView, delegate: NavDoneDelegate) {
        webView.navigationDelegate = delegate
        if let url = Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "katex")
            ?? Bundle.main.url(forResource: "editor", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<html><body>fallback</body></html>", baseURL: nil)
        }
    }

    /// Pump the run loop for `seconds`, letting WebKit's async post-load work
    /// (content-process round trips, etc.) run.
    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitForNavigation(_ delegate: NavDoneDelegate, timeout: TimeInterval = 10) {
        let expectation = XCTestExpectation(description: "navigation finished")
        delegate.onFinish = { expectation.fulfill() }
        if delegate.finished { expectation.fulfill() }
        wait(for: [expectation], timeout: timeout)
    }

    /// H1a: acceptsDrops is set to false *before* the load (matching the real
    /// app's steady state while the AI tab is visible — updateNSView sets
    /// acceptsDrops on every SwiftUI update, so by the time content finishes
    /// loading it has long since been false). If WebKit re-registers dragged
    /// types on its own after navigation, this view — which is supposed to be
    /// drag-transparent — will silently start winning drags again.
    func testAcceptsDropsFalseBeforeLoadStaysUnregisteredAfterNavigation() {
        let config = WKWebViewConfiguration()
        let webView = ScratchpadWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.acceptsDrops = false

        let delegate = NavDoneDelegate()
        loadRealOrFallbackTemplate(into: webView, delegate: delegate)
        waitForNavigation(delegate)
        pump(2)

        print("[H1a] registeredDraggedTypes after load (offscreen, no window):",
              webView.registeredDraggedTypes)

        if !webView.registeredDraggedTypes.isEmpty {
            // Try harder before concluding anything: put it in a real window
            // with a nonzero frame, as WebKit's drag registration may be tied
            // to actually being in a window/layer hierarchy.
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.setIsVisible(false)
        pump(2)

        print("[H1a] registeredDraggedTypes after attaching to offscreen window:",
              webView.registeredDraggedTypes)

        XCTAssertTrue(
            webView.registeredDraggedTypes.isEmpty,
            "ScratchpadWebView re-registered dragged types (\(webView.registeredDraggedTypes)) " +
            "after navigation even though acceptsDrops == false — the invisible scratchpad " +
            "editor will win Finder drops meant for the AI panel underneath it."
        )
    }

    /// H1b: acceptsDrops starts true (scratchpad tab visible at load time),
    /// the user then switches to the AI tab — flipping acceptsDrops to false
    /// — *after* navigation already finished. Registration for the drop types
    /// happened once already during setup; this checks unregisterDraggedTypes
    /// actually sticks post-navigation rather than WebKit clobbering it right
    /// back on some subsequent internal event.
    func testAcceptsDropsFlippedFalseAfterLoadStaysUnregistered() {
        let config = WKWebViewConfiguration()
        let webView = ScratchpadWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.acceptsDrops = true

        let delegate = NavDoneDelegate()
        loadRealOrFallbackTemplate(into: webView, delegate: delegate)
        waitForNavigation(delegate)
        pump(2)

        webView.acceptsDrops = false
        pump(2)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = webView
        window.setIsVisible(false)
        pump(2)

        print("[H1b] registeredDraggedTypes after flip-to-false post-navigation:",
              webView.registeredDraggedTypes)

        XCTAssertTrue(
            webView.registeredDraggedTypes.isEmpty,
            "ScratchpadWebView re-registered dragged types (\(webView.registeredDraggedTypes)) " +
            "after acceptsDrops was flipped to false post-navigation — switching away from the " +
            "scratchpad tab does not actually stop it from swallowing drops."
        )
    }
}

/// Minimal WKNavigationDelegate that just signals when the first navigation
/// finishes (success or failure — either way WebKit's load-related work has
/// had a chance to run).
private final class NavDoneDelegate: NSObject, WKNavigationDelegate {
    private(set) var finished = false
    var onFinish: (() -> Void)?

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        onFinish?()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finished = true
        onFinish?()
    }

    func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        finished = true
        onFinish?()
    }
}
