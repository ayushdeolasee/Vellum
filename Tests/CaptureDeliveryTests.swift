import Foundation
import Testing

@testable import Vellum

struct CaptureDeliveryTests {
    @Test("DOM limit has an exact boundary and reports URL-only fallback")
    func domLimitBoundary() {
        #expect(CaptureDOMPolicy.includes(byteCount: CaptureDOMPolicy.maximumByteCount))
        #expect(
            CaptureDOMPolicy.includes(byteCount: CaptureDOMPolicy.maximumByteCount + 1) == false)

        let record = CaptureRecordBuilder.make(
            sourceURL: "https://example.com/large",
            title: "Large",
            outerHTML: nil,
            reportedHTMLByteCount: CaptureDOMPolicy.maximumByteCount + 1,
            maxHTMLBytes: CaptureDOMPolicy.maximumByteCount,
            now: CaptureFixtures.date("2026-08-05T12:00:00.000000+00:00"))

        #expect(record.payload == .urlOnly)
        #expect(record.droppedReason == .oversize)
        #expect(record.droppedHTMLByteCount == CaptureDOMPolicy.maximumByteCount + 1)
    }

    @Test("Safari DOM bypasses the app's network fetch")
    func safariDOMWins() async throws {
        let counter = FetchCounter()
        let record = CaptureFixtures.record(
            sourceURL: "https://example.com/article",
            outerHTML: "<html><body>Safari state</body></html>")

        let page = try await CapturePageResolver.resolve(
            record: record,
            normalizedURL: "https://example.com/article",
            fetch: { url in
                await counter.called()
                return CapturePageHTML(html: "network", baseURL: url)
            })

        #expect(page.html == "<html><body>Safari state</body></html>")
        #expect(await counter.count == 0)
    }

    @Test("URL-only capture uses the reader fetch and wake session uses the App Group")
    func urlFallbackAndWakeConfiguration() async throws {
        let record = CaptureRecordBuilder.make(
            sourceURL: "https://example.com/article",
            title: nil,
            outerHTML: nil,
            maxHTMLBytes: CaptureDOMPolicy.maximumByteCount,
            now: CaptureFixtures.date("2026-08-05T12:00:00.000000+00:00"))
        let page = try await CapturePageResolver.resolve(
            record: record,
            normalizedURL: "https://example.com/article",
            fetch: { url in CapturePageHTML(html: "network", baseURL: url) })
        #expect(page.html == "network")

        let identifier = "com.ayushdeolasee.vellum.capture-test.\(UUID().uuidString)"
        let configuration = CaptureBackgroundSession.configuration(identifier: identifier)
        #expect(configuration.identifier == identifier)
        #expect(
            configuration.sharedContainerIdentifier == CaptureInboxLayout.appGroupIdentifier)
        #expect(configuration.sessionSendsLaunchEvents)
    }

    @Test("A durable replay restores New only while its inbox record remains pending")
    func durableReplayRestoresUnreadUntilRecordIsConsumed() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-durable-replay")
        let webRoot = layout.container.appendingPathComponent("web", isDirectory: true)
        let suite = "vellum-capture-replay-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            WebLibrary.storeDirOverride = nil
            defaults.removePersistentDomain(forName: suite)
            CaptureFixtures.remove(layout)
        }
        WebLibrary.storeDirOverride = webRoot

        let record = CaptureFixtures.record()
        let normalizedURL = try WebUrl.normalize(record.sourceURL)
        let key = WebLibrary.pageKey(normalizedURL)
        let storage = WebLibraryStorage()
        let ledger = CapturedUnreadLedger(suiteName: suite)
        try WebArchive.installArchiveDir(
            key: key, snapshotHtml: "<html>durable</html>", assets: [], manifest: nil)
        try await storage.mutateRecord(url: normalizedURL, key: key) { pageRecord in
            pageRecord.saved = true
            pageRecord.savedAt = record.capturedAt
        }
        try CaptureInboxWriter(layout: layout).write(record)

        let fetchCounter = FetchCounter()
        let ingestion = CaptureIngestion(
            layout: layout,
            storage: storage,
            unreadLedger: ledger,
            fetch: { url in
                await fetchCounter.called()
                return CapturePageHTML(html: "unexpected", baseURL: url)
            },
            snapshot: { _, html in CapturedSnapshot(html: html, assets: [], skipped: 0) },
            libraryDidChange: {})

        #expect(await ingestion.drain() == CaptureDrainReport(deduped: 1))
        #expect(await ledger.isUnread(forKey: key))
        #expect(await fetchCounter.count == 0)

        await ledger.clearUnread(forKey: key)
        #expect(await ingestion.drain() == CaptureDrainReport())
        #expect(await ledger.isUnread(forKey: key) == false)
    }
}

private actor FetchCounter {
    private(set) var count = 0

    func called() {
        count += 1
    }
}
