import SwiftUI

// Per-page annotation layer — port of src/components/annotations/HighlightLayer.tsx.
// One rect view per PositionData rect; mousedown selects (and suppresses a new
// text selection, since the overlay swallows the event before the PDFView sees
// it); edit popover above the selected highlight's FIRST rect; sticky-note
// overlays for the page's notes.

/// Which end of a highlight a drag handle controls.
enum HighlightEdge { case start, end }

struct HighlightLayer: View {
    var annotations: [Annotation]
    var zoom: Double
    /// Nil in the web viewer (no PDF page geometry to resize against); when
    /// present, selected highlights grow draggable blue end bars.
    var controller: PdfViewerController? = nil

    @Environment(AnnotationStore.self) private var annotationStore

    private var highlights: [Annotation] {
        annotations.filter { $0.type == .highlight && $0.positionData != nil }
    }

    private var notes: [Annotation] {
        annotations.filter { $0.type == .note && $0.positionData != nil }
    }

    private var selectedHighlight: Annotation? {
        guard let id = annotationStore.selectedAnnotationId else { return nil }
        return highlights.first { $0.id == id }
    }

    /// The rects to draw for an annotation — the live resize preview overrides
    /// the stored ones while its handle is being dragged.
    private func effectiveRects(for annotation: Annotation) -> [AnnotationRect] {
        if let resize = controller?.highlightResize, resize.id == annotation.id {
            return resize.positionData.rects
        }
        return annotation.positionData?.rects ?? []
    }

    var body: some View {
        if !(highlights.isEmpty && notes.isEmpty) {
            ZStack(alignment: .topLeading) {
                ForEach(highlights) { annotation in
                    let rects = effectiveRects(for: annotation)
                    ForEach(Array(rects.enumerated()), id: \.offset) { _, rect in
                        HighlightRectView(
                            annotation: annotation,
                            rect: rect,
                            zoom: zoom,
                            isSelected: annotationStore.selectedAnnotationId == annotation.id
                        )
                        .zIndex(20)
                    }
                }

                if let selected = selectedHighlight {
                    let rects = effectiveRects(for: selected)
                    if let rect0 = rects.first {
                        AnchoredAbove(point: CGPoint(
                            x: (rect0.x + rect0.width / 2) * zoom,
                            y: rect0.y * zoom - 8
                        )) {
                            HighlightEditPopover(annotation: selected)
                        }
                        .zIndex(30)
                    }
                    // Draggable blue end bars — only in the PDF viewer, where we
                    // can map a drag point back to text.
                    if let controller, let first = rects.first, let last = rects.last {
                        HighlightResizeHandle(
                            annotation: selected, edge: .start, rect: first,
                            zoom: zoom, controller: controller)
                            .zIndex(40)
                        HighlightResizeHandle(
                            annotation: selected, edge: .end, rect: last,
                            zoom: zoom, controller: controller)
                            .zIndex(40)
                    }
                }

                ForEach(notes) { note in
                    StickyNoteOverlay(annotation: note, zoom: zoom)
                        .zIndex(10)
                }
            }
            .coordinateSpace(.named(Self.coordinateSpaceName))
        }
    }

    static let coordinateSpaceName = "highlightLayer"
}

/// A vertical blue bar with a round knob at the selected highlight's start or
/// end. Dragging it re-runs text selection between the moved edge and the
/// pinned opposite edge, previewing live and committing on release.
private struct HighlightResizeHandle: View {
    let annotation: Annotation
    let edge: HighlightEdge
    /// The end rect this handle sits on (first rect for .start, last for .end),
    /// at zoom 1 in page-top-left coordinates.
    let rect: AnnotationRect
    let zoom: Double
    let controller: PdfViewerController

    /// Bar geometry in screen points (kept constant across zoom so the handle
    /// stays grabbable). Position/height still scale with zoom.
    private let barWidth: CGFloat = 3
    private let knobSize: CGFloat = 11
    private let hitPadding: CGFloat = 12

    private var barHeight: CGFloat { rect.height * zoom }

    /// The bar's center x in layer coordinates: left edge for start, right for end.
    private var barCenterX: CGFloat {
        switch edge {
        case .start: return rect.x * zoom
        case .end: return (rect.x + rect.width) * zoom
        }
    }

    private var barTopY: CGFloat { rect.y * zoom }

    var body: some View {
        let color = Color(hex: "#2563eb") // blue-600
        ZStack {
            Capsule()
                .fill(color)
                .frame(width: barWidth, height: max(barHeight, knobSize))
            // Knob sits at the outer end: top for the start bar, bottom for the end.
            Circle()
                .fill(color)
                .overlay(Circle().strokeBorder(.white, lineWidth: 1.5))
                .frame(width: knobSize, height: knobSize)
                .offset(y: edge == .start ? -barHeight / 2 : barHeight / 2)
        }
        .frame(width: knobSize + hitPadding, height: max(barHeight, knobSize) + knobSize + hitPadding)
        .contentShape(Rectangle())
        .pointerStyle(.grabActive)
        .position(x: barCenterX, y: barTopY + barHeight / 2)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(HighlightLayer.coordinateSpaceName))
                .onChanged { value in
                    controller.previewHighlightResize(
                        annotation: annotation, edge: edge,
                        toDisplayPoint: CGPoint(
                            x: value.location.x / zoom, y: value.location.y / zoom))
                }
                .onEnded { value in
                    controller.commitHighlightResize(
                        annotation: annotation, edge: edge,
                        toDisplayPoint: CGPoint(
                            x: value.location.x / zoom, y: value.location.y / zoom))
                }
        )
    }
}

/// A single highlight rectangle: color = annotation.color ?? #fef08a, opacity
/// 0.40 (hover/selected 0.60), 2pt rounded corners, primary ring when selected.
private struct HighlightRectView: View {
    let annotation: Annotation
    let rect: AnnotationRect
    let zoom: Double
    let isSelected: Bool

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var pressing = false

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Color(hex: annotation.color ?? "#fef08a"))
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2)
                        .strokeBorder(palette.primary, lineWidth: 2)
                }
            }
            .opacity(isSelected || hovering ? 0.6 : 0.4)
            .frame(width: rect.width * zoom, height: rect.height * zoom)
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .help(annotation.content ?? annotation.positionData?.selectedText ?? "")
            .gesture(
                // Select on mouse DOWN, like the original's onMouseDown with
                // preventDefault + stopPropagation.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !pressing {
                            pressing = true
                            annotationStore.selectAnnotation(annotation.id)
                        }
                    }
                    .onEnded { _ in pressing = false }
            )
            .offset(x: rect.x * zoom, y: rect.y * zoom)
    }
}

/// Edit popover above the selected highlight's first rect: 5 swatches (20px,
/// current marked with a primary ring) and an "Unhighlight" row. Shared with
/// the web viewer, which anchors it at the clicked highlight rect.
struct HighlightEditPopover: View {
    let annotation: Annotation
    /// Runs after Unhighlight (the web viewer closes its popover state here).
    var onDelete: (() -> Void)? = nil

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(HIGHLIGHT_COLORS) { color in
                    HighlightSwatchButton(
                        color: color,
                        size: 20,
                        isCurrent: annotation.color == color.value,
                        helpText: "Set highlight color: \(color.name)"
                    ) {
                        Task {
                            await annotationStore.updateAnnotation(UpdateAnnotationInput(
                                id: annotation.id,
                                color: color.value,
                                content: nil,
                                positionData: nil
                            ))
                        }
                    }
                }
            }
            UnhighlightButton {
                Task {
                    await annotationStore.deleteAnnotation(id: annotation.id)
                }
                onDelete?()
            }
        }
        // Hug horizontally BEFORE padding/glass: the swatch row's intrinsic
        // width sets the popover width and the Unhighlight row's maxWidth:.infinity
        // fills to match it. Without this the overlay's page-wide ZStack proposes
        // its full width to the maxWidth:.infinity row and the glass panel
        // stretches across the page.
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.md))
    }
}

private struct UnhighlightButton: View {
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                Text("Unhighlight")
                    .font(.system(size: 12))
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(hovering ? palette.accent : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(palette.foreground)
        .onHover { hovering = $0 }
        .help("Remove highlight")
    }
}
