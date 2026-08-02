import Foundation
import Testing

@testable import Vellum

// The drain is the only place a capture can be lost, so every test here is
// really about delete ordering: nothing leaves `pending/` until the app has
// committed it or has decided it can never be committed.

@Suite("Capture inbox — drain")
struct CaptureInboxDrainTests {
    /// Records what `ingest` saw, across actor hops.
    private final class IngestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(record: CaptureRecord, key: DocumentKey)] = []

        func append(_ record: CaptureRecord, _ key: DocumentKey) {
            lock.lock()
            defer { lock.unlock() }
            entries.append((record, key))
        }

        var calls: [(record: CaptureRecord, key: DocumentKey)] {
            lock.lock()
            defer { lock.unlock() }
            return entries
        }

        var count: Int { calls.count }
    }

    private struct IngestFailure: Error {}

    private func webKey(_ raw: String) throws -> DocumentKey {
        .web(normalizedURL: try WebUrl.normalize(raw))
    }

    @Test("Draining the same page twice produces exactly one library entry")
    func repeatedDrainsIngestOnce() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)

        try writer.write(
            CaptureFixtures.record(
                captureID: "11111111-1111-4111-8111-111111111111",
                sourceURL: "https://example.com/post"))
        let first = await inbox.drain { _, key in .ingested(key) }
        #expect(first == CaptureDrainReport(ingested: 1))

        // The same page shared again, after the first was already committed.
        try writer.write(
            CaptureFixtures.record(
                captureID: "22222222-2222-4222-8222-222222222222",
                capturedAt: "2026-08-02T19:00:00.000000+00:00",
                sourceURL: "https://example.com/post"))
        let second = await inbox.drain { _, key in .alreadyPresent(key) }
        #expect(second == CaptureDrainReport(deduped: 1))
        #expect(await inbox.pendingCount() == 0)
    }

    @Test("Two pending records for URLs that normalize to the same page collapse to one ingest")
    func intraBatchDedup() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)
        let log = IngestLog()

        try writer.write(
            CaptureFixtures.record(
                captureID: "11111111-1111-4111-8111-111111111111",
                sourceURL: "https://example.com/post?utm_source=newsletter"))
        try writer.write(
            CaptureFixtures.record(
                captureID: "22222222-2222-4222-8222-222222222222",
                capturedAt: "2026-08-02T18:25:00.000000+00:00",
                sourceURL: "https://example.com/post#section-2"))

        let report = await inbox.drain { record, key in
            log.append(record, key)
            return .ingested(key)
        }

        #expect(log.count == 1)
        #expect(report == CaptureDrainReport(ingested: 1, deduped: 1))
        #expect(await inbox.pendingCount() == 0)
        let expectedKey = try webKey("https://example.com/post")
        #expect(log.calls.first?.key == expectedKey)
    }

    @Test("The newest record wins when a page was captured twice")
    func newestRecordWins() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)
        let log = IngestLog()

        try writer.write(
            CaptureFixtures.record(
                captureID: "11111111-1111-4111-8111-111111111111",
                capturedAt: "2026-08-02T18:00:00.000000+00:00",
                sourceURL: "https://example.com/post",
                title: "Draft"))
        try writer.write(
            CaptureFixtures.record(
                captureID: "22222222-2222-4222-8222-222222222222",
                capturedAt: "2026-08-02T18:30:00.000000+00:00",
                sourceURL: "https://example.com/post",
                title: "Published"))

        await inbox.drain { record, key in
            log.append(record, key)
            return .ingested(key)
        }

        #expect(log.calls.first?.record.title == "Published")
    }

    /// A crash between reading a record and committing it must re-drain the
    /// record, so the delete can only ever happen after `ingest` returns.
    @Test("A record is deleted only after ingest commits")
    func deleteHappensAfterCommit() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)

        let url = try writer.write(CaptureFixtures.record())
        let existedDuringIngest = Locked(false)

        await inbox.drain { _, key in
            existedDuringIngest.value = FileManager.default.fileExists(atPath: url.path)
            return .ingested(key)
        }

        #expect(existedDuringIngest.value)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An ingest failure leaves the record pending for the next drain")
    func ingestFailureRetains() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)

        let url = try writer.write(CaptureFixtures.record())
        let failed = await inbox.drain { _, _ in throw IngestFailure() }
        #expect(failed == CaptureDrainReport(retained: 1))
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(CaptureFixtures.names(in: layout.failed).isEmpty)

        let recovered = await inbox.drain { _, key in .ingested(key) }
        #expect(recovered == CaptureDrainReport(ingested: 1))
        #expect(await inbox.pendingCount() == 0)
    }

    /// The bytes still contain a URL the user chose to save, so a parse failure
    /// must not be a delete.
    @Test("A record that cannot be decoded is quarantined, never deleted")
    func undecodableIsQuarantined() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        try layout.createDirectories()
        let inbox = CaptureInbox(layout: layout)

        let name = "0001754159999000-33333333-3333-4333-8333-333333333333.json"
        try Data("{\"source_url\": \"https://example.com/x\"".utf8).write(
            to: layout.pending.appendingPathComponent(name))

        let report = await inbox.drain { _, key in .ingested(key) }
        #expect(report == CaptureDrainReport(quarantined: 1))
        #expect(CaptureFixtures.names(in: layout.pending).isEmpty)
        #expect(CaptureFixtures.names(in: layout.failed) == [name])
    }

    @Test("A pending record older than the abandon window is quarantined")
    func abandonedRecordIsQuarantined() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let clock = ManualPositionClock(CaptureFixtures.date("2026-08-02T18:00:00.000000+00:00"))
        let inbox = CaptureInbox(layout: layout, clock: clock, abandonAfter: 30 * 86_400)

        try writer.write(
            CaptureFixtures.record(capturedAt: "2026-08-02T17:00:00.000000+00:00"))

        // One day in: still a live capture, and an ingest failure keeps it.
        clock.advance(by: 86_400)
        let stillLive = await inbox.drain { _, _ in throw IngestFailure() }
        #expect(stillLive == CaptureDrainReport(retained: 1))

        // Thirty days in: it will never succeed, so stop retrying it forever.
        clock.advance(by: 30 * 86_400)
        let report = await inbox.drain { _, key in .ingested(key) }
        #expect(report == CaptureDrainReport(quarantined: 1))
        #expect(CaptureFixtures.names(in: layout.failed).count == 1)
    }

    @Test("A URL-only record reaches ingest with no HTML, so the app fetches the page itself")
    func urlOnlyReachesIngest() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)
        let log = IngestLog()

        try writer.write(
            CaptureRecordBuilder.make(
                sourceURL: "https://example.com/enormous",
                title: "An Enormous Post",
                outerHTML: String(repeating: "a", count: 4096),
                maxHTMLBytes: 64,
                now: CaptureFixtures.date("2026-08-02T18:23:41.008000+00:00"),
                captureID: "7f0a2c9d-1b3e-4a5f-8c6d-2e9b0a1f3c4d",
                extensionBuild: "0.1.0 (1)"))

        await inbox.drain { record, key in
            log.append(record, key)
            return .ingested(key)
        }

        let seen = try #require(log.calls.first)
        #expect(seen.record.payload == .urlOnly)
        #expect(seen.record.outerHTML == nil)
        #expect(seen.record.droppedReason == .oversize)
        let expectedKey = try webKey("https://example.com/enormous")
        #expect(seen.key == expectedKey)
    }

    /// This is the pin at the handoff: the inbox's dedup key and the library's
    /// storage key must be the same derivation, not two that agree today.
    @Test("The dedup key matches WebLibrary.pageKey for the same normalized URL")
    func dedupKeyMatchesLibraryKey() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)
        let log = IngestLog()

        let raw = "https://example.com/post?utm_campaign=spring&id=7#top"
        try writer.write(CaptureFixtures.record(sourceURL: raw))
        await inbox.drain { record, key in
            log.append(record, key)
            return .ingested(key)
        }

        let normalized = try WebUrl.normalize(raw)
        let seen = try #require(log.calls.first)
        #expect(seen.key.namespace == .web)
        #expect(seen.key.hash == WebLibrary.pageKey(normalized))
        #expect(seen.key.rawValue == "web:\(WebLibrary.pageKey(normalized))")
    }

    @Test("Draining an empty inbox is a no-op")
    func emptyDrainIsNoOp() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let inbox = CaptureInbox(layout: layout)

        let report = await inbox.drain { _, _ in
            Issue.record("an empty inbox must not call ingest")
            return .ingested(DocumentKey.web(normalizedURL: "https://example.com/"))
        }
        #expect(report == CaptureDrainReport())
        #expect(await inbox.pendingCount() == 0)
    }

    @Test("A record whose URL cannot be normalized is quarantined, not retried forever")
    func unnormalizableURLIsQuarantined() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-drain")
        defer { CaptureFixtures.remove(layout) }
        let writer = CaptureInboxWriter(layout: layout)
        let inbox = CaptureInbox(layout: layout)

        // The extension writes `source_url` raw, so a share sheet handing over
        // something the web library can't key — a Files item, say — does reach
        // the drain, and `WebUrl.normalize` rejects any non-http(s) scheme.
        try writer.write(CaptureFixtures.record(sourceURL: "file:///var/mobile/paper.pdf"))

        let report = await inbox.drain { _, key in
            Issue.record("an un-normalizable URL must not reach ingest")
            return .ingested(key)
        }
        #expect(report == CaptureDrainReport(quarantined: 1))
        #expect(CaptureFixtures.names(in: layout.pending).isEmpty)
        #expect(CaptureFixtures.names(in: layout.failed).count == 1)
    }
}

/// Minimal cross-isolation box for values a test closure writes and the test
/// body reads.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            stored = newValue
        }
    }
}
