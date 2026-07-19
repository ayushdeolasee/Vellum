import Foundation

// Recent-documents list — port of src/lib/recent-pdfs.ts. Same UserDefaults key
// and JSON payload as the localStorage original.

enum RecentFilesService {
    static let storageKey = "vellum.recent-pdfs"
    static let maxRecent = 8

    static func getRecent() -> [RecentDocument] {
        guard let raw = UserDefaults.standard.string(forKey: storageKey),
              let data = raw.data(using: .utf8) else { return [] }
        guard let parsed = try? JSONDecoder().decode([FailableRecent].self, from: data) else {
            return []
        }
        return parsed.compactMap(\.value).prefix(maxRecent).map { $0 }
    }

    static func record(_ document: DocumentInfo) {
        let entry = RecentDocument(
            pdfPath: document.pdfPath,
            kind: document.kind,
            title: document.title,
            pageCount: document.pageCount,
            openedAt: ISO8601DateFormatter.recentTimestamp.string(from: Date()),
            docId: document.docId
        )
        let next = ([entry] + getRecent().filter { $0.pdfPath != document.pdfPath })
            .prefix(maxRecent)
        write(Array(next))
    }

    static func remove(path: String) -> [RecentDocument] {
        let next = getRecent().filter { $0.pdfPath != path }
        write(next)
        return next
    }

    /// The best on-disk path for a recent PDF, resolved by the stable document
    /// identity, not just path existence: a path can be reused by a different
    /// file after a move, so whenever meta.json's last_known_path (kept fresh
    /// by DocumentDataStore.touch) offers a rival candidate, the embedded
    /// /VellumDocId decides which file is really this document (design §7).
    /// The identity read is bounded to rival/dead-path cases — the common
    /// still-in-place recent never opens the PDF here.
    /// Web entries and dead entries with no docId return their recorded path.
    static func resolvedPath(for entry: RecentDocument) -> String {
        guard entry.kind == .pdf,
              let docId = entry.docId, !docId.isEmpty,
              let meta = DocumentDataStore.loadMeta(forKey: docId)
        else { return entry.pdfPath }
        let fm = FileManager.default
        let metaPath = meta.lastKnownPath
        let recordedExists = fm.fileExists(atPath: entry.pdfPath)
        let rivalExists = metaPath != entry.pdfPath && fm.fileExists(atPath: metaPath)
        guard rivalExists else { return entry.pdfPath }
        if recordedExists {
            if PdfMetadata.documentId(atPath: entry.pdfPath) == docId { return entry.pdfPath }
            if PdfMetadata.documentId(atPath: metaPath) == docId { return metaPath }
            return entry.pdfPath
        }
        // Recorded path is dead: adopt the meta path only when its identity
        // matches — a mismatched file there is some other document.
        return PdfMetadata.documentId(atPath: metaPath) == docId ? metaPath : entry.pdfPath
    }

    /// Compact display label: filename for PDFs.
    static func fileName(for path: String) -> String {
        path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? path
    }

    /// Compact display label for a webpage URL, e.g. "example.com/post".
    static func webpageDisplayName(for url: String) -> String {
        guard let parsed = URL(string: url), let host = parsed.host else { return url }
        var path = parsed.path
        if path == "/" { path = "" }
        if path.hasSuffix("/") { path.removeLast() }
        return "\(host)\(path)"
    }

    private static func write(_ documents: [RecentDocument]) {
        // Recent files are a convenience; failures are silently ignored.
        guard let data = try? JSONEncoder().encode(documents),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: storageKey)
    }

    /// Skips malformed entries instead of failing the whole list, mirroring the
    /// original's per-entry validation.
    private struct FailableRecent: Decodable {
        let value: RecentDocument?
        init(from decoder: Decoder) throws {
            value = try? RecentDocument(from: decoder)
        }
    }
}

extension ISO8601DateFormatter {
    /// Matches JS `new Date().toISOString()` (milliseconds, Z suffix).
    /// ISO8601DateFormatter is thread-safe; the unsafe marker only silences
    /// the shared-mutable-state check.
    nonisolated(unsafe) static let recentTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
