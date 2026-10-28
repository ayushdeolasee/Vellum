#if os(iOS)
import SwiftUI

struct EpubReaderTools_iOS: View {
    let reader: EpubReaderController
    @Environment(AppStore.self) private var app
    @State private var showNotes = false
    @State private var deleting: EpubHandwritingNote?
    private var ink: EpubHandwritingController_iOS { reader.handwriting }

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                Button(reader.pencilHighlighting ? "Stop Pencil Highlighting" : "Pencil Text Highlighting") {
                    reader.pencilHighlighting.toggle()
                }
                ForEach(HIGHLIGHT_COLORS, id: \.value) { color in
                    Button(color.name) { reader.pencilHighlightColor = color.value; reader.pencilHighlighting = true }
                }
                Divider()
                Button("Find in Book", systemImage: "magnifyingglass") { app.showFind() }
                Button("Handwrite at Selected Passage", systemImage: "pencil.tip.crop.circle.badge.plus") {
                    guard let anchor = reader.selectedAnchor else { return }
                    reader.run { await ink.create(anchor: anchor) }
                }
                .disabled(reader.selectedAnchor == nil || ink.isLoading)
                Button("Handwriting (\(ink.notes.count))", systemImage: "note.text") { showNotes = true }
                Button("Annotations", systemImage: "sidebar.right") { app.workspace?.revealSidebarTab(.annotations) }
            } label: {
                Image(systemName: reader.pencilHighlighting ? "highlighter" : "pencil.tip")
                    .foregroundStyle(reader.pencilHighlighting ? Color.accentColor : Color.primary)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .accessibilityLabel("Pencil and passage handwriting")
            .accessibilityIdentifier("epub.pencil.tools")
        }
        .sheet(isPresented: Binding(get: { showNotes || ink.isPresented }, set: { shown in
            if !shown {
                showNotes = false; ink.isPresented = false
                reader.run { _ = await ink.flushPendingInkAndWait() }
            }
        })) {
            if ink.isPresented {
                EpubHandwritingSheet_iOS(ink: ink) {
                    reader.run {
                        if await ink.flushPendingInkAndWait() { ink.isPresented = false; showNotes = false }
                    }
                }
            } else {
                notesList
            }
        }
        .onChange(of: reader.isCurrent) { _, current in if !current { showNotes = false } }
    }

    private var notesList: some View {
        NavigationStack {
            List {
                if ink.isLoading { ProgressView() }
                if let notice = ink.notice { Text(notice).foregroundStyle(.secondary) }
                if ink.notes.isEmpty, !ink.isLoading {
                    Text("Select a passage, then choose Handwrite at Selected Passage. Draw with Pencil; scroll with a finger.")
                        .foregroundStyle(.secondary)
                }
                ForEach(ink.notes) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Button { reader.run { await ink.open(note) } } label: {
                            Label(note.anchor.quote, systemImage: "pencil.tip")
                                .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                        }
                        if ink.unresolved.contains(note.id) {
                            Text("Passage not found — drawing preserved").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Button("Go to Passage") {
                                guard let chapter = reader.session?.publication.spineIndex(path: note.anchor.chapterHref) else { return }
                                showNotes = false
                                reader.go(chapter: chapter, anchor: note.anchor)
                            }
                            .disabled(ink.unresolved.contains(note.id))
                            Spacer()
                            if let anchor = reader.selectedAnchor {
                                Button("Reattach to Selection") {
                                    reader.run { await ink.reattach(id: note.id, to: anchor) }
                                }
                            }
                            Button("Delete", role: .destructive) { deleting = note }
                        }
                        .font(.caption)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .navigationTitle("Handwriting")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showNotes = false } } }
            .confirmationDialog("Delete this handwritten note?", isPresented: Binding(
                get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Delete Note", role: .destructive) {
                    guard let note = deleting else { return }
                    reader.run { await ink.delete(id: note.id) }
                    deleting = nil
                }
            }
        }
    }
}
#endif
