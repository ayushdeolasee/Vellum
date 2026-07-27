#if os(iOS)
import PDFKit
import PencilKit
import UIKit

/// A `PKCanvasView` that carries its 1-based page number (so the drawing
/// delegate can route changes back to the controller without a reverse map) and
/// its current super-sample factor `K` (the canvas's `zoomScale` — see
/// `InkOverlayProvider_iOS` for the whole scheme).
final class InkPageCanvas_iOS: PKCanvasView {
    var pageNumber = 0
    /// The linear super-sample factor this canvas currently rasterizes at, i.e.
    /// its `zoomScale`. The canvas's *content* coordinate space is always the
    /// page's zoom-1 space; `K` only makes PencilKit rasterize that content into
    /// a `K`× denser backing store. `1` means "same as the page".
    var superSample: CGFloat = 1
    /// The drawing as of the last change this provider processed.
    ///
    /// PencilKit hands the delegate the whole drawing, never "the stroke that
    /// just landed", so scratch-out detection diffs against this to find the
    /// stroke the user just finished — and the scratch-out undo action restores
    /// it. It is refreshed on seeding *and* on every delegate callback, so a
    /// programmatic mutation (clear page, undo, redo) can never leave it stale.
    var committedDrawing = PKDrawing()
    /// Guards *this* canvas's programmatic `drawing =` assignments from being
    /// mistaken for user edits. Per-canvas rather than provider-wide so
    /// suppressing one page can never swallow another page's change callback
    /// (which would drop that page's stroke before it was ever persisted).
    var suppressChange = false
}

/// Wraps a page's ink canvas so we can super-sample it. PDFKit sizes this
/// container to the page's zoom-1 bounds and scales it by the live zoom
/// transform. Inside, the canvas is laid out `K`× as large and given
/// `zoomScale = K`, then shrunk back over the container by a `1/K` view
/// transform. It *looks* the same size, but its backing store — and therefore
/// PencilKit's stroke rasterization — is `K`× denser.
///
/// `zoomScale` is the load-bearing part. It is how PencilKit is *designed* to be
/// scaled (`PKCanvasView` is a `UIScrollView`, and Apple's own PencilKit sample
/// zooms it this way), so PencilKit re-rasterizes the vector strokes at the new
/// density while the drawing's own coordinates stay in unzoomed content space.
/// Two alternatives do not work:
/// * nudging `contentScaleFactor` — that only changes the scale hint, and
///   PencilKit keeps upscaling its existing low-res bitmap (blurry);
/// * enlarging the canvas's `bounds` by `K` and scaling stroke geometry to match
///   — crisp, but it forces the tool width through `PKInkingTool.width`, which
///   PencilKit clamps (pen 0.88…25.66, marker 7.5…60) and does not map linearly
///   onto rendered stroke geometry. Strokes then came out ~2× thinner when drawn
///   while zoomed in than at 100%. Keeping geometry in page space avoids the
///   whole problem: the tool width is whatever the user picked, at every zoom.
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
        // Reset the transform before resizing so the two don't compound, then
        // re-apply. The canvas is laid out `K`× the container, zoomed `K`× (so
        // its content space stays the container's zoom-1 page space and the
        // content exactly fills the viewport), then shrunk by `1/K` back over
        // the container.
        canvas.transform = .identity
        canvas.bounds = CGRect(x: 0, y: 0, width: bounds.width * k, height: bounds.height * k)
        canvas.minimumZoomScale = k
        canvas.maximumZoomScale = k
        canvas.zoomScale = k
        canvas.contentSize = canvas.bounds.size
        canvas.contentOffset = .zero
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
/// canvas `zoomScale = K = ceil(zoom)` (capped at the app's 4× max zoom) so
/// PencilKit rasterizes the vectors at full device resolution. Off-screen pages
/// drop back to `K = 1` to bound memory (an inked page at 4× is a large bitmap).
/// Stroke geometry is *always* page (zoom-1) space — the canvas's content space
/// is page space at every `K` — so seeding and persistence are straight copies
/// and `PdfInk` round-tripping is unchanged.
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
    // NB: the guard against programmatic `canvas.drawing =` assignments being
    // mistaken for user edits lives on the canvas (`InkPageCanvas_iOS
    // .suppressChange`), not here — a provider-wide flag would let one page's
    // suppression window swallow another page's change callback.

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
        canvas.superSample = superSample(forZoom: pdfScale)
        canvas.tool = ink?.pkTool ?? PKInkingTool(.pen, color: .black, width: 4)

        // Seed from the page's embedded PKDrawing — the canvas's content space
        // is page space at every `K`, so this is a straight copy — then strip
        // the page's native ink so the display document doesn't double-render
        // behind the canvas.
        canvas.suppressChange = true
        let seeded = PdfInk.drawing(on: page) ?? PKDrawing()
        canvas.drawing = seeded
        canvas.committedDrawing = seeded
        canvas.suppressChange = false
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

    /// Change a canvas's super-sample factor, relaying out so PencilKit
    /// re-rasterizes the vectors at the new `zoomScale`. The drawing itself is
    /// untouched — its coordinates are page space at every `K`.
    private func setSuperSample(_ newK: CGFloat, for container: InkOverlayContainer_iOS) {
        let canvas = container.canvas
        guard abs(canvas.superSample - newK) > 0.001 else { return }
        canvas.superSample = newK
        container.setNeedsLayout()
        container.layoutIfNeeded()
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

    /// Drop all cached canvases. Called when a viewer adopts a fresh
    /// PDFDocument — the cache is keyed by PDFPage identity, so canvases for a
    /// replaced document are unreachable and would otherwise leak.
    func resetCache() {
        rescaleTask?.cancel()
        // Drop any scratch-out undo actions still pointing at this provider
        // before the canvases go. The undo manager comes from the responder
        // chain, so it outlives the document swap: a stale action firing later
        // would restore the *old* document's drawing and — via
        // `drawingChanged(_:page:)` — write it over the new document's page.
        // `withTarget:` scopes the removal to our own actions; PencilKit's are
        // registered against its own targets and are left alone.
        // Iterating every canvas rather than just one: the undo manager is
        // resolved through each canvas's responder chain, so in a split view two
        // pages can legitimately answer with different managers. The call is
        // idempotent, so hitting the same manager twice is free.
        for container in containers.values {
            container.canvas.undoManager?.removeAllActions(withTarget: self)
        }
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
    /// `PdfInk`). The bitmap eraser clips a stroke via its mask but leaves the
    /// (now-invisible) stroke object in `drawing.strokes`, so a raw
    /// `strokes.isEmpty` check would report a fully erased page as still inked —
    /// hence the per-stroke visibility test (see `PdfInk.strokeHasVisibleInk`).
    func cachedStrokes(forPage n: Int) -> Bool? {
        canvas(forPage: n).map { canvas in
            canvas.drawing.strokes.contains { PdfInk.strokeHasVisibleInk($0) }
        }
    }

    // MARK: - State propagation (driven by the controller's didSets)

    /// Re-apply the active tool/color/width to every cached canvas. The width is
    /// the one the user picked, unmodified — a canvas's super-sample factor is a
    /// rasterization detail and never touches stroke geometry.
    func applyTool() {
        guard let ink else { return }
        for container in containers.values {
            container.canvas.tool = ink.pkTool
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
        guard let canvas = canvasView as? InkPageCanvas_iOS,
              !canvas.suppressChange,
              canvas.pageNumber >= 1 else { return }
        // Scratch-out runs first, and synchronously (see `applyScratchOut`): if
        // the stroke the user just finished is a scribble over existing ink, what
        // we persist is the *post*-erase drawing, so the scribble itself never
        // reaches the canvas's steady state or the disk.
        let drawing = scratchOutErase(on: canvas) ?? canvasView.drawing
        canvas.committedDrawing = drawing
        // The canvas's content space is page (zoom-1) space at every `K`, so the
        // drawing persists as-is and the on-disk `/Ink` geometry is
        // resolution-independent.
        ink?.drawingChanged(drawing, page: canvas.pageNumber)
    }

    // MARK: - Scratch out to erase

    /// If the stroke the user just finished is a scratch-out over existing ink,
    /// delete it and everything it covered and return the resulting drawing.
    /// `nil` means "nothing to do" — the caller persists the drawing unchanged.
    ///
    /// Preconditions beyond the geometry (see `ScratchOutRecognizer` for those):
    /// * the user has the feature on (Settings ▸ Reading ▸ Apple Pencil);
    /// * ink mode is active, so this can only ever be a stroke the user drew;
    /// * an **inking** tool is selected, and specifically the *pen*. The
    ///   highlighter is excluded because sweeping a marker back and forth over a
    ///   word to deepen the highlight is a legitimate, common action with exactly
    ///   the geometry of a scratch-out. The eraser is excluded because it can't
    ///   produce a stroke at all;
    /// * we are not inside an undo or redo. `UndoManager` mutating the drawing
    ///   fires this delegate too, and undoing a single-stroke object-erase
    ///   restores exactly one stroke — indistinguishable by count from the user
    ///   drawing one. Without this guard, undo could re-run the recognizer and
    ///   erase ink *while restoring* it, and the erase would register its own
    ///   action onto the redo stack mid-group;
    /// * exactly one stroke was appended, with every earlier stroke unchanged
    ///   (`ScratchOutInk.appendedStrokeIndex`). A bitmap erase (masks strokes,
    ///   count unchanged), a vector erase (count drops) and a programmatic clear
    ///   all fail that test.
    private func scratchOutErase(on canvas: InkPageCanvas_iOS) -> PKDrawing? {
        guard InkController_iOS.scratchOutToErase,
              let ink, ink.isActive, ink.tool == .pen else { return nil }
        let undoManager = canvas.undoManager
        guard undoManager?.isUndoing != true, undoManager?.isRedoing != true else { return nil }

        let drawing = canvas.drawing
        guard let scratchIndex = ScratchOutInk.appendedStrokeIndex(
            in: drawing, after: canvas.committedDrawing) else { return nil }
        guard let result = ScratchOutInk.erase(scratchIndex: scratchIndex, in: drawing) else {
            return nil
        }

        #if DEBUG
        NSLog("[ink-debug] scratch-out on page %d erased %d stroke(s)",
              canvas.pageNumber, result.erasedStrokeCount)
        #endif
        applyScratchOut(result.drawing, undoingTo: drawing, on: canvas)
        return result.drawing
    }

    /// Swap a canvas's drawing for `new`, registering an undo that restores
    /// `old`. Recursive by design: the undo's own registration becomes the redo.
    ///
    /// ## Undo grouping
    /// `old` is the drawing PencilKit just handed us — the one that still
    /// contains the scribble — *not* the pre-scribble drawing. That choice is
    /// what makes the undo correct without depending on anything we cannot
    /// verify:
    ///
    /// PencilKit has already registered its own "I added a stroke" undo for the
    /// scribble. If UIKit's `UndoManager.groupsByEvent` folds that registration
    /// and ours into one group, a single ⌘Z runs both in reverse — ours restores
    /// the scribble and its victims, then PencilKit's removes the scribble —
    /// landing exactly on the pre-scribble page. If the two land in *separate*
    /// groups, the user presses undo twice and sees the same two steps
    /// individually, each of them coherent.
    ///
    /// Separate groups are a real possibility: `PKCanvasViewDelegate` documents
    /// that `canvasViewDrawingDidChange` "may be called some time after
    /// `canvasViewDidEndUsingTool`" because Apple Pencil pressure data lags touch
    /// data — which is precisely the path this feature runs on. Handing
    /// PencilKit's action back the state it expects (a drawing whose last stroke
    /// is the scribble) means we never have to care which way it went, and never
    /// depend on whether PencilKit's own undo is snapshot- or delta-based.
    private func applyScratchOut(
        _ new: PKDrawing,
        undoingTo old: PKDrawing,
        on canvas: InkPageCanvas_iOS
    ) {
        canvas.undoManager?.registerUndo(withTarget: self) { [weak canvas] provider in
            guard let canvas else { return }
            provider.applyScratchOut(old, undoingTo: new, on: canvas)
            provider.ink?.drawingChanged(old, page: canvas.pageNumber)
        }
        canvas.undoManager?.setActionName("Erase")
        // Reassigning `drawing` re-enters the delegate; suppress so the swap
        // isn't mistaken for a second user edit (and re-scanned for scratch-out).
        // Per-canvas and saved/restored rather than a provider-wide set/clear: a
        // delegate callback for a *different* page arriving inside this window
        // would otherwise be dropped entirely — no `drawingChanged`, so that
        // page's stroke would never be written to disk.
        let wasSuppressed = canvas.suppressChange
        canvas.suppressChange = true
        canvas.drawing = new
        canvas.suppressChange = wasSuppressed
        canvas.committedDrawing = new
    }

    // MARK: - UIPencilInteractionDelegate

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        ink?.pencilDoubleTap(preferredAction: UIPencilInteraction.preferredTapAction)
    }
}
#endif
