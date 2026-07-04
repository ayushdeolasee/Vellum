import SwiftUI

// Shared chrome controls — ports of src/components/ui/*. Every toolbar/tab/
// panel control reaches for these so sizing, radius, hover, and focus behavior
// stay identical everywhere.

enum IconButtonVariant { case ghost, primary, active }
enum IconButtonSize {
    case sm, md
    var side: CGFloat { self == .sm ? 28 : 32 }
}

/// A single, consistent square icon button used across the chrome.
struct IconButton<Icon: View>: View {
    var variant: IconButtonVariant = .ghost
    var size: IconButtonSize = .sm
    var help: String? = nil
    var disabled = false
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            icon()
                .frame(width: size.side, height: size.side)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled && variant == .ghost ? 0.3 : (disabled ? 0.5 : 1))
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityLabel(help ?? "")
    }

    private var background: AnyShapeStyle {
        switch variant {
        case .ghost:
            return hovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear)
        case .active, .primary:
            return hovering ? AnyShapeStyle(palette.primaryHover) : AnyShapeStyle(.tint)
        }
    }

    private var foreground: AnyShapeStyle {
        switch variant {
        case .ghost:
            return hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
        case .active, .primary:
            return AnyShapeStyle(palette.primaryForeground)
        }
    }
}

enum TextButtonVariant { case primary, secondary, ghost }
enum TextButtonSize {
    case sm, md, lg
    var height: CGFloat { switch self { case .sm: 28; case .md: 36; case .lg: 44 } }
    var paddingX: CGFloat { switch self { case .sm: 10; case .md: 14; case .lg: 20 } }
    var fontSize: CGFloat { switch self { case .sm: 12; case .md: 14; case .lg: 14 } }
    var gap: CGFloat { switch self { case .sm: 6; case .md: 8; case .lg: 8 } }
}

/// A consistent text button with optional leading icon. (ui/Button.tsx)
/// Primary/secondary variants render as Liquid Glass; ghost stays borderless.
struct TextButton<Content: View>: View {
    var variant: TextButtonVariant = .primary
    var size: TextButtonSize = .md
    var disabled = false
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: size.gap) { label() }
                .font(.system(size: size.fontSize, weight: .medium))
                .padding(.horizontal, size.paddingX / 2)
                .frame(minHeight: size.height - 12)
        }
        .controlSize(controlSize)
        .disabled(disabled)

        switch variant {
        case .primary: button.buttonStyle(.glassProminent)
        case .secondary: button.buttonStyle(.glass)
        case .ghost: button.buttonStyle(.borderless)
        }
    }

    private var controlSize: ControlSize {
        switch size {
        case .sm: return .small
        case .md: return .regular
        case .lg: return .large
        }
    }
}

/// Capsule segment switcher with a sliding Liquid Glass thumb, like the view
/// switcher in Music. The system segmented Picker snaps between segments;
/// this one morphs.
struct GlassSegmentedPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    /// Optional stable identifier prefix for UI automation, e.g. "sidebarTab"
    /// produces "sidebarTab.annotations" / "sidebarTab.ai" from each label.
    var accessibilityIdentifierPrefix: String? = nil

    @Namespace private var thumbNamespace

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Button {
                    // Springy morph, like the view switcher in Music — the
                    // thumb overshoots slightly and settles instead of snapping.
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) {
                        selection = option.value
                    }
                } label: {
                    // Every segment is sized by the widest label (hidden
                    // copies) so the thumb doesn't shrink-wrap short labels
                    // like "AI" and read lopsided. The hidden copies must be
                    // excluded from accessibility or every segment announces
                    // every label's text.
                    ZStack {
                        ForEach(options, id: \.value) { sizing in
                            Text(sizing.label)
                                .hidden()
                                .accessibilityHidden(true)
                        }
                        Text(option.label)
                            .foregroundStyle(isSelected ? .primary : .secondary)
                            .accessibilityHidden(true)
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 14)
                    .frame(maxHeight: .infinity)
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.label)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier(
                    accessibilityIdentifierPrefix.map { "\($0).\(option.label)" } ?? option.label
                )
                .background {
                    if isSelected {
                        // The thumb fills the track's full height (only the
                        // 2 px inset shows), matching Apple Music's snug pill.
                        Capsule()
                            .fill(.quaternary.opacity(0.6))
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .matchedGeometryEffect(id: "thumb", in: thumbNamespace)
                    }
                }
            }
        }
        .frame(height: 26)
        .padding(2)
        .background(.quaternary.opacity(0.4), in: Capsule())
    }
}

/// The Vellum wordmark. Set in the serif display face — the one place the
/// "parchment" identity is allowed to speak loudly. Render at the real point
/// size: scaling it up with scaleEffect rasterizes the small glyphs and
/// produces a blurry bitmap.
struct Wordmark: View {
    var size: CGFloat = 15

    @Environment(\.palette) private var palette

    var body: some View {
        (Text("Vellum").foregroundStyle(palette.foreground)
            + Text(".").foregroundStyle(palette.primary))
            .font(.custom("Iowan Old Style", size: size).weight(.semibold))
            .kerning(-0.2 * size / 15)
    }
}

