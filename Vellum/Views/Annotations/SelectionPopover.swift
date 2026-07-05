import SwiftUI

// Selection popover — port of src/components/annotations/SelectionPopover.tsx.
// 5 color swatches (24px, tooltip "Highlight {Name}"), divider, note button
// toggling a 256px note-input row (Enter/Add submits trimmed non-empty text →
// addNote with the selection's position + selected_text; Escape closes).

struct SelectionPopover: View {
    let selection: PdfTextSelection
    let onClose: () -> Void

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var showNoteInput = false
    @State private var noteText = ""
    @State private var noteButtonHovering = false
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(HIGHLIGHT_COLORS) { color in
                    HighlightSwatchButton(
                        color: color,
                        size: 24,
                        helpText: "Highlight \(color.name)"
                    ) {
                        handleHighlight(color.value)
                    }
                }

                Rectangle()
                    .fill(.quaternary)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 4)

                Button {
                    showNoteInput.toggle()
                } label: {
                    Image(systemName: "plus.bubble")
                        .font(.system(size: 12))
                        .frame(width: 24, height: 24)
                        .foregroundStyle(noteButtonHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .background(noteButtonHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .onHover { noteButtonHovering = $0 }
                .help("Add note")
                .accessibilityLabel("Add note")
                .accessibilityIdentifier("selectionPopover.addNote")
            }
            .padding(6)
            .darkGlassSurface(in: .capsule)

            if showNoteInput {
                HStack(spacing: 6) {
                    TextField("Add a note...", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($noteFieldFocused)
                        .onSubmit { handleAddNote() }
                        .onExitCommand { onClose() }
                        .onAppear { noteFieldFocused = true }

                    Button("Add", action: handleAddNote)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                }
                .padding(8)
                .frame(width: 256)
                .darkGlassSurface(in: .rect(cornerRadius: Radius.lg))
            }
        }
    }

    private func handleHighlight(_ color: String) {
        let input = CreateAnnotationInput(
            type: .highlight,
            pageNumber: selection.pageNumber,
            color: color,
            content: nil,
            positionData: selection.positionData
        )
        onClose()
        Task {
            await annotationStore.addHighlight(input)
        }
    }

    private func handleAddNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let input = CreateAnnotationInput(
            type: .note,
            pageNumber: selection.pageNumber,
            color: nil,
            content: trimmed,
            positionData: selection.positionData
        )
        onClose()
        Task {
            await annotationStore.addNote(input)
        }
    }
}

/// Round highlight-color swatch shared by the selection popover (24px) and the
/// highlight edit popover (20px, ring when current).
struct HighlightSwatchButton: View {
    let color: HighlightColor
    let size: CGFloat
    var isCurrent = false
    let helpText: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: color.value))
                .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                .overlay {
                    if isCurrent {
                        // ring-2 ring-primary ring-offset-1
                        Circle()
                            .stroke(palette.primary, lineWidth: 2)
                            .padding(-2)
                    }
                }
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.1 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
