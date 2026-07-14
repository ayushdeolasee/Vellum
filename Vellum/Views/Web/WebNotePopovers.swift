import SwiftUI

// Note popovers for webpage tabs — port of src/components/web/WebNotePopovers.tsx
// plus the web-side use of the shared SelectionPopover. These are app-shell
// overlays anchored at page coordinates mapped by WebViewerView (the page
// itself lives inside the WKWebView).

/// Tailwind amber tokens used by the sticky-note theme (one-off, not themed).
enum WebAmber {
    static let amber300 = Color(hex: "#fcd34d")
    static let amber500 = Color(hex: "#f59e0b")
}

// MARK: - Anchored positioning (useAnchoredPosition)

enum WebPopoverPlacement {
    case above
    case below
    case menu
}

/// Position a popover near an anchor point, measured after layout so the
/// whole box is clamped inside the container with 8 px margins. "above"/
/// "below" center horizontally and flip vertically when there's no room;
/// "menu" hangs from the point like a native context menu.
struct AnchoredPopover<Content: View>: View {
    var x: CGFloat
    var y: CGFloat
    var placement: WebPopoverPlacement
    var containerSize: CGSize
    @ViewBuilder var content: () -> Content

    @State private var size: CGSize = .zero

    var body: some View {
        content()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { newSize in
                size = newSize
            }
            .offset(x: origin.x, y: origin.y)
            // Render invisibly at the anchor for the measuring frame.
            .opacity(size == .zero ? 0 : 1)
    }

    private var origin: CGPoint {
        guard size != .zero else { return CGPoint(x: x, y: y) }
        let margin: CGFloat = 8
        var left: CGFloat
        var top: CGFloat
        switch placement {
        case .menu:
            left = x
            top = y
        case .above:
            left = x - size.width / 2
            top = y - size.height - 10
            if top < margin { top = y + 10 }
        case .below:
            left = x - size.width / 2
            top = y + 10
            if top + size.height > containerSize.height - margin {
                top = y - size.height - 10
            }
        }
        left = min(max(left, margin), max(margin, containerSize.width - size.width - margin))
        top = min(max(top, margin), max(margin, containerSize.height - size.height - margin))
        return CGPoint(x: left, y: top)
    }
}

// MARK: - Shared popover chrome

private struct PopoverCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        content()
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.lg))
    }
}

/// The shared note textarea (h-20, bg-muted, Enter submits, Escape closes).
private struct NoteTextEditor: View {
    @Binding var text: String
    var onSubmit: () -> Void
    var onClose: () -> Void

    @Environment(\.palette) private var palette
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(palette.foreground)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .focused($focused)
                .onKeyPress { press in
                    if press.key == .return && !press.modifiers.contains(.shift) {
                        onSubmit()
                        return .handled
                    }
                    if press.key == .escape {
                        onClose()
                        return .handled
                    }
                    return .ignored
                }
            if text.isEmpty {
                Text("Write a note…")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.mutedForeground)
                    .padding(.horizontal, 8)
                    .padding(.top, 6)
                    .allowsHitTesting(false)
            }
        }
        .frame(height: 80)
        .background(palette.muted)
        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.sm)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .onAppear { focused = true }
    }
}

private struct SmallGhostButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
                .background(hovering ? palette.accent : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct SmallPrimaryButton: View {
    let title: String
    var disabled = false
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .foregroundStyle(palette.primaryForeground)
                .background(hovering ? palette.primaryHover : palette.primary)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
    }
}

// MARK: - WebNoteComposer

struct WebNoteComposerView: View {
    var onSubmit: (String) -> Void
    var onClose: () -> Void

    @State private var text = ""
    @Environment(\.palette) private var palette

    var body: some View {
        PopoverCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 13))
                        .foregroundStyle(WebAmber.amber500)
                    Text("New note")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(palette.mutedForeground)
                }
                NoteTextEditor(text: $text, onSubmit: submit, onClose: onClose)
                HStack(spacing: 6) {
                    Spacer()
                    SmallGhostButton(title: "Cancel", action: onClose)
                    SmallPrimaryButton(
                        title: "Add note",
                        disabled: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        action: submit)
                }
            }
            .padding(8)
            .frame(width: 288)
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
    }
}

// MARK: - WebContextMenu

struct WebContextMenuView: View {
    var canAddNote: Bool
    var onAddNote: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        // A single-action pill that hugs its label — not a full-width menu row.
        Button(action: onAddNote) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(WebAmber.amber500)
                Text("Add note here")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.foreground)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(!canAddNote)
        .opacity(canAddNote ? 1 : 0.5)
        // Hover tints the whole pill a shade darker, edge to edge, rather
        // than a smaller inset rectangle behind just the text.
        // Hover darkens the whole pill edge to edge, behind the label so the
        // text stays crisp (accent is too close to the glass tint to register).
        .background {
            if hovering && canAddNote {
                RoundedRectangle(cornerRadius: Radius.lg).fill(.black.opacity(0.25))
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.lg))
        .onHover { hovering = $0 }
        .help(canAddNote ? "" : "No text near this spot to attach a note to")
        // The overlay proposes the full container width; hug the label instead.
        .fixedSize()
    }
}

// MARK: - WebNoteViewer

struct WebNoteViewerView: View {
    let annotationId: String
    var onClose: () -> Void

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var isEditing = false
    @State private var text = ""
    @State private var initialized = false

    private var annotation: Annotation? {
        annotationStore.annotations.first { $0.id == annotationId }
    }

    var body: some View {
        if let annotation {
            PopoverCard {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        HStack(spacing: 6) {
                            Image(systemName: "note.text")
                                .font(.system(size: 13))
                                .foregroundStyle(WebAmber.amber500)
                            Text("Note")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(palette.mutedForeground)
                        }
                        Spacer()
                        DeleteNoteButton {
                            Task { await annotationStore.deleteAnnotation(id: annotation.id) }
                            onClose()
                        }
                    }

                    if isEditing {
                        NoteTextEditor(
                            text: $text,
                            onSubmit: { save(annotation) },
                            onClose: onClose)
                        HStack(spacing: 6) {
                            Spacer()
                            SmallGhostButton(title: "Cancel", action: onClose)
                            SmallPrimaryButton(title: "Save") { save(annotation) }
                        }
                    } else {
                        ScrollView {
                            MarkdownMessage(content: annotation.content ?? "", textColor: palette.foreground, baseSize: 13)
                                .foregroundStyle(palette.foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 2)
                        }
                        .frame(maxHeight: 160)
                        .fixedSize(horizontal: false, vertical: true)

                        if let quote = annotation.positionData?.selectedText, !quote.isEmpty {
                            Text(quote)
                                .font(.system(size: 12))
                                .italic()
                                .foregroundStyle(palette.mutedForeground)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(.leading, 8)
                                .overlay(alignment: .leading) {
                                    Rectangle()
                                        .fill(WebAmber.amber300)
                                        .frame(width: 2)
                                }
                        }
                        HStack {
                            Spacer()
                            SmallGhostButton(title: "Edit") {
                                text = annotation.content ?? ""
                                isEditing = true
                            }
                        }
                    }
                }
                .padding(8)
                .frame(width: 288)
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                // Open straight into editing when the note has no content yet.
                let content = annotation.content ?? ""
                text = content
                isEditing = content.isEmpty
            }
        }
    }

    private func save(_ annotation: Annotation) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (annotation.content ?? "") {
            Task {
                await annotationStore.updateAnnotation(
                    UpdateAnnotationInput(id: annotation.id, color: nil, content: trimmed, positionData: nil))
            }
        }
        isEditing = false
    }
}

private struct DeleteNoteButton: View {
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "trash")
                .font(.system(size: 13))
                .foregroundStyle(hovering ? palette.destructive : palette.mutedForeground)
                .frame(width: 24, height: 24)
                .background(hovering ? palette.accent : .clear)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                .contentShape(RoundedRectangle(cornerRadius: Radius.sm))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Delete note")
    }
}

// MARK: - Selection popover (shared SelectionPopover, web instance)

/// The highlight/note popover shown above a text selection. Hangs above and
/// centered on the anchor point (translate(-50%, -100%)).
struct WebSelectionPopover: View {
    var position: CGPoint
    var onHighlight: (String) -> Void
    var onNote: (String) -> Void
    /// Fired as the note field opens, so the controller can pin the selection
    /// before the field steals first responder from the web view.
    var onBeginNote: () -> Void
    var onAskAi: () -> Void
    var onClose: () -> Void

    @Environment(\.palette) private var palette
    @State private var showNoteInput = false
    @State private var noteText = ""
    @State private var size: CGSize = .zero
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ForEach(HIGHLIGHT_COLORS) { color in
                    SwatchButton(color: color) {
                        // The action must run before onClose: onClose clears
                        // controller.selection, which addHighlight reads.
                        onHighlight(color.value)
                        onClose()
                    }
                }
                Rectangle()
                    .fill(palette.border)
                    .frame(width: 1, height: 20)
                    .padding(.horizontal, 4)
                NoteToggleButton {
                    showNoteInput.toggle()
                    // Must run here, not from the field's onAppear: the pin has
                    // to be taken while the page still holds the selection.
                    if showNoteInput { onBeginNote() }
                }
                .accessibilityIdentifier("webSelectionPopover.addNote")
                AskAiButton {
                    // Same ordering trap as the swatches: onClose drops both the
                    // live selection and the pinned draft, and the reference is
                    // built from one of them.
                    onAskAi()
                    onClose()
                }
                .accessibilityIdentifier("webSelectionPopover.askAi")
            }
            .padding(6)
            .darkGlassSurface(in: .capsule)

            if showNoteInput {
                HStack(spacing: 6) {
                    TextField("Add a note...", text: $noteText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.muted)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(palette.border, lineWidth: 1)
                        }
                        .focused($noteFieldFocused)
                        .onSubmit(submitNote)
                        .onExitCommand { onClose() }
                        .onAppear { noteFieldFocused = true }
                    SmallPrimaryButton(title: "Add", action: submitNote)
                }
                .padding(8)
                .frame(width: 256)
                .darkGlassSurface(in: .rect(cornerRadius: Radius.lg))
            }
        }
        .onGeometryChange(for: CGSize.self) { proxy in
            proxy.size
        } action: { newSize in
            size = newSize
        }
        // translate(-50%, -100%): hangs above and centered on the anchor.
        .offset(x: position.x - size.width / 2, y: position.y - size.height)
        .opacity(size == .zero ? 0 : 1)
    }

    private func submitNote() {
        let trimmed = noteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // The action must run before onClose: onClose drops both the live
        // selection and the pinned draft, and addSelectionNote needs one of
        // them for the note's anchor.
        onNote(trimmed)
        onClose()
    }
}

private struct SwatchButton: View {
    let color: HighlightColor
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: color.value))
                .frame(width: 24, height: 24)
                .overlay {
                    Circle().strokeBorder(palette.border, lineWidth: 1)
                }
                .scaleEffect(hovering ? 1.10 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Highlight \(color.name)")
    }
}

private struct NoteToggleButton: View {
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus.message")
                .font(.system(size: 14))
                .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
                .frame(width: 24, height: 24)
                .background(hovering ? palette.accent : .clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add note")
    }
}

/// Attaches the selection to the AI composer as a reference chip (the web twin
/// of SelectionPopover's sparkles button).
private struct AskAiButton: View {
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
                .frame(width: 24, height: 24)
                .background(hovering ? palette.accent : .clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ask AI about this")
    }
}
