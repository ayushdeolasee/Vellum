import CryptoKit
import Foundation
import Testing

@testable import Vellum

// The ledger is the only thing standing between a fourteen-day-old article and
// its bytes being deleted, so these tests are mostly about restraint: what a
// sweep must NOT touch, and what must survive a reconcile.
//
// `.serialized` because the coexistence test drives `WebLibrary.storeDirOverride`
// and `RetentionLayout.directoryOverride`, both process-global.

@Suite("Read-later retention — ledger and sweep", .serialized)
struct RetentionLedgerTests {
    private let added = RetentionFixtures.date("2026-07-20T09:00:00.000000+00:00")
    private let lastRead = RetentionFixtures.date("2026-07-30T21:14:02.000000+00:00")
    private let annotated = RetentionFixtures.date("2026-08-01T10:00:00.000000+00:00")
    private let writtenAt = RetentionFixtures.date("2026-08-02T18:40:11.014000+00:00")

    /// The one line the contract documents, byte for byte.
    private let documentedBytes = Data(
        #"""
        {"items":{"raindrop:884213771":{"added_at":"2026-07-20T09:00:00.000000+00:00","offline_bytes":482301},"readwise:01j9x7kqvv3":{"added_at":"2026-07-20T09:00:00.000000+00:00","annotated_at":"2026-08-01T10:00:00.000000+00:00","last_read_at":"2026-07-30T21:14:02.000000+00:00","offline_bytes":1204880}},"schema_version":1,"written_at":"2026-08-02T18:40:11.014000+00:00"}
        """#.utf8)

    private func documentedFile() -> RetentionLedgerFile {
        RetentionLedgerFile(
            writtenAt: writtenAt,
            items: [
                RetentionFixtures.raindrop: RetentionItemState(
                    addedAt: added, offlineBytes: 482_301),
                RetentionFixtures.readwise: RetentionItemState(
                    addedAt: added,
                    lastReadAt: lastRead,
                    annotatedAt: annotated,
                    offlineBytes: 1_204_880),
            ])
    }

    private func scratchLedgerURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("retention.json")
    }

    @Test("The ledger file round-trips through encode and decode")
    func roundTrip() throws {
        let file = documentedFile()
        let bytes = try RetentionCoding.encoder.encode(file)
        let decoded = try RetentionCoding.decoder.decode(RetentionLedgerFile.self, from: bytes)
        #expect(decoded == file)
    }

    @Test("The encoded ledger matches the documented bytes exactly")
    func documentedBytesMatch() async throws {
        #expect(try RetentionCoding.encoder.encode(documentedFile()) == documentedBytes)

        // ...and the actor produces those same bytes from its own event API,
        // so the documented example is what a real ledger writes.
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let url = scratchLedgerURL(directory)
        let ledger = RetentionLedger(fileURL: url, clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added, offlineBytes: 482_301)
        await ledger.markAdded(RetentionFixtures.readwise, at: added, offlineBytes: 1_204_880)
        await ledger.markRead(RetentionFixtures.readwise, at: lastRead)
        await ledger.markAnnotated(RetentionFixtures.readwise, at: annotated)
        #expect(try Data(contentsOf: url) == documentedBytes)
    }

    @Test("Article source URLs round-trip under the snake_case wire key")
    func articleSourceURLRoundTrips() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger-source")
        defer { RetentionFixtures.remove(directory) }
        let url = scratchLedgerURL(directory)
        let ledger = RetentionLedger(fileURL: url, clock: ManualPositionClock(writtenAt))
        let source = "https://example.com/article"

        await ledger.markAdded(
            RetentionFixtures.readwise, at: added, offlineBytes: 512, sourceURL: source)

        let data = try Data(contentsOf: url)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let items = try #require(json["items"] as? [String: Any])
        let item = try #require(items[RetentionFixtures.readwise] as? [String: Any])
        #expect(item["source_url"] as? String == source)
        #expect(await ledger.snapshot().items[RetentionFixtures.readwise]?.sourceURL == source)
    }

    @Test("Every written ledger carries schema_version")
    func schemaVersionIsWritten() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let url = scratchLedgerURL(directory)
        let ledger = RetentionLedger(fileURL: url, clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added)

        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let json = try #require(object as? [String: Any])
        #expect(json["schema_version"] as? Int == RetentionLayout.schemaVersion)
        #expect(await ledger.snapshot().schemaVersion == 1)
    }

    /// A ledger is bookkeeping, not user content: unparseable bytes are treated
    /// as absent and rebuilt, and the failure never reaches a caller.
    @Test("A corrupt ledger is treated as empty and rebuilt, never thrown")
    func corruptLedgerRebuilds() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let url = scratchLedgerURL(directory)
        try Data("{ this is not json".utf8).write(to: url)

        let ledger = RetentionLedger(fileURL: url, clock: ManualPositionClock(writtenAt))
        #expect(await ledger.snapshot().items.isEmpty)

        await ledger.markAdded(RetentionFixtures.raindrop, at: added)
        #expect(await ledger.snapshot().items.count == 1)

        let reopened = RetentionLedger(fileURL: url, clock: ManualPositionClock(writtenAt))
        #expect(await reopened.snapshot().items[RetentionFixtures.raindrop]?.addedAt == added)
    }

    @Test("A sweep deletes the offline copies of expired items and nothing else")
    func sweepDeletesOnlyExpired() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let ledger = RetentionLedger(
            fileURL: scratchLedgerURL(directory), clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added)
        await ledger.markAdded(RetentionFixtures.readwise, at: added)
        await ledger.markRead(
            RetentionFixtures.readwise, at: added.addingTimeInterval(RetentionFixtures.days(13)))

        let log = RetentionFixtures.DeleterLog()
        let report = await ledger.sweep(
            now: added.addingTimeInterval(RetentionFixtures.days(20)),
            deleteOfflineCopy: log.deleter)

        #expect(report == RetentionSweepReport(evaluated: 2, retained: 1, expired: 1, deleted: 1))
        #expect(log.deletedIDs == [RetentionFixtures.raindrop])
        #expect(await ledger.snapshot().items.keys.sorted() == [RetentionFixtures.readwise])
    }

    /// Expiry removes bytes, never list rows. The engine has no way to reach the
    /// queue at all — the only thing it can do is call the injected deleter.
    @Test("A sweep leaves the queue entry itself intact")
    func sweepLeavesTheQueueEntry() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let queueURL = directory.appendingPathComponent("queue.json")
        let queueBytes = Data(
            #"{"items":["raindrop:884213771","readwise:01j9x7kqvv3"]}"#.utf8)
        try queueBytes.write(to: queueURL)

        let ledger = RetentionLedger(
            fileURL: scratchLedgerURL(directory), clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added)
        let log = RetentionFixtures.DeleterLog()
        await ledger.sweep(
            now: added.addingTimeInterval(RetentionFixtures.days(20)),
            deleteOfflineCopy: log.deleter)

        #expect(log.deletedIDs == [RetentionFixtures.raindrop])
        #expect(try Data(contentsOf: queueURL) == queueBytes)
    }

    @Test("Sweeping twice is idempotent")
    func sweepIsIdempotent() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let ledger = RetentionLedger(
            fileURL: scratchLedgerURL(directory), clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added)

        let log = RetentionFixtures.DeleterLog()
        let now = added.addingTimeInterval(RetentionFixtures.days(20))
        let first = await ledger.sweep(now: now, deleteOfflineCopy: log.deleter)
        let second = await ledger.sweep(now: now, deleteOfflineCopy: log.deleter)

        #expect(first == RetentionSweepReport(evaluated: 1, expired: 1, deleted: 1))
        #expect(second == RetentionSweepReport())
        #expect(log.deletedIDs == [RetentionFixtures.raindrop])
    }

    /// One-way by construction: a reconcile run against a sidecar that hasn't
    /// downloaded yet must never be able to revoke an exemption, because doing
    /// so would delete content the user annotated.
    @Test("Reconcile can mark an item annotated but never un-mark it")
    func reconcileIsOneWay() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let clock = ManualPositionClock(writtenAt)
        let ledger = RetentionLedger(fileURL: scratchLedgerURL(directory), clock: clock)
        await ledger.markAdded(RetentionFixtures.raindrop, at: added)
        await ledger.markAdded(RetentionFixtures.readwise, at: added)

        await ledger.reconcileAnnotations(itemIDsWithAnnotations: [RetentionFixtures.raindrop])
        let afterFirst = await ledger.snapshot().items
        #expect(afterFirst[RetentionFixtures.raindrop]?.annotatedAt == writtenAt)
        #expect(afterFirst[RetentionFixtures.readwise]?.annotatedAt == nil)

        clock.advance(by: RetentionFixtures.days(5))
        await ledger.reconcileAnnotations(itemIDsWithAnnotations: [])
        await ledger.reconcileAnnotations(itemIDsWithAnnotations: [RetentionFixtures.raindrop])
        let afterSecond = await ledger.snapshot().items
        // Still exempt, and still stamped with the FIRST reconcile's instant.
        #expect(afterSecond[RetentionFixtures.raindrop]?.annotatedAt == writtenAt)
    }

    @Test("An annotated item's offline copy is never deleted by a sweep")
    func annotatedItemSurvivesSweep() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let ledger = RetentionLedger(
            fileURL: scratchLedgerURL(directory), clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.readwise, at: added)
        await ledger.markAnnotated(RetentionFixtures.readwise, at: annotated)

        let log = RetentionFixtures.DeleterLog()
        let report = await ledger.sweep(
            now: added.addingTimeInterval(RetentionFixtures.days(400)),
            deleteOfflineCopy: log.deleter)

        #expect(report == RetentionSweepReport(evaluated: 1, exempt: 1))
        #expect(log.deletedIDs.isEmpty)
        #expect(await ledger.snapshot().items[RetentionFixtures.readwise] != nil)
    }

    @Test("An item whose deleter reports failure stays in the ledger for the next sweep")
    func failedDeleteIsRetried() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let ledger = RetentionLedger(
            fileURL: scratchLedgerURL(directory), clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added)

        let now = added.addingTimeInterval(RetentionFixtures.days(20))
        let failing = RetentionFixtures.DeleterLog(failingFor: [RetentionFixtures.raindrop])
        let first = await ledger.sweep(now: now, deleteOfflineCopy: failing.deleter)
        #expect(first == RetentionSweepReport(evaluated: 1, expired: 1, deleted: 0))
        #expect(await ledger.snapshot().items[RetentionFixtures.raindrop] != nil)

        let succeeding = RetentionFixtures.DeleterLog()
        let second = await ledger.sweep(now: now, deleteOfflineCopy: succeeding.deleter)
        #expect(second == RetentionSweepReport(evaluated: 1, expired: 1, deleted: 1))
        #expect(succeeding.deletedIDs == [RetentionFixtures.raindrop])
    }

    /// A read that arrives for an item the ledger never saw is still evidence
    /// the user has the thing; dropping it would start the window at the next
    /// add instead of at the read.
    @Test("markRead on an unknown item adds it rather than silently dropping the read")
    func markReadAddsUnknownItem() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let ledger = RetentionLedger(
            fileURL: scratchLedgerURL(directory), clock: ManualPositionClock(writtenAt))
        await ledger.markRead(RetentionFixtures.raindrop, at: lastRead)

        let item = try #require(await ledger.snapshot().items[RetentionFixtures.raindrop])
        #expect(item.addedAt == lastRead)
        #expect(item.lastReadAt == lastRead)
        #expect(
            await ledger.verdict(
                for: RetentionFixtures.raindrop,
                now: lastRead.addingTimeInterval(RetentionFixtures.days(1)))
                == .retained(until: lastRead.addingTimeInterval(RetentionFixtures.days(14))))
    }

    @Test("Timestamps are written in the same RFC3339 shape as the webpage sidecar")
    func timestampsMatchTheSidecarShape() async throws {
        let directory = RetentionFixtures.scratchDirectory("retention-ledger")
        defer { RetentionFixtures.remove(directory) }
        let url = scratchLedgerURL(directory)
        let ledger = RetentionLedger(fileURL: url, clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.readwise, at: added)
        await ledger.markRead(RetentionFixtures.readwise, at: lastRead)
        await ledger.markAnnotated(RetentionFixtures.readwise, at: annotated)

        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
        let json = try #require(object as? [String: Any])
        let items = try #require(json["items"] as? [String: Any])
        let entry = try #require(items[RetentionFixtures.readwise] as? [String: Any])

        var stamps = [try #require(json["written_at"] as? String)]
        for key in ["added_at", "last_read_at", "annotated_at"] {
            stamps.append(try #require(entry[key] as? String))
        }
        for stamp in stamps {
            // The sidecar's own parser must accept every byte we write.
            let parsed = try #require(WebLibrary.parseRfc3339(stamp))
            #expect(PositionTimestamp.string(from: parsed) == stamp)
        }
        #expect(entry["added_at"] as? String == "2026-07-20T09:00:00.000000+00:00")
    }

    /// The coexistence pin: `StorageHousekeeping` sweeps derived web/text-cache
    /// artifacts, this sweeps read-later offline copies, and neither may read or
    /// write the other's bookkeeping.
    @Test(
        "The retention sweep writes only under read-later/ and touches no web snapshot or text-cache artifact"
    )
    func sweepStaysInsideReadLater() async throws {
        let root = RetentionFixtures.scratchDirectory("retention-coexistence")
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        let textCacheDir = root.appendingPathComponent("text", isDirectory: true)
        let readLaterDir = root.appendingPathComponent("read-later", isDirectory: true)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: webDir, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: textCacheDir, withIntermediateDirectories: true)

        let previousStore = WebLibrary.storeDirOverride
        let previousDirectory = RetentionLayout.directoryOverride
        WebLibrary.storeDirOverride = webDir
        RetentionLayout.directoryOverride = readLaterDir
        defer {
            WebLibrary.storeDirOverride = previousStore
            RetentionLayout.directoryOverride = previousDirectory
            RetentionFixtures.remove(root)
        }

        var record = WebPageRecord(url: "https://example.com/read-later")
        record.title = "A Post"
        record.saved = true
        record.savedAt = "2026-07-20T09:00:00.000000+00:00"
        try WebLibrary.saveRecord(
            record, at: WebLibrary.recordPath(forKey: WebLibrary.pageKey(record.url)))
        let cacheEntry = textCacheDir.appendingPathComponent("index.json")
        try Data(#"{"entries":{}}"#.utf8).write(to: cacheEntry)

        let before = Self.digests(under: webDir).merging(
            Self.digests(under: textCacheDir), uniquingKeysWith: { lhs, _ in lhs })

        #expect(RetentionLayout.ledgerURL == readLaterDir.appendingPathComponent("retention.json"))
        let ledger = RetentionLedger(clock: ManualPositionClock(writtenAt))
        await ledger.markAdded(RetentionFixtures.raindrop, at: added, offlineBytes: 482_301)
        let log = RetentionFixtures.DeleterLog()
        let report = await ledger.sweep(
            now: added.addingTimeInterval(RetentionFixtures.days(20)),
            deleteOfflineCopy: log.deleter)
        #expect(report.deleted == 1)

        let after = Self.digests(under: webDir).merging(
            Self.digests(under: textCacheDir), uniquingKeysWith: { lhs, _ in lhs })
        #expect(after == before)
        #expect(!before.isEmpty)
        #expect(
            try fileManager.contentsOfDirectory(atPath: readLaterDir.path).sorted()
                == ["retention.json"])
    }

    private static func digests(under root: URL) -> [String: String] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(atPath: root.path) else { return [:] }
        var result: [String: String] = [:]
        for case let relative as String in enumerator {
            let url = root.appendingPathComponent(relative)
            guard let data = try? Data(contentsOf: url) else { continue }
            result[relative] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        return result
    }
}
