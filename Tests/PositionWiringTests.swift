import Foundation
import Testing

@testable import Vellum

@Suite("Position store — app wiring", .serialized)
@MainActor
struct PositionWiringTests {
    private let pageURL = "https://example.com/spec-154"

    private func service(
        storage: InMemoryPositionStorage = InMemoryPositionStorage(),
        clock: ManualPositionClock = ManualPositionClock(
            PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")),
        beforeRecordMoved: (@Sendable (ReadingPosition) async -> Void)? = nil
    ) -> DocumentPositionService {
        DocumentPositionService(
            storage: storage,
            device: .phone,
            clock: clock,
            timer: ManualPositionTimer(),
            policy: .immediate,
            beforeRecordMoved: beforeRecordMoved)
    }

    @Test("PDF keying uses the path fallback without forcing a document-id stamp")
    func pdfKeyingUsesPathFallbackWithoutStamping() {
        let document = DocumentInfo(
            kind: .pdf,
            pdfPath: "/tmp/unstamped.pdf",
            title: "Unstamped",
            pageCount: 10,
            lastPage: 2,
            docId: nil)

        #expect(DocumentPositionService.key(for: document) == .pdfPath("/tmp/unstamped.pdf"))
    }

    @Test("Opening resumes from the position store before legacy last_page")
    func openingResumesFromPositionBeforeLegacyLastPage() async throws {
        let path = "/tmp/legacy-last-page.pdf"
        let key = DocumentKey.pdfPath(path)
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let storage = InMemoryPositionStorage()
        storage.seed(
            PositionFixtures.record(
                .mac,
                writtenAt: t0,
                documents: [
                    key: .init(
                        readingPosition: Stamped(
                            at: t0, value: ReadingPosition(page: 7, pageCount: 10)),
                        openedAt: t0)
                ]))
        let sessions = StubPositionSessionService(
            openFileInfo: DocumentInfo(
                kind: .pdf,
                pdfPath: path,
                title: "Legacy",
                pageCount: 10,
                lastPage: 2,
                docId: nil))
        let workspace = WorkspaceStore(sessions: sessions, positions: service(storage: storage))

        await workspace.focusedPane.app.openFile(path: path)

        #expect(workspace.focusedPane.app.currentPage == 7)
        #expect(sessions.ensureDocumentIdCalls == 0)
    }

    @Test("Opening a webpage through the app leaves the sidecar bytes untouched")
    func openingWebpageLeavesSidecarBytesUntouched() async throws {
        try await withScratch { scratch in
            let sidecar = try seedSidecar()
            let before = try Data(contentsOf: sidecar)
            let storage = InMemoryPositionStorage()
            let positions = service(storage: storage)
            let workspace = WorkspaceStore(
                sessions: DocumentSessionManager(),
                positions: positions)

            await workspace.focusedPane.app.openUrl(pageURL)
            await positions.flush()

            #expect(try Data(contentsOf: sidecar) == before)
            #expect(storage.writeCount == 1)
            let record = try #require(await storage.loadAll().first)
            #expect(record.documents[.web(normalizedURL: pageURL)]?.openedAt != nil)
            #expect(record.documents[.web(normalizedURL: pageURL)]?.openState?.value.isOpen == true)
            #expect(scratch.positionsDir.path.hasSuffix("/positions"))
        }
    }

    @Test("Closing a webpage records closed state without writing last_page to the sidecar")
    func closingWebpageRecordsClosedWithoutSidecarWrite() async throws {
        try await withScratch { _ in
            let sidecar = try seedSidecar()
            let before = try Data(contentsOf: sidecar)
            let storage = InMemoryPositionStorage()
            let positions = service(storage: storage)
            let workspace = WorkspaceStore(
                sessions: DocumentSessionManager(),
                positions: positions)
            let app = workspace.focusedPane.app

            await app.openUrl(pageURL)
            app.setCurrentPage(4)
            let tabId = try #require(app.activeTabId)
            await app.closeTab(tabId)
            await workspace.tabTeardowns.awaitAll()

            #expect(try Data(contentsOf: sidecar) == before)
            let record = try #require(await storage.loadAll().first)
            let entry = try #require(record.documents[.web(normalizedURL: pageURL)])
            #expect(entry.readingPosition?.value.page == 4)
            #expect(entry.closedAt != nil)
            #expect(entry.openState?.value.isOpen == false)
        }
    }

    @Test("Background position flush does not restamp opened_at")
    func backgroundFlushDoesNotInventAVisit() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage, clock: clock)
        let workspace = WorkspaceStore(
            sessions: StubPositionSessionService(),
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl(pageURL)
        await positions.flush()
        let key = DocumentPositionService.webKey(for: pageURL)
        let openedAt = try #require(await storedEntry(in: storage, key: key).openedAt)

        clock.advance(by: 3600)
        app.setCurrentPage(6)
        await app.flushPendingPositionRecords()
        await workspace.flushOpenTabPositions()

        let flushed = try await storedEntry(in: storage, key: key)
        #expect(flushed.openedAt == openedAt)
        #expect(flushed.readingPosition?.value.page == 6)
        #expect(flushed.openState?.value.isOpen == true)
    }

    @Test("Closing a pane flushes final position and closed state for discarded tabs")
    func closePaneFlushesDiscardedLiveTabs() async throws {
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage)
        let workspace = WorkspaceStore(
            sessions: StubPositionSessionService(),
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl(pageURL)
        app.setCurrentPage(5)
        workspace.closePane(workspace.focusedPaneId)
        await workspace.tabTeardowns.awaitAll()

        let entry = try await storedEntry(in: storage, key: DocumentPositionService.webKey(for: pageURL))
        #expect(entry.readingPosition?.value.page == 5)
        #expect(entry.closedAt != nil)
        #expect(entry.openState?.value.isOpen == false)
    }

    @Test("Closing one duplicate web tab keeps the document key open until the last duplicate closes")
    func duplicateTabCloseOnlyClosesDocumentKeyAtTheLastTab() async throws {
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage)
        let workspace = WorkspaceStore(
            sessions: StubPositionSessionService(),
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl(pageURL)
        let originalTab = try #require(app.activeTabId)
        await app.duplicateTab(originalTab)
        let duplicateTab = try #require(app.activeTabId)

        await app.closeTab(originalTab)
        await workspace.tabTeardowns.awaitAll()

        let key = DocumentPositionService.webKey(for: pageURL)
        var entry = try await storedEntry(in: storage, key: key)
        #expect(entry.closedAt == nil)
        #expect(entry.openState?.value.isOpen == true)

        await app.closeTab(duplicateTab)
        await workspace.tabTeardowns.awaitAll()

        entry = try await storedEntry(in: storage, key: key)
        #expect(entry.closedAt != nil)
        #expect(entry.openState?.value.isOpen == false)
    }

    @Test("Out-of-order page-position tasks cannot let an older page win")
    func stalePagePositionTaskCannotWin() async throws {
        let gate = PagePositionGate(heldPage: 2)
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage) { position in
            await gate.holdIfNeeded(position.page)
        }
        let workspace = WorkspaceStore(
            sessions: StubPositionSessionService(),
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl(pageURL)
        app.setCurrentPage(2)
        await gate.waitUntilHeld()

        app.setCurrentPage(9)
        await Task.yield()
        await gate.release()
        await app.flushPendingPositionRecords()
        await positions.flush()

        let entry = try await storedEntry(in: storage, key: DocumentPositionService.webKey(for: pageURL))
        #expect(entry.readingPosition?.value.page == 9)
    }

    @Test("Tab close waits for an already-drained page-position worker before final flush")
    func closeWaitsForDrainedPositionWorkerBeforeFinalFlush() async throws {
        let gate = PagePositionGate(heldPage: 2)
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage) { position in
            await gate.holdIfNeeded(position.page)
        }
        let workspace = WorkspaceStore(
            sessions: StubPositionSessionService(),
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl(pageURL)
        app.setCurrentPage(2)
        await gate.waitUntilHeld()

        app.setCurrentPage(9)
        let tabId = try #require(app.activeTabId)
        await app.closeTab(tabId)
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        await workspace.tabTeardowns.awaitAll()

        let entry = try await storedEntry(in: storage, key: DocumentPositionService.webKey(for: pageURL))
        #expect(entry.readingPosition?.value.page == 9)
        #expect(entry.openState?.value.isOpen == false)
    }

    @Test("Workspace background flush waits for every pane's page-position worker")
    func workspaceFlushWaitsForEveryPanePositionWorker() async throws {
        let gate = PagePositionGate(heldPage: 2)
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage) { position in
            await gate.holdIfNeeded(position.page)
        }
        let workspace = WorkspaceStore(
            sessions: StubPositionSessionService(),
            positions: positions)
        let firstPane = workspace.focusedPane

        await firstPane.app.openUrl(pageURL)
        workspace.splitFocused(.horizontal)
        firstPane.app.setCurrentPage(2)
        await gate.waitUntilHeld()

        firstPane.app.setCurrentPage(7)
        let flush = Task { await workspace.flushOpenTabPositions() }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        await flush.value

        let entry = try await storedEntry(in: storage, key: DocumentPositionService.webKey(for: pageURL))
        #expect(entry.readingPosition?.value.page == 7)
        #expect(entry.openState?.value.isOpen == true)
    }

    @Test("Direct web reopen waits for pending teardown of the same normalized key")
    func directWebReopenWaitsForSameKeyTeardown() async throws {
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage)
        let sessions = GatedWebSessionService()
        let workspace = WorkspaceStore(
            sessions: sessions,
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl("example.com/spec-154#first")
        let tabId = try #require(app.activeTabId)
        sessions.holdNextClose()
        await app.closeTab(tabId)
        await sessions.waitUntilCloseHeld()

        let reopen = Task {
            await app.openUrl("https://example.com/spec-154#second")
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(sessions.openWebDocumentCalls == 1)

        sessions.releaseClose()
        await reopen.value

        #expect(sessions.openWebDocumentCalls == 2)
    }

    @Test("Reopening the same .vellumweb archive waits for the URL-key teardown")
    func sameArchiveReopenWaitsForUrlKeyTeardown() async throws {
        try await withScratch { scratch in
            let archive = scratch.root.appendingPathComponent("spec.vellumweb")
            try writeArchive(url: pageURL, to: archive)
            try await archiveReopenWaitsForUrlKey(archiveToOpen: archive)
        }
    }

    @Test("Opening a different .vellumweb archive for the same URL waits for the URL-key teardown")
    func differentArchiveForSameURLWaitsForUrlKeyTeardown() async throws {
        try await withScratch { scratch in
            let original = scratch.root.appendingPathComponent("spec-original.vellumweb")
            let copy = scratch.root.appendingPathComponent("spec-copy.vellumweb")
            try writeArchive(url: pageURL, to: original)
            try writeArchive(url: pageURL, to: copy)
            try await archiveReopenWaitsForUrlKey(archiveToOpen: copy)
        }
    }

    @Test("Storage inventory prefers position-store recency for web rows")
    func storageInventoryUsesPositionRecencyForWebRows() throws {
        let key = WebLibrary.pageKey(pageURL)
        let sidecarDate = PositionFixtures.date("2026-01-01T00:00:00.000000+00:00")
        let positionDate = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let web = WebLibrary.SnapshotStorageEntry(
            key: key,
            url: pageURL,
            title: "Spec",
            saved: false,
            hasAnnotations: false,
            lastOpened: sidecarDate,
            byteSize: 32)

        let row = try #require(
            StorageInventory.joinRows(
                documents: [],
                cacheEntries: [],
                webEntries: [web],
                positionLastOpened: [key: positionDate]).first)

        #expect(row.lastOpened == positionDate)
    }

    @Test("Storage inventory sees more than 512 merged web recents")
    func storageInventorySeesMoreThan512MergedWebRecents() async {
        let base = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let storage = InMemoryPositionStorage()
        var macDocuments: [DocumentKey: PositionDeviceRecord.DocumentEntry] = [:]
        var phoneDocuments: [DocumentKey: PositionDeviceRecord.DocumentEntry] = [:]
        for index in 0..<512 {
            macDocuments[.web(normalizedURL: "https://example.com/mac-\(index)")] = .init(
                openedAt: base.addingTimeInterval(Double(index)))
            phoneDocuments[.web(normalizedURL: "https://example.com/phone-\(index)")] = .init(
                openedAt: base.addingTimeInterval(Double(1_000 + index)))
        }
        storage.seed(PositionFixtures.record(.mac, writtenAt: base, documents: macDocuments))
        storage.seed(PositionFixtures.record(.phone, writtenAt: base, documents: phoneDocuments))
        let positions = service(storage: storage)

        let openedByKey = await positions.lastOpenedByWebKey()

        #expect(openedByKey.count == 1_024)
    }

    @Test("Housekeeping uses injected now and position-store last-opened for web eviction")
    func housekeepingUsesInjectedClockAndPositionRecency() async throws {
        try await withScratch { _ in
            _ = try seedSidecar(openedAt: nil, savedAt: nil)
            try Data("snapshot".utf8).write(
                to: WebLibrary.snapshotPath(forKey: WebLibrary.pageKey(pageURL)))
            let previous = UserDefaults.standard.object(forKey: StorageHousekeeping.retentionMonthsKey)
            UserDefaults.standard.removeObject(forKey: StorageHousekeeping.retentionMonthsKey)
            defer {
                if let previous {
                    UserDefaults.standard.set(previous, forKey: StorageHousekeeping.retentionMonthsKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: StorageHousekeeping.retentionMonthsKey)
                }
            }

            _ = await StorageHousekeeping.runCleanup(
                openPdfKeys: [],
                openWebUrls: [],
                now: PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"),
                webLastOpened: { _ in PositionFixtures.date("2026-01-01T09:00:00.000000+00:00") })

            #expect(!FileManager.default.fileExists(
                atPath: WebLibrary.snapshotPath(forKey: WebLibrary.pageKey(pageURL)).path))
        }
    }

    private struct Scratch {
        let root: URL
        let positionsDir: URL
    }

    private func withScratch(_ body: (Scratch) async throws -> Void) async throws {
        let root = PositionFixtures.scratchDirectory("position-wiring")
        let webDir = root.appendingPathComponent("web", isDirectory: true)
        let positionsDir = root.appendingPathComponent("positions", isDirectory: true)
        let previousStore = WebLibrary.storeDirOverride
        let previousRoot = PositionLayout.rootOverride
        WebLibrary.storeDirOverride = webDir
        PositionLayout.rootOverride = positionsDir
        defer {
            WebLibrary.storeDirOverride = previousStore
            PositionLayout.rootOverride = previousRoot
            PositionFixtures.remove(root)
        }
        try await body(Scratch(root: root, positionsDir: positionsDir))
    }

    private func seedSidecar(
        openedAt: String? = "2026-08-01T09:00:00.000000+00:00",
        savedAt: String? = "2026-08-01T09:00:00.000000+00:00"
    ) throws -> URL {
        var record = WebPageRecord(url: pageURL)
        record.title = "Spec #154"
        record.saved = false
        record.savedAt = savedAt
        record.openedAt = openedAt
        let path = WebLibrary.recordPath(forKey: WebLibrary.pageKey(pageURL))
        try WebLibrary.saveRecord(record, at: path)
        return path
    }

    private func writeArchive(url: String, to path: URL) throws {
        let snapshot = "<!doctype html><title>Spec</title><p>Snapshot</p>"
        let pages = try WebArchive.encodePagesJson([])
        let manifest = WebArchive.buildManifest(
            url: url,
            title: "Spec",
            pageCount: 1,
            lastPage: nil,
            loadingPolicy: "live-first",
            snapshotHtml: snapshot,
            pagesJson: pages,
            assets: [],
            assetsSkipped: 0)
        _ = try WebArchive.writeArchive(
            to: path,
            manifest: manifest,
            snapshotHtml: snapshot,
            assets: [],
            pagesJson: pages,
            annotations: [])
    }

    private func archiveReopenWaitsForUrlKey(archiveToOpen: URL) async throws {
        let storage = InMemoryPositionStorage()
        let positions = service(storage: storage)
        let sessions = GatedWebSessionService()
        let workspace = WorkspaceStore(
            sessions: sessions,
            positions: positions)
        let app = workspace.focusedPane.app

        await app.openUrl(pageURL)
        let tabId = try #require(app.activeTabId)
        sessions.holdNextClose()
        await app.closeTab(tabId)
        await sessions.waitUntilCloseHeld()

        let reopen = Task {
            await app.openFile(path: archiveToOpen.path)
        }
        for _ in 0..<10 { await Task.yield() }
        #expect(sessions.openWebDocumentCalls == 1)

        sessions.releaseClose()
        await reopen.value

        #expect(sessions.openWebDocumentCalls == 2)
    }

    private func storedEntry(
        in storage: InMemoryPositionStorage,
        key: DocumentKey
    ) async throws -> PositionDeviceRecord.DocumentEntry {
        let record = try #require(await storage.loadAll().first { $0.deviceID == DeviceIdentity.phone.id })
        return try #require(record.documents[key])
    }
}

@MainActor
private final class StubPositionSessionService: SessionService {
    var openFileInfo: DocumentInfo
    var ensureDocumentIdCalls = 0

    init(openFileInfo: DocumentInfo = DocumentInfo(
        kind: .pdf,
        pdfPath: "/tmp/stub.pdf",
        title: "Stub",
        pageCount: 10,
        lastPage: nil,
        docId: nil)
    ) {
        self.openFileInfo = openFileInfo
    }

    func openFile(path: String, sessionId: String) async throws -> DocumentInfo { openFileInfo }
    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .web, pdfPath: url, title: nil, pageCount: nil, lastPage: nil)
    }
    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .web, pdfPath: path, title: nil, pageCount: nil, lastPage: nil)
    }
    func saveFile(sessionId: String) async throws {}
    func closeFile(sessionId: String) async throws {}
    func readPdfBytes(sessionId: String) async throws -> Data { Data() }
    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}
    func exportVellumweb(
        sessionId: String, destPath: String, pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(path: destPath, bytes: 0, assetCount: 0, assetsSkipped: 0)
    }
    func archiveWebpageDefault(
        sessionId: String, pages: [WebPageText], expectedUrl: String
    ) async throws -> Bool { false }
    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(sessionId: String, input: CreateAnnotationInput) async throws -> Annotation {
        Annotation(
            id: input.id ?? UUID().uuidString,
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color,
            content: input.content,
            positionData: input.positionData,
            createdAt: input.createdAt ?? WebLibrary.rfc3339Now(),
            updatedAt: input.createdAt ?? WebLibrary.rfc3339Now())
    }
    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool { false }
    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String {
        ensureDocumentIdCalls += 1
        return "unexpected"
    }
}

private actor PagePositionGate {
    private let heldPage: Int
    private var isHolding = false
    private var heldContinuations: [CheckedContinuation<Void, Never>] = []
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []

    init(heldPage: Int) {
        self.heldPage = heldPage
    }

    func holdIfNeeded(_ page: Int) async {
        guard page == heldPage else { return }
        isHolding = true
        let arrivals = arrivalContinuations
        arrivalContinuations = []
        for continuation in arrivals { continuation.resume() }
        await withCheckedContinuation { continuation in
            heldContinuations.append(continuation)
        }
    }

    func waitUntilHeld() async {
        if isHolding { return }
        await withCheckedContinuation { continuation in
            arrivalContinuations.append(continuation)
        }
    }

    func release() {
        isHolding = false
        let held = heldContinuations
        heldContinuations = []
        for continuation in held { continuation.resume() }
    }
}

@MainActor
private final class GatedWebSessionService: SessionService {
    private var holdClose = false
    private var heldCloseContinuations: [CheckedContinuation<Void, Never>] = []
    private var arrivalContinuations: [CheckedContinuation<Void, Never>] = []
    private(set) var openWebDocumentCalls = 0

    func holdNextClose() {
        holdClose = true
    }

    func waitUntilCloseHeld() async {
        if !heldCloseContinuations.isEmpty { return }
        await withCheckedContinuation { arrivalContinuations.append($0) }
    }

    func releaseClose() {
        holdClose = false
        let held = heldCloseContinuations
        heldCloseContinuations = []
        for continuation in held { continuation.resume() }
    }

    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: nil, pageCount: 10, lastPage: nil)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        openWebDocumentCalls += 1
        let normalized = try WebUrl.normalize(url)
        return DocumentInfo(
            kind: .web,
            pdfPath: normalized,
            title: nil,
            pageCount: nil,
            lastPage: nil,
            docId: WebLibrary.pageKey(normalized))
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        let manifest = try WebArchive.readManifest(at: URL(fileURLWithPath: path))
        return try await openWebDocument(url: manifest.url, sessionId: sessionId)
    }

    func saveFile(sessionId: String) async throws {}

    func closeFile(sessionId: String) async throws {
        if holdClose {
            holdClose = false
            await withCheckedContinuation { continuation in
                heldCloseContinuations.append(continuation)
                let arrivals = arrivalContinuations
                arrivalContinuations = []
                for arrival in arrivals { arrival.resume() }
            }
        }
    }

    func readPdfBytes(sessionId: String) async throws -> Data { Data() }
    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}
    func exportVellumweb(
        sessionId: String, destPath: String, pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(path: destPath, bytes: 0, assetCount: 0, assetsSkipped: 0)
    }
    func archiveWebpageDefault(
        sessionId: String, pages: [WebPageText], expectedUrl: String
    ) async throws -> Bool { false }
    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(sessionId: String, input: CreateAnnotationInput) async throws -> Annotation {
        Annotation(
            id: input.id ?? UUID().uuidString,
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color,
            content: input.content,
            positionData: input.positionData,
            createdAt: input.createdAt ?? WebLibrary.rfc3339Now(),
            updatedAt: input.createdAt ?? WebLibrary.rfc3339Now())
    }
    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool { false }
    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { false }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String { "unused" }
}
