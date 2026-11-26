#if os(macOS)
import Darwin
import Foundation
import Testing
import VellumCore

@testable import Vellum

@Suite("Shared folder storage", .serialized, .isolatedStorage)
struct SyncedFolderStorageTests {
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
                #expect(await coordinator.currentStatus().effectiveMode == .syncedFolder)
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
            } catch { await coordinator.stop(); throw error }
            await coordinator.stop()
        }
    }

    @Test("Only eligible shared storage advertises the actual build and new position bytes",
          arguments: [false, true])
    func advertisesHandwritingCapability(eligible: Bool) async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/web", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "vellum.ink-capability-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await AppDefaults.withDefaults(defaults) {
            let id = DeviceIdentity.current().id
            let layout = WebStorageLayout.syncedFolder(root: shared)
            let directory = InkCapabilityStore.directory(in: shared)
            let advertisement = directory.appendingPathComponent(id.rawValue + ".json")
            let build = "macOS/0.1.1 (fixture)"
            let sharedCoordinator = StorageCoordinator(
                storeDir: local, modeProvider: { .syncedFolder }, syncedFolderRootResolver: { shared },
                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }),
                inkCapabilityBuild: eligible ? build : nil)
            let position = PositionDeviceRecord(deviceID: id, deviceName: "Fixture",
                                                devicePlatform: "macos", writtenAt: .now)
            await sharedCoordinator.start()
            do {
                #expect(fm.fileExists(atPath: advertisement.path) == eligible)
                try await CoordinatedPositionStorage(coordinator: sharedCoordinator).write(position)
                if eligible {
                    let url = try PositionLayout.fileURL(in: layout.positionsDir, for: id)
                    let bytes = try Data(contentsOf: url)
                    let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: advertisement))
                    #expect(fields["app_build"] == .string(build))
                    #expect(fields["device_id"] == .string(id.rawValue))
                    #expect(fields["position_sha256"] == .string(DocumentIdentity.byteHash(bytes)))
                } else {
                    #expect(!fm.fileExists(atPath: directory.path))
                }
            } catch {
                await sharedCoordinator.stop()
                throw error
            }
            await sharedCoordinator.stop()

            let localCoordinator = StorageCoordinator(storeDir: local, modeProvider: { .local },
                                                      inkCapabilityBuild: build)
            await localCoordinator.start()
            await localCoordinator.stop()
            #expect(!fm.fileExists(atPath: InkCapabilityStore.directory(in: local).path))
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
        let document = DocumentInfo(
            kind: .pdf, pdfPath: root.appendingPathComponent("fixture.pdf").path,
            title: "Fixture", pageCount: 1, lastPage: 1, docId: key)

        let batchID: String
        await coordinator.start()
        do {
            try #require(await coordinator.currentStatus().effectiveMode == .syncedFolder)
            let committed = await ScratchpadPersistence.save(
                forKey: key, document: document, schemeText: "Local edit",
                expectedBaseline: ScratchpadPersistence.relativeToScheme(offlineNote),
                attachments: [], dirtyAttachmentNames: [], coordinator: coordinator)
            #expect(committed == "Local edit")
            #expect(try Data(contentsOf: note) == Data("Local edit".utf8))
            #expect(try Data(contentsOf: file) == bytes)

            let inventory = try await ScratchpadAttachmentCleanup.inventory(coordinator: coordinator)
            #expect(inventory.documents.first?.title == "Fixture")
            #expect(inventory.documents.first?.hasAttachments == true)
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
