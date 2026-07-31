import SwiftUI

// The small, reusable pieces of the home screen's result list. Split out of
// `WelcomeScreen` so the screen itself reads as layout, and so each row type
// owns its own hover state (a single `@State hovering` on the parent would
// invalidate the whole list on every pointer move).
//
// Everything here is built from the existing design system: `palette`,
// `Radius`, `SelectionStyle`/`selectionSurface`, and the same SF Symbols the
// rest of the chrome uses. No new visual language.

// MARK: - Shared page geometry

/// The home screen's column measurements, in ONE place.
///
/// The header block and the result list are separate view trees that have to
/// look like a single column, and when each carried its own copy of these
/// numbers they drifted: the search field's content sat 16pt inside the column
/// while every result row and section header sat 10pt inside it, so the search
/// glyph and the row glyphs below it were not on the same vertical line and the
/// list read as a differently-sized block bolted under the field.
///
/// `column()` is what makes the two blocks the same width by construction
/// rather than by two copies of the same literals, and `rowInset` is the single
/// inner inset every row-like thing uses so their leading edges agree.
enum HomeLayout {
    /// Widest the content column is allowed to get. Past roughly this, a row's
    /// title and its date column drift so far apart that they stop reading as
    /// one line.
    static let contentMaxWidth: CGFloat = 900
    /// Gutter between the column and the window edge.
    static let columnPadding: CGFloat = 24
    /// Inner leading/trailing inset shared by the search field's contents, the
    /// result rows and the section headers.
    static let rowInset: CGFloat = 16
}

extension View {
    /// Constrain to the shared content column: capped, centred, and guttered.
    func homeContentColumn() -> some View {
        frame(maxWidth: HomeLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, HomeLayout.columnPadding)
    }
}

// MARK: - Result row

/// One openable result. Single click opens — this screen is a launcher, not a
/// file browser, and the extra click of a select-then-open interaction is the
/// exact friction issue #62 is about. Keyboard selection is shown with the
/// shared selection surface so it reads identically to a selected tab or chip.
struct HomeResultRow: View {
    let item: HomeSearchItem
    let isSelected: Bool
    let open: () -> Void
    let reveal: (() -> Void)?
    let rename: (() -> Void)?
    /// Every "forget this" action that applies, in menu order. A row can offer
    /// more than one — a saved article that is also a recent can be dropped
    /// from either shelf independently.
    let removals: [(removal: HomeSearchRemoval, action: () -> Void)]

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                icon

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        HomeBadgeStrip(badges: item.badges)
                    }
                    Text(item.subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        // Fixed so a long title can never squeeze the date
                        // column into an ellipsis; the title truncates instead.
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .padding(.horizontal, HomeLayout.rowInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionSurface(
                selected: isSelected, hovering: hovering,
                in: RoundedRectangle(cornerRadius: Radius.md), palette: palette)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(item.tooltip)
        .accessibilityIdentifier("welcome.result")
        .accessibilityLabel(item.title)
        .accessibilityValue(item.subtitle)
        .contextMenu {
            Button("Open") { open() }
            if let rename {
                Button("Rename…") { rename() }
            }
            if let reveal {
                Button("Show in Finder") { reveal() }
            }
            if !removals.isEmpty {
                Divider()
                ForEach(removals, id: \.removal) { entry in
                    Button(entry.removal.menuLabel, role: .destructive, action: entry.action)
                }
            }
        }
    }

    private var icon: some View {
        Image(systemName: item.systemImage)
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(item.badges.contains(.missing) ? AnyShapeStyle(palette.destructive)
                                                            : AnyShapeStyle(.secondary))
            .frame(width: 32, height: 32)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.separator)
            }
    }
}

/// The trailing status glyphs on a row. Each carries a tooltip, because a lone
/// symbol is only self-explanatory to the person who chose it.
struct HomeBadgeStrip: View {
    let badges: HomeSearchBadges

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 5) {
            badge(.missing, "exclamationmark.triangle.fill", "File not found at its last known location",
                  tint: palette.destructive)
            badge(.saved, "bookmark.fill", "Saved to your library", tint: palette.gold)
            badge(.offline, "arrow.down.circle.fill", "Available offline")
            badge(.notes, "note.text", "Has notes or an AI conversation")
        }
    }

    @ViewBuilder
    private func badge(
        _ flag: HomeSearchBadges, _ symbol: String, _ help: String, tint: Color? = nil
    ) -> some View {
        if badges.contains(flag) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(tint ?? palette.mutedForeground)
                .help(help)
                .accessibilityLabel(help)
        }
    }
}

// MARK: - Pinned link action

/// The "you pasted a link" row. Sits above the results and opens the URL
/// directly, so copy-a-link → read-it is two keystrokes (⌘V, ↩).
struct HomeLinkActionRow: View {
    let url: String
    let isSelected: Bool
    let open: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                    .frame(width: 32, height: 32)
                    .background(
                        palette.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Radius.md))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Open this webpage")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(palette.foreground)
                    Text(url)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: 12)

                // Hidden from VoiceOver: this row is a single button whose
                // label already says what ↩ does, and `Keycap` would otherwise
                // add a second "Keyboard shortcut" element inside it.
                Keycap(keys: "↩")
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, HomeLayout.rowInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .selectionSurface(
                selected: isSelected, hovering: hovering,
                in: RoundedRectangle(cornerRadius: Radius.md), palette: palette)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("welcome.openLink")
    }
}

// MARK: - Section header

/// Sticky section header for the result list.
struct HomeSectionHeader: View {
    let section: HomeSearchSection
    let count: Int

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: section.systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(section.title)
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .kerning(0.4)
            Text("\(count)")
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(palette.mutedForeground.opacity(0.7))
            Spacer(minLength: 0)
        }
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, HomeLayout.rowInset)
        .padding(.top, 14)
        .padding(.bottom, 6)
        // Pinned headers scroll over rows, so they need the page's own
        // background rather than transparency.
        .background(palette.well)
        .accessibilityIdentifier("welcome.section")
        .accessibilityLabel("\(section.title), \(count) items")
    }
}

// MARK: - Small controls

/// Capsule filter chip. Uses the shared `SelectionStyle` surface so it reads as
/// the same "this is current" state as the toolbar tabs and segmented thumb.
struct HomeFilterChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    SelectionStyle.foreground(palette, selected: isSelected, hovering: hovering))
                .padding(.horizontal, 12)
                .frame(height: 26)
                .selectionSurface(
                    selected: isSelected, hovering: hovering, in: Capsule(), palette: palette)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// `KeyCapsule` used to live here. It is gone in favour of `Keycap`
// (Views/Shared/Controls.swift), which #70 landed on main: this version styled
// itself with `.quaternary` / `.separator`, and those resolve from the color
// scheme rather than from our palette, so against the light parchment chrome
// they washed out to nearly nothing — the same defect that made the
// walkthrough's page dots invisible in light mode. `Keycap` uses
// `palette.muted` / `palette.borderStrong`, which are defined for both schemes.
