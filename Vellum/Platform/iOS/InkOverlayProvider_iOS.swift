#if os(iOS)
import PDFKit
import PencilKit
import UIKit

/// A `PKCanvasView` that carries its 1-based page number (so the drawing
/// delegate can route changes back to the controller without a reverse map) and
/// its current super-sample factor `K` (so persistence can convert strokes back
/// to page space — see `InkOverlayProvider_iOS` for the whole scheme).
final class InkPageCanvas_iOS: PKCanvasView {
    var pageNumber = 0
    /// The linear super-sample factor this canvas currently rasterizes at. The
    /// canvas draws in a coordinate space `K`× the page's zoom-1 space, so its
    /// backing store holds `K`× the pixels and PencilKit re-rasterizes the vector
    /// strokes at that density. `1` means "same as the page" (no super-sampling).
    var superSample: CGFloat = 1
}

/// Wraps a page's ink canvas so we can super-sample it. PDFKit sizes this
/// container to the page's zoom-1 bounds and scales it by the live zoom
/// transform. Inside, the canvas is given `K`× the container's bounds and a
/// `1/K` view transform, so it *looks* the same size but its backing store — and
/// therefore PencilKit's stroke rasterization — is `K`× denser. This is the
/// crucial difference from nudging `contentScaleFactor`: that only changes the
/// scale hint and PencilKit keeps upscaling its existing low-res bitmap, whereas
/// enlarging the actual bounds makes PencilKit render the vectors into a bigger
/// surface (crisp). See `InkOverlayProvider_iOS.superSample(forZoom:)`.
final class InkOverlayContainer_iOS: UIView {
    let canvas: InkPageCanvas_iOS

    init(canvas: InkPageCanvas_iOS) {
        self.canvas = canvas
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        addSubview(canvas)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let k = max(canvas.superSample, 1)
        // Reset the transform before resizing bounds so the two don't compound,
        // then re-apply. The canvas ends up `K`× bounds, shrunk by `1/K` back to
        // the container's size and centered over it.
        canvas.transform = .identity
        canvas.bounds = CGRect(x: 0, y: 0, width: bounds.width * k, height: bounds.height * k)
        canvas.transform = CGAffineTransform(scaleX: 1 / k, y: 1 / k)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// PDFKit's sanctioned PencilKit bridge: returns a persistent per-page canvas
/// (wrapped in a super-sampling container) installed inside PDFView's zooming
/// document hierarchy, so positioning/scaling is automatic. Every visible page
/// owns its own live canvas (no page-flip commit dance), and — when Pencil-only
/// — finger touches fall through to PDFView's own scroll-view pan.
///
/// The canvas is the renderer for the editing session: on first creation each
/// page's native `/Ink` is lifted into the canvas and removed from the display
/// document (so it doesn't double-draw). Durable persistence still flows through
/// the controller's untouched debounced disk writer.
///
/// ## Crispness at high zoom
/// PencilKit rasterizes each stroke to a bitmap sized to the canvas's backing
/// store, then that bitmap is scaled by PDFView's zoom transform — so at, say,
/// 300% zoom a canvas rendered at page resolution is bilinearly upscaled 3× and
/// looks fuzzy next to the vector-crisp PDF glyphs. Bumping `contentScaleFactor`
/// does **not** help: PencilKit keeps upscaling its existing bitmap rather than
/// re-rendering the vectors. Instead we super-sample: give each *on-screen*
/// canvas a backing store `K = ceil(zoom)`× larger (capped at the app's 4× max
/// zoom) and draw the strokes at `K`× scale, so PencilKit rasterizes the vectors
/// at full device resolution. Off-screen pages drop back to `K = 1` to bound
/// memory (an inked page at 4× is a large bitmap). The stroke geometry stored on
/// disk is always page (zoom-1) space — we scale by `1/K` before persisting and
/// by `K` when seeding — so `PdfInk` round-tripping is unchanged.
@MainActor
final class InkOverlayProvider_iOS: NSObject, @preconcurrency PDFPageOverlayViewProvider,
    PKCanvasViewDelegate, UIPencilInteractionDelegate {
    /// The controller owns tool/color/policy state and the persistence path.
    weak var ink: InkController_iOS?

    /// Strong per-page cache (document outlives the tab, so canvases persist for
    /// the session even as pages scroll off and back on). Keyed by PDFPage.
    private var containers: [ObjectIdentifier: InkOverlayContainer_iOS] = [:]
    /// Pages PDFKit currently has on screen — only these are super-sampled (so an
    /// inked page that scrolled away doesn't retain a large high-res bitmap).
    private var displayedKeys: Set<ObjectIdentifier> = []
    /// Guards programmatic `canvas.drawing =` seeding/rescaling from triggering a
    /// persist.
    private var suppressChange = false

    /// The PDFView's current zoom, tracked so freshly-installed / rescaled pages
    /// pick the right super-sample factor immediately.
    private var pdfScale: CGFloat = 1
    /// The app's maximum zoom — the super-sample factor is capped here so a page
    /// stays crisp across the whole zoom range without over-allocating.
    private let maxSuperSample: CGFloat = 4
    /// Debounces the (relatively expensive) rescale during a live pinch — we only
    /// re-rasterize when the zoom settles, so the gesture stays smooth. Ink is
    /// briefly bilinear-scaled mid-pinch and snaps crisp on release, same as the
    /// system Notes app.
    private var rescaleTask: Task<Void, Never>?

    /// The super-sample factor for a given zoom: enough to keep strokes crisp,
    /// clamped to the useful range. `ceil` so we're always at least as dense as
    /// the on-screen scale.
    private func superSample(forZoom zoom: CGFloat) -> CGFloat {
        min(max(ceil(zoom), 1), maxSuperSample)
    }

    // MARK: - PDFPageOverlayViewProvider

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> UIView? {
        pdfScale = pdfView.scaleFactor
        let key = ObjectIdentifier(page)
        displayedKeys.insert(key)

        if let existing = containers[key] {
            applyPolicy(to: existing.canvas)
            setSuperSample(superSample(forZoom: pdfScale), for: existing)
            return existing
        }

        let canvas = InkPageCanvas_iOS()
        canvas.pageNumber = (pdfView.document?.index(for: page)).map { $0 + 1 } ?? 0
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        // The document is white paper, so pin the canvas to a light appearance.
        // Otherwise, in dark mode PencilKit adaptively lightens dark inks — pure
        // black renders as a washed-out grey — and defeats the true-black pen.
        canvas.overrideUserInterfaceStyle = .light
        canvas.delegate = self
        // NB: the Pencil double-tap interaction is NOT attached here — per-page
        // canvases are virtualized (added/removed as pages scroll), so a barrel
        // double-tap could land on a page whose canvas isn't window-attached and
        // be dropped. It lives on the stable PDFView instead (see PdfKitView_iOS).

        let container = InkOverlayContainer_iOS(canvas: canvas)
        let k = superSample(forZoom: pdfScale)
        canvas.superSample = k
        canvas.tool = ink?.pkTool(widthScale: k) ?? PKInkingTool(.pen, color: .black, width: 4 * k)

        // Seed from the page's embedded PKDrawing (page space) scaled into the
        // canvas's `K`× space, then strip the page's native ink so the display
        // document doesn't double-render behind the canvas.
        suppressChange = true
        let seeded = PdfInk.drawing(on: page) ?? PKDrawing()
        canvas.drawing = Self.scaleDrawing(seeded, by: k)
        suppressChange = false
        PdfInk.removeVellumInk(from: page)
        if !seeded.strokes.isEmpty {
            // Let observers (the sidebar's Handwriting chips) know ink exists
            // on this page — seeding is invisible to them otherwise.
            ink?.noteSeededDrawing()
        }

        applyPolicy(to: canvas)
        containers[key] = container
        return container
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: UIView, for page: PDFPage) {
        let key = ObjectIdentifier(page)
        displayedKeys.remove(key)
        // Free the large super-sampled bitmap now that the page is off screen;
        // it re-super-samples when it scrolls back in.
        if let container = containers[key] {
            setSuperSample(1, for: container)
        }
    }

    // MARK: - Render resolution (crispness under zoom)

    /// Change a canvas's super-sample factor: rescale its drawing into the new
    /// space (so on-disk page-space geometry is preserved), relayout the backing
    /// store, and re-apply the tool at the matching width. Reassigning `drawing`
    /// is what forces PencilKit to re-rasterize the vectors at the new density.
    private func setSuperSample(_ newK: CGFloat, for container: InkOverlayContainer_iOS) {
        let canvas = container.canvas
        let oldK = canvas.superSample
        guard abs(oldK - newK) > 0.001 else { return }
        canvas.superSample = newK
        if !canvas.drawing.strokes.isEmpty {
            suppressChange = true
            canvas.drawing = Self.scaleDrawing(canvas.drawing, by: newK / oldK)
            suppressChange = false
        }
        container.setNeedsLayout()
        container.layoutIfNeeded()
        canvas.tool = ink?.pkTool(widthScale: newK) ?? PKInkingTool(.pen, color: .black, width: 4 * newK)
    }

    /// Called from `PdfKitView_iOS`'s `.PDFViewScaleChanged` observer. Debounced
    /// so we only re-rasterize once the pinch settles (see `rescaleTask`).
    func zoomChanged(_ scale: CGFloat) {
        guard scale > 0 else { return }
        pdfScale = scale
        rescaleTask?.cancel()
        rescaleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            self?.applyResolutionToVisible()
        }
    }

    /// Re-super-sample every on-screen canvas to the current zoom.
    private func applyResolutionToVisible() {
        let k = superSample(forZoom: pdfScale)
        for key in displayedKeys {
            if let container = containers[key] { setSuperSample(k, for: container) }
        }
    }

    /// Scale a drawing by `s` (positions and stroke widths together), returning a
    /// fresh drawing. Used to move strokes between page space and a canvas's
    /// super-sampled space. `PKStroke.transform` scales the whole stroke, width
    /// included, so page-space geometry round-trips exactly.
    static func scaleDrawing(_ drawing: PKDrawing, by s: CGFloat) -> PKDrawing {
        guard abs(s - 1) > 0.0001 else { return drawing }
        let t = CGAffineTransform(scaleX: s, y: s)
        let strokes = drawing.strokes.map { stroke in
            PKStroke(
                ink: stroke.ink,
                path: stroke.path,
                transform: stroke.transform.concatenating(t),
                mask: stroke.mask
            )
        }
        return PKDrawing(strokes: strokes)
    }

    /// Drop all cached canvases. Called when a viewer adopts a fresh
    /// PDFDocument — the cache is keyed by PDFPage identity, so canvases for a
    /// replaced document are unreachable and would otherwise leak.
    func resetCache() {
        rescaleTask?.cancel()
        containers.removeAll()
        displayedKeys.removeAll()
    }

    // MARK: - Lookup

    func canvas(forPage n: Int) -> PKCanvasView? {
        guard let document = ink?.pdfController?.document,
              n >= 1, n <= document.pageCount,
              let page = document.page(at: n - 1) else { return nil }
        return containers[ObjectIdentifier(page)]?.canvas
    }

    /// Whether a cached canvas exists for the page and, if so, whether it has
    /// any *visible* ink. `nil` means no cached canvas (caller should consult
    /// `PdfInk`). Uses each stroke's mask-aware `renderBounds`: the bitmap eraser
    /// clips a stroke via its mask but leaves the (now-invisible) stroke object in
    /// `drawing.strokes`, so a raw `strokes.isEmpty` check would report a fully
    /// erased page as still inked.
    func cachedStrokes(forPage n: Int) -> Bool? {
        canvas(forPage: n).map { canvas in
            canvas.drawing.strokes.contains { !$0.renderBounds.isEmpty }
        }
    }

    // MARK: - State propagation (driven by the controller's didSets)

    /// Re-apply the active tool/color/width to every cached canvas. Each canvas
    /// scales the tool width by its own super-sample factor so the on-page width
    /// stays what the user picked.
    func applyTool() {
        guard let ink else { return }
        for container in containers.values {
            container.canvas.tool = ink.pkTool(widthScale: container.canvas.superSample)
        }
    }

    /// Re-apply interaction + drawing-policy to every cached canvas.
    func refreshPolicies() {
        for container in containers.values { applyPolicy(to: container.canvas) }
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
        // The canvas draws in `K`× page space; persist page (zoom-1) space so the
        // on-disk `/Ink` geometry is resolution-independent.
        let pageDrawing = Self.scaleDrawing(canvasView.drawing, by: 1 / max(canvas.superSample, 1))
        ink?.drawingChanged(pageDrawing, page: canvas.pageNumber)
    }

    // MARK: - UIPencilInteractionDelegate

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        ink?.pencilDoubleTap(preferredAction: UIPencilInteraction.preferredTapAction)
    }
}
#endif
