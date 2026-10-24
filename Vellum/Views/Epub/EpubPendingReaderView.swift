import SwiftUI

/// Shown in an EPUB tab until the chapter reader lands (#398, stage 3): the
/// book is imported and its session open, so this only confirms what loaded.
struct EpubPendingReaderView: View {
    let document: DocumentInfo

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "book")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(document.title ?? "Untitled Book")
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if let chapters = document.pageCount {
                Text(chapters == 1 ? "1 chapter" : "\(chapters) chapters")
                    .foregroundStyle(.secondary)
            }
            Text("The EPUB reader is coming soon. This book is saved in your library.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("epub.pendingReader")
    }
}
