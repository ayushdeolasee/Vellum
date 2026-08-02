#if os(iOS)
import SwiftUI

/// The compact-width (iPhone) shell.
///
/// Phase 0 (#151) widens the target to iPhone and puts the size-class gate in
/// `RootShell_iOS`; the real phone surfaces — Home, reader, tab switcher —
/// land in #153. Until then this is a placeholder, and it is deliberately inert:
/// no fabricated library rows, no buttons that lead nowhere. A phone build that
/// shows a plausible-looking Home full of fake documents is worse than one that
/// says plainly that the screen isn't built yet.
///
/// It does draw itself in the app's own palette (via the `\.palette`
/// environment `VellumApp_iOS` injects) so the launch still reads as Vellum and
/// so this screen exercises the theme plumbing on the phone idiom.
struct PhoneShell_iOS: View {
    @Environment(\.palette) private var palette

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
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well.ignoresSafeArea())
        .accessibilityIdentifier("phoneShell.placeholder")
    }
}
#endif
