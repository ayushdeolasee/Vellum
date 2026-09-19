#if os(iOS)
import PencilKit
import WebKit
import XCTest
@testable import Vellum

// Phase 3 (WEB-INK-PLAN decision 8): spatial clustering of web-ink strokes,
// per-cluster translation math, anchor fields in the sidecar record, and a
// live round trip of the content script's anchor-at-point / resolve-anchors
// commands against a fixture HTML page.

// MARK: - Clustering + translation (pure Swift)

final class WebInkClusteringTests: XCTestCase {
    /// A horizontal stroke starting at `origin`, `length` pt long.
    private func stroke(at origin: CGPoint, length: CGFloat = 80) -> PKStroke {
        var points: [PKStrokePoint] = []
        for i in 0...8 {
            points.append(PKStrokePoint(
                location: CGPoint(x: origin.x + CGFloat(i) * length / 8, y: origin.y),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: CGFloat.pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKStroke(ink: PKInk(.pen, color: .black), path: path)
    }

    func testNearbyStrokesMergeAndDistantOnesSeparate() {
        // Two strokes 10 px apart vertically (same note), one 400 px below.
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 100, y: 100)),
            stroke(at: CGPoint(x: 100, y: 110)),
            stroke(at: CGPoint(x: 100, y: 510)),
        ])
        let clusters = WebInkClustering.clusters(of: drawing)
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(clusters[0].drawing.strokes.count, 2, "the two near strokes share a cluster")
        XCTAssertEqual(clusters[1].drawing.strokes.count, 1)
        XCTAssertLessThan(clusters[0].bounds.minY, clusters[1].bounds.minY, "clusters sort by document position")
    }

    func testProximityIsTransitiveWithinOneInkLine() {
        // A near B, B near C, A far from C: one chained cluster.
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 0, y: 0)),
            stroke(at: CGPoint(x: 0, y: 10)),
            stroke(at: CGPoint(x: 0, y: 20)),
        ])
        let clusters = WebInkClustering.clusters(of: drawing)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].drawing.strokes.count, 3)
    }

    func testAdjacentTextRowsStayInSeparateAnchorClusters() {
        // Regression: the old symmetric 48-point proximity merged these
        // independent underlines transitively. During toolbar zoom the text
        // rows reflow by different amounts, so sharing one anchor moved at
        // least two of the three strokes away from their words.
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 10, y: 100), length: 120),
            stroke(at: CGPoint(x: 10, y: 130), length: 120),
            stroke(at: CGPoint(x: 10, y: 160), length: 120),
        ])
        let clusters = WebInkClustering.clusters(of: drawing)
        XCTAssertEqual(clusters.count, 3)
        XCTAssertEqual(clusters.map(\.drawing.strokes.count), [1, 1, 1])
    }

    func testSameRowStrokesCanStillMergeAcrossHorizontalGaps() {
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 10, y: 100), length: 20),
            stroke(at: CGPoint(x: 55, y: 100), length: 20),
        ])
        let clusters = WebInkClustering.clusters(of: drawing)
        XCTAssertEqual(clusters.count, 1)
        XCTAssertEqual(clusters[0].drawing.strokes.count, 2)
    }

    func testClusteringIsDeterministic() {
        let strokes = [
            stroke(at: CGPoint(x: 300, y: 900)),
            stroke(at: CGPoint(x: 50, y: 60)),
            stroke(at: CGPoint(x: 60, y: 75)),
            stroke(at: CGPoint(x: 500, y: 60)),
        ]
        let a = WebInkClustering.clusters(of: PKDrawing(strokes: strokes))
        let b = WebInkClustering.clusters(of: PKDrawing(strokes: strokes))
        XCTAssertEqual(a.count, b.count)
        for (x, y) in zip(a, b) {
            XCTAssertEqual(x.bounds, y.bounds)
            XCTAssertEqual(x.drawing.strokes.count, y.drawing.strokes.count)
        }
        // Ordering: by minY then minX — the (50,60) pair first (min x wins the
        // tie against the (500,60) stroke), then (500,60), then (300,900).
        XCTAssertEqual(a.count, 3)
        XCTAssertEqual(a[0].bounds.minY, a[1].bounds.minY, accuracy: 1)
        XCTAssertLessThan(a[0].bounds.minX, a[1].bounds.minX)
        XCTAssertGreaterThan(a[2].bounds.minY, a[1].bounds.minY)
    }

    func testTranslationMovesOnlyDeltaedClusters() {
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 100, y: 100)),
            stroke(at: CGPoint(x: 100, y: 600)),
        ])
        let clusters = WebInkClustering.clusters(of: drawing)
        XCTAssertEqual(clusters.count, 2)
        let before = clusters.map(\.bounds)

        let (translated, moved) = WebInkClustering.translated(
            clusters, by: [CGVector(dx: 12, dy: 300), nil])
        XCTAssertTrue(moved)

        let after = WebInkClustering.clusters(of: translated)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after[0].bounds.minX, before[0].minX + 12, accuracy: 0.5)
        XCTAssertEqual(after[0].bounds.minY, before[0].minY + 300, accuracy: 0.5)
        XCTAssertEqual(after[1].bounds.minX, before[1].minX, accuracy: 0.5)
        XCTAssertEqual(after[1].bounds.minY, before[1].minY, accuracy: 0.5)
    }

    func testSubPixelDeltasAreNoise() {
        let drawing = PKDrawing(strokes: [stroke(at: CGPoint(x: 100, y: 100))])
        let clusters = WebInkClustering.clusters(of: drawing)
        let (_, moved) = WebInkClustering.translated(
            clusters, by: [CGVector(dx: 0.3, dy: -0.4)])
        XCTAssertFalse(moved, "rect-measurement jitter must not dirty the drawing")
    }

    // MARK: Anchors in the sidecar record

    func testSnapshotAttachesAnchorsPerClusterAndRoundTrips() throws {
        let drawing = PKDrawing(strokes: [
            stroke(at: CGPoint(x: 100, y: 100)),
            stroke(at: CGPoint(x: 100, y: 600)),
        ])
        let layout = WebInkRecord.Layout(contentWidth: 980, docHeight: 42000)
        let anchor = WebInkRecord.Anchor(
            startOffset: 1234,
            endOffset: 1394,
            text: "anchored paragraph text",
            prefix: "before ",
            suffix: " after",
            rect: WebInkRecord.Bounds(CGRect(x: 40, y: 90, width: 8, height: 18)))
        // Anchor only the upper cluster (the lower one is "not yet captured").
        let record = WebInkRecord.snapshot(
            of: drawing, url: "https://example.com/anchored", layout: layout,
            anchorFor: { bounds in bounds.minY < 300 ? anchor : nil })

        XCTAssertEqual(record.clusters.count, 2)
        XCTAssertEqual(record.clusters[0].anchor, anchor)
        XCTAssertNil(record.clusters[1].anchor)

        // Wire format: snake_case anchor keys; the unanchored cluster keeps
        // its explicit null.
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let clusters = try XCTUnwrap(object["clusters"] as? [[String: Any]])
        let anchorJson = try XCTUnwrap(clusters[0]["anchor"] as? [String: Any])
        XCTAssertEqual(anchorJson["start_offset"] as? Int, 1234)
        XCTAssertEqual(anchorJson["end_offset"] as? Int, 1394)
        XCTAssertEqual(anchorJson["text"] as? String, "anchored paragraph text")
        XCTAssertNotNil(anchorJson["rect"] as? [String: Any])
        XCTAssertTrue(clusters[1]["anchor"] is NSNull)

        let decoded = try JSONDecoder().decode(WebInkRecord.self, from: data)
        XCTAssertEqual(decoded, record)

        // Load-path translation: moving a cluster's bounds (what a re-anchor
        // pass does before merging) relocates its strokes in the merged
        // drawing.
        var shifted = decoded
        shifted.clusters[0].bounds.y += 250
        let merged = shifted.mergedDrawing()
        let reClustered = WebInkClustering.clusters(of: merged)
        XCTAssertEqual(reClustered.count, 2)
        XCTAssertEqual(
            reClustered[0].bounds.minY,
            record.clusters[0].bounds.y + 250,
            accuracy: 0.5)
    }
}

// MARK: - Content-script anchor round trip (live web view)

/// Collects bridge messages from the isolated-world content script.
private final class BridgeRecorder: NSObject, WKScriptMessageHandler {
    var onMessage: (([String: Any]) -> Void)?

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let body = message.body as? [String: Any],
              body["vellum"] as? Bool == true else { return }
        onMessage?(body)
    }
}

@MainActor
final class WebInkAnchorScriptTests: XCTestCase {
    private static let world = WKContentWorld.world(name: "VellumBridge")

    private var webView: WKWebView!
    private var recorder: BridgeRecorder!
    private var received: [[String: Any]] = []

    override func setUp() async throws {
        recorder = BridgeRecorder()
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(
            recorder, contentWorld: Self.world, name: "vellum")
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebContentScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.world))
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 1000),
            configuration: configuration)
        recorder.onMessage = { [weak self] body in
            Task { @MainActor in self?.received.append(body) }
        }
    }

    override func tearDown() async throws {
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "vellum", contentWorld: Self.world)
        webView = nil
        recorder = nil
        received = []
    }

    private func waitFor(_ type: String, timeout: TimeInterval = 15) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let index = received.firstIndex(where: { $0["type"] as? String == type }) {
                return received.remove(at: index)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("timed out waiting for '\(type)' message")
        throw XCTSkip("bridge message '\(type)' never arrived")
    }

    private func runJS(_ js: String) {
        webView.evaluateJavaScript(js, in: nil, in: Self.world, completionHandler: nil)
    }

    private func postCommand(_ command: String, _ payload: [String: Any]) throws {
        var message = payload
        message["vellumCmd"] = command
        let data = try JSONSerialization.data(withJSONObject: message)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        runJS("window.__vellumCmd && window.__vellumCmd(\(json));")
    }

    private func loadFixture() {
        var paragraphs = ""
        for i in 1...8 {
            paragraphs += """
            <p id="p\(i)">Paragraph \(i) of the anchor fixture. The quick brown fox jumps
            over the lazy dog again and again, wrapping across several lines so the
            layout has real text geometry to anchor ink clusters to.</p>
            """
        }
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body { font: 16px/1.5 -apple-system, sans-serif; margin: 24px; }
        p { margin: 0 0 18px; }</style>
        </head><body><h1>Anchor fixture</h1>\(paragraphs)</body></html>
        """
        webView.loadHTMLString(html, baseURL: URL(string: "https://fixture.test/article"))
    }

    /// Document-space (CSS px) top-left of an element.
    private func docPoint(of elementId: String) async throws -> CGPoint {
        let js = """
        (function () {
          var r = document.getElementById('\(elementId)').getBoundingClientRect();
          return { x: r.left + window.scrollX, y: r.top + window.scrollY };
        })()
        """
        // Parse to a Sendable value inside the completion — the raw `Any`
        // result must not cross the continuation boundary.
        let point: CGPoint? = await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(js, in: nil, in: Self.world) { result in
                let dict = (try? result.get()) as? [String: Any]
                if let x = dict?["x"] as? Double, let y = dict?["y"] as? Double {
                    continuation.resume(returning: CGPoint(x: x, y: y))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
        return try XCTUnwrap(point)
    }

    func testPencilSelectionUsesWholeWordsInBothDirections() async throws {
        loadFixture()
        _ = try await waitFor("init")
        for reverse in [false, true] {
            received.removeAll { $0["type"] as? String == "selection" }
            runJS("""
            (function () {
              var n = document.getElementById('p1').firstChild;
              function point(word) {
                var start = n.textContent.indexOf(word);
                var r = document.createRange();
                r.setStart(n, start + 1); r.setEnd(n, start + 2);
                var b = r.getBoundingClientRect(), v = window.visualViewport;
                return { x: (b.left + b.width / 2 - v.offsetLeft) * v.scale,
                         y: (b.top + b.height / 2 - v.offsetTop) * v.scale };
              }
              var first = point('quick'), last = point('fox');
              if (\(reverse ? "true" : "false")) { var t = first; first = last; last = t; }
              window.__vellumCmd({vellumCmd:'pencil-selection', phase:'begin', x:first.x, y:first.y});
              window.__vellumCmd({vellumCmd:'pencil-selection', phase:'move', x:last.x, y:last.y});
              window.__vellumCmd({vellumCmd:'pencil-selection', phase:'end', x:last.x, y:last.y});
            })()
            """)
            let selected = try await waitFor("selection")
            XCTAssertEqual(selected["text"] as? String, "quick brown fox")
            XCTAssertEqual(selected["fromPencil"] as? Bool, true)
            XCTAssertNotNil(selected["start"])
            XCTAssertNotNil(selected["end"])
        }
    }

    /// End-to-end anchor life cycle against real DOM geometry: capture an
    /// anchor at an ink cluster's document point, reflow the page by
    /// inserting content above it, observe the shift signal, and re-resolve
    /// the anchor to a rect displaced by exactly the inserted height.
    func testAnchorRoundTripSurvivesLayoutShift() async throws {
        loadFixture()
        _ = try await waitFor("init")

        // Capture: anchor at paragraph 2's top edge (in the viewport, so the
        // caret hit-test path runs).
        let p2 = try await docPoint(of: "p2")
        try postCommand("anchor-at-point", [
            "requestId": "cap1",
            "points": [["id": "a", "x": p2.x + 40, "y": p2.y + 4]],
        ])
        let captureResult = try await waitFor("ink-anchor-result")
        XCTAssertEqual(captureResult["requestId"] as? String, "cap1")
        let capturedList = try XCTUnwrap(captureResult["anchors"] as? [[String: Any]])
        XCTAssertEqual(capturedList.count, 1)
        let captured = capturedList[0]
        XCTAssertEqual(captured["found"] as? Bool, true)
        let start = try XCTUnwrap(captured["start"] as? Int)
        let text = try XCTUnwrap(captured["text"] as? String)
        // The caret hit-test lands wherever inside the paragraph the point
        // was (possibly mid-word), so match on a substring unique to p2.
        XCTAssertTrue(
            text.contains("2 of the anchor fixture"),
            "anchor text is the nearest paragraph: \(text)")
        let capturedRect = try XCTUnwrap(captured["rect"] as? [String: Any])
        let capturedY = try XCTUnwrap(capturedRect["y"] as? Double)
        XCTAssertEqual(capturedY, p2.y, accuracy: 60, "anchor rect sits at the paragraph")

        // Reflow: 300 px of new content above the anchored paragraph.
        received.removeAll { $0["type"] as? String == "ink-anchors-shifted" }
        runJS("""
        var spacer = document.createElement('div');
        spacer.style.height = '300px';
        document.body.insertBefore(spacer, document.getElementById('p2'));
        """)

        // The relayout/mutation hooks must report the shift.
        _ = try await waitFor("ink-anchors-shifted")

        // Re-resolution: same anchor, new rect, displaced by the spacer.
        try postCommand("resolve-anchors", [
            "requestId": "res1",
            "anchors": [[
                "id": "a",
                "start": start,
                "end": captured["end"] as? Int ?? start + 1,
                "text": text,
                "prefix": captured["prefix"] as? String ?? "",
                "suffix": captured["suffix"] as? String ?? "",
            ]],
        ])
        let resolveResult = try await waitFor("ink-anchors-resolved")
        XCTAssertEqual(resolveResult["requestId"] as? String, "res1")
        let resolvedList = try XCTUnwrap(resolveResult["anchors"] as? [[String: Any]])
        XCTAssertEqual(resolvedList.count, 1)
        XCTAssertEqual(resolvedList[0]["found"] as? Bool, true)
        let resolvedRect = try XCTUnwrap(resolvedList[0]["rect"] as? [String: Any])
        let resolvedY = try XCTUnwrap(resolvedRect["y"] as? Double)
        XCTAssertEqual(
            resolvedY, capturedY + 300, accuracy: 30,
            "the re-resolved anchor rect must move by the inserted height")
    }

    /// A point far outside the viewport still anchors (the document-Y binary
    /// search path — clusters are re-saved wherever they are, on- or
    /// off-screen).
    func testAnchorAtOffViewportPointResolvesByDocumentY() async throws {
        loadFixture()
        _ = try await waitFor("init")

        // Grow the page so p8 is well below the 1000 px viewport.
        runJS("""
        var pad = document.createElement('div');
        pad.style.height = '2000px';
        document.body.insertBefore(pad, document.getElementById('p8'));
        """)
        // Let layout settle before measuring.
        try await Task.sleep(for: .milliseconds(200))
        let p8 = try await docPoint(of: "p8")
        XCTAssertGreaterThan(p8.y, 1000, "fixture: p8 must be off-viewport")

        try postCommand("anchor-at-point", [
            "requestId": "cap2",
            "points": [["id": "b", "x": p8.x + 40, "y": p8.y + 4]],
        ])
        let result = try await waitFor("ink-anchor-result")
        let anchors = try XCTUnwrap(result["anchors"] as? [[String: Any]])
        XCTAssertEqual(anchors[0]["found"] as? Bool, true)
        let rect = try XCTUnwrap(anchors[0]["rect"] as? [String: Any])
        let y = try XCTUnwrap(rect["y"] as? Double)
        XCTAssertEqual(
            y, p8.y, accuracy: 120,
            "off-viewport anchor lands near the requested document Y")
    }

    /// The heading-underline regression: line boxes tile with no gap, so an
    /// underline stroke drawn just below a heading starts *inside* the next
    /// line's box. The band scoring must still anchor it to the heading above
    /// (simulator QA showed next-line anchors drifting ~2 lines under
    /// width-reflow because adjacent lines wrap by different amounts).
    func testUnderlineBelowHeadingAnchorsToHeadingNotNextLine() async throws {
        webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>body { font: 16px/1.25 -apple-system, sans-serif; margin: 24px; }
        h2, p { margin: 0; padding: 0; font-size: 16px; }</style>
        </head><body>
        <h2 id="head">What is out there today</h2>
        <p id="follow">Pointers to online information, subjects, servers, and
        everything else that follows the heading with zero margin so the two
        line boxes touch.</p>
        </body></html>
        """, baseURL: URL(string: "https://fixture.test/heading"))
        _ = try await waitFor("init")

        // Underline band: starts 1 px below the heading's line box (i.e. at
        // the very top of the paragraph's box), 4 px thick — where a real
        // Pencil underline of the heading lands.
        let head = try await docPoint(of: "head")
        let follow = try await docPoint(of: "follow")
        XCTAssertEqual(
            follow.y, head.y + 20, accuracy: 8,
            "fixture: the two line boxes must be adjacent")
        try postCommand("anchor-at-point", [
            "requestId": "cap3",
            "points": [[
                "id": "u", "x": head.x + 60,
                "y": follow.y + 1, "bottom": follow.y + 5,
                "left": head.x + 5, "right": head.x + 165,
            ]],
        ])
        let result = try await waitFor("ink-anchor-result")
        let anchors = try XCTUnwrap(result["anchors"] as? [[String: Any]])
        XCTAssertEqual(anchors[0]["found"] as? Bool, true)
        let text = try XCTUnwrap(anchors[0]["text"] as? String)
        XCTAssertTrue(
            text.contains("out there today"),
            "underline anchors to the heading above the band, got: \(text)")
    }

    /// A thin Pencil stroke can straddle the shared boundary between two text
    /// rows. Vertical scoring alone prefers the preceding row (the usual
    /// underline case), but when the stroke overlaps substantially more of the
    /// following row it belongs to that row. Toolbar zoom wraps those rows
    /// independently, so choosing the wrong one produces a visible horizontal
    /// jump at the next zoom step.
    func testBoundaryUnderlineUsesHorizontalSpanToChooseFollowingRow() async throws {
        webView.loadHTMLString("""
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          body { font: 16px/20px -apple-system, sans-serif; margin: 24px; }
          div { height: 20px; margin: 0; padding: 0; white-space: nowrap; }
          #previous { margin-left: 40px; }
        </style>
        </head><body>
        <div id="previous">NeXTStep previous row</div>
        <div id="target">Technical</div>
        </body></html>
        """, baseURL: URL(string: "https://fixture.test/boundary"))
        _ = try await waitFor("init")

        let previous = try await docPoint(of: "previous")
        let target = try await docPoint(of: "target")
        XCTAssertEqual(target.y, previous.y + 20, accuracy: 2)

        // Match the simulator regression: a 4 px stroke begins one pixel above
        // the target row and extends across almost all of "Technical", while
        // only its right-hand portion overlaps the indented previous row.
        let left = target.x + 2
        let right = target.x + 72
        try postCommand("anchor-at-point", [
            "requestId": "cap4",
            "points": [[
                "id": "boundary",
                "x": (left + right) / 2,
                "y": target.y - 1,
                "bottom": target.y + 3,
                "left": left,
                "right": right,
            ]],
        ])

        let result = try await waitFor("ink-anchor-result")
        let anchors = try XCTUnwrap(result["anchors"] as? [[String: Any]])
        XCTAssertEqual(anchors[0]["found"] as? Bool, true)
        let text = try XCTUnwrap(anchors[0]["text"] as? String)
        XCTAssertTrue(
            text.contains("nical") && !text.contains("previous row"),
            "horizontal coverage must select the following row, got: \(text)")
    }
}
#endif
