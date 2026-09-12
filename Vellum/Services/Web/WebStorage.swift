import Foundation

// Where the web library lives on disk (issue #29 follow-up): the user picks a
// storage location once — iCloud Drive (everything syncs: offline copies AND
// records with highlights/notes/reading position), a custom folder (offline
// copies only; records stay in Application Support and do not sync), or this
// device (the pre-existing layout, everything under Application Support).
//
// iOS adaptation (parity plan decision #5): iCloud resolves through Vellum's
// fixed explicit ubiquity container identifier (`SyncedContainerIdentifier.vellum`),
// never through a nil/per-bundle-ID lookup. The result is nil without an iCloud
// entitlement or when signed out, in which case the mode gracefully degrades to
// `.local`. The lookup can block on first use, so it is resolved OFF the main
// thread (`resolveICloudRoot`) and cached by the shared container-root resolver;
// the user-visible library lives under the container's `Documents/Vellum/` so
// it appears in the Files app. A custom folder is a security-scoped URL from
// UIDocumentPicker (Phase 4): we persist bookmark `Data`, resolve it back to a
// URL, and hold `startAccessingSecurityScopedResource` for the process while
// the mode is active.
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
    static let customBookmarkKey = "web.storage.customBookmark"
    static let autoSaveKey = "web.storage.autoSavePages"
    static let pendingRelocationKey = "web.storage.pendingRelocationFrom"

    // Test seams (same idiom as WebLibrary.storeDirOverride).
    nonisolated(unsafe) static var modeOverride: WebStorageMode?
    nonisolated(unsafe) static var customRootOverride: URL?
    nonisolated(unsafe) static var autoSavePagesOverride: Bool?

    /// Nil until the user has made the first-launch choice.
    static var chosenMode: WebStorageMode? {
        if let modeOverride { return modeOverride }
        guard let raw = UserDefaults.standard.string(forKey: modeKey) else { return nil }
        return WebStorageMode(rawValue: raw)
    }

    /// What path resolution actually uses: the chosen mode, degraded to
    /// `.local` when its root is unusable (iCloud unavailable, custom folder
    /// deleted) so the app keeps working instead of writing into a void.
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

    static func setMode(_ mode: WebStorageMode, customPath: String? = nil, customBookmark: Data? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(mode.rawValue, forKey: modeKey)
        if mode == .custom {
            if let customBookmark { defaults.set(customBookmark, forKey: customBookmarkKey) }
            if let customPath { defaults.set(customPath, forKey: customPathKey) }
        }
    }

    /// Persist the security-scoped bookmark for a user-picked custom folder.
    static func setCustomBookmark(_ data: Data) {
        UserDefaults.standard.set(data, forKey: customBookmarkKey)
    }

    // MARK: iCloud ubiquity container (resolved off-main, cached)

    /// Resolve the iCloud ubiquity container. Blocking on first call, so this
    /// MUST run off the main thread (launch sweep / background task). Caches the
    /// result — including nil when there is no entitlement or the user is signed
    /// out — so subsequent reads are cheap. Callers degrade to `.local` on nil.
    static func resolveICloudRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard RuntimeProfile.current.syncEnabled else { return }
        _ = VellumUbiquityContainerRoot.documentsRoot(
            for: .vellum, environment: environment)
    }

    /// iCloud Drive's real on-disk root, nil until resolved or when unavailable.
    /// Production reads only the cached ubiquity container (resolved off the
    /// main thread by `resolveICloudRoot`) so UI-facing path checks never perform
    /// a blocking lookup.
    static var icloudDriveRoot: URL? {
        VellumUbiquityContainerRoot.cachedDocumentsRoot(for: .vellum)
    }

    static var icloudVellumRoot: URL? {
        icloudDriveRoot?.appendingPathComponent("Vellum", isDirectory: true)
    }

    // MARK: Custom folder (security-scoped bookmark)

    /// Resolved custom URLs on which we hold an active security scope, so we
    /// only `startAccessingSecurityScopedResource` once per URL.
    private nonisolated(unsafe) static var accessedCustomURLs: Set<URL> = []
    private static let customLock = NSLock()

    static var customRoot: URL? {
        if let customRootOverride { return customRootOverride }
        // iOS: a user-picked folder is a security-scoped bookmark, not a path.
        if let data = UserDefaults.standard.data(forKey: customBookmarkKey),
           let url = resolveBookmark(data) {
            return url
        }
        // Fallback: a plain stored path (tests / non-scoped folders).
        guard let path = UserDefaults.standard.string(forKey: customPathKey),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        return url
    }

    /// Resolve a security-scoped bookmark to a folder URL and begin accessing it
    /// (once per URL, held for the process — the folder is active for the whole
    /// session while custom mode is selected). Returns nil when the bookmark is
    /// unresolvable (folder deleted / permission revoked) so the mode degrades.
    private static func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        else { return nil }
        customLock.lock()
        let alreadyAccessing = accessedCustomURLs.contains(url)
        customLock.unlock()
        if !alreadyAccessing {
            guard url.startAccessingSecurityScopedResource() else { return nil }
            customLock.lock()
            accessedCustomURLs.insert(url)
            customLock.unlock()
        }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
              isDir.boolValue else { return nil }
        // Refresh a stale bookmark so a moved/renamed folder keeps resolving.
        if stale, let fresh = try? url.bookmarkData() {
            setCustomBookmark(fresh)
        }
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
    /// documents stay in the app container); in local mode it is the default
    /// app-container location.
    var documentsDir: URL
    /// Pretty modes name archives after the page title (via the index);
    /// the local mode keeps the legacy `<key>.vellumweb` hashed names.
    var pretty: Bool
    /// `.vellum/index.json` next to the archives (pretty modes only).
    var indexPath: URL?

    /// True only for the fixed iCloud layout. A custom pretty folder still
    /// keeps records/documents local and must never construct a coordinator.
    var requiresCoordination: Bool {
        guard let internalDir = indexPath?.deletingLastPathComponent() else { return false }
        return recordsDir.deletingLastPathComponent().standardizedFileURL
                == internalDir.standardizedFileURL
            && documentsDir.deletingLastPathComponent().standardizedFileURL
                == internalDir.standardizedFileURL
    }

    /// Reading positions follow class-B data: fixed iCloud syncs them under
    /// `.vellum/positions`; local and custom modes keep the existing app-data
    /// sibling of `documents/`.
    var positionsDir: URL {
        if requiresCoordination, let internalDir = indexPath?.deletingLastPathComponent() {
            return internalDir.appendingPathComponent("positions", isDirectory: true)
        }
        return documentsDir.deletingLastPathComponent()
            .appendingPathComponent("positions", isDirectory: true)
    }

    /// The documents/ home for a local (app-container) layout. Derived from
    /// `storeDir` (a sibling of `web/` under appData) so the `storeDirOverride`
    /// test seam covers it too, and so it stays byte-for-byte the pre-existing
    /// `appDataDir/documents` location in production.
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

    /// Test seam: when set, `materialize` delegates to this for an evicted item
    /// instead of driving the real iCloud download machinery (unavailable in unit
    /// tests, and its poll would block for the whole timeout). Return true to
    /// simulate a successful download — the closure should itself create the real
    /// file if the test needs to read it — or false to simulate offline. Nil in
    /// production.
    nonisolated(unsafe) static var materializeOverride: ((URL) -> Bool)?

    /// Ensure the real bytes are local, triggering a download for an evicted
    /// item and polling until it lands or the timeout passes. Blocking — call
    /// off the main thread only. Returns false when the file neither exists
    /// nor could be downloaded in time (e.g. offline).
    static func materialize(at url: URL, timeout: TimeInterval = 10) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) { return true }
        if let materializeOverride { return materializeOverride(url) }
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
    static func sweepAtLaunchDirectForTests() {
        let active = WebLibrary.activeLayout
        if let source = pendingRelocationSource(), relocateDirect(from: source, to: active) {
            clearPendingRelocation()
        }
        let localLayout = WebStorageLayout.local(storeDir: WebLibrary.storeDir)
        if active != localLayout {
            _ = relocateDirect(from: localLayout, to: active)
        }
    }

    /// Production launch sweep. Each leg borrows its direct/coordinated file
    /// stores from the coordinator while normal storage traffic is stopped.
    static func sweepAtLaunch(coordinator: StorageCoordinator) async {
        let active = WebLibrary.activeLayout
        if let source = pendingRelocationSource() {
            let moved = await coordinator.performExclusiveStorageRelocation(
                from: source,
                to: active
            ) { sourceContext, destinationContext in
                guard let sourceContext, let destinationContext else { return false }
                return await relocate(
                    from: source,
                    to: active,
                    sourceStore: sourceContext.fileStore,
                    destinationStore: destinationContext.fileStore)
            }
            if moved { clearPendingRelocation() }
        }

        let localLayout = WebStorageLayout.local(storeDir: WebLibrary.storeDir)
        guard active != localLayout else { return }
        _ = await coordinator.performExclusiveStorageRelocation(
            from: localLayout,
            to: active
        ) { sourceContext, destinationContext in
            guard let sourceContext, let destinationContext else { return false }
            return await relocate(
                from: localLayout,
                to: active,
                sourceStore: sourceContext.fileStore,
                destinationStore: destinationContext.fileStore)
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
    static func relocateDirect(from source: WebStorageLayout, to dest: WebStorageLayout) -> Bool {
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
                    // A folder whose iCloud files can't materialize is SKIPPED
                    // (returns false), so `clean` stays false and the pending
                    // marker is kept for the next sweep — never moved as stubs.
                    if !DocumentDataStore.moveOrMergeDirectory(from: src, into: dst) { clean = false }
                }
            }
        }

        // Reading-position history belongs beside the class-B data it
        // describes. The direct implementation can reuse the same recursive,
        // newest-wins primitive as documents; the coordinated implementation
        // below transfers each file through LibraryFileStore instead.
        if source.positionsDir != dest.positionsDir,
           !DocumentDataStore.moveOrMergeDirectory(
                from: source.positionsDir,
                into: dest.positionsDir) {
            clean = false
        }

        if clean, source.pretty {
            cleanUpEmptyPrettyDirs(of: source)
        }
        return clean
    }

    /// Relocate every user-owned storage class. The caller supplies the access
    /// discipline for each side, so an iCloud URL cannot accidentally fall
    /// through to FileManager/WebICloud. A non-current item is left at the
    /// source and makes the result false, preserving the pending marker.
    @discardableResult
    static func relocate(
        from source: WebStorageLayout,
        to destination: WebStorageLayout,
        sourceStore: any LibraryFileStore,
        destinationStore: any LibraryFileStore
    ) async -> Bool {
        guard source != destination else { return true }

        // Preserve the mature byte-for-byte local/custom implementation when
        // neither side needs coordination.
        if !sourceStore.isCoordinated, !destinationStore.isCoordinated {
            return relocateDirect(from: source, to: destination)
        }

        var clean = true
        if source.recordsDir != destination.recordsDir {
            clean = await relocateRecords(
                from: source,
                to: destination,
                sourceStore: sourceStore,
                destinationStore: destinationStore) && clean
        }
        clean = await relocateArchives(
            from: source,
            to: destination,
            sourceStore: sourceStore,
            destinationStore: destinationStore) && clean
        clean = await relocateTree(
            from: source.documentsDir,
            to: destination.documentsDir,
            sourceStore: sourceStore,
            destinationStore: destinationStore) && clean
        clean = await relocateTree(
            from: source.positionsDir,
            to: destination.positionsDir,
            sourceStore: sourceStore,
            destinationStore: destinationStore) && clean
        return clean
    }

    private static func relocateRecords(
        from source: WebStorageLayout,
        to destination: WebStorageLayout,
        sourceStore: any LibraryFileStore,
        destinationStore: any LibraryFileStore
    ) async -> Bool {
        let sourceEntries: [LibraryFileEntry]
        let destinationEntries: [LibraryFileEntry]
        do {
            sourceEntries = try await sourceStore.list(source.recordsDir, suffix: ".json")
            destinationEntries = try await destinationStore.list(
                destination.recordsDir, suffix: ".json")
        } catch {
            return false
        }
        let destinationByName = Dictionary(
            uniqueKeysWithValues: destinationEntries.map { ($0.name, $0) })
        var clean = true

        for entry in sourceEntries {
            guard entry.readiness.isReady else {
                clean = false
                continue
            }
            let destinationURL = destination.recordsDir.appendingPathComponent(entry.name)
            do {
                guard let sourceData = try await sourceStore.read(entry.url) else {
                    clean = false
                    continue
                }
                let output: Data
                if let existing = destinationByName[entry.name] {
                    guard existing.readiness.isReady,
                          let destinationData = try await destinationStore.read(destinationURL),
                          let merged = mergedRecord(sourceData, into: destinationData)
                    else {
                        clean = false
                        continue
                    }
                    output = merged
                } else {
                    output = sourceData
                }
                try await destinationStore.replace(destinationURL, with: output)
                try await sourceStore.remove(entry.url)
            } catch {
                clean = false
            }
        }
        return clean
    }

    private static func mergedRecord(_ source: Data, into destination: Data) -> Data? {
        guard let incoming = try? JSONDecoder().decode(WebPageRecord.self, from: source),
              var current = try? JSONDecoder().decode(WebPageRecord.self, from: destination)
        else { return nil }
        WebArchive.mergeAnnotations(&current.annotations, incoming: incoming.annotations)
        current.saved = current.saved || incoming.saved
        current.savedAt = current.savedAt ?? incoming.savedAt
        current.title = current.title ?? incoming.title
        current.pageCount = current.pageCount ?? incoming.pageCount
        current.lastPage = current.lastPage ?? incoming.lastPage
        current.openedAt = current.openedAt ?? incoming.openedAt
        return try? WebLibrary.jsonEncoderPretty.encode(current)
    }

    private static func relocateArchives(
        from source: WebStorageLayout,
        to destination: WebStorageLayout,
        sourceStore: any LibraryFileStore,
        destinationStore: any LibraryFileStore
    ) async -> Bool {
        let sourceArchives: [LibraryFileEntry]
        let destinationArchives: [LibraryFileEntry]
        do {
            sourceArchives = try await sourceStore.list(
                source.archivesDir, suffix: ".vellumweb")
            destinationArchives = try await destinationStore.list(
                destination.archivesDir, suffix: ".vellumweb")
        } catch {
            return false
        }

        var sourceIndex: WebArchiveIndex.Contents
        var destinationIndex: WebArchiveIndex.Contents
        do {
            sourceIndex = try await loadIndex(for: source, store: sourceStore)
            destinationIndex = try await loadIndex(for: destination, store: destinationStore)
        } catch {
            return false
        }

        let sourceByName = Dictionary(uniqueKeysWithValues: sourceArchives.map { ($0.name, $0) })
        var destinationByName = Dictionary(
            uniqueKeysWithValues: destinationArchives.map { ($0.name, $0) })
        var occupied = Set(destinationByName.keys).union(destinationIndex.entries.values)
        var sourceIndexChanged = false
        var clean = true

        if source.pretty {
            let indexedNames = Set(sourceIndex.entries.values)
            if sourceArchives.contains(where: { !indexedNames.contains($0.name) }) {
                // A pretty archive without an index key cannot safely be
                // renamed to the hashed local form. Leave it at the source and
                // keep recovery pending rather than silently orphaning it.
                clean = false
            }
        }

        let keys: [String]
        if source.pretty {
            keys = sourceIndex.entries.keys.sorted()
        } else {
            keys = sourceArchives.map { String($0.name.dropLast(".vellumweb".count)) }.sorted()
        }

        for key in keys {
            let sourceName = source.pretty
                ? sourceIndex.entries[key]
                : "\(key).vellumweb"
            guard let sourceName, let sourceEntry = sourceByName[sourceName] else {
                // An index entry left behind by an already-completed copy is
                // stale and safe to prune; a missing local archive needs no work.
                if source.pretty, sourceIndex.entries.removeValue(forKey: key) != nil {
                    sourceIndexChanged = true
                }
                continue
            }
            guard sourceEntry.readiness.isReady else {
                clean = false
                continue
            }

            let destinationName: String
            if destination.pretty {
                if let existing = destinationIndex.entries[key] {
                    destinationName = existing
                } else {
                    let recordURL = destination.recordsDir.appendingPathComponent("\(key).json")
                    do {
                        guard let data = try await destinationStore.read(recordURL),
                              let record = try? JSONDecoder().decode(WebPageRecord.self, from: data)
                        else {
                            clean = false
                            continue
                        }
                        let base = WebArchiveIndex.sanitizedBaseName(
                            title: record.title, url: record.url)
                        var candidate = "\(base).vellumweb"
                        var counter = 2
                        while occupied.contains(candidate) {
                            candidate = "\(base) \(counter).vellumweb"
                            counter += 1
                        }
                        destinationIndex.entries[key] = candidate
                        try await saveIndex(
                            destinationIndex, for: destination, store: destinationStore)
                        occupied.insert(candidate)
                        destinationName = candidate
                    } catch {
                        clean = false
                        continue
                    }
                }
            } else {
                destinationName = "\(key).vellumweb"
            }

            let destinationURL = destination.archivesDir.appendingPathComponent(destinationName)
            do {
                guard let bytes = try await sourceStore.read(sourceEntry.url) else {
                    clean = false
                    continue
                }
                if let existing = destinationByName[destinationName] {
                    guard existing.readiness.isReady,
                          try await destinationStore.read(destinationURL) != nil
                    else {
                        clean = false
                        continue
                    }
                } else {
                    try await destinationStore.replace(destinationURL, with: bytes)
                    destinationByName[destinationName] = LibraryFileEntry(
                        url: destinationURL,
                        name: destinationName,
                        readiness: .current,
                        byteSize: Int64(bytes.count),
                        contentModifiedAt: sourceEntry.contentModifiedAt)
                }
                try await sourceStore.remove(sourceEntry.url)
                if source.pretty, sourceIndex.entries.removeValue(forKey: key) != nil {
                    sourceIndexChanged = true
                }
            } catch {
                clean = false
            }
        }

        if sourceIndexChanged {
            do {
                try await saveIndex(sourceIndex, for: source, store: sourceStore)
            } catch {
                clean = false
            }
        }
        return clean
    }

    private static func loadIndex(
        for layout: WebStorageLayout,
        store: any LibraryFileStore
    ) async throws -> WebArchiveIndex.Contents {
        guard let indexPath = layout.indexPath,
              let data = try await store.read(indexPath)
        else { return WebArchiveIndex.Contents() }
        return try JSONDecoder().decode(WebArchiveIndex.Contents.self, from: data)
    }

    private static func saveIndex(
        _ contents: WebArchiveIndex.Contents,
        for layout: WebStorageLayout,
        store: any LibraryFileStore
    ) async throws {
        guard let indexPath = layout.indexPath else { return }
        if contents.entries.isEmpty {
            try await store.remove(indexPath)
        } else {
            try await store.replace(
                indexPath, with: try WebLibrary.jsonEncoderPretty.encode(contents))
        }
    }

    private struct RelativeFile: Sendable {
        var relativePath: String
        var entry: LibraryFileEntry
    }

    private static func relocateTree(
        from sourceRoot: URL,
        to destinationRoot: URL,
        sourceStore: any LibraryFileStore,
        destinationStore: any LibraryFileStore
    ) async -> Bool {
        guard sourceRoot != destinationRoot else { return true }
        let sourceFiles: [RelativeFile]
        let destinationFiles: [RelativeFile]
        do {
            sourceFiles = try await treeFiles(in: sourceRoot, store: sourceStore)
            destinationFiles = try await treeFiles(in: destinationRoot, store: destinationStore)
        } catch {
            return false
        }
        let destinationByPath = Dictionary(
            uniqueKeysWithValues: destinationFiles.map { ($0.relativePath, $0.entry) })
        var clean = true

        for file in sourceFiles {
            guard file.entry.readiness.isReady else {
                clean = false
                continue
            }
            let destinationURL = destinationRoot.appendingPathComponent(file.relativePath)
            do {
                guard let sourceData = try await sourceStore.read(file.entry.url) else {
                    clean = false
                    continue
                }
                if let existing = destinationByPath[file.relativePath] {
                    guard existing.readiness.isReady,
                          try await destinationStore.read(destinationURL) != nil
                    else {
                        clean = false
                        continue
                    }
                    if shouldReplace(existing: existing, with: file.entry) {
                        try await destinationStore.replace(destinationURL, with: sourceData)
                    }
                } else {
                    try await destinationStore.replace(destinationURL, with: sourceData)
                }
                try await sourceStore.remove(file.entry.url)
            } catch {
                clean = false
            }
        }
        return clean
    }

    private static func shouldReplace(
        existing: LibraryFileEntry,
        with incoming: LibraryFileEntry
    ) -> Bool {
        guard let incomingDate = incoming.contentModifiedAt else { return false }
        guard let existingDate = existing.contentModifiedAt else { return true }
        return incomingDate > existingDate
    }

    private static func treeFiles(
        in root: URL,
        store: any LibraryFileStore
    ) async throws -> [RelativeFile] {
        let entries = try await store.list(root, suffix: nil)
        return try await treeFiles(
            entries,
            relativePrefix: "",
            depth: 0,
            store: store)
    }

    private static func treeFiles(
        _ entries: [LibraryFileEntry],
        relativePrefix: String,
        depth: Int,
        store: any LibraryFileStore
    ) async throws -> [RelativeFile] {
        var files: [RelativeFile] = []
        for entry in entries {
            let relative = relativePrefix.isEmpty
                ? entry.name
                : "\(relativePrefix)/\(entry.name)"
            if entry.url.pathExtension.isEmpty, depth < 8 {
                do {
                    let children = try await store.list(entry.url, suffix: nil)
                    if !children.isEmpty {
                        files += try await treeFiles(
                            children,
                            relativePrefix: relative,
                            depth: depth + 1,
                            store: store)
                        continue
                    }
                    // Empty document/attachments/quarantine directories carry
                    // no bytes. A deeper extensionless leaf can still be a real
                    // attachment, so let the read path decide at depth >= 2.
                    if depth < 2 { continue }
                } catch {
                    // DirectLibraryFileStore cannot list a regular file URL;
                    // that is the signal that an extensionless attachment is a
                    // leaf. Coordinated metadata listing simply returns empty.
                }
            }
            files.append(RelativeFile(relativePath: relative, entry: entry))
        }
        return files
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
        if let internalDir = layout.indexPath?.deletingLastPathComponent(),
           layout.positionsDir.deletingLastPathComponent().standardizedFileURL
            == internalDir.standardizedFileURL {
            dirs.append(layout.positionsDir)
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
