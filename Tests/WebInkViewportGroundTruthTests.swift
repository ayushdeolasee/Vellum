#if os(iOS)
import WebKit
import XCTest
@testable import Vellum

// Ground truth for the two zoom facts every web-ink coordinate transform rests
// on, measured against a real WKWebView with no Vellum machinery in the way:
//
//   1. does `scrollView.zoomScale` carry the Safari-style `viewScale` page
//      zoom (so the overlay's divide-by-`zoomScale` is the whole story), and
//   2. does a `user-scalable=no` page collapse the scroll view's pinch range,
//      and does `WKWebViewConfiguration.ignoresViewportScaleLimits` re-open it
//      (Safari-on-iPad ignores those metas; `WebViewerView_iOS.makeWebView`
//      never sets the flag).
//
// METHOD NOTE — why nothing here is put in a `UIWindow`. A second `UIWindow`
// made key over the test host's own window does NOT get composited on device:
// the web content process still lays the page out (`clientWidth`,
// `visualViewport.scale`, and element rects all respond to `viewScale`), but
// the `UIScrollView` never receives a layer-tree commit, so `contentSize`
// stays `.zero` and `min/maximumZoomScale` stay pinned at the 1.0/1.0 default.
// Reading zoom limits off that view measures the default, not the viewport —
// so every measurement below asserts a non-empty `contentSize` first and
// refuses to draw conclusions from a view that never rendered.

@MainActor
final class WebInkViewportGroundTruthTests: XCTestCase {
    /// One full reading of the zoom coordinate system.
    private struct Facts {
        var zoomScale: CGFloat
        var minimumZoomScale: CGFloat
        var maximumZoomScale: CGFloat
        var pinchEnabled: Bool
        var contentSize: CGSize
        /// `document.documentElement.clientWidth` — the CSS layout viewport.
        var clientWidth: Double
        /// `document.documentElement.scrollWidth/Height` in layout CSS px.
        var scrollWidth: Double
        var scrollHeight: Double
        var visualViewportScale: Double
    }

    private func makeWebView(ignoresViewportScaleLimits: Bool = false) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.ignoresViewportScaleLimits = ignoresViewportScaleLimits
        // Unparented but explicitly sized: this is the configuration that
        // demonstrably produces real viewport geometry (see the method note).
        return WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 1000),
            configuration: configuration)
    }

    private func fixtureHTML(viewport: String) -> String {
        var paragraphs = ""
        for i in 1...40 {
            paragraphs += """
            <p id="p\(i)">Paragraph \(i) of the viewport fixture. The quick brown fox
            jumps over the lazy dog again and again, wrapping across several lines so
            the layout has real text geometry that reflows with the viewport.</p>
            """
        }
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="\(viewport)">
        <style>body { font: 16px/1.5 -apple-system, sans-serif; margin: 24px; }
        p { margin: 0 0 18px; }</style>
        </head><body><h1>Viewport fixture</h1>\(paragraphs)</body></html>
        """
    }

    /// Load and wait for the scroll view to actually receive geometry. A web
    /// view that never renders reports `contentSize == .zero` forever, and
    /// every zoom number read off it is a default rather than a measurement.
    private func load(_ webView: WKWebView, html: String) async throws {
        webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/viewport"))
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if webView.scrollView.contentSize.height > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertGreaterThan(
            webView.scrollView.contentSize.height, 0,
            "web view never rendered — its zoom numbers would be defaults, not measurements")
    }

    private func facts(_ webView: WKWebView, _ label: String) async -> Facts {
        let js = """
        (function () {
          var d = document.documentElement;
          return {
            clientWidth: d.clientWidth,
            scrollWidth: d.scrollWidth,
            scrollHeight: d.scrollHeight,
            vvScale: (window.visualViewport ? window.visualViewport.scale : -1)
          };
        })()
        """
        let measured: [String: Double] = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js) { result, _ in
                var out: [String: Double] = [:]
                if let dict = result as? [String: Any] {
                    for (key, value) in dict where value is Double || value is Int {
                        out[key] = (value as? NSNumber)?.doubleValue ?? 0
                    }
                }
                continuation.resume(returning: out)
            }
        }
        let scroll = webView.scrollView
        let out = Facts(
            zoomScale: scroll.zoomScale,
            minimumZoomScale: scroll.minimumZoomScale,
            maximumZoomScale: scroll.maximumZoomScale,
            pinchEnabled: scroll.pinchGestureRecognizer?.isEnabled ?? false,
            contentSize: scroll.contentSize,
            clientWidth: measured["clientWidth"] ?? -1,
            scrollWidth: measured["scrollWidth"] ?? -1,
            scrollHeight: measured["scrollHeight"] ?? -1,
            visualViewportScale: measured["vvScale"] ?? -1)
        print("""
        VIEWPORTFACT[\(label)] zoomScale=\(out.zoomScale) min=\(out.minimumZoomScale) \
        max=\(out.maximumZoomScale) pinchEnabled=\(out.pinchEnabled) \
        contentSize=\(out.contentSize) clientWidth=\(out.clientWidth) \
        cssScrollW=\(out.scrollWidth) cssScrollH=\(out.scrollHeight) \
        vvScale=\(out.visualViewportScale)
        """)
        return out
    }

    /// Apply `viewScale` and wait for the *scroll view* to catch up, reporting
    /// how long that took.
    ///
    /// The CSS relayout and the compositing scale do NOT land atomically: a
    /// fixed 1.5 s wait measured `clientWidth == 800` (layout already back at
    /// the 1.0 basis) while `zoomScale == 0.75` was still the previous step's
    /// scale. Anything that samples both sides inside that window — the ink
    /// overlay's `zoomScale` KVO versus the content script's layout-CSS-px
    /// anchor rects — sees two different zoom levels at once, so the settle
    /// time is itself the interesting number.
    @discardableResult
    private func setViewScale(_ scale: CGFloat, on webView: WKWebView) async throws -> TimeInterval {
        let started = Date()
        webView.setValue(scale, forKey: "viewScale")
        let deadline = started.addingTimeInterval(10)
        while Date() < deadline {
            if abs(webView.scrollView.zoomScale - scale) < 0.01 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = Date().timeIntervalSince(started)
        print("VIEWPORTFACT[settle] viewScale=\(scale) scrollView.zoomScale reached it in \(Int(elapsed * 1000)) ms")
        // Let the layout finish after the scale lands, so the JS-side numbers
        // read below belong to the same generation.
        try await Task.sleep(for: .milliseconds(400))
        return elapsed
    }

    /// H4/H5: `viewScale` shrinks the CSS layout viewport by the factor and
    /// composites it back up through the scroll view, so `zoomScale` IS the
    /// toolbar zoom, `contentSize` is CSS px × zoomScale, and everything JS
    /// reports stays in layout CSS px. If this ever regresses, the ink overlay
    /// keeps 100% geometry over zoomed text — the "annotations move" symptom.
    func testViewScaleLandsOnScrollViewZoomScale() async throws {
        let webView = makeWebView()
        guard webView.responds(to: NSSelectorFromString("_setViewScale:")) else {
            throw XCTSkip("viewScale SPI unavailable")
        }
        try await load(webView, html: fixtureHTML(viewport: "width=device-width, initial-scale=1"))
        let base = await facts(webView, "viewScale=1.0")

        let upSettle = try await setViewScale(1.5, on: webView)
        let up = await facts(webView, "viewScale=1.5")

        let downSettle = try await setViewScale(0.75, on: webView)
        let down = await facts(webView, "viewScale=0.75")

        let restoreSettle = try await setViewScale(1.0, on: webView)
        let restored = await facts(webView, "viewScale=1.0-restored")

        // Settle latency is load-bearing for the re-anchor cadence in
        // `WebInkController_iOS.anchorsShifted` (0 / 400 / 1200 ms): a pass
        // that fires before the scale lands re-anchors against an
        // intermediate layout.
        print("""
        VIEWPORTFACT[settle-summary] up=\(Int(upSettle * 1000))ms \
        down=\(Int(downSettle * 1000))ms restore=\(Int(restoreSettle * 1000))ms
        """)

        XCTAssertEqual(base.zoomScale, 1, accuracy: 0.01)
        XCTAssertEqual(up.zoomScale, 1.5, accuracy: 0.02, "zoomScale must carry viewScale")
        XCTAssertEqual(down.zoomScale, 0.75, accuracy: 0.02)
        XCTAssertEqual(restored.zoomScale, 1, accuracy: 0.02, "viewScale=1 restores the base scale")

        // The layout viewport is the exact inverse of the factor.
        XCTAssertEqual(up.clientWidth, base.clientWidth / 1.5, accuracy: 2)
        XCTAssertEqual(down.clientWidth, base.clientWidth / 0.75, accuracy: 2)

        // contentSize is rendered view points = layout CSS px × zoomScale,
        // which is exactly what WebInkOverlay_iOS divides back out.
        XCTAssertEqual(
            up.contentSize.height, up.scrollHeight * up.zoomScale, accuracy: 2,
            "web contentSize is CSS px × zoomScale")
        XCTAssertEqual(
            down.contentSize.height, down.scrollHeight * down.zoomScale, accuracy: 2)

        // `visualViewport.scale` carries the page zoom too — it is not
        // pinch-only, which is what makes the content script's
        // `visualPointPayload` scale correct at toolbar zoom.
        XCTAssertEqual(up.visualViewportScale, Double(up.zoomScale), accuracy: 0.02)
        XCTAssertEqual(down.visualViewportScale, Double(down.zoomScale), accuracy: 0.02)

        // Kills H2: the pinch range is re-based on the page zoom (min = z,
        // max = 5z), never collapsed. Pinch-in stays available at any toolbar
        // zoom; pinch-out below the toolbar zoom is what WebKit forbids.
        XCTAssertEqual(up.minimumZoomScale, 1.5, accuracy: 0.02)
        XCTAssertEqual(up.maximumZoomScale, 7.5, accuracy: 0.05)
        XCTAssertGreaterThan(up.maximumZoomScale, up.minimumZoomScale + 0.1)
    }

    /// H1: Vellum's `makeWebView` never sets `ignoresViewportScaleLimits`, so
    /// any page shipping `user-scalable=no` / `maximum-scale=1` would ship the
    /// user a dead pinch. Measure both the collapse and whether the flag is the
    /// cure — on a web view that demonstrably rendered, so min == max means
    /// "WebKit collapsed the range", not "the view never got one".
    func testUserScalableNoVersusIgnoresViewportScaleLimits() async throws {
        // Control: a normal page on this exact setup, so a collapsed range is
        // distinguishable from an unrendered view.
        let control = makeWebView()
        try await load(control, html: fixtureHTML(viewport: "width=device-width, initial-scale=1"))
        let open = await facts(control, "control initial-scale=1")
        XCTAssertGreaterThan(
            open.maximumZoomScale, open.minimumZoomScale + 0.1,
            "control: an ordinary page must expose a real pinch range")

        let lockedViewport = "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"

        let locked = makeWebView(ignoresViewportScaleLimits: false)
        try await load(locked, html: fixtureHTML(viewport: lockedViewport))
        let lockedFacts = await facts(locked, "user-scalable=no ignoresViewportScaleLimits=false")

        let unlocked = makeWebView(ignoresViewportScaleLimits: true)
        try await load(unlocked, html: fixtureHTML(viewport: lockedViewport))
        let unlockedFacts = await facts(unlocked, "user-scalable=no ignoresViewportScaleLimits=true")

        XCTAssertEqual(
            lockedFacts.minimumZoomScale, lockedFacts.maximumZoomScale, accuracy: 0.001,
            "user-scalable=no collapses the pinch range")
        XCTAssertGreaterThan(
            unlockedFacts.maximumZoomScale, unlockedFacts.minimumZoomScale + 0.1,
            "ignoresViewportScaleLimits must re-open it (Safari-on-iPad behavior)")
    }

    /// The fix for the shipped viewer, pinned against regression.
    ///
    /// `testUserScalableNoVersusIgnoresViewportScaleLimits` proves the flag is
    /// the cure on a web view this test file builds; this one proves the web
    /// view the app actually ships carries it. The property is
    /// configuration-time only — reading it back off a live WKWebView is the
    /// only way to catch someone setting it after `WKWebView(frame:
    /// configuration:)`, where it silently does nothing.
    @MainActor
    func testShippedWebViewIgnoresViewportScaleLimits() {
        let controller = WebViewerController_iOS()
        XCTAssertTrue(
            controller.webView.configuration.ignoresViewportScaleLimits,
            "web reader must ignore user-scalable=no or WebKit disables the pinch recognizer outright")
    }

    /// End-to-end for BUG 1, through the web view the app actually ships: a
    /// page that locks its viewport must still be pinchable.
    ///
    /// The flag assertion above can only prove the configuration was built
    /// right. This one proves the consequence users feel — WebKit does not
    /// merely clamp min/max on a `user-scalable=no` page, it sets
    /// `pinchGestureRecognizer.isEnabled = false`, which is why the gesture was
    /// dead rather than merely limited.
    func testShippedWebViewStaysPinchableOnAViewportLockedPage() async throws {
        let controller = WebViewerController_iOS()
        let webView = controller.webView
        webView.frame = CGRect(x: 0, y: 0, width: 800, height: 1000)
        try await load(webView, html: fixtureHTML(
            viewport: "width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no"))
        let locked = await facts(webView, "shipped controller, user-scalable=no")

        XCTAssertTrue(
            locked.pinchEnabled,
            "shipped viewer must keep the pinch recognizer alive on a viewport-locked page")
        XCTAssertGreaterThan(
            locked.maximumZoomScale, locked.minimumZoomScale + 0.1,
            "shipped viewer must expose a real pinch range on a viewport-locked page")
    }
}
#endif
