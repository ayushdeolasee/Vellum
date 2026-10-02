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
    private var lifecycleGates: [LifecycleGate] = []
    private var lifecycleTasks: [Task<Void, Never>] = []
    private var apps: [AppStore] = []
    private var scratchpads: [ScratchpadStore] = []
    private var previousDocumentRoot: URL?

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-document-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: tempDirectory, withIntermediateDirectories: true)
        PdfDocIdRegistry.reset()
        previousDocumentRoot = DocumentDataStore.rootDirectoryOverride
    }

    override func tearDown() async throws {
        // A timeout must unblock and drain every parked close before deleting fixtures.
        for gate in positionGates { gate.release() }
        for gate in lifecycleGates { gate.release() }
        for task in lifecycleTasks { await task.value }
        for app in apps { await app.awaitPendingTabTeardowns() }
        for scratchpad in scratchpads {
            await scratchpad.flush().value
            await scratchpad.attachmentSweepTask?.value
        }
        await ScratchpadPersistence.awaitPendingFlush()
        for workspace in workspaces {
            await workspace.awaitMaintenance()
            await workspace.tabTeardowns.awaitAll()
            await workspace.positions.flush()
            for pane in workspace.root.allLeaves() {
                for tab in pane.app.tabs { await pane.app.closeTab(tab.id) }
            }
            await workspace.tabTeardowns.awaitAll()
        }
        positionGates = []
        lifecycleGates = []
        lifecycleTasks = []
        apps = []
        scratchpads = []
        workspaces = []
        DocumentDataStore.rootDirectoryOverride = previousDocumentRoot
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
        let document = try XCTUnwrap(paneA.app.document)
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
        // Opening promotes path identity to a stable docId; read the same owner.
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

    func testRenameIsImmediateAndDelayedCompletionCannotRestoreAReboundDocument() async throws {
        let gate = LifecycleGate()
        lifecycleGates.append(gate)
        let app = AppStore(sessions: DocumentSessionManager(), renamePersistence: { _, _ in
            await gate.pause()
            return true
        })
        apps.append(app)
        let original = testDocument("A", kind: .web)
        app.attachTab(testTab(original, id: "reused"))
        let binding = try XCTUnwrap(app.activeDocumentBinding)
        let rename = Task { await app.renameDocument(tabId: "reused", title: "Immediate") }
        lifecycleTasks.append(rename)
        try await gate.waitUntilPaused()
        XCTAssertEqual(app.document?.title, "Immediate")
        XCTAssertEqual(app.activeDocumentBinding, binding, "title-only updates preserve authority")

        var tab = try XCTUnwrap(app.detachTab("reused"))
        tab.document?.pageCount = 99
        XCTAssertEqual(tab.documentBindingGeneration, binding.generation)
        let replacement = testDocument("B", kind: .web)
        tab.document = replacement
        app.attachTab(tab)
        XCTAssertFalse(app.isCurrentDocumentBinding(binding))
        gate.release()
        await rename.value
        XCTAssertEqual(app.document, replacement)
        XCTAssertEqual(app.tabs.first?.document, replacement)

        var returned = try XCTUnwrap(app.detachTab("reused"))
        returned.document = original
        app.attachTab(returned)
        XCTAssertFalse(app.isCurrentDocumentBinding(binding), "A→B→A never revives old authority")
    }

    func testQueuedRenamesRemainJoinableAfterPaneClosure() async throws {
        let gate = LifecycleGate()
        lifecycleGates.append(gate)
        let registry = TabTeardownRegistry()
        var savedTitles: [String] = []
        let app = AppStore(sessions: DocumentSessionManager(), teardowns: registry,
            renamePersistence: { _, title in
                if title == "First" { await gate.pause() }
                savedTitles.append(title ?? "")
                return true
            })
        apps.append(app)
        app.attachTab(testTab(testDocument("Serialized"), id: "serial"))
        let first = Task { await app.renameDocument(tabId: "serial", title: "First") }
        lifecycleTasks.append(first)
        try await gate.waitUntilPaused()
        let second = Task { await app.renameDocument(tabId: "serial", title: "Second") }
        lifecycleTasks.append(second)
        try await waitUntil { app.document?.title == "Second" }
        XCTAssertTrue(savedTitles.isEmpty)
        app.discardAllTabsForPaneClosure()
        var drained = false
        let drain = Task { await registry.awaitAll(); drained = true }
        lifecycleTasks.append(drain)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(drained)
        gate.release()
        await drain.value
        XCTAssertEqual(savedTitles, ["First", "Second"])
        XCTAssertTrue(registry.isEmpty)
    }

    func testFailedRenameStaysAssociatedWithItsDocumentAndCanRetry() async throws {
        let registry = TabTeardownRegistry()
        var succeeds = false
        let app = AppStore(sessions: DocumentSessionManager(), teardowns: registry,
            renamePersistence: { _, _ in succeeds })
        apps.append(app)
        let original = testDocument("Retry")
        app.attachTab(testTab(original, id: "retry"))
        await app.renameDocument(tabId: "retry", title: "Requested title")
        let key = DocumentIdentity.storageKey(for: original)
        XCTAssertEqual(registry.failedRenames[key]?.title, "Requested title")
        XCTAssertNotNil(app.renameFailures[key])
        let replacement = testDocument("Other")
        app.attachTab(testTab(replacement, id: "other"))
        succeeds = true
        await app.renameDocument(tabId: "retry", title: "Requested title")
        XCTAssertNil(registry.failedRenames[key])
        XCTAssertEqual(app.document, replacement)
        XCTAssertEqual(app.tabs.first(where: { $0.id == "retry" })?.document?.title, "Requested title")
    }

    func testQuitDrainWaitsForScratchpadCommitAndReopensLatestNoteAndAttachment() async throws {
        let workspace = await scratchpadWorkspace()
        let document = testDocument("Quit")
        workspace.focusedPane.app.attachTab(testTab(document, id: "quit"))
        let scratchpad = workspace.focusedPane.scratchpad
        await scratchpad.loadForDocument(document).value
        let gate = LifecycleGate()
        lifecycleGates.append(gate)
        let key = DocumentIdentity.storageKey(for: document)
        let blocker = Task {
            await ScratchpadWriteCoordinator.shared.withExclusiveAccess(forKeys: [key]) {
                await gate.pause()
            }
        }
        lifecycleTasks.append(blocker)
        try await gate.waitUntilPaused()
        scratchpad.text = "latest note"
        let image = Data([1, 2, 3, 4])
        scratchpad.addImage(.init(data: image, fileExtension: "png", mediaType: "image/png"), label: "fixture")
        var finished = false
        var safeToQuit = false
        let quit = Task { safeToQuit = await workspace.flushScratchpadsForTermination(); finished = true }
        lifecycleTasks.append(quit)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(finished)
        gate.release()
        await quit.value
        XCTAssertTrue(safeToQuit)
        let restored = ScratchpadStore(coordinator: workspace.storageCoordinator)
        restored.app = workspace.focusedPane.app
        scratchpads.append(restored)
        await restored.loadForDocument(document).value
        XCTAssertTrue(restored.text.contains("latest note"))
        XCTAssertTrue(restored.text.contains("![fixture]"))
        XCTAssertEqual(restored.attachmentResolver.snapshot().map(\.data), [image])
    }

    func testFailedQuitCommitKeepsDraftForRetryAndMaintenanceRemainsJoinable() async throws {
        let workspace = await scratchpadWorkspace()
        let document = testDocument("Unavailable")
        workspace.focusedPane.app.attachTab(testTab(document, id: "failed-quit"))
        let scratchpad = workspace.focusedPane.scratchpad
        await scratchpad.loadForDocument(document).value
        scratchpad.text = "unsaved draft"
        let parent = try XCTUnwrap(DocumentDataStore.rootDirectoryOverride)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let blockedDirectory = parent.appendingPathComponent(DocumentIdentity.storageKey(for: document))
        try Data("not a directory".utf8).write(to: blockedDirectory)
        let safeToQuit = await workspace.flushScratchpadsForTermination()
        XCTAssertFalse(safeToQuit)
        XCTAssertEqual(scratchpad.text, "unsaved draft")
        XCTAssertTrue(scratchpad.hasUncommittedChanges)
        try FileManager.default.removeItem(at: blockedDirectory)
        let retrySucceeded = await workspace.flushScratchpadsForTermination()
        XCTAssertTrue(retrySucceeded)

        let gate = LifecycleGate()
        lifecycleGates.append(gate)
        workspace.startMaintenance { await gate.pause() }
        try await gate.waitUntilPaused()
        var drained = false
        let drain = Task { await workspace.awaitMaintenance(); drained = true }
        lifecycleTasks.append(drain)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(drained)
        gate.release()
        await drain.value
        XCTAssertTrue(drained)
    }

    func testStartupIsOwnedBeforeItsFirstAwaitAndTerminationRejectsLateStarts() async throws {
        let workspace = await scratchpadWorkspace()
        let startup = LifecycleGate()
        let cleanup = LifecycleGate()
        lifecycleGates += [startup, cleanup]
        var cleaned = false
        XCTAssertTrue(workspace.startMaintenance {
            await startup.pause()
            await cleanup.pause()
            cleaned = true
        })
        try await startup.waitUntilPaused()
        workspace.beginTermination()
        XCTAssertFalse(workspace.startMaintenance { XCTFail("late startup admitted") })
        var drained = false
        let drain = Task { await workspace.awaitMaintenance(); drained = true }
        lifecycleTasks.append(drain)
        startup.release()
        try await cleanup.waitUntilPaused()
        XCTAssertFalse(drained)
        XCTAssertFalse(cleaned)
        cleanup.release()
        await drain.value
        XCTAssertTrue(cleaned)
        XCTAssertTrue(drained)

        let lateWorkspace = WorkspaceStore(sessions: DocumentSessionManager())
        workspaces.append(lateWorkspace)
        lateWorkspace.beginTermination()
        XCTAssertFalse(lateWorkspace.startMaintenance { XCTFail("late startup admitted") })
        lateWorkspace.cancelTermination()
        XCTAssertTrue(lateWorkspace.startMaintenance {})
    }

    func testPromotionSerializesQueuedRenamesThroughStampAndRekey() async throws {
        DocumentDataStore.rootDirectoryOverride = tempDirectory.appendingPathComponent("promotion")
        let stamp = LifecycleGate()
        let rekey = LifecycleGate()
        lifecycleGates += [stamp, rekey]
        var original = testDocument("Promotion")
        original.docId = nil
        let id = UUID().uuidString.lowercased()
        let session = LifecycleDocumentSession(info: original, resolveId: {
            await stamp.pause()
            return id
        })
        let sessions = DocumentSessionManager(openWebSession: { _, _ in session })
        _ = try await sessions.openWebDocument(url: original.pdfPath, sessionId: "promotion")
        let workspace = WorkspaceStore(sessions: sessions)
        workspaces.append(workspace)
        await workspace.startStorageCoordinator()
        let coordinator = workspace.storageCoordinator
        let app = workspace.focusedPane.app
        app.attachTab(testTab(original, id: "promotion"))
        let oldKey = DocumentIdentity.storageKey(for: original)
        try await DocumentDataStore.touch(document: original, force: true, coordinator: coordinator)
        try await DocumentDataStore.saveScratchpad(forKey: oldKey, text: "original note", coordinator: coordinator)
        var promoted = false
        let promotion = Task { _ = await app.syncDocumentId(sessionId: "promotion"); promoted = true }
        lifecycleTasks.append(promotion)
        try await stamp.waitUntilPaused()
        let first = Task { await app.renameDocument(tabId: "promotion", title: "During stamp") }
        lifecycleTasks.append(first)
        try await waitUntil { app.document?.title == "During stamp" }
        let blocker = Task {
            await ScratchpadWriteCoordinator.shared.withExclusiveAccess(forKeys: [oldKey, id]) {
                await rekey.pause()
            }
        }
        lifecycleTasks.append(blocker)
        try await rekey.waitUntilPaused()
        stamp.release()
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(promoted)
        let latest = Task { await app.renameDocument(tabId: "promotion", title: "Latest") }
        lifecycleTasks.append(latest)
        try await waitUntil { app.document?.title == "Latest" }
        rekey.release()
        await latest.value
        await promotion.value
        XCTAssertEqual(app.document?.docId, id)
        XCTAssertEqual(app.document?.title, "Latest")
        let meta = try await DocumentDataStore.loadMeta(forKey: id, coordinator: coordinator)
        let note = try await DocumentDataStore.loadScratchpad(forKey: id, coordinator: coordinator)
        XCTAssertEqual(meta?.title, "Latest")
        XCTAssertEqual(note, "original note")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentDataStore.documentDir(forKey: oldKey).path))
        XCTAssertTrue(workspace.tabTeardowns.isEmpty)
    }

    func testOutOfOrderNavigationCannotReplaceTheAdmittedBackend() async throws {
        let slow = LifecycleGate()
        let successor = LifecycleGate()
        lifecycleGates += [slow, successor]
        let original = testDocument("Original", kind: .web)
        let a = LifecycleDocumentSession(info: testDocument("A", kind: .web))
        let b = LifecycleDocumentSession(info: testDocument("B", kind: .web))
        let sessions = DocumentSessionManager(openWebSession: { url, _ in
            if url == a.info.pdfPath { await slow.pause(); return a }
            await successor.pause()
            return b
        })
        let app = AppStore(sessions: sessions)
        apps.append(app)
        app.attachTab(testTab(original, id: "navigation"))
        let first = Task { _ = await app.webNavigated(tabId: "navigation", url: a.info.pdfPath) }
        lifecycleTasks.append(first)
        try await slow.waitUntilPaused()
        let second = Task { _ = await app.webNavigated(tabId: "navigation", url: b.info.pdfPath) }
        lifecycleTasks.append(second)
        try await successor.waitUntilPaused()
        successor.release()
        await second.value
        slow.release()
        await first.value
        XCTAssertEqual(app.document?.pdfPath, b.info.pdfPath)
        XCTAssertEqual(sessions.sessions["navigation"]?.info.pdfPath, b.info.pdfPath)
        _ = try await sessions.createAnnotation(sessionId: "navigation", input: CreateAnnotationInput(
            type: .note, pageNumber: 1, color: nil, content: "at B", positionData: nil))
        XCTAssertEqual(b.createdNotes, ["at B"])
        XCTAssertTrue(a.createdNotes.isEmpty)

        let closing = Task { _ = await app.webNavigated(tabId: "navigation", url: a.info.pdfPath) }
        lifecycleTasks.append(closing)
        try await slow.waitUntilPaused()
        await app.closeTab("navigation")
        await app.awaitPendingTabTeardowns()
        slow.release()
        await closing.value
        XCTAssertNil(sessions.sessions["navigation"], "a closed tab cannot admit a late open")
    }

    func testFinalQuitCheckRejectsLateEditsAndNewPanesAfterOtherDrains() async throws {
        let workspace = await scratchpadWorkspace()
        let document = testDocument("Late edit")
        workspace.focusedPane.app.attachTab(testTab(document, id: "late-edit"))
        let scratchpad = workspace.focusedPane.scratchpad
        await scratchpad.loadForDocument(document).value
        scratchpad.text = "before quit"
        let initiallySafe = await workspace.flushScratchpadsForTermination()
        XCTAssertTrue(initiallySafe)
        let snapshot = workspace.scratchpadTerminationSnapshot
        let otherDrain = LifecycleGate()
        lifecycleGates.append(otherDrain)
        var safeToQuit = true
        let quit = Task {
            await otherDrain.pause()
            safeToQuit = workspace.scratchpadsAreSafeToTerminate(after: snapshot)
        }
        lifecycleTasks.append(quit)
        try await otherDrain.waitUntilPaused()
        scratchpad.text = "during another drain"
        // Even a successful autosave cannot make the original quit snapshot current.
        await scratchpad.flush().value
        otherDrain.release()
        await quit.value
        XCTAssertFalse(safeToQuit)
        XCTAssertEqual(scratchpad.text, "during another drain")
        let clean = workspace.scratchpadTerminationSnapshot
        XCTAssertTrue(workspace.scratchpadsAreSafeToTerminate(after: clean))
        workspace.splitFocused(.horizontal)
        XCTAssertFalse(workspace.scratchpadsAreSafeToTerminate(after: clean))
        workspace.focusedPane.app.attachTab(testTab(testDocument("New pane"), id: "new-pane"))
        let added = workspace.focusedPane.scratchpad
        scratchpads.append(added)
        await added.loadForDocument(workspace.focusedPane.app.document).value
        added.text = "new pane draft"
        XCTAssertFalse(workspace.scratchpadsAreSafeToTerminate(after: clean))
    }

    // MARK: - Helpers

    private func testDocument(_ name: String, kind: DocumentKind = .pdf) -> DocumentInfo {
        DocumentInfo(kind: kind, pdfPath: kind == .web ? "https://example.test/\(name)" : tempDirectory.appendingPathComponent("\(name).pdf").path,
                     title: name, pageCount: 1, lastPage: 1, docId: UUID().uuidString.lowercased())
    }

    private func testTab(_ document: DocumentInfo, id: String) -> PdfTab {
        PdfTab(id: id, document: document, currentPage: 1, numPages: 1, zoom: 1,
               visiblePages: [], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view)
    }

    private func scratchpadWorkspace() async -> WorkspaceStore {
        DocumentDataStore.rootDirectoryOverride = tempDirectory.appendingPathComponent("notes")
        let workspace = WorkspaceStore(sessions: DocumentSessionManager())
        workspaces.append(workspace)
        scratchpads.append(workspace.focusedPane.scratchpad)
        await workspace.startStorageCoordinator()
        return workspace
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw LifecycleGate.GateError.didNotArrive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

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

@MainActor
private final class LifecycleGate {
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while continuation == nil {
            guard ContinuousClock.now < deadline else { throw GateError.didNotArrive }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    enum GateError: Error { case didNotArrive }
}

@MainActor
private final class LifecycleDocumentSession: DocumentSession {
    let info: DocumentInfo
    private let resolveId: (@MainActor () async -> String)?
    private(set) var createdNotes: [String] = []
    init(info: DocumentInfo, resolveId: (@MainActor () async -> String)? = nil) {
        self.info = info
        self.resolveId = resolveId
    }
    func save() async throws {}
    func close() async throws {}
    func readPdfBytes() async throws -> Data { Data() }
    func annotations(pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        createdNotes.append(input.content ?? "")
        return Annotation(id: UUID().uuidString, type: input.type, pageNumber: input.pageNumber,
                          color: input.color, content: input.content, positionData: input.positionData,
                          createdAt: "", updatedAt: "")
    }
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool { true }
    func deleteAnnotation(id: String) async throws -> Bool { true }
    func setMetadata(key: String, value: String) async throws {}
    func ensureDocumentId() async throws -> String {
        if let resolveId { return await resolveId() }
        return info.docId ?? ""
    }
}
