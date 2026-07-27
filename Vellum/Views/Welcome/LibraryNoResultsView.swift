import SwiftUI

struct LibraryNoResultsView: View {
    let query: String
    let filter: LibraryFilter
    let reset: () -> Void

    @Environment(\.palette) private var palette

    private var detail: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "There aren’t any \(filter.label.lowercased()) items in your library yet."
        }
        if filter == .all {
            return "No title, filename, domain, or URL matches “\(trimmed)”."
        }
        return "No \(filter.label.lowercased()) item matches “\(trimmed)”."
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(palette.mutedForeground)
            Text("No library results")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(palette.foreground)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
            Button("Show all items", action: reset)
                .buttonStyle(.link)
                .accessibilityIdentifier("welcome.librarySearch.reset")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("welcome.library.noResults")
    }
}
