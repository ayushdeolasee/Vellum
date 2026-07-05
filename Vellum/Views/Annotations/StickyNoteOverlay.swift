import SwiftUI

// Sticky note overlay — port of src/components/annotations/StickyNoteOverlay.tsx.
// Anchored at position_data.rects[0] (a zero-size point). Collapsed amber pill
// / expanded 224px card; expanded when selected or editing. Drag with a 3px
// threshold moves rects[0] (offset divided by zoom). Auto-edits freshly created
// (empty-content) notes. Saves on blur/Escape only when the trimmed content
// changed. Notes with missing/empty rects render nothing.

/// Tailwind amber tokens used by the sticky-note theme (spec-listed one-offs).
private enum Amber {
    static let a50 = Color(hex: "#fffbeb")
    static let a100 = Color(hex: "#fef3c7")
    static let a200 = Color(hex: "#fde68a")
    static let a300 = Color(hex: "#fcd34d")
    static let a400 = Color(hex: "#fbbf24")
    static let a500 = Color(hex: "#f59e0b")
    static let a600 = Color(hex: "#d97706")
    static let a700 = Color(hex: "#b45309")
    static let a800 = Color(hex: "#92400e")
    static let a900 = Color(hex: "#78350f")
    static let a950 = Color(hex: "#451a03")
    static let red600 = Color(hex: "#dc2626")
}

struct StickyNoteOverlay: View {
    let annotation: Annotation
    let zoom: Double

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.colorScheme) private var colorScheme

    @State private var isEditing = false
    @State private var editText: String
    @State private var dragOffset = CGSize.zero
    @State private var isDragging = false
    @State private var wasJustCreated: Bool
    @State private var pillHovering = false
    @FocusState private var textFocused: Bool

    init(annotation: Annotation, zoom: Double) {
        self.annotation = annotation
        self.zoom = zoom
        _editText = State(initialValue: annotation.content ?? "")
        // Auto-edit-on-creation flag: captured at mount, like the ref.
        _wasJustCreated = State(initialValue: (annotation.content ?? "").isEmpty)
    }

    private var dark: Bool { colorScheme == .dark }
    private var isSelected: Bool { annotationStore.selectedAnnotationId == annotation.id }
    private var isExpanded: Bool { isSelected || isEditing }
    /// Non-empty content or nil ("" is treated as empty, matching JS truthiness).
    private var content: String? {
        let value = annotation.content ?? ""
        return value.isEmpty ? nil : value
    }

    var body: some View {
        if let position = annotation.positionData, let anchor = position.rects.first {
            Group {
                if isExpanded {
                    expandedCard(position: position)
                } else {
                    collapsedPill
                }
            }
            .offset(
                x: (anchor.x + dragOffset.width) * zoom,
                y: (anchor.y + dragOffset.height) * zoom
            )
            .onAppear { maybeStartCreationEdit() }
            .onChange(of: isSelected) { maybeStartCreationEdit() }
        }
    }

    // MARK: - Collapsed pill

    private var collapsedPill: some View {
        HStack(spacing: 4) {
            Image(systemName: "note.text")
                .font(.system(size: 12))
                .foregroundStyle(dark ? Amber.a400 : Amber.a600)
            if let content {
                Text(content)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 120, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .foregroundStyle(dark ? Amber.a200 : Amber.a900)
            } else {
                Text("Empty")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(Amber.a500)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(dark ? Amber.a900.opacity(0.8) : Amber.a100)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(dark ? Amber.a600 : Amber.a300, lineWidth: 1)
        )
        .shadow(
            color: .black.opacity(pillHovering ? 0.18 : 0.12),
            radius: pillHovering ? 8 : 4,
            x: 0,
            y: pillHovering ? 4 : 2
        )
        .scaleEffect(pillHovering ? 1.05 : 1)
        .onHover { pillHovering = $0 }
        .help(content ?? "Empty note - click to edit, drag to move")
        .pointerStyle(isDragging ? .grabActive : .grabIdle)
        .gesture(noteDragGesture(onClick: {
            if !isSelected {
                annotationStore.selectAnnotation(annotation.id)
            } else if !isEditing {
                startEditing()
            }
        }))
    }

    // MARK: - Expanded card

    private func expandedCard(position: PositionData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            noteBody
            if let quote = position.selectedText, !quote.isEmpty {
                footer(quote)
            }
        }
        .frame(width: 224, alignment: .topLeading)
        .background(dark ? Amber.a950.opacity(0.9) : Amber.a50)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(dark ? Amber.a600 : Amber.a300, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.2), radius: 12, x: 0, y: 8)
    }

    private var header: some View {
        HStack(spacing: 0) {
            // Drag handle cluster (grip + icon + label).
            HStack(spacing: 4) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 10))
                    .foregroundStyle(dark ? Amber.a600 : Amber.a400)
                Image(systemName: "note.text")
                    .font(.system(size: 10))
                    .foregroundStyle(dark ? Amber.a400 : Amber.a600)
                Text("Note - p.\(annotation.pageNumber)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(dark ? Amber.a300 : Amber.a700)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .pointerStyle(isDragging ? .grabActive : .grabIdle)
            .gesture(noteDragGesture(onClick: nil))

            HStack(spacing: 2) {
                NoteHeaderButton(
                    symbol: "trash",
                    dark: dark,
                    hoverTint: Amber.red600,
                    helpText: "Delete note"
                ) {
                    Task {
                        await annotationStore.deleteAnnotation(id: annotation.id)
                    }
                }
                NoteHeaderButton(
                    symbol: "xmark",
                    dark: dark,
                    hoverTint: dark ? Amber.a200 : Amber.a800,
                    helpText: "Close"
                ) {
                    handleClose()
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(dark ? Amber.a700 : Amber.a200)
                .frame(height: 1)
        }
    }

    private var noteBody: some View {
        Group {
            if isEditing {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $editText)
                        .font(.system(size: 14))
                        .foregroundStyle(dark ? Amber.a100 : Amber.a900)
                        .scrollContentBackground(.hidden)
                        .frame(height: 76)
                        .focused($textFocused)
                        .onKeyPress(.escape) {
                            escapeFromEditor()
                            return .handled
                        }
                        .onExitCommand { escapeFromEditor() }
                    if editText.isEmpty {
                        Text("Type your note...")
                            .font(.system(size: 14))
                            .foregroundStyle(dark ? Amber.a600 : Amber.a400)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .padding(6)
                .background(dark ? Amber.a950 : Amber.a50)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(
                            dark ? Amber.a700 : (textFocused ? Amber.a400 : Amber.a200),
                            lineWidth: 1)
                )
                .onAppear { textFocused = true }
                .onChange(of: textFocused) { _, focused in
                    if !focused {
                        handleSave()
                    }
                }
            } else {
                Group {
                    if let content {
                        Text(content)
                            .font(.system(size: 14))
                            .foregroundStyle(dark ? Amber.a100 : Amber.a900)
                    } else {
                        Text("Click to add note...")
                            .font(.system(size: 14))
                            .italic()
                            .foregroundStyle(Amber.a400)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
                .contentShape(Rectangle())
                .pointerStyle(.horizontalText)
                .onTapGesture { startEditing() }
            }
        }
        .padding(8)
    }

    private func footer(_ quote: String) -> some View {
        Text("\u{201C}\(quote)\u{201D}")
            .font(.system(size: 12))
            .italic()
            .foregroundStyle(dark ? Amber.a500 : Amber.a600)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(dark ? Amber.a700 : Amber.a200)
                    .frame(height: 1)
            }
    }

    // MARK: - Editing / saving

    private func startEditing() {
        editText = annotation.content ?? ""
        isEditing = true
    }

    private func maybeStartCreationEdit() {
        guard wasJustCreated, isSelected else { return }
        wasJustCreated = false
        // One frame later, like the original's requestAnimationFrame.
        DispatchQueue.main.async {
            startEditing()
        }
    }

    private func persistEditIfChanged() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != (annotation.content ?? "") else { return }
        Task {
            await annotationStore.updateAnnotation(UpdateAnnotationInput(
                id: annotation.id,
                color: nil,
                content: trimmed,
                positionData: nil
            ))
        }
    }

    private func handleSave() {
        persistEditIfChanged()
        isEditing = false
    }

    private func escapeFromEditor() {
        handleSave()
        annotationStore.selectAnnotation(nil)
    }

    private func handleClose() {
        persistEditIfChanged()
        isEditing = false
        annotationStore.selectAnnotation(nil)
    }

    // MARK: - Dragging (3px threshold; offset divided by zoom; moves rects[0])

    private func noteDragGesture(onClick: (() -> Void)?) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !isDragging {
                    guard abs(value.translation.width) >= 3
                        || abs(value.translation.height) >= 3 else { return }
                    isDragging = true
                }
                dragOffset = CGSize(
                    width: value.translation.width / zoom,
                    height: value.translation.height / zoom
                )
            }
            .onEnded { _ in
                guard isDragging else {
                    onClick?()
                    return
                }
                isDragging = false
                let offset = dragOffset
                dragOffset = .zero
                guard offset != .zero,
                      var position = annotation.positionData,
                      !position.rects.isEmpty else { return }
                position.rects[0].x += offset.width
                position.rects[0].y += offset.height
                Task {
                    await annotationStore.updateAnnotation(UpdateAnnotationInput(
                        id: annotation.id,
                        color: nil,
                        content: nil,
                        positionData: position
                    ))
                }
            }
    }
}

/// Small amber header icon button (delete / close).
private struct NoteHeaderButton: View {
    let symbol: String
    let dark: Bool
    let hoverTint: Color
    let helpText: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(hovering ? hoverTint : Amber.a500)
                .padding(2)
                .background(hovering ? (dark ? Amber.a800 : Amber.a200) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
    }
}
