import Foundation
import Testing

@testable import Vellum

@Suite("Storage coordinator — relocation contexts")
struct StorageRelocationContextTests {
    @Test("Local to iCloud lends direct and coordinated stores with position roots")
    func localToICloudContexts() async throws {
        let localStore = URL(fileURLWithPath: "/local/web", isDirectory: true)
        let cloudRoot = URL(fileURLWithPath: "/cloud/Vellum", isDirectory: true)
        let local = WebStorageLayout.local(storeDir: localStore)
        let cloud = WebStorageLayout.pretty(
            root: cloudRoot, recordsInRoot: true, localStoreDir: localStore)
        let container = FakeSyncedContainer()
        let coordinator = StorageCoordinator(
            storeDir: localStore,
            modeProvider: { .local },
            effectiveModeProvider: { .local },
            rootResolver: { cloudRoot },
            containerFactory: { container })
        await coordinator.start()
        let position = cloud.positionsDir.appendingPathComponent("phone.v1.json")

        let moved = await coordinator.performExclusiveStorageRelocation(
            from: local, to: cloud
        ) { source, destination in
            guard let source, let destination else { return false }
            #expect(source.fileStore.isCoordinated == false)
            #expect(destination.fileStore.isCoordinated)
            do {
                try await destination.fileStore.replace(position, with: Data("position".utf8))
                return true
            } catch {
                Issue.record("Coordinated destination write failed: \(error)")
                return false
            }
        }

        #expect(moved)
        #expect(container.peek(position) == Data("position".utf8))
        #expect(container.isSuspended)
        #expect(container.presenterRemovals == 1)
        #expect(local.positionsDir == URL(fileURLWithPath: "/local/positions", isDirectory: true))
        #expect(cloud.positionsDir == URL(fileURLWithPath: "/cloud/Vellum/.vellum/positions", isDirectory: true))
    }

    @Test("Unavailable iCloud never becomes a direct writable destination")
    func unavailableDestinationStaysUnavailable() async {
        let localStore = URL(fileURLWithPath: "/local/web", isDirectory: true)
        let cloudRoot = URL(fileURLWithPath: "/cloud/Vellum", isDirectory: true)
        let local = WebStorageLayout.local(storeDir: localStore)
        let cloud = WebStorageLayout.pretty(
            root: cloudRoot, recordsInRoot: true, localStoreDir: localStore)
        let coordinator = StorageCoordinator(
            storeDir: localStore,
            modeProvider: { .local },
            effectiveModeProvider: { .local },
            rootResolver: { cloudRoot },
            containerFactory: { nil })
        await coordinator.start()

        let hasDestination = await coordinator.performExclusiveStorageRelocation(
            from: local, to: cloud
        ) { _, destination in
            destination != nil
        }

        #expect(hasDestination == false)
    }
}
