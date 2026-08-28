import UIKit
import XCTest
@testable import Vellum

// Coverage for the scratchpad image-import feature: the disk attachment store
// (save / resolve / GC), dropped-image normalization, and the store's
// snapshot/drop entry point that turns an image into note markdown.
//
// The UI gestures themselves — the drag-to-crop marquee and external file
// drop — are exercised out-of-process by ScratchpadSnapshotUITests (a UI-test
// target). Everything they funnel into is verified deterministically here.

@MainActor
final class ScratchpadImportTests: XCTestCase {
    private var tempDir: URL!
    private var savedPendingGracePeriod: TimeInterval = 60

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-scratch-attach-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        // Redirect the attachment store so tests never touch a real user's files.
        ScratchpadAttachmentStore.directoryOverride = tempDir
        savedPendingGracePeriod = ScratchpadAttachmentStore.pendingGracePeriod
        ScratchpadAttachmentStore.resetPending()
        AppDefaults.current.removeObject(forKey: ScratchpadPersistence.notesKey)
    }

    override func tearDown() async throws {
        await ScratchpadPersistence.awaitPendingFlush()
        AppDefaults.current.removeObject(forKey: ScratchpadPersistence.notesKey)
        ScratchpadAttachmentStore.directoryOverride = nil
        // This suite calls `addImage`, which claims a GC exemption for each id it
        // writes (#105). Harmless if it leaks — the keys are UUIDs — but the
        // registry is process-global, so leave it as we found it.
        ScratchpadAttachmentStore.resetPending()
        ScratchpadAttachmentStore.pendingGracePeriod = savedPendingGracePeriod
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
    }

    // MARK: - Attachment store

    func testSaveThenResolveRoundTrips() throws {
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let id = try XCTUnwrap(ScratchpadAttachmentStore.save(data: bytes, fileExtension: "jpg"))

        let url = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertEqual(url.pathExtension, "jpg")
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        // Ids are matched case-insensitively (URL hosts may be lowercased).
        XCTAssertNotNil(ScratchpadAttachmentStore.fileURL(for: id.uppercased()))
    }

    func testFileURLMissingIdIsNil() {
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: "does-not-exist"))
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: ""))
    }

    func testMediaTypeMapping() {
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "JPG"), "image/jpeg")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "jpeg"), "image/jpeg")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "png"), "image/png")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "gif"), "image/gif")
        XCTAssertEqual(ScratchpadAttachmentStore.mediaType(forExtension: "xyz"), "application/octet-stream")
    }

    func testReferencedIdsExtractsFromMarkdown() {
        let a = "aaaaaaaa-1111-2222-3333-444444444444"
        let b = "bbbbbbbb-5555-6666-7777-888888888888"
        let note = """
        Notes here.

        ![Region · p.3](vellum-scratchpad://\(a))

        More text ![Image](vellum-scratchpad://\(b)) inline.
        """
        let ids = ScratchpadAttachmentStore.referencedIds(in: note)
        XCTAssertEqual(ids, [a, b])
        XCTAssertTrue(ScratchpadAttachmentStore.referencedIds(in: "no refs").isEmpty)
    }

    func testCollectGarbagePrunesOnlyOrphans() throws {
        let keep = try XCTUnwrap(ScratchpadAttachmentStore.save(data: Data([1]), fileExtension: "jpg"))
        let orphan = try XCTUnwrap(ScratchpadAttachmentStore.save(data: Data([2]), fileExtension: "png"))

        ScratchpadAttachmentStore.collectGarbage(referencedIds: [keep])

        XCTAssertNotNil(ScratchpadAttachmentStore.fileURL(for: keep), "referenced attachment must survive")
        XCTAssertNil(ScratchpadAttachmentStore.fileURL(for: orphan), "unreferenced attachment must be pruned")
    }

    // MARK: - Dropped-image normalization (scratchpadCapture)

    func testCapturePreservesSmallPNG() throws {
        let data = try pngData(width: 40, height: 30)
        let capture = try XCTUnwrap(scratchpadCapture(from: data))
        XCTAssertEqual(capture.fileExtension, "png")
        XCTAssertEqual(capture.mediaType, "image/png")
        XCTAssertEqual(capture.width, 40)
        XCTAssertEqual(capture.height, 30)
        // A small PNG is kept verbatim.
        XCTAssertEqual(capture.data, data)
    }

    func testCapturePreservesSmallJPEG() throws {
        let data = try jpegData(width: 32, height: 32)
        let capture = try XCTUnwrap(scratchpadCapture(from: data))
        XCTAssertEqual(capture.fileExtension, "jpg")
        XCTAssertEqual(capture.mediaType, "image/jpeg")
    }

    func testCaptureDownscalesLargeImage() throws {
        // 3000px on the long side must be capped to 2000 and re-encoded.
        let data = try pngData(width: 3000, height: 1500)
        let capture = try XCTUnwrap(scratchpadCapture(from: data))
        XCTAssertLessThanOrEqual(max(capture.width, capture.height), 2000)
        XCTAssertEqual(capture.width, 2000)
        XCTAssertEqual(capture.height, 1000, "aspect ratio must be preserved")
    }

    func testCaptureRejectsNonImageData() {
        XCTAssertNil(scratchpadCapture(from: Data("not an image".utf8)))
    }

    // MARK: - Store entry point (addImage)

    func testAddImageWritesAttachmentAndInsertsMarkdown() throws {
        let store = ScratchpadStore()
        var inserted: String?
        store.insertMarkdownHandler = { inserted = $0 }

        let capture = ScratchpadImageCapture(
            data: Data([0xAA, 0xBB]), fileExtension: "jpg", mediaType: "image/jpeg",
            width: 10, height: 8, pageNumber: 3)
        store.addImage(capture, label: "Region · p.3")

        let markdown = try XCTUnwrap(inserted)
        // ![Region · p.3](vellum-scratchpad://<uuid>)
        let pattern = #"^!\[Region · p\.3\]\(vellum-scratchpad://([0-9a-f-]+)\)$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let match = try XCTUnwrap(
            regex.firstMatch(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)),
            "unexpected markdown: \(markdown)")
        let id = String(markdown[Range(match.range(at: 1), in: markdown)!])

        // The referenced attachment must exist on disk with the right bytes.
        let url = try XCTUnwrap(ScratchpadAttachmentStore.fileURL(for: id))
        XCTAssertEqual(try Data(contentsOf: url), capture.data)
    }

    func testAddImageSanitizesLabel() throws {
        let store = ScratchpadStore()
        var inserted: String?
        store.insertMarkdownHandler = { inserted = $0 }

        let capture = ScratchpadImageCapture(
            data: Data([1]), fileExtension: "png", mediaType: "image/png",
            width: 1, height: 1, pageNumber: nil)
        store.addImage(capture, label: "we]ird\nlabel")

        let markdown = try XCTUnwrap(inserted)
        // The `]` and newline must not leak into (and break) the alt text.
        XCTAssertFalse(markdown.contains("]e"), "unescaped ] leaked: \(markdown)")
        XCTAssertFalse(markdown.contains("\n"))
        XCTAssertTrue(markdown.hasPrefix("![we ird label]("))
    }

    func testWarnUnsupportedDropSetsMessage() {
        let store = ScratchpadStore()
        XCTAssertNil(store.dropWarning)
        store.warnUnsupportedDrop()
        XCTAssertNotNil(store.dropWarning, "a non-image drop should surface a warning")
        XCTAssertTrue(store.dropWarning?.localizedCaseInsensitiveContains("image") ?? false)
    }

    // MARK: - Coordinated persistence

    func testLegacyMigrationRetainsEverythingAfterAttachmentFailureThenRetries() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-migration-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let path = "/old/location/Unique.pdf"
        let attachmentID = UUID().uuidString.lowercased()
        let attachmentData = Data([0xCA, 0xFE])
        let attachmentURL = tempDir.appendingPathComponent("\(attachmentID).png")
        try attachmentData.write(to: attachmentURL)
        let legacyText = "![Old image](vellum-scratchpad://\(attachmentID))"
        AppDefaults.current.set(
            try JSONEncoder().encode([LegacyEntry(key: path, text: legacyText)]),
            forKey: ScratchpadPersistence.notesKey)
        let document = DocumentInfo(
            kind: .pdf, pdfPath: path, title: "Unique", pageCount: 1,
            lastPage: 1, docId: key)

        container.failNextWrite(with: .io("injected attachment failure"))
        let first = await ScratchpadPersistence.migrateLegacyIfNeeded(
            document: document, key: key, coordinator: coordinator)
        guard case .retainedForRetry = first else {
            return XCTFail("A failed attachment copy must retain the legacy source")
        }
        XCTAssertEqual(ScratchpadPersistence.listLegacyEntries().count, 1)
        XCTAssertEqual(try Data(contentsOf: attachmentURL), attachmentData)
        let noteURL = documentURL(root: root, key: key, name: "scratchpad.md")
        XCTAssertNil(container.peek(noteURL))

        // A destination created before retry is authoritative; migration must
        // keep it and make the legacy note visibly recoverable, not overwrite it
        // or leave the blob eligible to resurrect after a later delete.
        container.seed(noteURL, data: Data("destination".utf8))

        let retry = await ScratchpadPersistence.migrateLegacyIfNeeded(
            document: document, key: key, coordinator: coordinator)
        guard case .migrated = retry else {
            return XCTFail("The same retained migration should succeed on retry")
        }
        XCTAssertTrue(ScratchpadPersistence.listLegacyEntries().isEmpty)
        XCTAssertEqual(
            container.peek(documentURL(
                root: root, key: key, name: "attachments/\(attachmentID).png")),
            attachmentData)
        XCTAssertEqual(
            container.peek(noteURL),
            Data((
                "destination\n\n---\n\n"
                    + "## Recovered notes from an older Scratchpad\n\n"
                    + "![Old image](attachments/\(attachmentID).png)"
            ).utf8))
    }

    func testUnavailableICloudNotePausesEditingAndCleanReloadDoesNotWrite() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-unavailable-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Remote",
            pageCount: 1, lastPage: 1, docId: key)
        let target = documentURL(root: root, key: key, name: "scratchpad.md")
        let remote = Data("remote note".utf8)
        container.seed(target, data: remote, readiness: .notDownloaded)
        let app = AppStore(sessions: DocumentSessionManager())
        app.attachTab(PdfTab(
            id: "remote-tab", document: document, currentPage: 1, numPages: 1,
            zoom: 1, visiblePages: [1], webVisibleRange: nil,
            webVisibleBookmarks: [], mode: .view))
        let store = ScratchpadStore(coordinator: coordinator)
        store.app = app

        await store.loadForDocument(document).value
        XCTAssertTrue(store.isPersistencePaused)
        XCTAssertTrue(store.text.isEmpty)
        store.text = "must not replace remote"
        await store.flush().value
        XCTAssertEqual(container.peek(target), remote)
        XCTAssertEqual(container.coordinatedWriteCount, 0)

        container.setReadiness(.current, at: target)
        await store.discardAndReload(for: document).value
        XCTAssertFalse(store.isPersistencePaused)
        XCTAssertEqual(store.text, "remote note")
        await store.flush().value
        XCTAssertEqual(
            container.coordinatedWriteCount, 0,
            "switch/background flush must be a no-op after a clean load")
    }

    func testExclusiveDeleteAndImportCannotBeResurrectedByInflightSave() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-exclusive-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()

        let deleteKey = UUID().uuidString.lowercased()
        let deleteTarget = documentURL(root: root, key: deleteKey, name: "scratchpad.md")
        container.seed(deleteTarget, data: Data("before delete".utf8))
        let deleteGate = ScratchpadOperationGate()
        let staleDeleteSave = Task {
            await ScratchpadWriteCoordinator.shared.enqueue(forKey: deleteKey) {
                await deleteGate.pause()
                do {
                    try await DocumentDataStore.saveScratchpad(
                        forKey: deleteKey, text: "stale", coordinator: coordinator)
                    return true
                } catch {
                    return false
                }
            }
        }
        await deleteGate.waitUntilStarted()
        let deletion = Task {
            try await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
                forKeys: [deleteKey]
            ) {
                try await DocumentDataStore.deleteNotesSafely(
                    forKey: deleteKey, coordinator: coordinator)
            }
        }
        await Task.yield()
        await Task.yield()
        await deleteGate.release()
        _ = await staleDeleteSave.value
        try await deletion.value
        XCTAssertNil(container.peek(deleteTarget))

        let importKey = UUID().uuidString.lowercased()
        let importTarget = documentURL(root: root, key: importKey, name: "scratchpad.md")
        container.seed(importTarget, data: Data("before import".utf8))
        let importGate = ScratchpadOperationGate()
        let staleImportSave = Task {
            await ScratchpadWriteCoordinator.shared.enqueue(forKey: importKey) {
                await importGate.pause()
                do {
                    try await DocumentDataStore.saveScratchpad(
                        forKey: importKey, text: "stale", coordinator: coordinator)
                    return true
                } catch {
                    return false
                }
            }
        }
        await importGate.waitUntilStarted()
        let installation = Task {
            try await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
                forKeys: [importKey]
            ) {
                try await DocumentDataStore.saveScratchpad(
                    forKey: importKey, text: "imported", coordinator: coordinator)
            }
        }
        await Task.yield()
        await Task.yield()
        await importGate.release()
        _ = await staleImportSave.value
        try await installation.value
        XCTAssertEqual(container.peek(importTarget), Data("imported".utf8))
    }

    func testStalePaneSavePreservesBothEditsWithoutDuplicatingRecovery() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-two-panes-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Shared",
            pageCount: 1, lastPage: 1, docId: key)
        let target = documentURL(root: root, key: key, name: "scratchpad.md")
        container.seed(target, data: Data("baseline".utf8))

        let app = appShowing(document, tabID: "shared-tab")
        let first = ScratchpadStore(coordinator: coordinator)
        first.app = app
        let stale = ScratchpadStore(coordinator: coordinator)
        stale.app = app
        await first.loadForDocument(document).value
        await stale.loadForDocument(document).value

        first.text = "first pane edit"
        await first.flush().value
        stale.text = "stale pane edit"
        await stale.flush().value

        let committed = String(decoding: try XCTUnwrap(container.peek(target)), as: UTF8.self)
        XCTAssertTrue(committed.contains("first pane edit"))
        XCTAssertTrue(committed.contains("stale pane edit"))
        XCTAssertEqual(
            committed.components(separatedBy: "stale pane edit").count - 1, 1,
            "a retry-safe recovery must not duplicate the stale pane's edit")
        XCTAssertEqual(stale.text, ScratchpadPersistence.relativeToScheme(committed))
    }

    func testSamePaneFlushesSerializeBeforeSnapshottingBaseline() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-one-pane-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Serial",
            pageCount: 1, lastPage: 1, docId: key)
        let target = documentURL(root: root, key: key, name: "scratchpad.md")
        container.seed(target, data: Data("baseline".utf8))
        let app = appShowing(document, tabID: "serial-tab")
        let store = ScratchpadStore(coordinator: coordinator)
        store.app = app
        await store.loadForDocument(document).value

        let gate = ScratchpadOperationGate()
        let blocker = Task {
            await ScratchpadWriteCoordinator.shared.withExclusiveAccess(forKeys: [key]) {
                await gate.pause()
            }
        }
        await gate.waitUntilStarted()
        store.text = "first edit"
        let firstFlush = store.flush()
        await Task.yield()
        await Task.yield()
        store.text = "second edit"
        let secondFlush = store.flush()
        await gate.release()
        await blocker.value
        await firstFlush.value
        await secondFlush.value

        XCTAssertEqual(container.peek(target), Data("second edit".utf8))
        XCTAssertEqual(store.text, "second edit")
        XCTAssertFalse(store.text.contains("Recovered edit"))
    }

    func testConflictCommitRefreshesOtherPanesAttachments() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-conflict-image-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Images",
            pageCount: 1, lastPage: 1, docId: key)
        let app = appShowing(document, tabID: "images-tab")
        let imagePane = ScratchpadStore(coordinator: coordinator)
        imagePane.app = app
        let stalePane = ScratchpadStore(coordinator: coordinator)
        stalePane.app = app
        await imagePane.loadForDocument(document).value
        await stalePane.loadForDocument(document).value

        var markdown: String?
        imagePane.insertMarkdownHandler = { markdown = $0 }
        let bytes = Data([4, 5, 6, 7])
        imagePane.addImage(.init(
            data: bytes, fileExtension: "png", mediaType: "image/png",
            width: 1, height: 1, pageNumber: nil), label: "Shared image")
        await imagePane.flush().value
        let id = try XCTUnwrap(
            ScratchpadAttachmentStore.referencedIds(in: try XCTUnwrap(markdown)).first)

        stalePane.text = "the stale pane's edit"
        await stalePane.flush().value

        XCTAssertTrue(stalePane.text.contains(id))
        XCTAssertEqual(stalePane.attachmentResolver.attachment(for: id)?.data, bytes)
        XCTAssertEqual(
            stalePane.attachmentResolver.attachment(for: id)?.name,
            "\(id).png")
    }

    func testExternalDeleteStaysFrozenUntilSuccessAndFailureReloadsAuthoritativeNote() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-delete-state-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Delete",
            pageCount: 1, lastPage: 1, docId: key)
        let target = documentURL(root: root, key: key, name: "scratchpad.md")
        container.seed(target, data: Data("authoritative".utf8))
        let store = ScratchpadStore(coordinator: coordinator)
        store.app = appShowing(document, tabID: "delete-tab")
        await store.loadForDocument(document).value

        let failed = try XCTUnwrap(store.prepareForExternalDelete(matchingKey: key))
        XCTAssertTrue(store.isPersistencePaused)
        store.text = "must not queue behind delete"
        await store.finishExternalDelete(failed, succeeded: false)
        XCTAssertFalse(store.isPersistencePaused)
        XCTAssertEqual(store.text, "authoritative")

        let succeeded = try XCTUnwrap(store.prepareForExternalDelete(matchingKey: key))
        try await ScratchpadWriteCoordinator.shared.withExclusiveAccess(forKeys: [key]) {
            try await DocumentDataStore.deleteNotesSafely(
                forKey: key, coordinator: coordinator)
        }
        XCTAssertTrue(store.isPersistencePaused)
        await store.finishExternalDelete(succeeded, succeeded: true)
        XCTAssertFalse(store.isPersistencePaused)
        XCTAssertTrue(store.text.isEmpty)
        await store.flush().value
        XCTAssertNil(container.peek(target))
    }

    func testFailedInitialRekeyPausesEditing() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-rekey-failure-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Rekey",
            pageCount: 1, lastPage: 1, docId: UUID().uuidString.lowercased())
        container.failNextList(with: .io("injected rekey failure"))
        let store = ScratchpadStore(coordinator: coordinator)
        store.app = appShowing(document, tabID: "rekey-tab")

        await store.loadForDocument(document).value

        XCTAssertTrue(store.isPersistencePaused)
        XCTAssertTrue(store.text.isEmpty)
        XCTAssertTrue(store.dropWarning?.localizedCaseInsensitiveContains("paused") ?? false)
    }

    func testEmptyInitialRekeyDoesNotInspectDurableCopy() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-rekey-empty-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let oldKey = DocumentIdentity.sha256Hex("/tmp/\(UUID().uuidString).pdf")
        let newKey = UUID().uuidString.lowercased()
        let durableNote = documentURL(
            root: root, key: newKey, name: "scratchpad.md")
        container.seed(
            durableNote, data: Data("saved note".utf8), readiness: .notDownloaded)
        container.stallMaterialization(at: durableNote)

        let succeeded = await DocumentDataStore.rekey(
            from: oldKey, to: newKey, coordinator: coordinator)

        XCTAssertTrue(succeeded)
        XCTAssertEqual(container.metadataQueryCount, 1)
        XCTAssertEqual(container.materializationCount, 0)
        XCTAssertEqual(container.peek(durableNote), Data("saved note".utf8))
    }

    func testImageReferenceIsSavedBeforeWebViewCallback() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-image-flush-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Image",
            pageCount: 1, lastPage: 1, docId: key)
        let store = ScratchpadStore(coordinator: coordinator)
        let app = appShowing(document, tabID: "image-tab")
        store.app = app
        await store.loadForDocument(document).value
        var inserted: String?
        store.insertMarkdownHandler = { inserted = $0 }
        let bytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])

        store.addImage(.init(
            data: bytes, fileExtension: "png", mediaType: "image/png",
            width: 1, height: 1, pageNumber: nil), label: "Image")
        let markdown = try XCTUnwrap(inserted)
        let id = try XCTUnwrap(ScratchpadAttachmentStore.referencedIds(in: markdown).first)
        XCTAssertTrue(store.text.isEmpty, "the WebView callback has not arrived yet")
        await store.flush().value
        XCTAssertNil(store.dropWarning, "flush warning: \(store.dropWarning ?? "none")")
        XCTAssertFalse(store.text.isEmpty, "a successful flush publishes the committed snippet")

        XCTAssertEqual(
            container.peek(documentURL(
                root: root, key: key, name: "attachments/\(id).png")),
            bytes)
        XCTAssertEqual(
            container.peek(documentURL(root: root, key: key, name: "scratchpad.md")),
            Data((markdown + "\n").replacingOccurrences(
                of: "vellum-scratchpad://\(id)",
                with: "attachments/\(id).png").utf8))
    }

    func testConcurrentRecoveryMergeIsIdempotent() {
        let first = ScratchpadPersistence.mergeConcurrentEdit(
            durable: "baseline A", expectedBaseline: "baseline", edited: "baseline B")
        let retry = ScratchpadPersistence.mergeConcurrentEdit(
            durable: first, expectedBaseline: "baseline", edited: "baseline B")
        XCTAssertEqual(retry, first)
        XCTAssertEqual(first.components(separatedBy: "baseline B").count - 1, 1)
    }

    func testNearLimitConflictIsPreservedWithoutTruncation() async throws {
        let root = URL(fileURLWithPath: "/scratchpad-overflow-\(UUID().uuidString)/Vellum")
        let container = FakeSyncedContainer()
        let coordinator = makeCoordinator(container: container, cloudRoot: root)
        await coordinator.start()
        let key = UUID().uuidString.lowercased()
        let baseline = String(repeating: "x", count: ScratchpadPersistence.maxCharacters - 2)
        let durable = baseline + " A"
        let edited = baseline + " B"
        let target = documentURL(root: root, key: key, name: "scratchpad.md")
        container.seed(target, data: Data(durable.utf8))
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/tmp/\(UUID().uuidString).pdf", title: "Large",
            pageCount: 1, lastPage: 1, docId: key)

        let saveResult = await ScratchpadPersistence.save(
            forKey: key, document: document, schemeText: edited,
            expectedBaseline: baseline, attachments: [], dirtyAttachmentNames: [],
            coordinator: coordinator)
        let committed = try XCTUnwrap(saveResult)

        XCTAssertGreaterThan(committed.count, ScratchpadPersistence.maxCharacters)
        XCTAssertTrue(committed.contains(" A"))
        XCTAssertTrue(committed.contains(" B"))
        XCTAssertEqual(container.peek(target), Data(committed.utf8))
    }

    func testPendingWebInsertionSkipsAlreadyAuthoritativeSnippet() {
        let markdown = "![Image](vellum-scratchpad://abc)"
        XCTAssertFalse(scratchpadShouldDeliverPendingInsertion(
            markdown, authoritativeText: "notes\n\n\(markdown)\n"))
        XCTAssertTrue(scratchpadShouldDeliverPendingInsertion(
            markdown, authoritativeText: "notes without image"))
    }

    // MARK: - Helpers

    private struct LegacyEntry: Codable {
        var key: String
        var text: String
    }

    private func makeCoordinator(
        container: FakeSyncedContainer,
        cloudRoot: URL
    ) -> StorageCoordinator {
        StorageCoordinator(
            storeDir: URL(fileURLWithPath: "/scratchpad-local-\(UUID().uuidString)/web"),
            modeProvider: { .icloud },
            effectiveModeProvider: { .icloud },
            rootResolver: { cloudRoot },
            containerFactory: { container })
    }

    private func appShowing(_ document: DocumentInfo, tabID: String) -> AppStore {
        let app = AppStore(sessions: DocumentSessionManager())
        app.attachTab(PdfTab(
            id: tabID, document: document, currentPage: 1, numPages: 1,
            zoom: 1, visiblePages: [1], webVisibleRange: nil,
            webVisibleBookmarks: [], mode: .view))
        return app
    }

    private func documentURL(root: URL, key: String, name: String) -> URL {
        root.appendingPathComponent(".vellum/documents/\(key)/\(name)")
    }

    private func pngData(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(makeImage(width: width, height: height).pngData())
    }

    private func jpegData(width: Int, height: Int) throws -> Data {
        try XCTUnwrap(makeImage(width: width, height: height).jpegData(compressionQuality: 0.9))
    }

    /// A solid-color bitmap at exactly `width`×`height` pixels (scale 1). The
    /// default renderer format is non-opaque, so `pngData()` carries an alpha
    /// channel — matching the macOS 4-sample RGBA rep the shared normalizer
    /// re-encodes; the encoding (PNG vs JPEG) is chosen by the callers above.
    private func makeImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { ctx in
            UIColor.systemBlue.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }
}

private actor ScratchpadOperationGate {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func pause() async {
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
