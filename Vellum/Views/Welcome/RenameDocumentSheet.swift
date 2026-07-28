import SwiftUI

/// The rename prompt, shared by the home screen's row context menu and the tab
/// bar's, so a document is renamed the same way wherever the user reaches for
/// it.
///
/// Deliberately a small sheet rather than an inline editable label. Inline
/// editing in a list that re-sorts and re-ranks live is a trap: committing a
/// name under a name sort makes the row jump away mid-keystroke, and this list
/// also re-ranks against the search query. A sheet holds still.
struct RenameDocumentSheet: View {
    /// What the row currently shows — the starting text, and what "Reset"
    /// falls back to.
    let currentTitle: String
    /// The name the document would show with no override: its filename or its
    /// host. Shown as the placeholder so clearing the field is obviously not
    /// the same as leaving it blank forever.
    let fallbackName: String
    let commit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var draft: String = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Rename")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.foreground)
                // Says plainly what this does and does not touch, because
                // "rename" in a document app reasonably reads as "rename the
                // file" and here it does not.
                Text("Changes the name shown in Vellum. The file on disk keeps its own name.")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(fallbackName, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .foregroundStyle(palette.foreground)
                .focused($fieldFocused)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.separator)
                }
                .onSubmit(save)
                .accessibilityIdentifier("rename.field")

            HStack(spacing: 8) {
                // Clearing the field is the documented way to drop a custom
                // name, so there is an explicit control for it rather than
                // making the user guess that empty means "revert".
                TextButton(variant: .secondary, size: .sm) {
                    draft = ""
                    fieldFocused = true
                } label: {
                    Text("Use original name")
                }
                .accessibilityIdentifier("rename.reset")

                Spacer(minLength: 12)

                TextButton(variant: .secondary, size: .sm) { dismiss() } label: {
                    Text("Cancel")
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("rename.cancel")

                TextButton(size: .sm, action: save) {
                    Text("Rename")
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("rename.commit")
            }
        }
        .padding(18)
        .frame(width: 380)
        .background(palette.well)
        .onAppear {
            draft = currentTitle
            fieldFocused = true
        }
    }

    private func save() {
        commit(draft)
        dismiss()
    }
}
