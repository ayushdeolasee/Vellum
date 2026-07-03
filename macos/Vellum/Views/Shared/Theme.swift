import SwiftUI

// "Scriptorium" design system — ported 1:1 from src/index.css.
// Warm parchment chrome, deep ink-indigo accent, neutral document well.

extension Color {
    /// Parse "#rrggbb" or "#rrggbbaa" hex strings (as used across the app).
    init(hex: String) {
        var value = hex.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("#") { value.removeFirst() }
        var rgba: UInt64 = 0
        Scanner(string: value).scanHexInt64(&rgba)
        let r, g, b, a: Double
        if value.count == 8 {
            r = Double((rgba & 0xFF00_0000) >> 24) / 255
            g = Double((rgba & 0x00FF_0000) >> 16) / 255
            b = Double((rgba & 0x0000_FF00) >> 8) / 255
            a = Double(rgba & 0x0000_00FF) / 255
        } else {
            r = Double((rgba & 0xFF0000) >> 16) / 255
            g = Double((rgba & 0x00FF00) >> 8) / 255
            b = Double(rgba & 0x0000FF) / 255
            a = 1
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}

enum AppTheme: String, Sendable {
    case light
    case dark
}

/// Semantic palette for one theme. Mirrors the CSS custom properties.
struct ThemePalette: Sendable {
    let background: Color
    let surface: Color
    let surfaceMuted: Color
    let well: Color
    let foreground: Color
    let muted: Color
    let mutedForeground: Color
    let border: Color
    let borderStrong: Color
    let primary: Color
    let primaryForeground: Color
    let primaryHover: Color
    let accent: Color
    let accentForeground: Color
    let destructive: Color
    let destructiveForeground: Color
    let gold: Color
    let highlightYellow: Color
    let highlightGreen: Color
    let highlightBlue: Color
    let highlightPink: Color
    let highlightPurple: Color

    static let light = ThemePalette(
        background: Color(hex: "#fbfaf7"),
        surface: Color(hex: "#ffffff"),
        surfaceMuted: Color(hex: "#f4f1ea"),
        well: Color(hex: "#ece8df"),
        foreground: Color(hex: "#211d18"),
        muted: Color(hex: "#efebe2"),
        mutedForeground: Color(hex: "#786f62"),
        border: Color(hex: "#e6e0d4"),
        borderStrong: Color(hex: "#d6cdbb"),
        primary: Color(hex: "#45418f"),
        primaryForeground: Color(hex: "#ffffff"),
        primaryHover: Color(hex: "#3a3680"),
        accent: Color(hex: "#efebe2"),
        accentForeground: Color(hex: "#211d18"),
        destructive: Color(hex: "#b23a30"),
        destructiveForeground: Color(hex: "#ffffff"),
        gold: Color(hex: "#a9791b"),
        highlightYellow: Color(hex: "#fde68a"),
        highlightGreen: Color(hex: "#b9efc8"),
        highlightBlue: Color(hex: "#bcd9fb"),
        highlightPink: Color(hex: "#f6c7de"),
        highlightPurple: Color(hex: "#d8d0fb")
    )

    static let dark = ThemePalette(
        background: Color(hex: "#1b1a17"),
        surface: Color(hex: "#232220"),
        surfaceMuted: Color(hex: "#1f1e1b"),
        well: Color(hex: "#121110"),
        foreground: Color(hex: "#ece6da"),
        muted: Color(hex: "#2c2a26"),
        mutedForeground: Color(hex: "#a39a8a"),
        border: Color(hex: "#353229"),
        borderStrong: Color(hex: "#45413a"),
        primary: Color(hex: "#7c79df"),
        primaryForeground: Color(hex: "#15140f"),
        primaryHover: Color(hex: "#8b88e6"),
        accent: Color(hex: "#2c2a26"),
        accentForeground: Color(hex: "#ece6da"),
        destructive: Color(hex: "#e5645c"),
        destructiveForeground: Color(hex: "#15140f"),
        gold: Color(hex: "#d6a93b"),
        highlightYellow: Color(hex: "#7a5a0e80"),
        highlightGreen: Color(hex: "#14583080"),
        highlightBlue: Color(hex: "#1f3f9180"),
        highlightPink: Color(hex: "#8a2a5680"),
        highlightPurple: Color(hex: "#4b3fb380")
    )
}

/// Radii scale (px): sm 5, md 7, lg 10, xl 14, 2xl 20.
enum Radius {
    static let sm: CGFloat = 5
    static let md: CGFloat = 7
    static let lg: CGFloat = 10
    static let xl: CGFloat = 14
    static let xxl: CGFloat = 20
}

@MainActor
@Observable
final class ThemeStore {
    static let storageKey = "vellum.theme"

    private(set) var theme: AppTheme

    var palette: ThemePalette { theme == .dark ? .dark : .light }
    var colorScheme: ColorScheme { theme == .dark ? .dark : .light }

    init() {
        if let stored = UserDefaults.standard.string(forKey: Self.storageKey),
           let parsed = AppTheme(rawValue: stored) {
            theme = parsed
        } else {
            // First launch: follow the OS preference.
            let appearance = NSApp?.effectiveAppearance
                ?? NSAppearance.currentDrawing()
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            theme = isDark ? .dark : .light
        }
    }

    func setTheme(_ theme: AppTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey)
    }

    func toggleTheme() {
        setTheme(theme == .dark ? .light : .dark)
    }

    /// Render color for a persisted highlight hex: highlights are stored with
    /// their light value; dark mode maps to the matching dark variant.
    func highlightRenderColor(for storedHex: String?) -> Color {
        let hex = storedHex ?? HIGHLIGHT_COLORS[0].value
        if theme == .dark,
           let match = HIGHLIGHT_COLORS.first(where: {
               $0.value.caseInsensitiveCompare(hex) == .orderedSame
           }) {
            return Color(hex: match.dark)
        }
        return Color(hex: hex)
    }
}

extension EnvironmentValues {
    @Entry var palette: ThemePalette = .light
}
