import SwiftUI

struct AiToolSourceRow: View {
    let source: AiToolSummary.Source
    let onJumpToPage: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let page = source.page {
                Button("Page \(page)", systemImage: "arrow.right.circle") {
                    onJumpToPage(page)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .accessibilityHint("Moves the document to page \(page)")
                .accessibilityIdentifier("aiToolSource.jumpToPage")
            }

            Text(source.excerpt)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: Radius.sm))
    }
}
