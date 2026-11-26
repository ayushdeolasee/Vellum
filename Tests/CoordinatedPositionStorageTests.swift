import Foundation
import Testing

@testable import Vellum

@Suite("Position store — coordinated storage", .serialized, .isolatedStorage)
struct CoordinatedPositionStorageTests {
    private let cloudRoot = URL(fileURLWithPath: "/test-cloud/Vellum", isDirectory: true)

    @Test("Direct reads, writes, and quarantine follow the active layout", arguments: [
        WebStorageMode.local, .custom,
    ])
    func directStorageFollowsLayout(mode: WebStorageMode) async throws {
        let hostedRoot = try #require(TestEnvironment.storageRoot)
        let root = PositionFixtures.scratchDirectory("position-layout")
        defer { PositionFixtures.remove(root) }
        let localRoot = root.appendingPathComponent("app-data", isDirectory: true)
        let storeDir = localRoot.appendingPathComponent("web", isDirectory: true)
        let customRoot = root.appendingPathComponent("custom", isDirectory: true)
        try FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)
        let previousCustomRoot = WebStorageSettings.customRootOverride
        let previousPositionRoot = PositionLayout.rootOverride
        WebStorageSettings.customRootOverride = customRoot
        PositionLayout.rootOverride = nil
        defer {
            WebStorageSettings.customRootOverride = previousCustomRoot
            PositionLayout.rootOverride = previousPositionRoot
        }
        #expect(PositionLayout.root == hostedRoot.appendingPathComponent("positions", isDirectory: true))

        let coordinator = StorageCoordinator(
            storeDir: storeDir, modeProvider: { mode }, effectiveModeProvider: { mode })
        await coordinator.start()
        let storage = CoordinatedPositionStorage(coordinator: coordinator)
        let positionsRoot = localRoot.appendingPathComponent("positions", isDirectory: true)
        let date = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let phone = PositionFixtures.record(.phone, writtenAt: date, documents: [:])
        let pad = PositionFixtures.record(.pad, writtenAt: date, documents: [:])
        let corruptName = PositionLayout.fileName(for: PositionFixtures.mac.id)
        let corruptURL = positionsRoot.appendingPathComponent(corruptName)
        let corruptBytes = Data("not-json".utf8)
        try await FilePositionStorage(root: positionsRoot).write(pad)
        try corruptBytes.write(to: corruptURL)

        let loaded = await storage.loadAll()
        try #require(loaded.map(\.deviceID) == [pad.deviceID])
        #expect(!FileManager.default.fileExists(atPath: corruptURL.path))
        let quarantineURL = positionsRoot.appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(corruptName)
        #expect(try Data(contentsOf: quarantineURL) == corruptBytes)

        try await storage.write(phone)
        let name = PositionLayout.fileName(for: phone.deviceID)
        let savedURL = positionsRoot.appendingPathComponent(name)
        let phoneBytes = try PositionCoding.encoder.encode(phone)
        #expect(try Data(contentsOf: savedURL) == phoneBytes)
        #expect(!FileManager.default.fileExists(
            atPath: customRoot.appendingPathComponent(".vellum/positions").path))
        #expect(!FileManager.default.fileExists(
            atPath: PositionLayout.root.appendingPathComponent(name).path))

        let overrideRoot = root.appendingPathComponent("override", isDirectory: true)
        PositionLayout.rootOverride = overrideRoot
        #expect(await storage.loadAll().isEmpty)
        try await storage.write(pad)
        #expect(await storage.loadAll().map(\.deviceID) == [pad.deviceID])
        #expect(FileManager.default.fileExists(atPath: overrideRoot.appendingPathComponent(
            PositionLayout.fileName(for: pad.deviceID)).path))
        #expect(try Data(contentsOf: savedURL) == phoneBytes)
    }

    @Test("iCloud writes and loads current peer records only through the coordination seam")
    func coordinatedRoundTripUsesMetadataAndAtomicReplace() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let storage = CoordinatedPositionStorage(coordinator: coordinator)
        let positionsRoot = cloudRoot.appendingPathComponent(".vellum/positions", isDirectory: true)
        let phoneURL = positionsRoot.appendingPathComponent(
            PositionLayout.fileName(for: PositionFixtures.phone.id))
        let padURL = positionsRoot.appendingPathComponent(
            PositionLayout.fileName(for: PositionFixtures.pad.id))
        let date = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let phone = PositionFixtures.record(
            .phone, writtenAt: date,
            documents: [.web(normalizedURL: "https://example.com"): .init(openedAt: date)])
        let pad = PositionFixtures.record(.pad, writtenAt: date, documents: [:])
        container.seed(
            padURL,
            data: try PositionCoding.encoder.encode(pad),
            readiness: .downloaded)

        try await storage.write(phone)
        let loaded = await storage.loadAll()
        let expectedPhoneBytes = try PositionCoding.encoder.encode(phone)

        #expect(container.peek(phoneURL) == expectedPhoneBytes)
        #expect(loaded.map(\.deviceID) == [PositionFixtures.phone.id])
        #expect(container.coordinatedWriteCount == 1)
        #expect(container.forReplacingWriteCount == 1)
        #expect(container.metadataQueryCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    @Test("A corrupt iCloud peer is preserved and copied to quarantine")
    func corruptPeerIsPreservedAndQuarantined() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let storage = CoordinatedPositionStorage(coordinator: coordinator)
        let positionsRoot = cloudRoot.appendingPathComponent(".vellum/positions", isDirectory: true)
        let name = PositionLayout.fileName(for: PositionFixtures.pad.id)
        let source = positionsRoot.appendingPathComponent(name)
        let quarantine = positionsRoot
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(name)
        let corrupt = Data("not-json".utf8)
        container.seed(source, data: corrupt)

        let loaded = await storage.loadAll()

        #expect(loaded.isEmpty)
        #expect(container.peek(source) == corrupt)
        #expect(container.peek(quarantine) == corrupt)
    }

    private func makeCoordinator(container: FakeSyncedContainer) -> StorageCoordinator {
        StorageCoordinator(
            storeDir: URL(fileURLWithPath: "/test-local/web", isDirectory: true),
            modeProvider: { .icloud },
            effectiveModeProvider: { .icloud },
            rootResolver: { cloudRoot },
            containerFactory: { container })
    }
}
