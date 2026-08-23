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
    var storage: WebLibraryStorage

    init(storage: WebLibraryStorage = WebLibraryStorage()) {
        self.storage = storage
    }

    /// Open (or create) a webpage session for a raw URL. Re-invoking with an
    /// existing session id rebinds that tab to a new URL (in-tab navigation);
    /// the replaced session needs no teardown (web close is a no-op flush).
    func openWebDocument(
        url: String, sessionId: String, replacing: WebDocumentSession?
    ) async throws -> WebDocumentSession {
        // Normalize/hash/path-resolve INSIDE the detached task, not before it.
        // These look like cheap value math but `WebLibrary.recordPath` walks
        // `WebLibrary.activeLayout` -> `WebStorageSettings.effectiveMode` and,
        // for custom-folder users, `WebStorage.customRoot` -> `resolveBookmark`,
        // which hits UserDefaults, FileManager existence checks and
        // `startAccessingSecurityScopedResource`. Doing that on @MainActor put
        // disk work in the launch critical path (restoreTabs opens every
        // persisted web tab during the first frame). All three helpers are
        // nonisolated statics over plain String/URL values, so there is no
        // actor-isolated state here — do NOT hoist them back to the main actor
        // "for convenience".
        let storage = storage
        let opened = try await Task.detached(priority: .userInitiated) {
            let normalized = try WebUrl.normalize(url)

            // Read only: opening a page is reading-position state now, and that
            // lives in PositionStore. Do not rewrite the shared annotation
            // sidecar just because a tab opened.
            let record = await storage.loadRecord(forKey: WebLibrary.pageKey(normalized))
                ?? WebPageRecord(url: normalized)
            return (normalized: normalized, record: record)
        }.value

        return WebDocumentSession(url: opened.normalized, record: opened.record, storage: storage)
    }

    /// Open a `.vellumweb` archive: install its snapshot locally, merge its
    /// annotations into the sidecar, and open the page as a normal web tab
    /// (live-first with automatic snapshot fallback).
    func openVellumwebFile(path: String, sessionId: String) async throws -> WebDocumentSession {
        let archiveUrl = URL(fileURLWithPath: path)
        let imported = try await Task.detached(priority: .userInitiated) {
            try WebArchive.readArchive(at: archiveUrl)
        }.value

        // Install the snapshot (up to 64 MB of assets) and merge annotations
        // off the main thread — this used to block the UI on the main actor.
        // The record merge runs through withRecord (serialized per key) so it
        // can't clobber a concurrent session's write to the same sidecar; the
        // archive install writes to a separate dir so it stays outside the lock.
        //
        // The normalize/pageKey/recordPath prelude lives in here too (see
        // `openWebDocument`): `recordPath` resolves the active storage layout,
        // which for custom-folder users means a security-scoped bookmark
        // resolve + FileManager probes. Those are nonisolated String/URL
        // computations, so keeping them off @MainActor is free — don't move
        // them back out just to have `normalized` in scope for the return.
        let storage = storage
        let opened = try await Task.detached(priority: .userInitiated) {
            let normalized = try WebUrl.normalize(imported.manifest.url)
            let key = WebLibrary.pageKey(normalized)

            try WebArchive.installArchiveDir(
                key: key,
                snapshotHtml: imported.snapshotHtml,
                assets: imported.assets,
                manifest: imported.manifest)

            let record = try await storage.mutateRecord(url: normalized, key: key) { record in
                record.url = normalized

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
            // Carry `normalized` back out: the caller needs it for the session's
            // document identity, and recomputing it on the main actor would undo
            // the point of the hop.
            return (normalized: normalized, record: record)
        }.value

        return WebDocumentSession(url: opened.normalized, record: opened.record, storage: storage)
    }

    func listSavedWebpages() async throws -> [WebLibraryEntry] {
        try await storage.listSaved()
    }

    func removeSavedWebpage(url: String) async throws {
        let normalized = try WebUrl.normalize(url)
        let key = WebLibrary.pageKey(normalized)
        try await storage.mutateRecord(url: normalized, key: key) { record in
            record.saved = false
            record.savedAt = nil
        }
        await storage.removeLocalSnapshots(forKey: key)
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
    private let snapshotPath: URL
    /// DocumentInfo captured at open time (mirrors the Rust command's return).
    private let openInfo: DocumentInfo
    private let io: WebDocumentIO
    private let storage: WebLibraryStorage

    init(url: String, record: WebPageRecord, storage: WebLibraryStorage = WebLibraryStorage()) {
        self.url = url
        self.storage = storage
        key = WebLibrary.pageKey(url)
        snapshotPath = WebLibrary.snapshotPath(forKey: key)
        openInfo = DocumentInfo(
            kind: .web,
            pdfPath: url,
            title: record.title,
            pageCount: record.pageCount,
            lastPage: record.lastPage,
            docId: key)
        io = WebDocumentIO(url: url, key: key, storage: storage)
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

    /// The document identity for a webpage is its sha256 URL-hash key — already
    /// stable across sessions and byte-compatible with the Tauri-era library,
    /// so nothing is stamped or re-keyed.
    func ensureDocumentId() async throws -> String { key }

    // MARK: - Saved-pages library

    func setSaved(_ saved: Bool) async throws {
        try await io.setSaved(saved)
    }

    func isSaved() async throws -> Bool {
        // The toolbar's promise is "Keep Offline", not merely that the page
        // has a Saved-library record. Settings can remove snapshots while
        // retaining that record, so expose offline availability only when a
        // real local/managed snapshot remains.
        let saved = await io.isSaved()
        let hasSnapshot = await storage.hasLocalSnapshot(forKey: key)
        return saved && hasSnapshot
    }

    // MARK: - Archiving

    func exportVellumweb(destPath: String, pages: [WebPageText]) async throws -> VellumwebExportSummary {
        try await writeWebArchive(pages: pages, dest: URL(fileURLWithPath: destPath))
    }

    /// Automatic on-open archiver: writes the managed `.vellumweb` so the page
    /// reloads offline and the AI can read it. Deliberately does NOT mark the
    /// page saved — saving is an explicit user action (toolbar toggle) or an
    /// implicit one (annotating promotes, see `WebDocumentIO.createAnnotation`)
    /// — unless the user opted into Settings ▸ Storage ▸ "Automatically save
    /// every page", which restores the old open-means-keep behavior; artifacts
    /// for never-saved pages are TTL-evicted at launch.
    /// Returns false when the tab navigated away during the debounce.
    func archiveDefault(pages: [WebPageText], expectedUrl: String) async throws -> Bool {
        let expectedNormalized = (try? WebUrl.normalize(expectedUrl)) ?? expectedUrl
        if expectedNormalized != url {
            return false
        }
        let localKey = key
        // Resolve after the record exists (openWebDocument already wrote it),
        // so the pretty filename can come from the page title; do it off-main —
        // it may read the record and touch the index file.
        _ = try await writeManagedWebArchive(pages: pages)
        if WebStorageSettings.autoSavePages {
            let localUrl = url
            try await storage.mutateRecord(url: localUrl, key: localKey) { record in
                guard !record.saved else { return }
                record.saved = true
                record.savedAt = record.savedAt ?? WebLibrary.rfc3339Now()
            }
        }
        return true
    }

    /// Capture the best available snapshot, refresh the installed archive dir,
    /// and write a `.vellumweb` to `dest` atomically. Shared by the explicit
    /// export and the automatic on-open archiver (commands.rs write_web_archive).
    private func writeWebArchive(pages: [WebPageText], dest: URL) async throws -> VellumwebExportSummary {
        try await buildAndWriteWebArchive(pages: pages, destination: .external(dest))
    }

    private enum ArchiveDestination {
        case external(URL)
        case managed
    }

    private func writeManagedWebArchive(pages: [WebPageText]) async throws -> VellumwebExportSummary {
        try await buildAndWriteWebArchive(pages: pages, destination: .managed)
    }

    private func buildAndWriteWebArchive(
        pages: [WebPageText],
        destination: ArchiveDestination
    ) async throws -> VellumwebExportSummary {
        let localKey = key

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
        let record = await storage.loadRecord(forKey: localKey)

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
        let written: (path: String, bytes: Int)
        switch destination {
        case .external(let dest):
            let bytes = try await Task.detached(priority: .userInitiated) {
                try WebArchive.writeArchive(
                    to: dest,
                    manifest: manifest,
                    snapshotHtml: snapshot.html,
                    assets: snapshot.assets,
                    pagesJson: pagesJson,
                    annotations: annotations)
            }.value
            written = (dest.path, bytes)
        case .managed:
            written = try await storage.writeManagedArchive(
                forKey: localKey,
                manifest: manifest,
                snapshotHtml: snapshot.html,
                assets: snapshot.assets,
                pagesJson: pagesJson,
                annotations: annotations)
        }

        return VellumwebExportSummary(
            path: written.path,
            bytes: written.bytes,
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
    private let storage: WebLibraryStorage

    init(url: String, key: String, storage: WebLibraryStorage = WebLibraryStorage()) {
        self.url = url
        self.key = key
        self.storage = storage
    }

    func annotations(pageNumber: Int?) async -> [Annotation] {
        let record = await storage.loadRecord(forKey: key) ?? WebPageRecord(url: url)
        let list: [Annotation]
        if let pageNumber {
            list = record.annotations.filter { $0.pageNumber == pageNumber }
        } else {
            list = record.annotations
        }
        return Annotation.sortedForDisplay(list)
    }

    func createAnnotation(_ input: CreateAnnotationInput, storedHighlightColor: String) async throws -> Annotation {
        let now = WebLibrary.rfc3339Now()
        let defaultColor: String?
        switch input.type {
        case .highlight: defaultColor = storedHighlightColor
        case .note: defaultColor = defaultNoteColor
        case .bookmark: defaultColor = nil
        }
        // iPad optimistic-create echo: honor a client-supplied id/createdAt so
        // the store's optimistic annotation and the persisted record share
        // identity (id) and ordering (createdAt) — no duplicate/flicker on the
        // apply-annotations round-trip. Falls back to server-generated values.
        let createdAt = input.createdAt ?? now
        let annotation = Annotation(
            id: input.id ?? UUID().uuidString.lowercased(),
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color ?? defaultColor,
            content: input.content,
            positionData: input.positionData,
            createdAt: createdAt,
            updatedAt: createdAt)
        try await storage.mutateRecord(url: url, key: key) { record in
            record.annotations.append(annotation)
            // Annotating is user investment: promote the page into the saved
            // library so explicit-save semantics can never strand highlights or
            // notes on a page whose snapshots are eligible for TTL eviction.
            if !record.saved {
                record.saved = true
                record.savedAt = record.savedAt ?? WebLibrary.rfc3339Now()
            }
        }
        return annotation
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async throws -> Bool {
        try await storage.mutateRecord(url: url, key: key) { record in
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
            // iPad fix (main regressed this): persist an updated pageNumber. A
            // web highlight resized across a virtual-page boundary reports its
            // new page; without this the record keeps the stale page and the
            // sidebar/star land on the wrong virtual page after a round-trip.
            if let pageNumber = input.pageNumber {
                record.annotations[index].pageNumber = pageNumber
            }
            if let isPinned = input.isPinned {
                record.annotations[index].isPinned = isPinned
            }
            record.annotations[index].updatedAt = WebLibrary.rfc3339Now()
            return true
        }
    }

    func deleteAnnotation(id: String) async throws -> Bool {
        try await storage.mutateRecord(url: url, key: key) { record in
            let before = record.annotations.count
            record.annotations.removeAll { $0.id == id }
            return record.annotations.count != before
        }
    }

    func setMetadata(key: String, value: String) async throws {
        try await storage.mutateRecord(url: url, key: self.key) { record in
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

    func setSaved(_ saved: Bool) async throws {
        try await storage.mutateRecord(url: url, key: key) { record in
            record.saved = saved
            record.savedAt = saved ? WebLibrary.rfc3339Now() : nil
        }
        if !saved {
            await storage.removeLocalSnapshots(forKey: key)
        }
    }

    func isSaved() async -> Bool {
        await storage.loadRecord(forKey: key)?.saved ?? false
    }
}
