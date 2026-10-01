import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// Selection popover — port of src/components/annotations/SelectionPopover.tsx.
// Five compact color swatches plus copy, note, and AI actions. iOS wraps them
// into two rows of 44pt targets; note input stays a separate 256pt row.

struct SelectionPopover: View {
    let selection: PdfTextSelection
    let onClose: () -> Void

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var showNoteInput = false
    @State private var noteText = ""
    @State private var noteButtonHovering = false
    @State private var dictionaryButtonHovering = false
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

        #if os(macOS)
        Button {
            DictionaryLookup.show(selection.text)
            onClose()
        } label: {
            Image(systemName: "book.closed")
                .font(.system(size: 12))
                .frame(width: 24, height: 24)
                .foregroundStyle(dictionaryButtonHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .background(dictionaryButtonHovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { dictionaryButtonHovering = $0 }
        .help("Look Up in Dictionary")
        .accessibilityLabel("Look Up in Dictionary")
        .accessibilityIdentifier("selectionPopover.dictionaryLookup")
        #endif

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
        guard let sessionId = app.activeTabId,
              let queued = annotationStore.enqueueHighlight(input, sessionId: sessionId) else { return }
        #if os(iOS)
        app.workspace?.existingLiveTabRuntime(for: sessionId)?.trackAnnotationWrite(queued.persistence)
        #endif
        onClose()
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

#if os(macOS)
@MainActor
enum DictionaryLookup {
    static func show(_ selection: String) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty,
              let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView
        else { return }

        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let viewPoint = contentView.convert(windowPoint, from: nil)
        contentView.showDefinition(for: NSAttributedString(string: text), at: viewPoint)
    }
}
#endif

// HighlightSwatchButton moved to Views/Annotations/HighlightSwatchButton.swift
// (cross-platform) so the shared AnnotationSidebar can use it on iPad.
