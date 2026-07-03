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
        // Store → view zoom sync (setZoom fallback path when no anchored
        // handler ran; view → store flows through PDFViewScaleChanged).
        if abs(nsView.scaleFactor - app.zoom) > 0.0001 {
            nsView.scaleFactor = app.zoom
        }
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
                    guard let self, let point = self.pdfPoint(for: event) else { return }
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

            if let monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { [weak self] event in
                let swallow = MainActor.assumeIsolated { () -> Bool in
                    guard let self, self.controller.isNoteMode,
                          self.pdfPoint(for: event) != nil else { return false }
                    NSCursor.crosshair.set()
                    // Swallowed so PDFView's own tracking can't reset the cursor.
                    return true
                }
                return swallow ? nil : event
            }) {
                monitors.append(monitor)
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
