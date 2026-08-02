#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

// UIViewRepresentable around PDFKit's PDFView for iPad: continuous vertical
// layout, native pinch-zoom clamped 0.25–4.0, well background, and scroll/zoom/
// selection tracking feeding PdfViewerControlleriOS. Touch selection is native
// (long-press handles); note placement + dismissal happen in the SwiftUI overlay.

/// PDFView subclass — a hook for the Pencil ink canvas (Phase 4), a spot to
/// trim the selection edit menu so the custom Liquid Glass popover leads, and
/// the carrier for Vellum's hardware-keyboard commands over a PDF.
final class VellumPDFView: PDFView, VellumShortcutResponder {
    var onShortcut: VellumShortcutHandler?

    // MARK: - Zoom policy (issue #152)

    /// How this view picks its scale, injected by whichever shell hosts it
    /// (`\.pdfZoomMode`). `.free` — the default, and every iPad/mac mount — is
    /// the behaviour this view has always had: absolute zoom between the
    /// app-wide bounds. `.fitWidth` is the phone reader.
    var zoomMode: PdfZoomMode = .free {
        didSet {
            guard zoomMode != oldValue else { return }
            // The bounds themselves change with the mode, so nothing about the
            // previously applied policy can be reused.
            appliedPolicy = nil
            // A mode change changes the RULES, which means the scale the view
            // is sitting at was chosen under rules that no longer hold: a tab
            // adopted into the phone reader at an absolute 200% has to be
            // FITTED, not merely floored. Only `openingScale` fits, and only
            // `refitsFromScratch` routes through it.
            refitsFromScratch = true
            applyZoomPolicy()
        }
    }

    /// Whether this mount is its pane's active tab — the same flag
    /// `PdfKitView_iOS.isActive` carries, pushed down because the fit is
    /// applied from `layoutSubviews`, which UIKit runs on background tabs too.
    /// See `applyZoomPolicy` for what an unguarded background fit would do.
    var isActive: Bool = true {
        didSet {
            // A tab that was fitted-out while inactive (or whose viewport
            // rotated underneath it) fits on the way in. Going inactive needs
            // no work: the guard simply starts refusing.
            guard isActive, isActive != oldValue else { return }
            applyZoomPolicy()
        }
    }

    /// The app-wide zoom range (`AppStore.minZoom ... AppStore.maxZoom`), kept
    /// separately because `minScaleFactor` is no longer a copy of it: fit-width
    /// RAISES the view's minimum to the fit scale, so the absolute floor has to
    /// survive somewhere for the policy to be recomputed from.
    var absoluteScaleRange: ClosedRange<Double> = AppStore.minZoom...AppStore.maxZoom

    /// The policy currently installed, and the document it was installed for.
    /// A new document opens at its fit scale; a mere viewport change adjusts
    /// the scale the reader is already at (`PdfZoomPolicy.adjustedScale`).
    ///
    /// The document reference is weak — this is an identity marker, not
    /// ownership — and a zeroed one reads as "different", which re-fits. That
    /// is the safe direction to fail in.
    private var appliedPolicy: PdfZoomPolicy?
    private weak var appliedDocument: PDFDocument?

    /// Set when the next apply has to FIT rather than adjust — a mode change,
    /// which is the one case where the document is unchanged and the scale
    /// still has to be recomputed from the viewport rather than carried over.
    private var refitsFromScratch = false

    /// The viewport's width is only known once UIKit has laid the view out —
    /// it is zero throughout `makeUIView` — so the fit is applied here rather
    /// than at construction. This is also the callback that fires on rotation
    /// and on any resize of the reader, which is exactly when a width-derived
    /// scale needs recomputing.
    override func layoutSubviews() {
        super.layoutSubviews()
        applyZoomPolicy()
    }

    /// Re-derive the scale bounds for the current viewport and apply them.
    ///
    /// Under `.free` the resolved policy is a constant — the same
    /// `minScaleFactor`/`maxScaleFactor` the representable already assigned,
    /// and an opening scale equal to the current one — so the first call is a
    /// no-op assignment and every later call returns at the `appliedPolicy`
    /// guard. That is what keeps the iPad path untouched by construction.
    func applyZoomPolicy() {
        // An INACTIVE mount must not touch `scaleFactor`. PDFKit answers every
        // assignment with `.PDFViewScaleChanged`, the coordinator mirrors that
        // into the PANE-WIDE `AppStore.zoom`, and the pane's visible tab would
        // then be dragged to a background tab's fit scale on its next
        // `updateUIView`. `updateUIView` already guards the store→view half of
        // that loop on `isActive`; this is the view→store half. The fit is not
        // lost, only deferred: `isActive.didSet` re-runs this on the way in,
        // and UIKit lays the view out again when it is shown.
        guard isActive, let document, bounds.width > 0 else { return }
        let policy = PdfZoomPolicy.resolve(
            mode: zoomMode,
            pageWidth: Self.displayedWidth(of: document.page(at: 0), box: displayBox),
            viewportWidth: Double(bounds.width),
            // The only horizontal padding this view adds; vertical page breaks
            // carry the 6pt gaps, the sides are flush. If a device check ever
            // shows PDFKit inset the page further, it is fed in HERE and the
            // policy needs no change.
            horizontalInset: Double(pageBreakMargins.left + pageBreakMargins.right),
            minimumScale: absoluteScaleRange.lowerBound,
            maximumScale: absoluteScaleRange.upperBound)
        // A fresh document and a mode change are the two "fit it" cases;
        // everything else (rotation, a resize) adjusts the scale in hand.
        let fitsFromScratch = refitsFromScratch || appliedDocument !== document
        guard fitsFromScratch || policy != appliedPolicy else { return }
        let previousFitWidth = appliedPolicy?.fitWidthScale
        refitsFromScratch = false
        appliedPolicy = policy
        appliedDocument = document
        minScaleFactor = CGFloat(policy.minimumScale)
        maxScaleFactor = CGFloat(policy.maximumScale)
        let target = fitsFromScratch
            ? policy.openingScale(persisted: Double(scaleFactor))
            : policy.adjustedScale(
                current: Double(scaleFactor), previousFitWidth: previousFitWidth)
        if abs(target - Double(scaleFactor)) > 0.0001 {
            scaleFactor = CGFloat(target)
            // PDFKit posts .PDFViewScaleChanged for this, which is what mirrors
            // the new scale into AppStore.zoom (the % label, the persisted tab).
        }
    }

    /// Width of a page as it is DISPLAYED, at zoom 1.
    ///
    /// Page one stands in for the document: a per-page fit would rescale the
    /// reader mid-scroll through a document with mixed page sizes, which reads
    /// as the page jumping, and mixed sizes are rare enough not to be worth
    /// that. `bounds(for:)` is in unrotated page space, so a `/Rotate 90` page
    /// displays with its height across.
    private static func displayedWidth(of page: PDFPage?, box: PDFDisplayBox) -> Double {
        guard let page else { return 0 }
        let bounds = page.bounds(for: box)
        return Double(page.rotation % 180 == 0 ? bounds.width : bounds.height)
    }

    /// Built once: `keyCommands` is queried on every key press while this view
    /// is in the responder chain, and the array is constant for the lifetime of
    /// the view (the catalog is static and the selector never changes).
    private lazy var vellumCommands: [UIKeyCommand] =
        vellumKeyCommands(action: #selector(vellumPerformShortcut(_:)))

    /// Vellum's chords are listed first so they take precedence over anything
    /// PDFKit contributes for the same combination (scroll-to-top on ⌘↑, its own
    /// find plumbing on ⌘F), and `super`'s are preserved so nothing else PDFKit
    /// offers is lost. See `VellumShortcutResponder` for why the duplication
    /// with the SwiftUI menu is necessary at all.
    override var keyCommands: [UIKeyCommand]? {
        vellumCommands + (super.keyCommands ?? [])
    }

    @objc private func vellumPerformShortcut(_ sender: UIKeyCommand) {
        vellumPerform(sender)
    }

    override func buildMenu(with builder: UIMenuBuilder) {
        // Suppress the system callout entirely — it fights the Liquid Glass
        // selection popover for the same anchor (the popover carries copy /
        // highlight / note itself).
        builder.remove(menu: .lookup)
        builder.remove(menu: .learn)
        builder.remove(menu: .standardEdit)
        builder.remove(menu: .share)
        builder.remove(menu: .replace)
        builder.remove(menu: .find)
        super.buildMenu(with: builder)
    }
}

struct PdfKitView_iOS: UIViewRepresentable {
    let controller: PdfViewerControlleriOS
    let document: PDFDocument
    let ink: InkController_iOS
    /// Whether this mount is its pane's active tab. Inactive mounts are drawn
    /// at opacity 0 and must not push the shared store's zoom back into their
    /// own view — that would fight the visible tab's pinch.
    let isActive: Bool

    @Environment(AppStore.self) private var app
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    /// `.fitWidth` only under the compact phone shell; `.free` everywhere else,
    /// including an iPad in Slide Over. See `RootShell_iOS`.
    @Environment(\.pdfZoomMode) private var zoomMode

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, ink: ink) }

    func makeUIView(context: Context) -> PDFView {
        // Live tabs: the PDFView belongs to the tab's `LiveTabRuntime` and
        // outlives this host, so a remount (tab dragged to another pane, a warm
        // tab coming back, or two hosts transiently claiming one tab during
        // Merge Panes) re-parents the existing view rather than rebuilding
        // PDFKit. `adoptRetainedView` hands it back PARENTLESS — a UIView may
        // have only one superview.
        if let retained = controller.adoptRetainedView(where: { $0.document === document }) {
            // Deliberately NOT re-running the configuration block below on an
            // adopted view. `pageOverlayViewProvider` is already this tab's ink
            // provider (ink is per-runtime), and `addInteraction` is additive:
            // re-adding the `UIPencilInteraction` on every remount would stack
            // delegates and fire one double-tap N times.
            context.coordinator.attach(to: retained)
            controller.documentAttached()
            return retained
        }
        let view = VellumPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.absoluteScaleRange = AppStore.minZoom...AppStore.maxZoom
        view.minScaleFactor = CGFloat(AppStore.minZoom)
        view.maxScaleFactor = CGFloat(AppStore.maxZoom)
        // Set before the document: the first layout pass is what computes the
        // fit-width scale, and it needs to know it is fitting — and whether it
        // is even allowed to touch the scale — by then.
        view.isActive = isActive
        view.zoomMode = zoomMode
        view.backgroundColor = UIColor(palette.well)
        // Install the Pencil overlay provider BEFORE the document so PDFKit wires
        // a per-page canvas as each page lays out.
        view.pageOverlayViewProvider = ink.inkProvider
        // One Pencil double-tap interaction on the always-mounted PDFView (not on
        // the virtualized per-page canvases), so barrel double-taps are delivered
        // reliably regardless of scroll position / which page canvas is live.
        view.addInteraction(UIPencilInteraction(delegate: ink.inkProvider))
        // Hardware-keyboard commands for when PDFKit holds first responder. The
        // WorkspaceStore is created once for the app's lifetime, so capturing it
        // here (rather than re-assigning on every update) cannot go stale.
        view.onShortcut = { [workspace] action in
            VellumShortcutRouter.perform(action, workspace: workspace)
        }
        view.document = document
        view.scaleFactor = CGFloat(min(AppStore.maxZoom, max(AppStore.minZoom, app.zoom)))
        controller.pdfView = view
        context.coordinator.attach(to: view)
        controller.documentAttached()
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.backgroundColor = UIColor(palette.well)
        // Both of these also cover the adopted-view path in `makeUIView`, where
        // a tab that moved between panes or shells has to be told which pane's
        // active tab it is now and what its new scaling rules are. Both setters
        // are idempotent — they ignore an unchanged value.
        //
        // `isActive` FIRST: a mount that is going inactive has to be refusing
        // scale writes before the mode change asks for a re-fit, or the fit it
        // performs on the way out lands in the pane's shared zoom.
        if let vellum = uiView as? VellumPDFView {
            vellum.isActive = isActive
            // A tab that just moved between shells is not merely floored at its
            // new mode's bounds — it is re-fitted, since an absolute scale
            // chosen on an iPad-sized viewport means nothing on a phone one.
            vellum.zoomMode = zoomMode
        }
        if uiView.document !== document {
            uiView.document = document
            controller.pdfView = uiView
            controller.documentAttached()
        }
        // `app.zoom` is the pane's ACTIVE tab's zoom. An inactive mount reading
        // it would yank its own (invisible) document to another tab's scale and
        // lose the user's place in it.
        guard isActive else { return }
        // Store → view zoom sync only when it drifts (button zoom); the live
        // pinch drives scaleFactor directly and PDFViewScaleChanged mirrors it.
        //
        // Bounded by the VIEW's range rather than pushed raw: fit-width reading
        // raises `minScaleFactor` above the app-wide floor, so a zoom persisted
        // on a roomier viewport (an iPad, a rotated phone) can sit below what
        // this one allows, and pushing it verbatim would strand the page
        // narrower than the screen. On iPad the two ranges are identical and
        // this is the same assignment it always was.
        let target = min(
            Double(uiView.maxScaleFactor), max(Double(uiView.minScaleFactor), app.zoom))
        if abs(Double(uiView.scaleFactor) - target) > 0.0001 {
            uiView.scaleFactor = CGFloat(target)
        }
    }

    static func dismantleUIView(_ uiView: PDFView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let controller: PdfViewerControlleriOS
        private let ink: InkController_iOS
        private weak var view: PDFView?
        private weak var scrollView: UIScrollView?
        private var observers: [NSObjectProtocol] = []
        private var offsetObservation: NSKeyValueObservation?

        init(controller: PdfViewerControlleriOS, ink: InkController_iOS) {
            self.controller = controller
            self.ink = ink
        }

        func attach(to view: PDFView) {
            self.view = view

            // Outside-tap dismissal (highlight editor / context menu / selection
            // popover) and long-press "Add note here". Non-cancelling +
            // simultaneous so PDFView's own tap/selection gestures keep working;
            // taps on the SwiftUI overlays never reach these (sibling views).
            let tap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)

            // Receives only empty-area presses (shouldReceive gate) and cancels
            // the touch when it fires, so PDFView's native long-press can't
            // snap-select the nearest word underneath the "Add note here" pill.
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
            longPress.minimumPressDuration = 0.35
            longPress.cancelsTouchesInView = true
            longPress.delegate = self
            view.addGestureRecognizer(longPress)
            noteLongPress = longPress

            // Two-finger double-tap → sticky note at the tap point (Settings
            // toggle). Skipped while ink mode is on: PencilKit owns the
            // two-finger tap there (system undo gesture).
            let twoFingerTap = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped(_:)))
            twoFingerTap.numberOfTapsRequired = 2
            twoFingerTap.numberOfTouchesRequired = 2
            twoFingerTap.cancelsTouchesInView = false
            twoFingerTap.delegate = self
            view.addGestureRecognizer(twoFingerTap)

            let center = NotificationCenter.default

            observers.append(center.addObserver(
                forName: .PDFViewScaleChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.controller.scaleChanged()
                    // Re-rasterize the ink canvases at the new zoom so strokes stay
                    // as crisp as PDFKit's re-rendered glyphs (no bitmap upscaling).
                    if let scale = self.view?.scaleFactor {
                        self.ink.inkProvider.zoomChanged(scale)
                    }
                }
            })
            observers.append(center.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.selectionChanged() }
            })
            observers.append(center.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.controller.layoutChanged() }
            })

            // The internal scroll view drives per-frame geometry. It exists once
            // the document lays out, so grab it on the next runloop turn.
            DispatchQueue.main.async { [weak self] in
                self?.bindScrollView()
            }
        }

        private func bindScrollView() {
            guard let view, let scroll = Self.findScrollView(in: view) else {
                // Retry once more after layout settles.
                DispatchQueue.main.async { [weak self] in
                    guard let self, let view = self.view,
                          let scroll = Self.findScrollView(in: view) else { return }
                    self.observeScroll(scroll)
                }
                return
            }
            observeScroll(scroll)
        }

        private func observeScroll(_ scroll: UIScrollView) {
            scrollView = scroll
            // Make PDFKit's internal long-presses (nearest-word selection) wait
            // for ours to fail. On text presses ours never receives the touch
            // (shouldReceive gate) so natives run immediately; on empty-area
            // presses ours recognizes and the natives stay blocked.
            // cancelsTouchesInView can't do this — touch cancellation stops
            // view delivery, not other gesture recognizers.
            if let ours = noteLongPress, let view {
                for native in Self.longPressRecognizers(in: view) where native !== ours {
                    native.require(toFail: ours)
                }
            }
            offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] scroll, _ in
                MainActor.assumeIsolated {
                    self?.controller.scrollChanged(offsetY: scroll.contentOffset.y)
                }
            }
            controller.layoutChanged()
        }

        private var noteLongPress: UILongPressGestureRecognizer?

        private static func longPressRecognizers(in root: UIView) -> [UILongPressGestureRecognizer] {
            var result: [UILongPressGestureRecognizer] = []
            var stack: [UIView] = [root]
            while let view = stack.popLast() {
                result.append(contentsOf: (view.gestureRecognizers ?? [])
                    .compactMap { $0 as? UILongPressGestureRecognizer })
                stack.append(contentsOf: view.subviews)
            }
            return result
        }

        private static func findScrollView(in view: UIView) -> UIScrollView? {
            for subview in view.subviews {
                if let scroll = subview as? UIScrollView { return scroll }
                if let nested = findScrollView(in: subview) { return nested }
            }
            return nil
        }

        @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
            controller.handleBackgroundTap()
        }

        @objc private func longPressed(_ gesture: UILongPressGestureRecognizer) {
            guard gesture.state == .began, let view else { return }
            controller.handleLongPress(atTopLeft: gesture.location(in: view))
        }

        @objc private func twoFingerTapped(_ gesture: UITapGestureRecognizer) {
            guard let view, !ink.isActive,
                  UserDefaults.standard.object(forKey: "twoFingerNoteTap") as? Bool ?? true
            else { return }
            controller.handleNoteTap(atTopLeft: gesture.location(in: view))
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }

        nonisolated func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            // The long-press only takes empty-area touches; on/near text it
            // must not receive at all so the native selection engages cleanly.
            guard gestureRecognizer is UILongPressGestureRecognizer else { return true }
            return MainActor.assumeIsolated {
                guard let view = self.view else { return false }
                return self.controller.isEmptyPageArea(atTopLeft: touch.location(in: view))
            }
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers = []
            offsetObservation?.invalidate()
            offsetObservation = nil
            // The PDFView is NOT released here. It belongs to the tab's
            // `LiveTabRuntime`, not to this host: nil'ing the controller's
            // reference on dismantle is what used to make every remount rebuild
            // PDFKit, and it is what `adoptRetainedView` above exists to undo.
            // The view is released by `LiveTabRuntime.releaseResidency()`, which
            // drops the controller wholesale.
            view = nil
        }
    }
}
#endif
