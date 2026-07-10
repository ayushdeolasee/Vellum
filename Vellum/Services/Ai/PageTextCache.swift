import CryptoKit
import Foundation

// Persistent per-document page-text cache — reopening a previously indexed PDF
// restores AiStore.pageTexts from disk instead of re-running the whole
// getTextContent walk (issue #37 PR B). Only PDFs persist: web documents load
// their full text up front and never route through this actor.
//
// Identity is by canonical source PATH (sha256-hex, like WebLibrary.pageKey),
// NOT by content hash. Every in-app mutation — annotation writes AND the
// last_page metadata write on every quit — atomically rewrites the whole PDF,
// so a content-keyed file would miss on nearly every reopen. The index entry
// carries a contentHash used only to VALIDATE (external edits invalidate); it
// is refreshed inline by PdfDocumentIO after each in-app write so those writes
// don't invalidate. Storage layout, sha256-hex keys and the tmp+rename atomic
// write follow WebLibrary's conventions; corrupt/version-mismatched JSON decodes
// as a miss and regenerates, matching AiPersistence's silent-recovery style.

/// One document's cached page text (`text-cache/<pathKey>.json`). Empty-string
/// pages are meaningful (a scanned page with no text layer) and round-trip so
/// completion tracking — and a future OCR pass — see them as covered, not
/// missing.
struct PageTextCacheFile: Codable, Sendable {
    var version: Int
    var pageCount: Int
    var complete: Bool
    /// 1-indexed page number (as a string key) → normalized page text.
    var pages: [String: String]
}

/// Sidecar index row (`text-cache/index.json` → entries[pathKey]).
struct PageTextIndexEntry: Codable, Sendable {
    var path: String
    var contentHash: String
    var title: String?
    var lastOpened: String
    var pageCount: Int
    var complete: Bool
}

struct PageTextIndexFile: Codable, Sendable {
    var version: Int
    var entries: [String: PageTextIndexEntry]
}

/// Display DTO for the Storage settings tab (commit 2). Sizes and source
/// existence are resolved inside the actor so the UI never touches FileManager
/// on the main thread.
struct PageTextCacheEntry: Identifiable, Sendable, Equatable {
    var pathKey: String
    var title: String?
    var sourcePath: String
    var sourceExists: Bool
    var lastOpened: Date
    var pageCount: Int
    var isComplete: Bool
    var byteSize: Int64

    var id: String { pathKey }

    /// Best human label: stored title, else the source file name, else the key.
    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        let last = URL(fileURLWithPath: sourcePath).lastPathComponent
        if !last.isEmpty { return last }
        return String(pathKey.prefix(8))
    }
}

actor PageTextCache {
    static let shared = PageTextCache()

    private let directory: URL
    private let fileVersion = 1

    /// Path → most recent contentHash. Updated by `lookup` and `refreshHash` so
    /// a hash refreshed by an in-app write BEFORE the first flush still lands in
    /// the index entry when the flush happens (the annotate-before-first-flush
    /// case that would otherwise stamp a stale hash and self-invalidate).
    private var latestHash: [String: String] = [:]

    /// Test seam: point the actor at a scratch directory.
    init(directory: URL) {
        self.directory = directory
    }

    private init() {
        directory = WebLibrary.appDataDir.appendingPathComponent("text-cache", isDirectory: true)
    }

    // MARK: - Keys / hashing

    /// Stable storage key for a canonical source path: lowercase hex sha256
    /// (same style as WebLibrary.pageKey).
    static func pathKey(_ path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Validation hash over (UInt64 LE byte count + first 4 MB + last 4 MB) —
    /// constant ~8 MB cost, effectively a full hash for files under 8 MB.
    /// Overlapping windows are fine for small files.
    static func contentHash(of data: Data) -> String {
        var hasher = SHA256()
        let littleEndianCount = UInt64(data.count).littleEndian
        withUnsafeBytes(of: littleEndianCount) { hasher.update(bufferPointer: $0) }
        let window = 4 * 1024 * 1024
        hasher.update(data: data.prefix(window))
        hasher.update(data: data.suffix(window))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Public API

    /// Restore a document's page map, or nil (miss). Records the content hash in
    /// `latestHash`. Match → decode the cache body, stamp `lastOpened` (index
    /// only, never the big file), return the pages. Hash mismatch (external
    /// edit) → drop the cache file + entry and return nil. No entry → nil.
    func lookup(path: String, data: Data, title: String?) -> [Int: String]? {
        let hash = Self.contentHash(of: data)
        latestHash[path] = hash
        let key = Self.pathKey(path)
        var index = readIndex()
        guard let entry = index.entries[key] else { return nil }
        guard entry.contentHash == hash else {
            try? FileManager.default.removeItem(at: cacheFileURL(pathKey: key))
            index.entries[key] = nil
            writeIndex(index)
            return nil
        }
        guard let file = readCacheFile(pathKey: key) else {
            // Live entry but missing/corrupt body: treat as a miss and let the
            // walk regenerate; drop the dangling entry.
            index.entries[key] = nil
            writeIndex(index)
            return nil
        }
        var stamped = entry
        stamped.lastOpened = Self.now()
        index.entries[key] = stamped
        writeIndex(index)
        return Self.decodePages(file.pages)
    }

    /// Atomically write a document's cache body and upsert its index entry.
    /// The entry's hash comes from `latestHash` (set by the `lookup` that always
    /// precedes a walk), falling back to any hash already on the entry, else "".
    func write(path: String, title: String?, pageCount: Int, pages: [Int: String], complete: Bool) {
        let key = Self.pathKey(path)
        var pageStrings: [String: String] = [:]
        for (page, text) in pages { pageStrings[String(page)] = text }
        let file = PageTextCacheFile(
            version: fileVersion, pageCount: pageCount, complete: complete, pages: pageStrings)
        writeAtomic(file, to: cacheFileURL(pathKey: key))

        var index = readIndex()
        let hash = latestHash[path] ?? index.entries[key]?.contentHash ?? ""
        index.entries[key] = PageTextIndexEntry(
            path: path,
            contentHash: hash,
            title: title,
            lastOpened: Self.now(),
            pageCount: pageCount,
            complete: complete)
        writeIndex(index)
    }

    /// Re-key the validation hash after an in-app rewrite. Always updates
    /// `latestHash`; also rewrites the index entry's hash when one already
    /// exists, so a reopen with the just-written bytes still hits.
    func refreshHash(path: String, data: Data) {
        let hash = Self.contentHash(of: data)
        latestHash[path] = hash
        let key = Self.pathKey(path)
        var index = readIndex()
        guard var entry = index.entries[key] else { return }
        entry.contentHash = hash
        index.entries[key] = entry
        writeIndex(index)
    }

    /// Join index entries with on-disk file sizes and source existence, sorted
    /// by cache size descending (for the Storage settings tab).
    func listEntries() -> [PageTextCacheEntry] {
        let fm = FileManager.default
        let index = readIndex()
        var out: [PageTextCacheEntry] = []
        for (key, entry) in index.entries {
            let attributes = try? fm.attributesOfItem(atPath: cacheFileURL(pathKey: key).path)
            let byteSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let lastOpened = ISO8601DateFormatter.recentTimestamp.date(from: entry.lastOpened) ?? .distantPast
            out.append(PageTextCacheEntry(
                pathKey: key,
                title: entry.title,
                sourcePath: entry.path,
                sourceExists: fm.fileExists(atPath: entry.path),
                lastOpened: lastOpened,
                pageCount: entry.pageCount,
                isComplete: entry.complete,
                byteSize: byteSize))
        }
        out.sort { $0.byteSize > $1.byteSize }
        return out
    }

    func delete(pathKey: String) {
        try? FileManager.default.removeItem(at: cacheFileURL(pathKey: pathKey))
        var index = readIndex()
        if let entry = index.entries[pathKey] { latestHash[entry.path] = nil }
        index.entries[pathKey] = nil
        writeIndex(index)
    }

    func deleteAll() {
        try? FileManager.default.removeItem(at: directory)
        latestHash = [:]
    }

    /// Age-based eviction: drop entries whose `lastOpened` parses older than
    /// `cutoff`, never one whose path is in `excludingPaths`, and NEVER because
    /// the source file is missing (the cache is still worth keeping).
    func evictStale(olderThan cutoff: Date, excludingPaths: Set<String>) {
        var index = readIndex()
        var changed = false
        for (key, entry) in index.entries {
            guard !excludingPaths.contains(entry.path) else { continue }
            guard let opened = ISO8601DateFormatter.recentTimestamp.date(from: entry.lastOpened),
                  opened < cutoff else { continue }
            try? FileManager.default.removeItem(at: cacheFileURL(pathKey: key))
            index.entries[key] = nil
            latestHash[entry.path] = nil
            changed = true
        }
        if changed { writeIndex(index) }
    }

    // MARK: - Disk

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    private func cacheFileURL(pathKey: String) -> URL {
        directory.appendingPathComponent("\(pathKey).json")
    }

    private func readIndex() -> PageTextIndexFile {
        guard let data = try? Data(contentsOf: indexURL),
              let index = try? JSONDecoder().decode(PageTextIndexFile.self, from: data),
              index.version == fileVersion
        else { return PageTextIndexFile(version: fileVersion, entries: [:]) }
        return index
    }

    private func writeIndex(_ index: PageTextIndexFile) {
        writeAtomic(index, to: indexURL)
    }

    private func readCacheFile(pathKey: String) -> PageTextCacheFile? {
        guard let data = try? Data(contentsOf: cacheFileURL(pathKey: pathKey)),
              let file = try? JSONDecoder().decode(PageTextCacheFile.self, from: data),
              file.version == fileVersion
        else { return nil }
        return file
    }

    /// tmp + rename(2) atomic write (matches WebLibrary.saveRecord). Cache
    /// writes are best-effort: a failure just means a miss on the next open.
    private func writeAtomic<T: Encodable>(_ value: T, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(value)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp)
            guard rename(tmp.path, url.path) == 0 else {
                try? FileManager.default.removeItem(at: tmp)
                return
            }
        } catch {
            // Ignore: best-effort cache.
        }
    }

    private static func decodePages(_ pages: [String: String]) -> [Int: String] {
        var out: [Int: String] = [:]
        for (key, value) in pages where Int(key) != nil {
            out[Int(key)!] = value
        }
        return out
    }

    private static func now() -> String {
        ISO8601DateFormatter.recentTimestamp.string(from: Date())
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()
}
