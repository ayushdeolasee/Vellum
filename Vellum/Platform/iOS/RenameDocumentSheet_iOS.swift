#if os(iOS)
import SwiftUI

/// The rename prompt, shared by the home screen's row context menu and the tab
/// strip's, so a document is renamed the same way wherever the user reaches for
/// it.
///
/// Deliberately a sheet rather than an inline editable label. Inline editing in
/// a list that re-sorts and re-ranks live is a trap: committing a name under a
/// name sort makes the row jump away mid-keystroke, and the home list also
/// re-ranks against the search query. A sheet holds still.
///
/// iPad rebuild of main's `Vellum/Views/Welcome/RenameDocumentSheet.swift`
/// (packet 3 §2.10): same three inputs and the same semantics, in the
/// `NavigationStack` + toolbar + `.presentationDetents` idiom the other iPad
/// sheets use (`AddWebpageSheet_iOS`), instead of main's fixed 380pt panel with
/// its hand-drawn field chrome.
struct RenameDocumentSheet_iOS: View {
    /// What the row currently shows — the starting text, and what the field is
    /// seeded with.
    let currentTitle: String
    /// The name the document would show with no override: its filename or its
    /// host. Shown as the placeholder so clearing the field is obviously not
    /// the same as leaving it blank forever.
    let fallbackName: String
    let commit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(fallbackName, text: $draft)
                        .focused($fieldFocused)
                        .submitLabel(.done)
                        .onSubmit(save)
                        .accessibilityIdentifier("rename.field")
                    // Clearing the field is the documented way to drop a custom
                    // name, so there is an explicit control for it rather than
                    // making the user guess that empty means "revert". It clears
                    // the draft to "" — `DocumentRenameService.normalized("")`
                    // returns nil, which is what drops the override. Do NOT
                    // "helpfully" refill the field with the fallback name.
                    Button("Use original name") { draft = ""; fieldFocused = true }
                        .accessibilityIdentifier("rename.reset")
                } footer: {
                    // Says plainly what this does and does not touch, because
                    // "rename" in a document app reasonably reads as "rename the
                    // file" and here it does not. Verbatim from main — it is the
                    // user-facing statement of the PR #82 guarantee.
                    Text("Changes the name shown in Vellum. The file on disk keeps its own name.")
                }
            }
            .navigationTitle("Rename")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("rename.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Rename", action: save)
                        .accessibilityIdentifier("rename.commit")
                }
            }
            .onAppear {
                draft = currentTitle
                fieldFocused = true
            }
        }
        .presentationDetents([.medium])
    }

    private func save() {
        commit(draft)
        dismiss()
    }
}
#endif
