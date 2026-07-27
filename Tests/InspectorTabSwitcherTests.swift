import XCTest
@testable import Vellum

final class InspectorTabSwitcherTests: XCTestCase {
    func testInspectorMinimumWidthSupportsUsableContent() {
        XCTAssertGreaterThanOrEqual(InspectorLayout.minimumWidth, 280)
        XCTAssertLessThan(InspectorLayout.minimumWidth, InspectorLayout.idealWidth)
        XCTAssertLessThan(InspectorLayout.idealWidth, InspectorLayout.maximumWidth)
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
