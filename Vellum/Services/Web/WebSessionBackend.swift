import Foundation

// Webpage sessions — port of the session/command half of
// src-tauri/src/web_page.rs and the web commands from commands.rs
// (open_web_document, open_vellumweb_file, archive_webpage_default,
// export_vellumweb, set/get_webpage_saved, annotation CRUD, metadata).
// Annotations live in the per-URL JSON sidecar; every mutation rewrites the
// sidecar immediately, so save/close are no-ops.

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

        var record = WebLibrary.loadRecord(at: recordPath) ?? WebPageRecord(url: normalized)
        record.url = normalized
        record.openedAt = WebLibrary.rfc3339Now()
        try WebLibrary.saveRecord(record, at: recordPath)

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

        var record = WebLibrary.loadRecord(at: recordPath) ?? WebPageRecord(url: normalized)
        record.url = normalized
        record.openedAt = WebLibrary.rfc3339Now()

        try WebArchive.installArchiveDir(
            key: key,
            snapshotHtml: imported.snapshotHtml,
            assets: imported.assets,
            manifest: imported.manifest)

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
        try WebLibrary.saveRecord(record, at: recordPath)

        return WebDocumentSession(url: normalized, record: record)
    }

    func listSavedWebpages() async throws -> [WebLibraryEntry] {
        WebLibrary.listSaved()
    }

    func removeSavedWebpage(url: String) async throws {
        try WebLibrary.removeSaved(rawUrl: url)
    }
}

@MainActor
final class WebDocumentSession: DocumentSession {
    /// Normalized page URL — the document identity.
    let url: String
    private let key: String
    private let recordPath: URL
    private let snapshotPath: URL
    /// DocumentInfo captured at open time (mirrors the Rust command's return).
    private let openInfo: DocumentInfo

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
        let record = WebLibrary.loadRecord(at: recordPath) ?? WebPageRecord(url: url)
        guard let pageNumber else { return record.annotations }
        return record.annotations.filter { $0.pageNumber == pageNumber }
    }

    func createAnnotation(_ input: CreateAnnotationInput) async throws -> Annotation {
        let now = WebLibrary.rfc3339Now()
        let defaultColor: String?
        switch input.type {
        case .highlight: defaultColor = WorkspaceStore.storedDefaultHighlightColor()
        case .note: defaultColor = defaultNoteColor
        case .bookmark: defaultColor = nil
        }
        let id = input.id ?? UUID().uuidString.lowercased()
        let createdAt = input.createdAt ?? now
        let annotation = Annotation(
            id: id,
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color ?? defaultColor,
            content: input.content,
            positionData: input.positionData,
            createdAt: createdAt,
            updatedAt: createdAt)
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            record.annotations.append(annotation)
        }
        return annotation
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
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

    func deleteAnnotation(id: String) async throws -> Bool {
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            let before = record.annotations.count
            record.annotations.removeAll { $0.id == id }
            return record.annotations.count != before
        }
    }

    func setMetadata(key: String, value: String) async throws {
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

    // MARK: - Saved-pages library

    func setSaved(_ saved: Bool) async throws {
        try WebLibrary.withRecord(url: url, recordPath: recordPath) { record in
            record.saved = saved
            record.savedAt = saved ? WebLibrary.rfc3339Now() : nil
        }
        if !saved {
            WebLibrary.removeLocalSnapshots(forKey: key)
        }
    }

    func isSaved() async throws -> Bool {
        WebLibrary.loadRecord(at: recordPath)?.saved ?? false
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
        try WebLibrary.markSavedIfAbsent(recordPath: recordPath, url: url)
        return true
    }

    /// Capture the best available snapshot, refresh the installed archive dir,
    /// and write a `.vellumweb` to `dest` atomically. Shared by the explicit
    /// export and the automatic on-open archiver (commands.rs write_web_archive).
    private func writeWebArchive(pages: [WebPageText], dest: URL) async throws -> VellumwebExportSummary {
        let record = WebLibrary.loadRecord(at: recordPath)

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
        // matches what was just archived.
        try WebArchive.installArchiveDir(
            key: key,
            snapshotHtml: captured.html,
            assets: captured.assets.map { ($0.name, $0.bytes) },
            manifest: manifest)

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
