import PDFKit
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
        let closingTabId = ws.focusedPane.app.activeTabId!
        _ = ws.liveTabRuntime(for: closingTabId)
        ws.closePane(toClose)
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertFalse(ws.isSplit)
        XCTAssertNil(ws.root.leaf(id: toClose))
        XCTAssertNil(ws.existingLiveTabRuntime(for: closingTabId))
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
        let runtimeBeforeMove = ws.liveTabRuntime(for: movingId)
        let sourceCount = source.app.tabs.count
        ws.splitFocused(.horizontal)
        let dest = ws.focusedPane
        let destCount = dest.app.tabs.count

        ws.moveTab(tabId: movingId, from: source.id, to: dest.id)
        XCTAssertEqual(source.app.tabs.count, sourceCount - 1)
        XCTAssertEqual(dest.app.tabs.count, destCount + 1)
        XCTAssertTrue(dest.app.tabs.contains { $0.id == movingId })
        XCTAssertEqual(ws.focusedPaneId, dest.id)
        XCTAssertTrue(ws.liveTabRuntime(for: movingId) === runtimeBeforeMove)
    }

    func testFindStateFollowsItsDocumentTab() {
        let app = makeWorkspace().focusedPane.app
        let pdf = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A",
            pageCount: 10, lastPage: 1)
        let web = DocumentInfo(
            kind: .web, pdfPath: "https://example.com", title: "Example",
            pageCount: 1, lastPage: 1)
        app.attachTab(PdfTab(
            id: "pdf", document: pdf, currentPage: 1, numPages: 10,
            zoom: 1, visiblePages: [], webVisibleRange: nil,
            webVisibleBookmarks: [], mode: .view))
        app.showFind()
        app.performFind("retained query")
        app.setFindResults(count: 4, current: 2)

        app.attachTab(PdfTab(
            id: "web", document: web, currentPage: 1, numPages: 1,
            zoom: 1, visiblePages: [], webVisibleRange: nil,
            webVisibleBookmarks: [], mode: .view))
        XCTAssertFalse(app.findVisible)
        XCTAssertEqual(app.findQuery, "")
        app.showFind()
        app.performFind("web query")
        app.setFindResults(count: 2, current: 1)

        app.activateTab("pdf")
        XCTAssertTrue(app.findVisible)
        XCTAssertEqual(app.findQuery, "retained query")
        XCTAssertEqual(app.findMatchCount, 4)
        XCTAssertEqual(app.findCurrentMatch, 2)

        app.activateTab("web")
        XCTAssertTrue(app.findVisible)
        XCTAssertEqual(app.findQuery, "web query")
        XCTAssertEqual(app.findMatchCount, 2)
        XCTAssertEqual(app.findCurrentMatch, 1)
    }

    func testLiveRuntimeTextIsIsolatedPerTab() {
        let ws = makeWorkspace()
        let first = ws.liveTabRuntime(for: "first")
        let second = ws.liveTabRuntime(for: "second")
        first.pageTexts = [1: "first page"]
        second.pageTexts = [1: "second page"]

        XCTAssertEqual(first.pageTexts[1], "first page")
        XCTAssertEqual(second.pageTexts[1], "second page")
    }

    /// The workspace hands every activated runtime to the residency policy, so
    /// the tab ceiling bounds how many tabs hold native state at once. The trim
    /// is deferred by one main-actor hop (see
    /// `TabResidencyManager.scheduleCeilingEnforcement`), hence the yield.
    func testLiveRuntimeLimitEvictsLeastRecentlyUsedInactiveTab() async {
        let ws = makeWorkspace()
        var runtimes: [LiveTabRuntime] = []
        for index in 0...TabResidencyManager.residentTabLimit {
            let runtime = ws.liveTabRuntime(for: "runtime-\(index)")
            ws.activateLiveTabRuntime(runtime)
            runtimes.append(runtime)
        }

        var spins = 0
        while ws.residency.residentTabCount > TabResidencyManager.residentTabLimit, spins < 100 {
            await Task.yield()
            spins += 1
        }

        XCTAssertEqual(ws.residency.residentTabCount, TabResidencyManager.residentTabLimit)
        XCTAssertTrue(runtimes[0].isEvicted)
        XCTAssertFalse(runtimes.last!.isEvicted)
    }

    func testMemoryPressureEvictsInactiveButKeepsActiveRuntime() {
        let ws = makeWorkspace()
        ws.focusedPane.app.newStartTab()
        let activeId = ws.focusedPane.app.activeTabId!
        let active = ws.liveTabRuntime(for: activeId)
        let inactive = ws.liveTabRuntime(for: "inactive")
        let inactiveWebController = inactive.webController
        inactive.pageTexts = [1: "retained extraction"]
        ws.activateLiveTabRuntime(active)
        ws.activateLiveTabRuntime(inactive)

        // `.critical` is the harshest level the system can report: everything
        // off screen goes. The pane's own tab is pinned and must survive it.
        ws.residency.handleMemoryPressure(.critical)

        XCTAssertFalse(active.isEvicted)
        XCTAssertTrue(inactive.isEvicted)
        XCTAssertFalse(inactive.webController === inactiveWebController)
        // Page text is deliberately kept across eviction: cheap, and it keeps
        // the AI context truthful while the viewer restores.
        XCTAssertEqual(inactive.pageTexts[1], "retained extraction")
    }

    /// Closing a tab must hand its memory back immediately rather than leaving
    /// it to the two-hour window — the tab is gone, not idle.
    func testClosingATabReleasesItsRuntimeImmediately() {
        let ws = makeWorkspace()
        let runtime = ws.liveTabRuntime(for: "doomed")
        ws.activateLiveTabRuntime(runtime)
        XCTAssertTrue(ws.residency.isResident(tabId: "doomed"))

        ws.removeLiveTabRuntime(for: "doomed")

        XCTAssertFalse(ws.residency.isResident(tabId: "doomed"))
        XCTAssertTrue(runtime.isEvicted)
        XCTAssertNil(ws.existingLiveTabRuntime(for: "doomed"))
    }

    /// A split window shows two documents at once; the policy must pin one tab
    /// per pane, not one per window, or the second pane's document would be
    /// evictable while the user is looking at it.
    func testEachPanePinsItsOwnTabAgainstCriticalPressure() {
        let ws = makeWorkspace()
        ws.focusedPane.app.newStartTab()
        let firstId = ws.focusedPane.app.activeTabId!
        ws.splitFocused(.horizontal)
        let secondId = ws.focusedPane.app.activeTabId!
        XCTAssertNotEqual(firstId, secondId)
        for id in [firstId, secondId] {
            ws.activateLiveTabRuntime(ws.liveTabRuntime(for: id))
        }

        ws.residency.handleMemoryPressure(.critical)

        XCTAssertEqual(ws.residency.residentTabIds, [firstId, secondId])
    }

    /// The middle tier, end to end through the real store: a sixth tab pushes
    /// the oldest out of the hot 5, which stops it being rendered — `PaneView`
    /// reads `isRendered` to decide whether to mount the viewer at all — without
    /// releasing anything it owns.
    func testSixthTabStopsRenderingButKeepsItsResources() {
        let ws = makeWorkspace()
        var runtimes: [LiveTabRuntime] = []
        for index in 0...TabResidencyManager.hotTabLimit {
            let runtime = ws.liveTabRuntime(for: "hot-\(index)")
            runtime.adoptPreparedPdf(PDFDocument(), byteCount: 1_000)
            ws.activateLiveTabRuntime(runtime)
            runtimes.append(runtime)
        }

        XCTAssertFalse(runtimes[0].isRendered)
        XCTAssertFalse(runtimes[0].isEvicted)
        XCTAssertNotNil(runtimes[0].preparedDocument)
        XCTAssertTrue(ws.residency.isResident(tabId: "hot-0"))
        for runtime in runtimes.dropFirst() { XCTAssertTrue(runtime.isRendered) }
    }

    /// Re-selecting a warm tab must put it straight back on screen, and must do
    /// it by re-parenting the native view it still owns rather than reloading.
    func testReactivatingAWarmRuntimeRendersItWithoutReloading() {
        let ws = makeWorkspace()
        var runtimes: [LiveTabRuntime] = []
        for index in 0...TabResidencyManager.hotTabLimit {
            let runtime = ws.liveTabRuntime(for: "warm-\(index)")
            runtime.adoptPreparedPdf(PDFDocument(), byteCount: 1_000)
            ws.activateLiveTabRuntime(runtime)
            runtimes.append(runtime)
        }
        let demoted = runtimes[0]
        let controllerWhileWarm = demoted.pdfController
        let documentWhileWarm = demoted.preparedDocument
        XCTAssertFalse(demoted.isRendered)

        ws.activateLiveTabRuntime(demoted)

        XCTAssertTrue(demoted.isRendered)
        XCTAssertFalse(demoted.isEvicted)
        // Same controller, same parsed document: nothing was rebuilt.
        XCTAssertTrue(demoted.pdfController === controllerWhileWarm)
        XCTAssertTrue(demoted.preparedDocument === documentWhileWarm)
    }

    /// The byte budget is only meaningful if a tab reports what it actually
    /// holds: nothing before it has loaded, its file size once a PDF is parsed,
    /// and nothing again after eviction. The last one is the important half —
    /// if the runtime kept the parsed document, the memory the eviction existed
    /// to reclaim would still be held.
    func testRuntimeCostsNothingBeforeLoadAndNothingAfterEviction() {
        let ws = makeWorkspace()
        let runtime = ws.liveTabRuntime(for: "sized")
        XCTAssertEqual(runtime.residencyCostBytes, 0)

        runtime.adoptPreparedPdf(PDFDocument(), byteCount: 4_000_000)
        XCTAssertEqual(runtime.residencyCostBytes, 4_000_000)

        runtime.releaseResidency()
        XCTAssertNil(runtime.preparedDocument)
        XCTAssertEqual(runtime.residencyCostBytes, 0)
    }

    /// `releaseResidency` is reached from several paths (close, ceiling, window,
    /// pressure) and must be safe to call twice.
    func testReleasingARuntimeTwiceIsANoOp() {
        let ws = makeWorkspace()
        let runtime = ws.liveTabRuntime(for: "twice")
        runtime.adoptPreparedPdf(PDFDocument(), byteCount: 100)
        runtime.releaseResidency()
        let controllerAfterFirst = runtime.pdfController

        runtime.releaseResidency()

        XCTAssertTrue(runtime.pdfController === controllerAfterFirst)
        XCTAssertTrue(runtime.isEvicted)
    }

    func testPdfControllerActiveGateFollowsReboundPane() {
        let ws = makeWorkspace()
        let source = ws.focusedPane
        source.app.newStartTab()
        let tabId = source.app.activeTabId!
        let runtime = ws.liveTabRuntime(for: tabId)
        runtime.pdfController.rebind(
            app: source.app,
            annotationStore: source.annotations,
            ai: source.ai,
            tabId: tabId,
            runtime: runtime)
        XCTAssertTrue(runtime.pdfController.isActiveMount)

        source.app.newStartTab()
        XCTAssertFalse(runtime.pdfController.isActiveMount)
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
        // A pane only gets its start tab from the view that mounts it, so the
        // root pane starts empty here — give it one, or the prune below has two
        // empty leaves to choose from and proves nothing.
        original.app.newStartTab()
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
        firstPane.app.newStartTab()
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
        app.newStartTab()
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
        app.newStartTab()

        app.beginRegionCapture(target: .scratchpad)
        XCTAssertEqual(app.finishRegionCapture(), .scratchpad)
        XCTAssertEqual(app.mode, .view)
        XCTAssertNil(app.tabs.first(where: { $0.id == app.activeTabId })?.regionCaptureTarget)
    }

    func testDelayedNoteCompletionNeverClearsAnotherTabMode() {
        let app = makeWorkspace().focusedPane.app
        app.newStartTab()
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
        app.newStartTab()
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

    /// A tab switch has to carry three separate pieces of state, and they were
    /// added by three different changes that all land in `applyActiveState`:
    /// the incoming tab's find query (window chrome that became document work),
    /// its queued "Add as note" reply and capture target, and its residency pin
    /// — without which the policy could evict the document now on screen.
    func testTabSwitchRestoresFindAndNoteStateAndPinsTheIncomingTab() {
        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        let first = makeTab(
            id: "pdf-a",
            document: DocumentInfo(
                kind: .pdf, pdfPath: "/tmp/a.pdf", title: "A", pageCount: 10, lastPage: 1))
        let second = makeTab(
            id: "pdf-b",
            document: DocumentInfo(
                kind: .pdf, pdfPath: "/tmp/b.pdf", title: "B", pageCount: 4, lastPage: 1))

        app.attachTab(first)
        app.showFind()
        app.performFind("chapter")
        app.beginNoteWithContent("Queued AI reply")

        app.attachTab(second)
        XCTAssertFalse(app.findVisible)
        XCTAssertNil(app.pendingNoteContent)
        XCTAssertEqual(ws.residency.hotTabIds, ["pdf-b"])

        app.activateTab("pdf-a")
        XCTAssertTrue(app.findVisible)
        XCTAssertEqual(app.findQuery, "chapter")
        XCTAssertEqual(app.mode, .note)
        XCTAssertEqual(app.pendingNoteContent, "Queued AI reply")
        XCTAssertEqual(ws.residency.hotTabIds, ["pdf-a"])
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
