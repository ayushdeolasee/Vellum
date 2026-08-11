#if os(iOS)
import SwiftUI

/// The shared row body for library-style lists: a leading well, a title with an
/// optional badge, and a subtitle.
///
/// Touch rebuild of `main:Vellum/Views/Welcome/LibraryRowContent.swift`. The
/// typography and the badge capsule are kept verbatim — they are what makes the
/// read-later rows look like the rest of the library — but everything hover is
/// gone: no `@State hovering`, no `.onHover`, no hover background and no
/// `.help(tooltip)`, because none of those have a meaning on a touch screen.
///
/// The `tooltip` parameter is dropped rather than rerouted into
/// `.accessibilityLabel`: the URL it carried would have replaced the title and
/// subtitle for VoiceOver, which reads worse than the text already in the row.
/// The host is in the subtitle anyway.
///
/// Pressed/selected feedback is left to the enclosing `Button`'s `.plain` style
/// and the `List`'s own row highlight.
struct LibraryRowContent_iOS<Leading: View>: View {
    let title: String
    let subtitle: String
    let badge: String?
    @ViewBuilder let leading: Leading

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.foreground).lineLimit(1)
                    if let badge {
                        Text(badge).font(.system(size: 9, weight: .semibold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.mutedForeground).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // 34pt well + 13pt top and bottom clears the 60pt touch row the list
        // asks for via `defaultMinListRowHeight`.
        .padding(.vertical, 13).padding(.horizontal, 6)
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
    }
}
#endif
