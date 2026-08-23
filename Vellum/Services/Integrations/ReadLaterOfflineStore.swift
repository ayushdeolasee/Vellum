import Foundation
import PDFKit

// Where a read-later item's OFFLINE BYTES live, and the four things the
// prefetcher needs to ask about them: are they here, put them here, is this
// item exempt from retention, delete them.
//
// Nothing new is invented per kind. A PDF goes through the sync engine's own
// download plumbing (byte cap, revision-guarded reuse, generation checks,
// per-item dedup); a page goes through the same fetch → capture → install
// sequence `WebSessionBackend.archiveDefault` runs when a tab is opened. The
// only new thing is that they now run BEFORE the user opens the item.

protocol ReadLaterOfflineStoring: Sendable {
    /// A current offline copy exists (revision-checked for PDFs).
    func hasOfflineCopy(for item: ReadLaterItem) async -> Bool
    /// Downloads and installs the offline copy. Returns its size in bytes.
    func storeOfflineCopy(for item: ReadLaterItem) async throws -> Int
    /// The user has annotated (or explicitly kept) this item, so retention must
    /// never touch it. This is the read-later end of the annotated-pages-exempt
    /// housekeeping rule.
    func isExempt(_ item: ReadLaterItem) async -> Bool
    /// Deletes the offline copy. `false` means "still there" — the ledger keeps
    /// tracking the item so a later sweep can try again.
    func removeOfflineCopy(for item: ReadLaterItem, openDocumentPaths: Set<String>) async -> Bool
    /// Best-effort delete for an item that left the queue. Provider/vendor id
    /// locates PDFs; the optional persisted source URL locates article archives.
    func removeOfflineCopy(
        forItemID itemID: String,
        sourceURL: String?,
        openDocumentPaths: Set<String>
    ) async -> Bool
}

struct IntegrationsOfflineStore: ReadLaterOfflineStoring {
    private let engine: IntegrationsSyncEngine
    private let storage: WebLibraryStorage

    init(
        engine: IntegrationsSyncEngine,
        storage: WebLibraryStorage = WebLibraryStorage()
    ) {
        self.engine = engine
        self.storage = storage
    }

    // MARK: - Presence

    func hasOfflineCopy(for item: ReadLaterItem) async -> Bool {
        switch item.kind {
        case .pdf:
            return await engine.existingRoute(for: item) != nil
        case .article:
            guard let key = Self.pageKey(for: item) else { return false }
            return await storage.hasLocalSnapshot(forKey: key)
        case .epub, .video, .other:
            return false
        }
    }

    // MARK: - Storing

    func storeOfflineCopy(for item: ReadLaterItem) async throws -> Int {
        switch item.kind {
        case .pdf:
            // The engine's own download path: honours `maximumPDFBytes`,
            // validates the payload really is a PDF, dedupes against an open
            // that started first, and refuses to install across a disconnect.
            guard case .file(let url) = try await engine.prefetch(item) else {
                throw IntegrationError.notPDF
            }
            return Self.fileSize(at: url)
        case .article:
            return try await storePage(item)
        case .epub, .video, .other:
            throw IntegrationError.unsupportedDestination
        }
    }

    /// Headless version of the on-open archiver: fetch, capture subresources,
    /// install the snapshot directory the reader falls back to when the network
    /// is gone, and make sure the page has a sidecar so annotations made later
    /// have somewhere to land. Never marks the page `saved` — that is a user
    /// action, and a prefetched page the user never reads must stay evictable.
    private func storePage(_ item: ReadLaterItem) async throws -> Int {
        let address = item.sourceURL.absoluteString
        let normalized = try WebUrl.normalize(address)
        let key = WebLibrary.pageKey(normalized)
        guard case .html(let html, let finalUrl) = try await WebFetch.fetchPage(normalized) else {
            throw SessionServiceError.invalidDocument(
                "This link is not a web page Vellum can archive")
        }
        // Resolve relative asset URLs against where the page actually came
        // from (after redirects), exactly as the on-open archiver does.
        let base = (try? WebUrl.normalize(finalUrl)) ?? normalized
        let captured = await WebArchive.captureSnapshot(pageUrl: base, rawHtml: html)
        let title = item.title
        let pagesJson = try WebArchive.encodePagesJson([])
        let manifest = WebArchive.buildManifest(
            url: normalized,
            title: title,
            pageCount: nil,
            lastPage: nil,
            loadingPolicy: "live-first",
            snapshotHtml: captured.html,
            pagesJson: pagesJson,
            assets: captured.assets,
            assetsSkipped: captured.skipped)
        let assets = captured.assets.map { ($0.name, $0.bytes) }
        let snapshotHtml = captured.html
        try await Task.detached(priority: .utility) {
            try WebArchive.installArchiveDir(
                key: key, snapshotHtml: snapshotHtml, assets: assets, manifest: manifest)
        }.value
        // A record, but NOT a saved one: the sidecar is where a later
        // highlight is written, and its existence is what lets the exemption
        // check below see that highlight.
        try? await storage.mutateRecord(url: normalized, key: key) { record in
            record.url = normalized
            if record.title == nil { record.title = title }
        }
        return Int(await storage.snapshotArtifactsSize(forKey: key))
    }

    // MARK: - Exemption

    func isExempt(_ item: ReadLaterItem) async -> Bool {
        switch item.kind {
        case .article:
            guard let key = Self.pageKey(for: item) else { return false }
            let record: WebPageRecord?
            do {
                record = try await storage.loadRecordStrict(forKey: key)
            } catch {
                return true
            }
            guard let record else { return false }
            // `saved` counts as well as annotations: "Keep Offline" is the
            // user saying keep it, and annotating promotes to saved anyway.
            return record.saved || !record.annotations.isEmpty
        case .pdf:
            guard case .file(let url)? = await engine.existingRoute(for: item) else { return false }
            return await Task.detached(priority: .utility) {
                Self.pdfHasAnnotations(at: url)
            }.value
        case .epub, .video, .other:
            return false
        }
    }

    // MARK: - Deleting

    func removeOfflineCopy(
        for item: ReadLaterItem, openDocumentPaths: Set<String>
    ) async -> Bool {
        switch item.kind {
        case .pdf:
            guard case .file(let url)? = await engine.existingRoute(for: item) else {
                return false
            }
            let hasAnnotations = await Task.detached(priority: .utility) {
                Self.pdfHasAnnotations(at: url)
            }.value
            guard !hasAnnotations else { return false }
            return await engine.removeDownloadedCopy(
                for: item, openDocumentPaths: openDocumentPaths)
        case .article:
            guard let key = Self.pageKey(for: item),
                let normalized = try? WebUrl.normalize(item.sourceURL.absoluteString)
            else { return false }
            guard !openDocumentPaths.contains(normalized) else { return false }
            // Defensive second gate. The prefetcher reconciles exemptions
            // immediately before every sweep, so an annotated page should
            // never reach this line; if one does, refusing keeps it tracked.
            let record: WebPageRecord?
            do {
                record = try await storage.loadRecordStrict(forKey: key)
            } catch {
                return false
            }
            if let record,
               record.saved || !record.annotations.isEmpty {
                return false
            }
            await storage.removeLocalSnapshots(forKey: key)
            return !(await storage.hasLocalSnapshot(forKey: key))
        case .epub, .video, .other:
            return true
        }
    }

    /// The item is gone from the queue (deleted at the provider). PDFs are
    /// addressed by provider/vendor id; article entries persist their normalized
    /// source URL in the retention ledger so this path can reconstruct the
    /// URL-derived archive key. Old article entries without that locator stay
    /// tracked rather than claiming bytes were removed when they were not.
    func removeOfflineCopy(
        forItemID itemID: String,
        sourceURL: String?,
        openDocumentPaths: Set<String>
    ) async -> Bool {
        // Legacy article rows without a source locator cannot prove their
        // URL-keyed bytes were removed. Start false and report success only for
        // an artifact we actually located (article URL and/or PDF id).
        var removedLocatedArtifact = false
        if let sourceURL {
            guard let normalized = try? WebUrl.normalize(sourceURL),
                !openDocumentPaths.contains(normalized)
            else { return false }
            let key = WebLibrary.pageKey(normalized)
            let record: WebPageRecord?
            do {
                record = try await storage.loadRecordStrict(forKey: key)
            } catch {
                return false
            }
            if let record,
               record.saved || !record.annotations.isEmpty {
                return false
            }
            await storage.removeLocalSnapshots(forKey: key)
            removedLocatedArtifact = !(await storage.hasLocalSnapshot(forKey: key))
            guard removedLocatedArtifact else { return false }
        }

        guard let separator = itemID.firstIndex(of: ":") else {
            return removedLocatedArtifact
        }
        let providerID = String(itemID[itemID.startIndex..<separator])
        let vendorID = String(itemID[itemID.index(after: separator)...])
        guard let provider = IntegrationProvider(rawValue: providerID), !vendorID.isEmpty else {
            return removedLocatedArtifact
        }
        guard let pdfURL = await engine.downloadedCopyURL(
            provider: provider, itemID: vendorID)
        else { return removedLocatedArtifact }
        guard !openDocumentPaths.contains(pdfURL.path) else { return false }
        let hasAnnotations = await Task.detached(priority: .utility) {
            Self.pdfHasAnnotations(at: pdfURL)
        }.value
        guard !hasAnnotations else { return false }
        return await engine.removeDownloadedCopyIfPresent(
            provider: provider, itemID: vendorID, openDocumentPaths: openDocumentPaths)
    }

    // MARK: - Helpers

    static func pageKey(for item: ReadLaterItem) -> String? {
        guard let normalized = try? WebUrl.normalize(item.sourceURL.absoluteString) else {
            return nil
        }
        return WebLibrary.pageKey(normalized)
    }

    private static func fileSize(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Any annotation on any page counts — including ones made in another
    /// reader. Retention's job is to avoid deleting work, not to adjudicate
    /// whose work it was.
    private static func pdfHasAnnotations(at url: URL) -> Bool {
        guard let document = PDFDocument(url: url) else { return false }
        for index in 0..<document.pageCount {
            if let page = document.page(at: index), !page.annotations.isEmpty { return true }
        }
        return false
    }
}
