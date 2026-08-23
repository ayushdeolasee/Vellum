import Foundation
import Testing

@testable import Vellum

@MainActor
@Suite("Document data — coordinated storage", .serialized)
struct DocumentDataCoordinationTests {
    private let cloudRoot = URL(fileURLWithPath: "/test-cloud/Vellum", isDirectory: true)
    private let key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    @Test("Bundle scratchpad bytes round-trip only through coordinated primitives")
    func scratchpadRoundTrip() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let target = cloudRoot.appendingPathComponent(
            ".vellum/documents/\(key)/scratchpad.md")

        try await DocumentDataStore.saveScratchpad(
            forKey: key, text: "imported note", coordinator: coordinator)
        let loaded = try await DocumentDataStore.loadScratchpad(
            forKey: key, coordinator: coordinator)

        #expect(loaded == "imported note")
        #expect(container.peek(target) == Data("imported note".utf8))
        #expect(container.coordinatedWriteCount == 1)
        #expect(container.forReplacingWriteCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    @Test("Home library search inventories iCloud through the workspace coordinator")
    func homeSearchInventoryUsesCoordinator() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let directory = cloudRoot.appendingPathComponent(
            ".vellum/documents/\(key)", isDirectory: true)
        let meta = DocumentDataStore.Meta(
            version: 1,
            kind: DocumentKind.pdf.rawValue,
            title: "Coordinated Search",
            lastKnownPath: "/missing/coordinated.pdf",
            lastOpened: "2026-08-05T00:00:00Z")
        container.seed(directory, data: Data())
        container.seed(
            directory.appendingPathComponent("meta.json"),
            data: try WebLibrary.jsonEncoderPretty.encode(meta))
        container.seed(directory.appendingPathComponent("scratchpad.md"), data: Data("note".utf8))

        let storage = WebLibraryStorage(coordinator: coordinator)
        let provider = try #require(
            HomeSearchEngine.defaultProviders(storage: storage).first { $0.id == "library" })
        let item = try #require(try await provider.items(matching: "").first)

        #expect(item.title == "Coordinated Search")
        #expect(item.badges.contains(.notes))
        #expect(container.coordinatedReadCount == 1)
        #expect(container.metadataQueryCount >= 3)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    @Test("A not-downloaded conversation is never replaced")
    func notDownloadedConversationIsPreserved() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let target = cloudRoot.appendingPathComponent(
            ".vellum/documents/\(key)/conversations.json")
        let remote = Data("remote conversation".utf8)
        container.seed(target, data: remote, readiness: .notDownloaded)

        await #expect(throws: LibraryFileError.notDownloaded(target, .notDownloaded)) {
            try await DocumentDataStore.saveConversationsData(
                forKey: key, data: Data("[]".utf8), coordinator: coordinator)
        }

        #expect(container.peek(target) == remote)
        #expect(container.coordinatedWriteCount == 0)
    }

    @Test("AI edits wait for an authoritative reload, then merge remote bytes")
    func aiEditsDoNotBlindlyReplaceUnavailableConversation() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let documentKey = UUID().uuidString.lowercased()
        let target = cloudRoot.appendingPathComponent(
            ".vellum/documents/\(documentKey)/conversations.json")
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/coordinated.pdf", title: "Coordinated",
            pageCount: 1, lastPage: 1, docId: documentKey)
        let remote = AiPersistence.makeMessage(
            role: .assistant, content: "remote", id: "remote")
        let local = AiPersistence.makeMessage(
            role: .user, content: "local", id: "local")
        let remoteBytes = try JSONEncoder().encode([remote])
        container.seed(
            target, data: remoteBytes,
            readiness: .notDownloaded)
        defer { AiPersistence.invalidateCachedConversation(forKey: documentKey) }

        #expect(await AiPersistence.loadConversation(
            for: document, coordinator: coordinator).isEmpty)
        AiPersistence.saveConversation(
            for: document, messages: [local], coordinator: coordinator)
        await AiPersistence.awaitPendingFlush()

        #expect(container.peek(target) == remoteBytes)
        #expect(container.coordinatedWriteCount == 0)

        container.setReadiness(.current, at: target)
        let merged = await AiPersistence.loadConversation(
            for: document, coordinator: coordinator)
        await AiPersistence.awaitPendingFlush()

        #expect(Set(merged.map(\.id)) == ["remote", "local"])
        let persisted = try #require(container.peek(target))
        #expect(Set(try JSONDecoder().decode([AiMessage].self, from: persisted).map(\.id))
            == ["remote", "local"])
    }

    @Test("Pending relocation still reads the local source copy")
    func localFallbackSurvivesPendingRelocation() async throws {
        let root = PositionFixtures.scratchDirectory("document-data-fallback")
        defer {
            WebLibrary.storeDirOverride = nil
            PositionFixtures.remove(root)
        }
        let localWeb = root.appendingPathComponent("web", isDirectory: true)
        WebLibrary.storeDirOverride = localWeb
        let localConversation = WebStorageLayout.local(storeDir: localWeb).documentsDir
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("conversations.json")
        try FileManager.default.createDirectory(
            at: localConversation.deletingLastPathComponent(), withIntermediateDirectories: true)
        let local = Data("local pending bytes".utf8)
        try local.write(to: localConversation)

        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, storeDir: localWeb)
        await coordinator.start()

        let loaded = try await DocumentDataStore.loadConversationsData(
            forKey: key, coordinator: coordinator)

        #expect(loaded == local)
        #expect(container.coordinatedReadCount == 0)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    @Test("Relink updates synced metadata through the coordinator")
    func relinkUsesCoordinatedMetadata() async throws {
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container)
        await coordinator.start()
        let documentKey = UUID().uuidString.lowercased()
        let target = cloudRoot.appendingPathComponent(
            ".vellum/documents/\(documentKey)/meta.json")
        let original = DocumentDataStore.Meta(
            version: 1, kind: "pdf", title: "Relinked",
            lastKnownPath: "/missing/original.pdf",
            lastOpened: "2026-08-05T00:00:00Z")
        container.seed(target, data: try WebLibrary.jsonEncoderPretty.encode(original))

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "vellum-coordinated-relink-\(UUID().uuidString.lowercased())",
            isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let picked = scratch.appendingPathComponent("picked.pdf")
        let resolver = DocumentAccessResolver(
            store: DocumentAccessBookmarkStore(
                directory: scratch.appendingPathComponent("access", isDirectory: true)),
            adapter: CoordinatedRelinkAdapter(),
            libraryDirectory: { scratch },
            appOwnedRoots: { [scratch] })

        let result = await resolver.relink(
            key: documentKey, isDocIdKeyed: false, to: picked,
            coordinator: coordinator)

        guard case .success = result else {
            Issue.record("Expected coordinated relink to succeed")
            return
        }
        let data = try #require(container.peek(target))
        #expect(try JSONDecoder().decode(DocumentDataStore.Meta.self, from: data).lastKnownPath
            == picked.path)
        #expect(container.coordinatedWriteCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    private func makeCoordinator(
        container: FakeSyncedContainer,
        storeDir: URL = URL(fileURLWithPath: "/test-local/web", isDirectory: true)
    ) -> StorageCoordinator {
        StorageCoordinator(
            storeDir: storeDir,
            modeProvider: { .icloud },
            effectiveModeProvider: { .icloud },
            rootResolver: { cloudRoot },
            containerFactory: { container })
    }
}

private struct CoordinatedRelinkAdapter: DocumentAccessAdapter {
    func makeBookmark(for url: URL, access: DocumentBookmarkAccess) throws -> Data {
        Data(url.path.utf8)
    }

    func resolveBookmark(
        _ data: Data, access: DocumentBookmarkAccess
    ) throws -> (url: URL, isStale: Bool) {
        throw DocumentAccessError.unavailable("unused")
    }

    func startAccessing(_ url: URL) -> Bool { true }
    func stopAccessing(_ url: URL) {}
    func fileExists(_ url: URL) -> Bool { true }
    func documentId(atPath path: String) -> String? { nil }
}
