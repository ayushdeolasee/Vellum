#if os(iOS)
import PencilKit
import WebKit
import XCTest
@testable import Vellum

// Web-ink persistence (WEB-INK-PLAN decisions 5, 6, 7): the `<key>.ink.json`
// sidecar record round-trips, strokes are stored in layout CSS px and are
// invariant across toolbar zoom changes, writes are debounced but
// always durable after a flush, and the first stroke promotes the page into
// the saved library. The whole web store is pointed at a scratch directory via
// `WebLibrary.storeDirOverride` (same seam as `WebLibraryStorageTests`).

@MainActor
final class WebInkPersistenceTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-webink-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        WebLibrary.storeDirOverride = tempDir
    }

    override func tearDown() async throws {
        WebLibrary.storeDirOverride = nil
        WebLibrary.layoutOverride = nil
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Helpers

    /// A recognizable one-stroke drawing in document space.
    private func sampleDrawing(offsetX: CGFloat = 100, offsetY: CGFloat = 200) -> PKDrawing {
        var points: [PKStrokePoint] = []
        for i in 0..<10 {
            let point = PKStrokePoint(
                location: CGPoint(x: offsetX + CGFloat(i * 20), y: offsetY + CGFloat((i % 3) * 5)),
                timeOffset: TimeInterval(i) * 0.01,
                size: CGSize(width: 4, height: 4),
                opacity: 1,
                force: 1,
                azimuth: 0,
                altitude: CGFloat.pi / 2)
            points.append(point)
        }
        let path = PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0))
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .systemIndigo), path: path)])
    }

    private let layout = WebInkRecord.Layout(contentWidth: 980, docHeight: 42000)

    // MARK: - Record round-trip + wire format

    func testRecordRoundTripAndWireFormat() throws {
        let drawing = sampleDrawing()
        let record = WebInkRecord.snapshot(
            of: drawing, url: "https://example.com/article", layout: layout)

        XCTAssertEqual(record.version, WebInkRecord.currentVersion)
        XCTAssertEqual(record.clusters.count, 1, "MVP writes exactly one cluster")
        XCTAssertNil(record.clusters[0].anchor, "MVP anchor is null")
        XCTAssertFalse(record.updatedAt.isEmpty)

        // Cluster drawings are cluster-local: translated so bounds.origin is (0,0).
        let local = try PKDrawing(data: record.clusters[0].drawing)
        XCTAssertEqual(local.bounds.minX, 0, accuracy: 0.5)
        XCTAssertEqual(local.bounds.minY, 0, accuracy: 0.5)
        XCTAssertEqual(record.clusters[0].bounds.x, drawing.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(record.clusters[0].bounds.y, drawing.bounds.minY, accuracy: 0.5)

        // Wire format: snake_case keys, base64 drawing, explicit null anchor.
        let data = try JSONEncoder().encode(record)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, WebInkRecord.currentVersion)
        XCTAssertEqual(object["url"] as? String, "https://example.com/article")
        XCTAssertNotNil(object["updated_at"])
        let layoutJson = try XCTUnwrap(object["layout"] as? [String: Any])
        XCTAssertEqual(layoutJson["content_width"] as? Double, 980)
        XCTAssertEqual(layoutJson["doc_height"] as? Double, 42000)
        let clusters = try XCTUnwrap(object["clusters"] as? [[String: Any]])
        XCTAssertEqual(clusters.count, 1)
        XCTAssertTrue(clusters[0]["drawing"] is String, "PKDrawing is base64 in JSON")
        XCTAssertTrue(clusters[0]["anchor"] is NSNull, "anchor serializes as an explicit null")
        XCTAssertNotNil(clusters[0]["bounds"] as? [String: Any])

        // Decode → merge restores the original document-space drawing.
        let decoded = try JSONDecoder().decode(WebInkRecord.self, from: data)
        XCTAssertEqual(decoded, record)
        let merged = decoded.mergedDrawing()
        XCTAssertEqual(merged.strokes.count, drawing.strokes.count)
        XCTAssertEqual(merged.bounds.minX, drawing.bounds.minX, accuracy: 0.5)
        XCTAssertEqual(merged.bounds.minY, drawing.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(merged.bounds.width, drawing.bounds.width, accuracy: 0.5)
        XCTAssertEqual(merged.bounds.height, drawing.bounds.height, accuracy: 0.5)
    }

    func testEmptyDrawingSnapshotsToZeroClusters() {
        let record = WebInkRecord.snapshot(
            of: PKDrawing(), url: "https://example.com/blank", layout: layout)
        XCTAssertTrue(record.clusters.isEmpty)
        XCTAssertTrue(record.mergedDrawing().strokes.isEmpty)
    }

    // MARK: - Zoom invariance (decision 3, viewScale model)

    /// Canvas space is layout CSS px at every toolbar zoom — under viewScale
    /// the web scroll view's `zoomScale` carries toolbar zoom × pinch and the
    /// overlay applies it as a view transform only. So `zoomChanged` must
    /// never mutate the live drawing, and the persisted record must be
    /// byte-identical across zoom changes. (Regression guard: the pageZoom-era
    /// `rescaleDrawing(newZoom/oldZoom)` double-scaled ink against the
    /// transform and scrambled positions.)
    func testZoomChangeNeverRescalesStrokesOrPersistedRecord() throws {
        let base = sampleDrawing()
        let controller = WebInkController_iOS()
        let webView = WKWebView()
        let overlay = controller.attachOverlay(to: webView)
        defer { controller.detachOverlay() }
        let capture = CapturingInkPersister()
        controller.persistence = capture

        overlay.setDrawing(base)
        controller.drawingChanged(base)
        let before = try XCTUnwrap(capture.captured.last)

        controller.zoomChanged(1.5)
        controller.zoomChanged(0.75)

        XCTAssertEqual(
            overlay.canvas.drawing.bounds.minX, base.bounds.minX, accuracy: 0.01)
        XCTAssertEqual(
            overlay.canvas.drawing.bounds.width, base.bounds.width, accuracy: 0.01)

        controller.drawingChanged(overlay.canvas.drawing)
        let after = try XCTUnwrap(capture.captured.last)
        let recordBefore = WebInkRecord.snapshot(
            of: before.drawing, url: "https://example.com/zoom", layout: before.layout)
        let recordAfter = WebInkRecord.snapshot(
            of: after.drawing, url: "https://example.com/zoom", layout: after.layout)
        XCTAssertEqual(recordBefore.clusters.count, recordAfter.clusters.count)
        XCTAssertEqual(
            recordAfter.clusters[0].bounds.x, recordBefore.clusters[0].bounds.x, accuracy: 0.01)
        XCTAssertEqual(
            recordAfter.clusters[0].bounds.y, recordBefore.clusters[0].bounds.y, accuracy: 0.01)
        XCTAssertEqual(
            recordAfter.clusters[0].bounds.w, recordBefore.clusters[0].bounds.w, accuracy: 0.01)
    }

    // MARK: - Debounce / flush (decision 6)

    func testWriteIsDebouncedAndFlushMakesItDurable() async throws {
        let url = "https://example.com/inked"
        let key = WebLibrary.pageKey(url)
        let persister = WebInkPersister(url: url)

        persister.drawingChanged(sampleDrawing(), layout: layout)
        XCTAssertNil(
            WebInkStore.loadRecord(forKey: key),
            "the write is debounced — nothing may reach disk synchronously")

        await persister.flushPendingInkAndWait()

        let record = try XCTUnwrap(WebInkStore.loadRecord(forKey: key))
        XCTAssertEqual(record.url, url)
        XCTAssertEqual(record.clusters.count, 1)
        XCTAssertEqual(record.mergedDrawing().strokes.count, 1)
        XCTAssertEqual(record.layout, layout)
    }

    func testFlushWritesTheLatestCoalescedEdit() async throws {
        let url = "https://example.com/coalesced"
        let key = WebLibrary.pageKey(url)
        let persister = WebInkPersister(url: url)

        var two = sampleDrawing()
        two = two.appending(sampleDrawing(offsetX: 150, offsetY: 600))

        persister.drawingChanged(sampleDrawing(), layout: layout)
        persister.drawingChanged(two, layout: layout)
        await persister.flushPendingInkAndWait()

        let record = try XCTUnwrap(WebInkStore.loadRecord(forKey: key))
        XCTAssertEqual(record.mergedDrawing().strokes.count, 2, "the newest edit wins")
    }

    func testDebouncedWriteLandsOnItsOwn() async throws {
        let url = "https://example.com/debounced"
        let key = WebLibrary.pageKey(url)
        let persister = WebInkPersister(url: url)
        persister.debounceInterval = .milliseconds(20)

        persister.drawingChanged(sampleDrawing(), layout: layout)

        for _ in 0..<200 where WebInkStore.loadRecord(forKey: key) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(
            WebInkStore.loadRecord(forKey: key),
            "the debounced write must land without an explicit flush")
    }

    /// A failed release flush must keep its persister alive after the runtime
    /// drops it. One barrier reports failure without spinning; a later barrier
    /// retries the retained work after storage becomes writable.
    func testFailedReleaseFlushIsRetainedForNextBarrier() async throws {
        let url = "https://example.com/retry-failed-web-ink"
        let blockedStore = tempDir.appendingPathComponent("not-a-directory")
        try Data("blocked".utf8).write(to: blockedStore)
        WebLibrary.storeDirOverride = blockedStore

        let registry = TabTeardownRegistry()
        weak var retainedPersister: WebInkPersister?
        do {
            let persister = WebInkPersister(url: url)
            retainedPersister = persister
            persister.drawingChanged(sampleDrawing(), layout: layout)
            registry.registerReleaseFlush { [persister] in
                await persister.flushPendingInkAndWait()
            }
        }

        let failed = await registry.awaitAll()
        XCTAssertFalse(failed)
        XCTAssertFalse(registry.isEmpty)
        XCTAssertNotNil(retainedPersister, "the failed persister must remain retryable")

        WebLibrary.storeDirOverride = tempDir
        let retried = await registry.awaitAll()
        XCTAssertTrue(retried)
        XCTAssertTrue(registry.isEmpty)

        let record = try XCTUnwrap(
            WebInkStore.loadRecord(forKey: WebLibrary.pageKey(url)))
        XCTAssertEqual(record.mergedDrawing().strokes.count, 1)
    }

    /// A flush can suspend in I/O while PencilKit reports a newer drawing. The
    /// newer debounce must be cancelled and joined before the next drain; a
    /// completed debounce handle with no pending record must never make the
    /// main actor loop synchronously.
    func testEditDuringFlushDrainsNewestDrawingWithoutSpinning() async {
        let writer = PausingInkWriter()
        let persister = WebInkPersister(
            url: "https://example.com/edit-during-flush",
            writer: { record, _ in await writer.write(record) })
        let first = sampleDrawing()
        let newest = first.appending(sampleDrawing(offsetX: 350, offsetY: 900))

        persister.drawingChanged(first, layout: layout)
        let flush = Task { await persister.flushPendingInkAndWait() }
        await writer.waitUntilFirstWriteStarts()
        persister.drawingChanged(newest, layout: layout)
        await writer.resumeFirstWrite()

        let flushSucceeded = await flush.value
        XCTAssertTrue(flushSucceeded)
        let writes = await writer.records
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.last?.mergedDrawing().strokes.count, 2)
    }

    // MARK: - First stroke promotes to saved (decision 7)

    func testFirstStrokePromotesPageToSaved() async throws {
        let url = "https://example.com/promote"
        let key = WebLibrary.pageKey(url)
        let recordPath = WebLibrary.recordPath(forKey: key)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: recordPath)
        XCTAssertFalse(WebLibrary.loadRecord(at: recordPath)?.saved ?? true)

        let persister = WebInkPersister(url: url)
        persister.drawingChanged(sampleDrawing(), layout: layout)
        await persister.flushPendingInkAndWait()

        let record = try XCTUnwrap(WebLibrary.loadRecord(at: recordPath))
        XCTAssertTrue(record.saved, "inking must promote the page to saved")
        XCTAssertNotNil(record.savedAt)
    }

    func testPromotionKeepsExistingSavedAt() async throws {
        let url = "https://example.com/already-saved"
        let key = WebLibrary.pageKey(url)
        let recordPath = WebLibrary.recordPath(forKey: key)
        var existing = WebPageRecord(url: url)
        existing.saved = true
        existing.savedAt = "2026-01-01T00:00:00.000000+00:00"
        try WebLibrary.saveRecord(existing, at: recordPath)

        let persister = WebInkPersister(url: url)
        persister.drawingChanged(sampleDrawing(), layout: layout)
        await persister.flushPendingInkAndWait()

        XCTAssertEqual(
            WebLibrary.loadRecord(at: recordPath)?.savedAt,
            "2026-01-01T00:00:00.000000+00:00")
    }

    func testEmptyDrawingDoesNotPromote() async throws {
        let url = "https://example.com/erased"
        let key = WebLibrary.pageKey(url)
        let recordPath = WebLibrary.recordPath(forKey: key)
        try WebLibrary.saveRecord(WebPageRecord(url: url), at: recordPath)

        let persister = WebInkPersister(url: url)
        persister.drawingChanged(PKDrawing(), layout: layout)
        await persister.flushPendingInkAndWait()

        XCTAssertEqual(WebLibrary.loadRecord(at: recordPath)?.saved, false)
        // The empty record still writes — erasing everything durably clears the sidecar.
        XCTAssertEqual(WebInkStore.loadRecord(forKey: key)?.clusters.isEmpty, true)
    }

    // MARK: - Storage-location path resolution

    func testInkPathFollowsActiveLayoutWithLegacyReadFallback() throws {
        let key = "abc123"
        // Local mode: next to the record in the store dir.
        XCTAssertEqual(
            WebInkStore.inkPath(forKey: key).path,
            tempDir.appendingPathComponent("\(key).ink.json").path)

        // Pretty (iCloud-shaped) layout: sidecar follows the records dir.
        let root = tempDir.appendingPathComponent("cloud-root", isDirectory: true)
        WebLibrary.layoutOverride = .pretty(root: root, recordsInRoot: true, localStoreDir: tempDir)
        defer { WebLibrary.layoutOverride = nil }
        let expected = root
            .appendingPathComponent(".vellum", isDirectory: true)
            .appendingPathComponent("records", isDirectory: true)
            .appendingPathComponent("\(key).ink.json")
        XCTAssertEqual(WebInkStore.inkPath(forKey: key).path, expected.path)

        // A legacy local sidecar the migration sweep has not moved yet is
        // still found (read fallback, mirroring candidateRecordPaths).
        let url = "https://example.com/legacy"
        let legacyKey = WebLibrary.pageKey(url)
        let legacy = WebInkRecord.snapshot(of: sampleDrawing(), url: url, layout: layout)
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: tempDir.appendingPathComponent("\(legacyKey).ink.json"))
        XCTAssertEqual(WebInkStore.loadRecord(forKey: legacyKey), legacy)
    }

    /// Relocation carries the newer whole snapshot. An older source containing
    /// a stroke may not union that stroke back into a newer cleared destination.
    func testRelocationKeepsNewerDeletionSnapshotAuthoritative() throws {
        let source = tempDir.appendingPathComponent("source.ink.json")
        let destination = tempDir.appendingPathComponent("destination.ink.json")
        var older = WebInkRecord.snapshot(
            of: sampleDrawing(), url: "https://example.com/relocated", layout: layout)
        older.updatedAt = "2026-01-01T00:00:00.000000+00:00"
        var newerClear = WebInkRecord.snapshot(
            of: PKDrawing(), url: older.url, layout: layout)
        newerClear.updatedAt = "2026-02-01T00:00:00.000000+00:00"
        try WebInkStore.writeRecord(older, to: source)
        try WebInkStore.writeRecord(newerClear, to: destination)

        XCTAssertTrue(WebInkStore.adoptInkFile(from: source, to: destination))
        XCTAssertEqual(WebInkStore.loadRecord(at: destination), newerClear)
        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
    }

    // MARK: - .vellumweb archive integration (Phase 4)

    private func archiveManifest(url: String, pagesJson: Data) -> ArchiveManifest {
        WebArchive.buildManifest(
            url: url, title: "Archived Ink", pageCount: 1, lastPage: 1,
            loadingPolicy: "live-first", snapshotHtml: archiveHtml,
            pagesJson: pagesJson, assets: [], assetsSkipped: 0)
    }

    private let archiveHtml = "<html><body>archived</body></html>"

    /// An `ink.json` entry round-trips through a `.vellumweb` archive with its
    /// own manifest sha256, and the format version does NOT bump — ink is
    /// additive, so older readers skip it rather than hard-failing.
    func testArchiveEmbedsAndImportsInk() throws {
        let url = "https://example.com/archived-ink"
        let record = WebInkRecord.snapshot(of: sampleDrawing(), url: url, layout: layout)
        let inkJson = try WebLibrary.jsonEncoderPretty.encode(record)
        let pagesJson = try WebArchive.encodePagesJson([WebPageText(number: 1, text: "hello world")])
        let dest = tempDir.appendingPathComponent("with-ink.vellumweb")

        _ = try WebArchive.writeArchive(
            to: dest, manifest: archiveManifest(url: url, pagesJson: pagesJson),
            snapshotHtml: archiveHtml, assets: [], pagesJson: pagesJson,
            annotations: [], inkJson: inkJson)

        let imported = try WebArchive.readArchive(at: dest)
        XCTAssertEqual(
            imported.manifest.version, WebArchive.formatVersion,
            "ink is additive — the format version must stay the same")
        XCTAssertNotNil(imported.manifest.hashes.ink, "the manifest carries the ink sha256")
        let importedInk = try XCTUnwrap(imported.inkRecord)
        XCTAssertEqual(importedInk, record)
        XCTAssertEqual(importedInk.mergedDrawing().strokes.count, 1)
    }

    /// An archive written without ink imports a nil ink record and no manifest
    /// ink hash — the read path is clean for every pre-ink archive.
    func testArchiveWithoutInkImportsNil() throws {
        let url = "https://example.com/no-ink"
        let pagesJson = try WebArchive.encodePagesJson([WebPageText(number: 1, text: "plain")])
        let dest = tempDir.appendingPathComponent("no-ink.vellumweb")

        _ = try WebArchive.writeArchive(
            to: dest, manifest: archiveManifest(url: url, pagesJson: pagesJson),
            snapshotHtml: archiveHtml, assets: [], pagesJson: pagesJson, annotations: [])

        let imported = try WebArchive.readArchive(at: dest)
        XCTAssertNil(imported.inkRecord)
        XCTAssertNil(imported.manifest.hashes.ink)
    }

    /// `mergeInk` unions clusters by id and lets the record with the newer
    /// `updated_at` win same-id collisions, carrying its layout + timestamp.
    func testMergeInkPrefersNewerRecordByClusterId() throws {
        func cluster(_ id: String, byte: UInt8) -> WebInkRecord.Cluster {
            WebInkRecord.Cluster(
                id: id, drawing: Data([byte]),
                bounds: WebInkRecord.Bounds(CGRect(x: 0, y: 0, width: 10, height: 10)),
                anchor: nil)
        }
        let older = WebInkRecord(
            version: WebInkRecord.currentVersion - 1,
            url: "https://example.com/m", updatedAt: "2026-01-01T00:00:00.000000+00:00",
            layout: WebInkRecord.Layout(contentWidth: 800, docHeight: 1000),
            clusters: [cluster("a", byte: 1), cluster("b", byte: 2)])
        let newer = WebInkRecord(
            version: WebInkRecord.currentVersion,
            url: "https://example.com/m", updatedAt: "2026-02-01T00:00:00.000000+00:00",
            layout: WebInkRecord.Layout(contentWidth: 980, docHeight: 2000),
            clusters: [cluster("a", byte: 9), cluster("c", byte: 3)])

        var base: WebInkRecord? = older
        let changed = WebArchive.mergeInk(&base, incoming: newer)
        let merged = try XCTUnwrap(base)
        XCTAssertEqual(changed, 2, "cluster a replaced, cluster c added")
        XCTAssertEqual(Set(merged.clusters.map(\.id)), ["a", "b", "c"])
        XCTAssertEqual(
            merged.clusters.first(where: { $0.id == "a" })?.drawing, Data([9]),
            "the newer record's cluster a wins")
        XCTAssertEqual(merged.updatedAt, newer.updatedAt)
        XCTAssertEqual(merged.layout, newer.layout, "the newer layout fingerprint carries in")
        XCTAssertEqual(
            merged.version, WebInkRecord.currentVersion - 1,
            "retained legacy clusters keep the record eligible for anchor recapture")

        // Symmetric: an older incoming record never overwrites newer clusters.
        var base2: WebInkRecord? = newer
        let changed2 = WebArchive.mergeInk(&base2, incoming: older)
        XCTAssertEqual(base2?.updatedAt, newer.updatedAt)
        XCTAssertEqual(
            base2?.clusters.first(where: { $0.id == "a" })?.drawing, Data([9]),
            "the newer cluster a is retained")
        XCTAssertEqual(changed2, 1, "only the brand-new cluster b is added")
        XCTAssertEqual(
            base2?.version, WebInkRecord.currentVersion - 1,
            "adding a legacy cluster downgrades capture guarantees until the next snapshot")
    }

    /// Regression for the non-stable-id bug: two INDEPENDENT snapshots of the
    /// same page's ink (the raced-copy / re-import scenario) must land on the
    /// same cluster ids, so `mergeInk`'s newer-wins replaces the shared cluster
    /// instead of blindly appending a duplicate. A per-save random UUID made
    /// the id sets disjoint and doubled the ink on every merge.
    func testSnapshotClusterIdsAreStableAcrossIndependentWrites() throws {
        let drawing = sampleDrawing()
        // Same drawing, snapshotted twice (as two separate saves would).
        let first = WebInkRecord.snapshot(
            of: drawing, url: "https://example.com/stable", layout: layout)
        let second = WebInkRecord.snapshot(
            of: drawing, url: "https://example.com/stable", layout: layout)
        XCTAssertEqual(first.clusters.count, 1)
        XCTAssertEqual(
            first.clusters.map(\.id), second.clusters.map(\.id),
            "the same geometry must produce the same cluster id across independent saves")

        // Merging the second (newer) into the first must REPLACE, not append.
        var merged: WebInkRecord? = first
        WebArchive.mergeInk(&merged, incoming: second)
        XCTAssertEqual(
            merged?.clusters.count, 1,
            "the same-id cluster is replaced, never doubled")

        // An anchored cluster keys off its text span, stable even after reflow
        // moves its bounds.
        let anchor = { (rect: CGRect) -> WebInkRecord.Anchor in
            WebInkRecord.Anchor(
                startOffset: 4200, endOffset: 4260, text: "hi",
                prefix: nil, suffix: nil, rect: WebInkRecord.Bounds(rect))
        }
        let atY200 = WebInkRecord.snapshot(
            of: sampleDrawing(offsetY: 200), url: "https://example.com/anchored",
            layout: layout, anchorFor: { anchor($0) })
        let atY900 = WebInkRecord.snapshot(
            of: sampleDrawing(offsetY: 900), url: "https://example.com/anchored",
            layout: layout, anchorFor: { anchor($0) })
        XCTAssertEqual(
            atY200.clusters.map(\.id), atY900.clusters.map(\.id),
            "an anchored cluster's id survives the paragraph moving under reflow")
    }

    /// The same stroke first saved before anchor capture and later saved with a
    /// text anchor has different cluster metadata/ids. Archive import must
    /// still de-duplicate by stroke identity rather than append both clusters.
    func testArchiveMergeDeduplicatesAcrossClusterIdChange() throws {
        let drawing = sampleDrawing()
        let unanchored = WebInkRecord.snapshot(
            of: drawing, url: "https://example.com/anchor-transition", layout: layout)
        let anchored = WebInkRecord.snapshot(
            of: drawing, url: "https://example.com/anchor-transition", layout: layout,
            anchorFor: { rect in
                WebInkRecord.Anchor(
                    startOffset: 12, endOffset: 24, text: "anchor",
                    prefix: nil, suffix: nil, rect: WebInkRecord.Bounds(rect))
            })
        XCTAssertNotEqual(unanchored.clusters.map(\.id), anchored.clusters.map(\.id))

        var merged: WebInkRecord? = unanchored
        WebArchive.mergeInk(&merged, incoming: anchored)
        let drawingAfterMerge = try XCTUnwrap(merged).validatedMergedDrawing()
        XCTAssertEqual(drawingAfterMerge.strokes.count, drawing.strokes.count)
    }

    func testMergeInkIntoNilAdoptsIncoming() {
        let incoming = WebInkRecord.snapshot(
            of: sampleDrawing(), url: "https://example.com/nil", layout: layout)
        var base: WebInkRecord?
        let changed = WebArchive.mergeInk(&base, incoming: incoming)
        XCTAssertEqual(changed, incoming.clusters.count)
        XCTAssertEqual(base, incoming)
    }

    func testIoRoundTripThroughActor() async throws {
        let url = "https://example.com/actor"
        let io = WebInkIO(url: url)
        let record = WebInkRecord.snapshot(of: sampleDrawing(), url: url, layout: layout)
        try await io.write(record)
        let loaded = await io.load()
        XCTAssertEqual(loaded, record)
        // Atomic write left no tmp litter.
        let tmp = WebInkStore.inkPath(forKey: io.key).appendingPathExtension("tmp")
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.path))
    }

    /// Archive import and a live runtime write share one path-locked
    /// read-modify-write operation. Whichever enters first, neither addition is
    /// overwritten by the other's stale read.
    func testArchiveMergeIsAtomicWithLiveSnapshotWrite() async throws {
        let url = "https://example.com/atomic-archive-merge"
        let baseDrawing = sampleDrawing()
        let base = WebInkRecord.snapshot(of: baseDrawing, url: url, layout: layout)
        try WebInkStore.saveRecord(base, forKey: WebLibrary.pageKey(url))

        let liveDrawing = baseDrawing.appending(
            sampleDrawing(offsetX: 350, offsetY: 900))
        let live = WebInkRecord.snapshot(of: liveDrawing, url: url, layout: layout)
        let imported = WebInkRecord.snapshot(
            of: sampleDrawing(offsetX: 600, offsetY: 1_600), url: url, layout: layout)
        let liveIO = WebInkIO(url: url)
        let importIO = WebInkIO(url: url)

        async let liveWrite = liveIO.write(live, replacing: base)
        async let archiveMerge: Void = importIO.mergeImported(imported)
        _ = try await (liveWrite, archiveMerge)

        let stored = try XCTUnwrap(WebInkStore.loadRecord(forKey: WebLibrary.pageKey(url)))
        XCTAssertEqual(stored.mergedDrawing().strokes.count, 3)
    }

    /// Two runtimes for equivalent normalized URLs apply their own delta to the
    /// latest shared file. Concurrent additions both survive; a later clear
    /// removes the clusters it observed, and a stale runtime adding a new stroke
    /// cannot resurrect those cleared clusters.
    func testSameURLRuntimesPreserveConcurrentAddsAndClear() async throws {
        let canonical = "https://example.com/shared-runtime"
        let trackingVariant = canonical + "?utm_source=test"
        let first = WebInkPersister(url: canonical)
        let second = WebInkPersister(url: trackingVariant)

        first.drawingChanged(sampleDrawing(), layout: layout)
        second.drawingChanged(
            sampleDrawing(offsetX: 120, offsetY: 210), layout: layout)
        async let firstFlush = first.flushPendingInkAndWait()
        async let secondFlush = second.flushPendingInkAndWait()
        let initialFlushes = await (firstFlush, secondFlush)
        XCTAssertTrue(initialFlushes.0)
        XCTAssertTrue(initialFlushes.1)

        let key = WebLibrary.pageKey(try WebUrl.normalize(canonical))
        let shared = try XCTUnwrap(WebInkStore.loadRecord(forKey: key))
        XCTAssertEqual(shared.mergedDrawing().strokes.count, 2)
        XCTAssertEqual(
            shared.clusters.count, 1,
            "same-cluster concurrent additions must not fall back to cluster-level last writer wins")

        let clearer = WebInkPersister(url: canonical)
        let staleAdder = WebInkPersister(url: trackingVariant)
        clearer.seedBaseline(shared)
        staleAdder.seedBaseline(shared)
        clearer.drawingChanged(PKDrawing(), layout: layout)
        let stalePlusNew = shared.mergedDrawing().appending(
            sampleDrawing(offsetX: 650, offsetY: 1_700))
        staleAdder.drawingChanged(stalePlusNew, layout: layout)
        async let clearFlush = clearer.flushPendingInkAndWait()
        async let staleFlush = staleAdder.flushPendingInkAndWait()
        let deletionFlushes = await (clearFlush, staleFlush)
        XCTAssertTrue(deletionFlushes.0)
        XCTAssertTrue(deletionFlushes.1)

        let afterClear = try XCTUnwrap(WebInkStore.loadRecord(forKey: key))
        XCTAssertEqual(
            afterClear.mergedDrawing().strokes.count, 1,
            "the new concurrent stroke survives, but stale pre-clear strokes stay deleted")
    }

    /// Simulate an initial load whose snapshot is delivered after an early
    /// stroke has already written. The early write coordinates with the loaded
    /// file and must adopt that committed A+B record as its baseline; seeding
    /// the older A snapshot afterwards cannot make the controller's merged A+B
    /// report append A a second time.
    func testLateInitialLoadAfterEarlyWriteDoesNotDuplicateStoredInk() async throws {
        let url = "https://example.com/late-load-early-write"
        let existingDrawing = sampleDrawing(offsetX: 100, offsetY: 200)
        let existing = WebInkRecord.snapshot(
            of: existingDrawing, url: url, layout: layout)
        try WebInkStore.saveRecord(existing, forKey: WebLibrary.pageKey(url))

        let persister = WebInkPersister(url: url)
        let loaded = await persister.loadRecord()
        let lateLoaded = try XCTUnwrap(loaded)
        let earlyStroke = sampleDrawing(offsetX: 500, offsetY: 1_200)
        persister.drawingChanged(earlyStroke, layout: layout)
        let earlyWriteSucceeded = await persister.flushPendingInkAndWait()
        XCTAssertTrue(earlyWriteSucceeded)

        persister.seedBaseline(lateLoaded)
        let mergedCanvas = earlyStroke.appending(lateLoaded.mergedDrawing())
        persister.drawingChanged(mergedCanvas, layout: layout)
        let mergedWriteSucceeded = await persister.flushPendingInkAndWait()
        XCTAssertTrue(mergedWriteSucceeded)

        let stored = try XCTUnwrap(
            WebInkStore.loadRecord(forKey: WebLibrary.pageKey(url)))
        XCTAssertEqual(
            stored.mergedDrawing().strokes.count, 2,
            "the loaded stroke and the early stroke must each appear once")
    }

    /// A restored tab can report its document before SwiftUI mounts the
    /// retained PencilKit overlay, especially when several tabs are recreated
    /// together. The completed sidecar load must wait for that overlay rather
    /// than being consumed invisibly.
    func testLoadBeforeOverlayMountIsAppliedWhenOverlayAttaches() async throws {
        let controller = WebInkController_iOS()
        let loader = ControlledInkPersister()
        controller.persistenceFactory = { _ in loader }
        let record = WebInkRecord.snapshot(
            of: sampleDrawing(offsetY: 900),
            url: "https://example.com/restored-tab",
            layout: layout)

        let loadTask = try XCTUnwrap(
            controller.documentOpened(url: "https://example.com/restored-tab"))
        loader.resolveLoad(with: record)
        await loadTask.value
        XCTAssertEqual(loader.seededBaseline, record)

        let overlay = controller.attachOverlay(to: WKWebView())
        defer { controller.detachOverlay() }
        XCTAssertEqual(overlay.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(
            overlay.canvas.drawing.bounds.minY,
            record.mergedDrawing().bounds.minY,
            accuracy: 0.01)
    }

    /// URL equality is insufficient for A → B → A: the first A load can finish
    /// after the second A becomes current. Only the newest open generation may
    /// seed the overlay.
    func testStaleFirstALoadCannotOverwriteSecondA() async throws {
        let controller = WebInkController_iOS()
        let overlay = controller.attachOverlay(to: WKWebView())
        defer { controller.detachOverlay() }
        var loaders: [ControlledInkPersister] = []
        controller.persistenceFactory = { _ in
            let loader = ControlledInkPersister()
            loaders.append(loader)
            return loader
        }

        let firstATask = try XCTUnwrap(controller.documentOpened(url: "https://example.com/a"))
        let bTask = try XCTUnwrap(controller.documentOpened(url: "https://example.com/b"))
        let secondATask = try XCTUnwrap(controller.documentOpened(url: "https://example.com/a"))
        XCTAssertEqual(loaders.count, 3)

        let secondARecord = WebInkRecord.snapshot(
            of: sampleDrawing(offsetY: 1_200), url: "https://example.com/a", layout: layout)
        loaders[2].resolveLoad(with: secondARecord)
        await secondATask.value
        XCTAssertEqual(
            overlay.canvas.drawing.bounds.minY,
            secondARecord.mergedDrawing().bounds.minY,
            accuracy: 0.01)

        let staleFirstA = WebInkRecord.snapshot(
            of: sampleDrawing(offsetY: 200), url: "https://example.com/a", layout: layout)
        loaders[0].resolveLoad(with: staleFirstA)
        await firstATask.value
        XCTAssertEqual(
            overlay.canvas.drawing.bounds.minY,
            secondARecord.mergedDrawing().bounds.minY,
            accuracy: 0.01)
        XCTAssertNil(loaders[0].seededBaseline)
        XCTAssertEqual(loaders[2].seededBaseline, secondARecord)

        loaders[1].resolveLoad(with: nil)
        await bTask.value
    }

    // MARK: - Phase 5 memory-audit stress coverage

    /// A wide, ~50k-px-tall document with many spatially separated stroke
    /// groups must snapshot into one cluster per group and merge back with the
    /// stroke count and per-group geometry intact — the long-page / many-cluster
    /// path the Phase 5 memory audit exercises. Clustering is O(n²) over
    /// strokes, so this also guards against a snapshot regression at scale.
    func testLongDocumentManyClustersRoundTrips() throws {
        let groups = 60
        let spacing: CGFloat = 800 // well beyond the 48px proximity threshold
        var full = PKDrawing()
        for g in 0..<groups {
            full = full.appending(sampleDrawing(offsetX: 120, offsetY: CGFloat(g) * spacing))
        }
        let tallLayout = WebInkRecord.Layout(
            contentWidth: 980, docHeight: Double(groups) * Double(spacing))

        let record = WebInkRecord.snapshot(
            of: full, url: "https://example.com/long", layout: tallLayout)
        XCTAssertEqual(
            record.clusters.count, groups,
            "each well-separated stroke group is its own cluster")

        // Round-trip through the wire format and back.
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WebInkRecord.self, from: data)
        let merged = decoded.mergedDrawing()
        XCTAssertEqual(merged.strokes.count, full.strokes.count)
        XCTAssertEqual(merged.bounds.minY, full.bounds.minY, accuracy: 0.5)
        XCTAssertEqual(merged.bounds.maxY, full.bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(merged.bounds.width, full.bounds.width, accuracy: 0.5)
    }

    /// Clearing the canvas resets the controller cleanly and the persisted
    /// record for the page is emptied — the Phase 5 fix that stops the anchor
    /// cache from retaining orphaned entries after a Clear. Exercised through
    /// the real controller so the `drawingChanged`-empties-anchor-state path
    /// runs; the observable contract is that a cleared page persists no ink.
    func testClearEmptiesRecordThroughController() async throws {
        let url = "https://example.com/cleared"
        let key = WebLibrary.pageKey(url)
        let controller = WebInkController_iOS()
        let webView = WKWebView()
        _ = controller.attachOverlay(to: webView)
        defer { controller.detachOverlay() }
        let persister = WebInkPersister(url: url)
        persister.debounceInterval = .milliseconds(10)
        controller.persistence = persister

        controller.drawingChanged(sampleDrawing())
        controller.clearCurrentPage()
        await persister.flushPendingInkAndWait()

        XCTAssertEqual(
            WebInkStore.loadRecord(forKey: key)?.clusters.isEmpty, true,
            "a cleared page persists no clusters")
    }
}

/// Test double for the persistence seam: records what the controller hands it.
@MainActor
private final class CapturingInkPersister: WebInkPersisting {
    var captured: [(drawing: PKDrawing, layout: WebInkRecord.Layout)] = []

    func drawingChanged(
        _ drawing: PKDrawing,
        layout: WebInkRecord.Layout,
        anchorFor: (CGRect) -> WebInkRecord.Anchor?
    ) {
        captured.append((drawing, layout))
    }

    func flushPendingInkAndWait() async -> Bool { true }
}

/// Manually completed loader for the A → B → A navigation regression. It has
/// no timing dependency: resolving before or after `loadRecord()` starts is
/// equivalent.
@MainActor
private final class ControlledInkPersister: WebInkPersisting {
    private var loadContinuation: CheckedContinuation<WebInkRecord?, Never>?
    private var resolvedLoad: WebInkRecord??
    private(set) var seededBaseline: WebInkRecord?

    func loadRecord() async -> WebInkRecord? {
        if let resolvedLoad { return resolvedLoad }
        return await withCheckedContinuation { continuation in
            loadContinuation = continuation
        }
    }

    func resolveLoad(with record: WebInkRecord?) {
        if let loadContinuation {
            self.loadContinuation = nil
            loadContinuation.resume(returning: record)
        } else {
            resolvedLoad = .some(record)
        }
    }

    func seedBaseline(_ record: WebInkRecord) {
        seededBaseline = record
    }

    func drawingChanged(
        _ drawing: PKDrawing,
        layout: WebInkRecord.Layout,
        anchorFor: (CGRect) -> WebInkRecord.Anchor?
    ) {}

    func flushPendingInkAndWait() async -> Bool { true }
}

/// Deterministic suspension point for the edit-during-flush regression. The
/// first write waits for the test; later writes complete immediately.
private actor PausingInkWriter {
    private(set) var records: [WebInkRecord] = []
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func write(_ record: WebInkRecord) async -> WebInkRecord {
        records.append(record)
        guard records.count == 1 else { return record }
        startContinuation?.resume()
        startContinuation = nil
        await withCheckedContinuation { continuation in
            releaseContinuation = continuation
        }
        return record
    }

    func waitUntilFirstWriteStarts() async {
        guard records.isEmpty else { return }
        await withCheckedContinuation { continuation in
            startContinuation = continuation
        }
    }

    func resumeFirstWrite() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
#endif
