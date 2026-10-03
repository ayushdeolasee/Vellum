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

/// Small unsaved text outlives a reclaimed WKWebView. The tab runtime keeps
/// this reference and passes it to each replacement web controller.
@MainActor
final class WebNoteDraftState {
    var selectionTexts: [String: [String: String]] = [:]
    var noteEdits: [String: [String: String]] = [:]
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
            .background(palette.surface, in: .rect(cornerRadius: Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(palette.border, lineWidth: 1)
            }
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
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                #endif
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
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                #endif
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
    var initialContent: String = ""
    var availableWidth: CGFloat? = nil
    var onSubmit: (String) -> Void
    var onClose: () -> Void
    /// Reports edits upward so an unasked-for dismissal (stray tap, scroll)
    /// can hand the draft back to the note queue instead of dropping it — see
    /// `WebViewerController_iOS.returnNoteComposerDraft` and issue #92.
    var onDraftChange: (String) -> Void = { _ in }

    @State private var text: String
    @Environment(\.palette) private var palette

    init(
        initialContent: String = "",
        availableWidth: CGFloat? = nil,
        onSubmit: @escaping (String) -> Void,
        onClose: @escaping () -> Void,
        onDraftChange: @escaping (String) -> Void = { _ in }
    ) {
        self.initialContent = initialContent
        self.availableWidth = availableWidth
        self.onSubmit = onSubmit
        self.onClose = onClose
        self.onDraftChange = onDraftChange
        _text = State(initialValue: initialContent)
    }

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
                // Written through on set rather than observed with
                // `.onChange`: that fires during a later update pass, so a
                // dismissal landing in the same pass could hand back a mirror
                // one keystroke stale. The write costs nothing — it lands on an
                // observation-ignored field and invalidates no view.
                NoteTextEditor(
                    text: Binding(get: { text }, set: { text = $0; onDraftChange($0) }),
                    onSubmit: submit,
                    onClose: onClose)
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
            .frame(width: min(288, availableWidth ?? 288))
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
    var availableWidth: CGFloat? = nil
    var initialDraft: String? = nil
    var onDraftChange: (String) -> Void = { _ in }
    var onDiscardDraft: () -> Void = {}
    var onSaveDraft: (String) -> Void = { _ in }
    var onClose: () -> Void

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var isEditing = false
    @State private var text = ""
    @State private var initialized = false
    @State private var saving = false

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
                            onDiscardDraft()
                            Task { await annotationStore.deleteAnnotation(id: annotation.id) }
                            onClose()
                        }
                    }

                    if isEditing {
                        NoteTextEditor(
                            text: Binding(get: { text }, set: { text = $0; onDraftChange($0) }),
                            onSubmit: { save(annotation) },
                            onClose: cancel)
                        HStack(spacing: 6) {
                            Spacer()
                            SmallGhostButton(title: "Cancel", action: cancel)
                            SmallPrimaryButton(title: "Save", disabled: saving) { save(annotation) }
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
                .frame(width: min(288, availableWidth ?? 288))
            }
            .onAppear {
                guard !initialized else { return }
                initialized = true
                // Open straight into editing when the note has no content yet.
                let content = annotation.content ?? ""
                text = initialDraft ?? content
                isEditing = initialDraft != nil || content.isEmpty
            }
        }
    }

    private func save(_ annotation: Annotation) {
        guard !saving else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (annotation.content ?? "") {
            saving = true
            annotationStore.saveNote(
                UpdateAnnotationInput(id: annotation.id, color: nil, content: trimmed, positionData: nil)
            ) { saved in
                saving = false
                // Keep the draft on failure or if typing continued during I/O.
                guard saved,
                      text.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed else { return }
                onSaveDraft(trimmed)
                isEditing = false
            }
        } else {
            onSaveDraft(trimmed)
            isEditing = false
        }
    }

    private func cancel() {
        onDiscardDraft()
        onClose()
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
                // Expand the tap target toward the touch-friendly 44pt
                // minimum without growing the visible 24pt glyph box — the
                // header row has room to spare (a Spacer sits to its left).
                .contentShape(Rectangle().inset(by: -10))
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
    var initialDraft: String? = nil
    var availableWidth: CGFloat? = nil
    var onDraftChange: (String) -> Void = { _ in }
    var onHighlight: (String) -> Void
    var onNote: (String) -> Void
    /// Fired as the note field opens, so the controller can pin the selection
    /// before the field steals first responder from the web view.
    var onBeginNote: () -> Void
    #if os(macOS)
    var onDictionaryLookup: () -> Void
    #endif
    var onAskAi: () -> Void
    var onClose: () -> Void

    @Environment(\.palette) private var palette
    @State private var showNoteInput = false
    @State private var noteText = ""
    @FocusState private var noteFieldFocused: Bool

    var body: some View {
        VStack(spacing: 4) {
            #if os(iOS)
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(44), spacing: 0), count: 5),
                alignment: .leading,
                spacing: 0
            ) {
                controlItems
            }
            .frame(width: 220)
            .padding(4)
            .darkGlassSurface(in: .rect(cornerRadius: Radius.lg))
            #else
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { controlItems }
                    .padding(6)
                    .fixedSize()
                    .darkGlassSurface(in: .capsule)
                VStack(spacing: 4) {
                    HStack(spacing: 4) { colorItems }
                    HStack(spacing: 4) { actionItems }
                }
                .padding(6)
                .fixedSize()
                .darkGlassSurface(in: .rect(cornerRadius: Radius.lg))
            }
            .frame(width: min(256, availableWidth ?? 256))
            #endif

            if showNoteInput {
                HStack(spacing: 6) {
                    TextField("Add a note...", text: Binding(
                        get: { noteText }, set: { noteText = $0; onDraftChange($0) }
                    ))
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
                        #if os(macOS)
                        .onExitCommand { onClose() }
                        #endif
                        .onAppear { noteFieldFocused = true }
                    SmallPrimaryButton(title: "Add", action: submitNote)
                }
                .padding(8)
                .frame(width: min(256, availableWidth ?? 256))
                .darkGlassSurface(in: .rect(cornerRadius: Radius.lg))
            }
        }
        .onAppear {
            if let initialDraft {
                noteText = initialDraft
                showNoteInput = true
                onBeginNote()
            }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        colorItems
        #if os(macOS)
        Rectangle()
            .fill(palette.border)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
        #endif
        actionItems
    }

    private var colorItems: some View {
        ForEach(HIGHLIGHT_COLORS) { color in
            SwatchButton(color: color) {
                // Preserve the anchor until the action consumes it.
                onHighlight(color.value)
                onClose()
            }
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        NoteToggleButton {
            if showNoteInput {
                onClose()
                return
            }
            showNoteInput = true
            // Pin while the page still holds the selection.
            if showNoteInput { onBeginNote() }
        }
        .accessibilityIdentifier("webSelectionPopover.addNote")
        #if os(macOS)
        DictionaryLookupButton {
            onDictionaryLookup()
            onClose()
        }
        .accessibilityIdentifier("webSelectionPopover.dictionaryLookup")
        #endif
        AskAiButton {
            onAskAi()
            onClose()
        }
        .accessibilityIdentifier("webSelectionPopover.askAi")
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

#if os(macOS)
private struct DictionaryLookupButton: View {
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "book.closed")
                .font(.system(size: 14))
                .foregroundStyle(hovering ? palette.foreground : palette.mutedForeground)
                .frame(width: 24, height: 24)
                .background(hovering ? palette.accent : .clear)
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Look Up in Dictionary")
        .accessibilityLabel("Look Up in Dictionary")
    }
}
#endif

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
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #else
                .contentShape(Circle())
                #endif
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Highlight \(color.name)")
        .accessibilityLabel("Highlight \(color.name)")
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
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #else
                .contentShape(Circle())
                #endif
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Add note")
        .accessibilityLabel("Add note")
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
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #else
                .contentShape(Circle())
                #endif
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Ask AI about this")
        .accessibilityLabel("Ask AI about this")
    }
}
