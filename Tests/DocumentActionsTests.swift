import CoreGraphics
import CoreText
import PDFKit
import XCTest
@testable import Vellum

/// Document-level actions that outlive the gesture that started them: a close's
/// backend teardown, and the rename that hangs off the same #113 work.
///
/// PORT NOTE (parity #129, packet 4 §2.14 / packet 9 Stage 4). main's copy of
/// this suite is eight tests. Five of them exercise `AppStore.savePdfAs`, which
/// iPad does not have and is not getting under §2.14 — Save As on macOS is an
/// `NSSavePanel` that RETARGETS the live tab to a new file, and the iPad's
/// document actions are "Export a Copy…" (a share sheet that leaves the tab
/// alone) and Rename (a title override that never touches the file). §2.14
/// names `AppStore.renameDocument(tabId:title:)` as the iPad's "Save As state"
/// for exactly that reason, so the Save As group is replaced by the rename
/// group below rather than dropped silently.
///
/// A sixth, `testWebActionIdentityRejectsSameSessionAfterNavigation`, needs
/// `AppStore.WebDocumentActionIdentity` / `activeWebDocumentActionIdentity()` /
/// `isCurrentWebDocument(_:)`. Those are not in §2.14's scope and have no owner
/// on iPad yet (packet 1 §2.17 lists them as belonging to another packet); the
/// test comes back with them.
///
/// The two teardown-race tests are the ones §2.14 exists for and are ported as
/// they stand.
@MainActor
final class DocumentActionsTests: XCTestCase {
    private var tempDirectory: URL!
    private var workspaces: [WorkspaceStore] = []
    private var positionGates: [GatedPositionWrite] = []

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-document-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)
        PdfDocIdRegistry.reset()
    }

    override func tearDown() async throws {
        // A timeout must unblock and drain every parked close before deleting fixtures.
        for gate in positionGates { gate.release() }
        for workspace in workspaces {
            await workspace.tabTeardowns.awaitAll()
            await workspace.positions.flush()
            for pane in workspace.root.allLeaves() {
                for tab in pane.app.tabs { await pane.app.closeTab(tab.id) }
            }
            await workspace.tabTeardowns.awaitAll()
        }
        positionGates = []
        workspaces = []
        PdfDocIdRegistry.reset()
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    // MARK: - Close teardowns (#113)

    /// The reopen-races-teardown guard must work ACROSS panes. Teardowns are
    /// registered workspace-wide: a close in one pane — here one that also
    /// collapses that pane, discarding its AppStore — must still park an
    /// immediate reopen of the same file from another pane until the close's
    /// position write has landed. With per-pane tracking the reopen sailed
    /// through: it read the pre-teardown bytes (stale reading position) and
    /// anything it wrote was clobbered by the teardown's atomic rename.
    func testReopenInAnotherPaneWaitsOutCollapsedPanesTeardown() async throws {
        let file = tempDirectory.appendingPathComponent("Shared.pdf")
        makePDF(at: file, pages: 4)

        let gate = GatedPositionWrite()
        let workspace = makeWorkspace(gate: gate)
        let paneA = workspace.focusedPane
        await paneA.app.openFile(path: file.path)
        let tabId = try XCTUnwrap(paneA.app.activeTabId)
        paneA.app.setCurrentPage(3)
        await workspace.awaitPendingPositionRecords()

        workspace.splitFocused(.horizontal)
        let paneB = workspace.focusedPane
        XCTAssertNotEqual(paneA.id, paneB.id)

        // Park the teardown's position write at the gate, then close pane A's
        // only tab. The pane collapses, so only the workspace registry still
        // knows a teardown holds this file.
        gate.holdNextWrite()
        await paneA.app.closeTab(tabId)
        XCTAssertNil(workspace.root.leaf(id: paneA.id))
        try await gate.waitUntilHeld()

        let reopen = Task { await paneB.app.openFile(path: file.path) }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertNil(paneB.app.document, "the reopen must wait for the pending teardown")

        gate.release()
        await reopen.value
        XCTAssertEqual(Self.normalized(paneB.app.document?.pdfPath), Self.normalized(file.path))
        XCTAssertEqual(
            paneB.app.currentPage, 3,
            "the reopen must observe the teardown's position write, not pre-teardown bytes")
    }

    /// Backgrounding right after a close that collapsed its pane: the flush path
    /// used to drain teardowns per leaf, and a collapsed pane has no leaf left
    /// to ask — its pending write was silently abandoned. The registry outlives
    /// the pane and `flushOnBackground` drains it directly.
    ///
    /// (main names this `testQuitDrainCoversTeardownWhosePaneCollapsed`, after
    /// `applicationShouldTerminate`. iOS has no quit; the scene-background flush
    /// is the equivalent last chance, and drains the same registry.)
    func testBackgroundDrainCoversTeardownWhosePaneCollapsed() async throws {
        let file = tempDirectory.appendingPathComponent("Collapsing.pdf")
        makePDF(at: file, pages: 5)

        let gate = GatedPositionWrite()
        let workspace = makeWorkspace(gate: gate)
        let paneA = workspace.focusedPane
        await paneA.app.openFile(path: file.path)
        let tabId = try XCTUnwrap(paneA.app.activeTabId)
        paneA.app.setCurrentPage(4)
        await workspace.awaitPendingPositionRecords()
        workspace.splitFocused(.horizontal)

        gate.holdNextWrite()
        await paneA.app.closeTab(tabId)
        XCTAssertNil(workspace.root.leaf(id: paneA.id))
        try await gate.waitUntilHeld()

        // The orphaned teardown must remain reachable workspace-wide.
        XCTAssertFalse(workspace.tabTeardowns.isEmpty)

        gate.release()
        await workspace.tabTeardowns.awaitAll()
        XCTAssertTrue(workspace.tabTeardowns.isEmpty)

        // The drain returned only after the write landed on disk.
        let document = DocumentInfo(kind: .pdf, pdfPath: file.path, title: nil, pageCount: 5, lastPage: nil)
        let reopened = DocumentPositionService(
            storage: FilePositionStorage(root: positionRoot), timer: ManualPositionTimer())
        let persisted = await reopened.resumePosition(for: document)
        XCTAssertEqual(persisted?.page, 4)
    }

    /// A start tab has no backend session, so closing one must not register a
    /// teardown — the metadata/close round trips would fire against a session
    /// id that never existed, and an entry that nothing finishes would stall
    /// the background drain forever.
    func testClosingAStartTabRegistersNoTeardown() async throws {
        let gate = GatedPositionWrite()
        let workspace = makeWorkspace(gate: gate)
        let pane = workspace.focusedPane
        pane.app.newStartTab()
        let tabId = try XCTUnwrap(pane.app.activeTabId)

        await pane.app.closeTab(tabId)

        XCTAssertTrue(workspace.tabTeardowns.isEmpty)
    }

    // MARK: - Rename (#82) — the iPad's "Save As state", see the port note

    func testRenamingAnOpenTabUpdatesTheTabAndTheActiveProjection() async throws {
        let file = tempDirectory.appendingPathComponent("Original.pdf")
        makePDF(at: file, pages: 2)

        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: file.path)
        let tabId = try XCTUnwrap(app.activeTabId)

        await app.renameDocument(tabId: tabId, title: "  Chapter Four  ")

        XCTAssertEqual(app.document?.title, "Chapter Four", "the title is trimmed before it is stored")
        XCTAssertEqual(app.tabs.first(where: { $0.id == tabId })?.document?.title, "Chapter Four")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "a rename is a label; the file on disk keeps its own name")
        XCTAssertEqual(
            URL(fileURLWithPath: try XCTUnwrap(app.document?.pdfPath)).lastPathComponent,
            "Original.pdf")
    }

    /// Blank means "stop overriding", not "the title is the empty string" — the
    /// row falls back to the filename, which is what it showed before anyone
    /// renamed it. This is what the sheet's "Use original name" button does.
    func testRenamingToBlankClearsTheOverrideInsteadOfStoringAnEmptyTitle() async throws {
        let file = tempDirectory.appendingPathComponent("Named.pdf")
        makePDF(at: file, pages: 1)

        let app = AppStore(sessions: DocumentSessionManager())
        await app.openFile(path: file.path)
        let tabId = try XCTUnwrap(app.activeTabId)
        await app.renameDocument(tabId: tabId, title: "Something")
        XCTAssertEqual(app.document?.title, "Something")

        await app.renameDocument(tabId: tabId, title: "   ")

        XCTAssertNil(app.document?.title)
        XCTAssertNil(app.tabs.first(where: { $0.id == tabId })?.document?.title)
    }

    /// A rename aimed at a tab that closed while the sheet was open — or at a
    /// start tab, which has no document to name — is dropped rather than
    /// mis-filed onto whatever is active.
    func testRenamingATabWithNoDocumentIsANoOp() async throws {
        let app = AppStore(sessions: DocumentSessionManager())
        app.newStartTab()
        let startTabId = try XCTUnwrap(app.activeTabId)

        await app.renameDocument(tabId: startTabId, title: "Ignored")
        await app.renameDocument(tabId: "no-such-tab", title: "Ignored")

        XCTAssertNil(app.document)
        XCTAssertNil(app.tabs.first(where: { $0.id == startTabId })?.document)
    }

    func testRenameNormalizationIsWhatDropsTheOverride() {
        XCTAssertEqual(DocumentRenameService.normalized("  Paper  "), "Paper")
        XCTAssertNil(DocumentRenameService.normalized(""))
        XCTAssertNil(DocumentRenameService.normalized("   \n "))
    }

    // MARK: - Helpers

    private var positionRoot: URL { tempDirectory.appendingPathComponent("positions") }

    private func makeWorkspace(gate: GatedPositionWrite) -> WorkspaceStore {
        let positions = DocumentPositionService(
            storage: FilePositionStorage(root: positionRoot),
            timer: ManualPositionTimer(),
            beforeRecordMoved: { position in await gate.recordMoved(position) })
        let workspace = WorkspaceStore(sessions: DocumentSessionManager(), positions: positions)
        workspaces.append(workspace)
        positionGates.append(gate)
        return workspace
    }

    /// The session backend reports the filesystem's own path (/private/var/…)
    /// while `FileManager.temporaryDirectory` hands back the /var symlink form,
    /// and Foundation's standardization maps the former onto the latter. Compare
    /// both ends the same way so these assertions test retargeting rather than
    /// which spelling of the temp directory the OS happened to return.
    private static func normalized(_ path: String?) -> String? {
        guard let path else { return nil }
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    private func makePDF(at url: URL, pages: Int) {
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
            let attributes = [kCTFontAttributeName: font] as CFDictionary
            let attributed = CFAttributedStringCreate(
                nil, "Page \(page)" as CFString, attributes)!
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
    }
}

/// Parks the real close path's position operation; obsolete PDF metadata writes
/// no longer participate in tab teardown.
@MainActor
private final class GatedPositionWrite {
    private var holdNext = false
    private var held: CheckedContinuation<Void, Never>?

    func holdNextWrite() { holdNext = true }

    func recordMoved(_ position: ReadingPosition) async {
        guard holdNext else { return }
        holdNext = false
        await withCheckedContinuation { held = $0 }
    }

    func waitUntilHeld() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while held == nil {
            guard ContinuousClock.now < deadline else {
                throw GateError.positionWriteDidNotArrive
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        holdNext = false
        let continuation = held
        held = nil
        continuation?.resume()
    }

    enum GateError: Error { case positionWriteDidNotArrive }
}
