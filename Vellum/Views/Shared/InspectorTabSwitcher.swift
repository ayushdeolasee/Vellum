import SwiftUI

enum InspectorLayout {
    // The one definition of the inspector's resize envelope. `PaneShell_iOS`
    // hands these straight to `.inspectorColumnWidth(min:ideal:max:)` and
    // `WorkspaceStore.rememberSidebarWidth` clamps to the same numbers, so a
    // second copy would either reject widths the host can legitimately produce
    // or remember ones it immediately overrides.
    //
    // Owned here rather than on `WorkspaceStore` for isolation reasons: the
    // store is `@MainActor`, so its statics are main-actor-isolated and cannot
    // seed a nonisolated type's stored defaults. This enum is nonisolated, and
    // the store can read it freely from the main actor.
    //
    // The floor is 280 because below that the AI composer and the annotation
    // rows are too cramped to use.
    static let minimumWidth: CGFloat = 280
    static let idealWidth: CGFloat = 360
    /// iPad ceiling: 560, not macOS's 700. 700 pt is over half the width of an
    /// 11" iPad in portrait and nearly all of a Split View pane. 560 is exactly
    /// the envelope `ContentView_iOS` already shipped, so pinning it here is not
    /// a user-visible regression — it just gives that number one owner.
    static let maximumWidth: CGFloat = 560

    /// Full titles fit comfortably at the default inspector width. At the
    /// minimum width, icons keep every destination visible without truncation.
    static let fullLabelsMinimumWidth: CGFloat = 320
    static let iconsMinimumWidth: CGFloat = 170

    /// Inset applied to the switcher inside the inspector column.
    static let switcherHorizontalPadding: CGFloat = 12
    static let switcherVerticalPadding: CGFloat = 8
    /// A real 44pt segment. Padding around a Button does not enlarge that
    /// Button's accessibility frame, so the control itself owns the HIG floor.
    static let switcherHeight: CGFloat = 44

    /// Height of the inspector's header row — the control plus its inset,
    /// stopping above the divider. On iPad this is a layout fact only: main's
    /// version of this comment is about the AppKit `SidebarDropCatcher`, which
    /// the iPad deliberately does not port (it keeps its iOS-native drop
    /// rebuild), so do not go looking for a catcher this number serves.
    static var headerHeight: CGFloat { switcherHeight + switcherVerticalPadding * 2 }

    /// The narrowest width the switcher can actually be handed: the column
    /// cannot go below `minimumWidth`, and the switcher is inset inside it.
    /// `presentation(for:)` must still keep all three destinations laid out
    /// side by side here — see `InspectorTabSwitcherTests`. The `.menu`
    /// fallback below therefore should not be reachable in a normal window; it
    /// is kept only for the case where the host squeezes the column past its
    /// own stated minimum, so that a stranded user still has a way to switch.
    static var narrowestContentWidth: CGFloat {
        minimumWidth - switcherHorizontalPadding * 2
    }

    enum Presentation: Equatable {
        case fullLabels
        case icons
        case menu
    }

    static func presentation(for width: CGFloat) -> Presentation {
        if width >= fullLabelsMinimumWidth { return .fullLabels }
        if width >= iconsMinimumWidth { return .icons }
        return .menu
    }
}

extension WorkspaceStore.SidebarTab: Identifiable {
    var id: Self { self }

    var title: String {
        switch self {
        case .annotations: "Annotations"
        case .ai: "AI"
        case .scratchpad: "Scratchpad"
        }
    }

    var systemImage: String {
        switch self {
        case .annotations: "highlighter"
        case .ai: "sparkles"
        case .scratchpad: "note.text"
        }
    }

    /// Stem of the `sidebarTab.*` automation identifier. The case name, NOT
    /// `title`: lowercase is the convention `GlassSegmentedPicker` documented —
    /// but that control interpolated the display label, so on iPad it actually
    /// emitted `sidebarTab.Annotations` and anything automating the sidebar
    /// could never match. Deriving the identifier from the case rather than the
    /// visible title also means renaming a panel cannot silently break
    /// automation.
    var accessibilityIdentifierStem: String {
        switch self {
        case .annotations: "annotations"
        case .ai: "ai"
        case .scratchpad: "scratchpad"
        }
    }

    /// The full identifier each destination control carries, in every layout.
    var accessibilityIdentifier: String { "sidebarTab.\(accessibilityIdentifierStem)" }

    /// Digit of the shortcut that reveals this panel.
    ///
    /// Numbered in `allCases` order, so the shortcut matches the left-to-right
    /// order of the switcher itself rather than an independent list that could
    /// drift from it.
    var shortcutDigit: Character {
        switch self {
        case .annotations: "1"
        case .ai: "2"
        case .scratchpad: "3"
        }
    }

    /// ⌥⌘, not plain ⌘: ⌘1…⌘9 already switch TABS (#83), and a tab is the thing
    /// most users reach for first. ⌥⌘ is also the prefix the neighbouring
    /// inspector commands already use — ⌥⌘S toggles the inspector, ⌥⌘\ and ⌥⌘J
    /// drive the splits.
    static let shortcutModifiers: EventModifiers = [.command, .option]
}

/// Responsive navigation for the inspector's three persistent panels.
///
/// This intentionally lives inside the inspector instead of the toolbar: the
/// toolbar may collapse items into an overflow menu at narrow widths, and the
/// synthesized overflow previously exposed only one section. Keeping the
/// control here guarantees that all destinations remain reachable.
struct InspectorTabSwitcher: View {
    @Binding var selection: WorkspaceStore.SidebarTab

    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Hovered segment, so an unselected one can preview the selection surface
    /// the way the annotation filter chips and Home rows do. Kept on iPad
    /// because `.onHover` fires for a trackpad or Magic Mouse pointer — it is a
    /// real iPad affordance, not dead macOS code.
    @State private var hovering: WorkspaceStore.SidebarTab?

    @ViewBuilder
    var body: some View {
#if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            compactMenu
                .frame(minHeight: InspectorLayout.switcherHeight)
        } else {
            sizedSwitcher
        }
#else
        sizedSwitcher
#endif
    }

    private var sizedSwitcher: some View {
        GeometryReader { proxy in
            switch InspectorLayout.presentation(for: proxy.size.width) {
            case .fullLabels:
                segmentedControl(showTitles: true)
            case .icons:
                segmentedControl(showTitles: false)
            case .menu:
                compactMenu
            }
        }
        .frame(height: InspectorLayout.switcherHeight)
        .accessibilityElement(children: .contain)
    }

    private func segmentedControl(showTitles: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceStore.SidebarTab.allCases) { tab in
                let isSelected = selection == tab
                let isHovering = hovering == tab
                Button {
                    selection = tab
                } label: {
                    Group {
                        if showTitles {
                            Label(tab.title, systemImage: tab.systemImage)
                                .labelStyle(.titleAndIcon)
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        } else {
                            Label(tab.title, systemImage: tab.systemImage)
                                .labelStyle(.iconOnly)
                        }
                    }
                    // KEEP THIS PLACEMENT. On macOS `.buttonStyle(.plain)`
                    // hit-tests against the label's rendered content, so the
                    // expanding frame has to be inside the label closure to
                    // widen the tap target. UIKit's hit test is frame-based and
                    // would forgive the outer placement — but the whole-segment
                    // target is a touch requirement here too, and keeping the
                    // two platforms structurally identical is what stops the
                    // next port from re-introducing #112.
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                // All three parts of the shared selection language — tinted
                // label, tinted fill, hairline edge — exactly as the annotation
                // filter chips and the Home result rows use it, and as the
                // picker this control replaced used the fill and edge.
                //
                // NOT `.quaternary` / `.separator`: those resolve from the color
                // scheme rather than from our palette, which disappears on the
                // parchment palette. Selected reads as *indigo*, in both
                // schemes, rather than as a slightly different shade of grey.
                .foregroundStyle(
                    SelectionStyle.foreground(palette, selected: isSelected, hovering: isHovering))
                .selectionSurface(
                    selected: isSelected, hovering: isHovering, in: Capsule(), palette: palette)
                .onHover { hovering = $0 ? tab : nil }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier(tab.accessibilityIdentifier)
            }
        }
        .font(.callout)
        .padding(2)
        // The recessed track behind the thumb, from the palette for the same
        // reason: `muted` is defined for both schemes and stays visible against
        // parchment, where a scheme-derived quaternary wash does not.
        .background(palette.muted, in: Capsule())
    }

    private var compactMenu: some View {
        Menu {
            ForEach(WorkspaceStore.SidebarTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label {
                        Text(tab.title)
                    } icon: {
                        Image(systemName: selection == tab ? "checkmark" : tab.systemImage)
                    }
                }
                .accessibilityIdentifier(tab.accessibilityIdentifier)
            }
        } label: {
            Label(selection.title, systemImage: selection.systemImage)
                .frame(maxWidth: .infinity)
        }
        // `.borderlessButton` is macOS-only; `.button` + `.plain` is the iOS
        // equivalent that keeps the label from acquiring a bordered chrome.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .accessibilityLabel("Inspector section")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("sidebarTab.menu")
    }
}
