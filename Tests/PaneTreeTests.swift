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
        let firstActiveTabId = first.app.activeTabId
        ws.splitFocused(.horizontal)   // new pane has 1 start tab
        XCTAssertEqual(ws.root.allLeaves().count, 2)
        // Focus the original pane, then merge: the other pane's tab migrates in.
        ws.focus(first.id)
        ws.mergeAll()
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertEqual(ws.focusedPane.app.tabs.count, firstTabCount + 1)
        // Merging must not steal focus from the tab the user was viewing in the
        // surviving pane, even though each migrated tab activates on attach.
        XCTAssertEqual(ws.focusedPane.app.activeTabId, firstActiveTabId)
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

    func testPruneAbandonedEmptyPanesCollapsesSplit() {
        let ws = makeWorkspace()
        let original = ws.focusedPane
        ws.splitFocused(.horizontal)
        let temporary = ws.focusedPane

        // `detachTab` mirrors an interrupted move: it leaves a live but empty
        // split leaf, exactly what a restore can produce when a saved document
        // no longer opens.
        _ = temporary.app.detachTab(temporary.app.tabs[0].id)
        ws.pruneAbandonedEmptyPanes()

        XCTAssertFalse(ws.isSplit)
        XCTAssertEqual(ws.root.leaf(id: original.id)?.id, original.id)
        XCTAssertNil(ws.root.leaf(id: temporary.id))
    }

    func testAllTabsIncludesEveryPaneAndActivationFocusesOwningPane() {
        let ws = makeWorkspace()
        let firstPane = ws.focusedPane
        firstPane.app.newStartTab()
        let firstPaneTabId = firstPane.app.tabs[1].id
        ws.splitFocused(.vertical)
        let secondPane = ws.focusedPane
        let secondPaneTabId = secondPane.app.tabs[0].id

        XCTAssertEqual(ws.allTabs.map(\.tab.id).sorted(), [
            firstPane.app.tabs[0].id, firstPaneTabId, secondPaneTabId,
        ].sorted())
        XCTAssertEqual(
            ws.allTabs.first(where: { $0.tab.id == secondPaneTabId })?.paneId,
            secondPane.id)

        ws.activateWorkspaceTab(paneId: firstPane.id, tabId: firstPaneTabId)
        XCTAssertEqual(ws.focusedPaneId, firstPane.id)
        XCTAssertEqual(firstPane.app.activeTabId, firstPaneTabId)
    }

    func testWorkspaceCloseRoutesToTheOwningPane() async {
        let ws = makeWorkspace()
        let firstPane = ws.focusedPane
        let firstPaneTabId = firstPane.app.tabs[0].id
        ws.splitFocused(.horizontal)
        let survivor = ws.focusedPane

        await ws.closeWorkspaceTab(paneId: firstPane.id, tabId: firstPaneTabId)

        XCTAssertNil(ws.root.leaf(id: firstPane.id))
        XCTAssertEqual(ws.root.leaf(id: survivor.id)?.id, survivor.id)
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

    func testSerializeDropsTransientNewTabsAndReindexesSelection() {
        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        let first = makeTab(
            id: "pdf-a",
            document: DocumentInfo(
                kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A",
                pageCount: 10, lastPage: 3))
        let second = makeTab(
            id: "web-b",
            document: DocumentInfo(
                kind: .web, pdfPath: "https://example.com", title: "Example",
                pageCount: 1, lastPage: 1))
        app.attachTab(first)
        app.newStartTab()
        app.attachTab(second)

        guard case .leaf(let tabs, let activeIndex) = ws.serialize().root else {
            return XCTFail("expected a leaf")
        }
        XCTAssertEqual(tabs.map(\.document?.title), ["A", "Example"])
        XCTAssertEqual(activeIndex, 1)
    }

    func testSerializeDoesNotRestoreAbandonedActiveNewTab() {
        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        app.attachTab(makeTab(
            id: "pdf-a",
            document: DocumentInfo(
                kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A",
                pageCount: 10, lastPage: 3)))
        app.newStartTab()

        guard case .leaf(let tabs, let activeIndex) = ws.serialize().root else {
            return XCTFail("expected a leaf")
        }
        XCTAssertEqual(tabs.count, 1)
        XCTAssertNil(activeIndex)
    }

    func testSerializePreservesDuplicateWebTabsAndTheirSelection() {
        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        let document = DocumentInfo(
            kind: .web, pdfPath: "https://example.com/article", title: "Article",
            pageCount: 1, lastPage: 1)
        app.attachTab(makeTab(id: "web-a", document: document))
        app.attachTab(makeTab(id: "web-b", document: document))

        guard case .leaf(let tabs, let activeIndex) = ws.serialize().root else {
            return XCTFail("expected a leaf")
        }
        XCTAssertEqual(tabs.map(\.document?.pdfPath), [
            "https://example.com/article", "https://example.com/article",
        ])
        XCTAssertEqual(activeIndex, 1)
    }

    func testPendingNoteAndRegionCaptureBelongToTheirTabAcrossSwitches() {
        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        let noteTabId = app.activeTabId!

        app.beginNoteWithContent("Queued AI reply")
        app.newStartTab()
        XCTAssertNil(app.pendingNoteContent)
        XCTAssertEqual(app.tabs.first(where: { $0.id == noteTabId })?.pendingNoteContent, "Queued AI reply")

        app.activateTab(noteTabId)
        XCTAssertEqual(app.mode, .note)
        XCTAssertEqual(app.pendingNoteContent, "Queued AI reply")

        app.beginRegionCapture(target: .scratchpad)
        app.newStartTab()
        app.activateTab(noteTabId)
        XCTAssertEqual(app.mode, .snapshotRegion)
        XCTAssertEqual(app.regionCaptureTarget, .scratchpad)
        XCTAssertEqual(app.tabs.first(where: { $0.id == noteTabId })?.regionCaptureTarget, .scratchpad)
        XCTAssertNil(app.pendingNoteContent)
    }

    func testInteractionCompletionKeepsTheTargetThatWasArmedBeforeReset() {
        let app = makeWorkspace().focusedPane.app

        app.beginRegionCapture(target: .scratchpad)
        XCTAssertEqual(app.finishRegionCapture(), .scratchpad)
        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.tabs.first(where: { $0.id == app.activeTabId })?.regionCaptureTarget)
    }

    func testDelayedNoteCompletionNeverClearsAnotherTabMode() {
        let app = makeWorkspace().focusedPane.app
        let originSessionId = app.activeTabId!
        app.beginNoteWithContent("Note for A")

        app.newStartTab()
        let otherSessionId = app.activeTabId!
        app.beginNoteWithContent("Note for B")

        app.finishNotePlacement(forSessionId: originSessionId)

        XCTAssertEqual(app.activeTabId, otherSessionId)
        XCTAssertEqual(app.mode, .note)
        XCTAssertEqual(app.pendingNoteContent, "Note for B")

        app.activateTab(originSessionId)
        app.finishNotePlacement(forSessionId: originSessionId)
        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
    }

    func testNotePlacementConsumesItsQueuedContentBeforeModeReset() {
        let app = makeWorkspace().focusedPane.app
        app.beginNoteWithContent("AI response")

        XCTAssertEqual(app.consumePendingNoteContent(), "AI response")
        app.finishNotePlacement(forSessionId: app.activeTabId!)

        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.pendingNoteContent)
    }

    func testCloseOthersAndCloseRightPreserveExpectedTabs() async {
        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        app.newStartTab()
        app.newStartTab()
        app.newStartTab()
        app.newStartTab()
        let ids = app.tabs.map(\.id)

        await app.closeTabsToRight(of: ids[1])
        XCTAssertEqual(app.tabs.map(\.id), Array(ids.prefix(2)))

        app.newStartTab()
        await app.closeOtherTabs(keeping: ids[1])
        XCTAssertEqual(app.tabs.map(\.id), [ids[1]])
        XCTAssertEqual(app.activeTabId, ids[1])
    }

    func testTabPresentationUsesFullTitleAndType() {
        let pdf = makeTab(
            id: "pdf",
            document: DocumentInfo(
                kind: .pdf, pdfPath: "/tmp/Fallback.pdf",
                title: "A long, fully searchable document title",
                pageCount: 10, lastPage: 1))
        let web = makeTab(
            id: "web",
            document: DocumentInfo(
                kind: .web, pdfPath: "https://example.com",
                title: "Example", pageCount: 1, lastPage: 1))
        let start = makeTab(id: "start", document: nil)

        XCTAssertEqual(TabPresentation.title(for: pdf), "A long, fully searchable document title")
        XCTAssertEqual(TabPresentation.typeLabel(for: pdf), "PDF")
        XCTAssertEqual(TabPresentation.typeLabel(for: web), "Webpage")
        XCTAssertEqual(TabPresentation.title(for: start), "New Tab")
    }

    private func makeTab(id: String, document: DocumentInfo?) -> PdfTab {
        PdfTab(
            id: id,
            document: document,
            currentPage: 1,
            numPages: document?.pageCount ?? 0,
            zoom: 1,
            visiblePages: [],
            webVisibleRange: nil,
            webVisibleBookmarks: [],
            mode: .view)
    }
}
