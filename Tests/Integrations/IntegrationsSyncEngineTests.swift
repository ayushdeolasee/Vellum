import Foundation
import Testing
@testable import Vellum

@Suite(.serialized)
struct IntegrationsSyncEngineTests {
    @Test func readwisePersistsTentativePagesAndResumesWithoutAdvancingWatermark() async throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let oldItem = try makeIntegrationItem(provider: .readwise, id: "old", updatedAt: boundary)
        let firstNewItem = try makeIntegrationItem(provider: .readwise, id: "new-1", updatedAt: boundary.addingTimeInterval(60))
        let finalNewItem = try makeIntegrationItem(provider: .readwise, id: "new-2", updatedAt: boundary.addingTimeInterval(120))
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(
                provider: .readwise,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [oldItem],
                collections: ReadwiseClient.locationCollections,
                committedBoundary: boundary,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let interruptedReadwise = ScriptedReadwiseService(
            pages: [integrationPage(items: [firstNewItem], nextCursor: "cursor-2")],
            terminalError: .server(status: 500)
        )
        let interruptedEngine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: interruptedReadwise,
            raindrop: ScriptedRaindropService()
        )

        await #expect(throws: IntegrationError.server(status: 500)) {
            try await interruptedEngine.sync(provider: .readwise)
        }

        let interruptedCalls = await interruptedReadwise.pageCalls()
        #expect(interruptedCalls.map(\.cursor) == [nil, "cursor-2"])
        #expect(interruptedCalls.map(\.updatedAfter) == [boundary.addingTimeInterval(-300), boundary.addingTimeInterval(-300)])
        guard case .snapshot(let interruptedSnapshot) = await harness.cache.load(provider: .readwise) else {
            Issue.record("Expected the committed snapshot plus tentative pagination")
            return
        }
        #expect(interruptedSnapshot.items.map(\.id) == [oldItem.id])
        #expect(interruptedSnapshot.committedBoundary == boundary)
        let tentative = try #require(interruptedSnapshot.tentativePagination)
        #expect(tentative.cursor == "cursor-2")
        #expect(tentative.fetchedItems.map(\.id) == [firstNewItem.id])

        let resumedReadwise = ScriptedReadwiseService(pages: [integrationPage(items: [finalNewItem])])
        let resumedEngine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: resumedReadwise,
            raindrop: ScriptedRaindropService()
        )
        let committed = try await resumedEngine.sync(provider: .readwise)

        let resumedCalls = await resumedReadwise.pageCalls()
        #expect(resumedCalls.map(\.cursor) == ["cursor-2"])
        #expect(resumedCalls.map(\.updatedAfter) == [boundary.addingTimeInterval(-300)])
        #expect(Set(committed.items.map(\.id)) == Set([oldItem.id, firstNewItem.id, finalNewItem.id]))
        #expect(committed.committedBoundary == finalNewItem.updatedAt)
        #expect(committed.tentativePagination == nil)
    }

    @Test func cleanFullReadwiseSweepDeletesItemsMissingFromTheService() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let retained = try makeIntegrationItem(provider: .readwise, id: "retained", updatedAt: oldDate.addingTimeInterval(10))
        let deleted = try makeIntegrationItem(provider: .readwise, id: "deleted", updatedAt: oldDate)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(
                provider: .readwise,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [retained, deleted],
                collections: ReadwiseClient.locationCollections,
                committedBoundary: retained.updatedAt,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let syncTime = Date(timeIntervalSince1970: 1_800_000_000)
        let readwise = ScriptedReadwiseService(pages: [integrationPage(items: [retained])])
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService(),
            now: { syncTime }
        )

        let snapshot = try await engine.sync(provider: .readwise, forceFull: true)

        let pageCalls = await readwise.pageCalls()
        #expect(snapshot.items.map(\.id) == [retained.id])
        #expect(snapshot.lastFullSweep == syncTime)
        #expect(snapshot.skippedRecordCount == 0)
        #expect(pageCalls.first?.updatedAfter == nil)
    }

    @Test func skippedRecordMakesFullSweepConservativeAndPreventsDeletion() async throws {
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let retained = try makeIntegrationItem(provider: .readwise, id: "retained", updatedAt: oldDate.addingTimeInterval(10))
        let potentiallyDeleted = try makeIntegrationItem(provider: .readwise, id: "potentially-deleted", updatedAt: oldDate)
        let previousSweep = Date(timeIntervalSince1970: 1_600_000_000)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(
                provider: .readwise,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [retained, potentiallyDeleted],
                collections: ReadwiseClient.locationCollections,
                committedBoundary: retained.updatedAt,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: previousSweep,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let readwise = ScriptedReadwiseService(pages: [integrationPage(items: [retained], skipped: 1)])
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )

        let snapshot = try await engine.sync(provider: .readwise, forceFull: true)

        #expect(Set(snapshot.items.map(\.id)) == Set([retained.id, potentiallyDeleted.id]))
        #expect(snapshot.lastFullSweep == previousSweep)
        #expect(snapshot.skippedRecordCount == 1)
    }

    @Test func multipageSyncPublishesTentativeItemsBeforeTraversalCompletes() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let first = try makeIntegrationItem(provider: .readwise, id: "first", updatedAt: date)
        let second = try makeIntegrationItem(provider: .readwise, id: "second", updatedAt: date.addingTimeInterval(60))
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            .empty(provider: .readwise, fingerprint: fingerprint, generation: generation)
        }
        defer { harness.cleanup() }
        let recorder = IntegrationSnapshotRecorder()
        let engine = IntegrationsSyncEngine(credentials: harness.credentials, cache: harness.cache, preferences: try makeIntegrationPreferences(suiteName: harness.suiteName), readwise: ScriptedReadwiseService(pages: [integrationPage(items: [first], nextCursor: "next"), integrationPage(items: [second])]), raindrop: ScriptedRaindropService())

        let final = try await engine.sync(provider: .readwise, forceFull: true) { await recorder.record($0) }

        let previews = await recorder.snapshots()
        #expect(previews.count == 1)
        #expect(previews.first?.items.map(\.id) == [first.id])
        #expect(Set(final.items.map(\.id)) == Set([first.id, second.id]))
    }

    @Test func raindropAlwaysWalksEveryPageBeforeAuthoritativeSweep() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stale = try makeIntegrationItem(provider: .raindrop, id: "stale", updatedAt: date)
        let first = try makeIntegrationItem(provider: .raindrop, id: "first", updatedAt: date.addingTimeInterval(10))
        let second = try makeIntegrationItem(provider: .raindrop, id: "second", updatedAt: date.addingTimeInterval(20))
        let collections = [
            ReadLaterCollection(provider: .raindrop, vendorID: "10", title: "Research", depth: 0, sortIndex: 0),
            ReadLaterCollection(provider: .raindrop, vendorID: "11", title: "Swift", parentID: "raindrop:collection:10", depth: 1, sortIndex: 1),
            ReadLaterCollection(provider: .raindrop, vendorID: "12", title: "Concurrency", parentID: "raindrop:collection:11", depth: 2, sortIndex: 2)
        ]
        let harness = try await IntegrationEngineHarness.make(provider: .raindrop) { fingerprint, generation in
            ProviderSnapshot(
                provider: .raindrop,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [stale],
                collections: [],
                committedBoundary: stale.updatedAt,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let raindrop = ScriptedRaindropService(
            collections: collections,
            pages: [
                integrationPage(items: [first], nextCursor: "1"),
                integrationPage(items: [second])
            ]
        )
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: raindrop
        )

        let snapshot = try await engine.sync(provider: .raindrop)

        let pageCalls = await raindrop.pageCalls()
        let collectionsCalls = await raindrop.collectionsCalls()
        #expect(pageCalls == [.init(page: 0, perPage: 50), .init(page: 1, perPage: 50)])
        #expect(collectionsCalls == 1)
        #expect(Set(snapshot.items.map(\.id)) == Set([first.id, second.id]))
        #expect(snapshot.items.contains(where: { $0.id == stale.id }) == false)
        #expect(snapshot.collections == collections)
        #expect(snapshot.lastFullSweep != nil)
    }

    @Test func interruptedRaindropFullWalkPreservesCommittedItemsWatermarkAndSweepDate() async throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let previousSweep = Date(timeIntervalSince1970: 1_600_000_000)
        let committedItem = try makeIntegrationItem(provider: .raindrop, id: "committed", updatedAt: boundary)
        let partialItem = try makeIntegrationItem(provider: .raindrop, id: "partial", updatedAt: boundary.addingTimeInterval(60))
        let harness = try await IntegrationEngineHarness.make(provider: .raindrop) { fingerprint, generation in
            ProviderSnapshot(
                provider: .raindrop,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [committedItem],
                collections: [],
                committedBoundary: boundary,
                tentativePagination: nil,
                lastSuccessfulSync: boundary,
                lastFullSweep: previousSweep,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let raindrop = ScriptedRaindropService(
            pages: [integrationPage(items: [partialItem], nextCursor: "1")],
            terminalError: .server(status: 500)
        )
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: raindrop
        )

        await #expect(throws: IntegrationError.server(status: 500)) {
            try await engine.sync(provider: .raindrop)
        }

        guard case .snapshot(let cached) = await harness.cache.load(provider: .raindrop) else {
            Issue.record("Expected the committed snapshot to survive the interrupted full walk")
            return
        }
        #expect(cached.items.map(\.id) == [committedItem.id])
        #expect(cached.committedBoundary == boundary)
        #expect(cached.lastFullSweep == previousSweep)
        let tentative = try #require(cached.tentativePagination)
        #expect(tentative.mode == .full)
        #expect(tentative.cursor == "1")
        #expect(tentative.fetchedItems.map(\.id) == [partialItem.id])
    }

    @Test func generationChangeWhilePageIsSuspendedRejectsStaleResults() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let oldItem = try makeIntegrationItem(provider: .readwise, id: "old", updatedAt: date)
        let staleResult = try makeIntegrationItem(provider: .readwise, id: "stale-result", updatedAt: date.addingTimeInterval(30))
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(
                provider: .readwise,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [oldItem],
                collections: ReadwiseClient.locationCollections,
                committedBoundary: date,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let started = IntegrationTestGate()
        let release = IntegrationTestGate()
        let readwise = ScriptedReadwiseService(
            pages: [integrationPage(items: [staleResult])],
            pageStarted: started,
            pageRelease: release
        )
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )
        let syncTask = Task { try await engine.sync(provider: .readwise) }
        await started.wait()
        IntegrationPreferences(defaults: harness.defaults).persist(
            .init(enabled: true, generation: harness.generation + 1, accountFingerprint: harness.fingerprint),
            for: .readwise
        )
        await release.open()

        await #expect(throws: IntegrationError.staleGeneration) {
            try await syncTask.value
        }

        guard case .snapshot(let cached) = await harness.cache.load(provider: .readwise) else {
            Issue.record("Expected the prior committed snapshot")
            return
        }
        #expect(cached.items.map(\.id) == [oldItem.id])
        #expect(cached.committedBoundary == date)
        #expect(cached.tentativePagination == nil)
    }

    @Test func reconnectReplacesAnActiveSyncWithoutJoiningItsCancelledTask() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let oldItem = try makeIntegrationItem(provider: .readwise, id: "old", updatedAt: date)
        let replacementItem = try makeIntegrationItem(provider: .readwise, id: "replacement", updatedAt: date.addingTimeInterval(60))
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: generation, items: [oldItem], collections: ReadwiseClient.locationCollections, committedBoundary: date, tentativePagination: nil, lastSuccessfulSync: date, lastFullSweep: nil, skippedRecordCount: 0)
        }
        defer { harness.cleanup() }
        let firstPageStarted = IntegrationTestGate()
        let readwise = ReconnectReadwiseService(firstPageStarted: firstPageStarted, replacementPage: integrationPage(items: [replacementItem]))
        let engine = IntegrationsSyncEngine(credentials: harness.credentials, cache: harness.cache, preferences: try makeIntegrationPreferences(suiteName: harness.suiteName), readwise: readwise, raindrop: ScriptedRaindropService())
        let oldSync = Task { try await engine.sync(provider: .readwise) }
        await firstPageStarted.wait()

        let initial = try await engine.connect(provider: .readwise, candidate: "replacement-token")
        let replacement = try await engine.sync(provider: .readwise, forceFull: true)

        await #expect(throws: CancellationError.self) { try await oldSync.value }
        #expect(initial.items.isEmpty)
        #expect(replacement.items.map(\.id) == [replacementItem.id])
        #expect(await harness.credentials.credential(for: .readwise) == "replacement-token")
    }

    @Test func cancellingCredentialValidationLeavesTheExistingConnectionUntouched() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: date)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: generation, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: date, tentativePagination: nil, lastSuccessfulSync: date, lastFullSweep: nil, skippedRecordCount: 0)
        }
        defer { harness.cleanup() }
        let validationStarted = IntegrationTestGate()
        let validationRelease = IntegrationTestGate()
        let readwise = ScriptedReadwiseService(validationStarted: validationStarted, validationRelease: validationRelease)
        let engine = IntegrationsSyncEngine(credentials: harness.credentials, cache: harness.cache, preferences: try makeIntegrationPreferences(suiteName: harness.suiteName), readwise: readwise, raindrop: ScriptedRaindropService())
        let connectTask = Task { try await engine.connect(provider: .readwise, candidate: "replacement-token") }
        await validationStarted.wait()

        connectTask.cancel()
        await validationRelease.open()

        await #expect(throws: CancellationError.self) { try await connectTask.value }
        #expect(await harness.credentials.credential(for: .readwise) == harness.token)
        guard case .snapshot(let cached) = await harness.cache.load(provider: .readwise) else {
            Issue.record("Expected the original snapshot after cancellation")
            return
        }
        #expect(cached.items.map(\.id) == [item.id])
        #expect(cached.connectionGeneration == harness.generation)
    }

    @Test func openDownloadPreflightFailureDoesNotDisableTheProvider() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: date)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: generation, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: date, tentativePagination: nil, lastSuccessfulSync: date, lastFullSweep: nil, skippedRecordCount: 0)
        }
        defer { harness.cleanup() }
        let managed = try await harness.cache.downloadURL(provider: .readwise, itemID: "download")
        try Data("pdf".utf8).write(to: managed)
        let managedDownloads = await harness.cache.managedDownloadURLs(provider: .readwise)
        #expect(managedDownloads.count == 1)
        let engine = IntegrationsSyncEngine(credentials: harness.credentials, cache: harness.cache, preferences: try makeIntegrationPreferences(suiteName: harness.suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService())

        await #expect(throws: IntegrationError.downloadsAreOpen) {
            try await engine.disconnect(provider: .readwise, deleteDownloads: true, openDocumentPaths: [managed.path])
        }

        let metadata = IntegrationPreferences(defaults: harness.defaults).metadata(for: .readwise)
        #expect(metadata.enabled)
        #expect(metadata.accountFingerprint == harness.fingerprint)
        #expect(await harness.credentials.credential(for: .readwise) == harness.token)
        #expect(FileManager.default.fileExists(atPath: managed.path))
        guard case .snapshot = await harness.cache.load(provider: .readwise) else { Issue.record("Expected the snapshot to remain"); return }
    }

    @Test func credentialDeletionFailureDoesNotDisableOrDeleteTheProvider() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: date)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: generation, items: [item], collections: ReadwiseClient.locationCollections, committedBoundary: date, tentativePagination: nil, lastSuccessfulSync: date, lastFullSweep: nil, skippedRecordCount: 0)
        }
        defer { harness.cleanup() }
        let credentials = InMemoryIntegrationCredentials([.readwise: harness.token], deleteSucceeds: false)
        let engine = IntegrationsSyncEngine(credentials: credentials, cache: harness.cache, preferences: try makeIntegrationPreferences(suiteName: harness.suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService())

        await #expect(throws: IntegrationError.credentialPersistenceFailed) {
            try await engine.disconnect(provider: .readwise, deleteDownloads: false)
        }

        let metadata = IntegrationPreferences(defaults: harness.defaults).metadata(for: .readwise)
        #expect(metadata.enabled)
        #expect(await credentials.credential(for: .readwise) == harness.token)
        guard case .snapshot = await harness.cache.load(provider: .readwise) else { Issue.record("Expected the snapshot to remain"); return }
    }

    @Test func raindropCollectionFailurePreventsAFalseSuccessfulSync() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .raindrop, id: "cached", updatedAt: date)
        let harness = try await IntegrationEngineHarness.make(provider: .raindrop) { fingerprint, generation in
            ProviderSnapshot(provider: .raindrop, accountFingerprint: fingerprint, connectionGeneration: generation, items: [item], collections: [], committedBoundary: date, tentativePagination: nil, lastSuccessfulSync: date, lastFullSweep: date, skippedRecordCount: 0)
        }
        defer { harness.cleanup() }
        let engine = IntegrationsSyncEngine(credentials: harness.credentials, cache: harness.cache, preferences: try makeIntegrationPreferences(suiteName: harness.suiteName), readwise: ScriptedReadwiseService(), raindrop: ScriptedRaindropService(collectionError: .server(status: 500), pages: [integrationPage(items: [item])]))

        await #expect(throws: IntegrationError.server(status: 500)) {
            try await engine.sync(provider: .raindrop)
        }

        guard case .snapshot(let cached) = await harness.cache.load(provider: .raindrop) else { Issue.record("Expected the prior snapshot"); return }
        #expect(cached.lastSuccessfulSync == date)
        #expect(cached.items.map(\.id) == [item.id])
    }

    @Test func disconnectCancelsAnInFlightProviderSync() async throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let committedItem = try makeIntegrationItem(provider: .readwise, id: "committed", updatedAt: boundary)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(
                provider: .readwise,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [committedItem],
                collections: ReadwiseClient.locationCollections,
                committedBoundary: boundary,
                tentativePagination: nil,
                lastSuccessfulSync: boundary,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let started = IntegrationTestGate()
        let readwise = CancellationBlockingReadwiseService(pageStarted: started)
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )
        let syncTask = Task { try await engine.sync(provider: .readwise) }
        await started.wait()

        try await engine.disconnect(provider: .readwise, deleteDownloads: false)

        await #expect(throws: CancellationError.self) {
            try await syncTask.value
        }
        let credential = await harness.credentials.credential(for: .readwise)
        #expect(credential == nil)
        if case .missing = await harness.cache.load(provider: .readwise) {} else {
            Issue.record("Expected disconnect to remove the provider snapshot")
        }
    }

    @Test func readwisePDFIsResolvedAtOpenInstalledDurablyAndReused() async throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(
            provider: .readwise,
            id: "rw-pdf",
            updatedAt: updatedAt,
            kind: .pdf,
            sourceURL: URL(string: "https://example.com/paper"),
            pdfRetrieval: .readwiseItem(id: "rw-pdf")
        )
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot.empty(provider: .readwise, fingerprint: fingerprint, generation: generation)
        }
        defer { harness.cleanup() }
        let rawSourceJSON = try JSONSerialization.jsonObject(with: FixtureLoader.data("Readwise", "raw-source"))
        let rawSourceObject = try #require(rawSourceJSON as? [String: Any])
        let results = try #require(rawSourceObject["results"] as? [[String: Any]])
        let signedString = try #require(results.first?["raw_source_url"] as? String)
        let signedURL = try #require(URL(string: signedString))
        let readwise = ScriptedReadwiseService(rawSource: signedURL)
        let downloader = RecordingIntegrationDownloader(payload: try integrationTestPDFData(), headers: ["ETag": "pdf-etag"])
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService(),
            downloader: downloader,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let route = try await engine.download(item) { _ in }
        guard case .file(let managedURL) = route else {
            Issue.record("Expected a managed local PDF route")
            return
        }
        let rawSourceIDs = await readwise.rawSourceIDs()
        let downloadRequests = await downloader.requests()
        #expect(FileManager.default.fileExists(atPath: managedURL.path))
        #expect(managedURL.path.hasPrefix(harness.root.path))
        #expect(rawSourceIDs == ["rw-pdf"])
        #expect(downloadRequests == [signedURL])

        let manifestURL = try await harness.cache.manifestURL(provider: .readwise, itemID: item.vendorID)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(IntegrationsCache.DownloadManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.provider == .readwise)
        #expect(manifest.itemID == "rw-pdf")
        #expect(manifest.revision == ISO8601DateFormatter.integrationString(from: updatedAt))
        let persistedManifest = String(decoding: try Data(contentsOf: manifestURL), as: UTF8.self)
        #expect(persistedManifest.contains("signed.example.com") == false)

        let freshEngine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService(),
            downloader: downloader
        )
        let durableRoute = await freshEngine.existingRoute(for: item)
        let reusedRoute = try await freshEngine.download(item) { _ in }
        let finalRawSourceIDs = await readwise.rawSourceIDs()
        let finalDownloadRequests = await downloader.requests()
        #expect(durableRoute == .file(managedURL))
        #expect(reusedRoute == .file(managedURL))
        #expect(finalRawSourceIDs == ["rw-pdf"])
        #expect(finalDownloadRequests == [signedURL])
    }

    @Test func aRepeatingCursorEndsTheWalkInsteadOfPagingForever() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .readwise, id: "looped", updatedAt: date)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            .empty(provider: .readwise, fingerprint: fingerprint, generation: generation)
        }
        defer { harness.cleanup() }
        let readwise = LoopingReadwiseService(response: integrationPage(items: [item], nextCursor: "stuck"))
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )

        await #expect(throws: IntegrationError.paginationDidNotAdvance) {
            try await engine.sync(provider: .readwise, forceFull: true)
        }

        // Two calls: the first page is progress, the second repeats it. Without
        // the guard this stub would page until the process died.
        #expect(await readwise.callCount() == 2)
        guard case .snapshot(let cached) = await harness.cache.load(provider: .readwise) else {
            Issue.record("Expected the walk to leave its progress behind")
            return
        }
        #expect(cached.items.isEmpty)
        #expect(cached.lastFullSweep == nil)
    }

    @Test func anEmptyPageThatPromisesMoreEndsTheWalk() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .readwise, id: "first", updatedAt: date)
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            .empty(provider: .readwise, fingerprint: fingerprint, generation: generation)
        }
        defer { harness.cleanup() }
        let readwise = ScriptedReadwiseService(pages: [
            integrationPage(items: [item], nextCursor: "2"),
            integrationPage(items: [], nextCursor: "3", responseWasEmpty: true)
        ])
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )

        await #expect(throws: IntegrationError.paginationDidNotAdvance) {
            try await engine.sync(provider: .readwise, forceFull: true)
        }

        #expect(await readwise.pageCalls().map(\.cursor) == [nil, "2"])
    }

    @Test func aFullWalkResumedAfterARestartMergesRatherThanDeletingShiftedItems() async throws {
        let boundary = Date(timeIntervalSince1970: 1_700_000_000)
        let previousSweep = Date(timeIntervalSince1970: 1_600_000_000)
        let firstPageItem = try makeIntegrationItem(provider: .raindrop, id: "page-one", updatedAt: boundary.addingTimeInterval(60))
        let shifted = try makeIntegrationItem(provider: .raindrop, id: "shifted", updatedAt: boundary)
        let harness = try await IntegrationEngineHarness.make(provider: .raindrop) { fingerprint, generation in
            ProviderSnapshot(
                provider: .raindrop,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [firstPageItem, shifted],
                collections: [],
                committedBoundary: firstPageItem.updatedAt,
                tentativePagination: nil,
                lastSuccessfulSync: boundary,
                lastFullSweep: previousSweep,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let interruptedEngine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: ScriptedRaindropService(pages: [integrationPage(items: [firstPageItem], nextCursor: "1")], terminalError: .server(status: 500))
        )

        await #expect(throws: IntegrationError.server(status: 500)) {
            try await interruptedEngine.sync(provider: .raindrop)
        }

        // Relaunch. `shifted` slid up into page 0 while the app was gone, so the
        // resumed walk starts at page 1 and never sees it again — page-offset
        // pagination cannot tell that absence apart from a server-side delete.
        let resumedRaindrop = ScriptedRaindropService(pages: [integrationPage(items: [])])
        let resumedEngine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: resumedRaindrop,
            now: { Date(timeIntervalSince1970: 1_800_000_000) }
        )

        let snapshot = try await resumedEngine.sync(provider: .raindrop)

        #expect(await resumedRaindrop.pageCalls() == [.init(page: 1, perPage: 50)])
        #expect(Set(snapshot.items.map(\.id)) == Set([firstPageItem.id, shifted.id]))
        #expect(snapshot.lastFullSweep == previousSweep)
        #expect(snapshot.tentativePagination == nil)
    }

    @Test func walkCheckpointsInBatchesButAlwaysSavesItsProgressOnTheWayOut() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let items = try (1...3).map { try makeIntegrationItem(provider: .readwise, id: "page-\($0)", updatedAt: date.addingTimeInterval(Double($0) * 60)) }
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            .empty(provider: .readwise, fingerprint: fingerprint, generation: generation)
        }
        defer { harness.cleanup() }
        let readwise = ScriptedReadwiseService(
            pages: [
                integrationPage(items: [items[0]], nextCursor: "2"),
                integrationPage(items: [items[1]], nextCursor: "3"),
                integrationPage(items: [items[2]], nextCursor: "4")
            ],
            terminalError: .server(status: 500)
        )
        let cache = harness.cache
        let recorder = CachedWalkRecorder()
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )

        await #expect(throws: IntegrationError.server(status: 500)) {
            try await engine.sync(provider: .readwise, forceFull: true) { _ in
                guard case .snapshot(let snapshot) = await cache.load(provider: .readwise) else { return }
                await recorder.record(snapshot.tentativePagination != nil)
            }
        }

        // Three pages is inside one checkpoint window, so none of them paid for a
        // re-sort and re-encode of everything fetched so far…
        #expect(await recorder.observations() == [false, false, false])
        // …and the failure still leaves the whole walk on disk to resume from.
        guard case .snapshot(let cached) = await cache.load(provider: .readwise) else {
            Issue.record("Expected the interrupted walk to be checkpointed on the way out")
            return
        }
        let tentative = try #require(cached.tentativePagination)
        #expect(tentative.cursor == "4")
        #expect(tentative.fetchedItems.map(\.id).sorted() == items.map(\.id).sorted())
    }

    @Test(.timeLimit(.minutes(1))) func aFullRequestThatJoinsAnIncrementalSyncStillRunsItsOwnSweep() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let cachedItem = try makeIntegrationItem(provider: .readwise, id: "cached", updatedAt: date)
        let freshItem = try makeIntegrationItem(provider: .readwise, id: "fresh", updatedAt: date.addingTimeInterval(60))
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            ProviderSnapshot(provider: .readwise, accountFingerprint: fingerprint, connectionGeneration: generation, items: [cachedItem], collections: ReadwiseClient.locationCollections, committedBoundary: date, tentativePagination: nil, lastSuccessfulSync: date, lastFullSweep: nil, skippedRecordCount: 0)
        }
        defer { harness.cleanup() }
        let started = IntegrationTestGate(), release = IntegrationTestGate()
        let readwise = ScriptedReadwiseService(
            pages: [integrationPage(items: [freshItem]), integrationPage(items: [cachedItem, freshItem])],
            pageStarted: started,
            pageRelease: release
        )
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: readwise,
            raindrop: ScriptedRaindropService()
        )
        let incrementalTask = Task { try await engine.sync(provider: .readwise) }
        await started.wait()
        let fullTask = Task { try await engine.sync(provider: .readwise, forceFull: true) }
        for _ in 0..<64 { await Task.yield() }
        await release.open()

        let incremental = try await incrementalTask.value
        let full = try await fullTask.value

        let calls = await readwise.pageCalls()
        #expect(calls.count == 2)
        #expect(calls.first?.updatedAfter == date.addingTimeInterval(-300))
        #expect(calls.last?.updatedAfter == nil)
        #expect(Set(incremental.items.map(\.id)) == Set([cachedItem.id, freshItem.id]))
        #expect(Set(full.items.map(\.id)) == Set([cachedItem.id, freshItem.id]))
        #expect(full.lastFullSweep != nil)
    }

    @Test func anItemUpdatedOnTheServiceIsDownloadedAgainInsteadOfServingTheStaleCopy() async throws {
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = try makeIntegrationItem(provider: .readwise, id: "rw-pdf", updatedAt: updatedAt, kind: .pdf, pdfRetrieval: .readwiseItem(id: "rw-pdf"))
        let harness = try await IntegrationEngineHarness.make(provider: .readwise) { fingerprint, generation in
            .empty(provider: .readwise, fingerprint: fingerprint, generation: generation)
        }
        defer { harness.cleanup() }
        let downloader = RecordingIntegrationDownloader(payload: try integrationTestPDFData())
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(rawSource: URL(string: "https://signed.example.com/paper.pdf")),
            raindrop: ScriptedRaindropService(),
            downloader: downloader
        )

        let first = try await engine.download(item) { _ in }
        let updated = try makeIntegrationItem(provider: .readwise, id: "rw-pdf", updatedAt: updatedAt.addingTimeInterval(3600), kind: .pdf, pdfRetrieval: .readwiseItem(id: "rw-pdf"))
        let staleRoute = await engine.existingRoute(for: updated)
        let second = try await engine.download(updated) { _ in }

        #expect(staleRoute == nil)
        #expect(second == first)
        #expect(await downloader.requests().count == 2)
        #expect(await engine.existingRoute(for: updated) == second)
        #expect(await engine.existingRoute(for: item) == nil)
        let manifestURL = try await harness.cache.manifestURL(provider: .readwise, itemID: item.vendorID)
        let manifest = try JSONDecoder().decode(IntegrationsCache.DownloadManifest.self, from: Data(contentsOf: manifestURL))
        #expect(manifest.revision == ISO8601DateFormatter.integrationString(from: updated.updatedAt))
    }

    @Test func movePatchesCachedSnapshotAfterProviderConfirms() async throws {
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let moveTime = Date(timeIntervalSince1970: 1_700_000_100)
        let item = try makeIntegrationItem(provider: .raindrop, id: "42", updatedAt: savedAt)
        let bystander = try makeIntegrationItem(provider: .raindrop, id: "other", updatedAt: savedAt)
        let harness = try await IntegrationEngineHarness.make(provider: .raindrop) { fingerprint, generation in
            ProviderSnapshot(
                provider: .raindrop,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [item, bystander],
                collections: [],
                committedBoundary: nil,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let raindrop = ScriptedRaindropService()
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: raindrop,
            now: { moveTime }
        )

        try await engine.move(item, toCollectionVendorID: "11")

        #expect(await raindrop.moveCalls() == [.init(itemID: "42", collectionVendorID: "11")])
        guard case .snapshot(let snapshot) = await harness.cache.load(provider: .raindrop) else {
            Issue.record("Expected the cached snapshot to survive the move")
            return
        }
        let moved = try #require(snapshot.items.first { $0.vendorID == "42" })
        #expect(moved.collectionIDs == ["raindrop:collection:11"])
        #expect(moved.updatedAt == moveTime)
        let untouched = try #require(snapshot.items.first { $0.vendorID == "other" })
        #expect(untouched.collectionIDs.isEmpty)
        #expect(untouched.updatedAt == savedAt)
        #expect(snapshot.items.map(\.vendorID) == ["42", "other"])
    }

    @Test func moveFailsForDisconnectedProviderWithoutCallingTheService() async throws {
        let item = try makeIntegrationItem(provider: .raindrop, id: "42", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let root = try IntegrationTemporaryRoot.make()
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Vellum.IntegrationsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let raindrop = ScriptedRaindropService()
        let engine = IntegrationsSyncEngine(
            credentials: InMemoryIntegrationCredentials(),
            cache: IntegrationsCache(root: root),
            preferences: try makeIntegrationPreferences(suiteName: suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: raindrop
        )

        await #expect(throws: IntegrationError.disconnected) {
            try await engine.move(item, toCollectionVendorID: "11")
        }
        #expect(await raindrop.moveCalls().isEmpty)
    }

    @Test func moveRacingADisconnectDoesNotResurrectTheDeletedSnapshot() async throws {
        let item = try makeIntegrationItem(provider: .raindrop, id: "42", updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let harness = try await IntegrationEngineHarness.make(provider: .raindrop) { fingerprint, generation in
            ProviderSnapshot(
                provider: .raindrop,
                accountFingerprint: fingerprint,
                connectionGeneration: generation,
                items: [item],
                collections: [],
                committedBoundary: nil,
                tentativePagination: nil,
                lastSuccessfulSync: nil,
                lastFullSweep: nil,
                skippedRecordCount: 0
            )
        }
        defer { harness.cleanup() }
        let moveStarted = IntegrationTestGate()
        let moveRelease = IntegrationTestGate()
        let raindrop = ScriptedRaindropService(moveStarted: moveStarted, moveRelease: moveRelease)
        let engine = IntegrationsSyncEngine(
            credentials: harness.credentials,
            cache: harness.cache,
            preferences: try makeIntegrationPreferences(suiteName: harness.suiteName),
            readwise: ScriptedReadwiseService(),
            raindrop: raindrop
        )

        let moveTask = Task { try await engine.move(item, toCollectionVendorID: "11") }
        await moveStarted.wait()
        try await engine.disconnect(provider: .raindrop, deleteDownloads: false)
        await moveRelease.open()

        await #expect(throws: IntegrationError.staleGeneration) { try await moveTask.value }
        let providerDirectory = harness.root.appendingPathComponent("raindrop", isDirectory: true)
        #expect(FileManager.default.fileExists(atPath: providerDirectory.appendingPathComponent("snapshot.json").path) == false)
        #expect(FileManager.default.fileExists(atPath: providerDirectory.appendingPathComponent("snapshot.backup.json").path) == false)
    }
}

/// A service stuck in a paging loop: it keeps reporting more results while
/// handing back the same cursor and the same record.
private actor LoopingReadwiseService: ReadwiseServing {
    private let response: IntegrationPage
    private var calls = 0

    init(response: IntegrationPage) { self.response = response }

    func validate(token: String) async throws {}
    func page(token: String, cursor: String?, updatedAfter: Date?, limit: Int) async throws -> IntegrationPage { calls += 1; return response }
    func rawSourceURL(token: String, itemID: String) async throws -> URL? { nil }
    func moveItem(token: String, itemID: String, locationVendorID: String) async throws {}
    func callCount() -> Int { calls }
}

/// Records, once per progress callback, whether the walk had written a
/// tentative checkpoint to disk by that point.
private actor CachedWalkRecorder {
    private var values: [Bool] = []
    func record(_ value: Bool) { values.append(value) }
    func observations() -> [Bool] { values }
}

private struct IntegrationEngineHarness {
    let root: URL
    let suiteName: String
    let defaults: UserDefaults
    let credentials: InMemoryIntegrationCredentials
    let cache: IntegrationsCache
    let token: String
    let fingerprint: String
    let generation: Int

    static func make(
        provider: IntegrationProvider,
        snapshot: (String, Int) throws -> ProviderSnapshot
    ) async throws -> Self {
        let root = try IntegrationTemporaryRoot.make()
        let suiteName = "Vellum.IntegrationsTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw IntegrationTestFixtureError.couldNotCreateUserDefaults }
        let preferences = IntegrationPreferences(defaults: defaults)
        let token = "token-\(UUID().uuidString)"
        let fingerprint = integrationFingerprint(token)
        let generation = 1
        preferences.persist(.init(enabled: true, generation: generation, accountFingerprint: fingerprint), for: provider)
        let credentials = InMemoryIntegrationCredentials([provider: token])
        let cache = IntegrationsCache(root: root)
        try await cache.save(try snapshot(fingerprint, generation))
        return .init(
            root: root,
            suiteName: suiteName,
            defaults: defaults,
            credentials: credentials,
            cache: cache,
            token: token,
            fingerprint: fingerprint,
            generation: generation
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
    }
}
