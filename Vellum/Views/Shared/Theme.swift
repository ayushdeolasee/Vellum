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

enum AppTheme: String, Sendable, CaseIterable {
    case system
    case light
    case dark

    var label: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
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

/// Shared selection language for every "current" chrome element — active tab,
/// selected segmented item, active annotation tool, selected filter chip. One
/// quiet primary-tinted fill plus a hairline primary edge everywhere, so state
/// reads from shape and color, not from labels. Deliberately semantic (no
/// glass): per the material strategy the unified toolbar owns the glass, and
/// selected children get this flat tint instead of their own stacked pane.
enum SelectionStyle {
    /// Fill behind an element: primary tint when selected, a faint neutral wash
    /// on hover, otherwise clear.
    static func fill(_ palette: ThemePalette, selected: Bool, hovering: Bool = false) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(palette.primary.opacity(0.16)) }
        return hovering ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(Color.clear)
    }

    /// Hairline edge: a translucent primary stroke when selected, else clear.
    static func edge(_ palette: ThemePalette, selected: Bool) -> AnyShapeStyle {
        selected ? AnyShapeStyle(palette.primary.opacity(0.45)) : AnyShapeStyle(Color.clear)
    }

    /// Label/icon color: primary tint when selected, secondary at rest, primary
    /// on hover.
    static func foreground(_ palette: ThemePalette, selected: Bool, hovering: Bool = false) -> AnyShapeStyle {
        if selected { return AnyShapeStyle(palette.primary) }
        return hovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary)
    }
}

extension View {
    /// Apply the shared selection surface (tinted fill + hairline edge) clipped
    /// to `shape`. Used by tabs, the segmented thumb, and filter chips so they
    /// all read as one selection system.
    func selectionSurface<S: InsettableShape>(
        selected: Bool,
        hovering: Bool = false,
        in shape: S,
        palette: ThemePalette
    ) -> some View {
        background {
            shape.fill(SelectionStyle.fill(palette, selected: selected, hovering: hovering))
        }
        .overlay {
            shape.strokeBorder(SelectionStyle.edge(palette, selected: selected), lineWidth: 1)
        }
    }
}

@MainActor
@Observable
final class ThemeStore {
    static let storageKey = "vellum.theme"

    /// The user's three-way choice (System / Light / Dark). Persisted verbatim.
    private(set) var theme: AppTheme

    /// Live snapshot of the OS appearance, updated by a KVO observer on
    /// `NSApp.effectiveAppearance` so System mode re-renders the instant macOS
    /// flips between light and dark.
    private var systemIsDark: Bool

    @ObservationIgnored private var appearanceObservation: NSKeyValueObservation?
    @ObservationIgnored private var distributedObserver: NSObjectProtocol?

    /// Effective dark-mode state after resolving System against the OS.
    var isDark: Bool {
        switch theme {
        case .light: false
        case .dark: true
        case .system: systemIsDark
        }
    }

    var palette: ThemePalette { isDark ? .dark : .light }

    /// Scheme forced onto the window chrome. `nil` in System mode so we defer to
    /// the OS appearance instead of pinning it — required for live switching.
    var colorScheme: ColorScheme? {
        switch theme {
        case .light: .light
        case .dark: .dark
        case .system: nil
        }
    }

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey)
            .flatMap(AppTheme.init(rawValue:))
        // Existing light/dark preferences migrate untouched; a fresh install
        // (no stored value) defaults to System so it tracks macOS out of the box.
        theme = stored ?? .system
        systemIsDark = Self.currentSystemIsDark()
        observeSystemAppearance()
    }

    private static func currentSystemIsDark() -> Bool {
        let appearance = NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
        return appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func observeSystemAppearance() {
        // In System mode the window forces no scheme, so effectiveAppearance
        // tracks the OS and this fires on every Control Center appearance flip.
        if let app = NSApp {
            appearanceObservation = app.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.systemIsDark = Self.currentSystemIsDark()
                }
            }
        }
        // Belt-and-suspenders: the OS also broadcasts this when the global Light/
        // Dark setting flips, covering any case where the KVO signal is missed.
        distributedObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.systemIsDark = Self.currentSystemIsDark()
            }
        }
    }

    func setTheme(_ theme: AppTheme) {
        self.theme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: Self.storageKey)
        // Re-read the OS appearance so a switch into System resolves correctly
        // even if the KVO callback lands a frame later.
        systemIsDark = Self.currentSystemIsDark()
    }

    func toggleTheme() {
        setTheme(isDark ? .light : .dark)
    }

    /// Render color for a persisted highlight hex: highlights are stored with
    /// their light value; dark mode maps to the matching dark variant.
    func highlightRenderColor(for storedHex: String?) -> Color {
        let hex = storedHex ?? HIGHLIGHT_COLORS[0].value
        if isDark,
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
