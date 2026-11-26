import Foundation
import Testing
import VellumCore

@testable import Vellum

@Suite(.serialized, .isolatedStorage)
struct InkCapabilityAdvertisingTests {
    @Test("Only eligible shared storage advertises the hosted app build and binds new position bytes",
          arguments: [false, true])
    func advertisesHandwritingCapability(eligible: Bool) async throws {
        try await withFixture { shared, local in
            let build = try #require(StorageCoordinator.liveInkCapabilityBuild)
            let version = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            let buildNumber = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            #if os(macOS)
            let platform = "macOS"
            #else
            let platform = "iOS"
            #endif
            #expect(build == "\(platform)/\(version) (\(buildNumber))")

            let device = DeviceIdentity.current()
            let layout = WebStorageLayout.syncedFolder(root: shared)
            let directory = InkCapabilityStore.directory(in: shared)
            let advertisement = directory.appendingPathComponent(device.id.rawValue + ".json")
            // Use the folder backend in the hosted sandbox. The injected
            // root bypasses the platform picker and resolver, including on iPad.
            let coordinator = StorageCoordinator(
                storeDir: local, modeProvider: { .syncedFolder },
                syncedFolderRootResolver: { shared },
                folderContainerFactory: StorageCoordinator.sharedFolderActivation { requested in
                    #expect(requested == layout)
                    return await SharedFolderContainerFactory.make(root: requested.rootDir)
                },
                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }),
                inkCapabilityBuild: eligible ? build : nil)
            await coordinator.start()
            do {
                try #require(await coordinator.currentStatus().effectiveMode == .syncedFolder)
                #expect(FileManager.default.fileExists(atPath: advertisement.path) == eligible)
                let position = PositionDeviceRecord(deviceID: device.id, deviceName: device.name,
                                                    devicePlatform: device.platform, writtenAt: .now)
                try await CoordinatedPositionStorage(coordinator: coordinator).write(position)

                if eligible {
                    let url = try PositionLayout.fileURL(in: layout.positionsDir, for: device.id)
                    let bytes = try Data(contentsOf: url)
                    let fields = try JSONDecoder().decode([String: JSONValue].self, from: Data(contentsOf: advertisement))
                    #expect(fields["app_build"] == .string(build))
                    #expect(fields["device_id"] == .string(device.id.rawValue))
                    #expect(fields["features"] == .array([.string(InkCapabilityStore.feature)]))
                    #expect(fields["position_sha256"] == .string(DocumentIdentity.byteHash(bytes)))
                } else {
                    #expect(!FileManager.default.fileExists(atPath: directory.path))
                }
            } catch {
                await coordinator.stop()
                throw error
            }
            await coordinator.stop()

            let localCoordinator = StorageCoordinator(storeDir: local, modeProvider: { .local },
                                                      inkCapabilityBuild: build)
            await localCoordinator.start()
            await localCoordinator.stop()
            #expect(!FileManager.default.fileExists(atPath: InkCapabilityStore.directory(in: local).path))
        }
    }

    #if os(iOS)
    @Test("iOS production shared-folder resolution falls back without shared capability evidence")
    func productionSharedFolderSelectionFallsBackWithoutAdvertising() async throws {
        try await withFixture { shared, local in
            WebStorageSettings.selectSyncedFolder(path: shared.path, bookmark: Data())
            #expect(await WebStorageSettings.resolveSyncedFolderRoot() == nil)
            let build = try #require(StorageCoordinator.liveInkCapabilityBuild)
            let coordinator = StorageCoordinator(
                storeDir: local, modeProvider: { .syncedFolder },
                folderContainerFactory: { _ in
                    Issue.record("The iOS production resolver admitted an unavailable shared root")
                    return nil
                },
                conflictArchiveRegistry: .init(load: { [] }, save: { _ in }),
                inkCapabilityBuild: build)

            let positions = WebStorageLayout.local(storeDir: local).positionsDir
            let previousRoot = PositionLayout.rootOverride
            PositionLayout.rootOverride = positions
            defer { PositionLayout.rootOverride = previousRoot }

            await coordinator.start()
            do {
                let status = await coordinator.currentStatus()
                #expect(status.chosenMode == .syncedFolder)
                #expect(status.effectiveMode == .local)
                #expect(status.availability == .degradedToLocal(.syncedFolderUnavailable))
                #expect(!status.acceptsCoordinatedOperations)
                let device = DeviceIdentity.current()
                let position = PositionDeviceRecord(deviceID: device.id, deviceName: device.name,
                                                    devicePlatform: device.platform, writtenAt: .now)
                try await CoordinatedPositionStorage(coordinator: coordinator).write(position)
                let localPosition = try PositionLayout.fileURL(in: positions, for: device.id)
                #expect(FileManager.default.fileExists(atPath: localPosition.path))
                #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
            } catch {
                await coordinator.stop()
                throw error
            }
            await coordinator.stop()
        }
    }
    #endif

    private func withFixture(_ run: (URL, URL) async throws -> Void) async throws {
        try #require(TestEnvironment.isHostedTestProcess)
        try #require(RuntimeProfile.current.syncEnabled)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let shared = root.appendingPathComponent("shared", isDirectory: true)
        let local = root.appendingPathComponent("local/web", isDirectory: true)
        try fm.createDirectory(at: shared, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let suite = "vellum.ink-capability-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try await AppDefaults.withDefaults(defaults) { try await run(shared, local) }
    }
}
