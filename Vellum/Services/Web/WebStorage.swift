import Foundation

// Where the web library lives on disk (issue #29 follow-up): the user picks a
// storage location once — iCloud Drive (everything syncs: offline copies AND
// records with highlights/notes/reading position), a custom folder (offline
// copies only; records stay in Application Support and do not sync), or this
// Mac (the pre-existing layout, everything under Application Support).
//
// iCloud is plain-folder iCloud Drive (`~/Library/Mobile Documents/
// com~apple~CloudDocs/Vellum/`), not an app ubiquity container — the app is
// ad-hoc signed with no entitlements, so `url(forUbiquityContainerIdentifier:)`
// is unavailable. Being unsandboxed, FileManager can write there directly and
// the iCloud daemon syncs it like any Finder-managed iCloud Drive folder
// (the Obsidian-vault approach). Swapping to a real container later only
// changes `WebStorageSettings.icloudVellumRoot`.
//
// User-facing layout under the chosen root ("pretty" modes):
//   Web Pages/<Title>.vellumweb    one self-contained archive per page
//   .vellum/index.json             page-key → filename map
//   .vellum/records/<key>.json     records (iCloud mode only)
// Derived caches (plain snapshots, unpacked archive dirs) always stay in
// Application Support — they're rebuildable and would be sync noise.

// MARK: - Mode + preferences

enum WebStorageMode: String, CaseIterable, Sendable {
    case local
    case icloud
    case custom
}

enum WebStorageSettings {
    static let modeKey = "web.storage.mode"
    static let customPathKey = "web.storage.customPath"
    static let autoSaveKey = "web.storage.autoSavePages"
    static let pendingRelocationKey = "web.storage.pendingRelocationFrom"

    // Test seams (same idiom as WebLibrary.storeDirOverride).
    nonisolated(unsafe) static var modeOverride: WebStorageMode?
    nonisolated(unsafe) static var customRootOverride: URL?
    nonisolated(unsafe) static var icloudDriveRootOverride: URL?
    nonisolated(unsafe) static var autoSavePagesOverride: Bool?

    /// Nil until the user has made the first-launch choice.
    static var chosenMode: WebStorageMode? {
        if let modeOverride { return modeOverride }
        guard let raw = UserDefaults.standard.string(forKey: modeKey) else { return nil }
        return WebStorageMode(rawValue: raw)
    }

    /// What path resolution actually uses: the chosen mode, degraded to
    /// `.local` when its root is unusable (iCloud Drive signed out, custom
    /// folder deleted) so the app keeps working instead of writing into a void.
    static var effectiveMode: WebStorageMode {
        switch chosenMode {
        case .icloud: return icloudVellumRoot != nil ? .icloud : .local
        case .custom: return customRoot != nil ? .custom : .local
        default: return .local
        }
    }

    /// The chosen mode exists but its root is currently unusable (Settings
    /// surfaces this as a warning instead of failing silently).
    static var modeIsDegraded: Bool {
        guard let chosenMode else { return false }
        return chosenMode != effectiveMode
    }

    static var needsFirstLaunchChoice: Bool { chosenMode == nil }

    static func setMode(_ mode: WebStorageMode, customPath: String? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: modeKey)
        if mode == .custom, let customPath {
            defaults.set(customPath, forKey: customPathKey)
        }
    }

    /// iCloud Drive's real on-disk root, nil when iCloud Drive is off. The
    /// test override goes through the same existence check so degraded-mode
    /// behavior is testable.
    static var icloudDriveRoot: URL? {
        let root = icloudDriveRootOverride
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return root
    }

    static var icloudVellumRoot: URL? {
        icloudDriveRoot?.appendingPathComponent("Vellum", isDirectory: true)
    }

    static var customRoot: URL? {
        if let customRootOverride { return customRootOverride }
        guard let path = UserDefaults.standard.string(forKey: customPathKey),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    /// Root for the *chosen* mode even when degraded — used by the migrator so
    /// an interrupted relocation can still name its source.
    static func root(for mode: WebStorageMode) -> URL? {
        switch mode {
        case .icloud: return icloudVellumRoot
        case .custom: return customRoot
        case .local: return nil
        }
    }

    /// Settings ▸ Storage: mark every opened page saved (pre-explicit-save
    /// behavior, now opt-in). Off by default.
    static var autoSavePages: Bool {
        if let autoSavePagesOverride { return autoSavePagesOverride }
        return UserDefaults.standard.bool(forKey: autoSaveKey)
    }

    static func setAutoSavePages(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: autoSaveKey)
    }
}

// MARK: - Resolved layout

/// The concrete directories the active mode resolves to. Everything in
/// WebLibrary that touches records or managed archives goes through this.
struct WebStorageLayout: Equatable, Sendable {
    /// Where `<key>.json` records live.
    var recordsDir: URL
    /// Where managed `.vellumweb` archives live.
    var archivesDir: URL
    /// Where `documents/<key>/` folders (scratchpad, conversations, meta,
    /// attachments — class-B user data) live. Mirrors the records rule: in
    /// iCloud mode it sits next to the records under the synced root, so notes
    /// and AI conversations sync too; in custom mode it stays LOCAL (custom
    /// mode's meaning is "my folder holds the visible web pages" — records and
    /// documents stay in Application Support); in local mode it is the default
    /// Application-Support location.
    var documentsDir: URL
    /// Pretty modes name archives after the page title (via the index);
    /// the local mode keeps the legacy `<key>.vellumweb` hashed names.
    var pretty: Bool
    /// `.vellum/index.json` next to the archives (pretty modes only).
    var indexPath: URL?

    /// The documents/ home for a local (Application Support) layout. Derived
    /// from `storeDir` (a sibling of `web/` under appData) so the
    /// `storeDirOverride` test seam covers it too, and so it stays byte-for-byte
    /// the pre-existing `appDataDir/documents` location in production.
    static func localDocumentsDir(storeDir: URL) -> URL {
        storeDir.deletingLastPathComponent().appendingPathComponent("documents", isDirectory: true)
    }

    static func local(storeDir: URL) -> WebStorageLayout {
        WebStorageLayout(
            recordsDir: storeDir, archivesDir: storeDir,
            documentsDir: localDocumentsDir(storeDir: storeDir),
            pretty: false, indexPath: nil)
    }

    static func pretty(root: URL, recordsInRoot: Bool, localStoreDir: URL) -> WebStorageLayout {
        let internalDir = root.appendingPathComponent(".vellum", isDirectory: true)
        return WebStorageLayout(
            recordsDir: recordsInRoot
                ? internalDir.appendingPathComponent("records", isDirectory: true)
                : localStoreDir,
            archivesDir: root.appendingPathComponent("Web Pages", isDirectory: true),
            // Documents follow records: synced under the root in iCloud mode
            // (recordsInRoot), local in custom mode.
            documentsDir: recordsInRoot
                ? internalDir.appendingPathComponent("documents", isDirectory: true)
                : localDocumentsDir(storeDir: localStoreDir),
            pretty: true,
            indexPath: internalDir.appendingPathComponent("index.json"))
    }

    static func resolve(mode: WebStorageMode, storeDir: URL) -> WebStorageLayout {
        switch mode {
        case .icloud:
            guard let root = WebStorageSettings.icloudVellumRoot else { return .local(storeDir: storeDir) }
            return .pretty(root: root, recordsInRoot: true, localStoreDir: storeDir)
        case .custom:
            guard let root = WebStorageSettings.customRoot else { return .local(storeDir: storeDir) }
            return .pretty(root: root, recordsInRoot: false, localStoreDir: storeDir)
        case .local:
            return .local(storeDir: storeDir)
        }
    }
}

// MARK: - Pretty-name index

/// Maps page keys to the human-named `.vellumweb` files in `Web Pages/`.
/// Names are assigned once and kept stable across title changes (renames would
/// be iCloud sync churn). A missing entry just means a fresh name is assigned
/// on the next archive write — the index is a convenience, not a source of
/// truth, so losing it (e.g. an iCloud conflict) is never data loss.
enum WebArchiveIndex {
    struct Contents: Codable {
        var version: Int
        var entries: [String: String]

        init() {
            version = 1
            entries = [:]
        }
    }

    private static let lock = NSLock()

    static func load(at path: URL) -> Contents {
        guard let data = try? Data(contentsOf: path),
              let contents = try? JSONDecoder().decode(Contents.self, from: data)
        else { return Contents() }
        return contents
    }

    private static func save(_ contents: Contents, at path: URL) {
        try? FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? WebLibrary.jsonEncoderPretty.encode(contents) else { return }
        let tmp = path.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        if rename(tmp.path, path.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
        }
    }

    static func fileName(forKey key: String, at path: URL) -> String? {
        lock.lock()
        defer { lock.unlock() }
        _ = WebICloud.materialize(at: path, timeout: 5)
        return load(at: path).entries[key]
    }

    /// Existing name for the key, or assign one derived from the title —
    /// unique against both the index and whatever is already on disk.
    static func assignFileName(forKey key: String, title: String?, url: String, at path: URL, archivesDir: URL) -> String {
        lock.lock()
        defer { lock.unlock() }
        // An evicted index read as empty would re-assign names that are
        // already taken and overwrite other pages' archives — download it
        // first, and treat evicted archives as occupying their filename.
        _ = WebICloud.materialize(at: path, timeout: 5)
        var contents = load(at: path)
        if let existing = contents.entries[key] { return existing }
        let base = sanitizedBaseName(title: title, url: url)
        var candidate = "\(base).vellumweb"
        var counter = 2
        let taken = Set(contents.entries.values)
        while taken.contains(candidate)
            || WebICloud.itemExists(at: archivesDir.appendingPathComponent(candidate)) {
            candidate = "\(base) \(counter).vellumweb"
            counter += 1
        }
        contents.entries[key] = candidate
        save(contents, at: path)
        return candidate
    }

    static func removeEntry(forKey key: String, at path: URL) {
        lock.lock()
        defer { lock.unlock() }
        _ = WebICloud.materialize(at: path, timeout: 5)
        var contents = load(at: path)
        guard contents.entries.removeValue(forKey: key) != nil else { return }
        save(contents, at: path)
    }

    /// Filesystem-safe display name: strip path separators and control chars,
    /// collapse whitespace, trim leading dots (hidden files), cap the length.
    /// Falls back to the URL's host+path when the title is empty.
    static func sanitizedBaseName(title: String?, url: String) -> String {
        var source = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty {
            // Lenient Foundation URL parsing can yield a path but no host —
            // never emit a dangling "host — " / "— tail" fragment.
            let parsed = URL(string: url)
            let host = parsed?.host ?? ""
            let tail = parsed?.path.split(separator: "/").last.map(String.init) ?? ""
            switch (host.isEmpty, tail.isEmpty) {
            case (false, false): source = "\(host) — \(tail)"
            case (false, true): source = host
            case (true, _): source = tail
            }
        }
        if source.isEmpty { source = "Web Page" }
        var cleaned = ""
        for scalar in source.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                cleaned.append("-")
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? "Web Page" : cleaned
    }
}

// MARK: - iCloud materialization

/// iCloud Drive evicts files it thinks are cold, leaving a `.<name>.icloud`
/// placeholder where the real file was. Anything that reads library files from
/// a pretty root must cope with that.
enum WebICloud {
    /// The dataless-placeholder path iCloud Drive uses for an evicted file.
    static func placeholderURL(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
    }

    /// True when the item exists in the library — either materialized or as an
    /// evicted placeholder.
    static func itemExists(at url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path)
            || fm.fileExists(atPath: placeholderURL(for: url).path)
    }

    /// Ensure the real bytes are local, triggering a download for an evicted
    /// item and polling until it lands or the timeout passes. Blocking — call
    /// off the main thread only. Returns false when the file neither exists
    /// nor could be downloaded in time (e.g. offline).
    static func materialize(at url: URL, timeout: TimeInterval = 10) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        guard fm.fileExists(atPath: placeholderURL(for: url).path) else { return false }
        try? fm.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if fm.fileExists(atPath: url.path) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return false
    }

    /// Fire-and-forget download request for an evicted item — used by listing
    /// paths that must not block on the network.
    static func requestDownload(at url: URL) {
        guard FileManager.default.fileExists(atPath: placeholderURL(for: url).path) else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
    }

    /// Delete an item that may currently be evicted (removing the placeholder
    /// removes the item from iCloud too).
    static func removeItem(at url: URL) {
        let fm = FileManager.default
        try? fm.removeItem(at: url)
        try? fm.removeItem(at: placeholderURL(for: url))
    }

    static func size(ofItemAt url: URL) -> Int64 {
        let fm = FileManager.default
        if let attributes = try? fm.attributesOfItem(atPath: url.path) {
            return (attributes[.size] as? NSNumber)?.int64Value ?? 0
        }
        // Evicted: report the true size recorded on the placeholder so the
        // Storage tab reflects what deleting would reclaim in iCloud.
        let placeholder = placeholderURL(for: url)
        if let data = try? Data(contentsOf: placeholder),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
           let dict = plist as? [String: Any],
           let size = dict["NSURLFileSizeKey"] as? NSNumber {
            return size.int64Value
        }
        return 0
    }
}

// MARK: - Migration

/// Moves the store between layouts: on the first-launch choice, on a Settings
/// location change, and as an idempotent launch sweep that finishes interrupted
/// moves and collects strays (e.g. records written by a still-open tab after a
/// mid-session switch). Every step is per-file and skip-if-done, so it is safe
/// to re-run at any time.
enum WebStorageMigrator {
    /// Remember the source of an in-flight relocation (mode plus, for custom,
    /// the concrete folder — the preference may already point elsewhere) so an
    /// interrupted move resumes at next launch.
    static func recordPendingRelocation(mode: WebStorageMode, customPath: String?) {
        let marker = mode == .custom ? "\(mode.rawValue)|\(customPath ?? "")" : mode.rawValue
        UserDefaults.standard.set(marker, forKey: WebStorageSettings.pendingRelocationKey)
    }

    static func clearPendingRelocation() {
        UserDefaults.standard.removeObject(forKey: WebStorageSettings.pendingRelocationKey)
    }

    /// Launch-time pass: resume any interrupted relocation, then fold whatever
    /// still sits in the legacy local store into the active layout.
    static func sweepAtLaunch() {
        let active = WebLibrary.activeLayout
        if let source = pendingRelocationSource(), relocate(from: source, to: active) {
            clearPendingRelocation()
        }
        let localLayout = WebStorageLayout.local(storeDir: WebLibrary.storeDir)
        if active != localLayout {
            _ = relocate(from: localLayout, to: active)
        }
    }

    /// The layout an interrupted relocation should resume FROM. Returns nil —
    /// keeping the marker for a later launch — when the source root is
    /// currently unreachable (iCloud signed out, external folder unmounted):
    /// resolving a degraded source to the local layout would make the resume
    /// a local→local no-op that clears the marker and strands the real files.
    private static func pendingRelocationSource() -> WebStorageLayout? {
        guard let raw = UserDefaults.standard.string(forKey: WebStorageSettings.pendingRelocationKey) else {
            return nil
        }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard let mode = WebStorageMode(rawValue: parts[0]) else { return nil }
        switch mode {
        case .custom:
            guard parts.count == 2, !parts[1].isEmpty else { return nil }
            let root = URL(fileURLWithPath: parts[1], isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { return nil }
            return .pretty(root: root, recordsInRoot: false, localStoreDir: WebLibrary.storeDir)
        case .icloud:
            guard let root = WebStorageSettings.icloudVellumRoot else { return nil }
            return .pretty(root: root, recordsInRoot: true, localStoreDir: WebLibrary.storeDir)
        case .local:
            return .local(storeDir: WebLibrary.storeDir)
        }
    }

    /// Move records and managed archives from one layout to another. Returns
    /// true when nothing was skipped (an evicted iCloud file that could not be
    /// downloaded stays put and is retried at the next sweep). Derived caches
    /// (plain snapshots, unpacked archive dirs) never move — they live in the
    /// local store regardless of mode.
    @discardableResult
    static func relocate(from source: WebStorageLayout, to dest: WebStorageLayout) -> Bool {
        guard source != dest else { return true }
        let fm = FileManager.default
        var clean = true

        do {
            try fm.createDirectory(at: dest.recordsDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dest.archivesDir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        // Records first, so archive naming below can read titles from their
        // final location. `recordFileNames` reports evicted records under
        // their real name so they are downloaded and moved, not skipped.
        if source.recordsDir != dest.recordsDir {
            for name in WebLibrary.recordFileNames(inDir: source.recordsDir) {
                let src = source.recordsDir.appendingPathComponent(name)
                let dst = dest.recordsDir.appendingPathComponent(name)
                if !WebICloud.materialize(at: src) {
                    if WebICloud.itemExists(at: src) { clean = false }
                    continue
                }
                if !WebLibrary.adoptRecordFile(from: src, to: dst) {
                    clean = false
                }
            }
        }

        // Managed archives: resolve each record's key to a source archive and
        // move it to the destination's naming scheme.
        for name in WebLibrary.recordFileNames(inDir: dest.recordsDir) {
            let key = String(name.dropLast(".json".count))
            guard let src = archiveURL(forKey: key, in: source), WebICloud.itemExists(at: src) else { continue }
            let recordFile = dest.recordsDir.appendingPathComponent(name)
            _ = WebICloud.materialize(at: recordFile)
            let record = WebLibrary.loadRecord(at: recordFile)
            let dst = destinationArchiveURL(
                forKey: key, title: record?.title, url: record?.url ?? "", in: dest)
            guard src != dst else { continue }
            if !WebICloud.materialize(at: src) {
                clean = false
                continue
            }
            if fm.fileExists(atPath: dst.path) {
                WebICloud.removeItem(at: src)
            } else {
                try? fm.createDirectory(
                    at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? fm.moveItem(at: src, to: dst)) == nil {
                    clean = false
                    if let indexPath = dest.indexPath {
                        WebArchiveIndex.removeEntry(forKey: key, at: indexPath)
                    }
                    continue
                }
            }
            if let sourceIndex = source.indexPath {
                WebArchiveIndex.removeEntry(forKey: key, at: sourceIndex)
            }
        }

        // Documents (class-B user data) move AFTER records/archives, per-folder,
        // only when the two layouts actually put them in different homes (custom
        // mode keeps documents local, so local<->custom never moves them). The
        // move/merge is file-level newest-wins via the shared DocumentDataStore
        // primitive; idempotent and never throwing, so an interrupted run just
        // resumes at the next sweep.
        if source.documentsDir != dest.documentsDir {
            let fm2 = FileManager.default
            if let names = try? fm2.contentsOfDirectory(atPath: source.documentsDir.path) {
                for name in names where name != ".DS_Store" {
                    let src = source.documentsDir.appendingPathComponent(name, isDirectory: true)
                    var isDir: ObjCBool = false
                    guard fm2.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue
                    else { continue }
                    let dst = dest.documentsDir.appendingPathComponent(name, isDirectory: true)
                    DocumentDataStore.moveOrMergeDirectory(from: src, into: dst)
                }
            }
        }

        if clean, source.pretty {
            cleanUpEmptyPrettyDirs(of: source)
        }
        return clean
    }

    private static func archiveURL(forKey key: String, in layout: WebStorageLayout) -> URL? {
        if layout.pretty {
            guard let indexPath = layout.indexPath,
                  let name = WebArchiveIndex.fileName(forKey: key, at: indexPath) else { return nil }
            return layout.archivesDir.appendingPathComponent(name)
        }
        return layout.archivesDir.appendingPathComponent("\(key).vellumweb")
    }

    private static func destinationArchiveURL(
        forKey key: String, title: String?, url: String, in layout: WebStorageLayout
    ) -> URL {
        if layout.pretty, let indexPath = layout.indexPath {
            let name = WebArchiveIndex.assignFileName(
                forKey: key, title: title, url: url, at: indexPath, archivesDir: layout.archivesDir)
            return layout.archivesDir.appendingPathComponent(name)
        }
        return layout.archivesDir.appendingPathComponent("\(key).vellumweb")
    }

    /// After a full move out of a pretty root, remove the now-empty structure
    /// we created (never the user's own folder or anything with content).
    private static func cleanUpEmptyPrettyDirs(of layout: WebStorageLayout) {
        let fm = FileManager.default
        if let indexPath = layout.indexPath,
           WebArchiveIndex.load(at: indexPath).entries.isEmpty {
            try? fm.removeItem(at: indexPath)
        }
        // A custom layout's records dir IS the shared local store — home to
        // derived caches for every mode, not something this migration created.
        // Never a removal candidate, even when it happens to be empty.
        var dirs = [layout.archivesDir]
        if layout.recordsDir != WebLibrary.storeDir { dirs.append(layout.recordsDir) }
        // Only the pretty (iCloud) documents dir — which lives under `.vellum`
        // and this migration created — is a removal candidate. A custom layout's
        // documents dir IS the shared local store, never removed (same guard as
        // the records dir above, expressed as "parent is the .vellum internal dir").
        if let internalDir = layout.indexPath?.deletingLastPathComponent(),
           layout.documentsDir.deletingLastPathComponent().standardizedFileURL
            == internalDir.standardizedFileURL {
            dirs.append(layout.documentsDir)
        }
        if let internalDir = layout.indexPath?.deletingLastPathComponent() {
            dirs.append(internalDir) // last: it contains the others above in iCloud mode
        }
        for dir in dirs {
            if (try? fm.contentsOfDirectory(atPath: dir.path)) == [".DS_Store"] {
                try? fm.removeItem(at: dir.appendingPathComponent(".DS_Store"))
            }
            // rmdir, not removeItem: it is atomic and only succeeds while the
            // directory is still empty at the syscall itself. A check-then-
            // remove would recursively delete a record a still-open tab wrote
            // in between (the same concurrency this migration handles
            // elsewhere via `adoptRecordFile`).
            _ = rmdir(dir.path)
        }
    }
}
