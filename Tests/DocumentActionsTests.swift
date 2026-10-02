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
    private var aiStores: [AiStore] = []
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
        for store in aiStores { store.cancelActiveRequest() }
        for gate in positionGates { gate.release() }
        for gate in lifecycleGates { gate.release() }
        for task in lifecycleTasks { await task.value }
        for app in apps { await app.awaitPendingTabTeardowns() }
        for scratchpad in scratchpads {
            await scratchpad.flush().value
            await scratchpad.attachmentSweepTask?.value
        }
        await ScratchpadPersistence.awaitPendingFlush()
        await AiPersistence.awaitPendingFlush()
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
        aiStores = []
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
        let outcome = LifecycleRenameOutcome()
        let app = AppStore(sessions: DocumentSessionManager(), teardowns: registry,
            renamePersistence: { _, _ in outcome.succeeds })
        apps.append(app)
        let original = testDocument("Retry")
        app.attachTab(testTab(original, id: "retry"))
        await app.renameDocument(tabId: "retry", title: "Requested title")
        let key = DocumentIdentity.storageKey(for: original)
        XCTAssertEqual(registry.failedRenames[key]?.title, "Requested title")
        XCTAssertNotNil(app.renameFailures[key])
        let replacement = testDocument("Other")
        app.attachTab(testTab(replacement, id: "other"))
        outcome.succeeds = true
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
        scratchpad.addImage(.init(data: image, fileExtension: "png", mediaType: "image/png", width: 1, height: 1), label: "fixture")
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
        let coordinator = StorageCoordinator(
            storeDir: tempDirectory.appendingPathComponent("startup-owned-local"),
            modeProvider: { .local }, effectiveModeProvider: { .local },
            rootResolver: { nil }, containerFactory: { nil })
        let workspace = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: coordinator)
        workspaces.append(workspace)
        let startup = LifecycleGate()
        let cleanup = LifecycleGate()
        lifecycleGates += [startup, cleanup]
        var cleaned = false
        XCTAssertTrue(workspace.startMaintenance {
            await startup.pause()
            await cleanup.pause()
            cleaned = true
        })
        // Quit owns the registered startup before that background-priority
        // task begins. Joining it also supplies real termination's priority
        // donation instead of testing background scheduler throughput.
        workspace.beginTermination()
        XCTAssertFalse(workspace.startMaintenance { XCTFail("late startup admitted") })
        var drained = false
        let drain = Task { await workspace.awaitMaintenance(); drained = true }
        lifecycleTasks.append(drain)
        try await startup.waitUntilPaused(label: "startup before first suspension")
        XCTAssertFalse(drained)
        XCTAssertFalse(cleaned)
        startup.release()
        try await cleanup.waitUntilPaused(label: "startup cleanup during termination")
        XCTAssertFalse(drained)
        XCTAssertFalse(cleaned)
        cleanup.release()
        await drain.value
        XCTAssertTrue(cleaned)
        XCTAssertTrue(drained)

        let lateWorkspace = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: coordinator)
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

        // A fresh unstamped document at the same locator cannot inherit A's
        // promotion. Its new generation owns the path key until it is stamped.
        await app.closeTab("promotion")
        await workspace.tabTeardowns.awaitAll()
        let replacement = DocumentInfo(kind: .pdf, pdfPath: original.pdfPath,
                                       title: "Replacement", pageCount: 1, lastPage: 1, docId: nil)
        app.attachTab(testTab(replacement, id: "replacement"))
        try await DocumentDataStore.touch(document: replacement, force: true, coordinator: coordinator)
        await app.renameDocument(tabId: "replacement", title: "B title")
        let oldOwner = try await DocumentDataStore.loadMeta(forKey: id, coordinator: coordinator)
        let newOwner = try await DocumentDataStore.loadMeta(forKey: oldKey, coordinator: coordinator)
        XCTAssertEqual(oldOwner?.title, "Latest")
        XCTAssertEqual(newOwner?.title, "B title")
        XCTAssertNil(app.document?.docId)
        await app.closeTab("replacement")
        await workspace.tabTeardowns.awaitAll()
        let oldPosition = await workspace.positions.store.resume(for: .pdf(stableIdentifier: id))
        let newPosition = await workspace.positions.store.resume(for: .pdfPath(replacement.pdfPath))
        XCTAssertEqual(oldPosition?.title, "Latest")
        XCTAssertEqual(newPosition?.title, "B title")
    }

    func testPromotionIncludesExistingPaneOwnerButExcludesLaterReplacement() async throws {
        DocumentDataStore.rootDirectoryOverride = tempDirectory.appendingPathComponent("two-pane-promotion")
        let stamp = LifecycleGate()
        lifecycleGates.append(stamp)
        var original = testDocument("Shared PDF")
        original.docId = nil
        let id = UUID().uuidString.lowercased()
        let session = LifecycleDocumentSession(info: original, resolveId: {
            await stamp.pause()
            return id
        })
        let sessions = DocumentSessionManager(openWebSession: { _, _ in session })
        _ = try await sessions.openWebDocument(url: original.pdfPath, sessionId: "pane-a")
        _ = try await sessions.openWebDocument(url: original.pdfPath, sessionId: "pane-b")
        let workspace = WorkspaceStore(sessions: sessions)
        workspaces.append(workspace)
        await workspace.startStorageCoordinator()
        let coordinator = workspace.storageCoordinator
        let appA = workspace.focusedPane.app
        appA.attachTab(testTab(original, id: "pane-a"))
        workspace.splitFocused(.horizontal)
        let appB = workspace.focusedPane.app
        appB.attachTab(testTab(original, id: "pane-b"))
        XCTAssertNotEqual(appA.activeDocumentBinding?.generation, appB.activeDocumentBinding?.generation)
        try await DocumentDataStore.touch(document: original, force: true, coordinator: coordinator)
        let oldKey = DocumentIdentity.storageKey(for: original)
        let promotion = Task { _ = await appA.syncDocumentId(sessionId: "pane-a") }
        lifecycleTasks.append(promotion)
        try await stamp.waitUntilPaused()
        let rename = Task { await appB.renameDocument(tabId: "pane-b", title: "From pane B") }
        lifecycleTasks.append(rename)
        try await waitUntil { appB.document?.title == "From pane B" }
        await appB.closeTab("pane-b")
        stamp.release()
        await promotion.value
        await workspace.tabTeardowns.awaitAll()
        let meta = try await DocumentDataStore.loadMeta(forKey: id, coordinator: coordinator)
        XCTAssertEqual(meta?.title, "From pane B")
        XCTAssertFalse(FileManager.default.fileExists(atPath: DocumentDataStore.documentDir(forKey: oldKey).path))
        let promotedPosition = await workspace.positions.store.resume(for: .pdf(stableIdentifier: id))
        let stalePosition = await workspace.positions.store.resume(for: .pdfPath(original.pdfPath))
        XCTAssertEqual(promotedPosition?.title, "From pane B")
        XCTAssertNil(stalePosition)

        // A new owner admitted after the snapshot never follows the old PDF.
        appB.attachTab(testTab(original, id: "replacement-b"))
        try await DocumentDataStore.touch(document: original, force: true, coordinator: coordinator)
        await appB.renameDocument(tabId: "replacement-b", title: "Replacement B")
        let unchanged = try await DocumentDataStore.loadMeta(forKey: id, coordinator: coordinator)
        let replacement = try await DocumentDataStore.loadMeta(forKey: oldKey, coordinator: coordinator)
        XCTAssertEqual(unchanged?.title, "From pane B")
        XCTAssertEqual(replacement?.title, "Replacement B")
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

        slow.arm()
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

    func testAIStreamAndSuspendedReadCannotCrossSameTabNavigation() async throws {
        try await withAIDefaults {
            let read = LifecycleGate()
            lifecycleGates.append(read)
            let result = AIRequestFixtureState()
            let fixture = try await aiFixture { engine, event in
                event(.textDelta("accepted A text"))
                result.outputs.append(await engine.run(
                    AIRequestFixtureState.action("getPageText"), sessionIdAtStart: "ai", actionCount: 0))
                event(.textDelta("LATE A TEXT"))
                event(.status("Reading old A"))
                result.outputs.append(await engine.run(
                    AIRequestFixtureState.action("addNote", text: "wrong owner"), sessionIdAtStart: "ai", actionCount: 1))
                return AiProviderResult(reply: "LATE A REPLY", actionResults: [])
            }
            fixture.ai.ensureExtractedHandler = { _ in
                result.extractions += 1
                if result.extractions == 2 { await read.pause() }
                return 0
            }
            let request = Task { await fixture.ai.sendMessage("A question", context: fixture.context) }
            lifecycleTasks.append(request)
            try await read.waitUntilPaused()
            XCTAssertTrue(fixture.ai.messages.contains { $0.content == "accepted A text" })
            _ = await fixture.app.webNavigated(tabId: "ai", url: fixture.b.info.pdfPath)
            fixture.ai.setPageText(page: 1, text: "PRIVATE B TEXT")
            read.release()
            await request.value
            await fixture.app.awaitPendingTabTeardowns()
            XCTAssertTrue(fixture.ai.messages.isEmpty)
            XCTAssertFalse(fixture.ai.isThinking)
            XCTAssertTrue(fixture.annotations.annotations.isEmpty)
            XCTAssertTrue(fixture.a.createdNotes.isEmpty)
            XCTAssertTrue(fixture.b.createdNotes.isEmpty)
            XCTAssertTrue(result.outputs.allSatisfy { $0.hasPrefix("Skipped") && !$0.contains("PRIVATE B TEXT") })
            XCTAssertEqual(AiPersistence.loadConversation(for: fixture.a.info).map(\.content), ["A question", "accepted A text"])
            XCTAssertTrue(AiPersistence.loadConversation(for: fixture.b.info).isEmpty)
        }
    }

    func testAIReturnToSameDocumentCannotReviveOldRequestOrClearNewerLoading() async throws {
        try await withAIDefaults {
            let old = LifecycleGate()
            let newer = LifecycleGate()
            let otherPane = LifecycleGate()
            lifecycleGates += [old, newer, otherPane]
            let state = AIRequestFixtureState()
            let fixture = try await aiFixture { _, event in
                state.calls += 1
                if state.calls == 1 {
                    event(.textDelta("first partial"))
                    await old.pause()
                    event(.textDelta("STALE DELTA"))
                    return AiProviderResult(reply: "STALE RESULT", actionResults: [])
                }
                event(.status("Thinking newer"))
                await newer.pause()
                return AiProviderResult(reply: "new answer", actionResults: [])
            }
            let independent = try await aiFixture { _, event in
                event(.status("Thinking another pane"))
                await otherPane.pause()
                return AiProviderResult(reply: "independent", actionResults: [])
            }
            let separate = Task { await independent.ai.sendMessage("other pane", context: independent.context) }
            lifecycleTasks.append(separate)
            try await otherPane.waitUntilPaused()
            let first = Task { await fixture.ai.sendMessage("first", context: fixture.context) }
            lifecycleTasks.append(first)
            try await old.waitUntilPaused()
            let original = try XCTUnwrap(fixture.app.activeDocumentBinding)
            _ = await fixture.app.webNavigated(tabId: "ai", url: fixture.b.info.pdfPath)
            _ = await fixture.app.webNavigated(tabId: "ai", url: fixture.a.info.pdfPath)
            XCTAssertFalse(fixture.app.isCurrentDocumentBinding(original))
            await fixture.ai.loadConversationForDocument(fixture.a.info)
            let next = Task { await fixture.ai.sendMessage("second", context: fixture.context) }
            lifecycleTasks.append(next)
            try await newer.waitUntilPaused()
            old.release()
            await first.value
            XCTAssertTrue(fixture.ai.isThinking, "an old completion cannot reset its successor")
            XCTAssertTrue(independent.ai.isThinking, "request generations belong to one pane")
            XCTAssertFalse(fixture.ai.messages.contains { $0.content.contains("STALE") })
            newer.release()
            otherPane.release()
            await next.value
            await separate.value
            await fixture.app.awaitPendingTabTeardowns()
            await independent.app.awaitPendingTabTeardowns()
            XCTAssertEqual(AiPersistence.loadConversation(for: fixture.a.info).map(\.content),
                           ["first", "first partial", "second", "new answer"])
            XCTAssertEqual(independent.ai.messages.last?.content, "independent")
            XCTAssertFalse(fixture.ai.isThinking)
        }
    }

    func testAISuspendedLocatorAndAdmittedWriteKeepTheirCapturedBackend() async throws {
        try await withAIDefaults {
            let locator = LifecycleGate()
            let write = LifecycleGate()
            lifecycleGates += [locator, write]
            let state = AIRequestFixtureState()
            let fixture = try await aiFixture(beforeCreate: { await write.pause() }) { engine, event in
                state.calls += 1
                if state.calls == 1 {
                    state.outputs.append(await engine.run(
                        AIRequestFixtureState.action("addHighlight", text: "phrase"), sessionIdAtStart: "ai", actionCount: 0))
                } else {
                    event(.textDelta("writing original A"))
                    state.outputs.append(await engine.run(
                        AIRequestFixtureState.action("addNote", text: "legitimate A note"), sessionIdAtStart: "ai", actionCount: 0))
                }
                return AiProviderResult(reply: "late answer", actionResults: [])
            }
            fixture.ai.locateWebTextHandler = { _, _ in
                await locator.pause()
                return LocatedText(positionData: PositionData(rects: [], pageWidth: 612, pageHeight: 792, selectedText: "phrase"), pageNumber: 1)
            }
            let first = Task { await fixture.ai.sendMessage("highlight", context: fixture.context) }
            lifecycleTasks.append(first)
            try await locator.waitUntilPaused()
            _ = await fixture.app.webNavigated(tabId: "ai", url: fixture.b.info.pdfPath)
            locator.release()
            await first.value
            XCTAssertTrue(fixture.a.createdNotes.isEmpty)
            XCTAssertTrue(fixture.b.createdNotes.isEmpty)
            _ = await fixture.app.webNavigated(tabId: "ai", url: fixture.a.info.pdfPath)
            await fixture.ai.loadConversationForDocument(fixture.a.info)
            let second = Task { await fixture.ai.sendMessage("note", context: fixture.context) }
            lifecycleTasks.append(second)
            try await write.waitUntilPaused()
            XCTAssertTrue(fixture.annotations.annotations.contains { $0.content == "legitimate A note" })
            // Navigation must join the admitted original-owner write. Its intent
            // still cancels AI immediately, before the backend can be rebound.
            let navigation = Task { _ = await fixture.app.webNavigated(tabId: "ai", url: fixture.b.info.pdfPath) }
            lifecycleTasks.append(navigation)
            try await waitUntil { !fixture.ai.isThinking }
            XCTAssertEqual(fixture.app.document?.pdfPath, fixture.a.info.pdfPath)
            write.release()
            await navigation.value
            await second.value
            await fixture.app.awaitPendingTabTeardowns()
            XCTAssertEqual(fixture.a.createdNotes, ["legitimate A note"])
            XCTAssertTrue(fixture.b.createdNotes.isEmpty)
            XCTAssertTrue(fixture.annotations.annotations.isEmpty)
            XCTAssertTrue(fixture.ai.messages.isEmpty)
            XCTAssertTrue(state.outputs.allSatisfy { $0.hasPrefix("Skipped") })
            XCTAssertTrue(AiPersistence.loadConversation(for: fixture.a.info).contains { $0.content == "writing original A" })
            XCTAssertTrue(AiPersistence.loadConversation(for: fixture.b.info).isEmpty)
        }
    }

    func testAIConsentFailureRetryAndExplicitClearKeepTheRightHistory() async throws {
        try await withAIDefaults {
            let pending = LifecycleGate()
            lifecycleGates.append(pending)
            let state = AIRequestFixtureState()
            let fixture = try await aiFixture { _, event in
                state.calls += 1
                if state.calls == 1 {
                    event(.textDelta("partial failure"))
                    throw AiClientError.message("fixture failure")
                }
                if state.calls == 2 { return AiProviderResult(reply: "retry answer", actionResults: []) }
                event(.textDelta("discarded partial"))
                await pending.pause()
                event(.textDelta("late cleared text"))
                return AiProviderResult(reply: "late cleared answer", actionResults: [])
            }
            AiSharingConsent.revoke(for: .gemini)
            await fixture.ai.sendMessage("blocked", context: fixture.context)
            XCTAssertEqual(state.calls, 0)
            XCTAssertTrue(fixture.ai.messages.isEmpty)
            XCTAssertFalse(fixture.ai.isThinking)
            AiSharingConsent.grant(for: .gemini)
            await fixture.ai.sendMessage("failure", context: fixture.context)
            XCTAssertTrue(fixture.ai.messages.last?.content.contains("partial failure") == true)
            XCTAssertEqual(fixture.ai.error, "fixture failure")
            XCTAssertFalse(fixture.ai.isThinking)
            await fixture.ai.sendMessage("retry", context: fixture.context)
            XCTAssertEqual(fixture.ai.messages.last?.content, "retry answer")
            await fixture.app.awaitPendingTabTeardowns()
            let clearable = Task { await fixture.ai.sendMessage("clear me", context: fixture.context) }
            lifecycleTasks.append(clearable)
            try await pending.waitUntilPaused()
            await fixture.app.awaitPendingTabTeardowns()
            XCTAssertNotNil(fixture.ai.clearConversation())
            pending.release()
            await clearable.value
            await fixture.app.awaitPendingTabTeardowns()
            await AiPersistence.awaitPendingFlush()
            XCTAssertTrue(fixture.ai.messages.isEmpty)
            XCTAssertFalse(fixture.ai.isThinking)
            XCTAssertTrue(AiPersistence.loadConversation(for: fixture.a.info).isEmpty)
        }
    }

    func testAIExplicitMutationsFollowUnflushedPartialHistory() async throws {
        try await withAIDefaults {
            let gates = (0..<4).map { _ in LifecycleGate() }
            lifecycleGates += gates
            let state = AIRequestFixtureState()
            let fixture = try await aiFixture { _, event in
                let index = state.calls
                state.calls += 1
                event(.textDelta("partial \(index)"))
                await gates[index].pause()
                event(.textDelta("late obsolete"))
                return AiProviderResult(reply: "late obsolete", actionResults: [])
            }
            fixture.ai.addLocalMessage(role: .user, content: "original", id: "original")
            let cleared = fixture.ai.clearConversation()
            let transaction = try XCTUnwrap(cleared)
            for index in 0..<4 {
                let request = Task { await fixture.ai.sendMessage("turn \(index)", context: fixture.context) }
                lifecycleTasks.append(request)
                try await gates[index].waitUntilPaused()
                // Deliberately no registry/persistence drain before the mutation.
                switch index {
                case 0:
                    XCTAssertTrue(fixture.ai.undoClear(transaction))
                    XCTAssertEqual(fixture.ai.messages.first?.id, "original")
                case 1:
                    XCTAssertTrue(fixture.ai.redoClear(transaction))
                    XCTAssertFalse(fixture.ai.messages.contains { $0.id == "original" })
                case 2:
                    let user = try XCTUnwrap(fixture.ai.messages.last { $0.role == .user })
                    fixture.ai.updateLocalMessage(id: user.id, content: "edited partial turn")
                default:
                    fixture.ai.addLocalMessage(role: .assistant, content: "local final", id: "local-final")
                }
                gates[index].release()
                await request.value
                await fixture.app.awaitPendingTabTeardowns()
                await AiPersistence.awaitPendingFlush()
                let key = DocumentIdentity.storageKey(for: fixture.a.info)
                let bytes = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: key))
                let durable = try JSONDecoder().decode([AiMessage].self, from: bytes)
                XCTAssertEqual(durable, fixture.ai.messages)
                XCTAssertFalse(durable.contains { $0.content.contains("obsolete") })
                if index == 2 { XCTAssertTrue(durable.contains { $0.content == "edited partial turn" }) }
                if index == 3 { XCTAssertEqual(durable.last?.id, "local-final") }
            }
        }
    }

    func testClearQueuedDuringPromotionUsesOnlyItsCapturedOwner() async throws {
        try await withAIDefaults {
            let stamp = LifecycleGate()
            lifecycleGates.append(stamp)
            var original = testDocument("Clear promotion")
            original.docId = nil
            let id = UUID().uuidString.lowercased()
            let backend = LifecycleDocumentSession(info: original, resolveId: {
                await stamp.pause()
                return id
            })
            let sessions = DocumentSessionManager(openWebSession: { _, _ in backend })
            _ = try await sessions.openWebDocument(url: original.pdfPath, sessionId: "clear-promotion")
            let workspace = WorkspaceStore(sessions: sessions)
            workspaces.append(workspace)
            await workspace.startStorageCoordinator()
            let pane = workspace.focusedPane
            pane.app.attachTab(testTab(original, id: "clear-promotion"))
            pane.ai.app = pane.app
            aiStores.append(pane.ai)
            await pane.ai.loadConversationForDocument(original, coordinator: workspace.storageCoordinator)
            pane.ai.addLocalMessage(role: .user, content: "before promotion", id: "promotion-history")
            let promotion = Task { _ = await pane.app.syncDocumentId(sessionId: "clear-promotion") }
            lifecycleTasks.append(promotion)
            try await stamp.waitUntilPaused()
            let transaction = pane.ai.clearConversation()
            stamp.release()
            await promotion.value
            await workspace.tabTeardowns.awaitAll()
            let accepted = try XCTUnwrap(transaction)
            let oldKey = DocumentIdentity.storageKey(for: original)
            XCTAssertEqual(pane.app.document?.docId, id)
            XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: oldKey))
            XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: id))
            XCTAssertTrue(pane.ai.undoClear(accepted))
            await workspace.tabTeardowns.awaitAll()
            let bytes = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: id))
            XCTAssertEqual(try JSONDecoder().decode([AiMessage].self, from: bytes).map(\.content), ["before promotion"])
            await pane.app.closeTab("clear-promotion")
            await workspace.tabTeardowns.awaitAll()
            pane.app.attachTab(testTab(original, id: "clear-promotion"))
            XCTAssertFalse(pane.ai.undoClear(accepted), "a new binding at the same locator cannot inherit this Undo")
        }
    }

    func testImportRefusesOpenDestinationAndIncomingOwnerWithoutChangingAI() async throws {
        try await withAIDefaults {
            let pending = LifecycleGate()
            lifecycleGates.append(pending)
            let destination = tempDirectory.appendingPathComponent("import-owner.pdf")
            makePDF(at: destination, pages: 1)
            var original = testDocument("Original owner")
            original.pdfPath = destination.path
            try PdfMetadata.stampDocumentId(atPath: destination.path, id: try XCTUnwrap(original.docId))
            let originalBytes = try Data(contentsOf: destination)
            let state = AIRequestFixtureState()
            let fixture = try await aiFixture(document: original) { engine, event in
                event(.textDelta("original owner partial"))
                await pending.pause()
                state.outputs.append(await engine.run(
                    AIRequestFixtureState.action("addNote", text: "original owner note"), sessionIdAtStart: "ai", actionCount: 0))
                return AiProviderResult(reply: "original owner reply", actionResults: [])
            }
            let request = Task { await fixture.ai.sendMessage("original question", context: fixture.context) }
            lifecycleTasks.append(request)
            try await pending.waitUntilPaused()
            let reference = AiReference(kind: .selection(text: "unsent draft reference", page: 1))
            fixture.ai.addReference(reference)
            let incoming = try importedFixture()
            let visible = fixture.ai.messages
            do {
                _ = try await fixture.app.importVellumBundle(incoming, to: destination) { _ in
                    XCTFail("an open destination must be refused before its merge prompt")
                    return .keepLocal
                }
                XCTFail("expected open destination refusal")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Close this document")) }
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
            XCTAssertEqual(fixture.ai.messages, visible)
            XCTAssertEqual(fixture.ai.composerReferences, [reference])
            XCTAssertTrue(fixture.ai.isThinking)

            // The same incoming stable owner in another pane is protected even
            // when inactive and located at an entirely different path.
            let workspace = WorkspaceStore(sessions: fixture.app.sessions)
            workspaces.append(workspace)
            fixture.app.workspace = workspace
            var sameOwner = testDocument("Other incoming owner")
            sameOwner.docId = incoming.manifest.docId
            workspace.focusedPane.app.attachTab(testTab(sameOwner, id: "incoming-owner"))
            workspace.focusedPane.app.newStartTab()
            let otherDestination = tempDirectory.appendingPathComponent("not-yet-written.pdf")
            do {
                _ = try await fixture.app.importVellumBundle(incoming, to: otherDestination) { _ in .keepLocal }
                XCTFail("expected inactive incoming-owner refusal")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Close this document")) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: otherDestination.path))
            pending.release()
            await request.value
            await fixture.app.awaitPendingTabTeardowns()
            XCTAssertEqual(fixture.a.createdNotes, ["original owner note"])
            XCTAssertEqual(try Data(contentsOf: destination), originalBytes)
            XCTAssertFalse(fixture.ai.messages.contains { $0.content == "imported history" })
            XCTAssertEqual(fixture.ai.composerReferences, [reference])
        }
    }

    func testClosedOwnerImportRemainsRegisteredAcrossItsMergePrompt() async throws {
        try await withAIDefaults {
            let prompt = LifecycleGate()
            lifecycleGates.append(prompt)
            let imported = try importedFixture()
            let destination = tempDirectory.appendingPathComponent("registered-import.pdf")
            let alternate = tempDirectory.appendingPathComponent("same-owner-other-path.pdf")
            try imported.documentData.write(to: alternate)
            let sessions = DocumentSessionManager()
            let app = AppStore(sessions: sessions)
            apps.append(app)
            let outcome = LifecycleRenameOutcome()
            let importing = Task {
                do {
                    _ = try await app.importVellumBundle(imported, to: destination) { _ in
                        await prompt.pause()
                        return .keepLocal
                    }
                    outcome.succeeds = true
                } catch { XCTFail("closed owner import failed: \(error)") }
            }
            lifecycleTasks.append(importing)
            try await prompt.waitUntilPaused()
            XCTAssertEqual(PdfMetadata.documentId(atPath: destination.path), imported.manifest.docId)
            XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: imported.manifest.docId))
            let opening = Task { await app.openFile(path: destination.path) }
            lifecycleTasks.append(opening)
            let alternateOpening = Task { await app.openFile(path: alternate.path) }
            lifecycleTasks.append(alternateOpening)
            try await waitUntil { sessions.sessions.count == 1 }
            XCTAssertTrue(app.tabs.isEmpty, "both path and newly discovered stable-owner opens must join the whole import")
            prompt.release()
            await importing.value
            await opening.value
            await alternateOpening.value
            await app.awaitPendingTabTeardowns()
            XCTAssertTrue(outcome.succeeds)
            XCTAssertEqual(app.document?.docId, imported.manifest.docId)
            let bytes = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: imported.manifest.docId))
            XCTAssertEqual(try JSONDecoder().decode([AiMessage].self, from: bytes).map(\.content), ["imported history"])
            for tab in app.tabs { await app.closeTab(tab.id) }
            await app.awaitPendingTabTeardowns()
        }
    }

    private func importedFixture() throws -> VellumBundle.Imported {
        let path = tempDirectory.appendingPathComponent("incoming-\(UUID().uuidString).pdf")
        makePDF(at: path, pages: 1)
        let id = UUID().uuidString.lowercased()
        try PdfMetadata.stampDocumentId(atPath: path.path, id: id)
        let content = VellumBundle.Content(kind: .pdf, docId: id, documentFile: "incoming.pdf",
            documentData: try Data(contentsOf: path), title: "Imported", scratchpad: nil, attachments: [],
            conversations: try JSONEncoder().encode([AiPersistence.makeMessage(role: .user, content: "imported history")]))
        let bundle = tempDirectory.appendingPathComponent("fixture-\(UUID().uuidString).vellum")
        try VellumBundle.write(content, to: bundle)
        return try VellumBundle.read(at: bundle)
    }

    private func withAIDefaults(_ operation: () async throws -> Void) async throws {
        DocumentDataStore.rootDirectoryOverride = tempDirectory.appendingPathComponent("ai-scope")
        let name = "vellum.ai-scope-tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try await AppDefaults.withDefaults(defaults) {
            AiSharingConsent.grant(for: .gemini)
            do { try await operation() }
            catch {
                await drainAITestWork()
                throw error
            }
            await drainAITestWork()
        }
    }

    private func drainAITestWork() async {
        for store in aiStores { store.cancelActiveRequest() }
        for gate in lifecycleGates { gate.release() }
        for task in lifecycleTasks { await task.value }
        for app in apps { await app.awaitPendingTabTeardowns() }
        await AiPersistence.awaitPendingFlush()
    }

    private func aiFixture(
        document: DocumentInfo? = nil,
        beforeCreate: (@MainActor () async -> Void)? = nil, generate: @escaping AiStore.Generate
    ) async throws -> AIRequestFixture {
        let a = AIRequestFixtureSession(info: document ?? testDocument("AI-A-\(UUID().uuidString)", kind: .web), beforeCreate: beforeCreate)
        let b = AIRequestFixtureSession(info: testDocument("AI-B-\(UUID().uuidString)", kind: .web))
        let manager = DocumentSessionManager(openWebSession: { url, _ in url == a.info.pdfPath ? a : b })
        _ = try await manager.openWebDocument(url: a.info.pdfPath, sessionId: "ai")
        let app = AppStore(sessions: manager)
        apps.append(app)
        app.attachTab(testTab(a.info, id: "ai"))
        let annotations = AnnotationStore(app: app)
        var settings = AiSettings()
        settings.provider = .gemini
        settings.apiKey = "isolated-unused-fixture-key"
        let ai = AiStore(settings: settings, generate: generate)
        ai.app = app
        ai.annotationStore = annotations
        aiStores.append(ai)
        return AIRequestFixture(app: app, annotations: annotations, ai: ai, a: a, b: b)
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
    private var isReleased = false

    /// Explicitly rearm a reused gate after its prior task has been joined.
    func arm() { precondition(continuation == nil); isReleased = false }

    func pause() async {
        // Cleanup can arrive before a background-priority task reaches its gate.
        // Remember it so timeout teardown cannot park that task forever later.
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilPaused(label: String? = nil) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while continuation == nil {
            guard ContinuousClock.now < deadline else {
                if let label { throw GateError.namedGateDidNotArrive(label) }
                throw GateError.didNotArrive
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func release() {
        isReleased = true
        let pending = continuation
        continuation = nil
        pending?.resume()
    }

    enum GateError: Error {
        case didNotArrive
        case namedGateDidNotArrive(String)
    }
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

@MainActor
private final class LifecycleRenameOutcome {
    var succeeds = false
}

@MainActor
private struct AIRequestFixture {
    let app: AppStore
    let annotations: AnnotationStore
    let ai: AiStore
    let a: AIRequestFixtureSession
    let b: AIRequestFixtureSession
    var context: AiContextSnapshot {
        AiContextSnapshot(title: "fixture", numPages: 1, currentPage: 1, visiblePages: [1], annotations: [], currentPageImage: nil)
    }
}

@MainActor
private final class AIRequestFixtureState {
    var calls = 0
    var extractions = 0
    var outputs: [String] = []
    static func action(_ tool: String, text: String? = nil) -> AiToolAction {
        AiToolAction(tool: tool, args: AiToolArguments(pageNumber: 1, text: text))
    }
}

@MainActor
private final class AIRequestFixtureSession: DocumentSession {
    let info: DocumentInfo
    private let beforeCreate: (@MainActor () async -> Void)?
    private(set) var createdNotes: [String] = []
    init(info: DocumentInfo, beforeCreate: (@MainActor () async -> Void)? = nil) {
        self.info = info
        self.beforeCreate = beforeCreate
    }
    func save() async throws {}
    func close() async throws {}
    func readPdfBytes() async throws -> Data { Data() }
    func annotations(pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        await beforeCreate?()
        createdNotes.append(input.content ?? input.positionData?.selectedText ?? "")
        return Annotation(id: input.id ?? UUID().uuidString, type: input.type, pageNumber: input.pageNumber,
                          color: input.color, content: input.content, positionData: input.positionData,
                          createdAt: "", updatedAt: "")
    }
    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool { true }
    func deleteAnnotation(id: String) async throws -> Bool { true }
    func setMetadata(key: String, value: String) async throws {}
    func ensureDocumentId() async throws -> String { info.docId ?? "" }
}
