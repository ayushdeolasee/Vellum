import SwiftUI

// Per-page annotation layer — port of src/components/annotations/HighlightLayer.tsx.
// One rect view per PositionData rect; mousedown selects (and suppresses a new
// text selection, since the overlay swallows the event before the PDFView sees
// it); edit popover above the selected highlight's FIRST rect; sticky-note
// overlays for the page's notes.

struct HighlightLayer: View {
    var annotations: [Annotation]
    var zoom: Double

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

    var body: some View {
        if !(highlights.isEmpty && notes.isEmpty) {
            ZStack(alignment: .topLeading) {
                ForEach(highlights) { annotation in
                    let rects = annotation.positionData?.rects ?? []
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

                if let selected = selectedHighlight,
                   let rect0 = selected.positionData?.rects.first {
                    AnchoredAbove(point: CGPoint(
                        x: (rect0.x + rect0.width / 2) * zoom,
                        y: rect0.y * zoom - 8
                    )) {
                        HighlightEditPopover(annotation: selected)
                    }
                    .zIndex(30)
                }

                ForEach(notes) { note in
                    StickyNoteOverlay(annotation: note, zoom: zoom)
                        .zIndex(10)
                }
            }
        }
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
