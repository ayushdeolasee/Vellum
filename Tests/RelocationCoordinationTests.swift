import Foundation
import Testing

@testable import Vellum

@Suite("Storage relocation — coordinated side")
struct RelocationCoordinationTests {
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
