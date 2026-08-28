#if os(macOS)
import SwiftUI

struct LibraryRowContent<Leading: View>: View {
    let title: String
    let subtitle: String
    let badge: String?
    let tooltip: String
    @ViewBuilder let leading: Leading

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            leading.frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(palette.foreground).lineLimit(1)
                    if let badge { Text(badge).font(.system(size: 9, weight: .semibold)).padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule()) }
                }
                Text(subtitle).font(.system(size: 12)).foregroundStyle(palette.mutedForeground).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
        .background { RoundedRectangle(cornerRadius: Radius.md).fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(Color.clear)).padding(.vertical, -5) }
        .padding(.horizontal, -6).contentShape(Rectangle()).onHover { hovering = $0 }.animation(.easeOut(duration: 0.12), value: hovering).help(tooltip)
    }
}
#endif
