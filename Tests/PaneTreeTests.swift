import XCTest
@testable import Vellum

// Unit tests for the split-screen layout: the WorkspaceStore tree algebra
// (split / close / merge / move) and WorkspaceState Codable round-tripping.

@MainActor
final class PaneTreeTests: XCTestCase {
    private func makeWorkspace() -> WorkspaceStore {
        WorkspaceStore(sessions: DocumentSessionManager())
    }

    // MARK: - Tree algebra

    func testStartsAsSingleLeaf() {
        let ws = makeWorkspace()
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertFalse(ws.isSplit)
    }

    func testSplitFocusedAddsPaneAndMovesFocus() {
        let ws = makeWorkspace()
        let original = ws.focusedPaneId
        ws.splitFocused(.horizontal)
        XCTAssertEqual(ws.root.allLeaves().count, 2)
        XCTAssertTrue(ws.isSplit)
        // Focus moves to the freshly created pane.
        XCTAssertNotEqual(ws.focusedPaneId, original)
        // The new pane opens on a start tab (the new-tab page).
        let newPane = ws.root.leaf(id: ws.focusedPaneId)
        XCTAssertEqual(newPane?.app.tabs.count, 1)
        XCTAssertNil(newPane?.app.document)
    }

    func testNestedSplitsAllowArbitraryDepth() {
        let ws = makeWorkspace()
        ws.splitFocused(.horizontal)
        ws.splitFocused(.vertical)
        ws.splitFocused(.horizontal)
        XCTAssertEqual(ws.root.allLeaves().count, 4)
    }

    func testClosePaneCollapsesAndReclaims() {
        let ws = makeWorkspace()
        ws.splitFocused(.horizontal)
        let toClose = ws.focusedPaneId
        ws.closePane(toClose)
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertFalse(ws.isSplit)
        XCTAssertNil(ws.root.leaf(id: toClose))
        // Focus lands on a surviving pane.
        XCTAssertNotNil(ws.root.leaf(id: ws.focusedPaneId))
    }

    func testClosingLastPaneResetsToSingleEmptyPane() {
        let ws = makeWorkspace()
        ws.closePane(ws.focusedPaneId)
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertNotNil(ws.root.leaf(id: ws.focusedPaneId))
    }

    func testMergeAllFlattensAndMigratesTabs() {
        let ws = makeWorkspace()
        // Give the initial pane a couple of start tabs.
        let first = ws.focusedPane
        first.app.newStartTab()
        first.app.newStartTab()
        let firstTabCount = first.app.tabs.count
        ws.splitFocused(.horizontal)   // new pane has 1 start tab
        XCTAssertEqual(ws.root.allLeaves().count, 2)
        // Focus the original pane, then merge: the other pane's tab migrates in.
        ws.focus(first.id)
        ws.mergeAll()
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertEqual(ws.focusedPane.app.tabs.count, firstTabCount + 1)
    }

    func testMoveTabBetweenPanes() {
        let ws = makeWorkspace()
        let source = ws.focusedPane
        source.app.newStartTab()
        let movingId = source.app.tabs.last!.id
        let sourceCount = source.app.tabs.count
        ws.splitFocused(.horizontal)
        let dest = ws.focusedPane
        let destCount = dest.app.tabs.count

        ws.moveTab(tabId: movingId, from: source.id, to: dest.id)
        XCTAssertEqual(source.app.tabs.count, sourceCount - 1)
        XCTAssertEqual(dest.app.tabs.count, destCount + 1)
        XCTAssertTrue(dest.app.tabs.contains { $0.id == movingId })
        XCTAssertEqual(ws.focusedPaneId, dest.id)
    }

    func testSetSizesUpdatesRatios() {
        let ws = makeWorkspace()
        ws.splitFocused(.horizontal)
        guard case .split(let id, _, _, _) = ws.root else {
            return XCTFail("expected a split at the root")
        }
        ws.setSizes(splitId: id, sizes: [75, 25])
        guard case .split(_, _, _, let sizes) = ws.root else {
            return XCTFail("expected a split at the root")
        }
        XCTAssertEqual(sizes, [75, 25])
    }

    // MARK: - Persistence round-trip

    func testWorkspaceStateRoundTrips() throws {
        let pdf = DocumentInfo(kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A", pageCount: 10, lastPage: 3)
        let web = DocumentInfo(kind: .web, pdfPath: "https://example.com", title: "Ex", pageCount: 1, lastPage: 1)
        let state = WorkspaceState(
            root: .split(
                direction: .horizontal,
                children: [
                    .leaf(tabs: [
                        TabDescriptor(document: pdf, currentPage: 3, zoom: 1.5, mode: .note),
                        TabDescriptor(document: nil, currentPage: 1, zoom: 1.0, mode: .view),
                    ], activeTabIndex: 0),
                    .leaf(tabs: [
                        TabDescriptor(document: web, currentPage: 1, zoom: 1.0, mode: .view),
                    ], activeTabIndex: 0),
                ],
                sizes: [60, 40]),
            focusedLeafIndex: 1)

        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(WorkspaceState.self, from: data)
        XCTAssertEqual(decoded, state)
    }

    func testSerializeReflectsLiveTree() {
        let ws = makeWorkspace()
        ws.splitFocused(.vertical)
        let state = ws.serialize()
        guard case .split(let dir, let children, _) = state.root else {
            return XCTFail("expected a split")
        }
        XCTAssertEqual(dir, .vertical)
        XCTAssertEqual(children.count, 2)
    }
}
