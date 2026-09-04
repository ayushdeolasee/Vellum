import Foundation
import Testing

@testable import Vellum

@Suite("Storage relocation — coordinated side")
struct RelocationCoordinationTests {
    @Test("Legacy Mac iCloud data copies into the coordinated shared container")
    func legacyMacICloudImportPreservesSource() async throws {
        let root = PositionFixtures.scratchDirectory("legacy-mac-icloud-import")
        defer { PositionFixtures.remove(root) }

        let storeDir = root.appendingPathComponent("local/web", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy/Vellum", isDirectory: true)
        let sharedRoot = root.appendingPathComponent("shared/Documents/Vellum", isDirectory: true)
        let source = WebStorageLayout.pretty(
            root: legacyRoot,
            recordsInRoot: true,
            localStoreDir: storeDir)
        let destination = WebStorageLayout.pretty(
            root: sharedRoot,
            recordsInRoot: true,
            localStoreDir: storeDir)
        let recordURL = source.recordsDir.appendingPathComponent("legacy.json")
        let destinationRecordURL = destination.recordsDir.appendingPathComponent("legacy.json")
        var sourceRecord = WebPageRecord(url: "https://example.com/legacy")
        sourceRecord.loadingPolicy = "snapshot-only"
        sourceRecord.saved = true
        sourceRecord.savedAt = "2026-09-01T00:00:00Z"
        let bytes = try WebLibrary.jsonEncoderPretty.encode(sourceRecord)
        try await DirectLibraryFileStore().replace(recordURL, with: bytes)

        let container = FakeSyncedContainer()
        var destinationRecord = WebPageRecord(url: sourceRecord.url)
        destinationRecord.loadingPolicy = "live-first"
        container.seed(
            destinationRecordURL,
            data: try WebLibrary.jsonEncoderPretty.encode(destinationRecord))
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { .icloud },
            effectiveModeProvider: { .icloud },
            rootResolver: { sharedRoot },
            containerFactory: { container },
            conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        await coordinator.start()

        let moved = await WebStorageMigrator.migrateLegacyICloudRoot(
            legacyRoot,
            to: destination,
            coordinator: coordinator)
        var userRecord = try JSONDecoder().decode(
            WebPageRecord.self,
            from: try #require(container.peek(destinationRecordURL)))
        userRecord.saved = false
        userRecord.savedAt = nil
        userRecord.title = "User title"
        try await CoordinatedLibraryFileStore(container: container).replace(
            destinationRecordURL,
            with: try WebLibrary.jsonEncoderPretty.encode(userRecord))
        let writesAfterUserChange = container.coordinatedWriteCount
        let repeated = await WebStorageMigrator.migrateLegacyICloudRoot(
            legacyRoot,
            to: destination,
            coordinator: coordinator)

        #expect(moved)
        #expect(repeated)
        #expect(try await DirectLibraryFileStore().read(recordURL) == bytes)
        let importedBytes = try #require(container.peek(destinationRecordURL))
        let imported = try JSONDecoder().decode(WebPageRecord.self, from: importedBytes)
        #expect(imported.loadingPolicy == "snapshot-only")
        #expect(!imported.saved)
        #expect(imported.savedAt == nil)
        #expect(imported.title == "User title")
        #expect(writesAfterUserChange == 2)
        #expect(container.coordinatedWriteCount == writesAfterUserChange)
        #expect(container.metadataQueryCount > 0)
        await coordinator.stop()
    }

    @Test("An unequal legacy archive collision preserves both copies")
    func unequalLegacyArchiveCollisionStaysPending() async throws {
        let root = PositionFixtures.scratchDirectory("legacy-archive-collision")
        defer { PositionFixtures.remove(root) }

        let storeDir = root.appendingPathComponent("local/web", isDirectory: true)
        let legacyRoot = root.appendingPathComponent("legacy/Vellum", isDirectory: true)
        let sharedRoot = root.appendingPathComponent("shared/Documents/Vellum", isDirectory: true)
        let source = WebStorageLayout.pretty(
            root: legacyRoot,
            recordsInRoot: true,
            localStoreDir: storeDir)
        let destination = WebStorageLayout.pretty(
            root: sharedRoot,
            recordsInRoot: true,
            localStoreDir: storeDir)
        let key = "collision"
        let sourceName = "Legacy.vellumweb"
        let destinationName = "Shared.vellumweb"
        let sourceURL = source.archivesDir.appendingPathComponent(sourceName)
        let destinationURL = destination.archivesDir.appendingPathComponent(destinationName)
        let sourceBytes = Data("legacy".utf8)
        let destinationBytes = Data("shared".utf8)
        var sourceIndex = WebArchiveIndex.Contents()
        sourceIndex.entries[key] = sourceName
        var destinationIndex = WebArchiveIndex.Contents()
        destinationIndex.entries[key] = destinationName
        let direct = DirectLibraryFileStore()
        try await direct.replace(sourceURL, with: sourceBytes)
        try await direct.replace(
            try #require(source.indexPath),
            with: try WebLibrary.jsonEncoderPretty.encode(sourceIndex))

        let container = FakeSyncedContainer()
        container.seed(destinationURL, data: destinationBytes)
        container.seed(
            try #require(destination.indexPath),
            data: try WebLibrary.jsonEncoderPretty.encode(destinationIndex))
        let coordinator = StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { .icloud },
            effectiveModeProvider: { .icloud },
            rootResolver: { sharedRoot },
            containerFactory: { container },
            conflictArchiveRegistry: .init(load: { [] }, save: { _ in }))
        await coordinator.start()

        let moved = await WebStorageMigrator.migrateLegacyICloudRoot(
            legacyRoot,
            to: destination,
            coordinator: coordinator)

        #expect(!moved)
        #expect(try await direct.read(sourceURL) == sourceBytes)
        #expect(container.peek(destinationURL) == destinationBytes)
        await coordinator.stop()
    }

    @Test("A stale iCloud file stays pending while current data and positions move")
    func staleFileKeepsSourceAndRetryFinishes() async throws {
        let destinationRoot = PositionFixtures.scratchDirectory("coordinated-relocation")
        defer { PositionFixtures.remove(destinationRoot) }

        let cloudRoot = URL(fileURLWithPath: "/test-cloud/Vellum", isDirectory: true)
        let localStoreDir = destinationRoot.appendingPathComponent("web", isDirectory: true)
        let source = WebStorageLayout.pretty(
            root: cloudRoot,
            recordsInRoot: true,
            localStoreDir: localStoreDir)
        let destination = WebStorageLayout.local(storeDir: localStoreDir)
        let container = FakeSyncedContainer()
        let sourceStore = CoordinatedLibraryFileStore(container: container)
        let destinationStore = DirectLibraryFileStore()

        let currentKey = WebLibrary.pageKey("https://example.com/current")
        let staleKey = WebLibrary.pageKey("https://example.com/stale")
        var currentRecord = WebPageRecord(url: "https://example.com/current")
        currentRecord.title = "Current Article"
        let staleRecord = WebPageRecord(url: "https://example.com/stale")
        let currentRecordURL = source.recordsDir.appendingPathComponent("\(currentKey).json")
        let staleRecordURL = source.recordsDir.appendingPathComponent("\(staleKey).json")
        container.seed(
            currentRecordURL,
            data: try WebLibrary.jsonEncoderPretty.encode(currentRecord))
        container.seed(
            staleRecordURL,
            data: try WebLibrary.jsonEncoderPretty.encode(staleRecord),
            readiness: .notDownloaded)

        let archiveName = "Current Article.vellumweb"
        let archiveURL = source.archivesDir.appendingPathComponent(archiveName)
        container.seed(archiveURL, data: Data("archive".utf8))
        var index = WebArchiveIndex.Contents()
        index.entries[currentKey] = archiveName
        container.seed(
            try #require(source.indexPath),
            data: try WebLibrary.jsonEncoderPretty.encode(index))

        let documentDir = source.documentsDir.appendingPathComponent(currentKey, isDirectory: true)
        let scratchpad = documentDir.appendingPathComponent("scratchpad.md")
        container.seed(documentDir, data: Data())
        container.seed(scratchpad, data: Data("note".utf8))

        let positionName = "phone.v1.json"
        let positionURL = source.positionsDir.appendingPathComponent(positionName)
        container.seed(positionURL, data: Data("position".utf8))

        WebStorageMigrator.recordPendingRelocation(mode: .icloud, customPath: nil)
        defer { WebStorageMigrator.clearPendingRelocation() }

        let first = await WebStorageMigrator.relocate(
            from: source,
            to: destination,
            sourceStore: sourceStore,
            destinationStore: destinationStore)

        #expect(!first)
        #expect(container.peek(staleRecordURL) != nil)
        #expect(UserDefaults.standard.string(
            forKey: WebStorageSettings.pendingRelocationKey) != nil)
        #expect(try await destinationStore.read(
            destination.recordsDir.appendingPathComponent("\(currentKey).json")) != nil)
        #expect(try await destinationStore.read(
            destination.archivesDir.appendingPathComponent("\(currentKey).vellumweb"))
            == Data("archive".utf8))
        #expect(try await destinationStore.read(
            destination.documentsDir
                .appendingPathComponent(currentKey, isDirectory: true)
                .appendingPathComponent("scratchpad.md")) == Data("note".utf8))
        #expect(try await destinationStore.read(
            destination.positionsDir.appendingPathComponent(positionName))
            == Data("position".utf8))

        container.setReadiness(.current, at: staleRecordURL)
        let second = await WebStorageMigrator.relocate(
            from: source,
            to: destination,
            sourceStore: sourceStore,
            destinationStore: destinationStore)

        #expect(second)
        #expect(container.peek(staleRecordURL) == nil)
        #expect(try await destinationStore.read(
            destination.recordsDir.appendingPathComponent("\(staleKey).json")) != nil)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
        #expect(container.coordinatedReadCount > 0)
        #expect(container.coordinatedRemoveCount > 0)
    }
}
