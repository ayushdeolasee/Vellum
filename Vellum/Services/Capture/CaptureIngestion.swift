import Foundation

/// Resolves the best HTML input before the existing webpage pipeline runs.
/// Safari DOM wins because it includes logged-in/client-rendered state; a URL-
/// only record falls back to the same `WebFetch` path the reader already uses.
struct CapturePageHTML: Sendable, Equatable {
    var html: String
    var baseURL: String
}

enum CaptureLibraryFreshness {
    /// Duplicates are already represented in Home; only a newly durable item
    /// invalidates the snapshot.
    static func shouldRefresh(after report: CaptureDrainReport) -> Bool {
        report.ingested > 0
    }
}

enum CapturePageResolver {
    static func resolve(
        record: CaptureRecord,
        normalizedURL: String,
        fetch: @Sendable (String) async throws -> CapturePageHTML
    ) async throws -> CapturePageHTML {
        if let html = record.outerHTML {
            return CapturePageHTML(html: html, baseURL: normalizedURL)
        }

        return try await fetch(normalizedURL)
    }
}

/// App-only owner of the idempotent App Group drain. Nothing in this file is
/// linked into `VellumShare`; all fetch, asset capture, archive creation, and
/// storage-location routing therefore happen in the containing app.
actor CaptureIngestion {
    typealias Fetch = @Sendable (String) async throws -> CapturePageHTML
    typealias Snapshot = @Sendable (String, String) async -> CapturedSnapshot
    typealias LibraryDidChange = @MainActor @Sendable () -> Void

    private let inbox: CaptureInbox
    private let storage: WebLibraryStorage
    private let unreadLedger: CapturedUnreadLedger
    private let syncEnabled: Bool
    private let fetch: Fetch
    private let snapshot: Snapshot
    private let libraryDidChange: LibraryDidChange
    private var drainTask: Task<CaptureDrainReport, Never>?
    private var drainGeneration = 0
    private var recoveryTasks: [UUID: Task<Void, Never>] = [:]
    private var acceptsIngestion = true

    init(
        layout: CaptureInboxLayout,
        storage: WebLibraryStorage,
        clock: PositionClock = SystemPositionClock(),
        unreadLedger: CapturedUnreadLedger = .shared,
        syncEnabled: Bool = RuntimeProfile.current.syncEnabled,
        fetch: @escaping Fetch = { url in
            switch try await WebFetch.fetchPage(url) {
            case .html(let html, let finalURL):
                return CapturePageHTML(
                    html: html,
                    baseURL: (try? WebUrl.normalize(finalURL)) ?? url)
            case .other:
                throw SessionServiceError.invalidDocument(
                    "The shared URL is not an HTML webpage")
            }
        },
        snapshot: @escaping Snapshot = { pageURL, html in
            await WebArchive.captureSnapshot(pageUrl: pageURL, rawHtml: html)
        },
        libraryDidChange: @escaping LibraryDidChange = {
            NotificationCenter.default.post(name: .vellumCapturedLibraryChanged, object: nil)
        }
    ) {
        inbox = CaptureInbox(layout: layout, clock: clock)
        self.storage = storage
        self.unreadLedger = unreadLedger
        self.syncEnabled = syncEnabled
        self.fetch = fetch
        self.snapshot = snapshot
        self.libraryDidChange = libraryDidChange
    }

    @discardableResult
    func drain() async -> CaptureDrainReport {
        guard syncEnabled else { return CaptureDrainReport() }
        guard acceptsIngestion else { return CaptureDrainReport(retained: await inbox.pendingCount()) }
        if let drainTask {
            return await drainTask.value
        }
        let storage = storage
        let unreadLedger = unreadLedger
        let fetch = fetch
        let snapshot = snapshot
        let libraryDidChange = libraryDidChange
        let inbox = inbox
        drainGeneration += 1
        let generation = drainGeneration
        let task = Task {
            guard !Task.isCancelled else { return CaptureDrainReport(retained: await inbox.pendingCount()) }
            return await inbox.drain { record, key in
                try await Self.ingest(
                    record: record, key: key, storage: storage, unreadLedger: unreadLedger,
                    fetch: fetch, snapshot: snapshot)
            }
        }
        drainTask = task
        let report = await task.value
        if generation == drainGeneration {
            drainTask = nil
        }
        if CaptureLibraryFreshness.shouldRefresh(after: report) {
            await libraryDidChange()
        }
        return report
    }

    /// Backgrounding stops new network work but keeps every unsaved intent.
    /// Foreground/wake triggers join this cancellation before restarting a drain.
    func prepareForBackground() async {
        acceptsIngestion = false
        drainTask?.cancel()
        await inbox.cancelAndJoinDrain()
        await awaitPendingOperations()
    }

    func resume() async {
        await awaitPendingOperations()
        acceptsIngestion = true
    }

    func recoveryEntries() async throws -> [CaptureInbox.RecoveryEntry] {
        try await inbox.recoveryEntries()
    }

    func retry(_ entry: CaptureInbox.RecoveryEntry) async throws -> CaptureDrainReport {
        guard syncEnabled else { throw CaptureInboxError.io("Capture saving is disabled in this session.") }
        return try await performRecovery { [self] in
            try await inbox.retry(entry)
            return await drain()
        }
    }

    func delete(_ entry: CaptureInbox.RecoveryEntry) async throws {
        try await performRecovery { [inbox] in try await inbox.delete(entry) }
    }

    func export(_ entry: CaptureInbox.RecoveryEntry) async throws -> URL {
        try await performRecovery { [inbox] in try await inbox.export(entry) }
    }

    /// A recovery sheet can disappear while its operation runs. The service
    /// retains every handle so lifecycle code and tests can still join it.
    private func performRecovery<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let task = Task { try await operation() }
        recoveryTasks[id] = Task { _ = try? await task.value }
        defer { recoveryTasks[id] = nil }
        return try await task.value
    }

    func awaitPendingOperations() async {
        while drainTask != nil || !recoveryTasks.isEmpty {
            let tasks = Array(recoveryTasks.values)
            _ = await drainTask?.value
            for task in tasks { await task.value }
            await Task.yield()
        }
    }

    private static func ingest(
        record: CaptureRecord,
        key: DocumentKey,
        storage: WebLibraryStorage,
        unreadLedger: CapturedUnreadLedger,
        fetch: Fetch,
        snapshot: Snapshot
    ) async throws -> CaptureIngestOutcome {
        try Task.checkCancellation()
        let normalizedURL = try WebUrl.normalize(record.sourceURL)

        if let existing = await storage.loadRecord(forKey: key.hash),
           existing.saved,
           await storage.hasLocalSnapshot(forKey: key.hash) {
            // Reaching this branch while an inbox record is still pending can
            // mean the previous attempt crashed after committing `saved = true`
            // but before recording the device-local New marker. Ensuring it here
            // is idempotent. Once this returns, `CaptureInbox` consumes the
            // record, so later opens/other drains cannot re-arm an already
            // consumed capture.
            await unreadLedger.markUnread(forKey: key.hash)
            return .alreadyPresent(key)
        }

        let page = try await CapturePageResolver.resolve(
            record: record, normalizedURL: normalizedURL, fetch: fetch)
        let captured = await snapshot(page.baseURL, page.html)
        try Task.checkCancellation()
        let pagesJSON = try WebArchive.encodePagesJson([])
        let existing = await storage.loadRecord(forKey: key.hash)
        let title = normalizedTitle(record.title) ?? existing?.title
        let annotations = existing?.annotations ?? []
        let manifest = WebArchive.buildManifest(
            url: normalizedURL,
            title: title,
            pageCount: existing?.pageCount,
            lastPage: existing?.lastPage,
            loadingPolicy: "live-first",
            snapshotHtml: captured.html,
            pagesJson: pagesJSON,
            assets: captured.assets,
            assetsSkipped: captured.skipped)

        // The managed archive is the durable commit. The derived installed
        // snapshot may land first, but the sidecar isn't marked saved until the
        // managed write succeeds, so a failed attempt remains retryable.
        try WebArchive.installArchiveDir(
            key: key.hash,
            snapshotHtml: captured.html,
            assets: captured.assets.map { ($0.name, $0.bytes) },
            manifest: manifest)
        _ = try await storage.writeManagedArchive(
            forKey: key.hash,
            manifest: manifest,
            snapshotHtml: captured.html,
            assets: captured.assets,
            pagesJson: pagesJSON,
            annotations: annotations)
        try await storage.mutateRecord(url: normalizedURL, key: key.hash) { pageRecord in
            pageRecord.title = title
            pageRecord.saved = true
            pageRecord.savedAt = pageRecord.savedAt ?? record.capturedAt
        }
        // Only the fully durable path is new. Failed captures and duplicates do
        // not create or re-arm a badge.
        await unreadLedger.markUnread(forKey: key.hash)
        return .ingested(key)
    }

    private static func normalizedTitle(_ title: String?) -> String? {
        let value = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}
