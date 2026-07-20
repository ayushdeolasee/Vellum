#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

// UIViewRepresentable around PDFKit's PDFView for iPad: continuous vertical
// layout, native pinch-zoom clamped 0.25–4.0, well background, and scroll/zoom/
// selection tracking feeding PdfViewerControlleriOS. Touch selection is native
// (long-press handles); note placement + dismissal happen in the SwiftUI overlay.

/// PDFView subclass — a hook for the Pencil ink canvas (Phase 4) and a spot to
/// trim the selection edit menu so the custom Liquid Glass popover leads.
final class VellumPDFView: PDFView {
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

    @Environment(AppStore.self) private var app
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller, ink: ink) }

    func makeUIView(context: Context) -> PDFView {
        let view = VellumPDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.displaysPageBreaks = true
        view.pageBreakMargins = UIEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.minScaleFactor = CGFloat(AppStore.minZoom)
        view.maxScaleFactor = CGFloat(AppStore.maxZoom)
        view.backgroundColor = UIColor(palette.well)
        // Install the Pencil overlay provider BEFORE the document so PDFKit wires
        // a per-page canvas as each page lays out.
        view.pageOverlayViewProvider = ink.inkProvider
        // One Pencil double-tap interaction on the always-mounted PDFView (not on
        // the virtualized per-page canvases), so barrel double-taps are delivered
        // reliably regardless of scroll position / which page canvas is live.
        view.addInteraction(UIPencilInteraction(delegate: ink.inkProvider))
        view.document = document
        view.scaleFactor = CGFloat(min(AppStore.maxZoom, max(AppStore.minZoom, app.zoom)))
        controller.pdfView = view
        context.coordinator.attach(to: view)
        controller.documentAttached()
        return view
    }

    func updateUIView(_ uiView: PDFView, context: Context) {
        uiView.backgroundColor = UIColor(palette.well)
        if uiView.document !== document {
            uiView.document = document
            controller.pdfView = uiView
            controller.documentAttached()
        }
        // Store → view zoom sync only when it drifts (button zoom); the live
        // pinch drives scaleFactor directly and PDFViewScaleChanged mirrors it.
        if abs(Double(uiView.scaleFactor) - app.zoom) > 0.0001 {
            uiView.scaleFactor = CGFloat(app.zoom)
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
            if controller.pdfView === view { controller.pdfView = nil }
            view = nil
        }
    }
}
#endif
