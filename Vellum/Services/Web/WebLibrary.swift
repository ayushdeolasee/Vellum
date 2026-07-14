import CryptoKit
import Foundation

// Webpage sidecar records + the saved-pages library — port of the storage half
// of src-tauri/src/web_page.rs. Uses the exact same on-disk layout under the
// app-data dir (~/Library/Application Support/com.vellum.app/web/) — same
// sha256-hex keys, same snake_case JSON — so libraries written by the Tauri
// app keep working.

/// Sidecar record persisted per webpage (`<appData>/web/<key>.json`).
/// All fields default on decode except `url` (mirrors `#[serde(default)]`).
struct WebPageRecord: Codable, Sendable {
    var url: String
    var title: String?
    var pageCount: Int?
    var lastPage: Int?
    var saved: Bool
    var savedAt: String?
    var openedAt: String?
    /// "live-first" (default when nil) or "snapshot-only" (pinned snapshot,
    /// set when importing a .vellumweb archive that requests it).
    var loadingPolicy: String?
    var annotations: [Annotation]

    enum CodingKeys: String, CodingKey {
        case url
        case title
        case pageCount = "page_count"
        case lastPage = "last_page"
        case saved
        case savedAt = "saved_at"
        case openedAt = "opened_at"
        case loadingPolicy = "loading_policy"
        case annotations
    }

    init(url: String) {
        self.url = url
        title = nil
        pageCount = nil
        lastPage = nil
        saved = false
        savedAt = nil
        openedAt = nil
        loadingPolicy = nil
        annotations = []
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        lastPage = try container.decodeIfPresent(Int.self, forKey: .lastPage)
        saved = try container.decodeIfPresent(Bool.self, forKey: .saved) ?? false
        savedAt = try container.decodeIfPresent(String.self, forKey: .savedAt)
        openedAt = try container.decodeIfPresent(String.self, forKey: .openedAt)
        loadingPolicy = try container.decodeIfPresent(String.self, forKey: .loadingPolicy)
        annotations = try container.decodeIfPresent([Annotation].self, forKey: .annotations) ?? []
    }
}

enum WebLibrary {
    // MARK: - Storage paths

    /// The app-data dir the Rust app used: `~/Library/Application Support/<bundle id>`.
    static var appDataDir: URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        let bundleId = Bundle.main.bundleIdentifier ?? "com.vellum.app"
        return base.appendingPathComponent(bundleId, isDirectory: true)
    }

    /// Test seam: point the whole web store at a scratch directory (mirrors
    /// `ScratchpadAttachmentStore.directoryOverride`). Every path below derives
    /// from `storeDir`, so overriding this redirects records and artifacts alike.
    nonisolated(unsafe) static var storeDirOverride: URL?

    static var storeDir: URL {
        storeDirOverride ?? appDataDir.appendingPathComponent("web", isDirectory: true)
    }

    static func recordPath(forKey key: String) -> URL {
        storeDir.appendingPathComponent("\(key).json")
    }

    static func snapshotPath(forKey key: String) -> URL {
        storeDir.appendingPathComponent("\(key).snapshot.html")
    }

    /// Managed library path for a page's `.vellumweb` archive.
    static func managedArchivePath(forKey key: String) -> URL {
        storeDir.appendingPathComponent("\(key).vellumweb")
    }

    /// Installed self-contained snapshot dir (`web/archives/<key>/`).
    static func archiveDir(forKey key: String) -> URL {
        storeDir.appendingPathComponent("archives", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    /// Stable storage key for a normalized URL: lowercase hex sha256.
    static func pageKey(_ normalizedUrl: String) -> String {
        let digest = SHA256.hash(data: Data(normalizedUrl.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Record persistence

    nonisolated(unsafe) static let jsonEncoderPretty: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return encoder
    }()

    nonisolated(unsafe) static let jsonEncoderCompact: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    static func loadRecord(at path: URL) -> WebPageRecord? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(WebPageRecord.self, from: data)
    }

    static func saveRecord(_ record: WebPageRecord, at path: URL) throws {
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to create web store dir: \(error.localizedDescription)")
        }
        let json: Data
        do {
            json = try jsonEncoderPretty.encode(record)
        } catch {
            throw SessionServiceError.io("Failed to serialize webpage record: \(error.localizedDescription)")
        }
        // Atomic write: `<key>.json.tmp` then rename (matches the Rust temp name).
        let tmp = path.appendingPathExtension("tmp")
        do {
            try json.write(to: tmp)
        } catch {
            throw SessionServiceError.io("Failed to write webpage record: \(error.localizedDescription)")
        }
        guard rename(tmp.path, path.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to commit webpage record: rename failed")
        }
    }

    // Per-record serialization. The sidecar CRUD actors are per-session, so two
    // sessions (or an open touching `openedAt` while another writes annotations)
    // for the same page key would otherwise run overlapping read-modify-write
    // cycles and clobber each other. Routing every mutation through `withRecord`
    // under a per-path lock makes the shared file the single serialization point.
    nonisolated(unsafe) private static var recordLocks: [String: NSLock] = [:]
    private static let recordLocksGuard = NSLock()

    private static func recordLock(for path: URL) -> NSLock {
        recordLocksGuard.lock()
        defer { recordLocksGuard.unlock() }
        if let existing = recordLocks[path.path] { return existing }
        let lock = NSLock()
        recordLocks[path.path] = lock
        return lock
    }

    /// Read-modify-write on the sidecar (a corrupt/missing file is silently
    /// replaced by a fresh record, matching the Rust behavior). Serialized per
    /// record path so concurrent sessions for the same page never interleave.
    @discardableResult
    static func withRecord<T>(
        url: String, recordPath: URL, _ mutate: (inout WebPageRecord) -> T
    ) throws -> T {
        let lock = recordLock(for: recordPath)
        lock.lock()
        defer { lock.unlock() }
        var record = loadRecord(at: recordPath) ?? WebPageRecord(url: url)
        let out = mutate(&record)
        try saveRecord(record, at: recordPath)
        return out
    }

    /// Matches chrono `Utc::now().to_rfc3339()` closely enough to sort and
    /// parse interchangeably ("+00:00" offset, fractional seconds).
    static func rfc3339Now() -> String {
        rfc3339Formatter.string(from: Date())
    }

    nonisolated(unsafe) private static let rfc3339Formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter
    }()

    // MARK: - Saved-pages library

    static func hasLocalSnapshot(forKey key: String) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: snapshotPath(forKey: key).path, isDirectory: &isDir), !isDir.boolValue {
            return true
        }
        if fm.fileExists(atPath: managedArchivePath(forKey: key).path, isDirectory: &isDir), !isDir.boolValue {
            return true
        }
        let installed = archiveDir(forKey: key).appendingPathComponent("snapshot.html")
        if fm.fileExists(atPath: installed.path, isDirectory: &isDir), !isDir.boolValue {
            return true
        }
        return false
    }

    /// Delete all locally cached snapshot artifacts for a page.
    static func removeLocalSnapshots(forKey key: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: snapshotPath(forKey: key))
        try? fm.removeItem(at: managedArchivePath(forKey: key))
        try? fm.removeItem(at: archiveDir(forKey: key))
    }

    static func listSaved() -> [WebLibraryEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: storeDir.path) else {
            return []
        }
        var out: [WebLibraryEntry] = []
        for name in names where name.hasSuffix(".json") {
            guard let record = loadRecord(at: storeDir.appendingPathComponent(name)),
                  record.saved else { continue }
            let key = pageKey(record.url)
            out.append(WebLibraryEntry(
                url: record.url,
                title: record.title,
                pageCount: record.pageCount,
                savedAt: record.savedAt,
                hasSnapshot: hasLocalSnapshot(forKey: key)
            ))
        }
        // saved_at descending; missing timestamps sort last (Option cmp: None < Some).
        out.sort { a, b in
            switch (a.savedAt, b.savedAt) {
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            case (let x?, let y?): return x > y
            }
        }
        return out
    }

    static func removeSaved(rawUrl: String) throws {
        let url = try WebUrl.normalize(rawUrl)
        let key = pageKey(url)
        let path = recordPath(forKey: key)
        // Un-save (keep annotations in case the page is reopened later).
        if var record = loadRecord(at: path) {
            record.saved = false
            record.savedAt = nil
            try saveRecord(record, at: path)
        }
        removeLocalSnapshots(forKey: key)
    }

    // MARK: - Snapshot storage management (Settings ▸ Storage)

    /// One page's on-disk snapshot footprint. Sizes cover only the derived
    /// artifacts (plain snapshot, managed `.vellumweb`, installed archive dir),
    /// never the sidecar record — that holds the user's annotations and reading
    /// state and is not deletable from the Storage tab.
    struct SnapshotStorageEntry: Identifiable, Sendable, Equatable {
        var key: String
        var url: String
        var title: String?
        var saved: Bool
        var hasAnnotations: Bool
        var lastOpened: Date?
        var byteSize: Int64

        var id: String { key }

        var displayTitle: String {
            if let title, !title.isEmpty { return title }
            return url
        }
    }

    /// Every page that currently has snapshot artifacts on disk, largest first.
    static func listSnapshotStorage() -> [SnapshotStorageEntry] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: storeDir.path) else {
            return []
        }
        var out: [SnapshotStorageEntry] = []
        for name in names where name.hasSuffix(".json") {
            guard let record = loadRecord(at: storeDir.appendingPathComponent(name)) else { continue }
            let key = pageKey(record.url)
            let size = snapshotArtifactsSize(forKey: key)
            guard size > 0 else { continue }
            out.append(SnapshotStorageEntry(
                key: key,
                url: record.url,
                title: record.title,
                saved: record.saved,
                hasAnnotations: !record.annotations.isEmpty,
                lastOpened: parseRfc3339(record.openedAt) ?? parseRfc3339(record.savedAt),
                byteSize: size))
        }
        out.sort { $0.byteSize > $1.byteSize }
        return out
    }

    /// Launch-time TTL eviction of snapshot artifacts for pages the user never
    /// kept: not saved, no annotations (annotating promotes to saved, so any
    /// annotations mean "keep" defensively), not currently open, and last
    /// opened before `cutoff`. Only ever deletes the derived artifacts — the
    /// sidecar record (reading state) always survives, and a record with no
    /// parseable timestamp is never evicted.
    static func evictStaleUnsavedSnapshots(olderThan cutoff: Date, excludingUrls: Set<String>) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: storeDir.path) else {
            return
        }
        for name in names where name.hasSuffix(".json") {
            guard let record = loadRecord(at: storeDir.appendingPathComponent(name)),
                  !record.saved, record.annotations.isEmpty,
                  !excludingUrls.contains(record.url),
                  let opened = parseRfc3339(record.openedAt) ?? parseRfc3339(record.savedAt),
                  opened < cutoff
            else { continue }
            removeLocalSnapshots(forKey: pageKey(record.url))
        }
    }

    /// Delete every snapshot artifact in the store (records stay). Sweeps the
    /// directory listing rather than the records so orphaned artifacts whose
    /// record was lost are removed too.
    static func removeAllSnapshotArtifacts() {
        let fm = FileManager.default
        try? fm.removeItem(at: storeDir.appendingPathComponent("archives", isDirectory: true))
        guard let names = try? fm.contentsOfDirectory(atPath: storeDir.path) else { return }
        for name in names where name.hasSuffix(".snapshot.html") || name.hasSuffix(".vellumweb") {
            try? fm.removeItem(at: storeDir.appendingPathComponent(name))
        }
    }

    private static func snapshotArtifactsSize(forKey key: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        for file in [snapshotPath(forKey: key), managedArchivePath(forKey: key)] {
            let attributes = try? fm.attributesOfItem(atPath: file.path)
            total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        total += directorySize(at: archiveDir(forKey: key))
        return total
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [],
            errorHandler: nil)
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// Lenient parse for record timestamps: our writer's 6-digit-fraction
    /// RFC3339 first, then ISO8601 with/without fractional seconds (Tauri-era
    /// chrono emitted variable fraction widths).
    static func parseRfc3339(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = rfc3339Formatter.date(from: value) { return date }
        if let date = iso8601Fractional.date(from: value) { return date }
        return iso8601Plain.date(from: value)
    }

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
