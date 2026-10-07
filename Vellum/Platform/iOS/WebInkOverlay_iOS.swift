#if os(iOS)
import PencilKit
import UIKit
import WebKit

// The web-ink drawing surface (plan decisions 1, 2, 3, 4, 11). One viewport-
// sized PKCanvasView covers the whole web document: PKCanvasView *is* a
// UIScrollView, so it gets contentSize = the full document size and its
// contentOffset stays in lockstep with the WKWebView's scroll view. PencilKit
// tiles its rendering internally, so an arbitrarily tall drawing surface never
// materializes a giant view. One canvas ⇒ one PKDrawing, one undoManager, no
// stroke-crosses-band problem.

/// The single web-ink canvas. It draws in layout-CSS-pixel document space —
/// the exact coordinates the content script reports — at every zoom: under
/// viewScale (`WebViewerController_iOS.applyZoom`) the web scroll view's
/// `zoomScale` is toolbar zoom × pinch, and the overlay divides it out of
/// every offset/size and applies it back as a view transform. Strokes
/// therefore persist as-is (decision 3's "zoom-1 CSS px" with no runtime
/// normalization step).
final class WebInkCanvas_iOS: PKCanvasView {}

/// Viewport-sized container mounted as a sibling directly above the WKWebView
/// inside `WebViewRepresentable_iOS`'s host view. Owns the scroll/zoom
/// synchronization:
///
/// - **Scroll sync (decision 2)** is bidirectional, mode-dependent, KVO-only —
///   WebKit owns its scroll view's `delegate`, so nobody touches it. Ink
///   inactive: the container passes all touches to the page and KVO on the web
///   scroll view's `contentOffset` drives the canvas in the same runloop turn.
///   Ink active: the canvas sits on top, pencil draws, fingers pan the canvas's
///   own scroll view, and its offset mirrors back into the web scroll view —
///   which fires the page's JS scroll events naturally (verified by the Phase 0
///   spike), so virtual-page tracking keeps working untouched. An `isSyncing`
///   reentrancy flag prevents feedback loops.
/// - **Zoom (decisions 3+4)** is view-transform-only, never folded into
///   stroke coordinates: under viewScale, `scrollView.zoomScale` carries
///   toolbar zoom × pinch as one factor, and KVO on it applies a matching
///   scale transform so ink tracks both (briefly bilinear-scaled mid-pinch,
///   same as the PDF mid-pinch behavior). Toolbar zoom additionally reflows
///   the page — cluster positions are corrected by the re-anchor pass
///   (`WebInkController_iOS.zoomChanged` → `anchorsShifted`), not by
///   geometric rescaling.
@MainActor
final class WebInkOverlay_iOS: UIView, PKCanvasViewDelegate, UIPencilInteractionDelegate {
    /// The controller owns tool/policy state and the persistence path.
    weak var ink: WebInkController_iOS?
    /// The live drawing surface. Swapped for a fresh instance by
    /// `recreateCanvas()` when a programmatic drawing move needs to render while
    /// idle (see `setDrawing`); everything else drives it in place.
    private(set) var canvas = WebInkCanvas_iOS()

    private weak var webScrollView: UIScrollView?
    /// KVO on the web scroll view (offset/size/zoom) — stable across canvas
    /// swaps.
    private var webObservations: [NSKeyValueObservation] = []
    /// KVO on the *current* canvas's contentOffset — re-bound whenever the
    /// canvas is recreated.
    private var canvasObservation: NSKeyValueObservation?
    /// Reentrancy flag: mirroring one scroll view into the other fires the
    /// other's KVO synchronously; the flag keeps the echo from bouncing back.
    private var isSyncing = false
    /// Guards programmatic `canvas.drawing =` swaps (zoom rescale, load
    /// seeding) from being reported as user edits.
    private var suppressChange = false
    /// Live visual magnification (`scrollView.zoomScale` — toolbar zoom ×
    /// pinch under viewScale). View-transform state only — stored stroke
    /// coordinates never include it.
    private var visualScale: CGFloat = 1
    /// True while a PencilKit tool gesture is on the canvas — re-anchor
    /// passes must not swap the drawing out from under a live stroke.
    private(set) var isToolInUse = false
    /// Last laid-out width, so a rotation/split-screen resize can trigger a
    /// re-anchor pass once (the page reflows at the new viewport width).
    private var lastLayoutWidth: CGFloat = 0
    /// Last canvas-space (layout CSS px) document size handed to the canvas —
    /// the reflow detector's previous sample. See `synchronizeCanvasGeometry`.
    private var lastSyncedContentSize: CGSize = .zero

    init(webView: WKWebView) {
        super.init(frame: .zero)
        clipsToBounds = true
        backgroundColor = .clear
        isOpaque = false

        configure(canvas)
        addSubview(canvas)

        let scroll = webView.scrollView
        webScrollView = scroll
        visualScale = max(scroll.zoomScale, 0.01)

        // KVO only — never replace WebKit's scrollView.delegate (decision 2).
        webObservations.append(scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.webOffsetChanged() }
        })
        webObservations.append(scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.webContentSizeChanged() }
        })
        webObservations.append(scroll.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.webZoomScaleChanged() }
        })
        observeCanvasOffset()

        webContentSizeChanged()
        applyVisualTransform()
        webOffsetChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Apply the fixed per-canvas configuration. Runs on the initial canvas and
    /// on every replacement built by `recreateCanvas()`.
    private func configure(_ canvas: WebInkCanvas_iOS) {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // A web page's own theme is independent of the system theme, so pin the
        // canvas to light appearance (decision 11): otherwise in dark mode
        // PencilKit adaptively lightens dark inks — pure black renders as a
        // washed-out grey — and ink stops being WYSIWYG against the page.
        canvas.overrideUserInterfaceStyle = .light
        // Offsets must map 1:1 against the web scroll view; safe-area insets
        // are mirrored explicitly from its adjustedContentInset instead.
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.delegate = self
    }

    /// (Re)bind the canvas-offset KVO to the current `canvas`. The canvas is
    /// itself a scroll view; when ink is active it is the live scroller and its
    /// offset mirrors back into the page.
    private func observeCanvasOffset() {
        canvasObservation?.invalidate()
        canvasObservation = canvas.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.canvasOffsetChanged() }
        }
    }

    /// Stop observing the web scroll view. Idempotent — a superseded mount's
    /// dismantle may run after the replacement already attached a new overlay.
    func teardown() {
        for observation in webObservations { observation.invalidate() }
        webObservations.removeAll()
        canvasObservation?.invalidate()
        canvasObservation = nil
        canvas.delegate = nil
        ink = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        synchronizeCanvasGeometry()
        // Viewport width change (rotation, split-screen) re-wraps every line:
        // kick the re-anchor settle sequence. The content script's own resize
        // relayout reports too — anchorsShifted coalesces the two signals.
        if bounds.width != lastLayoutWidth {
            let firstLayout = lastLayoutWidth == 0
            lastLayoutWidth = bounds.width
            if !firstLayout { ink?.anchorsShifted() }
        }
    }

    /// Pencil-only web ink must not steal direct-touch navigation from WebKit.
    /// Returning nil lets the container continue hit-testing the WKWebView
    /// underneath, so one-finger scrolling and native two-finger pinch keep
    /// Safari's exact focal-point/velocity behavior while Pencil touches still
    /// land on the canvas. Finger-drawing mode remains intentionally modal.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        #if !targetEnvironment(simulator)
        if ink?.toolState.allowFingerDrawing != true,
           let touches = event?.allTouches,
           !touches.isEmpty,
           !touches.contains(where: Self.isPencilInContact) {
            return nil
        }
        #endif
        return super.hitTest(point, with: event)
    }

    /// A Pencil that is actually drawing — not one hovering over the glass and
    /// not one whose stroke already ended.
    ///
    /// `UIEvent.allTouches` is app-wide, and on hover-capable iPads a Pencil
    /// within ~12 mm delivers `.regionEntered/.regionMoved/.regionExited`
    /// touches that are still `type == .pencil`. Asking only "does this event
    /// contain a pencil touch" therefore reads "Pencil resting in hand near the
    /// screen" as "the Pencil owns this event", and the canvas claims the
    /// user's fingers. That kills pinch outright, because the web ink overlay
    /// is a SIBLING of the WKWebView (unlike the PDF canvas, which is a
    /// descendant of PDFView and so keeps ancestor recognizers alive): WebKit's
    /// pinch/pan recognizers live on the web scroll view, so a touch
    /// hit-tested to the canvas never reaches them at all. Returning nil is the
    /// only channel by which fingers reach the page.
    private static func isPencilInContact(_ touch: UITouch) -> Bool {
        guard touch.type == .pencil else { return false }
        switch touch.phase {
        case .began, .moved, .stationary: return true
        default: return false
        }
    }

    // MARK: - Native pinch (decision 4)

    /// Geometry contract: with `canvas.contentOffset = webOffset / s`, a
    /// document point `d` must render at viewport coordinate `d·s − webOffset`.
    /// The canvas's *unscaled* viewport must therefore be `(W/s, H/s)`, with a
    /// scale-by-`s` transform centered in the overlay. This both produces that
    /// mapping and keeps the canvas's scrollable range identical to WebKit's.
    ///
    /// Keeping `(W, H)` as the canvas bounds (the old implementation) made its
    /// transformed frame `s` times the reader: at 75% zoom the drawing surface
    /// covered only 75% of the viewport, while above 100% its content offset
    /// clamped before WebKit's near the document edges.
    private func applyVisualTransform() {
        let s = max(visualScale, 0.01)
        canvas.bounds.size = CGSize(
            width: bounds.width / s,
            height: bounds.height / s)
        canvas.transform = abs(s - 1) < 0.0001 ? .identity : CGAffineTransform(scaleX: s, y: s)
        canvas.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func webZoomScaleChanged() {
        guard let web = webScrollView else { return }
        let s = max(web.zoomScale, 0.01)
        guard abs(s - visualScale) > 0.0001 else { return }
        visualScale = s
        synchronizeCanvasGeometry()
    }

    // MARK: - Scroll sync (decision 2)

    private func webOffsetChanged() {
        guard !isSyncing, let web = webScrollView else { return }
        let liveScale = max(web.zoomScale, 0.01)
        if abs(liveScale - visualScale) > 0.0001 {
            visualScale = liveScale
            synchronizeCanvasGeometry()
            return
        }
        isSyncing = true
        canvas.contentOffset = CGPoint(
            x: web.contentOffset.x / visualScale,
            y: web.contentOffset.y / visualScale)
        isSyncing = false
    }

    /// Mode-dependent direction: only while ink is active is the canvas the
    /// interactive scroller (fingers pan it under `.pencilOnly`); inactive, its
    /// offset only ever changes through `webOffsetChanged`, which holds the
    /// flag.
    private func canvasOffsetChanged() {
        guard !isSyncing, ink?.isActive == true, let web = webScrollView else { return }
        isSyncing = true
        web.contentOffset = CGPoint(
            x: canvas.contentOffset.x * visualScale,
            y: canvas.contentOffset.y * visualScale)
        isSyncing = false
    }

    /// The canvas drawing surface always spans the full web document
    /// (decision 1). The web scroll view reports its contentSize ×zoomScale
    /// mid-pinch; dividing by `visualScale` keeps the canvas's own space
    /// stable through the gesture.
    private func webContentSizeChanged() {
        synchronizeCanvasGeometry()
    }

    /// Update every canvas property that participates in the WebKit↔PencilKit
    /// coordinate transform as one transaction. Resizing a UIScrollView or
    /// changing its content size may clamp `contentOffset` synchronously; keep
    /// the mirroring guard raised until the exact WebKit offset is restored so
    /// zoom/layout changes cannot echo a transient clamp back into the page.
    private func synchronizeCanvasGeometry() {
        guard let web = webScrollView else { return }
        let size = web.contentSize
        guard size.width > 0, size.height > 0 else { return }
        let wasSyncing = isSyncing
        isSyncing = true
        visualScale = max(web.zoomScale, 0.01)
        applyVisualTransform()
        canvas.contentSize = CGSize(
            width: size.width / visualScale,
            height: size.height / visualScale)
        // Insets are reported in rendered view points. The canvas scrolls in
        // layout-CSS points, so they must be divided by the same visual scale
        // as contentSize and contentOffset.
        let inset = web.adjustedContentInset
        canvas.contentInset = UIEdgeInsets(
            top: inset.top / visualScale,
            left: inset.left / visualScale,
            bottom: inset.bottom / visualScale,
            right: inset.right / visualScale)
        canvas.contentOffset = CGPoint(
            x: web.contentOffset.x / visualScale,
            y: web.contentOffset.y / visualScale)
        isSyncing = wasSyncing
        detectReflow()
    }

    /// Tell the controller when WebKit's own relayout landed.
    ///
    /// This is the missing half of the toolbar-zoom interlock. `applyZoom` is an
    /// asynchronous cross-process message, so `zoomChanged` → `anchorsShifted`
    /// runs against the PRE-reflow DOM, and the anchor capture it posts rides
    /// the same web-process IPC queue behind `_setViewScale:`. By the time the
    /// script handles it, the first `getBoundingClientRect()` has force-flushed
    /// the pending relayout — so cluster bands computed in the old layout get
    /// hit-tested against the new one, anchoring ink to whatever text slid into
    /// those coordinates. Nothing else on the native side ever learns the
    /// reflow happened: `layoutSubviews` fires only when the OVERLAY resizes
    /// (rotation, split view), which a viewScale change does not touch, and the
    /// page's own ResizeObserver report arrives 250 ms later — after the
    /// poisoned anchor has already been cached and persisted.
    ///
    /// WebKit's content size is the one piece of native evidence available, and
    /// bumping the layout generation here is what makes the in-flight capture's
    /// `anchorLayoutGeneration` check reject it. Comparing in canvas space
    /// (already divided by `visualScale`) is what keeps a live pinch — which
    /// magnifies without reflowing, leaving CSS px unchanged — from tripping it.
    private func detectReflow() {
        let synced = canvas.contentSize
        guard abs(synced.width - lastSyncedContentSize.width) > 1
            || abs(synced.height - lastSyncedContentSize.height) > 1 else { return }
        let first = lastSyncedContentSize == .zero
        lastSyncedContentSize = synced
        if !first { ink?.anchorsShifted() }
    }

    /// Programmatically replace the drawing without reporting a user edit —
    /// the load path (persistence step) and the re-anchor pass seed / re-place
    /// ink through this.
    func setDrawing(_ drawing: PKDrawing) {
        // Replacing existing ink with a new non-empty drawing is the re-anchor
        // move: it must recreate the canvas to render (see `recreateCanvas`).
        // Seeding onto an empty canvas or clearing to empty can go in place —
        // an empty→non-empty first assignment renders fine, and clears have
        // nothing to repaint.
        let replacingInk = !canvas.drawing.strokes.isEmpty && !drawing.strokes.isEmpty
        if replacingInk, canvas.superview != nil {
            recreateCanvas(with: drawing)
        } else {
            suppressChange = true
            canvas.drawing = drawing
            suppressChange = false
        }
    }

    /// Replace the live canvas with a fresh `PKCanvasView` seeded with `drawing`,
    /// to make a re-anchor move actually repaint.
    ///
    /// `PKCanvasView` renders ink through an internal Metal-backed tiled layer
    /// whose invalidation is driven by live touch/Pencil interaction, not the
    /// standard UIKit display cycle. Assigning `.drawing` while a stroke is in
    /// progress (or in the runloop turn the gesture ended in) repaints; assigning
    /// it once the renderer has gone idle updates the `PKDrawing` model but
    /// leaves the previously rendered ink composited on screen. Every re-anchor
    /// swap is idle by construction (`reanchorPass` is gated on `!isToolInUse`),
    /// so on each ink-mode-toggle reflow the strokes' coordinates moved with the
    /// text while the pixels stayed put — stranding them ~40 px (≈2 lines) off.
    /// `setNeedsDisplay()`, `layoutIfNeeded()`, re-assigning `.drawing`, and
    /// detaching/re-attaching the same canvas are all confirmed ineffective
    /// against this renderer (re-assigning also races it to a blank frame). A
    /// *newly constructed* canvas renders the drawing handed to it at
    /// construction reliably — the one code path Apple's own samples exercise —
    /// so swap the instance instead of trying to invalidate the old one.
    ///
    /// Trade-off: the replacement starts with an empty `UndoManager`, so a
    /// reflow/zoom re-anchor clears ink undo history. That is acceptable here —
    /// re-anchor already mutates `.drawing` directly (outside the undo stack), so
    /// undo across a reflow was never coherent, and reflow is an explicit user
    /// action.
    private func recreateCanvas(with drawing: PKDrawing) {
        guard let parent = canvas.superview else {
            suppressChange = true
            canvas.drawing = drawing
            suppressChange = false
            return
        }
        let old = canvas
        let offset = old.contentOffset

        let fresh = WebInkCanvas_iOS()
        configure(fresh)
        // Seed geometry + drawing BEFORE inserting so the first composite is
        // already correct (no blank/again flash), then adopt it as the live
        // canvas and re-point the offset KVO at it.
        fresh.bounds.size = bounds.size
        fresh.contentSize = old.contentSize
        fresh.contentInset = old.contentInset
        // `configure` already attached the delegate, so this assignment is
        // reported as a user edit — the same PencilKit behavior the in-place
        // branch of `setDrawing` raises this flag for. Unguarded, every
        // re-anchor move re-entered `drawingChanged` mid-`reanchorPass`: it
        // bumped `drawingVersion` and fired an anchor capture that the pass's
        // own bump one line later then rejected, so each settle pass burned two
        // bridge round trips and deferred the re-capture a whole pass.
        suppressChange = true
        fresh.drawing = drawing
        suppressChange = false
        fresh.tool = old.tool

        let wasSyncing = isSyncing
        isSyncing = true
        canvas = fresh
        observeCanvasOffset()
        parent.insertSubview(fresh, aboveSubview: old)
        applyVisualTransform()          // sets transform + center for `fresh`
        fresh.contentOffset = offset
        old.delegate = nil
        old.removeFromSuperview()
        isSyncing = wasSyncing
        // A brand-new PKCanvasView resets to the default tool/drawing policy;
        // re-apply the overlay's live tool and interaction policy so drawing
        // continues to work after a reflow recreate.
        applyTool()
        refreshPolicy()
    }

    // MARK: - State propagation (driven by the controller)

    /// Re-apply the active tool. The canvas draws in layout CSS px; the view
    /// transform magnifies stroke widths together with the page, so the
    /// user-selected width needs no zoom scaling.
    func applyTool() {
        canvas.tool = ink?.pkTool() ?? PKInkingTool(.pen, color: .black, width: 4)
    }

    /// Ink mode is modal, like PDF (decision 10): while active the overlay
    /// intercepts all touches — links, text selection, and note interactions
    /// are inert; inactive, every touch passes through to the page.
    func refreshPolicy() {
        let active = (ink?.isActive ?? false) && ink?.toolState.tool != .textHighlight
        isUserInteractionEnabled = active
        #if targetEnvironment(simulator)
        canvas.drawingPolicy = .anyInput // no Pencil in the Simulator
        #else
        canvas.drawingPolicy =
            (ink?.toolState.allowFingerDrawing ?? false) ? .anyInput : .pencilOnly
        #endif
    }

    // MARK: - PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !suppressChange else { return }
        ink?.drawingChanged(canvasView.drawing)
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        isToolInUse = true
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        isToolInUse = false
        ink?.toolUseEnded()
    }

    // MARK: - UIPencilInteractionDelegate

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        ink?.pencilDoubleTap(preferredAction: UIPencilInteraction.preferredTapAction)
    }
}
#endif
