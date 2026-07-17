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

    /// The best on-disk path for a recent PDF: the recorded path if it still
    /// exists, else — for a docId-carrying entry — meta.json's last_known_path
    /// (kept fresh by DocumentDataStore.touch) when that resolves, else the
    /// recorded path unchanged. Lets a moved PDF reopen by identity (design §7).
    /// Web entries and dead entries with no docId return their recorded path.
    static func resolvedPath(for entry: RecentDocument) -> String {
        guard entry.kind == .pdf,
              !FileManager.default.fileExists(atPath: entry.pdfPath),
              let docId = entry.docId, !docId.isEmpty,
              let meta = DocumentDataStore.loadMeta(forKey: docId),
              FileManager.default.fileExists(atPath: meta.lastKnownPath)
        else { return entry.pdfPath }
        return meta.lastKnownPath
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
