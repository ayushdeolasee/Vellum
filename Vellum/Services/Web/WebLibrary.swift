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

    /// Test seam for the location feature itself; when only `storeDirOverride`
    /// is set the layout is forced local so existing tests (and the test host's
    /// real UserDefaults mode) can't leak a pretty layout into scratch dirs.
    nonisolated(unsafe) static var layoutOverride: WebStorageLayout?

    /// Where records and managed archives resolve for the user's chosen
    /// storage location. Derived caches (plain snapshots, unpacked archive
    /// dirs) always stay under `storeDir` regardless of layout.
    static var activeLayout: WebStorageLayout {
        if let layoutOverride { return layoutOverride }
        if storeDirOverride != nil { return .local(storeDir: storeDir) }
        return .resolve(mode: WebStorageSettings.effectiveMode, storeDir: storeDir)
    }

    static func recordPath(forKey key: String) -> URL {
        activeLayout.recordsDir.appendingPathComponent("\(key).json")
    }

    /// Every place a record for `key` may live, primary first: the active
    /// layout's records dir, then the legacy local store (files not yet picked
    /// up by the migration sweep).
    static func candidateRecordPaths(forKey key: String) -> [URL] {
        var paths = [recordPath(forKey: key)]
        let legacy = storeDir.appendingPathComponent("\(key).json")
        if legacy != paths[0] { paths.append(legacy) }
        return paths
    }

    /// Load a record wherever it currently lives, downloading an evicted
    /// iCloud copy if needed (blocking; call off the main thread when the
    /// active layout may be iCloud).
    static func loadRecord(forKey key: String, timeout: TimeInterval = 10) -> WebPageRecord? {
        for path in candidateRecordPaths(forKey: key) {
            _ = WebICloud.materialize(at: path, timeout: timeout)
            if let record = loadRecord(at: path) { return record }
        }
        return nil
    }

    /// Record read for the page-serving path, which must not stall on iCloud.
    /// A local copy resolves with no wait at all; only an evicted record waits,
    /// and then briefly and on a dedicated thread — `WebICloud.materialize`
    /// blocks with `Thread.sleep`, which must never happen on a cooperative
    /// (async) thread. The record still has to be read rather than skipped: it
    /// carries `saved` and the pinned-snapshot loading policy, so treating an
    /// evicted one as absent would silently serve a live page in place of an
    /// imported archive's snapshot.
    static func loadRecordForServing(forKey key: String) async -> WebPageRecord? {
        let paths = candidateRecordPaths(forKey: key)
        for path in paths {
            if let record = loadRecord(at: path) { return record }
        }
        guard paths.contains(where: { WebICloud.itemExists(at: $0) }) else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: loadRecord(forKey: key, timeout: 2))
            }
        }
    }

    static func snapshotPath(forKey key: String) -> URL {
        storeDir.appendingPathComponent("\(key).snapshot.html")
    }

    /// Legacy managed library path (`web/<key>.vellumweb`) — still the write
    /// destination in local mode and the read fallback for archives the sweep
    /// hasn't moved yet.
    static func managedArchivePath(forKey key: String) -> URL {
        storeDir.appendingPathComponent("\(key).vellumweb")
    }

    /// Where the next managed-archive write for this page should land. In
    /// pretty layouts this assigns (or reuses) the title-based filename in
    /// `Web Pages/`; in local mode it is the hashed legacy path.
    static func managedArchiveDestination(forKey key: String) -> URL {
        let layout = activeLayout
        guard layout.pretty, let indexPath = layout.indexPath else {
            return managedArchivePath(forKey: key)
        }
        let record = loadRecord(forKey: key)
        let name = WebArchiveIndex.assignFileName(
            forKey: key,
            title: record?.title,
            url: record?.url ?? "",
            at: indexPath,
            archivesDir: layout.archivesDir)
        return layout.archivesDir.appendingPathComponent(name)
    }

    /// The managed archive that currently exists for this page, if any —
    /// checks the pretty location (counting an evicted iCloud placeholder as
    /// present), then the legacy hashed path.
    static func existingManagedArchiveURL(forKey key: String) -> URL? {
        let layout = activeLayout
        if layout.pretty, let indexPath = layout.indexPath,
           let name = WebArchiveIndex.fileName(forKey: key, at: indexPath) {
            let url = layout.archivesDir.appendingPathComponent(name)
            if WebICloud.itemExists(at: url) { return url }
        }
        let legacy = managedArchivePath(forKey: key)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: legacy.path, isDirectory: &isDir), !isDir.boolValue {
            return legacy
        }
        return nil
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
    ///
    /// When the primary path has no file yet, the legacy local store is
    /// consulted (and an evicted iCloud copy downloaded) before falling back
    /// to a fresh record — so a page opened right after a storage-location
    /// switch keeps its annotations even if the migration sweep hasn't reached
    /// its file. The write always lands on the primary path; the stale source
    /// copy is cleaned up by the next sweep.
    @discardableResult
    static func withRecord<T>(
        url: String, recordPath: URL, _ mutate: (inout WebPageRecord) -> T
    ) throws -> T {
        let lock = recordLock(for: recordPath)
        lock.lock()
        defer { lock.unlock() }
        if !WebICloud.materialize(at: recordPath),
           FileManager.default.fileExists(atPath: WebICloud.placeholderURL(for: recordPath).path) {
            // The record exists in iCloud but its bytes couldn't be downloaded
            // (offline?). Writing a fresh record here would overwrite the real
            // one — highlights and notes — once iCloud reconnects. Refuse.
            throw SessionServiceError.io(
                "This page's reading data is in iCloud but hasn't downloaded yet — check your connection and try again")
        }
        var record = loadRecord(at: recordPath)
            ?? loadRecord(forKey: pageKey(url))
            ?? WebPageRecord(url: url)
        let out = mutate(&record)
        try saveRecord(record, at: recordPath)
        return out
    }

    /// Migration seam: carry a record file to its new home while holding both
    /// paths' locks, so the sweep can't race a session's read-modify-write on
    /// either side. When the destination already has a copy (a session
    /// fallback-read wrote it there), the two are MERGED — annotations
    /// unioned, saved-ness kept if either side had it — never blindly
    /// discarded: an open session may have written to the source after the
    /// destination copy was created. Returns false when the record could not
    /// be moved or merged (caller must keep its resume marker).
    static func adoptRecordFile(from source: URL, to destination: URL) -> Bool {
        let first = source.path < destination.path ? source : destination
        let second = source.path < destination.path ? destination : source
        let lockA = recordLock(for: first)
        let lockB = recordLock(for: second)
        lockA.lock()
        defer { lockA.unlock() }
        lockB.lock()
        defer { lockB.unlock() }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            guard var dest = loadRecord(at: destination) else { return false }
            guard let src = loadRecord(at: source) else {
                // Unreadable source: don't delete it — leave it for inspection.
                return false
            }
            WebArchive.mergeAnnotations(&dest.annotations, incoming: src.annotations)
            dest.saved = dest.saved || src.saved
            dest.savedAt = dest.savedAt ?? src.savedAt
            dest.title = dest.title ?? src.title
            dest.pageCount = dest.pageCount ?? src.pageCount
            dest.lastPage = dest.lastPage ?? src.lastPage
            dest.openedAt = dest.openedAt ?? src.openedAt
            guard (try? saveRecord(dest, at: destination)) != nil else { return false }
            try? fm.removeItem(at: source)
            return true
        }
        do {
            try fm.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
            return true
        } catch {
            return false
        }
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
        if existingManagedArchiveURL(forKey: key) != nil {
            return true
        }
        let installed = archiveDir(forKey: key).appendingPathComponent("snapshot.html")
        if fm.fileExists(atPath: installed.path, isDirectory: &isDir), !isDir.boolValue {
            return true
        }
        return false
    }

    /// Delete all locally cached snapshot artifacts for a page — including a
    /// pretty-named (possibly evicted) managed archive and its index entry.
    static func removeLocalSnapshots(forKey key: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: snapshotPath(forKey: key))
        if let managed = existingManagedArchiveURL(forKey: key) {
            WebICloud.removeItem(at: managed)
        }
        try? fm.removeItem(at: managedArchivePath(forKey: key))
        if let indexPath = activeLayout.indexPath {
            WebArchiveIndex.removeEntry(forKey: key, at: indexPath)
        }
        try? fm.removeItem(at: archiveDir(forKey: key))
    }

    /// Record filenames in a directory — including ones iCloud has evicted to
    /// a `.<name>.json.icloud` placeholder, reported under their real name so
    /// migration and listings never silently skip an evicted record.
    static func recordFileNames(inDir dir: URL) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out = Set<String>()
        for name in names {
            if name.hasSuffix(".json") {
                out.insert(name)
            } else if name.hasPrefix("."), name.hasSuffix(".json.icloud") {
                out.insert(String(name.dropFirst().dropLast(".icloud".count)))
            }
        }
        return out.sorted()
    }

    /// Every record file across the active layout and the legacy local store,
    /// deduplicated by filename with the active location winning (a stale
    /// legacy copy the sweep hasn't collected must not shadow the live one).
    static func allRecordFiles() -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        var dirs = [activeLayout.recordsDir]
        if storeDir != activeLayout.recordsDir { dirs.append(storeDir) }
        for dir in dirs {
            for name in recordFileNames(inDir: dir) {
                guard seen.insert(name).inserted else { continue }
                out.append(dir.appendingPathComponent(name))
            }
        }
        return out
    }

    static func listSaved() -> [WebLibraryEntry] {
        var out: [WebLibraryEntry] = []
        for file in allRecordFiles() {
            guard let record = loadRecord(at: file) else {
                WebICloud.requestDownload(at: file)
                continue
            }
            guard record.saved else { continue }
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
        // Un-save (keep annotations in case the page is reopened later) —
        // through withRecord so the un-migrated/evicted copy is found too and
        // the page can't reappear in the library from a stale legacy record.
        if loadRecord(forKey: key) != nil {
            try withRecord(url: url, recordPath: recordPath(forKey: key)) { record in
                record.saved = false
                record.savedAt = nil
            }
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
        var out: [SnapshotStorageEntry] = []
        for file in allRecordFiles() {
            guard let record = loadRecord(at: file) else {
                // Evicted iCloud record: request the bytes in the background so
                // the page shows up on the next refresh instead of blocking now.
                WebICloud.requestDownload(at: file)
                continue
            }
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
        for file in allRecordFiles() {
            // An unreadable (e.g. evicted) record is never grounds for
            // eviction — loadRecord returning nil skips the page entirely.
            guard let record = loadRecord(at: file),
                  !record.saved, record.annotations.isEmpty,
                  !excludingUrls.contains(record.url),
                  let opened = parseRfc3339(record.openedAt) ?? parseRfc3339(record.savedAt),
                  opened < cutoff
            else { continue }
            removeLocalSnapshots(forKey: pageKey(record.url))
        }
    }

    /// Delete every snapshot artifact in the store (records stay). Sweeps the
    /// directory listings rather than the records so orphaned artifacts whose
    /// record was lost are removed too — both the legacy local store and the
    /// active layout's `Web Pages/` folder (evicted placeholders included).
    static func removeAllSnapshotArtifacts() {
        let fm = FileManager.default
        try? fm.removeItem(at: storeDir.appendingPathComponent("archives", isDirectory: true))
        if let names = try? fm.contentsOfDirectory(atPath: storeDir.path) {
            for name in names where name.hasSuffix(".snapshot.html") || name.hasSuffix(".vellumweb") {
                try? fm.removeItem(at: storeDir.appendingPathComponent(name))
            }
        }
        let layout = activeLayout
        if layout.pretty, let names = try? fm.contentsOfDirectory(atPath: layout.archivesDir.path) {
            for name in names where name.hasSuffix(".vellumweb") || name.hasSuffix(".vellumweb.icloud") {
                try? fm.removeItem(at: layout.archivesDir.appendingPathComponent(name))
            }
            if let indexPath = layout.indexPath {
                try? fm.removeItem(at: indexPath)
            }
        }
    }

    private static func snapshotArtifactsSize(forKey key: String) -> Int64 {
        let fm = FileManager.default
        var total: Int64 = 0
        let attributes = try? fm.attributesOfItem(atPath: snapshotPath(forKey: key).path)
        total += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if let managed = existingManagedArchiveURL(forKey: key) {
            total += WebICloud.size(ofItemAt: managed)
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
