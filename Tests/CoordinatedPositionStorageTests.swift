import Foundation
import Testing

@testable import Vellum

@Suite("Position store — coordinated storage")
struct CoordinatedPositionStorageTests {
    private let cloudRoot = URL(fileURLWithPath: "/test-cloud/Vellum", isDirectory: true)

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
