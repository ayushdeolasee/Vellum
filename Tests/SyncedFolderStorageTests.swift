#if os(macOS)
import Foundation
import Testing

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
}
#endif
