import SwiftUI

/// Slim find bar shown under the toolbar/tab strip while ⌘F is active. Drives
/// the active viewer's find (PDFKit search for PDF tabs, the content-script
/// find layer for web tabs) through AppStore's find handlers, and mirrors the
/// live match count reported back by the viewer.
struct FindBar: View {
    @Environment(AppStore.self) private var app
    @Environment(\.palette) private var palette

    @FocusState private var fieldFocused: Bool
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        let wide = availableWidth >= 440
        let layout = wide
            ? AnyLayout(HStackLayout(spacing: 8))
            : AnyLayout(VStackLayout(spacing: 2))
        layout {
            searchField.frame(minWidth: wide ? 160 : 0, maxWidth: wide ? 240 : .infinity)
            HStack(spacing: 8) {
                matchCount.frame(
                    minWidth: wide ? 64 : 0,
                    maxWidth: wide ? nil : .infinity,
                    alignment: wide ? .trailing : .leading)
                if wide { Divider().frame(height: 14) }
                navigationControls
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .background(.bar)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            availableWidth = width
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
        .onAppear {
            fieldFocused = true
            if !app.findQuery.isEmpty { app.performFind(app.findQuery) }
        }
        // Escape while the bar (or its field) holds focus dismisses it; the
        // window-level key monitor covers the other focus cases. (macOS only —
        // iPad dismisses via the bar's Done button.)
        #if os(macOS)
        .onExitCommand { app.hideFind() }
        #endif
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
            TextField("Find", text: Binding(
                get: { app.findQuery },
                set: { app.performFind($0) }
            ))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .frame(minWidth: 0, maxWidth: .infinity)
                .onSubmit { app.findNext() }
                .accessibilityLabel("Find in document")
                #if os(iOS)
                .frame(minHeight: 44)
                #endif
        }
    }

    private var matchCount: some View {
        Text(matchLabel)
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(palette.mutedForeground)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }

    @ViewBuilder
    private var navigationControls: some View {
        Button { app.findPrev() } label: {
            Image(systemName: "chevron.up")
                .font(.system(size: 12, weight: .semibold))
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        .disabled(app.findMatchCount == 0)
        .help("Previous match (⌘⇧G)")
        .accessibilityLabel("Previous match")

        Button { app.findNext() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 12, weight: .semibold))
                #if os(iOS)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
        .disabled(app.findMatchCount == 0)
        .help("Next match (⌘G)")
        .accessibilityLabel("Next match")

        Button { app.hideFind() } label: {
            Text("Done")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.primary)
                #if os(iOS)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                #endif
        }
        .buttonStyle(.plain)
    }

    private var matchLabel: String {
        if app.findQuery.isEmpty { return "" }
        if app.findMatchCount == 0 { return "No results" }
        return "\(app.findCurrentMatch) of \(app.findMatchCount)"
    }
}
