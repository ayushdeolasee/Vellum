import SwiftUI

struct AiToolSummaryView: View {
    let summary: AiToolSummary
    let onJumpToPage: (Int) -> Void

    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(summary.sources) { source in
                    AiToolSourceRow(source: source, onJumpToPage: onJumpToPage)
                }
                if summary.sources.isEmpty, let page = summary.destinationPage {
                    Button("Jump to page \(page)", systemImage: "arrow.right.circle") {
                        onJumpToPage(page)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
                    .accessibilityHint("Moves the document to page \(page)")
                    .accessibilityIdentifier("aiToolSummary.jumpToPage")
                }
            }
            .padding(.top, 6)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.title)
                        .lineLimit(1)
                    if let detail = summary.detail, detail.isEmpty == false {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: summary.sources.isEmpty ? "wrench.and.screwdriver" : "doc.text.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: Radius.md))
        .accessibilityIdentifier("aiToolSummary")
        .accessibilityHint(isExpanded ? "Collapses source details" : "Expands source details")
    }
}
