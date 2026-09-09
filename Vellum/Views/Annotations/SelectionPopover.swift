import SwiftUI
#if os(iOS)
import UIKit
#endif

// Selection popover — port of src/components/annotations/SelectionPopover.tsx.
// Five compact color swatches plus copy, note, and AI actions. iOS wraps them
// into two rows of 44pt targets; note input stays a separate 256pt row.

struct SelectionPopover: View {
    let selection: PdfTextSelection
    let onClose: () -> Void

    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var showNoteInput = false
    @State private var noteText = ""
    @State private var noteButtonHovering = false
    @State private var askAiHovering = false
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
            HStack(spacing: 4) {
                controlItems
            }
            .padding(6)
            .darkGlassSurface(in: .capsule)
            #endif

            if showNoteInput {
                HStack(spacing: 6) {
                    TextField("Add a note...", text: $noteText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                        .focused($noteFieldFocused)
                        .onSubmit { handleAddNote() }
                        #if os(macOS)
                        .onExitCommand { onClose() }
                        #endif
                        .onAppear { noteFieldFocused = true }

                    #if os(iOS)
                    Button(action: handleAddNote) {
                        Text("Add")
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                    #else
                    Button("Add", action: handleAddNote)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    #endif
                }
                .padding(8)
                .frame(width: 256)
                .darkGlassSurface(in: .rect(cornerRadius: Radius.lg))
            }
        }
    }

    @ViewBuilder
    private var controlItems: some View {
        ForEach(HIGHLIGHT_COLORS) { color in
            HighlightSwatchButton(
                color: color,
                size: 24,
                helpText: "Highlight \(color.name)"
            ) {
                handleHighlight(color.value)
            }
        }

        #if os(macOS)
        Rectangle()
            .fill(.quaternary)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 4)
        #else
        // The system callout is suppressed on iPad (it collided with this
        // popover), so copy lives here instead.
        Button {
            UIPasteboard.general.string = selection.text
            onClose()
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Copy")
        .accessibilityIdentifier("selectionPopover.copy")
        #endif

        Button {
            showNoteInput.toggle()
        } label: {
            Image(systemName: "plus.bubble")
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .foregroundStyle(noteButtonHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(noteButtonHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                .clipShape(Circle())
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #else
                .contentShape(Circle())
                #endif
        }
        .buttonStyle(.plain)
        .onHover { noteButtonHovering = $0 }
        .help("Add note")
        .accessibilityLabel("Add note")
        .accessibilityIdentifier("selectionPopover.addNote")

        Button(action: handleAskAi) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .foregroundStyle(askAiHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(askAiHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                .clipShape(Circle())
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #else
                .contentShape(Circle())
                #endif
        }
        .buttonStyle(.plain)
        .onHover { askAiHovering = $0 }
        .help("Ask AI about this")
        .accessibilityLabel("Ask AI about this")
        .accessibilityIdentifier("selectionPopover.askAi")
    }

    /// Attach the selected text to the AI composer as a `.selection` reference
    /// (page locator preserved). Mirrors the web viewer's askAiAboutSelection —
    /// the reference sits in the composer until the user opens the AI panel.
    private func handleAskAi() {
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        onClose()
        guard !text.isEmpty else { return }
        aiStore.addReference(AiReference(kind: .selection(text: text, page: selection.pageNumber)))
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

// HighlightSwatchButton moved to Views/Annotations/HighlightSwatchButton.swift
// (cross-platform) so the shared AnnotationSidebar can use it on iPad.
