import Foundation
import Testing
@testable import Vellum

@MainActor
struct IntegrationsStoreTests {
    @Test func exposesExactlyTwoProvidersAndStartsOnce() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw IntegrationTestFixtureError.couldNotCreateUserDefaults
        }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let setupPreferences = IntegrationPreferences(defaults: defaults)
        setupPreferences.autoRefreshEnabled = false
        let engine = IntegrationsSyncEngine(
            credentials: InMemoryIntegrationCredentials(),
            cache: IntegrationsCache(root: root),
            preferences: try makeIntegrationPreferences(suiteName: suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: ScriptedRaindropService()
        )
        let store = IntegrationsStore(engine: engine)

        #expect(store.providers.count == 2)
        await store.start()
        await store.start()
        #expect(store.didStart)
        #expect(store.hasConnectedProvider == false)
    }

    @Test func connectReturnsAfterCredentialPersistenceAndSurfacesInitialSyncFailure() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let pageStarted = IntegrationTestGate()
        let pageRelease = IntegrationTestGate()
        let readwise = ScriptedReadwiseService(terminalError: .server(status: 500), pageStarted: pageStarted, pageRelease: pageRelease)
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials(), cache: IntegrationsCache(root: root), preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: readwise, raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)

        try await store.connect(provider: .readwise, token: "valid-token")
        await pageStarted.wait()

        #expect(store.providers[.readwise]?.connection == .syncing)
        #expect(store.providers[.readwise]?.isConnected == true)
        await pageRelease.open()
        await store.sync(.readwise)
        guard case .failed(let message)? = store.providers[.readwise]?.connection else {
            Issue.record("Expected the failed first traversal to remain visible")
            return
        }
        #expect(message.contains("HTTP 500"))
        #expect(store.providers[.readwise]?.isConnected == true)
        #expect(store.providers[.readwise]?.items.isEmpty == true)
    }

    @Test func rejectedTokenKeepsCachedItemsAndProviderAvailable() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: item.updatedAt, tentativePagination: nil, lastSuccessfulSync: item.updatedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.readwise: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(terminalError: .tokenRejected), raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)
        await store.start()

        await store.sync(.readwise)

        #expect(store.providers[.readwise]?.connection == .tokenRejected)
        #expect(store.providers[.readwise]?.items.map(\.id) == [item.id])
        #expect(store.providers[.readwise]?.isConnected == true)
        #expect(store.connectedProviders.contains(.readwise))
    }

    @Test func missingCredentialAtLaunchKeepsCachedProviderAvailableForReconnect() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "missing-token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: item.updatedAt, tentativePagination: nil, lastSuccessfulSync: item.updatedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials(), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)

        await store.start()

        #expect(store.providers[.readwise]?.connection == .tokenRejected)
        #expect(store.providers[.readwise]?.items.map(\.id) == [item.id])
        #expect(store.providers[.readwise]?.isConnected == true)
        #expect(store.connectedProviders.contains(.readwise))
    }

    @Test func failedDisconnectKeepsTheActiveSyncTrackedAndUsable() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: item.updatedAt, tentativePagination: nil, lastSuccessfulSync: item.updatedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let managed = try await cache.downloadURL(provider: .readwise, itemID: "download")
        try Data("pdf".utf8).write(to: managed)
        let pageStarted = IntegrationTestGate()
        let pageRelease = IntegrationTestGate()
        let readwise = ScriptedReadwiseService(pages: [integrationPage(items: [item])], pageStarted: pageStarted, pageRelease: pageRelease)
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.readwise: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: readwise, raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)
        await store.start()
        let syncTask = Task { await store.sync(.readwise) }
        await pageStarted.wait()

        await #expect(throws: IntegrationError.downloadsAreOpen) {
            try await store.disconnect(provider: .readwise, deleteDownloads: true, openDocumentPaths: [managed.path])
        }
        #expect(store.providers[.readwise]?.connection == .syncing)
        await pageRelease.open()
        await syncTask.value

        #expect(store.providers[.readwise]?.connection == .connected)
        #expect(store.providers[.readwise]?.items.map(\.id) == [item.id])
        #expect(store.providers[.readwise]?.isConnected == true)
    }

    @Test func cancellingReconnectValidationLeavesTheActiveSyncTracked() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: item.updatedAt, tentativePagination: nil, lastSuccessfulSync: item.updatedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let pageStarted = IntegrationTestGate()
        let pageRelease = IntegrationTestGate()
        let validationStarted = IntegrationTestGate()
        let validationRelease = IntegrationTestGate()
        let readwise = ScriptedReadwiseService(pages: [integrationPage(items: [item])], validationStarted: validationStarted, validationRelease: validationRelease, pageStarted: pageStarted, pageRelease: pageRelease)
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.readwise: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: readwise, raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)
        await store.start()
        let syncTask = Task { await store.sync(.readwise) }
        await pageStarted.wait()
        let reconnectTask = Task { try await store.connect(provider: .readwise, token: "replacement") }
        await validationStarted.wait()

        reconnectTask.cancel()
        await validationRelease.open()
        await #expect(throws: CancellationError.self) { try await reconnectTask.value }
        #expect(store.providers[.readwise]?.connection == .syncing)
        await pageRelease.open()
        await syncTask.value

        #expect(store.providers[.readwise]?.connection == .connected)
        #expect(store.providers[.readwise]?.items.map(\.id) == [item.id])
    }

    @Test func corruptConfiguredCacheRemainsRetryableWithoutTokenReentry() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let providerDirectory = root.appendingPathComponent("readwise", isDirectory: true)
        try FileManager.default.createDirectory(at: providerDirectory, withIntermediateDirectories: true)
        try Data("corrupt".utf8).write(to: providerDirectory.appendingPathComponent("snapshot.json"))
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.readwise: token]), cache: IntegrationsCache(root: root), preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)

        await store.start()

        guard case .failed? = store.providers[.readwise]?.connection else { Issue.record("Expected corrupt-cache recovery state"); return }
        #expect(store.providers[.readwise]?.isConnected == true)
        #expect(store.connectedProviders.contains(.readwise))
    }

    @Test func terminalDownloadFailureIsNotMarkedAsActiveProgress() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let item = try makeIntegrationItem(provider: .readwise, id: "pdf", updatedAt: Date(timeIntervalSince1970: 1_700_000_000), kind: .pdf, pdfRetrieval: .readwiseItem(id: "pdf"))
        let cache = IntegrationsCache(root: root)
        try await cache.save(.empty(provider: .readwise, fingerprint: fingerprint, generation: 1))
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.readwise: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(rawSource: nil), raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)

        await #expect(throws: IntegrationError.notPDF) { try await store.route(for: item) }

        #expect(store.downloads[item.id]?.isActive == false)
        #expect(store.downloads[item.id]?.progress == nil)
    }

    @Test func moveRefilesOptimisticallyOffersTargetsAndMapsOpenDocumentsBack() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .raindrop)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try #require(ReadLaterItem(provider: .raindrop, vendorID: "42", sourceURL: URL(string: "https://www.example.com/article/"), title: "Article", collectionIDs: ["raindrop:collection:10"], savedAt: savedAt, updatedAt: savedAt))
        let collections = [
            ReadLaterCollection(provider: .raindrop, vendorID: "10", title: "Research", sortIndex: 0),
            ReadLaterCollection(provider: .raindrop, vendorID: "11", title: "Swift", sortIndex: 1),
        ]
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .raindrop, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: collections, committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: savedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let raindrop = ScriptedRaindropService()
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.raindrop: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: raindrop)
        let store = IntegrationsStore(engine: engine)
        await store.start()

        #expect(store.moveTargets(for: .raindrop).map(\.vendorID) == ["-1", "10", "11"])

        #expect(store.readLaterItem(forOpenDocumentPath: "http://example.com/article")?.id == item.id)
        #expect(store.readLaterItem(forOpenDocumentPath: "https://EXAMPLE.com/article#section-2")?.id == item.id)
        #expect(store.readLaterItem(forOpenDocumentPath: "https://example.com/article?utm_source=reader")?.id == item.id)
        let downloadName = IntegrationsCache.downloadKey(provider: .raindrop, itemID: "42") + ".pdf"
        #expect(store.readLaterItem(forOpenDocumentPath: "/downloads/\(downloadName)")?.id == item.id)
        #expect(store.readLaterItem(forOpenDocumentPath: "https://example.com/elsewhere") == nil)
        #expect(store.readLaterItem(forOpenDocumentPath: "/tmp/aaaa0000bbbb.pdf") == nil)
        #expect(store.readLaterItem(forOpenDocumentPath: "/downloads/notes.txt") == nil)

        await store.move(item, to: collections[1])

        #expect(await raindrop.moveCalls() == [.init(itemID: "42", collectionVendorID: "11")])
        #expect(store.providers[.raindrop]?.items.first?.collectionIDs == ["raindrop:collection:11"])
        #expect(store.moveNotices[item.id]?.isSuccess == true)
        #expect(store.moveNotices[item.id]?.message == "Moved to Swift")

        await store.move(item, to: collections[1])
        #expect(await raindrop.moveCalls().count == 1)
    }

    @Test func failedMoveRevertsTheOptimisticRefileAndSurfacesTheError() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .raindrop)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try #require(ReadLaterItem(provider: .raindrop, vendorID: "42", sourceURL: URL(string: "https://example.com/article"), title: "Article", collectionIDs: ["raindrop:collection:10"], savedAt: savedAt, updatedAt: savedAt))
        let target = ReadLaterCollection(provider: .raindrop, vendorID: "11", title: "Swift", sortIndex: 1)
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .raindrop, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: [target], committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: savedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.raindrop: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService(moveError: .server(status: 500)))
        let store = IntegrationsStore(engine: engine)
        await store.start()

        await store.move(item, to: target)

        #expect(store.providers[.raindrop]?.items.first?.collectionIDs == ["raindrop:collection:10"])
        #expect(store.providers[.raindrop]?.items.first?.updatedAt == savedAt)
        #expect(store.moveNotices[item.id]?.isSuccess == false)
        #expect(store.moveNotices[item.id]?.message.contains("HTTP 500") == true)
        guard case .snapshot(let snapshot) = await cache.load(provider: .raindrop) else {
            Issue.record("Expected the cached snapshot to survive the failed move")
            return
        }
        #expect(snapshot.items.first?.collectionIDs == ["raindrop:collection:10"])
    }

    @Test func readwiseMoveTargetsMatchTheUpdateContractAndMovesRefile() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .readwise)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try #require(ReadLaterItem(provider: .readwise, vendorID: "doc-1", sourceURL: URL(string: "https://example.com/doc"), title: "Doc", collectionIDs: ["readwise:collection:new"], savedAt: savedAt, updatedAt: savedAt))
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: savedAt, tentativePagination: nil, lastSuccessfulSync: savedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let readwise = ScriptedReadwiseService()
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.readwise: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: readwise, raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)
        await store.start()

        // The Reader v3 update contract: shortlist is list-filter-only, feed is
        // deliberately not offered as a destination.
        #expect(store.moveTargets(for: .readwise).map(\.vendorID) == ["new", "later", "archive"])

        let later = try #require(store.moveTargets(for: .readwise).first { $0.vendorID == "later" })
        await store.move(item, to: later)

        #expect(await readwise.moveCalls() == [.init(itemID: "doc-1", collectionVendorID: "later")])
        #expect(store.providers[.readwise]?.items.first?.collectionIDs == ["readwise:collection:later"])
        #expect(store.moveNotices[item.id]?.isSuccess == true)
    }

    @Test func moveDuringActiveSyncTriggersFollowUpSyncAndKeepsTheNewCollection() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .raindrop)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let preMove = try #require(ReadLaterItem(provider: .raindrop, vendorID: "42", sourceURL: URL(string: "https://example.com/a"), title: "A", collectionIDs: ["raindrop:collection:10"], savedAt: savedAt, updatedAt: savedAt))
        let postMove = try #require(ReadLaterItem(provider: .raindrop, vendorID: "42", sourceURL: URL(string: "https://example.com/a"), title: "A", collectionIDs: ["raindrop:collection:11"], savedAt: savedAt, updatedAt: savedAt.addingTimeInterval(60)))
        let target = ReadLaterCollection(provider: .raindrop, vendorID: "11", title: "Swift", sortIndex: 1)
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .raindrop, accountFingerprint: fingerprint, connectionGeneration: 1, items: [preMove], collections: [target], committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: savedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let pageStarted = IntegrationTestGate()
        let pageRelease = IntegrationTestGate()
        // First walk (already in flight when the move lands) returns the
        // pre-move item; the follow-up walk returns the server's post-move state.
        let raindrop = ScriptedRaindropService(
            collections: [target],
            pages: [integrationPage(items: [preMove]), integrationPage(items: [postMove])],
            pageStarted: pageStarted, pageRelease: pageRelease)
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.raindrop: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: raindrop)
        let store = IntegrationsStore(engine: engine)
        await store.start()

        let syncTask = Task { await store.sync(.raindrop) }
        await pageStarted.wait()
        let moveTask = Task { await store.move(preMove, to: target) }
        // The success notice is set in the same MainActor slice that decides on
        // the follow-up sync, so once it appears the decision has been made.
        // This is the one wait that cannot be a handle await: `move` ends by
        // awaiting the sync this test is deliberately holding open at its first
        // page, so awaiting `moveTask` here would deadlock.
        #expect(await waitForIntegrationCondition { store.moveNotices[preMove.id] != nil })

        await pageRelease.open()
        await syncTask.value
        await moveTask.value

        // The first sync's pre-move snapshot must not have bounced the item
        // back, and the follow-up sync must have fetched the server's state.
        #expect(store.providers[.raindrop]?.items.first?.collectionIDs == ["raindrop:collection:11"])
        #expect(await raindrop.pageCalls().count == 2)
        #expect(await raindrop.moveCalls() == [.init(itemID: "42", collectionVendorID: "11")])
    }

    @Test func overlappingMovesOfTheSameItemAreRejectedWhileOneIsInFlight() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .raindrop)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try #require(ReadLaterItem(provider: .raindrop, vendorID: "42", sourceURL: URL(string: "https://example.com/a"), title: "A", collectionIDs: ["raindrop:collection:10"], savedAt: savedAt, updatedAt: savedAt))
        let collections = [
            ReadLaterCollection(provider: .raindrop, vendorID: "11", title: "Swift", sortIndex: 0),
            ReadLaterCollection(provider: .raindrop, vendorID: "12", title: "Research", sortIndex: 1),
        ]
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .raindrop, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: collections, committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: savedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let moveStarted = IntegrationTestGate()
        let moveRelease = IntegrationTestGate()
        let raindrop = ScriptedRaindropService(moveStarted: moveStarted, moveRelease: moveRelease)
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.raindrop: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: raindrop)
        let store = IntegrationsStore(engine: engine)
        await store.start()

        let firstMove = Task { await store.move(item, to: collections[0]) }
        await moveStarted.wait()
        #expect(store.inFlightMoves.contains(item.id))

        // A second move of the same item while the first is on the wire is
        // rejected at entry — no second network call, no state change.
        await store.move(item, to: collections[1])

        await moveRelease.open()
        await firstMove.value

        #expect(await raindrop.moveCalls() == [.init(itemID: "42", collectionVendorID: "11")])
        #expect(store.providers[.raindrop]?.items.first?.collectionIDs == ["raindrop:collection:11"])
        #expect(store.inFlightMoves.isEmpty)
    }

    @Test func moveSuccessNoticeExpiresOnItsOwn() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let token = "token"
        let fingerprint = integrationFingerprint(token)
        preferences.persist(.init(enabled: true, generation: 1, accountFingerprint: fingerprint), for: .raindrop)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try #require(ReadLaterItem(provider: .raindrop, vendorID: "42", sourceURL: URL(string: "https://example.com/a"), title: "A", collectionIDs: ["raindrop:collection:10"], savedAt: savedAt, updatedAt: savedAt))
        let target = ReadLaterCollection(provider: .raindrop, vendorID: "11", title: "Swift", sortIndex: 0)
        let cache = IntegrationsCache(root: root)
        try await cache.save(.init(provider: .raindrop, accountFingerprint: fingerprint, connectionGeneration: 1, items: [item], collections: [target], committedBoundary: nil, tentativePagination: nil, lastSuccessfulSync: savedAt, lastFullSweep: nil, skippedRecordCount: 0))
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials([.raindrop: token]), cache: cache, preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine, scheduler: NoWaitIntegrationSleeper())
        await store.start()

        await store.move(item, to: target)
        #expect(store.moveNotices[item.id] != nil)

        // The fade-out timer is a retained, joinable handle — await it instead
        // of polling for the notice to disappear.
        await store.awaitNoticeExpiry(for: item.id)

        #expect(store.moveNotices[item.id] == nil)
    }

    /// The quit path (`applicationShouldTerminate`) drains the store, so a
    /// preference the user toggled a moment before ⌘Q must be on disk when the
    /// drain returns — it used to ride on a dropped `Task` handle and revert.
    @Test func quitDrainLandsAPreferenceToggledMomentsEarlier() async throws {
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsStoreTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = IntegrationPreferences(defaults: defaults)
        preferences.autoRefreshEnabled = false
        let engine = IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials(), cache: IntegrationsCache(root: root), preferences: try makeIntegrationPreferences(suiteName: suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService())
        let store = IntegrationsStore(engine: engine)
        await store.start()
        #expect(store.autoRefreshEnabled == false)

        store.setAutoRefresh(true)
        #expect(store.autoRefreshEnabled == true)
        await store.awaitQuiescence()

        #expect(preferences.autoRefreshEnabled == true)
    }
}
