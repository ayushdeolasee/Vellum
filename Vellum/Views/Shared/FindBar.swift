import SwiftUI

/// Slim find bar shown under the toolbar/tab strip while ⌘F is active. Drives
/// the active viewer's find (PDFKit search for PDF tabs, the content-script
/// find layer for web tabs) through AppStore's find handlers, and mirrors the
/// live match count reported back by the viewer.
struct FindBar: View {
    @Environment(AppStore.self) private var app
    @Environment(\.palette) private var palette

    @State private var query = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)

            TextField("Find", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .frame(minWidth: 160, maxWidth: 240)
                .onSubmit { app.findNext() }
                .onChange(of: query) { _, value in app.performFind(value) }

            Text(matchLabel)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(palette.mutedForeground)
                .frame(minWidth: 64, alignment: .trailing)

            Divider().frame(height: 14)

            Button { app.findPrev() } label: {
                Image(systemName: "chevron.up").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(app.findMatchCount == 0)
            .help("Previous match (⌘⇧G)")

            Button { app.findNext() } label: {
                Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            .disabled(app.findMatchCount == 0)
            .help("Next match (⌘G)")

            Button("Done") { app.hideFind() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(.bar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
        .onAppear {
            fieldFocused = true
            if !query.isEmpty { app.performFind(query) }
        }
        // Escape while the bar (or its field) holds focus dismisses it; the
        // window-level key monitor covers the other focus cases. (macOS only —
        // iPad dismisses via the bar's Done button.)
        #if os(macOS)
        .onExitCommand { app.hideFind() }
        #endif
    }

    private var matchLabel: String {
        if query.isEmpty { return "" }
        if app.findMatchCount == 0 { return "No results" }
        return "\(app.findCurrentMatch) of \(app.findMatchCount)"
    }
}
