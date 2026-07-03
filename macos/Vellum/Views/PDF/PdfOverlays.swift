import SwiftUI

// Overlay positioning glue over PDFView page coordinates: places per-page
// HighlightLayer/StickyNoteOverlay stacks, the selection popover, and the
// right-click context menu in viewer (top-left origin) coordinates. Frames are
// recomputed whenever the controller bumps geometryVersion (scroll/zoom/layout).

struct PdfOverlayStack: View {
    let controller: PdfViewerController

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    var body: some View {
        // Recompute page frames on every geometry change.
        let _ = controller.geometryVersion
        ZStack(alignment: .topLeading) {
            ForEach(overlayPages, id: \.self) { pageNumber in
                let pageAnnotations = annotationStore.annotationsForPage(pageNumber)
                if !pageAnnotations.isEmpty,
                   let frame = controller.pageViewFrame(pageNumber: pageNumber) {
                    HighlightLayer(annotations: pageAnnotations, zoom: app.zoom)
                        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                        .offset(x: frame.minX, y: frame.minY)
                }
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
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onAddNote) {
                HStack(spacing: 8) {
                    Image(systemName: "note.text")
                        .font(.system(size: 12))
                        .foregroundStyle(Color(hex: "#f59e0b"))
                    Text("Add note here")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.foreground)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(hovering ? palette.accent : .clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.vertical, 4)
        .frame(minWidth: 160, alignment: .leading)
        .background(palette.background)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(palette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.1), radius: 15, x: 0, y: 10)
    }
}
