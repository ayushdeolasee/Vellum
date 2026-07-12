import Foundation

// Webpage sessions — port of the session/command half of
// src-tauri/src/web_page.rs and the web commands from commands.rs
// (open_web_document, open_vellumweb_file, archive_webpage_default,
// export_vellumweb, set/get_webpage_saved, annotation CRUD, metadata).
// Annotations live in the per-URL JSON sidecar; every mutation rewrites the
// sidecar immediately, so save/close are no-ops.
//
// Sidecar CRUD runs on a per-session `WebDocumentIO` actor (off the main
// thread, serialized per document); the archive install/read paths hop to
// detached tasks. The earlier port pinned the whole @MainActor session to
// synchronous JSON read-modify-write + up-to-64 MB archive installs, freezing
// the UI during note edits — the same bug the PDF backend had.

private let defaultNoteColor = "#fde68a"

@MainActor
final class WebSessionBackend {
    /// Open (or create) a webpage session for a raw URL. Re-invoking with an
    /// existing session id rebinds that tab to a new URL (in-tab navigation);
    /// the replaced session needs no teardown (web close is a no-op flush).
    func openWebDocument(
        url: String, sessionId: String, replacing: WebDocumentSession?
    ) async throws -> WebDocumentSession {
        let normalized = try WebUrl.normalize(url)
        let key = WebLibrary.pageKey(normalized)
        let recordPath = WebLibrary.recordPath(forKey: key)

        // Read + touch + rewrite the sidecar off the main thread, serialized per
        // key via withRecord so a concurrent session for the same page can't
        // clobber this open (or vice versa).
        let record = try await Task.detached(priority: .userInitiated) {
            try WebLibrary.withRecord(url: normalized, recordPath: recordPath) { record in
                record.url = normalized
                record.openedAt = WebLibrary.rfc3339Now()
                return record
            }
        }.value

        return WebDocumentSession(url: normalized, record: record)
    }

    /// Open a `.vellumweb` archive: install its snapshot locally, merge its
    /// annotations into the sidecar, and open the page as a normal web tab
    /// (live-first with automatic snapshot fallback).
    func openVellumwebFile(path: String, sessionId: String) async throws -> WebDocumentSession {
        let archiveUrl = URL(fileURLWithPath: path)
        let imported = try await Task.detached(priority: .userInitiated) {
            try WebArchive.readArchive(at: archiveUrl)
        }.value

        let normalized = try WebUrl.normalize(imported.manifest.url)
        let key = WebLibrary.pageKey(normalized)
        let recordPath = WebLibrary.recordPath(forKey: key)

        // Install the snapshot (up to 64 MB of assets) and merge annotations
        // off the main thread — this used to block the UI on the main actor.
        // The record merge runs through withRecord (serialized per key) so it
        // can't clobber a concurrent session's write to the same sidecar; the
        // archive install writes to a separate dir so it stays outside the lock.
        let record = try await Task.detached(priority: .userInitiated) {
            try WebArchive.installArchiveDir(
                key: key,
                snapshotHtml: imported.snapshotHtml,
                assets: imported.assets,
                manifest: imported.manifest)

            return try WebLibrary.withRecord(url: normalized, recordPath: recordPath) { record in
                record.url = normalized
                record.openedAt = WebLibrary.rfc3339Now()

                // Merge archive metadata without clobbering local reading state.
                if record.title == nil {
                    record.title = imported.manifest.title
                }
                if record.pageCount == nil {
                    record.pageCount = imported.manifest.pageCount
                }
                if record.lastPage == nil {
                    record.lastPage = imported.manifest.lastPage
                }
                if imported.manifest.loadingPolicy == "snapshot-only" {
                    record.loadingPolicy = "snapshot-only"
                }
                record.saved = true
                if record.savedAt == nil {
                    record.savedAt = WebLibrary.rfc3339Now()
                }
                WebArchive.mergeAnnotations(&record.annotations, incoming: imported.annotations)
                return record
            }
        }.value

        return WebDocumentSession(url: normalized, record: record)
    }

    func listSavedWebpages() async throws -> [WebLibraryEntry] {
        await Task.detached(priority: .userInitiated) {
            WebLibrary.listSaved()
        }.value
    }

    func removeSavedWebpage(url: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try WebLibrary.removeSaved(rawUrl: url)
        }.value
    }
}

/// Thin @MainActor facade satisfying the @MainActor `DocumentSession` protocol.
/// Sidecar CRUD delegates to the background `WebDocumentIO` actor; the archive
/// writer keeps its existing async shape but hops its two synchronous disk
/// operations (record load, archive install) off the main thread.
@MainActor
final class WebDocumentSession: DocumentSession {
    /// Normalized page URL — the document identity.
    let url: String
    private let key: String
    private let recordPath: URL
    private let snapshotPath: URL
    /// DocumentInfo captured at open time (mirrors the Rust command's return).
    private let openInfo: DocumentInfo
    private let io: WebDocumentIO

    init(url: String, record: WebPageRecord) {
        self.url = url
        key = WebLibrary.pageKey(url)
        recordPath = WebLibrary.recordPath(forKey: key)
        snapshotPath = WebLibrary.snapshotPath(forKey: key)
        openInfo = DocumentInfo(
            kind: .web,
            pdfPath: url,
            title: record.title,
            pageCount: record.pageCount,
            lastPage: record.lastPage)
        io = WebDocumentIO(url: url, key: key, recordPath: recordPath)
    }

    var info: DocumentInfo { openInfo }

    // MARK: - Lifecycle

    /// No-op: webpage mutations are written to the sidecar immediately.
    func save() async throws {}

    /// No-op flush.
    func close() async throws {}

    func readPdfBytes() async throws -> Data {
        throw SessionServiceError.invalidDocument("This tab is a webpage, not a PDF")
    }

    // MARK: - Annotations (sidecar CRUD)

    func annotations(pageNumber: Int?) async throws -> [Annotation] {
        await io.annotations(pageNumber: pageNumber)
    }

    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        // UserDefaults read stays on the main actor; pass the resolved default in.
        try await io.createAnnotation(input, storedHighlightColor: WorkspaceStore.storedDefaultHighlightColor())
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        try await io.updateAnnotation(input)
    }

    func deleteAnnotation(id: String) async throws -> Bool {
        try await io.deleteAnnotation(id: id)
    }

    func setMetadata(key: String, value: String) async throws {
        try await io.setMetadata(key: key, value: value)
    }

    // MARK: - Saved-pages library

    func setSaved(_ saved: Bool) async throws {
        try await io.setSaved(saved)
    }

    func isSaved() async throws -> Bool {
        await io.isSaved()
    }

    // MARK: - Archiving

    func exportVellumweb(destPath: String, pages: [WebPageText]) async throws -> VellumwebExportSummary {
        try await writeWebArchive(pages: pages, dest: URL(fileURLWithPath: destPath))
    }

    /// Automatic on-open archiver: writes the managed `.vellumweb` and marks
    /// the record saved-if-absent so opened pages land in the library.
    /// Returns false when the tab navigated away during the debounce.
    func archiveDefault(pages: [WebPageText], expectedUrl: String) async throws -> Bool {
        let expectedNormalized = (try? WebUrl.normalize(expectedUrl)) ?? expectedUrl
        if expectedNormalized != url {
            return false
        }
        let dest = WebLibrary.managedArchivePath(forKey: key)
        _ = try await writeWebArchive(pages: pages, dest: dest)
        try await io.markSavedIfAbsent()
        return true
    }

    /// Capture the best available snapshot, refresh the installed archive dir,
    /// and write a `.vellumweb` to `dest` atomically. Shared by the explicit
    /// export and the automatic on-open archiver (commands.rs write_web_archive).
    private func writeWebArchive(pages: [WebPageText], dest: URL) async throws -> VellumwebExportSummary {
        let localKey = key
        let localRecordPath = recordPath

        // Best available snapshot: live capture > installed archive dir >
        // plain saved snapshot (assets skipped when offline).
        let captured: CapturedSnapshot
        if case .html(let html, let finalUrl)? = try? await WebFetch.fetchPage(url) {
            // Resolve relative asset URLs against where the page actually
            // came from (after redirects), not the requested URL.
            let base = (try? WebUrl.normalize(finalUrl)) ?? url
            captured = await WebArchive.captureSnapshot(pageUrl: base, rawHtml: html)
        } else if let installed = WebArchive.loadArchiveDir(key: key) {
            captured = CapturedSnapshot(
                html: installed.html,
                assets: installed.assets.map { name, bytes in
                    CapturedAsset(
                        name: name,
                        url: "",
                        contentType: WebArchive.contentTypeForName(name),
                        bytes: bytes)
                },
                skipped: 0)
        } else if let html = try? String(contentsOf: snapshotPath, encoding: .utf8) {
            captured = await WebArchive.captureSnapshot(pageUrl: url, rawHtml: html)
        } else {
            throw SessionServiceError.invalidDocument(
                "The page could not be fetched and no local snapshot exists yet")
        }

        let pagesJson = try WebArchive.encodePagesJson(pages)

        // Load the record only now — after the fetch/snapshot capture above — so
        // annotation edits made during that window are included in the archive.
        let record = await Task.detached(priority: .userInitiated) {
            WebLibrary.loadRecord(at: localRecordPath)
        }.value

        var pageCount = record?.pageCount
        if !pages.isEmpty {
            pageCount = pages.count
        }
        let annotations = record?.annotations ?? []

        let manifest = WebArchive.buildManifest(
            url: url,
            title: record?.title,
            pageCount: pageCount,
            lastPage: record?.lastPage,
            loadingPolicy: "live-first",
            snapshotHtml: captured.html,
            pagesJson: pagesJson,
            assets: captured.assets,
            assetsSkipped: captured.skipped)

        // Refresh the local self-contained snapshot so offline fallback
        // matches what was just archived — off the main thread (can be tens of MB).
        let installHtml = captured.html
        let installAssets = captured.assets.map { ($0.name, $0.bytes) }
        let installManifest = manifest
        try await Task.detached(priority: .userInitiated) {
            try WebArchive.installArchiveDir(
                key: localKey,
                snapshotHtml: installHtml,
                assets: installAssets,
                manifest: installManifest)
        }.value

        let assetCount = captured.assets.count
        let assetsSkipped = captured.skipped
        let snapshot = captured
        let bytes = try await Task.detached(priority: .userInitiated) {
            try WebArchive.writeArchive(
                to: dest,
                manifest: manifest,
                snapshotHtml: snapshot.html,
                assets: snapshot.assets,
                pagesJson: pagesJson,
                annotations: annotations)
        }.value

        return VellumwebExportSummary(
            path: dest.path,
            bytes: bytes,
            assetCount: assetCount,
            assetsSkipped: assetsSkipped)
    }
}

// MARK: - Background sidecar engine

/// Owns the per-URL JSON sidecar CRUD for one open webpage. Being an `actor`,
/// its read-modify-write work runs off the main thread and is serialized per
/// session, so rapid note edits can't clobber each other's writes.
actor WebDocumentIO {
    let url: String
    let key: String
    let recordPath: URL

    init(url: String, key: String, recordPath: URL) {
        self.url = url
        self.key = key
        self.recordPath = recordPath
    }

    func annotations(pageNumber: Int?) -> [Annotation] {
        let record = WebLibrary.loadRecord(at: recordPath) ?? WebPageRecord(url: url)
        guard let pageNumber else { return record.annotations }
        return record.annotations.filter { $0.pageNumber == pageNumber }
    }

    func createAnnotation(_ input: CreateAnnotationInput, storedHighlightColor: String) throws -> Annotation {
        let now = WebLibrary.rfc3339Now()
        let defaultColor: String?
        switch input.type {
        case .highlight: defaultColor = storedHighlightColor
        case .note: defaultColor = defaultNoteColor
        case .bookmark: defaultColor = nil
        }
        let annotation = Annotation(
            id: input.id ?? UUID().uuidString.lowercased(),
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color ?? defaultColor,
            content: input.content,
            positionData: input.positionData,
            createdAt: now,
            updatedAt: now)
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            record.annotations.append(annotation)
        }
        return annotation
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) throws -> Bool {
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            guard let index = record.annotations.firstIndex(where: { $0.id == input.id }) else {
                return false
            }
            if let color = input.color {
                record.annotations[index].color = color
            }
            if let content = input.content {
                record.annotations[index].content = content
            }
            if let positionData = input.positionData {
                record.annotations[index].positionData = positionData
            }
            record.annotations[index].updatedAt = WebLibrary.rfc3339Now()
            return true
        }
    }

    func deleteAnnotation(id: String) throws -> Bool {
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            let before = record.annotations.count
            record.annotations.removeAll { $0.id == id }
            return record.annotations.count != before
        }
    }

    func setMetadata(key: String, value: String) throws {
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            switch key {
            case "title":
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    record.title = trimmed
                }
            case "page_count":
                record.pageCount = UInt32(value).map(Int.init)
            case "last_page":
                record.lastPage = UInt32(value).map(Int.init)
            default:
                break
            }
        }
    }

    func setSaved(_ saved: Bool) throws {
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            record.saved = saved
            record.savedAt = saved ? WebLibrary.rfc3339Now() : nil
        }
        if !saved {
            WebLibrary.removeLocalSnapshots(forKey: key)
        }
    }

    func isSaved() -> Bool {
        WebLibrary.loadRecord(at: recordPath)?.saved ?? false
    }

    func markSavedIfAbsent() throws {
        try WebLibrary.markSavedIfAbsent(recordPath: recordPath, url: url)
    }
}
