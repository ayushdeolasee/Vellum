import PDFKit
import SwiftUI

extension NSCursor {
    /// Cursor shown while placing a sticky note (note tool / "Add as note"): a
    /// bold "+" with a white halo so it stays legible over any page content.
    /// The hotspot sits at the crossing, marking exactly where the note lands.
    nonisolated(unsafe) static let addNote: NSCursor = {
        let side: CGFloat = 24
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let center = CGPoint(x: side / 2, y: side / 2)
            let arm: CGFloat = 7  // half-length of each arm from the crossing
            func drawPlus(width: CGFloat, color: NSColor) {
                color.setFill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: center.x - arm, y: center.y - width / 2, width: arm * 2, height: width),
                    xRadius: width / 2, yRadius: width / 2
                ).fill()
                NSBezierPath(
                    roundedRect: NSRect(
                        x: center.x - width / 2, y: center.y - arm, width: width, height: arm * 2),
                    xRadius: width / 2, yRadius: width / 2
                ).fill()
            }
            drawPlus(width: 5, color: .white)   // halo
            drawPlus(width: 2.5, color: .black)  // core
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()

    /// Cursor shown while dragging out a snapshot region for the AI ("Snapshot
    /// region…"): a crosshair with a small center gap — the macOS screen-capture
    /// idiom — signalling "drag to grab a screenshot." A white halo keeps it
    /// legible over any page content; the hotspot sits at the exact crossing.
    nonisolated(unsafe) static let snapshotCrosshair: NSCursor = {
        let side: CGFloat = 28
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let center = side / 2
            let gap: CGFloat = 3.5  // clear window around the exact target point
            func drawCross(width: CGFloat, color: NSColor) {
                color.setStroke()
                let path = NSBezierPath()
                path.lineWidth = width
                path.lineCapStyle = .round
                path.move(to: NSPoint(x: 1.5, y: center))
                path.line(to: NSPoint(x: center - gap, y: center))
                path.move(to: NSPoint(x: center + gap, y: center))
                path.line(to: NSPoint(x: side - 1.5, y: center))
                path.move(to: NSPoint(x: center, y: 1.5))
                path.line(to: NSPoint(x: center, y: center - gap))
                path.move(to: NSPoint(x: center, y: center + gap))
                path.line(to: NSPoint(x: center, y: side - 1.5))
                path.stroke()
            }
            drawCross(width: 3.5, color: .white)  // halo
            drawCross(width: 1.5, color: .black)  // core
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: side / 2, y: side / 2))
    }()
}

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
        // Custom mode cursors: note-placement "+" and the snapshot-region
        // crosshair (the original's cursor-crosshair container class). Reading
        // app.mode here registers the SwiftUI dependency so this runs on every
        // mode change.
        context.coordinator.cursorModeChanged(for: app.mode)
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
        private var activeCursor: NSCursor?

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
        /// MUST be `@objc(mouseMoved:)`: `Coordinator` is an `NSObject`, not an
        /// `NSResponder`, so a bare `@objc func mouseMoved(with:)` would export the
        /// selector `mouseMovedWith:` while `NSTrackingArea` sends `mouseMoved:` —
        /// every mouse-move over the PDF would then throw `unrecognized selector`
        /// (an NSInvalidArgumentException that crashes under NSApplicationCrashOnExceptions).
        @objc(mouseMoved:) func mouseMoved(with event: NSEvent) {}

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
                    guard let self, let cursor = self.modeCursor,
                          self.pointerOverViewer(event) else { return }
                    // The PDFView (and the SwiftUI overlay above it) re-set their
                    // own cursor while handling this event, so asserting here
                    // would be immediately overridden. Re-assert on the next
                    // runloop turn, after their handling ran.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, let cursor = self.modeCursor else { return }
                        cursor.set()
                    }
                }
                return event
            }) {
                monitors.append(monitor)
            }
        }

        /// The custom cursor for a given interaction mode (note-placement "+" or
        /// the snapshot-region crosshair), or nil for modes with the plain arrow.
        private func cursor(for mode: InteractionMode) -> NSCursor? {
            switch mode {
            case .note: return .addNote
            case .snapshotRegion: return .snapshotCrosshair
            default: return nil
            }
        }

        /// The custom cursor for the live mode, read from the controller — used
        /// by the mouse-moved monitor, which fires outside SwiftUI's update pass.
        private var modeCursor: NSCursor? {
            if controller.isNoteMode { return .addNote }
            if controller.isSnapshotRegionMode { return .snapshotCrosshair }
            return nil
        }

        /// Mode-change hook from updateNSView: assert the mode cursor immediately
        /// when a custom-cursor mode turns on with the pointer already over the
        /// viewer (the monitor above keeps it asserted while the mouse moves),
        /// and restore the arrow when it ends.
        func cursorModeChanged(for mode: InteractionMode) {
            let cursor = cursor(for: mode)
            guard cursor !== activeCursor else { return }
            activeCursor = cursor
            guard let view, let window = view.window else { return }
            let mouse = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            guard view.bounds.contains(mouse) else { return }
            (cursor ?? .arrow).set()
        }

        /// True when `event` belongs to the viewer's window and the pointer sits
        /// within the PDFView's bounds — used to keep the note-placement cursor
        /// asserted across BOTH the PDFView and the SwiftUI note overlay layered
        /// above it (the overlay hit-tests away from the PDFView, so the tighter
        /// `pdfPoint` check would drop the cursor over the very region where
        /// notes are placed).
        private func pointerOverViewer(_ event: NSEvent) -> Bool {
            guard let view, let window = view.window, event.window === window else { return false }
            let point = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
            return view.bounds.contains(point)
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
