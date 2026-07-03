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

    private var background: Color {
        switch variant {
        case .ghost: return hovering ? palette.accent : .clear
        case .active: return hovering ? palette.primaryHover : palette.primary
        case .primary: return hovering ? palette.primaryHover : palette.primary
        }
    }

    private var foreground: Color {
        switch variant {
        case .ghost: return hovering ? palette.foreground : palette.mutedForeground
        case .active, .primary: return palette.primaryForeground
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
struct TextButton<Content: View>: View {
    var variant: TextButtonVariant = .primary
    var size: TextButtonSize = .md
    var disabled = false
    let action: () -> Void
    @ViewBuilder let label: () -> Content

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: size.gap) { label() }
                .font(.system(size: size.fontSize, weight: .medium))
                .padding(.horizontal, size.paddingX)
                .frame(height: size.height)
                .background(background)
                .foregroundStyle(foreground)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    if variant == .secondary {
                        RoundedRectangle(cornerRadius: Radius.md)
                            .strokeBorder(palette.borderStrong, lineWidth: 1)
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .onHover { hovering = $0 }
    }

    private var background: Color {
        switch variant {
        case .primary: return hovering ? palette.primaryHover : palette.primary
        case .secondary: return hovering ? palette.accent : palette.surface
        case .ghost: return hovering ? palette.accent : .clear
        }
    }

    private var foreground: Color {
        switch variant {
        case .primary: return palette.primaryForeground
        case .secondary: return palette.foreground
        case .ghost: return hovering ? palette.foreground : palette.mutedForeground
        }
    }
}

/// The Vellum wordmark. Set in the serif display face — the one place the
/// "parchment" identity is allowed to speak loudly.
struct Wordmark: View {
    @Environment(\.palette) private var palette

    var body: some View {
        (Text("Vellum").foregroundStyle(palette.foreground)
            + Text(".").foregroundStyle(palette.primary))
            .font(.custom("Iowan Old Style", size: 15).weight(.semibold))
            .kerning(-0.2)
    }
}

/// Toolbar control that flips between the light and dark Scriptorium themes.
struct ThemeToggle: View {
    @Environment(ThemeStore.self) private var themeStore

    var body: some View {
        let isDark = themeStore.theme == .dark
        IconButton(
            help: isDark ? "Switch to light theme" : "Switch to dark theme",
            action: { themeStore.toggleTheme() }
        ) {
            Image(systemName: isDark ? "sun.max" : "moon")
                .font(.system(size: 14))
        }
    }
}
