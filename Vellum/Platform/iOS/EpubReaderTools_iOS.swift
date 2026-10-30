#if os(iOS)
import SwiftUI

struct EpubReaderTools_iOS: View {
    let reader: EpubReaderController
    @State private var deleting: EpubHandwritingNote?
    private var ink: EpubHandwritingController_iOS { reader.handwriting }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .allowsHitTesting(false)
            .sheet(isPresented: Binding(get: { ink.listPresented || ink.isPresented }, set: { shown in
                if !shown {
                    ink.listPresented = false; ink.isPresented = false
                    reader.run { _ = await ink.flushPendingInkAndWait() }
                }
            })) {
                if ink.isPresented {
                    EpubHandwritingSheet_iOS(ink: ink) {
                        reader.run {
                            if await ink.flushPendingInkAndWait() { ink.isPresented = false; ink.listPresented = false }
                        }
                    }
                } else {
                    notesList
                }
            }
            .onChange(of: reader.isCurrent) { _, current in if !current { ink.listPresented = false } }
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
                                ink.listPresented = false
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
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { ink.listPresented = false } } }
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
