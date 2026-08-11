import PDFKit
import PencilKit
import UIKit
import XCTest
@testable import Vellum

// Unit tests for the split-screen layout: the WorkspaceStore tree algebra
// (split / close / merge / move), the workspace-level tab surface
// (`allTabs` / `activateWorkspaceTab` / `closeWorkspaceTab` /
// `pruneAbandonedEmptyPanes`), the `LiveTabRuntime` lifecycle the residency
// policy drives, and WorkspaceState Codable round-tripping.
//
// The runtime half lives here rather than in `TabResidencyTests` for the same
// reason main puts it here: `TabResidencyTests` proves the POLICY against a
// `FakeResident`, deliberately never touching PDFKit or WebKit, while these
// tests prove the real `LiveTabRuntime` honours the protocol the policy calls
// through — that `applyResidencyTier` actually stops the tab rendering, that
// `releaseResidency` actually gives the memory back and is safe to repeat, and
// that neither one loses user work on the way out.

@MainActor
final class PaneTreeTests: XCTestCase {
    private func makeWorkspace() -> WorkspaceStore {
        WorkspaceStore(sessions: DocumentSessionManager())
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

    private func pdfDocument(path: String) -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: path, pageCount: 4, lastPage: 1)
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

    /// The regression test for #91: `mergeAll` must TRANSFER tab ownership —
    /// detach from the donor, attach to the survivor — exactly as `moveTab`
    /// does. Copying instead leaves two AppStores claiming the same tab id, and
    /// everything keyed on tab-to-pane ownership (the web controller's mount
    /// guard, the ink registry, find and note-placement state, the residency
    /// pin) keeps resolving the tab to the pane it just left.
    func testMergeAllTransfersTabOwnershipInsteadOfCopying() {
        let ws = makeWorkspace()
        let keep = ws.focusedPane
        keep.app.attachTab(makeTab(id: "keep-a", document: pdfDocument(path: "/tmp/keep-a.pdf")))
        keep.app.attachTab(makeTab(id: "keep-b", document: pdfDocument(path: "/tmp/keep-b.pdf")))
        keep.app.activateTab("keep-a")

        ws.splitFocused(.horizontal)
        let donor = ws.focusedPane
        // `donor-a` is a WEB tab: the migrating web view is the case the issue is
        // actually about, and the only tab kind whose native state is bound to a
        // pane's stores rather than rebuilt per host.
        donor.app.attachTab(makeTab(
            id: "donor-a",
            document: DocumentInfo(
                kind: .web, pdfPath: "https://example.com", title: "Example",
                pageCount: 1, lastPage: 1)))
        donor.app.attachTab(makeTab(id: "donor-b", document: pdfDocument(path: "/tmp/donor-b.pdf")))
        let donorRuntime = ws.liveTabRuntime(for: "donor-a")

        ws.focus(keep.id)
        ws.mergeAll()

        // The donor gave the tabs up: no lingering claim on any of them. The
        // middle assertion is the one the web controller's mount guard reads.
        XCTAssertTrue(donor.app.tabs.isEmpty)
        XCTAssertNil(donor.app.activeTabId)
        XCTAssertNil(donor.app.document)

        // …and the survivor holds each exactly once, in visual order, with the
        // tabs it already had still ahead of the migrated ones. (The split's
        // own start tab rides along between them, hence the filter.)
        XCTAssertEqual(
            keep.app.tabs.map(\.id).filter { !$0.hasPrefix("start-") },
            ["keep-a", "keep-b", "donor-a", "donor-b"])
        XCTAssertEqual(keep.app.tabs.count, 5)
        XCTAssertEqual(Set(keep.app.tabs.map(\.id)).count, keep.app.tabs.count)
        // Migrating a tab must not disturb its live runtime — it is workspace
        // owned and keyed by tab id, so it follows the tab across the move.
        XCTAssertTrue(ws.liveTabRuntime(for: "donor-a") === donorRuntime)
        // The user's current document still wins over each attach's activation.
        XCTAssertEqual(keep.app.activeTabId, "keep-a")
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

    // MARK: - The workspace-level tab surface

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

    /// The other branch of the prune: a restore in which EVERY saved document
    /// was unavailable leaves nothing to keep, and collapsing to nothing is not
    /// an option — the window would have no pane at all. One Welcome pane
    /// survives, and focus has to land on a leaf that still exists.
    func testPruningWhenEveryPaneIsEmptyKeepsOneWelcomePane() {
        let ws = makeWorkspace()
        // The root pane is created without a start tab (the view that mounts it
        // supplies one), so it is already empty; emptying the split's pane too
        // leaves the tree with no non-empty leaf anywhere.
        ws.splitFocused(.horizontal)
        let temporary = ws.focusedPane
        _ = temporary.app.detachTab(temporary.app.tabs[0].id)

        ws.pruneAbandonedEmptyPanes()

        XCTAssertFalse(ws.isSplit)
        XCTAssertEqual(ws.root.allLeaves().count, 1)
        XCTAssertNotNil(
            ws.root.leaf(id: ws.focusedPaneId),
            "focus was left pointing at a pruned pane")
        XCTAssertTrue(ws.root.allLeaves()[0].app.tabs.isEmpty)
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

    /// The pane id travels with the tab precisely so a workspace-level control
    /// cannot activate or close an identically positioned tab in the wrong pane.
    /// Both guards refuse rather than guessing.
    func testWorkspaceTabActionsIgnoreATabThatIsNotInTheNamedPane() async {
        let ws = makeWorkspace()
        let firstPane = ws.focusedPane
        firstPane.app.newStartTab()
        let firstPaneTabId = firstPane.app.tabs[0].id
        ws.splitFocused(.horizontal)
        let secondPane = ws.focusedPane

        // Right tab, wrong pane.
        ws.activateWorkspaceTab(paneId: secondPane.id, tabId: firstPaneTabId)
        XCTAssertEqual(ws.focusedPaneId, secondPane.id)
        XCTAssertEqual(firstPane.app.tabs.count, 1)

        await ws.closeWorkspaceTab(paneId: secondPane.id, tabId: firstPaneTabId)
        XCTAssertEqual(firstPane.app.tabs.count, 1)
        XCTAssertNotNil(ws.root.leaf(id: firstPane.id))
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

    // MARK: - Live tab runtimes

    /// `applyResidencyTier` is the whole warm tier, seen from the runtime's
    /// side: a demotion has to stop the tab being drawn (`PaneView_iOS` reads
    /// `isRendered` to decide whether to mount the viewer at all) WITHOUT
    /// releasing anything it owns. Driven through the real store rather than by
    /// calling the method directly, so the policy's tiering is in the loop.
    func testATabPastTheHotLimitStopsRenderingButKeepsItsResources() {
        let ws = makeWorkspace()
        var runtimes: [LiveTabRuntime] = []
        // One more than the hot set holds — which is exactly `residentTabLimit`,
        // so nothing here is close to being evicted.
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

    /// Closing a tab must hand its memory back immediately rather than leaving
    /// it to the retention window — the tab is gone, not idle.
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

    /// `releaseResidency` is reached from several paths (close, ceiling, window,
    /// pressure) and must be safe to call twice: the second call must not
    /// discard the fresh controllers the first one installed, because a
    /// reactivated tab is already building on them.
    func testReleasingARuntimeTwiceIsANoOp() {
        let ws = makeWorkspace()
        let runtime = ws.liveTabRuntime(for: "twice")
        runtime.adoptPreparedPdf(PDFDocument(), byteCount: 100)
        runtime.releaseResidency()
        let controllerAfterFirst = runtime.pdfController
        let inkAfterFirst = runtime.ink

        runtime.releaseResidency()

        XCTAssertTrue(runtime.pdfController === controllerAfterFirst)
        XCTAssertTrue(runtime.ink === inkAfterFirst)
        XCTAssertTrue(runtime.isEvicted)
    }

    /// Retargeting — PDF Save As pointing a LIVE tab at a new file — is the one
    /// case where a tab keeps its identity while the bytes underneath it change.
    /// Neither `isActive` nor the view's structural identity moves, so
    /// `documentGeneration` is the only thing that can tell the mounted viewer
    /// to read the file again; `adoptPreparedPdf` deliberately does not bump it,
    /// because adopting is the ANSWER to a bump rather than a new question.
    func testRetargetingATabInvalidatesItsPdfAndBumpsTheGeneration() {
        let ws = makeWorkspace()
        let runtime = ws.liveTabRuntime(for: "retargeted")
        runtime.adoptPreparedPdf(PDFDocument(), byteCount: 2_000)
        XCTAssertEqual(runtime.documentGeneration, 0)
        XCTAssertEqual(runtime.residencyCostBytes, 2_000)

        let controllerBefore = runtime.pdfController
        runtime.invalidateLoadedPdf()

        XCTAssertEqual(runtime.documentGeneration, 1)
        XCTAssertNil(runtime.preparedDocument)
        XCTAssertEqual(runtime.residencyCostBytes, 0)
        // NOT an eviction: the tab is still resident and still owns its
        // controllers, so all the viewer has to do is re-read the file.
        XCTAssertFalse(runtime.isEvicted)
        XCTAssertTrue(runtime.pdfController === controllerBefore)

        runtime.adoptPreparedPdf(PDFDocument(), byteCount: 3_000)
        XCTAssertEqual(runtime.documentGeneration, 1)
        XCTAssertEqual(runtime.residencyCostBytes, 3_000)
    }

    /// iPad-only, and the only guard against silently losing Pencil strokes to a
    /// memory warning. Ink writes are debounced (PR #78's per-frame coalescing
    /// is exactly what makes a pending one possible), and `releaseResidency`
    /// replaces `runtime.ink` wholesale — so without the flush task and the
    /// `withExtendedLifetime` that holds the displaced controller alive until it
    /// lands, an eviction would drop real, unwritten user edits on the floor.
    ///
    /// Deliberately does not keep a strong reference to the displaced
    /// controller: the test would then be proving its own retain rather than
    /// the runtime's.
    func testEvictionDoesNotDropDebouncedInk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-evict-ink-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("evicted.pdf")
        try writeBlankDocument(pageCount: 1, to: url)

        let ws = makeWorkspace()
        let app = ws.focusedPane.app
        await app.openFile(path: url.path)
        let tabId = try XCTUnwrap(app.activeTabId)
        let runtime = ws.liveTabRuntime(for: tabId)
        ws.activateLiveTabRuntime(runtime)

        runtime.ink.app = app
        runtime.ink.drawingChanged(sampleDrawing(), page: 1)
        let inkBeforeEviction = ObjectIdentifier(runtime.ink)

        runtime.releaseResidency()

        // The runtime dropped the controller that held the pending stroke…
        XCTAssertNotEqual(ObjectIdentifier(runtime.ink), inkBeforeEviction)
        XCTAssertTrue(runtime.isEvicted)

        // …and the stroke still reached disk, written by the flush the eviction
        // itself started.
        let deadline = Date().addingTimeInterval(20)
        var landed = false
        while Date() < deadline, !landed {
            try? await Task.sleep(for: .milliseconds(100))
            if let document = PDFDocument(url: url), let page = document.page(at: 0) {
                landed = PdfInk.hasInk(on: page)
            }
        }
        XCTAssertTrue(landed, "eviction dropped a debounced stroke instead of flushing it")
    }

    // MARK: - Ink fixtures (shared with InkPersistenceTests' idiom)

    private func writeBlankDocument(pageCount: Int, to url: URL) throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let data: Data = renderer.pdfData { context in
            for _ in 0..<pageCount {
                context.beginPage()
                UIColor.white.setFill()
                UIRectFill(bounds)
            }
        }
        try data.write(to: url)
    }

    private func sampleDrawing() -> PKDrawing {
        var points: [PKStrokePoint] = []
        for index in 0..<10 {
            points.append(PKStrokePoint(
                location: CGPoint(x: 100 + index * 20, y: 200 + (index % 3) * 5),
                timeOffset: TimeInterval(index) * 0.01,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: .pi / 2))
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemIndigo), path: path)])
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
