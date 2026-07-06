#if os(iOS)
import PDFKit
import PencilKit
import UIKit

/// A `PKCanvasView` that carries its 1-based page number so the drawing
/// delegate can route changes back to the controller without a reverse map,
/// and that re-asserts its target rasterization density on every layout pass.
final class InkPageCanvas_iOS: PKCanvasView {
    var pageNumber = 0

    /// Backing-store density PencilKit should rasterize strokes at (screen scale
    /// × clamped zoom). The provider sets this on creation and on every zoom.
    ///
    /// PencilKit renders through private subviews (`PKTiledView` et al.) that it
    /// creates — and sometimes *recreates* — lazily (first stroke, resize, window
    /// changes, a page recycled by the scroll view). A newborn render subview is
    /// born at the default scale, so if we only pushed the density on zoom/draw
    /// events, a freshly recreated subview would rasterize grainy (bitmap-upscaled
    /// past the display) until the next such event. `layoutSubviews` fires exactly
    /// when those subviews are inserted/relaid, so re-asserting here closes that
    /// window and keeps ink crisp through PencilKit's whole view lifecycle.
    var targetContentScale: CGFloat = UIScreen.main.scale {
        didSet {
            guard abs(oldValue - targetContentScale) > 0.001 else { return }
            applyContentScaleToTree()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyContentScaleToTree()
    }

    /// Push `targetContentScale` onto the whole view subtree. Only the sanctioned
    /// `contentScaleFactor` is touched — UIKit keeps each view's
    /// `layer.contentsScale` in sync and re-renders. (Poking the private ink
    /// layer's `contentsScale` directly instead blanks the strokes.)
    func applyContentScaleToTree() {
        applyScale(to: self)
    }

    private func applyScale(to view: UIView) {
        if abs(view.contentScaleFactor - targetContentScale) > 0.001 {
            view.contentScaleFactor = targetContentScale
            view.setNeedsDisplay()
        }
        for sub in view.subviews { applyScale(to: sub) }
    }
}

/// PDFKit's sanctioned PencilKit bridge: returns a persistent `PKCanvasView`
/// per `PDFPage`, installed inside PDFView's zooming document hierarchy so
/// positioning/scaling is automatic. Every visible page owns its own live
/// canvas (no page-flip commit dance), and — when Pencil-only — finger touches
/// fall through to PDFView's own scroll-view pan.
///
/// The canvas is the renderer for the editing session: on first creation each
/// page's native `/Ink` is lifted into the canvas and removed from the display
/// document (so it doesn't double-draw). Durable persistence still flows through
/// the controller's untouched debounced disk writer.
@MainActor
final class InkOverlayProvider_iOS: NSObject, @preconcurrency PDFPageOverlayViewProvider,
    PKCanvasViewDelegate, UIPencilInteractionDelegate {
    /// The controller owns tool/color/policy state and the persistence path.
    weak var ink: InkController_iOS?

    /// Strong per-page cache (document outlives the tab, so canvases persist for
    /// the session even as pages scroll off and back on).
    private var canvases: [ObjectIdentifier: InkPageCanvas_iOS] = [:]
    /// Guards programmatic `canvas.drawing =` seeding from triggering a persist.
    private var suppressChange = false

    /// The PDFView's current zoom. Each canvas is installed at page-size (zoom-1)
    /// bounds and scaled up by PDFKit's document transform, so PencilKit rasterizes
    /// its strokes at the canvas's nominal (zoom-1) backing resolution and the
    /// bitmap is then bilinearly upscaled by that transform — visibly grainy at
    /// high zoom. (The canvas also defaults to `contentScaleFactor` 1.0 inside the
    /// overlay hierarchy — not the screen's native 2.0 — so ink is soft even at
    /// rest.) We counter both by driving each canvas's `contentScaleFactor` to
    /// `screen scale × zoom`, so PencilKit re-renders the vector strokes at the
    /// effective on-screen device resolution. Drawing coordinates never change —
    /// only the rasterization density — so on-disk PdfInk round-tripping is
    /// unaffected.
    private var pdfScale: CGFloat = 1
    /// Cap the rasterization density multiple at the app's max zoom so strokes
    /// stay crisp across the whole zoom range (below this, ink at high zoom is
    /// bitmap-upscaled past the display resolution and looks grainy).
    private let maxScaleMultiple: CGFloat = 4

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        // Track the live zoom so freshly-installed pages rasterize at the right
        // density immediately (e.g. a page scrolled in while already zoomed).
        pdfScale = pdfView.scaleFactor

        let key = ObjectIdentifier(page)
        if let existing = canvases[key] {
            applyPolicy(to: existing)
            applyContentScale(to: existing)
            return existing
        }

        let canvas = InkPageCanvas_iOS()
        canvas.pageNumber = (pdfView.document?.index(for: page)).map { $0 + 1 } ?? 0
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.delegate = self
        canvas.tool = ink?.pkTool ?? PKInkingTool(.pen, color: .black, width: 4)
        canvas.addInteraction(UIPencilInteraction(delegate: self))

        // Seed from the page's embedded PKDrawing, then strip the page's native
        // ink so the display document doesn't double-render behind the canvas.
        suppressChange = true
        let seeded = PdfInk.drawing(on: page) ?? PKDrawing()
        canvas.drawing = seeded
        suppressChange = false
        PdfInk.removeVellumInk(from: page)
        if !seeded.strokes.isEmpty {
            // Let observers (the sidebar's Handwriting chips) know ink exists
            // on this page — seeding is invisible to them otherwise.
            ink?.noteSeededDrawing()
        }

        applyPolicy(to: canvas)
        applyContentScale(to: canvas)
        canvases[key] = canvas
        return canvas
    }

    // MARK: - Render resolution (anti-graininess under zoom)

    /// Called from `PdfKitView_iOS`'s `.PDFViewScaleChanged` observer. Re-rasterize
    /// every live canvas at the new effective device resolution so strokes stay as
    /// crisp as the PDF glyphs PDFKit re-renders at each zoom step.
    func zoomChanged(_ scale: CGFloat) {
        guard scale > 0, abs(scale - pdfScale) > 0.001 else { return }
        pdfScale = scale
        for canvas in canvases.values { applyContentScale(to: canvas) }
    }

    private func applyContentScale(to canvas: PKCanvasView) {
        let base = UIScreen.main.scale
        let target = base * min(max(pdfScale, 1), maxScaleMultiple)
        // The canvas re-asserts this across PencilKit's whole subview lifecycle
        // (see `InkPageCanvas_iOS.targetContentScale`); `didSet` pushes it onto
        // the current subtree immediately.
        if let canvas = canvas as? InkPageCanvas_iOS {
            canvas.targetContentScale = target
            canvas.applyContentScaleToTree()
        }
    }

    // Keep drawings alive when a page scrolls off — the cache retains the canvas
    // and it is returned again for the same page. (No willEndDisplaying cleanup.)

    /// Drop all cached canvases. Called when a viewer adopts a fresh
    /// PDFDocument — the cache is keyed by PDFPage identity, so canvases for a
    /// replaced document are unreachable and would otherwise leak.
    func resetCache() {
        canvases.removeAll()
    }

    // MARK: - Lookup

    func canvas(forPage n: Int) -> PKCanvasView? {
        guard let document = ink?.pdfController?.document,
              n >= 1, n <= document.pageCount,
              let page = document.page(at: n - 1) else { return nil }
        return canvases[ObjectIdentifier(page)]
    }

    /// Whether a cached canvas exists for the page and, if so, whether it has
    /// strokes. `nil` means no cached canvas (caller should consult `PdfInk`).
    func cachedStrokes(forPage n: Int) -> Bool? {
        canvas(forPage: n).map { !$0.drawing.strokes.isEmpty }
    }

    // MARK: - State propagation (driven by the controller's didSets)

    /// Re-apply the active tool/color/width to every cached canvas.
    func applyTool() {
        guard let tool = ink?.pkTool else { return }
        for canvas in canvases.values { canvas.tool = tool }
    }

    /// Re-apply interaction + drawing-policy to every cached canvas.
    func refreshPolicies() {
        for canvas in canvases.values { applyPolicy(to: canvas) }
    }

    private func applyPolicy(to canvas: PKCanvasView) {
        let active = ink?.isActive ?? false
        // Inactive canvases still render their strokes but pass all touches to
        // PDFView (so finger pan/zoom and text selection keep working).
        canvas.isUserInteractionEnabled = active
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput // no Pencil in the simulator
        #else
        canvas.drawingPolicy = (ink?.allowFingerDrawing ?? false) ? .anyInput : .pencilOnly
        #endif
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppressChange,
              let canvas = canvasView as? InkPageCanvas_iOS,
              canvas.pageNumber >= 1 else { return }
        #if DEBUG
        let strokes = canvasView.drawing.strokes
        NSLog("[ink-debug] page %d didChange strokes=%d bounds=%@ canvasBounds=%@ tool=%@",
              canvas.pageNumber, strokes.count,
              NSCoder.string(for: canvasView.drawing.bounds),
              NSCoder.string(for: canvasView.bounds),
              String(describing: type(of: canvasView.tool)))
        #endif
        // PencilKit instantiates its stroke-rendering subview lazily on the first
        // stroke — after `pdfView(_:overlayViewFor:)` already ran — so that subview
        // is born at the default backing scale. Re-push the target scale now that
        // it exists (the abs-diff guard makes this a no-op once it's correct).
        applyContentScale(to: canvasView)
        ink?.drawingChanged(canvasView.drawing, page: canvas.pageNumber)
    }

    // MARK: - UIPencilInteractionDelegate

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        ink?.pencilDoubleTap(preferredAction: UIPencilInteraction.preferredTapAction)
    }
}
#endif
