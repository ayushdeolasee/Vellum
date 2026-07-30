import SwiftUI
import XCTest
@testable import Vellum

final class InspectorTabSwitcherTests: XCTestCase {
    func testInspectorMinimumWidthSupportsUsableContent() {
        XCTAssertGreaterThanOrEqual(InspectorLayout.minimumWidth, 280)
        XCTAssertLessThan(InspectorLayout.minimumWidth, InspectorLayout.idealWidth)
        XCTAssertLessThan(InspectorLayout.idealWidth, InspectorLayout.maximumWidth)
    }

    /// Pins the widened envelope with literals. `InspectorLayout` is its single
    /// owner — `.inspectorColumnWidth` and `WorkspaceStore.rememberSidebarWidth`
    /// both read it, so silently restoring the old 240pt floor here would let the
    /// column shrink back below usable width for the AI composer.
    func testEnvelopeIsTheWidenedOne() {
        XCTAssertEqual(InspectorLayout.minimumWidth, 280)
        XCTAssertEqual(InspectorLayout.idealWidth, 360)
        XCTAssertEqual(InspectorLayout.maximumWidth, 700)
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

    /// Pins the `sidebarTab.*` automation contract with hardcoded literals.
    /// `UITests/ScratchpadSnapshotUITests` looks up `sidebarTab.scratchpad`; the
    /// previous control interpolated the display label and emitted
    /// `sidebarTab.Scratchpad`, so that lookup could never match. Written out
    /// rather than derived so a change to `title` cannot quietly move them.
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

    /// The header's height is a drop-routing fact as much as a layout one: it
    /// is the strip issue #101 found was not a drag target, and
    /// `SidebarDropRoutingTests` aims at its midpoint. Pinned with a literal so
    /// the drop test cannot start aiming somewhere else by accident.
    func testHeaderHeightIsTheStripTheCatcherMustCover() {
        XCTAssertEqual(InspectorLayout.switcherHeight, 30)
        XCTAssertEqual(InspectorLayout.switcherVerticalPadding, 8)
        XCTAssertEqual(InspectorLayout.headerHeight, 46)
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

    /// The collision guard, comparing the two real constants rather than a
    /// remembered value. Plain ⌘1…⌘9 already activate TABS (`VellumCommands`
    /// ▸ Navigate, from #83); binding the panels to the same chord would give
    /// two enabled menu items one key equivalent, and AppKit would hand it to
    /// whichever menu it walked first. The digits deliberately DO overlap —
    /// that is what the different modifier is for — so the modifier is the
    /// entire separation, and changing EITHER side to match the other fails
    /// here.
    func testPanelShortcutsDoNotCollideWithTabSwitching() {
        let panel = WorkspaceStore.SidebarTab.shortcutModifiers
        let tabs = VellumCommands.tabShortcutModifiers
        XCTAssertNotEqual(
            panel, tabs,
            "the inspector panels and the tab switcher claim the same chord for ⌘1/2/3")
        XCTAssertEqual(panel, [.command, .option])
        XCTAssertEqual(tabs, .command)

        // Every panel digit is inside the range the Navigate menu claims, which
        // is exactly why the modifiers have to differ.
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
