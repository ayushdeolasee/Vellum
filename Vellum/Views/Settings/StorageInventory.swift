import Foundation

// Joins the three storage sources the design's §8 per-document list unions —
// `documents/<key>/` folders, extracted-text-cache entries, and web-snapshot
// records — into one row per storage key. Pure value transform: it takes the
// already-listed arrays (each gathered off-main by its own store) and merges
// them, so it is trivially testable and never touches disk itself.
enum StorageInventory {
    /// One logical document as the Storage pane shows it: a title/kind/recency
    /// header plus the four size buckets (notes+attachments, chat, text cache,
    /// web archive) that each get their own delete control. `sourceExists`
    /// drives the orphans section — false only for a PDF whose file has moved.
    struct DocumentRow: Identifiable, Sendable, Equatable {
        var key: String
        var title: String
        var kind: DocumentKind
        var lastOpened: Date?
        var sourceExists: Bool
        var sourcePath: String?
        var isDocIdKeyed: Bool

        var notesBytes: Int64
        var conversationBytes: Int64
        var cacheBytes: Int64
        var archiveBytes: Int64

        var id: String { key }

        var totalBytes: Int64 { notesBytes + conversationBytes + cacheBytes + archiveBytes }
        var hasNotes: Bool { notesBytes > 0 }
        var hasConversation: Bool { conversationBytes > 0 }
        var hasCache: Bool { cacheBytes > 0 }
        var hasArchive: Bool { archiveBytes > 0 }
    }

    enum SortOrder: String, CaseIterable, Sendable {
        case size
        case lastOpened

        var label: String {
            switch self {
            case .size: return "Size"
            case .lastOpened: return "Last opened"
            }
        }
    }

    /// Union the three sources by storage key. Rows with no on-disk footprint
    /// (a meta-only folder, say) are dropped — the list is a size drill-down, so
    /// a zero-byte document is noise. Sort is applied last.
    static func joinRows(
        documents: [DocumentDataStore.DocumentDataEntry],
        cacheEntries: [PageTextCacheEntry],
        webEntries: [WebLibrary.SnapshotStorageEntry],
        sort: SortOrder = .size
    ) -> [DocumentRow] {
        var docByKey: [String: DocumentDataStore.DocumentDataEntry] = [:]
        for entry in documents { docByKey[entry.key] = entry }
        var cacheByKey: [String: PageTextCacheEntry] = [:]
        for entry in cacheEntries { cacheByKey[entry.pathKey] = entry }
        var webByKey: [String: WebLibrary.SnapshotStorageEntry] = [:]
        for entry in webEntries { webByKey[entry.key] = entry }

        let keys = Set(docByKey.keys).union(cacheByKey.keys).union(webByKey.keys)
        var rows: [DocumentRow] = []
        for key in keys {
            let doc = docByKey[key]
            let cache = cacheByKey[key]
            let web = webByKey[key]

            let notesBytes = doc?.notesBytes ?? 0
            let conversationBytes = doc?.conversationBytes ?? 0
            let cacheBytes = cache?.byteSize ?? 0
            let archiveBytes = web?.byteSize ?? 0
            guard notesBytes + conversationBytes + cacheBytes + archiveBytes > 0 else { continue }

            let kind = resolveKind(doc: doc, web: web)
            rows.append(DocumentRow(
                key: key,
                title: resolveTitle(doc: doc, cache: cache, web: web, kind: kind),
                kind: kind,
                lastOpened: resolveLastOpened(doc: doc, cache: cache, web: web),
                sourceExists: resolveSourceExists(doc: doc, cache: cache, web: web, kind: kind),
                sourcePath: doc?.meta?.lastKnownPath ?? cache?.sourcePath ?? web?.url,
                isDocIdKeyed: kind == .web || isLikelyDocId(key),
                notesBytes: notesBytes,
                conversationBytes: conversationBytes,
                cacheBytes: cacheBytes,
                archiveBytes: archiveBytes))
        }
        return sorted(rows, by: sort)
    }

    static func sorted(_ rows: [DocumentRow], by sort: SortOrder) -> [DocumentRow] {
        switch sort {
        case .size:
            return rows.sorted { $0.totalBytes > $1.totalBytes }
        case .lastOpened:
            // Newest first; unknown recency sorts last.
            return rows.sorted { a, b in
                switch (a.lastOpened, b.lastOpened) {
                case (nil, nil): return a.totalBytes > b.totalBytes
                case (nil, _): return false
                case (_, nil): return true
                case (let x?, let y?): return x > y
                }
            }
        }
    }

    // MARK: - Field resolution

    private static func resolveKind(
        doc: DocumentDataStore.DocumentDataEntry?,
        web: WebLibrary.SnapshotStorageEntry?
    ) -> DocumentKind {
        if let raw = doc?.meta?.kind, let kind = DocumentKind(rawValue: raw) { return kind }
        return web != nil ? .web : .pdf
    }

    private static func resolveTitle(
        doc: DocumentDataStore.DocumentDataEntry?,
        cache: PageTextCacheEntry?,
        web: WebLibrary.SnapshotStorageEntry?,
        kind: DocumentKind
    ) -> String {
        if let title = doc?.meta?.title, !title.isEmpty { return title }
        if let title = cache?.title, !title.isEmpty { return title }
        if let web { return web.displayTitle }
        if let path = doc?.meta?.lastKnownPath ?? cache?.sourcePath {
            let last = URL(fileURLWithPath: path).lastPathComponent
            if !last.isEmpty { return last }
        }
        return kind == .web ? "Web page" : "Untitled document"
    }

    private static func resolveLastOpened(
        doc: DocumentDataStore.DocumentDataEntry?,
        cache: PageTextCacheEntry?,
        web: WebLibrary.SnapshotStorageEntry?
    ) -> Date? {
        if let stamp = doc?.meta?.lastOpened, let date = WebLibrary.parseRfc3339(stamp) { return date }
        if let cache { return cache.lastOpened }
        return web?.lastOpened
    }

    private static func resolveSourceExists(
        doc: DocumentDataStore.DocumentDataEntry?,
        cache: PageTextCacheEntry?,
        web: WebLibrary.SnapshotStorageEntry?,
        kind: DocumentKind
    ) -> Bool {
        if kind == .web { return true }
        if let doc { return doc.sourceExists }
        // No document folder — fall back to the cache entry's own probe. A web
        // record alone (already handled above) is never an orphan.
        if let cache { return cache.sourceExists }
        return true
    }

    /// A stamped /VellumDocId is a UUID (contains a hyphen); a path-hash
    /// fallback key is a bare 64-hex sha256. Relink can only verify the embedded
    /// id of a docId-keyed entry, so the pane branches on this.
    private static func isLikelyDocId(_ key: String) -> Bool {
        key.contains("-")
    }
}
