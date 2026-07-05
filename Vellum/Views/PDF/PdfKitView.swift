import PDFKit
import SwiftUI

// NSViewRepresentable around PDFKit's PDFView: continuous vertical layout,
// zoom clamped 0.25–4.0, well background, scroll/zoom tracking, and local
// event monitors feeding PdfViewerController (note placement, selection
// capture, context menu, note-mode crosshair cursor).

struct PdfKitView: NSViewRepresentable {
    let controller: PdfViewerController
    let document: PDFDocument

    @Environment(AppStore.self) private var app
    @Environment(\.palette) private var palette

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = false
        view.displaysPageBreaks = true
        // 12px gap between pages (top 6 + bottom 6); PDFKit has no separate
        // edge padding, so the 16px py of the original becomes 6.
        view.pageBreakMargins = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        view.minScaleFactor = AppStore.minZoom
        view.maxScaleFactor = AppStore.maxZoom
        view.backgroundColor = NSColor(palette.well)
        view.document = document
        view.scaleFactor = min(AppStore.maxZoom, max(AppStore.minZoom, app.zoom))
        controller.pdfView = view
        context.coordinator.attach(to: view)
        controller.documentAttached()
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        nsView.backgroundColor = NSColor(palette.well)
        // Store → view zoom sync, ONLY on the fallback path where no anchored
        // zoom handler is registered. While a PDF viewer is live the handler is
        // always set and zoom flows view → store: the pinch gesture / zoomTo
        // drive scaleFactor directly and PDFViewScaleChanged mirrors it into
        // app.zoom. Re-asserting app.zoom onto scaleFactor here would fight the
        // live magnify gesture (yanking it back to a lagging clamped value) and
        // undo rapid button zooms that app.zoom hasn't caught up to yet.
        if app.zoomToHandler == nil, abs(nsView.scaleFactor - app.zoom) > 0.0001 {
            nsView.scaleFactor = app.zoom
        }
        // Note-mode crosshair (the original's cursor-crosshair container class).
        context.coordinator.noteModeChanged(app.mode == .note)
    }

    /// Always adopt the container's proposed size and never the PDFView's own
    /// fitting size — which is the full document (e.g. 1890×2446 vs a 1293×1184
    /// viewport). Without this, a relayout triggered by a highlight add/remove
    /// makes SwiftUI re-measure the host and resize it to that huge intrinsic
    /// size for a pass: the PDFView stretches past the window and its scroll
    /// view retiles, snapping a zoomed/panned document's scroll position (the
    /// "recentering"). Echoing the proposal keeps the host pinned to the
    /// viewport across every layout pass.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PDFView, context: Context) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height,
              width.isFinite, height.isFinite else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: Coordinator) {
        coordinator.detach(from: nsView)
    }

    @MainActor
    final class Coordinator: NSObject {
        private let controller: PdfViewerController
        private weak var view: PDFView?
        private var observers: [NSObjectProtocol] = []
        private var monitors: [Any] = []
        private var trackingArea: NSTrackingArea?
        private var noteModeActive = false

        init(controller: PdfViewerController) {
            self.controller = controller
        }

        func attach(to view: PDFView) {
            self.view = view
            let center = NotificationCenter.default

            observers.append(center.addObserver(
                forName: .PDFViewScaleChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.controller.scaleChanged()
                }
            })

            if let clipView = view.documentView?.enclosingScrollView?.contentView {
                clipView.postsBoundsChangedNotifications = true
                observers.append(center.addObserver(
                    forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self,
                              let clip = self.view?.documentView?.enclosingScrollView?.contentView
                        else { return }
                        self.controller.scrollChanged(origin: clip.bounds.origin)
                    }
                })
            }

            // Per-frame zoom signal for the annotation overlays. PDFKit defers
            // .PDFViewScaleChanged until a trackpad magnify ENDS, and the host
            // frame is pinned to the viewport, so mid-pinch the only geometry
            // that moves is the documentView (PDFKit resizes it to
            // pageSize × scaleFactor every frame). Without observing it, a pinch
            // that doesn't also shift the clip origin (content anchored at the
            // top-left, or smaller than the viewport) bumps nothing, and the
            // overlays freeze at the pre-pinch scale until release. layoutChanged
            // only bumps geometry (never touches scaleFactor), so it can't fight
            // the gesture or loop.
            if let documentView = view.documentView {
                documentView.postsFrameChangedNotifications = true
                observers.append(center.addObserver(
                    forName: NSView.frameDidChangeNotification, object: documentView, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.controller.layoutChanged()
                    }
                })
            }

            view.postsFrameChangedNotifications = true
            observers.append(center.addObserver(
                forName: NSView.frameDidChangeNotification, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.controller.layoutChanged()
                }
            })

            // Guarantees mouse-moved events flow for the note-mode crosshair.
            let tracking = NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            view.addTrackingArea(tracking)
            trackingArea = tracking

            installMonitors()
        }

        func detach(from view: PDFView) {
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
            }
            observers = []
            for monitor in monitors {
                NSEvent.removeMonitor(monitor)
            }
            monitors = []
            if let trackingArea {
                view.removeTrackingArea(trackingArea)
            }
            trackingArea = nil
            if controller.pdfView === view {
                controller.pdfView = nil
            }
            self.view = nil
        }

        /// Tracking-area owner hook; the mouse-moved monitor does the work.
        @objc func mouseMoved(with event: NSEvent) {}

        // MARK: - Event monitors

        private func installMonitors() {
            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] event in
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let view = self.view, event.window === view.window else {
                        return false
                    }
                    let native = view.convert(event.locationInWindow, from: nil)
                    guard view.bounds.contains(native) else {
                        // Window-wide dismissal (the original listens on
                        // window mousedown/click): clicks on the toolbar or
                        // sidebar close the popover and context menu.
                        self.controller.handleOutsideMouseDown()
                        return false
                    }
                    guard let point = self.pdfPoint(for: event) else {
                        // A SwiftUI overlay inside the viewer (popover, note,
                        // highlight, menu) — those stopPropagation upstream.
                        return false
                    }
                    return self.controller.handleMouseDown(atNative: point)
                }
                return swallow ? nil : event
            }) {
                monitors.append(monitor)
            }

            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in
                MainActor.assumeIsolated {
                    // Container-level mouseup like the original's onMouseUp on
                    // the scroll container: a selection drag released on top of
                    // a highlight rect or sticky-note pill must still capture
                    // (overlays only stop propagation for mousedown/click), so
                    // no hit-test gate here — just bounds containment.
                    guard let self, let view = self.view,
                          event.window === view.window else { return }
                    let point = view.convert(event.locationInWindow, from: nil)
                    guard view.bounds.contains(point) else { return }
                    self.controller.handleMouseUp(atNative: point)
                }
                return event
            }) {
                monitors.append(monitor)
            }

            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown, handler: { [weak self] event in
                let overPdf = MainActor.assumeIsolated { () -> Bool in
                    guard let self, let point = self.pdfPoint(for: event) else { return false }
                    _ = self.controller.handleRightMouseDown(atNative: point)
                    return true
                }
                // Swallow whenever the click targeted the PDFView so its own
                // context menu never appears (the annotation layer / native
                // menus are disabled in the original).
                return overPdf ? nil : event
            }) {
                monitors.append(monitor)
            }

            if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .cursorUpdate], handler: { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, self.controller.isNoteMode,
                          self.pdfPoint(for: event) != nil else { return }
                    // PDFView re-sets its own cursor (arrow / I-beam) while it
                    // handles this event, so asserting the crosshair here would
                    // be immediately overridden. Re-assert on the next runloop
                    // turn, after PDFView's handling ran.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.controller.isNoteMode else { return }
                        NSCursor.crosshair.set()
                    }
                }
                return event
            }) {
                monitors.append(monitor)
            }
        }

        /// Mode-change hook from updateNSView: show the crosshair immediately
        /// when note mode turns on with the pointer already over the viewer
        /// (the monitor above keeps it asserted while the mouse moves), and
        /// restore the arrow when note mode ends.
        func noteModeChanged(_ active: Bool) {
            guard active != noteModeActive else { return }
            noteModeActive = active
            guard let view, let window = view.window else { return }
            let mouse = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard view.bounds.contains(mouse) else { return }
            if active {
                NSCursor.crosshair.set()
            } else {
                NSCursor.arrow.set()
            }
        }

        /// Location in PDFView coords when the event targets the PDFView's own
        /// hierarchy (SwiftUI overlays above it hit-test to the hosting view
        /// and are ignored here); nil otherwise.
        private func pdfPoint(for event: NSEvent) -> CGPoint? {
            guard let view, let window = view.window, event.window === window else { return nil }
            guard let content = window.contentView else { return nil }
            let root = content.superview ?? content
            guard let hit = root.hitTest(event.locationInWindow),
                  hit.isDescendant(of: view) else { return nil }
            return view.convert(event.locationInWindow, from: nil)
        }
    }
}
