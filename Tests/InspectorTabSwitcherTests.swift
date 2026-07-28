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

    func testCollapsedControlValueReflectsEverySelection() {
        for tab in WorkspaceStore.SidebarTab.allCases {
            XCTAssertFalse(tab.title.isEmpty)
            XCTAssertEqual(tab.id, tab)
        }
    }
}
