#if os(macOS)
import Darwin
import Foundation
import Testing

@testable import Vellum

@Suite("Shared folder storage", .serialized, .isolatedStorage)
struct SyncedFolderStorageTests {
    @Test("Shared PDFs import, reopen and relink by verified identity without deleting the prior PDF")
    @MainActor
    func sharedPDFLifecycle() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = tmp.appendingPathComponent("Users/alice/Vellum", isDirectory: true)
        let local = tmp.appendingPathComponent("local/web", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let savedOverride = WebLibrary.storeDirOverride
        WebLibrary.storeDirOverride = local
        defer { WebLibrary.storeDirOverride = savedOverride }
        let suite = "vellum.shared-pdf-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await AppDefaults.withDefaults(defaults) {
            WebStorageSettings.selectSyncedFolder(path: shared.path, bookmark: Data())
            let coordinator = StorageCoordinator(storeDir: local, rootResolver: { nil }, containerFactory: { nil },
                                                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
            await coordinator.start()
            do {
                let base = DocumentAccessResolver(store: DocumentAccessBookmarkStore(directory: tmp),
                                                  adapter: SystemDocumentAccessAdapter(),
                                                  libraryDirectory: { tmp.appendingPathComponent("managed") },
                                                  appOwnedRoots: { [] })
                let resolver = try await base.configured(for: coordinator)
                let backend = PdfSessionBackend()
                for (fixture, shouldStamp) in [("classic-two-column", true), ("digitally-signed", false)] {
                    let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL(fixture))
                    let source = tmp.appendingPathComponent(fixture + ".pdf")
                    try original.write(to: source)
                    let doc = try await resolver.openPickedPDF(url: source, sessionId: "picked") { path, id in
                        try await backend.open(path: path, sessionId: id).info
                    }
                    let key = try #require(doc.docId)
                    let destination = URL(fileURLWithPath: doc.pdfPath)
                    let bytes = try Data(contentsOf: destination)
                    #expect(try Data(contentsOf: source) == original)
                    #expect(bytes.starts(with: original))
                    #expect(shouldStamp ? SharedPDFImport.readID(bytes) == key : key == DocumentIdentity.byteHash(original))
                    #expect(shouldStamp || bytes == original)
                    try await DocumentDataStore.touch(document: doc, coordinator: coordinator)
                    let path = try await DocumentDataStore.loadMeta(forKey: key, coordinator: coordinator)?.lastKnownPath
                    #expect(path == "PDFs/" + source.lastPathComponent)
                    let repeated = try await resolver.openPickedPDF(url: source, sessionId: "repeat") { path, id in
                        try await backend.open(path: path, sessionId: id).info
                    }
                    #expect(repeated.pdfPath == doc.pdfPath && repeated.docId == key)
                    let reopened = try await resolver.openPickedPDF(url: destination, sessionId: "again") { path, id in
                        try await backend.open(path: path, sessionId: id).info
                    }
                    #expect(reopened.pdfPath == doc.pdfPath && reopened.docId == key)
                    let next = destination.deletingLastPathComponent().appendingPathComponent("Moved-" + source.lastPathComponent)
                    try fm.copyItem(at: destination, to: next)
                    try await resolver.relink(key: key, isDocIdKeyed: false, to: next, coordinator: coordinator).get()
                    #expect(try Data(contentsOf: destination) == bytes)
                    let moved = try await DocumentDataStore.loadMeta(forKey: key, coordinator: coordinator)
                    #expect(moved?.lastKnownPath == "PDFs/" + next.lastPathComponent)
                    #expect(!resolver.sourceExists(key: key, lastKnownPath: source.path))
                    #expect(!resolver.sourceExists(key: key, lastKnownPath: "PDFs/../../" + source.lastPathComponent))
                }
                #expect(!fm.fileExists(atPath: tmp.appendingPathComponent("managed").path))
            } catch {
                await coordinator.stop()
                throw error
            }
            await coordinator.stop()
        }
    }

    @Test("Changing or replacing a shared folder waits for closed documents and saves drafts in their original root")
    @MainActor
    func sharedFolderSwitchDrainsDocumentOwners() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let local = tmp.appendingPathComponent("private/web")
        let first = tmp.appendingPathComponent("first")
        let second = tmp.appendingPathComponent("second")
        for root in [local, first, second] { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: tmp) }
        let previousStore = WebLibrary.storeDirOverride
        let previousDocuments = DocumentDataStore.rootDirectoryOverride
        WebLibrary.storeDirOverride = local
        DocumentDataStore.rootDirectoryOverride = nil
        defer {
            WebLibrary.storeDirOverride = previousStore
            DocumentDataStore.rootDirectoryOverride = previousDocuments
        }
        let suite = "vellum.switch-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await AppDefaults.withDefaults(defaults) {
            WebStorageSettings.setMode(.local)
            let coordinator = StorageCoordinator(storeDir: local, rootResolver: { nil }, containerFactory: { nil },
                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
            let workspace = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: coordinator)
            let pane = workspace.focusedPane
            let site = "https://example.invalid/" + UUID().uuidString
            let key = DocumentIdentity.sha256Hex(site)
            let doc = DocumentInfo(kind: .web, pdfPath: site, title: "Fixture", pageCount: nil, lastPage: nil, docId: key)
            let tab = PdfTab(id: "source", document: doc, currentPage: 1, numPages: 1, zoom: 1,
                             visiblePages: [], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view)
            let message = AiPersistence.makeMessage(role: .user, content: "private transcript")
            let privateDocs = WebStorageLayout.local(storeDir: local).documentsDir
            func select(_ root: URL) async {
                await WebStorageRelocator.selectSyncedFolder(.init(path: root.path, bookmarkData: Data()), workspace: workspace)
            }
            await coordinator.start()
            defer { AiPersistence.invalidateCachedConversation(forKey: key) }
            do {
                pane.app.attachTab(tab)
                await pane.scratchpad.loadForDocument(doc).value
                pane.scratchpad.text = "private notes"
                #expect(AiPersistence.saveConversation(for: doc, messages: [message], coordinator: coordinator))
                await select(first)
                #expect(WebStorageSettings.chosenMode == .local)
                #expect(WebStorageRelocator.status.message.contains("close all document tabs"))
                #expect(!fm.fileExists(atPath: first.appendingPathComponent(".vellum/documents/" + key).path))
                await pane.app.closeTab(tab.id)
                await select(first)
                #expect(await coordinator.currentStatus().activeSharedFolderRoot?.path == first.path)
                #expect(try String(contentsOf: privateDocs.appendingPathComponent(key + "/scratchpad.md"),
                                   encoding: .utf8) == "private notes")
                #expect(try JSONDecoder().decode([AiMessage].self, from: Data(contentsOf:
                    privateDocs.appendingPathComponent(key + "/conversations.json"))) == [message])
                #expect(await AiPersistence.loadConversation(for: doc, coordinator: coordinator).isEmpty)

                pane.app.attachTab(tab)
                await select(second)
                #expect(await coordinator.currentStatus().activeSharedFolderRoot?.path == first.path)
                await WebStorageRelocator.apply(mode: .local, workspace: workspace)
                #expect(await coordinator.currentStatus().activeSharedFolderRoot?.path == first.path)
                await pane.app.closeTab(tab.id)

                // A failed close-release remains joinable by the next attempt.
                let saved = tmp.appendingPathComponent("release-complete")
                workspace.tabTeardowns.registerReleaseFlush(document: doc) { fm.fileExists(atPath: saved.path) }
                await select(second)
                #expect(await coordinator.currentStatus().activeSharedFolderRoot?.path == first.path)
                try Data().write(to: saved)
                await select(second)
                #expect(await coordinator.currentStatus().activeSharedFolderRoot?.path == second.path)
                // Hold the old backend in use until the transition has closed
                // coordinator admission. A document admitted during that await
                // must veto the preference write at the final commit boundary.
                let (entered, didEnter) = AsyncStream<Void>.makeStream()
                let (release, finish) = AsyncStream<Void>.makeStream()
                let reader = Task {
                    try await coordinator.withStorageContext { _ in
                        didEnter.finish()
                        for await _ in release {}
                    }
                }
                for await _ in entered {}
                let switching = Task { await WebStorageRelocator.apply(mode: .local, workspace: workspace) }
                let deadline = ContinuousClock.now + .seconds(3)
                while await coordinator.currentStatus().lifecycle != .starting && ContinuousClock.now < deadline {
                    await Task.yield()
                }
                #expect(await coordinator.currentStatus().lifecycle == .starting)
                pane.app.attachTab(tab)
                finish.finish()
                try await reader.value
                await switching.value
                #expect(await coordinator.currentStatus().activeSharedFolderRoot?.path == second.path)
                await pane.app.closeTab(tab.id)
                await WebStorageRelocator.apply(mode: .local, workspace: workspace)
                #expect(await coordinator.currentStatus().effectiveMode == .local)
                #expect(await AiPersistence.loadConversation(for: doc, coordinator: coordinator) == [message])
                for root in [first, second] {
                    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".vellum/documents/" + key + "/scratchpad.md").path))
                    #expect(!fm.fileExists(atPath: root.appendingPathComponent(".vellum/documents/" + key + "/conversations.json").path))
                }
            } catch {
                await coordinator.stop()
                throw error
            }
            await coordinator.stop()
        }
    }

    @Test("Shared-folder layout matches iCloud paths and selects a distinct backend")
    func layout() {
        let root = URL(fileURLWithPath: "/fixture/library", isDirectory: true)
        let local = root.appendingPathComponent("local/web", isDirectory: true)
        let folder = WebStorageLayout.syncedFolder(root: root)
        let cloud = WebStorageLayout.iCloud(root: root)
        #expect(folder.rootDir == root)
        #expect(folder.recordsDir.path == "/fixture/library/.vellum/records")
        #expect(folder.recordsDir == cloud.recordsDir)
        #expect(folder.documentsDir.path == "/fixture/library/.vellum/documents")
        #expect(folder.positionsDir.path == "/fixture/library/.vellum/positions")
        #expect(folder.indexPath?.path == "/fixture/library/.vellum/index.json")
        #expect(folder.archivesDir.path == "/fixture/library/Web Pages")
        #expect(folder.pdfsDir?.path == "/fixture/library/PDFs")
        #expect(folder.pretty && folder.storesMetadataInRoot && folder.usesSyncedContainer)
        #expect(!folder.requiresICloudCoordination)
        #expect(cloud.requiresICloudCoordination)
        let custom = WebStorageLayout.custom(root: root, storeDir: local)
        #expect(!custom.usesSyncedContainer)
        #expect(custom.positionsDir == WebStorageLayout.local(storeDir: local).positionsDir)
    }

    @Test("Folder selection routes only through its factory and falls back safely", arguments: [false, true])
    func routeThroughFolderFactory(installBackend: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local/web", isDirectory: true)
        let layout = WebStorageLayout.syncedFolder(root: shared)
        let bookmark = Data("unresolvable fixture bookmark".utf8)
        let suite = "vellum.shared-folder-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        try await AppDefaults.withDefaults(defaults) {
            WebStorageSettings.selectSyncedFolder(path: shared.path, bookmark: bookmark)
            #expect(WebStorageSettings.chosenMode == .syncedFolder)
            #expect(defaults.data(forKey: WebStorageSettings.syncedFolderBookmarkKey) == bookmark)
            #expect(WebStorageLayout.resolve(mode: .syncedFolder, storeDir: local) == layout)
            #expect(WebStorageSettings.effectiveMode == .local)
            #expect(WebStorageMigrator.pendingMarker == nil)

            let fake = FakeSyncedContainer()
            let coordinator = StorageCoordinator(
                storeDir: local,
                rootResolver: { Issue.record("Shared storage called the ubiquity resolver"); return nil },
                containerFactory: { Issue.record("Shared storage called the iCloud factory"); return nil },
                folderContainerFactory: { requested in
                    #expect(requested == layout)
                    return installBackend ? fake : nil
                },
                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
            await coordinator.start()
            do {
                #expect(!fm.fileExists(atPath: shared.appendingPathComponent(".stignore").path))
                let status = await coordinator.currentStatus()
                #expect(status.effectiveMode == (installBackend ? .syncedFolder : .local))
                #expect(status.availability == (installBackend
                    ? .coordinated : .degradedToLocal(.syncedFolderBackendUnavailable)))
                #expect(status.acceptsCoordinatedOperations == installBackend)
                try await coordinator.withStorageContext { context in
                    switch context {
                    case .coordinated(let container, let activeLayout):
                        #expect(installBackend && activeLayout == layout)
                        #expect(container as? FakeSyncedContainer === fake)
                    case .direct(let activeLayout):
                        #expect(!installBackend && activeLayout == .local(storeDir: local))
                    }
                }

                try fm.removeItem(at: shared)
                await coordinator.foreground()
                let fallback = await coordinator.currentStatus()
                #expect(fallback.availability == .degradedToLocal(.syncedFolderUnavailable))
                #expect(fallback.effectiveMode == .local)
            } catch {
                await coordinator.stop()
                throw error
            }
            await coordinator.stop()
        }
    }

    @Test("The default shared-folder backend recovers a PDF conflict through the coordinator")
    func liveFolderBackend() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let pdfs = shared.appendingPathComponent("PDFs", isDirectory: true)
        try fm.createDirectory(at: pdfs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let ignoreFile = shared.appendingPathComponent(".stignore")
        let userRules = Data("// A local rule\r\n!keep-me".utf8)
        try userRules.write(to: ignoreFile)
        let canonical = pdfs.appendingPathComponent("book.pdf")
        let sibling = pdfs.appendingPathComponent("book.sync-conflict-20260122-151234-PEER.pdf")
        try Data([1]).write(to: canonical)
        try Data([2]).write(to: sibling)
        let suite = "vellum.shared-folder-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await AppDefaults.withDefaults(defaults) {
            WebStorageSettings.selectSyncedFolder(path: shared.path, bookmark: Data())
            let coordinator = StorageCoordinator(
                storeDir: root.appendingPathComponent("local/web"),
                rootResolver: { Issue.record("Unexpected ubiquity lookup"); return nil },
                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
            await coordinator.start()
            do {
                let active = await coordinator.currentStatus()
                #expect(active.effectiveMode == .syncedFolder)
                #expect(active.activeSharedFolderRoot == shared)
                #expect(StorageLocationCopy.sharedFolderFooter(status: active, deviceName: "Mac")
                    .contains("shared library storage"))
                let ignoreBytes = try Data(contentsOf: ignoreFile)
                #expect(ignoreBytes.starts(with: userRules))
                #expect(ignoreBytes.range(of: Data("// BEGIN VELLUM MANAGED".utf8)) != nil)
                let deadline = ContinuousClock.now + .seconds(5)
                while await coordinator.archivedConflicts().isEmpty, ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(25))
                }
                let archived = try #require(await coordinator.archivedConflicts().first)
                #expect(archived.originalURL.standardizedFileURL == canonical.standardizedFileURL)
                #expect(try Data(contentsOf: archived.archiveURL) == Data([2]))
                #expect(try Data(contentsOf: canonical) == Data([1]))
                #expect(!fm.fileExists(atPath: sibling.path))

                try fm.removeItem(at: shared)
                await coordinator.foreground()
                let fallback = await coordinator.currentStatus()
                #expect(fallback.activeSharedFolderRoot == nil)
                #expect(fallback.availability == .degradedToLocal(.syncedFolderUnavailable))
                #expect(StorageLocationCopy.sharedFolderFooter(status: fallback, deviceName: "Mac")
                    .contains("private local storage"))
            } catch { await coordinator.stop(); throw error }
            await coordinator.stop()
        }
    }

    @Test("Shared-folder preparation precedes backend construction", arguments: [false, true])
    func preparesIgnoreBeforeActivation(malformed: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let ignoreFile = shared.appendingPathComponent(".stignore")
        let original = Data("// user rule\n// END VELLUM MANAGED\n".utf8)
        if malformed { try original.write(to: ignoreFile) }
        let fake = FakeSyncedContainer()
        let coordinator = StorageCoordinator(
            storeDir: root.appendingPathComponent("local/web", isDirectory: true),
            modeProvider: { .syncedFolder },
            syncedFolderRootResolver: { shared },
            folderContainerFactory: StorageCoordinator.sharedFolderActivation { layout in
                #expect(!malformed)
                #expect(layout.rootDir == shared)
                let bytes = try? Data(contentsOf: ignoreFile)
                #expect(bytes?.range(of: Data("// BEGIN VELLUM MANAGED".utf8)) != nil)
                return fake
            },
            conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        await coordinator.start()
        let status = await coordinator.currentStatus()
        await coordinator.stop()

        #expect(status.effectiveMode == (malformed ? .local : .syncedFolder))
        #expect(status.availability == (malformed
            ? .degradedToLocal(.syncedFolderBackendUnavailable) : .coordinated))
        if malformed { #expect(try Data(contentsOf: ignoreFile) == original) }
    }

    @MainActor
    @Test("Storage settings actions recover an offline Scratchpad image after relaunch")
    func offlineScratchpadImage() async throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let root = temporary.appendingPathComponent("shared", isDirectory: true)
        let local = temporary.appendingPathComponent("local/web", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let previousStore = WebLibrary.storeDirOverride
        let previousDocuments = DocumentDataStore.rootDirectoryOverride
        WebLibrary.storeDirOverride = local
        DocumentDataStore.rootDirectoryOverride = nil
        defer {
            WebLibrary.storeDirOverride = previousStore
            DocumentDataStore.rootDirectoryOverride = previousDocuments
        }
        // Import a real PDF the same way a shared-folder user opens a local
        // file. The session's verified identity owns the scratchpad sidecars.
        let source = temporary.appendingPathComponent("Fixture.pdf")
        try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column")).write(to: source)
        let resolver = DocumentAccessResolver(
            store: DocumentAccessBookmarkStore(directory: temporary),
            adapter: SystemDocumentAccessAdapter(),
            libraryDirectory: { temporary.appendingPathComponent("managed") },
            appOwnedRoots: { [] }
        ).scoped(to: root)
        let backend = PdfSessionBackend()
        let document = try await resolver.openPickedPDF(url: source, sessionId: "scratchpad-fixture") { path, id in
            try await backend.open(path: path, sessionId: id).info
        }
        let key = try #require(document.docId)
        let title = try #require(document.title)
        let imported = URL(fileURLWithPath: document.pdfPath)
        let portablePath = "PDFs/Fixture.pdf"
        let importedBytes = try Data(contentsOf: imported)
        try #require(resolver.sharedPDFs?.relativePath(for: imported) == portablePath)
        try #require(SharedPDFImport.readID(importedBytes) == key)
        let attachments = WebStorageLayout.syncedFolder(root: root).documentsDir
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try fm.createDirectory(at: attachments, withIntermediateDirectories: true)
        let coordinator = StorageCoordinator(
            storeDir: local, modeProvider: { .syncedFolder },
            syncedFolderRootResolver: { root },
            conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        let workspace = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: coordinator)
        let name = "abc.png"
        let file = attachments.appendingPathComponent(name)
        let documentDirectory = attachments.deletingLastPathComponent()
        let note = documentDirectory.appendingPathComponent("scratchpad.md")
        let offlineNote = "![Image](attachments/\(name))"
        let bytes = Data([0, 1, 0xff])
        try bytes.write(to: file)
        let collision = attachments.appendingPathComponent("ccc.png")
        try bytes.write(to: collision)
        try Data(offlineNote.utf8).write(to: note)
        let batchID: String
        await coordinator.start()
        do {
            try #require(await coordinator.currentStatus().effectiveMode == .syncedFolder)
            let committed = await ScratchpadPersistence.save(
                forKey: key, document: document, schemeText: "Local edit",
                expectedBaseline: ScratchpadPersistence.relativeToScheme(offlineNote),
                attachments: [], dirtyAttachmentNames: [], coordinator: coordinator)
            try #require(committed == "Local edit")
            #expect(try Data(contentsOf: note) == Data("Local edit".utf8))
            #expect(try Data(contentsOf: file) == bytes)
            let meta = try await DocumentDataStore.loadMeta(forKey: key, coordinator: coordinator)
            #expect(meta?.lastKnownPath == portablePath)

            let inventory = try await ScratchpadAttachmentCleanup.inventory(coordinator: coordinator)
            let row = try #require(inventory.documents.first(where: { $0.id == key }))
            #expect(row.title == title)
            #expect(row.hasAttachments)
            let newer = attachments.appendingPathComponent("ddd.png")
            try bytes.write(to: newer)
            try fm.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: newer.path)
            let batch = try #require(try await workspace
                .cleanSharedScratchpadAttachments(forKey: key, inventory: inventory))
            batchID = batch.name
            #expect(try Data(contentsOf: newer) == bytes)
            #expect(try Data(contentsOf: batch.directory.appendingPathComponent(name)) == bytes)
            #expect(batch.retainUntil.timeIntervalSinceNow > 29 * 24 * 60 * 60)
            let arriving = documentDirectory.appendingPathComponent(
                "scratchpad.sync-conflict-20261126-120000-PEER.md")
            try Data(offlineNote.utf8).write(to: arriving, options: .atomic)
            let deadline = ContinuousClock.now + .seconds(5)
            while await coordinator.archivedConflicts().isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let archive = try #require(await coordinator.archivedConflicts().first)
            #expect(try Data(contentsOf: archive.archiveURL) == Data(offlineNote.utf8))
            let conflicts = archive.archiveURL.deletingLastPathComponent()
            let archived = conflicts.appendingPathComponent("scratchpad.peer.md")
            let archivedFile = attachments.appendingPathComponent("def.png")
            try Data("50% done. ![Image](attachments/%64ef.png)".utf8).write(to: archived)
            try bytes.write(to: archivedFile)
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()

        // A new coordinator and workspace have no in-memory batch history.
        let relaunched = StorageCoordinator(
            storeDir: local, modeProvider: { .syncedFolder },
            syncedFolderRootResolver: { root },
            conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        let reopened = WorkspaceStore(sessions: DocumentSessionManager(), storageCoordinator: relaunched)
        await relaunched.start()
        do {
            let inventory = try await ScratchpadAttachmentCleanup.inventory(coordinator: relaunched)
            let stored = try #require(inventory.documents.first?.batches.first)
            #expect(stored.id == batchID)
            #expect(stored.files == [name, "ccc.png"])
            let newer = Data([9, 8, 7])
            try newer.write(to: collision)
            let result = try await reopened.restoreSharedScratchpadBatch(
                named: stored.id, forKey: key, inventory: inventory)
            #expect(result.restored == 1)
            #expect(result.keptInRecovery == 1)
            #expect(try Data(contentsOf: file) == bytes)
            #expect(try Data(contentsOf: collision) == newer)
            let remaining = try await ScratchpadAttachmentCleanup.inventory(coordinator: relaunched)
            #expect(remaining.documents.first?.batches.first?.files == ["ccc.png"])
            let secondCleanup = try await reopened.cleanSharedScratchpadAttachments(
                forKey: key, inventory: inventory)
            #expect(secondCleanup == nil)
            let archivedFile = attachments.appendingPathComponent("def.png")
            #expect(try Data(contentsOf: archivedFile) == bytes)
        } catch {
            await relaunched.stop()
            throw error
        }
        await relaunched.stop()
    }

    @Test("An out-of-root shared PDF cannot update or clear Scratchpad bytes", arguments: [false, true])
    func ineligibleSharedPDFDoesNotWriteScratchpad(clearing: Bool) async throws {
        let (root, key, attachments) = try scratchpadFixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let local = root.appendingPathComponent("local/web", isDirectory: true)
        let previousStore = WebLibrary.storeDirOverride
        let previousDocuments = DocumentDataStore.rootDirectoryOverride
        WebLibrary.storeDirOverride = local
        DocumentDataStore.rootDirectoryOverride = nil
        defer {
            WebLibrary.storeDirOverride = previousStore
            DocumentDataStore.rootDirectoryOverride = previousDocuments
        }

        let source = root.appendingPathComponent("Outside.pdf")
        try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column")).write(to: source)
        let document = DocumentInfo(
            kind: .pdf, pdfPath: source.path, title: "Outside", pageCount: 1, lastPage: 1, docId: key)
        let container = FakeSyncedContainer()
        let coordinator = StorageCoordinator(
            storeDir: local, modeProvider: { .syncedFolder },
            syncedFolderRootResolver: { root }, folderContainerFactory: { _ in container },
            conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        let directory = attachments.deletingLastPathComponent()
        let noteURL = directory.appendingPathComponent("scratchpad.md")
        let metadataURL = directory.appendingPathComponent("meta.json")
        let existingImage = attachments.appendingPathComponent("abc.png")
        let newImage = attachments.appendingPathComponent("def.png")
        let note = "Saved draft ![image](attachments/abc.png)"
        let metadata = Data(#"{"version":1,"kind":"pdf","title":"Saved title","last_known_path":"PDFs/Saved.pdf","last_opened":"2026-11-26T12:00:00Z"}"#.utf8)
        let imageBytes = Data([1, 2, 3])
        container.seed(noteURL, data: Data(note.utf8))
        container.seed(metadataURL, data: metadata)
        container.seed(existingImage, data: imageBytes)

        await coordinator.start()
        do {
            try #require(await coordinator.currentStatus().effectiveMode == .syncedFolder)
            let staged: [ScratchpadStagedAttachment] = clearing ? [] : [
                .init(id: "abc", name: "abc.png", data: Data([4])),
                .init(id: "def", name: "def.png", data: Data([5])),
            ]
            let result = await ScratchpadPersistence.save(
                forKey: key, document: document,
                schemeText: clearing ? "" : "New draft ![image](vellum-scratchpad://def)",
                expectedBaseline: ScratchpadPersistence.relativeToScheme(note),
                attachments: staged, dirtyAttachmentNames: Set(staged.map(\.name)),
                coordinator: coordinator)
            #expect(result == nil)
            #expect(container.coordinatedWriteCount == 0)
            #expect(container.coordinatedRemoveCount == 0)
            #expect(container.peek(noteURL) == Data(note.utf8))
            #expect(container.peek(metadataURL) == metadata)
            #expect(container.peek(existingImage) == imageBytes)
            #expect(container.peek(newImage) == nil)
        } catch {
            await coordinator.stop()
            throw error
        }
        await coordinator.stop()
    }

    @Test("Legacy attachment collection respects the selected storage mode")
    func legacyScratchpadCollection() async throws {
        let (root, _, attachments) = try scratchpadFixture()
        let previous = ScratchpadAttachmentStore.directoryOverride
        let previousMode = WebStorageSettings.modeOverride
        ScratchpadAttachmentStore.directoryOverride = attachments
        WebStorageSettings.modeOverride = nil
        defer {
            ScratchpadAttachmentStore.directoryOverride = previous
            WebStorageSettings.modeOverride = previousMode
            try? FileManager.default.removeItem(at: root)
        }
        let suite = "vellum.scratchpad-cleanup.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let file = attachments.appendingPathComponent("abc.png")
        let bytes = Data([0x42])
        try bytes.write(to: file)
        await AppDefaults.withDefaults(defaults) {
            WebStorageSettings.setMode(.syncedFolder)
            await ScratchpadAttachmentStore.collectGarbage(forTexts: [], referencedAsOf: .distantFuture)
            #expect((try? Data(contentsOf: file)) == bytes)
            WebStorageSettings.setMode(.local)
            await ScratchpadAttachmentStore.collectGarbage(forTexts: [], referencedAsOf: .distantFuture)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test("Incomplete or unsafe scans leave every attachment in place")
    func scratchpadCleanupFailsClosed() throws {
        let (root, key, attachments) = try scratchpadFixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let file = attachments.appendingPathComponent("abc.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: file)
        let document = attachments.deletingLastPathComponent()
        let conflicts = document.appendingPathComponent("conflicts")
        // A file masquerading as a directory is an enumeration failure.
        try bytes.write(to: conflicts)
        #expect(throws: (any Error).self) {
            try ScratchpadAttachmentCleanup.moveUnreferencedAttachments(forKey: key, root: root)
        }
        try fm.removeItem(at: conflicts)
        try fm.createDirectory(at: conflicts, withIntermediateDirectories: false)
        let malformedNote = conflicts.appendingPathComponent("scratchpad.peer.md")
        try Data([0xff]).write(to: malformedNote)
        #expect(throws: (any Error).self) {
            try ScratchpadAttachmentCleanup.moveUnreferencedAttachments(forKey: key, root: root)
        }
        try fm.removeItem(at: malformedNote)
        let outside = root.appendingPathComponent("unrelated", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let trash = root.appendingPathComponent(".vellum/trash")
        try fm.createSymbolicLink(at: trash, withDestinationURL: outside)
        #expect(throws: (any Error).self) {
            try ScratchpadAttachmentCleanup.moveUnreferencedAttachments(forKey: key, root: root)
        }
        #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try Data(contentsOf: file) == bytes)
    }

    @Test("A failed later move leaves earlier bytes recoverable and preserves unknown names")
    func partialScratchpadCleanup() throws {
        let (root, key, attachments) = try scratchpadFixture()
        let fm = FileManager.default
        defer { try? fm.removeItem(at: root) }
        let first = attachments.appendingPathComponent("aaa.png")
        let second = attachments.appendingPathComponent("bbb.png")
        let malformed = attachments.appendingPathComponent("abc.extra.png")
        let bytes = Data([1, 2, 3])
        for file in [first, second, malformed] { try bytes.write(to: file) }
        try #require(chflags(second.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { _ = chflags(second.path, 0) }
        do {
            _ = try ScratchpadAttachmentCleanup.moveUnreferencedAttachments(forKey: key, root: root)
            Issue.record("An immutable attachment unexpectedly moved")
        } catch ScratchpadAttachmentCleanup.CleanupError.partialCleanup(let batch, _) {
            #expect(try Data(contentsOf: second) == bytes)
            #expect(try Data(contentsOf: malformed) == bytes)
            #expect(try Data(contentsOf: batch.directory.appendingPathComponent("aaa.png")) == bytes)
            try Data([0x42]).write(to: first)
            #expect(throws: (any Error).self) {
                try ScratchpadAttachmentCleanup.restoreAttachment(
                    named: "aaa.png", fromBatch: batch.name, forKey: key, root: root)
            }
            #expect(try Data(contentsOf: first) == Data([0x42]))
            try fm.removeItem(at: first)
            try ScratchpadAttachmentCleanup.restoreAttachment(
                named: "aaa.png", fromBatch: batch.name, forKey: key, root: root)
            #expect(try Data(contentsOf: first) == bytes)
        }
    }

    private func scratchpadFixture() throws -> (root: URL, key: String, attachments: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-scratchpad-cleanup-\(UUID())", isDirectory: true)
        let key = UUID().uuidString.lowercased()
        let attachments = WebStorageLayout.syncedFolder(root: root).documentsDir
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("attachments", isDirectory: true)
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        return (root, key, attachments)
    }
}
#endif
