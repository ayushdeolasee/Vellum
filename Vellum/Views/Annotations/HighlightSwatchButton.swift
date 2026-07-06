import SwiftUI

/// Round highlight-color swatch shared by the annotations sidebar, the selection
/// popover, and the highlight edit popover. Cross-platform: `.onHover`/`.help`
/// are no-ops under touch and light up with a trackpad/pointer on iPad.
struct HighlightSwatchButton: View {
    let color: HighlightColor
    let size: CGFloat
    var isCurrent = false
    let helpText: String
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(hex: color.value))
                .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                .overlay {
                    if isCurrent {
                        // ring-2 ring-primary ring-offset-1
                        Circle()
                            .stroke(palette.primary, lineWidth: 2)
                            .padding(-2)
                    }
                }
                .frame(width: size, height: size)
                .scaleEffect(hovering ? 1.1 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(helpText)
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }
}
