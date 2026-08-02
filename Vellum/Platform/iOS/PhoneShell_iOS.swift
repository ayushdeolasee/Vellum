#if os(iOS)
import SwiftUI

/// The compact-width (iPhone) shell.
///
/// Phase 0 (#151) widens the target to iPhone and puts the idiom gate in
/// `RootShell_iOS`; the real phone surfaces — Home, reader, tab switcher —
/// land in #153. Until then this is a placeholder, and it is deliberately inert:
/// no fabricated library rows, no buttons that lead nowhere. A phone build that
/// shows a plausible-looking Home full of fake documents is worse than one that
/// says plainly that the screen isn't built yet.
///
/// It does draw itself in the app's own palette (via the `\.palette`
/// environment `VellumApp_iOS` injects) so the launch still reads as Vellum and
/// so this screen exercises the theme plumbing on the phone idiom.
///
/// The one thing it is NOT allowed to be silent about is `.vellumOpenFile`.
/// Widening the target made Vellum an "Open in" / share-sheet destination on
/// iPhone (`CFBundleDocumentTypes` is idiom-blind), and a hardware ⌘O reaches
/// the phone too. `ContentView_iOS` is the only other listener on that channel
/// and it is never in the tree here, so without the handler below a shared PDF
/// would be copied into the library and vanish, with the user still looking at
/// "being built" and no reason to think anything happened.
struct PhoneShell_iOS: View {
    @Environment(\.palette) private var palette

    /// What the last `.vellumOpenFile` did, or nil before the first one. Not
    /// an alert: the answer is an explanation of where the file went, and it
    /// belongs under the sentence that explains why it went there.
    @State private var notice: PhoneImportNotice?

    var body: some View {
        VStack(spacing: 14) {
            Wordmark(size: 44)
            Text("The iPhone app is being built.")
                .font(.headline)
                .foregroundStyle(palette.foreground)
            Text("Open Vellum on iPad to read, annotate and chat about your library in the meantime.")
                .font(.subheadline)
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let notice {
                Text(notice.message)
                    .font(.footnote)
                    .foregroundStyle(palette.foreground)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .fill(palette.surface))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .stroke(palette.border))
                    .accessibilityIdentifier("phoneShell.importNotice")
            }
        }
        .animation(.easeInOut(duration: 0.2), value: notice)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well.ignoresSafeArea())
        .accessibilityIdentifier("phoneShell.placeholder")
        .onReceive(NotificationCenter.default.publisher(for: .vellumOpenFile)) { note in
            notice = PhoneImportNotice(userInfo: note.userInfo)
        }
    }
}

/// The two shapes a `.vellumOpenFile` takes, phrased for a shell that cannot
/// open anything yet. A payload means `VellumApp_iOS` already copied the files
/// into the library, so the honest message is "kept, not opened"; no payload is
/// ⌘O asking for the importer, which there is nothing to import INTO.
enum PhoneImportNotice: Equatable {
    case imported(count: Int)
    case unavailable

    init(userInfo: [AnyHashable: Any]?) {
        let paths = userInfo?["paths"] as? [String] ?? []
        self = paths.isEmpty ? .unavailable : .imported(count: paths.count)
    }

    var message: String {
        switch self {
        case .imported(let count):
            let subject = count == 1
                ? "That document is saved to your library. Open it"
                : "Those \(count) documents are saved to your library. Open them"
            return "\(subject) on iPad — the iPhone reader isn't built yet."
        case .unavailable:
            return "Opening documents isn't available on iPhone yet."
        }
    }
}
#endif
