import Foundation
import Testing

@testable import Vellum

// The wiring between the three pre-built pieces: the planner decides, the
// offline store moves bytes, the ledger holds the fourteen-day clock. What
// these tests are really pinning is that a downloaded item gets a retention
// entry, that an expired one does not come straight back, and that reading or
// annotating changes both halves consistently.
//
// `.serialized` because the ledger and the prefetch state both resolve their
// paths through `RetentionLayout.directoryOverride`, which is process-global.

@Suite("Read-later autopull — prefetch, retention and eviction wiring", .serialized)
struct ReadLaterPrefetcherTests {
    private let now = RetentionFixtures.date("2026-08-02T09:00:00.000000+00:00")

    private func item(
        _ id: String, kind: ReadLaterKind = .article, provider: IntegrationProvider = .readwise
    ) throws -> ReadLaterItem {
        try makeIntegrationItem(provider: provider, id: id, updatedAt: now, kind: kind)
    }

    /// A prefetcher whose ledger and prefetch state both live in `directory`.
    private func makePrefetcher(
        directory: URL, offline: RetentionFixtures.OfflineStoreDouble, clock: PositionClock
    ) -> ReadLaterPrefetcher {
        ReadLaterPrefetcher(
            offline: offline,
            ledger: RetentionLedger(
                fileURL: directory.appendingPathComponent("retention.json"), clock: clock),
            state: ReadLaterPrefetchState(
                fileURL: directory.appendingPathComponent("prefetch.json"), clock: clock),
            clock: clock)
    }

    private func withScratch(
        _ body: (URL, RetentionFixtures.OfflineStoreDouble, ManualPositionClock, ReadLaterPrefetcher)
            async throws -> Void
    ) async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch")
        defer { RetentionFixtures.remove(directory) }
        let offline = RetentionFixtures.OfflineStoreDouble()
        let clock = ManualPositionClock(now)
        try await body(directory, offline, clock, makePrefetcher(directory: directory, offline: offline, clock: clock))
    }

    @Test("A run downloads the queue and starts each item's clock at local ingestion")
    func runStoresAndTracks() async throws {
        try await withScratch { directory, offline, clock, prefetcher in
            let items = try [item("a"), item("b", kind: .pdf)]
            let report = await prefetcher.run(items: items, isEnabled: true)

            #expect(report.stored == 2)
            #expect(report.failed == 0)
            #expect(report.bytes == 8_192)
            #expect(await Set(offline.storeCalls) == Set(items.map(\.id)))

            let ledger = RetentionLedger(
                fileURL: directory.appendingPathComponent("retention.json"), clock: clock)
            let tracked = await ledger.snapshot().items
            #expect(Set(tracked.keys) == Set(items.map(\.id)))
            // The clock starts now, not at the provider's savedAt.
            #expect(tracked[items[0].id]?.addedAt == now)
            #expect(tracked[items[0].id]?.offlineBytes == 4_096)
        }
    }

    @Test("With the setting off nothing is downloaded and nothing is tracked")
    func disabledRunDoesNothing() async throws {
        try await withScratch { _, offline, _, prefetcher in
            let report = await prefetcher.run(items: [try item("a")], isEnabled: false)
            #expect(report.stored == 0)
            #expect(report.skipped == 1)
            #expect(await offline.storeCalls.isEmpty)
        }
    }

    @Test("A failed download records no retention entry")
    func failedDownloadIsNotTracked() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-failure")
        defer { RetentionFixtures.remove(directory) }
        let broken = try item("broken")
        let offline = RetentionFixtures.OfflineStoreDouble(
            failing: [broken.id: IntegrationError.invalidResponse])
        let clock = ManualPositionClock(now)
        let prefetcher = makePrefetcher(directory: directory, offline: offline, clock: clock)

        let report = await prefetcher.run(items: [broken, try item("ok")], isEnabled: true)
        #expect(report.failed == 1)
        #expect(report.stored == 1)

        let ledger = RetentionLedger(
            fileURL: directory.appendingPathComponent("retention.json"), clock: clock)
        #expect(await ledger.snapshot().items[broken.id] == nil)
    }

    @Test("A rate-limited provider ends that provider's run and leaves the other one alone")
    func rateLimitBacksOff() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-ratelimit")
        defer { RetentionFixtures.remove(directory) }
        let first = try item("a", provider: .readwise)
        let second = try item("b", provider: .readwise)
        let other = try item("c", provider: .raindrop)
        let offline = RetentionFixtures.OfflineStoreDouble(
            failing: [first.id: IntegrationError.rateLimited])
        let clock = ManualPositionClock(now)
        let prefetcher = makePrefetcher(directory: directory, offline: offline, clock: clock)

        let report = await prefetcher.run(items: [first, second, other], isEnabled: true)
        #expect(report.backedOff)
        // The second Readwise item is never attempted; the Raindrop one is.
        #expect(await offline.storeCalls.contains(second.id) == false)
        #expect(await offline.storeCalls.contains(other.id))
    }

    @Test("A second run downloads nothing, because the copies are already here")
    func secondRunIsIdempotent() async throws {
        try await withScratch { _, offline, _, prefetcher in
            let items = try [item("a"), item("b")]
            _ = await prefetcher.run(items: items, isEnabled: true)
            let second = await prefetcher.run(items: items, isEnabled: true)
            #expect(second.stored == 0)
            #expect(second.skipped == 2)
            #expect(await offline.storeCalls.count == 2)
        }
    }

    @Test("A sweep arriving during prefetch waits and evaluates the landed copy")
    func sweepSerializesBehindPrefetch() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-serialization")
        defer { RetentionFixtures.remove(directory) }
        let started = IntegrationTestGate()
        let release = IntegrationTestGate()
        let offline = RetentionFixtures.OfflineStoreDouble(
            storeStarted: started, storeRelease: release)
        let clock = ManualPositionClock(now)
        let prefetcher = makePrefetcher(directory: directory, offline: offline, clock: clock)
        let queued = try item("serialized")

        let runTask = Task { await prefetcher.run(items: [queued], isEnabled: true) }
        await started.wait()
        let sweepTask = Task { await prefetcher.sweep(items: [queued], now: now) }
        await release.open()

        let run = await runTask.value
        let sweep = await sweepTask.value
        #expect(run.stored == 1)
        #expect(sweep.evaluated == 1)
        #expect(sweep.retained == 1)
    }

    @Test("Fourteen days later the sweep deletes the copy and the ledger forgets it")
    func sweepDeletesExpiredCopies() async throws {
        try await withScratch { _, offline, clock, prefetcher in
            let stale = try item("stale")
            _ = await prefetcher.run(items: [stale], isEnabled: true)

            let later = now.addingTimeInterval(RetentionFixtures.days(14))
            clock.set(later)
            let report = await prefetcher.sweep(items: [stale], now: later)
            #expect(report.expired == 1)
            #expect(report.deleted == 1)
            #expect(await offline.removeCalls == [stale.id])
        }
    }

    @Test("A swept item is not re-downloaded by the next run")
    func evictedItemStaysGone() async throws {
        try await withScratch { _, offline, clock, prefetcher in
            let stale = try item("stale")
            _ = await prefetcher.run(items: [stale], isEnabled: true)
            let later = now.addingTimeInterval(RetentionFixtures.days(14))
            clock.set(later)
            _ = await prefetcher.sweep(items: [stale], now: later)

            let report = await prefetcher.run(items: [stale], isEnabled: true)
            #expect(report.stored == 0)
            #expect(await offline.storeCalls == [stale.id])
        }
    }

    @Test("Reading an expired item lifts the tombstone, so the next run downloads it again")
    func readingRestoresEligibility() async throws {
        try await withScratch { _, offline, clock, prefetcher in
            let stale = try item("stale")
            _ = await prefetcher.run(items: [stale], isEnabled: true)
            let later = now.addingTimeInterval(RetentionFixtures.days(14))
            clock.set(later)
            _ = await prefetcher.sweep(items: [stale], now: later)

            await prefetcher.markRead(stale)
            let report = await prefetcher.run(items: [stale], isEnabled: true)
            #expect(report.stored == 1)
            #expect(await offline.storeCalls == [stale.id, stale.id])
        }
    }

    @Test("A read pushes expiry out by another fourteen days")
    func readResetsTheClock() async throws {
        try await withScratch { directory, _, clock, prefetcher in
            let read = try item("read")
            _ = await prefetcher.run(items: [read], isEnabled: true)

            let day13 = now.addingTimeInterval(RetentionFixtures.days(13))
            clock.set(day13)
            await prefetcher.markRead(read)

            let day15 = now.addingTimeInterval(RetentionFixtures.days(15))
            clock.set(day15)
            let report = await prefetcher.sweep(items: [read], now: day15)
            #expect(report.retained == 1)
            #expect(report.deleted == 0)

            let ledger = RetentionLedger(
                fileURL: directory.appendingPathComponent("retention.json"), clock: clock)
            #expect(await ledger.snapshot().items[read.id]?.lastReadAt == day13)
        }
    }

    @Test("An annotated item is exempted by the pre-sweep reconcile and never deleted")
    func annotationExemptsDuringSweep() async throws {
        try await withScratch { _, offline, clock, prefetcher in
            let annotated = try item("annotated")
            _ = await prefetcher.run(items: [annotated], isEnabled: true)
            // The annotation is made in the reader, so the ledger learns about
            // it the same way the app does: from the stored copy itself.
            await offline.setExempt([annotated.id])

            let later = now.addingTimeInterval(RetentionFixtures.days(40))
            clock.set(later)
            let report = await prefetcher.sweep(items: [annotated], now: later)
            #expect(report.exempt == 1)
            #expect(report.deleted == 0)
            #expect(await offline.removeCalls.isEmpty)
        }
    }

    @Test("An item whose copy refuses to delete stays tracked and un-tombstoned")
    func refusedDeletionStaysTracked() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-refuse")
        defer { RetentionFixtures.remove(directory) }
        let open = try item("open")
        let offline = RetentionFixtures.OfflineStoreDouble(refusingRemoval: [open.id])
        let clock = ManualPositionClock(now)
        let prefetcher = makePrefetcher(directory: directory, offline: offline, clock: clock)
        _ = await prefetcher.run(items: [open], isEnabled: true)

        let later = now.addingTimeInterval(RetentionFixtures.days(20))
        clock.set(later)
        let report = await prefetcher.sweep(items: [open], now: later)
        #expect(report.expired == 1)
        #expect(report.deleted == 0)

        let ledger = RetentionLedger(
            fileURL: directory.appendingPathComponent("retention.json"), clock: clock)
        #expect(await ledger.snapshot().items[open.id] != nil)
        let state = ReadLaterPrefetchState(
            fileURL: directory.appendingPathComponent("prefetch.json"), clock: clock)
        #expect(await state.wasEvicted(open.id) == false)
    }

    @Test("A vanished PDF is still deleted by id")
    func vanishedItemIsDeletedByID() async throws {
        try await withScratch { _, offline, clock, prefetcher in
            let gone = try item("gone", kind: .pdf)
            _ = await prefetcher.run(items: [gone], isEnabled: true)
            let later = now.addingTimeInterval(RetentionFixtures.days(30))
            clock.set(later)
            // The queue no longer contains it, but its provider/id still names
            // the PDF and the offline store verifies it is not annotated.
            let report = await prefetcher.sweep(items: [], now: later)
            #expect(report.deleted == 1)
            #expect(await offline.removeCalls == [gone.id])
        }
    }

    @Test("A legacy vanished article without a source locator stays tracked")
    func legacyArticleWithoutLocatorIsNotFalselyDeleted() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-legacy-article")
        defer { RetentionFixtures.remove(directory) }
        let clock = ManualPositionClock(now)
        let ledger = RetentionLedger(
            fileURL: directory.appendingPathComponent("retention.json"), clock: clock)
        let article = try item("legacy-article")
        await ledger.markAdded(article.id, at: now, offlineBytes: 15)
        let prefetcher = ReadLaterPrefetcher(
            offline: IntegrationsOfflineStore(
                engine: IntegrationsSyncEngine(credentials: InMemoryIntegrationCredentials())),
            ledger: ledger,
            state: ReadLaterPrefetchState(
                fileURL: directory.appendingPathComponent("prefetch.json"), clock: clock),
            clock: clock)

        let later = now.addingTimeInterval(RetentionFixtures.days(30))
        clock.set(later)
        let report = await prefetcher.sweep(items: [], now: later)

        #expect(report.expired == 1)
        #expect(report.deleted == 0)
        #expect(await ledger.snapshot().items[article.id] != nil)
    }

    @Test("A current item kind change removes both its article and PDF artifacts")
    func currentKindChangeDeletesEveryLocatedArtifact() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-article")
        let webDirectory = directory.appendingPathComponent("web", isDirectory: true)
        defer {
            WebLibrary.storeDirOverride = nil
            WebStorageSettings.modeOverride = nil
            RetentionFixtures.remove(directory)
        }
        try FileManager.default.createDirectory(at: webDirectory, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = webDirectory
        WebStorageSettings.modeOverride = .local

        let article = try item("gone-article")
        let normalized = try WebUrl.normalize(article.sourceURL.absoluteString)
        let key = WebLibrary.pageKey(normalized)
        try Data("offline article".utf8).write(to: WebLibrary.snapshotPath(forKey: key))

        let cache = IntegrationsCache(
            root: directory.appendingPathComponent("integrations", isDirectory: true))
        let temporaryPDF = try await cache.temporaryDownloadURL(
            provider: article.provider, itemID: article.vendorID)
        try Data("%PDF-1.4\n%%EOF".utf8).write(to: temporaryPDF)
        _ = try await cache.installDownload(
            temporaryURL: temporaryPDF,
            manifest: .init(
                provider: article.provider, itemID: article.vendorID, revision: "pdf-revision"))
        let engine = IntegrationsSyncEngine(
            credentials: InMemoryIntegrationCredentials(), cache: cache)

        let clock = ManualPositionClock(now)
        let ledger = RetentionLedger(
            fileURL: directory.appendingPathComponent("retention.json"), clock: clock)
        await ledger.markAdded(
            article.id, at: now, offlineBytes: 15, sourceURL: normalized)
        let prefetcher = ReadLaterPrefetcher(
            offline: IntegrationsOfflineStore(engine: engine),
            ledger: ledger,
            state: ReadLaterPrefetchState(
                fileURL: directory.appendingPathComponent("prefetch.json"), clock: clock),
            clock: clock)

        let later = now.addingTimeInterval(RetentionFixtures.days(30))
        clock.set(later)
        let currentPDF = try item("gone-article", kind: .pdf)
        let report = await prefetcher.sweep(items: [currentPDF], now: later)

        #expect(report.deleted == 1)
        #expect(WebLibrary.hasLocalSnapshot(forKey: key) == false)
        #expect(
            await cache.hasDownloadArtifacts(
                provider: article.provider, itemID: article.vendorID) == false)
        #expect(await ledger.snapshot().items[article.id] == nil)
    }

}

@Suite("Read-later autopull — the eviction tombstone file", .serialized)
struct ReadLaterPrefetchStateTests {
    private let writtenAt = RetentionFixtures.date("2026-08-02T18:40:11.014000+00:00")

    @Test("The tombstone file round-trips and is versioned")
    func roundTrip() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-state")
        defer { RetentionFixtures.remove(directory) }
        let url = directory.appendingPathComponent("prefetch.json")
        let state = ReadLaterPrefetchState(fileURL: url, clock: ManualPositionClock(writtenAt))
        await state.markEvicted([RetentionFixtures.raindrop], at: writtenAt)

        let data = try Data(contentsOf: url)
        let decoded = try RetentionCoding.decoder.decode(
            ReadLaterPrefetchStateFile.self, from: data)
        #expect(decoded.schemaVersion == RetentionLayout.schemaVersion)
        #expect(decoded.evicted[RetentionFixtures.raindrop] == writtenAt)
        // Same snake_case wire vocabulary as the ledger next to it.
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schema_version"] != nil)
        #expect(json["written_at"] != nil)
    }

    @Test("A corrupt tombstone file reads as empty rather than throwing")
    func corruptFileIsEmpty() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-corrupt")
        defer { RetentionFixtures.remove(directory) }
        let url = directory.appendingPathComponent("prefetch.json")
        try Data("{ not json".utf8).write(to: url)
        let state = ReadLaterPrefetchState(fileURL: url, clock: ManualPositionClock(writtenAt))
        #expect(await state.evictedIDs().isEmpty)
    }

    @Test("Tombstones for items that left the queue are dropped")
    func staleTombstonesAreDropped() async throws {
        let directory = RetentionFixtures.scratchDirectory("read-later-prefetch-retain")
        defer { RetentionFixtures.remove(directory) }
        let state = ReadLaterPrefetchState(
            fileURL: directory.appendingPathComponent("prefetch.json"),
            clock: ManualPositionClock(writtenAt))
        await state.markEvicted([RetentionFixtures.raindrop, RetentionFixtures.readwise])
        await state.retainOnly([RetentionFixtures.readwise])
        #expect(await state.evictedIDs() == [RetentionFixtures.readwise])
    }
}
