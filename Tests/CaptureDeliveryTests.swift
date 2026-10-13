import Foundation
import Testing

@testable import Vellum

@Suite(.isolatedStorage)
struct CaptureDeliveryTests {
    @Test("Disabled sync leaves pending captures untouched without fetching")
    func disabledSyncLeavesPendingCaptureUntouched() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-disabled-sync")
        defer { CaptureFixtures.remove(layout) }
        try CaptureInboxWriter(layout: layout).write(
            CaptureFixtures.record(outerHTML: nil))
        let counter = FetchCounter()
        let ingestion = CaptureIngestion(
            layout: layout,
            storage: WebLibraryStorage(),
            syncEnabled: false,
            fetch: { url in
                await counter.called()
                return CapturePageHTML(html: "network", baseURL: url)
            },
            snapshot: { _, html in CapturedSnapshot(html: html, assets: [], skipped: 0) },
            libraryDidChange: {})

        #expect(await ingestion.drain() == CaptureDrainReport())
        #expect(await counter.count == 0)
        #expect(await CaptureInbox(layout: layout, clock: CaptureFixtures.clock).pendingCount() == 1)
    }

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
            clock: CaptureFixtures.clock,
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
    @Test("Share capture preserves an unsaved custom webpage title and its archive ownership")
    @MainActor
    func capturePreservesManualTitle() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-manual-title")
        let previousWebRoot = WebLibrary.storeDirOverride
        let suite = "vellum-capture-title-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            WebLibrary.storeDirOverride = previousWebRoot
            defaults.removePersistentDomain(forName: suite)
            CaptureFixtures.remove(layout)
        }
        WebLibrary.storeDirOverride = layout.container.appendingPathComponent("web")
        let record = CaptureFixtures.record(title: "Safari DOM title")
        let url = try WebUrl.normalize(record.sourceURL)
        let key = WebLibrary.pageKey(url)
        let storage = WebLibraryStorage()
        try await storage.setTitle(rawUrl: url, title: "My page name")
        try CaptureInboxWriter(layout: layout).write(record)
        let ingestion = CaptureIngestion(
            layout: layout, storage: storage, clock: CaptureFixtures.clock,
            unreadLedger: CapturedUnreadLedger(suiteName: suite), syncEnabled: true,
            snapshot: { _, html in CapturedSnapshot(html: html, assets: [], skipped: 0) },
            libraryDidChange: {})
        #expect(await ingestion.drain() == CaptureDrainReport(ingested: 1))
        await ingestion.awaitPendingOperations()
        let saved = try #require(await storage.loadRecord(forKey: key))
        #expect(saved.title == "My page name")
        #expect(saved.titleIsUserDefined)
        #expect(saved.saved)

        let archive = WebLibrary.managedArchivePath(forKey: key)
        let manifest = try WebArchive.readManifest(at: archive)
        #expect(manifest.title == "My page name")
        #expect(manifest.titleIsUserDefined == true)
        // The captured archive must retain the same name on another installation.
        WebLibrary.storeDirOverride = layout.container.appendingPathComponent("imported-web")
        let importedStorage = WebLibraryStorage()
        let imported = try await WebSessionBackend(storage: importedStorage)
            .openVellumwebFile(path: archive.path, sessionId: "imported")
        #expect(imported.info.title == "My page name")
        #expect(imported.info.titleIsUserDefined == true)
        try await imported.setMetadata(key: "title", value: "Later DOM title")
        #expect(await importedStorage.loadRecord(forKey: key)?.title == "My page name")
    }

    @Test("Background cancellation retains intent and foreground retry commits once")
    func backgroundDrainKeepsPendingUntilForegroundRetry() async throws {
        let layout = CaptureFixtures.scratchLayout("capture-background-recovery")
        let previousWebRoot = WebLibrary.storeDirOverride
        WebLibrary.storeDirOverride = layout.container.appendingPathComponent("web")
        defer {
            WebLibrary.storeDirOverride = previousWebRoot
            CaptureFixtures.remove(layout)
        }
        let record = CaptureFixtures.record(sourceURL: "https://example.com/\(UUID().uuidString)", outerHTML: nil)
        let original = try CaptureInboxWriter(layout: layout).write(record)
        let bytes = try Data(contentsOf: original)
        let gate = CaptureFetchGate()
        let ingestion = CaptureIngestion(layout: layout, storage: WebLibraryStorage(),
            clock: CaptureFixtures.clock, syncEnabled: true,
            fetch: { url in
                await gate.pause()
                try Task.checkCancellation()
                return CapturePageHTML(html: "<html>recovered</html>", baseURL: url)
            }, snapshot: { _, html in CapturedSnapshot(html: html, assets: [], skipped: 0) },
            libraryDidChange: {})
        let drain = Task { await ingestion.drain() }
        do { try await gate.waitUntilEntered() }
        catch { await gate.release(); _ = await drain.value; throw error }
        let background = Task { await ingestion.prepareForBackground() }
        do { try await gate.waitUntilCancelled() }
        catch {
            await gate.release()
            _ = await drain.value
            await background.value
            throw error
        }
        await gate.release()
        #expect(await drain.value == CaptureDrainReport(retained: 1))
        await background.value
        #expect(try Data(contentsOf: original) == bytes)
        #expect(await ingestion.drain() == CaptureDrainReport(retained: 1))
        await ingestion.resume()
        let entry = try #require(try await ingestion.recoveryEntries().first)
        #expect(try await ingestion.retry(entry) == CaptureDrainReport(ingested: 1))
        await ingestion.awaitPendingOperations()
        #expect(try await ingestion.recoveryEntries().isEmpty)
        #expect(await ingestion.drain() == CaptureDrainReport())
    }

}

private actor FetchCounter {
    private(set) var count = 0

    func called() {
        count += 1
    }
}

private actor CaptureFetchGate {
    private var entered = false
    private var cancelled = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func pause() async {
        entered = true
        await withTaskCancellationHandler {
            if !released { await withCheckedContinuation { continuation = $0 } }
        } onCancel: {
            Task { await self.markCancelled() }
        }
    }
    private func markCancelled() { cancelled = true }
    func waitUntilEntered() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !entered {
            guard ContinuousClock.now < deadline else { throw GateError.didNotEnter }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    func waitUntilCancelled() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !cancelled {
            guard ContinuousClock.now < deadline else { throw GateError.didNotCancel }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
    enum GateError: Error { case didNotEnter, didNotCancel }
    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}
