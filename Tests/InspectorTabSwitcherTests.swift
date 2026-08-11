import SwiftUI
import XCTest
@testable import Vellum

// `InspectorLayout` — the inspector column's resize envelope, the responsive
// breakpoints the tab switcher picks a presentation from, and the `sidebarTab.*`
// automation identifiers.
//
// Two of the numbers here are NOT main's, and both changes are deliberate:
//
//   * `maximumWidth` is 560, not 700. 700 pt is over half the width of an 11"
//     iPad in portrait and nearly the whole of a Split View pane.
//   * `switcherHeight` is 44, not 30. The Button itself owns the HIG touch
//     target; padding around a smaller control does not enlarge its AX frame.
//
// Everything else — the 280 floor, the 360 ideal, the three breakpoints, the
// identifier convention — is shared with main, on purpose: they are the numbers
// `.inspectorColumnWidth` and `WorkspaceStore.rememberSidebarWidth` both read,
// and a second opinion about them is how the column ends up rejecting widths
// its own host can produce.
final class InspectorTabSwitcherTests: XCTestCase {
    func testInspectorMinimumWidthSupportsUsableContent() {
        XCTAssertGreaterThanOrEqual(InspectorLayout.minimumWidth, 280)
        XCTAssertLessThan(InspectorLayout.minimumWidth, InspectorLayout.idealWidth)
        XCTAssertLessThan(InspectorLayout.idealWidth, InspectorLayout.maximumWidth)
    }

    /// Pins the envelope with literals. `InspectorLayout` is its single owner —
    /// `.inspectorColumnWidth` and `WorkspaceStore.rememberSidebarWidth` both
    /// read it, so silently restoring the old 240pt floor here would let the
    /// column shrink back below usable width for the AI composer.
    ///
    /// The ceiling is the one number that is deliberately NOT main's. macOS
    /// widened it to 700; the iPad keeps 560, which is what `ContentView_iOS`
    /// already shipped. On an 11" iPad in portrait 700 pt is more than half the
    /// screen, and in Split View it is very nearly the whole pane — so "match
    /// main" here would be a regression, not parity.
    func testEnvelopeIsTheWidenedOne() {
        XCTAssertEqual(InspectorLayout.minimumWidth, 280)
        XCTAssertEqual(InspectorLayout.idealWidth, 360)
        XCTAssertEqual(InspectorLayout.maximumWidth, 560)
    }

    /// The invariant that actually protects the user: at the narrowest width the
    /// switcher can really be handed — the column's own minimum, less its inset —
    /// all three destinations must still be laid out side by side. If a future
    /// change raises `iconsMinimumWidth` past that floor, every window would
    /// collapse the switcher into a menu, and this fails.
    func testNarrowestRealInspectorStillShowsEveryDestinationInline() {
        XCTAssertLessThan(InspectorLayout.narrowestContentWidth, InspectorLayout.minimumWidth)
        XCTAssertEqual(
            InspectorLayout.presentation(for: InspectorLayout.narrowestContentWidth),
            .icons)
    }

    /// Pins the `sidebarTab.*` automation contract with hardcoded literals. The
    /// previous control interpolated the display label and emitted
    /// `sidebarTab.Scratchpad`, so anything automating the sidebar by identifier
    /// could never match. Written out rather than derived so a change to `title`
    /// cannot quietly move them.
    ///
    /// (Main's version of this comment cites `UITests/ScratchpadSnapshotUITests`
    /// as the consumer. The iPad has no XCUITest target, so the identifiers have
    /// no automated caller today — the contract is kept anyway because it is
    /// free, and because it is the thing an iOS UI-test target would need on
    /// day one.)
    func testAccessibilityIdentifiersMatchTheAutomationConvention() {
        XCTAssertEqual(
            WorkspaceStore.SidebarTab.allCases.map(\.accessibilityIdentifier),
            ["sidebarTab.annotations", "sidebarTab.ai", "sidebarTab.scratchpad"])
        for tab in WorkspaceStore.SidebarTab.allCases {
            XCTAssertEqual(
                tab.accessibilityIdentifier,
                "sidebarTab.\(tab.accessibilityIdentifierStem)")
            XCTAssertEqual(
                tab.accessibilityIdentifierStem,
                tab.accessibilityIdentifierStem.lowercased())
        }
    }

    /// The header's height is a TOUCH-TARGET fact on iOS. The segment itself is
    /// 44pt; the surrounding padding positions it but does not count toward the
    /// Button's accessibility frame.
    ///
    /// (Main names this `…IsTheStripTheCatcherMustCover` because there the
    /// number is a drop-routing fact: `SidebarDropRoutingTests` aims at the
    /// strip's midpoint. The iPad does not port the AppKit `SidebarDropCatcher`,
    /// so there is no catcher this number serves and the name would send the
    /// next reader looking for one that does not exist.)
    func testHeaderHeightMatchesTheSwitcherPlusItsInset() {
        XCTAssertEqual(InspectorLayout.switcherHeight, 44)
        XCTAssertEqual(InspectorLayout.switcherVerticalPadding, 8)
        XCTAssertEqual(InspectorLayout.headerHeight, 60)
        // Stated as the relationship too, so a padding change cannot leave the
        // two literals above quietly inconsistent.
        XCTAssertEqual(
            InspectorLayout.headerHeight,
            InspectorLayout.switcherHeight + InspectorLayout.switcherVerticalPadding * 2)
        // The reason the number moved at all.
        XCTAssertGreaterThanOrEqual(InspectorLayout.headerHeight, 44)
    }

    func testPresentationRespondsAtEachWidthClass() {
        XCTAssertEqual(
            InspectorLayout.presentation(for: InspectorLayout.idealWidth),
            .fullLabels)
        XCTAssertEqual(
            InspectorLayout.presentation(for: InspectorLayout.minimumWidth),
            .icons)
        XCTAssertEqual(InspectorLayout.presentation(for: 140), .menu)
    }

    func testEveryPresentationRetainsAllDestinations() {
        XCTAssertEqual(
            WorkspaceStore.SidebarTab.allCases,
            [.annotations, .ai, .scratchpad])
        XCTAssertEqual(
            WorkspaceStore.SidebarTab.allCases.map(\.title),
            ["Annotations", "AI", "Scratchpad"])
        XCTAssertEqual(
            Set(WorkspaceStore.SidebarTab.allCases.map(\.systemImage)).count,
            WorkspaceStore.SidebarTab.allCases.count)
    }

    /// The panel shortcuts follow the switcher's own left-to-right order, so
    /// ⌥⌘2 always means "the middle one". Written out rather than derived from
    /// `allCases` so reordering the panels has to be a deliberate decision here.
    func testPanelShortcutDigitsFollowTheSwitcherOrder() {
        XCTAssertEqual(
            WorkspaceStore.SidebarTab.allCases.map(\.shortcutDigit),
            ["1", "2", "3"])
        XCTAssertEqual(WorkspaceStore.SidebarTab.annotations.shortcutDigit, "1")
        XCTAssertEqual(WorkspaceStore.SidebarTab.ai.shortcutDigit, "2")
        XCTAssertEqual(WorkspaceStore.SidebarTab.scratchpad.shortcutDigit, "3")
    }

    /// Half of main's collision guard: the panel side of the contract. The
    /// digits deliberately DO overlap with ⌘1…⌘9 tab switching — the modifier is
    /// the entire separation — so this pins that the panels claim ⌥⌘ and that
    /// every digit they claim is inside the range tab switching also uses.
    ///
    /// The other half of main's test compares against
    /// `VellumCommands.tabShortcutModifiers`, which is macOS-gated and cannot
    /// compile here. The iPad equivalent lives in `KeyboardShortcutsTests`
    /// (`testPanelRevealChordsAreDistinctFromTabSwitching` for this exact pair,
    /// and `testNoChordIsBoundTwice` for the whole catalogue) because on iPad
    /// the chords are rows in `VellumShortcutCatalog` rather than key
    /// equivalents on menu items. It is not duplicated here.
    func testPanelShortcutsClaimTheOptionCommandChord() {
        XCTAssertEqual(WorkspaceStore.SidebarTab.shortcutModifiers, [.command, .option])

        // Every panel digit is inside the range tab switching claims, which is
        // exactly why the modifiers have to differ.
        for tab in WorkspaceStore.SidebarTab.allCases {
            XCTAssertTrue(
                ("1"..."9").contains(tab.shortcutDigit),
                "\(tab.shortcutDigit) is not a digit the switcher can reach")
        }
    }

    func testCollapsedControlValueReflectsEverySelection() {
        for tab in WorkspaceStore.SidebarTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertEqual(tab.id, tab)
        }
    }
}
