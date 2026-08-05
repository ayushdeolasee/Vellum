import XCTest
@testable import Vellum

// Unit tests for explicit-save semantics and snapshot-storage management
// (issue #29 Storage PR 0): annotating promotes a page to saved, TTL eviction
// only ever touches derived artifacts of never-kept pages, and the Storage-tab
// listing reports real artifact sizes. The whole web store is pointed at a
// scratch directory via `WebLibrary.storeDirOverride` (same seam pattern as
// `ScratchpadAttachmentStore.directoryOverride`).

@MainActor
final class WebLibraryStorageTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-weblibrary-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = tempDir
    }

    override func tearDown() async throws {
        WebLibrary.storeDirOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    /// Timestamp `months` months in the past, in the record writer's format.
    private func timestamp(monthsAgo months: Int) -> String {
        let date = Calendar.current.date(byAdding: .month, value: -months, to: .now) ?? .now
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    @discardableResult
    private func makeRecord(
        url: String, saved: Bool, openedMonthsAgo: Int?, annotated: Bool = false
    ) throws -> String {
        let key = WebLibrary.pageKey(url)
        var record = WebPageRecord(url: url)
        record.saved = saved
        record.savedAt = saved ? timestamp(monthsAgo: openedMonthsAgo ?? 0) : nil
        record.openedAt = openedMonthsAgo.map { timestamp(monthsAgo: $0) }
        if annotated {
            record.annotations = [Annotation(
                id: "a1", type: .highlight, pageNumber: 1, color: "#fde68a",
                content: "kept", positionData: nil,
                createdAt: timestamp(monthsAgo: 0), updatedAt: timestamp(monthsAgo: 0))]
        }
        try WebLibrary.saveRecord(record, at: WebLibrary.recordPath(forKey: key))
        return key
    }

    /// Write all three artifact kinds for a key: plain snapshot, managed
    /// archive, and an installed archive dir with one asset.
    private func makeArtifacts(forKey key: String, fill: Int = 100) throws {
        try Data(repeating: 0x61, count: fill)
            .write(to: WebLibrary.snapshotPath(forKey: key))
        try Data(repeating: 0x62, count: fill)
            .write(to: WebLibrary.managedArchivePath(forKey: key))
        let dir = WebLibrary.archiveDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x63, count: fill)
            .write(to: dir.appendingPathComponent("snapshot.html"))
    }

    private func hasArtifacts(forKey key: String) -> Bool {
        WebLibrary.hasLocalSnapshot(forKey: key)
    }

    private func cutoff(monthsAgo months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: -months, to: .now) ?? .now
    }

    private func coordinatedStorage(
        root: URL? = nil,
        container: FakeSyncedContainer = FakeSyncedContainer()
    ) async -> (WebLibraryStorage, StorageCoordinator, FakeSyncedContainer, WebStorageLayout) {
        let cloudRoot = root ?? tempDir.appendingPathComponent("cloud/Vellum", isDirectory: true)
        let coordinator = StorageCoordinator(
            storeDir: WebLibrary.storeDir,
            modeProvider: { .icloud },
            effectiveModeProvider: { .icloud },
            rootResolver: { cloudRoot },
            containerFactory: { container })
        await coordinator.start()
        let layout = WebStorageLayout.pretty(
            root: cloudRoot,
            recordsInRoot: true,
            localStoreDir: WebLibrary.storeDir)
        return (WebLibraryStorage(coordinator: coordinator), coordinator, container, layout)
    }

    private func archiveFixture(url: String = "https://example.com/archive") throws
        -> (ArchiveManifest, String, [CapturedAsset], Data, [Annotation]) {
        let pagesJson = try WebArchive.encodePagesJson([WebPageText(number: 1, text: "hello")])
        let asset = CapturedAsset(
            name: "a0.css",
            url: "https://example.com/a.css",
            contentType: "text/css",
            bytes: Data("body{}".utf8))
        let annotation = Annotation(
            id: "a1",
            type: .highlight,
            pageNumber: 1,
            color: "#fde68a",
            content: "kept",
            positionData: nil,
            createdAt: "2026-08-04T00:00:00Z",
            updatedAt: "2026-08-04T00:00:00Z")
        let html = "<html><body>Hello</body></html>"
        let manifest = WebArchive.buildManifest(
            url: url,
            title: "Archive",
            pageCount: 1,
            lastPage: nil,
            loadingPolicy: "live-first",
            snapshotHtml: html,
            pagesJson: pagesJson,
            assets: [asset],
            assetsSkipped: 0)
        return (manifest, html, [asset], pagesJson, [annotation])
    }

    // MARK: - Explicit save

    // Opening no longer saves; annotating does — and it must set savedAt so the
    // library sort has a timestamp.
    func testCreateAnnotationPromotesPageToSaved() async throws {
        let url = "https://example.com/article"
        let key = WebLibrary.pageKey(url)
        let recordPath = WebLibrary.recordPath(forKey: key)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: recordPath)
        XCTAssertFalse(WebLibrary.loadRecord(at: recordPath)?.saved ?? true)

        let io = WebDocumentIO(url: url, key: key)
        _ = try await io.createAnnotation(
            CreateAnnotationInput(type: .highlight, pageNumber: 1, content: "hi"),
            storedHighlightColor: "#fde68a")

        let record = WebLibrary.loadRecord(at: recordPath)
        XCTAssertEqual(record?.saved, true, "annotating must promote the page to saved")
        XCTAssertNotNil(record?.savedAt)
        XCTAssertEqual(record?.annotations.count, 1)
    }

    func testCreateAnnotationKeepsExistingSavedAt() async throws {
        let url = "https://example.com/already-saved"
        let key = try makeRecord(url: url, saved: true, openedMonthsAgo: 2)
        let recordPath = WebLibrary.recordPath(forKey: key)
        let originalSavedAt = WebLibrary.loadRecord(at: recordPath)?.savedAt

        let io = WebDocumentIO(url: url, key: key)
        _ = try await io.createAnnotation(
            CreateAnnotationInput(type: .note, pageNumber: 1, content: "note"),
            storedHighlightColor: "#fde68a")

        XCTAssertEqual(WebLibrary.loadRecord(at: recordPath)?.savedAt, originalSavedAt)
    }

    func testKeepOfflineStatusRequiresAnActualSnapshot() async throws {
        let url = "https://example.com/offline-status"
        let key = try makeRecord(url: url, saved: true, openedMonthsAgo: 1)
        let session = WebDocumentSession(
            url: url,
            record: try XCTUnwrap(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key))))

        let initiallyOffline = try await session.isSaved()
        XCTAssertFalse(initiallyOffline, "a Saved record without bytes is not offline")

        try makeArtifacts(forKey: key)
        let archivedOffline = try await session.isSaved()
        XCTAssertTrue(archivedOffline, "a Saved record with snapshot bytes is offline")

        try await session.setSaved(false)
        let removedOffline = try await session.isSaved()
        XCTAssertFalse(removedOffline, "removing the copy clears both membership and artifacts")
    }

    func testPinAnnotationPersistsAndSortsFirst() async throws {
        let url = "https://example.com/pin-me"
        let key = WebLibrary.pageKey(url)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: WebLibrary.recordPath(forKey: key))
        let io = WebDocumentIO(url: url, key: key)

        let first = try await io.createAnnotation(
            CreateAnnotationInput(type: .highlight, pageNumber: 1, content: "a"),
            storedHighlightColor: "#fde68a")
        let second = try await io.createAnnotation(
            CreateAnnotationInput(type: .note, pageNumber: 2, content: "b"),
            storedHighlightColor: "#fde68a")

        var list = await io.annotations(pageNumber: nil)
        XCTAssertEqual(list.map(\.id), [first.id, second.id])

        let updated = try await io.updateAnnotation(UpdateAnnotationInput(
            id: second.id, color: nil, content: nil, positionData: nil, isPinned: true))
        XCTAssertTrue(updated)

        list = await io.annotations(pageNumber: nil)
        XCTAssertEqual(list.map(\.id), [second.id, first.id])
        XCTAssertTrue(try XCTUnwrap(list.first).pinned)

        let record = try XCTUnwrap(WebLibrary.loadRecord(forKey: key))
        let stored = try XCTUnwrap(record.annotations.first { $0.id == second.id })
        XCTAssertEqual(stored.isPinned, true)

        // The decoded model round-trips through the same coding keys, so pin
        // the literal snake_case name other clients read.
        let data = try Data(contentsOf: WebLibrary.recordPath(forKey: key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawAnnotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        let raw = try XCTUnwrap(rawAnnotations.first { ($0["id"] as? String) == second.id })
        XCTAssertEqual(raw["is_pinned"] as? Bool, true)
    }

    /// The other half of the byte-compatibility contract: an unpinned record
    /// must not emit `is_pinned` at all, so sidecars written by this build stay
    /// readable byte-for-byte by pre-pin clients.
    func testUnpinnedWebAnnotationOmitsKey() async throws {
        let url = "https://example.com/no-pin"
        let key = WebLibrary.pageKey(url)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: WebLibrary.recordPath(forKey: key))
        let io = WebDocumentIO(url: url, key: key)
        let created = try await io.createAnnotation(
            CreateAnnotationInput(type: .highlight, pageNumber: 1, content: "a"),
            storedHighlightColor: "#fde68a")

        let data = try Data(contentsOf: WebLibrary.recordPath(forKey: key))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let rawAnnotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        let raw = try XCTUnwrap(rawAnnotations.first { ($0["id"] as? String) == created.id })
        XCTAssertNil(raw["is_pinned"], "unpinned records stay byte-compatible with pre-pin sidecars")
    }

    // MARK: - TTL eviction

    func testEvictionRemovesOnlyStaleUnsavedArtifacts() async throws {
        let staleUnsaved = try makeRecord(
            url: "https://example.com/stale", saved: false, openedMonthsAgo: 8)
        let staleSaved = try makeRecord(
            url: "https://example.com/saved", saved: true, openedMonthsAgo: 8)
        let staleAnnotated = try makeRecord(
            url: "https://example.com/annotated", saved: false, openedMonthsAgo: 8,
            annotated: true)
        let freshUnsaved = try makeRecord(
            url: "https://example.com/fresh", saved: false, openedMonthsAgo: 1)
        let staleOpenTab = try makeRecord(
            url: "https://example.com/open-tab", saved: false, openedMonthsAgo: 8)
        let noTimestamp = try makeRecord(
            url: "https://example.com/no-stamp", saved: false, openedMonthsAgo: nil)
        for key in [staleUnsaved, staleSaved, staleAnnotated, freshUnsaved, staleOpenTab, noTimestamp] {
            try makeArtifacts(forKey: key)
        }

        await WebLibrary.evictStaleUnsavedSnapshots(
            olderThan: cutoff(monthsAgo: 6),
            excludingUrls: ["https://example.com/open-tab"])

        XCTAssertFalse(hasArtifacts(forKey: staleUnsaved), "stale + never kept → evicted")
        XCTAssertTrue(hasArtifacts(forKey: staleSaved), "saved pages are never evicted")
        XCTAssertTrue(hasArtifacts(forKey: staleAnnotated), "annotated pages are never evicted")
        XCTAssertTrue(hasArtifacts(forKey: freshUnsaved), "recently opened pages survive")
        XCTAssertTrue(hasArtifacts(forKey: staleOpenTab), "open tabs are excluded")
        XCTAssertTrue(hasArtifacts(forKey: noTimestamp), "no parseable timestamp → never evict")

        // Eviction only touches derived artifacts — the record (reading state)
        // must survive for every page, including the evicted one.
        XCTAssertNotNil(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: staleUnsaved)))
    }

    // MARK: - Storage listing

    func testListSnapshotStorageReportsArtifactSizesLargestFirst() throws {
        let small = try makeRecord(
            url: "https://example.com/small", saved: false, openedMonthsAgo: 1)
        try makeArtifacts(forKey: small, fill: 10)
        let big = try makeRecord(
            url: "https://example.com/big", saved: true, openedMonthsAgo: 1)
        try makeArtifacts(forKey: big, fill: 1000)
        // Record with no artifacts must not appear at all.
        try makeRecord(url: "https://example.com/bare", saved: false, openedMonthsAgo: 1)

        let entries = WebLibrary.listSnapshotStorage()
        XCTAssertEqual(entries.map(\.key), [big, small], "sorted by size descending")
        // Three artifacts of `fill` bytes each (snapshot + archive + dir asset).
        XCTAssertEqual(entries[0].byteSize, 3000)
        XCTAssertEqual(entries[1].byteSize, 30)
        XCTAssertEqual(entries[0].saved, true)
        XCTAssertEqual(entries[1].saved, false)
        XCTAssertNotNil(entries[0].lastOpened)
    }

    func testRemoveAllSnapshotArtifactsKeepsRecords() throws {
        let a = try makeRecord(url: "https://example.com/a", saved: true, openedMonthsAgo: 1)
        let b = try makeRecord(url: "https://example.com/b", saved: false, openedMonthsAgo: 1)
        try makeArtifacts(forKey: a)
        try makeArtifacts(forKey: b)

        WebLibrary.removeAllSnapshotArtifacts()

        XCTAssertFalse(hasArtifacts(forKey: a))
        XCTAssertFalse(hasArtifacts(forKey: b))
        XCTAssertTrue(WebLibrary.listSnapshotStorage().isEmpty)
        XCTAssertNotNil(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: a)))
        XCTAssertNotNil(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: b)))
        // The saved flag is untouched — only bytes were removed.
        XCTAssertEqual(WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: a))?.saved, true)
    }

    // MARK: - Timestamp parsing

    func testParseRfc3339AcceptsWriterAndLegacyFormats() {
        // Our own writer (6-digit fraction, +00:00 offset).
        XCTAssertNotNil(WebLibrary.parseRfc3339("2026-07-14T10:20:30.123456+00:00"))
        // ISO8601 with milliseconds and Z.
        XCTAssertNotNil(WebLibrary.parseRfc3339("2026-07-14T10:20:30.123Z"))
        // ISO8601 without fraction.
        XCTAssertNotNil(WebLibrary.parseRfc3339("2026-07-14T10:20:30Z"))
        XCTAssertNil(WebLibrary.parseRfc3339(nil))
        XCTAssertNil(WebLibrary.parseRfc3339(""))
        XCTAssertNil(WebLibrary.parseRfc3339("not a date"))
    }

    // MARK: - C4a coordinated storage

    func testGatewayDirectRecordUsesLegacyFormatAndAtomicPath() async throws {
        let url = "https://example.com/direct-byte-compat"
        let key = WebLibrary.pageKey(url)
        let expectedTitle: String? = "Direct"
        let expectedSaved = true
        let expectedSavedAt: String? = "2026-08-04T00:00:00Z"

        let storage = WebLibraryStorage()
        try await storage.mutateRecord(url: url, key: key) { record in
            record.title = expectedTitle
            record.saved = expectedSaved
            record.savedAt = expectedSavedAt
        }

        let written = WebLibrary.recordPath(forKey: key)
        let writtenData = try Data(contentsOf: written)
        let record = try JSONDecoder().decode(WebPageRecord.self, from: writtenData)
        XCTAssertEqual(record.title, expectedTitle)
        XCTAssertEqual(record.saved, expectedSaved)
        XCTAssertEqual(record.savedAt, expectedSavedAt)
        let json = String(decoding: writtenData, as: UTF8.self)
        XCTAssertTrue(json.contains("https://example.com/direct-byte-compat"))
        XCTAssertTrue(json.contains("\n  \""), "direct writes keep the legacy pretty-printed JSON format")
        XCTAssertFalse(FileManager.default.fileExists(atPath: written.appendingPathExtension("tmp").path))
    }

    func testCoordinatedMutationDoesNotOverwriteUnreadableRecord() async throws {
        let (storage, _, container, layout) = await coordinatedStorage()
        let url = "https://example.com/corrupt"
        let key = WebLibrary.pageKey(url)
        let recordURL = layout.recordsDir.appendingPathComponent("\(key).json")
        let corrupt = Data("not-json".utf8)
        container.seed(recordURL, data: corrupt)

        do {
            try await storage.mutateRecord(url: url, key: key) { $0.saved = true }
            XCTFail("expected corrupt synced record to refuse replacement")
        } catch {
            XCTAssertEqual(container.peek(recordURL), corrupt)
            XCTAssertEqual(container.coordinatedWriteCount, 0)
        }
    }

    func testCoordinatedRecordMutationUsesContainerOnly() async throws {
        let (storage, _, container, layout) = await coordinatedStorage()
        let url = "https://example.com/coordinated"
        let key = WebLibrary.pageKey(url)

        try await storage.mutateRecord(url: url, key: key) { record in
            record.saved = true
            record.title = "Coordinated"
        }

        let recordURL = layout.recordsDir.appendingPathComponent("\(key).json")
        XCTAssertNil(try? Data(contentsOf: recordURL), "iCloud writes must not hit raw filesystem paths")
        XCTAssertNotNil(container.peek(recordURL))
        XCTAssertEqual(container.coordinatedWriteCount, 1)
        XCTAssertEqual(container.forReplacingWriteCount, 1)
        XCTAssertEqual(container.directoryEnumerationCount, 0)
        XCTAssertEqual(container.existenceCheckCount, 0)
    }

    func testCoordinatedListIsCurrentOnlyAndDoesNotMaterialize() async throws {
        let (storage, _, container, layout) = await coordinatedStorage()
        let currentURL = "https://example.com/current"
        let staleURL = "https://example.com/stale"
        let legacyURL = "https://example.com/legacy"
        for (url, readiness) in [(currentURL, ItemReadiness.current), (staleURL, .downloaded)] {
            let key = WebLibrary.pageKey(url)
            var record = WebPageRecord(url: url)
            record.saved = true
            record.savedAt = url
            let data = try WebLibrary.jsonEncoderPretty.encode(record)
            container.seed(
                layout.recordsDir.appendingPathComponent("\(key).json"),
                data: data,
                readiness: readiness)
        }
        var legacy = WebPageRecord(url: legacyURL)
        legacy.saved = true
        legacy.savedAt = legacyURL
        try WebLibrary.saveRecord(
            legacy,
            at: WebLibrary.storeDir.appendingPathComponent(
                "\(WebLibrary.pageKey(legacyURL)).json"))
        container.seed(
            layout.indexPath!,
            data: try WebLibrary.jsonEncoderPretty.encode(WebArchiveIndex.Contents()),
            readiness: .downloaded)

        let saved = try await storage.listSaved()

        XCTAssertEqual(Set(saved.map(\.url)), Set([currentURL, legacyURL]))
        XCTAssertGreaterThan(container.metadataQueryCount, 0)
        XCTAssertEqual(container.materializationCount, 0)
    }

    func testExplicitRecordLoadMaterializesDownloadedItem() async throws {
        let (storage, _, container, layout) = await coordinatedStorage()
        let url = "https://example.com/download"
        let key = WebLibrary.pageKey(url)
        var record = WebPageRecord(url: url)
        record.saved = true
        container.seed(
            layout.recordsDir.appendingPathComponent("\(key).json"),
            data: try WebLibrary.jsonEncoderPretty.encode(record),
            readiness: .downloaded)

        let loaded = await storage.loadRecord(forKey: key)

        XCTAssertEqual(loaded?.url, url)
        XCTAssertEqual(container.materializationCount, 1)
    }

    func testCoordinatedIndexCollisionUsesMetadataList() async throws {
        let (storage, _, container, layout) = await coordinatedStorage()
        let url = "https://example.com/collision"
        let key = WebLibrary.pageKey(url)
        var record = WebPageRecord(url: url)
        record.title = "Same Title"
        container.seed(
            layout.recordsDir.appendingPathComponent("\(key).json"),
            data: try WebLibrary.jsonEncoderPretty.encode(record))
        container.seed(
            layout.archivesDir.appendingPathComponent("Same Title.vellumweb"),
            data: Data("occupied".utf8))

        let name = try await storage.reserveManagedArchiveName(forKey: key)

        XCTAssertEqual(name, "Same Title 2.vellumweb")
        XCTAssertGreaterThanOrEqual(container.metadataQueryCount, 1)
        XCTAssertEqual(container.directoryEnumerationCount, 0)
    }

    func testCoordinatedManagedArchiveBytesMatchEncoder() async throws {
        let (storage, _, container, layout) = await coordinatedStorage()
        let url = "https://example.com/archive"
        let key = WebLibrary.pageKey(url)
        var record = WebPageRecord(url: url)
        record.title = "Archive"
        container.seed(
            layout.recordsDir.appendingPathComponent("\(key).json"),
            data: try WebLibrary.jsonEncoderPretty.encode(record))
        let (manifest, html, assets, pagesJson, annotations) = try archiveFixture(url: url)
        let written = try await storage.writeManagedArchive(
            forKey: key,
            manifest: manifest,
            snapshotHtml: html,
            assets: assets,
            pagesJson: pagesJson,
            annotations: annotations)

        let archiveURL = layout.archivesDir.appendingPathComponent("Archive.vellumweb")
        let stored = try XCTUnwrap(container.peek(archiveURL))
        XCTAssertEqual(written.bytes, stored.count)
        XCTAssertGreaterThan(stored.count, 0)
    }

    func testConcurrentCoordinatedMutationsDoNotLoseAnnotations() async throws {
        let (storage, _, _, _) = await coordinatedStorage()
        let url = "https://example.com/race"
        let key = WebLibrary.pageKey(url)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in ["a", "b", "c", "d"] {
                group.addTask {
                    try await storage.mutateRecord(url: url, key: key) { record in
                        record.annotations.append(Annotation(
                            id: id,
                            type: .note,
                            pageNumber: 1,
                            color: "#fde68a",
                            content: id,
                            positionData: nil,
                            createdAt: "2026-08-04T00:00:00Z",
                            updatedAt: "2026-08-04T00:00:00Z"))
                    }
                }
            }
            try await group.waitForAll()
        }

        let record = await storage.loadRecord(forKey: key)
        XCTAssertEqual(Set(record?.annotations.map(\.id) ?? []), Set(["a", "b", "c", "d"]))
    }
}
