import SwiftUI

// Overlay positioning glue over PDFView page coordinates: places per-page
// HighlightLayer/StickyNoteOverlay stacks, the selection popover, and the
// right-click context menu in viewer (top-left origin) coordinates. Frames are
// recomputed whenever the controller bumps geometryVersion (scroll/zoom/layout).

struct PdfOverlayStack: View {
    let controller: PdfViewerController

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(ScratchpadStore.self) private var scratchpadStore
    @Environment(\.palette) private var palette

    /// One per-page overlay layer with its frame resolved. Frames are computed
    /// in `body` (re-run on every geometryVersion bump) and passed into the
    /// ForEach as row DATA: a row whose closure merely calls
    /// controller.pageViewFrame never re-evaluates — its inputs (page number,
    /// annotations, controller reference) are unchanged and the frame is not
    /// observable — so highlights freeze at their creation-time position while
    /// the document scrolls and zooms underneath them.
    private struct PageOverlay: Equatable {
        var pageNumber: Int
        var frame: CGRect
        var annotations: [Annotation]
    }

    var body: some View {
        // Recompute page frames on every geometry change.
        let _ = controller.geometryVersion
        // Scale overlay rects by the LIVE PDFView scale, not app.zoom. During a
        // trackpad pinch PDFKit does not post PDFViewScaleChanged until the
        // gesture ends, so app.zoom lags the real scaleFactor mid-pinch — while
        // the page frames (pageViewFrame → convert) use the live scale. Mixing
        // the two made highlights drift as you zoomed and snap back on release.
        // geometryVersion bumps throughout the pinch (scroll/frame changes), so
        // reading scaleFactor here stays in lockstep with the page frames.
        let scale = controller.pdfView.map { Double($0.scaleFactor) } ?? app.zoom
        ZStack(alignment: .topLeading) {
            // Note-mode crosshair + click-to-place. A hit-testable clear layer
            // is the only way pointerStyle reliably beats PDFView's internal
            // cursor updates; it also owns the placement click (the PdfKitView
            // monitor ignores events that hit-test into SwiftUI overlays, so
            // exactly one placement fires). Sits below annotation overlays so
            // sticky pills keep their own cursor and drag behavior.
            if app.mode == .note {
                Color.clear
                    .contentShape(Rectangle())
                    .pointerStyle(.rectSelection) // crosshair-style pointer
                    .onTapGesture(coordinateSpace: .local) { location in
                        controller.handleNoteOverlayClick(atTopLeft: location)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Drag-to-crop region snapshot → scratchpad. Sits above the page
            // layers so its marquee owns the drag; a full-viewer hit-testable
            // scrim means PdfKitView's mouse monitors ignore these events (they
            // hit-test into this SwiftUI overlay, not the PDFView).
            if app.mode == .snapshotRegion {
                RegionCaptureOverlay { rect in
                    if let capture = controller.capturePageRegionData(viewerRect: rect) {
                        let label = capture.pageNumber.map { "Region · p.\($0)" } ?? "Region"
                        scratchpadStore.addImage(capture, label: label)
                    } else {
                        // Drag missed a page or was too small to crop — tell the
                        // user rather than silently reverting to view mode.
                        scratchpadStore.warnRegionCaptureFailed()
                    }
                    app.setMode(.view)
                } onCancel: {
                    // Plain click or tiny wobble: back out of capture mode
                    // without a warning — the user changed their mind.
                    app.setMode(.view)
                }
                .zIndex(60)
            }

            ForEach(pageOverlays, id: \.pageNumber) { overlay in
                HighlightLayer(annotations: overlay.annotations, zoom: scale)
                    .frame(
                        width: overlay.frame.width, height: overlay.frame.height,
                        alignment: .topLeading)
                    .offset(x: overlay.frame.minX, y: overlay.frame.minY)
            }

            if let selection = controller.selection,
               let position = controller.selectionPopoverPosition {
                AnchoredAbove(point: position) {
                    SelectionPopover(selection: selection) {
                        controller.clearSelection()
                    }
                }
                .zIndex(50)
            }

            if let menu = controller.contextMenu {
                PdfContextMenuView {
                    controller.addNoteFromContextMenu()
                }
                .offset(x: menu.location.x, y: menu.location.y)
                .zIndex(50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    private var pageOverlays: [PageOverlay] {
        overlayPages.compactMap { pageNumber in
            let annotations = annotationStore.annotationsForPage(pageNumber)
            guard !annotations.isEmpty,
                  let frame = controller.pageViewFrame(pageNumber: pageNumber)
            else { return nil }
            return PageOverlay(pageNumber: pageNumber, frame: frame, annotations: annotations)
        }
    }

    /// Pages that carry overlays: the visible range padded by the original's
    /// PAGE_BUFFER = 2 render buffer (center falls back to currentPage).
    private var overlayPages: [Int] {
        let numPages = app.numPages
        guard numPages >= 1 else { return [] }
        let center = app.visiblePages.isEmpty ? [app.currentPage] : app.visiblePages
        let low = max(1, (center.first ?? 1) - 2)
        let high = min(numPages, (center.last ?? 1) + 2)
        guard low <= high else { return [] }
        return Array(low...high)
    }
}

/// Drag-to-crop overlay for `.snapshotRegion` mode: draws a dashed marquee and
/// reports the final rectangle (viewer top-left coordinates) on release. A
/// plain click or a sub-threshold wobble calls `onCancel` instead, so the
/// capture mode never gets stuck behind the scrim.
struct RegionCaptureOverlay: View {
    let onCapture: (CGRect) -> Void
    let onCancel: () -> Void

    /// Drags smaller than this in either dimension are treated as an
    /// accidental click and cancel the capture instead of cropping.
    private static let minimumCaptureSize: CGFloat = 4

    @Environment(\.palette) private var palette
    @State private var start: CGPoint?
    @State private var current: CGPoint?

    private var rect: CGRect? {
        guard let start, let current else { return nil }
        return CGRect(
            x: min(start.x, current.x), y: min(start.y, current.y),
            width: abs(current.x - start.x), height: abs(current.y - start.y))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.08)
                .contentShape(Rectangle())
            if let rect {
                Rectangle()
                    .fill(palette.primary.opacity(0.12))
                    .overlay {
                        Rectangle().strokeBorder(
                            palette.primary,
                            style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .pointerStyle(.rectSelection)
        .gesture(
            // minimumDistance of 0 so even a plain click ends the gesture and
            // reaches the cancel path below — with a positive threshold a bare
            // click never fires onEnded and the overlay stays up forever.
            DragGesture(minimumDistance: 0, coordinateSpace: .local)
                .onChanged { value in
                    if start == nil { start = value.startLocation }
                    current = value.location
                }
                .onEnded { value in
                    let final = rect
                    start = nil
                    current = nil
                    if let final,
                       final.width >= Self.minimumCaptureSize,
                       final.height >= Self.minimumCaptureSize {
                        onCapture(final)
                    } else {
                        onCancel()
                    }
                }
        )
    }
}

/// Positions content so its bottom-center sits at `point` — the CSS
/// `translate(-50%, -100%)` used by both popovers.
struct AnchoredAbove<Content: View>: View {
    var point: CGPoint
    @ViewBuilder var content: () -> Content

    @State private var size: CGSize = .zero

    var body: some View {
        content()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
            .offset(x: point.x - size.width / 2, y: point.y - size.height)
    }
}

/// Right-click context menu: single "Add note here" row.
struct PdfContextMenuView: View {
    var onAddNote: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        // A single-action pill that hugs its label — not a full-width menu row.
        Button(action: onAddNote) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Color(hex: "#f59e0b"))
                Text("Add note here")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.foreground)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        // Hover darkens the whole pill edge to edge, behind the label.
        .background {
            if hovering {
                RoundedRectangle(cornerRadius: Radius.lg).fill(.black.opacity(0.25))
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.lg))
        .onHover { hovering = $0 }
        .fixedSize()
    }
}
