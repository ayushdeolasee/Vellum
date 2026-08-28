import Foundation

// Per-document user-data folder (class B in plans/storage-design.html §2/§4):
//   <appData>/documents/<storageKey>/
//     ├── meta.json        kind, title, last-known path, last-opened
//     ├── scratchpad.md     markdown; image refs are RELATIVE (attachments/<id>.<ext>)
//     └── attachments/      region snapshots + dropped images, scoped to this doc
//
// `storageKey` is DocumentIdentity.storageKey(for:) — the /VellumDocId (or the
// path-hash fallback until one is stamped) for PDFs, the sha256 URL hash for web
// docs. One folder per document; a keystroke rewrites one small scratchpad.md,
// not an all-documents blob. Writes use the tmp-file + rename(2) atomic idiom
// (WebLibrary.saveRecord) and THROW on failure — this is irreplaceable user data,
// not a disposable cache.
enum DocumentDataStore {
    /// Test seam: point the whole document store at a scratch directory (mirrors
    /// `WebLibrary.storeDirOverride` / `ScratchpadAttachmentStore.directoryOverride`).
    nonisolated(unsafe) static var rootDirectoryOverride: URL?

    /// The async class-B boundary used by production whenever a storage
    /// coordinator is available. Synchronous methods below remain the direct
    /// local/custom implementation and the test override; iCloud callers must
    /// enter through these overloads so discovery and byte access stay behind
    /// `LibraryFileStore`.
    private struct Access: Sendable {
        let store: any LibraryFileStore
        let documentsRoot: URL
        let fallbackRoot: URL?
    }

    private static func withAccess<T: Sendable>(
        coordinator: StorageCoordinator,
        _ operation: @escaping @Sendable (Access) async throws -> T
    ) async throws -> T {
        if let rootDirectoryOverride {
            return try await operation(Access(
                store: DirectLibraryFileStore(), documentsRoot: rootDirectoryOverride,
                fallbackRoot: nil))
        }
        return try await coordinator.withStorageContext { context in
            let localRoot = WebStorageLayout.local(storeDir: WebLibrary.storeDir).documentsDir
            let activeRoot = context.layout.documentsDir
            return try await operation(Access(
                store: context.fileStore,
                documentsRoot: activeRoot,
                fallbackRoot: localRoot.standardizedFileURL == activeRoot.standardizedFileURL
                    ? nil : localRoot))
        }
    }

    private static func safeStorageKey(_ key: String) -> String {
        DocumentIdentity.isCanonicalKey(key) ? key : DocumentIdentity.sha256Hex(key)
    }

    private static func documentDir(forKey key: String, root: URL) -> URL {
        root.appendingPathComponent(safeStorageKey(key), isDirectory: true)
    }

    private static func readData(
        forKey key: String,
        relativeName: String,
        coordinator: StorageCoordinator
    ) async throws -> Data? {
        try await withAccess(coordinator: coordinator) { access in
            try await readData(forKey: key, relativeName: relativeName, access: access)
        }
    }

    private static func readData(
        forKey key: String,
        relativeName: String,
        access: Access
    ) async throws -> Data? {
        let active = documentDir(forKey: key, root: access.documentsRoot)
            .appendingPathComponent(relativeName)
        do {
            if let data = try await access.store.read(active) { return data }
        } catch let error as LibraryFileError {
            guard case .notDownloaded = error,
                  let fallbackRoot = access.fallbackRoot else { throw error }
            let fallback = documentDir(forKey: key, root: fallbackRoot)
                .appendingPathComponent(relativeName)
            if let data = try await DirectLibraryFileStore().read(fallback) { return data }
            throw error
        }
        guard let fallbackRoot = access.fallbackRoot else { return nil }
        return try await DirectLibraryFileStore().read(
            documentDir(forKey: key, root: fallbackRoot)
                .appendingPathComponent(relativeName))
    }

    private static func replaceData(
        _ data: Data,
        forKey key: String,
        relativeName: String,
        coordinator: StorageCoordinator
    ) async throws {
        try await withAccess(coordinator: coordinator) { access in
            let destination = documentDir(forKey: key, root: access.documentsRoot)
                .appendingPathComponent(relativeName)
            // A coordinated read is the readiness guard. A stale/download-pending
            // item throws here, so a newly encoded empty/default value cannot
            // replace remote bytes this device has not actually read.
            _ = try await access.store.read(destination)
            try await access.store.replace(destination, with: data)
        }
    }

    private static func removeData(
        forKey key: String,
        relativeName: String,
        coordinator: StorageCoordinator,
        refuseUnavailable: Bool
    ) async throws {
        try await withAccess(coordinator: coordinator) { access in
            let active = documentDir(forKey: key, root: access.documentsRoot)
                .appendingPathComponent(relativeName)
            if refuseUnavailable { _ = try await access.store.read(active) }
            try await access.store.remove(active)
            if let fallbackRoot = access.fallbackRoot {
                try await DirectLibraryFileStore().remove(
                    documentDir(forKey: key, root: fallbackRoot)
                        .appendingPathComponent(relativeName))
            }
        }
    }

    /// The documents/ home for the user's chosen storage location, resolved PER
    /// OPERATION through the active web-storage layout (so a mode change takes
    /// effect on the next read/write, never a value cached at init). In iCloud
    /// mode this is `<iCloud root>/.vellum/documents` (notes and AI conversations
    /// sync); in local/custom mode it is the Application-Support default. The
    /// test override wins, matching the seams elsewhere.
    static var rootDirectory: URL {
        if let rootDirectoryOverride { return rootDirectoryOverride }
        return WebLibrary.activeLayout.documentsDir
    }

    /// The folder for a storage key. CENTRAL SECURITY GUARD: a key is used
    /// verbatim only when it is canonical (a lowercase UUID / bare-hex sha256 —
    /// every id the app mints). An attacker-influenced value — a crafted PDF's
    /// embedded /VellumDocId or a hostile `.vellum` manifest `doc_id` carrying
    /// path separators or `..` traversal — is deterministically replaced by its
    /// sha256, so it can never escape `documents/` (the app is unsandboxed). The
    /// mapping is total and stable, so every op on one key still agrees on one
    /// folder; the identity sources reject such values earlier so this only ever
    /// fires as a defense-in-depth backstop.
    static func documentDir(forKey key: String) -> URL {
        let safe = DocumentIdentity.isCanonicalKey(key) ? key : DocumentIdentity.sha256Hex(key)
        return rootDirectory.appendingPathComponent(safe, isDirectory: true)
    }

    static func attachmentsDir(forKey key: String) -> URL {
        documentDir(forKey: key).appendingPathComponent("attachments", isDirectory: true)
    }

    /// The LOCAL (Application-Support default) folder for a key, resolved
    /// independently of the active layout. During a pending Local→iCloud
    /// relocation the active `rootDirectory` flips to the iCloud home the instant
    /// the mode changes, but the launch sweep may not have MOVED this document's
    /// folder yet — so a read against the active dir finds nothing while the real
    /// note still sits locally. The read paths fall back here so the note/chat
    /// loads real bytes instead of degrading to empty (which the empty-state save
    /// path could then turn into a delete). nil when the active layout already IS
    /// the local dir (nothing to fall back to) or when a test override owns the
    /// whole tree.
    static func fallbackDocumentDir(forKey key: String) -> URL? {
        guard rootDirectoryOverride == nil else { return nil }
        let localDocs = WebStorageLayout.local(storeDir: WebLibrary.storeDir).documentsDir
        guard localDocs.standardizedFileURL != rootDirectory.standardizedFileURL else { return nil }
        let safe = DocumentIdentity.isCanonicalKey(key) ? key : DocumentIdentity.sha256Hex(key)
        return localDocs.appendingPathComponent(safe, isDirectory: true)
    }

    /// The path a synced file should be READ from: the active-layout location
    /// when it holds a real (materialized) copy, else the local fallback location
    /// when that holds one, else the active path (so a genuinely-absent file still
    /// reports its canonical location). Writes always target the active dir via
    /// the `…Path(forKey:)` helpers — only reads consult the fallback.
    private static func readPath(forKey key: String, relativeName: String) -> URL {
        let active = documentDir(forKey: key).appendingPathComponent(relativeName)
        if FileManager.default.fileExists(atPath: active.path) { return active }
        if let fallbackDir = fallbackDocumentDir(forKey: key) {
            let fallback = fallbackDir.appendingPathComponent(relativeName)
            if FileManager.default.fileExists(atPath: fallback.path) { return fallback }
        }
        return active
    }

    static func metaPath(forKey key: String) -> URL {
        documentDir(forKey: key).appendingPathComponent("meta.json")
    }

    static func scratchpadPath(forKey key: String) -> URL {
        documentDir(forKey: key).appendingPathComponent("scratchpad.md")
    }

    // MARK: - meta.json

    struct Meta: Codable, Equatable {
        var version: Int
        var kind: String
        var title: String?
        var lastKnownPath: String
        var lastOpened: String

        enum CodingKeys: String, CodingKey {
            case version
            case kind
            case title
            case lastKnownPath = "last_known_path"
            case lastOpened = "last_opened"
        }
    }

    static func loadMeta(forKey key: String) -> Meta? {
        guard let data = try? Data(contentsOf: readPath(forKey: key, relativeName: "meta.json"))
        else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    static func loadMeta(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> Meta? {
        guard let data = try await readData(
            forKey: key, relativeName: "meta.json", coordinator: coordinator)
        else { return nil }
        return try JSONDecoder().decode(Meta.self, from: data)
    }

    /// Upsert the document's meta.json, refreshing `last_opened`. Called from the
    /// per-pane document load path. A previously stored title is kept when the
    /// incoming document has none.
    ///
    /// By default this writes ONLY when the folder already holds data files or a
    /// meta.json already exists — a merely-opened document must not grow a
    /// synced folder holding nothing but a stamp (§8). The data-creating paths
    /// (a saved note, a saved conversation) pass `force: true` to guarantee the
    /// stamp so recents can re-resolve the document by its docId later.
    static func touch(document: DocumentInfo, force: Bool = false) throws {
        let key = DocumentIdentity.storageKey(for: document)
        if !force, !hasDataFiles(forKey: key),
           !FileManager.default.fileExists(atPath: metaPath(forKey: key).path) {
            return
        }
        let existing = loadMeta(forKey: key)
        let meta = Meta(
            version: 1,
            kind: document.kind.rawValue,
            title: document.title ?? existing?.title,
            lastKnownPath: document.pdfPath,
            lastOpened: WebLibrary.rfc3339Now())
        try writeAtomic(try WebLibrary.jsonEncoderPretty.encode(meta), to: metaPath(forKey: key),
                        label: "document meta")
    }

    static func touch(
        document: DocumentInfo,
        force: Bool = false,
        coordinator: StorageCoordinator
    ) async throws {
        let key = DocumentIdentity.storageKey(for: document)
        let existing = try await loadMeta(forKey: key, coordinator: coordinator)
        if !force, existing == nil,
           try await hasDataFiles(forKey: key, coordinator: coordinator) == false {
            return
        }
        let meta = Meta(
            version: 1,
            kind: document.kind.rawValue,
            title: document.title ?? existing?.title,
            lastKnownPath: document.pdfPath,
            lastOpened: WebLibrary.rfc3339Now())
        try await replaceData(
            try WebLibrary.jsonEncoderPretty.encode(meta), forKey: key,
            relativeName: "meta.json", coordinator: coordinator)
    }

    // MARK: - scratchpad.md

    static func scratchpadExists(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: readPath(forKey: key, relativeName: "scratchpad.md").path)
    }

    static func scratchpadExists(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> Bool {
        try await readData(
            forKey: key, relativeName: "scratchpad.md", coordinator: coordinator) != nil
    }

    /// The persisted (relative-ref) markdown for a document, or "" if none.
    static func loadScratchpad(forKey key: String) -> String {
        (try? String(contentsOf: readPath(forKey: key, relativeName: "scratchpad.md"), encoding: .utf8)) ?? ""
    }

    static func loadScratchpad(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> String {
        guard let data = try await readData(
            forKey: key, relativeName: "scratchpad.md", coordinator: coordinator)
        else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Atomically write scratchpad.md. Throws on write failure (user data) — and
    /// refuses to clobber a real-but-evicted iCloud copy (see `guardEvicted`).
    static func saveScratchpad(forKey key: String, text: String) throws {
        let path = scratchpadPath(forKey: key)
        try guardEvicted(at: path, label: "notes")
        try writeAtomic(Data(text.utf8), to: path, label: "scratchpad note")
    }

    static func saveScratchpad(
        forKey key: String, text: String, coordinator: StorageCoordinator
    ) async throws {
        try await replaceData(
            Data(text.utf8), forKey: key, relativeName: "scratchpad.md",
            coordinator: coordinator)
    }

    /// Delete scratchpad.md (delete-means-delete; §8). Best-effort — a missing
    /// file is already the desired end state. Skips an iCloud-evicted copy: an
    /// empty-note save must not delete real notes that just haven't downloaded
    /// (explicit Storage-pane deletes bypass this via their own removeItem).
    static func removeScratchpad(forKey key: String) {
        removeSyncedFile(forKey: key, relativeName: "scratchpad.md")
    }

    static func removeScratchpad(
        forKey key: String, coordinator: StorageCoordinator
    ) async {
        try? await removeScratchpadSafely(forKey: key, coordinator: coordinator)
    }

    /// Throwing form used by the live Scratchpad write queue. A failed or
    /// not-downloaded read must keep the edit dirty instead of being reported as
    /// a successful clear.
    static func removeScratchpadSafely(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws {
        try await removeData(
            forKey: key, relativeName: "scratchpad.md", coordinator: coordinator,
            refuseUnavailable: true)
    }

    /// Remove a synced file from BOTH the active-layout dir and the local
    /// fallback dir (delete-means-delete across both roots during a pending
    /// relocation). Each removal spares an iCloud-evicted placeholder: an
    /// empty-note save must not delete real data that just hasn't downloaded
    /// (explicit Storage-pane deletes bypass this via `WebICloud.removeItem`).
    private static func removeSyncedFile(forKey key: String, relativeName: String) {
        var paths = [documentDir(forKey: key).appendingPathComponent(relativeName)]
        if let fallbackDir = fallbackDocumentDir(forKey: key) {
            paths.append(fallbackDir.appendingPathComponent(relativeName))
        }
        for path in paths where !isEvictedPlaceholder(at: path) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    // MARK: - conversations.json

    static func conversationsPath(forKey key: String) -> URL {
        documentDir(forKey: key).appendingPathComponent("conversations.json")
    }

    static func conversationsExist(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: readPath(forKey: key, relativeName: "conversations.json").path)
    }

    static func conversationsExist(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> Bool {
        try await readData(
            forKey: key, relativeName: "conversations.json", coordinator: coordinator) != nil
    }

    /// Raw conversations.json bytes for a document, or nil if none.
    static func loadConversationsData(forKey key: String) -> Data? {
        try? Data(contentsOf: readPath(forKey: key, relativeName: "conversations.json"))
    }

    static func loadConversationsData(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> Data? {
        try await readData(
            forKey: key, relativeName: "conversations.json", coordinator: coordinator)
    }

    /// Atomically write conversations.json. Throws on write failure (user data) —
    /// and refuses to clobber a real-but-evicted iCloud copy (see `guardEvicted`).
    static func saveConversationsData(forKey key: String, data: Data) throws {
        let path = conversationsPath(forKey: key)
        try guardEvicted(at: path, label: "AI conversations")
        try writeAtomic(data, to: path, label: "conversations")
    }

    static func saveConversationsData(
        forKey key: String, data: Data, coordinator: StorageCoordinator
    ) async throws {
        try await replaceData(
            data, forKey: key, relativeName: "conversations.json",
            coordinator: coordinator)
    }

    /// Delete conversations.json (delete-means-delete; §8). Best-effort — a
    /// missing file is already the desired end state. Skips an iCloud-evicted
    /// copy so an empty save can't delete real chat that hasn't downloaded.
    static func removeConversations(forKey key: String) {
        removeSyncedFile(forKey: key, relativeName: "conversations.json")
    }

    static func removeConversations(
        forKey key: String, coordinator: StorageCoordinator
    ) async {
        try? await removeData(
            forKey: key, relativeName: "conversations.json", coordinator: coordinator,
            refuseUnavailable: true)
    }

    // MARK: - Folder lifecycle

    /// True when the folder holds any file other than meta.json — meta.json
    /// alone does not count as data (§8), so a doc whose notes/attachments were
    /// all cleared is pruned even though its meta stamp is still on disk.
    static func hasDataFiles(forKey key: String) -> Bool {
        let dir = documentDir(forKey: key)
        guard let enumerator = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return false }
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let isTopLevelMeta = file.lastPathComponent == "meta.json"
                && file.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL
            if isTopLevelMeta { continue }
            return true
        }
        return false
    }

    static func hasDataFiles(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> Bool {
        try await withAccess(coordinator: coordinator) { access in
            let directory = documentDir(forKey: key, root: access.documentsRoot)
            let active = try await access.store.list(directory, suffix: nil)
            if active.contains(where: { $0.name != "meta.json" }) { return true }
            guard let fallbackRoot = access.fallbackRoot else { return false }
            return try await DirectLibraryFileStore().list(
                documentDir(forKey: key, root: fallbackRoot), suffix: nil
            ).contains(where: { $0.name != "meta.json" })
        }
    }

    /// Remove the whole document folder when it holds no data files (§8).
    static func pruneEmptyDocumentDir(forKey key: String) {
        guard !hasDataFiles(forKey: key) else { return }
        try? FileManager.default.removeItem(at: documentDir(forKey: key))
    }

    static func pruneEmptyDocumentDir(
        forKey key: String, coordinator: StorageCoordinator
    ) async {
        guard (try? await hasDataFiles(forKey: key, coordinator: coordinator)) == false
        else { return }
        try? await withAccess(coordinator: coordinator) { access in
            try await access.store.remove(
                documentDir(forKey: key, root: access.documentsRoot))
            if let fallbackRoot = access.fallbackRoot {
                try? await DirectLibraryFileStore().remove(
                    documentDir(forKey: key, root: fallbackRoot))
            }
        }
    }

    // MARK: - Bundle-imported attachments

    static func listAttachmentNames(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> [String] {
        try await withAccess(coordinator: coordinator) { access in
            let activeDirectory = documentDir(forKey: key, root: access.documentsRoot)
                .appendingPathComponent("attachments", isDirectory: true)
            let active = try await access.store.list(activeDirectory, suffix: nil).map(\.name)
            guard let fallbackRoot = access.fallbackRoot else { return active }
            let fallback = try await DirectLibraryFileStore().list(
                documentDir(forKey: key, root: fallbackRoot)
                    .appendingPathComponent("attachments", isDirectory: true),
                suffix: nil).map(\.name)
            return Array(Set(active + fallback)).sorted()
        }
    }

    static func loadAttachments(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws -> [(name: String, data: Data)] {
        let names = try await listAttachmentNames(forKey: key, coordinator: coordinator)
        var attachments: [(name: String, data: Data)] = []
        for name in names {
            if let data = try await readData(
                forKey: key, relativeName: "attachments/\(name)",
                coordinator: coordinator)
            {
                attachments.append((name, data))
            }
        }
        return attachments
    }

    static func saveAttachment(
        forKey key: String,
        name: String,
        data: Data,
        coordinator: StorageCoordinator
    ) async throws {
        try await replaceData(
            data, forKey: key, relativeName: "attachments/\(name)",
            coordinator: coordinator)
    }

    /// Read one attachment through the active storage boundary. Live Scratchpad
    /// panes use this to stage bytes in their own resolver; an iCloud documents
    /// URL never escapes upward into a `FileManager` read.
    static func loadAttachment(
        forKey key: String,
        name: String,
        coordinator: StorageCoordinator
    ) async throws -> Data? {
        try await readData(
            forKey: key, relativeName: "attachments/\(name)",
            coordinator: coordinator)
    }

    /// Remove one attachment through the active storage boundary. The live
    /// Scratchpad calls this only after a newer scratchpad.md no longer refers
    /// to the attachment, so a failed removal is a recoverable orphan rather
    /// than missing note data.
    static func removeAttachment(
        forKey key: String,
        name: String,
        coordinator: StorageCoordinator
    ) async {
        try? await removeData(
            forKey: key, relativeName: "attachments/\(name)",
            coordinator: coordinator, refuseUnavailable: true)
    }

    // MARK: - iCloud placeholders (evicted synced files)

    /// A synced file that iCloud Drive has evicted: its real bytes are gone,
    /// leaving only a `.<name>.icloud` placeholder. Reading such a path returns
    /// nothing until it materializes; writing over it would clobber real data.
    private static func isEvictedPlaceholder(at path: URL) -> Bool {
        let fm = FileManager.default
        return !fm.fileExists(atPath: path.path)
            && fm.fileExists(atPath: WebICloud.placeholderURL(for: path).path)
    }

    /// Refuse a write that would overwrite a real-but-evicted iCloud file with
    /// fresh (possibly empty) data — mirrors `WebLibrary.withRecord`'s guard.
    /// The async load path (`materializeIfNeeded`) triggers the download first,
    /// so once the real bytes land this passes and the write proceeds.
    private static func guardEvicted(at path: URL, label: String) throws {
        guard isEvictedPlaceholder(at: path) else { return }
        throw SessionServiceError.io(
            "This document's \(label) are in iCloud but haven't downloaded yet — check your connection and try again")
    }

    /// Best-effort: before the sync load paths read a document's synced files
    /// (scratchpad.md / conversations.json / meta.json), download any that
    /// iCloud Drive evicted so the read returns the real bytes instead of
    /// "absent". Blocking `WebICloud.materialize` runs OFF the main thread; a
    /// short timeout keeps document load responsive, and any file that doesn't
    /// land just degrades to absent (the save paths then refuse to clobber it).
    /// A no-op — with no thread hop — when nothing is evicted.
    static func materializeIfNeeded(forKey key: String) async {
        let paths = [
            scratchpadPath(forKey: key),
            conversationsPath(forKey: key),
            metaPath(forKey: key),
        ]
        guard paths.contains(where: isEvictedPlaceholder) else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                for path in paths where isEvictedPlaceholder(at: path) {
                    _ = WebICloud.materialize(at: path, timeout: 2)
                }
                continuation.resume()
            }
        }
    }

    /// True when a synced file is present ONLY as an unmaterialized iCloud
    /// placeholder — its real bytes haven't downloaded and no local fallback copy
    /// exists. The UI pauses editing/persistence for such a document: a save would
    /// either clobber the evicted copy (refused by `guardEvicted`) or silently
    /// vanish, so we must not present an editable empty state whose writes are
    /// swallowed.
    private static func syncedFileUnavailableEvicted(forKey key: String, relativeName: String) -> Bool {
        // A readable copy anywhere (active or fallback) means it IS available.
        if FileManager.default.fileExists(
            atPath: readPath(forKey: key, relativeName: relativeName).path) { return false }
        return isEvictedPlaceholder(
            at: documentDir(forKey: key).appendingPathComponent(relativeName))
    }

    static func scratchpadUnavailableEvicted(forKey key: String) -> Bool {
        syncedFileUnavailableEvicted(forKey: key, relativeName: "scratchpad.md")
    }

    static func conversationsUnavailableEvicted(forKey key: String) -> Bool {
        syncedFileUnavailableEvicted(forKey: key, relativeName: "conversations.json")
    }

    // MARK: - Storage-pane inventory (design §8 per-document list)

    /// One `documents/<key>/` folder as the Storage pane sees it: its meta stamp
    /// (kind/title/last-known path/last-opened), the on-disk size of its notes
    /// (scratchpad.md + attachments/) and its chat (conversations.json), and
    /// whether the source document still resolves at its last-known path. Web
    /// docs and meta-less folders report `sourceExists == true` — only a PDF
    /// whose recorded file has vanished is an orphan.
    struct DocumentDataEntry: Identifiable, Sendable, Equatable {
        var key: String
        var meta: Meta?
        var notesBytes: Int64
        var conversationBytes: Int64
        var sourceExists: Bool

        var id: String { key }
    }

    /// One entry per `documents/<key>/` folder. Pure FileManager walk — safe to
    /// call from the Storage tab's off-main reload (same Task.detached the tab
    /// already uses for the cache/web listings).
    static func listDocuments(documentAccess: DocumentAccessResolver = .live) -> [DocumentDataEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootDirectory.path) else { return [] }
        var out: [DocumentDataEntry] = []
        for name in names {
            let dir = rootDirectory.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let meta = loadMeta(forKey: name)
            let sourceExists: Bool = {
                guard let meta else { return true }
                if meta.kind == DocumentKind.web.rawValue { return true }
                return documentAccess.sourceExists(key: name, lastKnownPath: meta.lastKnownPath)
            }()
            out.append(DocumentDataEntry(
                key: name,
                meta: meta,
                notesBytes: notesBytes(forKey: name),
                conversationBytes: fileSize(conversationsPath(forKey: name)),
                sourceExists: sourceExists))
        }
        return out
    }

    static func listDocuments(
        coordinator: StorageCoordinator,
        documentAccess: DocumentAccessResolver = .live
    ) async -> [DocumentDataEntry] {
        (try? await withAccess(coordinator: coordinator) { access in
            var keys = Set(try await access.store.list(
                access.documentsRoot, suffix: nil).map(\.name))
            if let fallbackRoot = access.fallbackRoot {
                keys.formUnion(try await DirectLibraryFileStore().list(
                    fallbackRoot, suffix: nil).map(\.name))
            }
            var entries: [DocumentDataEntry] = []
            for key in keys.sorted() {
                let directory = documentDir(forKey: key, root: access.documentsRoot)
                let activeFiles = try await access.store.list(directory, suffix: nil)
                var files = Dictionary(uniqueKeysWithValues: activeFiles.map { ($0.name, $0) })
                if let fallbackRoot = access.fallbackRoot {
                    for entry in try await DirectLibraryFileStore().list(
                        documentDir(forKey: key, root: fallbackRoot), suffix: nil)
                    where files[entry.name] == nil {
                        files[entry.name] = entry
                    }
                }
                let meta: Meta? = if let data = try await readData(
                    forKey: key, relativeName: "meta.json", coordinator: coordinator)
                {
                    try? JSONDecoder().decode(Meta.self, from: data)
                } else {
                    nil
                }
                let sourceExists: Bool = {
                    guard let meta else { return true }
                    if meta.kind == DocumentKind.web.rawValue { return true }
                    return documentAccess.sourceExists(
                        key: key, lastKnownPath: meta.lastKnownPath)
                }()
                var notes = files["scratchpad.md"]?.byteSize ?? 0
                let activeAttachments = try await access.store.list(
                    directory.appendingPathComponent("attachments", isDirectory: true),
                    suffix: nil)
                var attachments = Dictionary(uniqueKeysWithValues:
                    activeAttachments.map { ($0.name, $0) })
                if let fallbackRoot = access.fallbackRoot {
                    for entry in try await DirectLibraryFileStore().list(
                        documentDir(forKey: key, root: fallbackRoot)
                            .appendingPathComponent("attachments", isDirectory: true),
                        suffix: nil) where attachments[entry.name] == nil {
                        attachments[entry.name] = entry
                    }
                }
                notes += attachments.values.compactMap(\.byteSize).reduce(0, +)
                entries.append(DocumentDataEntry(
                    key: key, meta: meta, notesBytes: notes,
                    conversationBytes: files["conversations.json"]?.byteSize ?? 0,
                    sourceExists: sourceExists))
            }
            return entries
        }) ?? []
    }

    // MARK: - Home-screen search inventory

    /// One `documents/<key>/` folder as the home screen's search index sees it:
    /// just the meta stamp plus whether any user data hangs off it.
    struct DocumentMetaEntry: Sendable, Equatable {
        var key: String
        var meta: Meta
        /// A note and/or an AI conversation exists for this document. Two
        /// `fileExists` probes — deliberately NOT the byte totals, see below.
        var hasUserData: Bool
    }

    /// Lightweight inventory for `LibraryDocumentsSearchProvider`.
    ///
    /// Distinct from `listDocuments()` because the cost profile is different:
    /// the Storage pane needs exact byte totals and pays for a full recursive
    /// walk of every attachments/ folder once per visit, whereas the home
    /// screen rebuilds its corpus every time the welcome screen appears and
    /// only needs names and dates. Folders with no meta.json are skipped —
    /// without a stamp there is no title, kind, or path to search on.
    static func listDocumentMetas() -> [DocumentMetaEntry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: rootDirectory.path) else { return [] }
        var out: [DocumentMetaEntry] = []
        for name in names {
            let dir = rootDirectory.appendingPathComponent(name, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  let meta = loadMeta(forKey: name) else { continue }
            out.append(DocumentMetaEntry(
                key: name,
                meta: meta,
                hasUserData: scratchpadExists(forKey: name) || conversationsExist(forKey: name)))
        }
        return out
    }

    /// Coordinated home-search inventory. Production passes the workspace's
    /// shared coordinator, so an iCloud library is discovered through metadata
    /// queries and its meta bytes are read through `SyncedContainer`. The same
    /// path remains direct FileManager-backed I/O in local/custom modes and
    /// under `rootDirectoryOverride`.
    static func listDocumentMetas(
        coordinator: StorageCoordinator
    ) async throws -> [DocumentMetaEntry] {
        try await withAccess(coordinator: coordinator) { access in
            let direct = DirectLibraryFileStore()
            var keys = Set(try await access.store.list(
                access.documentsRoot, suffix: nil).map(\.name))
            if let fallbackRoot = access.fallbackRoot {
                keys.formUnion(try await direct.list(fallbackRoot, suffix: nil).map(\.name))
            }

            var entries: [DocumentMetaEntry] = []
            for key in keys.sorted() {
                let activeDirectory = documentDir(forKey: key, root: access.documentsRoot)
                var fileNames = Set(try await access.store.list(
                    activeDirectory, suffix: nil).map(\.name))
                if let fallbackRoot = access.fallbackRoot {
                    fileNames.formUnion(try await direct.list(
                        documentDir(forKey: key, root: fallbackRoot), suffix: nil).map(\.name))
                }
                guard fileNames.contains("meta.json"),
                      let data = try await readData(
                        forKey: key, relativeName: "meta.json", access: access),
                      let meta = try? JSONDecoder().decode(Meta.self, from: data)
                else { continue }
                entries.append(DocumentMetaEntry(
                    key: key,
                    meta: meta,
                    hasUserData: fileNames.contains("scratchpad.md")
                        || fileNames.contains("conversations.json")))
            }
            return entries
        }
    }

    /// scratchpad.md + everything under attachments/ (the note's full footprint).
    static func notesBytes(forKey key: String) -> Int64 {
        fileSize(scratchpadPath(forKey: key)) + directorySize(at: attachmentsDir(forKey: key))
    }

    // MARK: - Storage-pane deletes (delete-means-delete, §8)

    /// Delete the note and all its attachments, then prune a now-empty folder.
    /// Uses `WebICloud.removeItem` so an iCloud-EVICTED note (only its
    /// `.scratchpad.md.icloud` placeholder on disk) is truly deleted — a plain
    /// `removeItem` on the materialized path would leave the placeholder, which
    /// re-materializes the "deleted" note on the next sync (§8 delete-means-delete).
    static func deleteNotes(forKey key: String) {
        WebICloud.removeItem(at: scratchpadPath(forKey: key))
        WebICloud.removeItem(at: attachmentsDir(forKey: key))
        pruneEmptyDocumentDir(forKey: key)
    }

    static func deleteNotes(forKey key: String, coordinator: StorageCoordinator) async {
        try? await deleteNotesSafely(forKey: key, coordinator: coordinator)
    }

    /// Throwing delete used inside Scratchpad's exclusive write lane. The note
    /// is removed from active and fallback roots before attachments are touched;
    /// a fallback failure is surfaced so callers never announce a clean delete
    /// while an older copy can still reappear.
    static func deleteNotesSafely(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws {
        try await removeData(
            forKey: key, relativeName: "scratchpad.md", coordinator: coordinator,
            refuseUnavailable: false)
        try await removeData(
            forKey: key, relativeName: "attachments", coordinator: coordinator,
            refuseUnavailable: false)
        await pruneEmptyDocumentDir(forKey: key, coordinator: coordinator)
    }

    /// Delete conversations.json, then prune a now-empty folder. Explicit
    /// Storage-pane delete: unlike `removeConversations` (which spares an evicted
    /// placeholder so an empty in-app save can't clobber undownloaded chat), this
    /// removes the placeholder too via `WebICloud.removeItem` — delete means delete.
    static func deleteConversation(forKey key: String) {
        WebICloud.removeItem(at: conversationsPath(forKey: key))
        pruneEmptyDocumentDir(forKey: key)
    }

    static func deleteConversation(forKey key: String, coordinator: StorageCoordinator) async {
        try? await removeData(
            forKey: key, relativeName: "conversations.json", coordinator: coordinator,
            refuseUnavailable: false)
        await pruneEmptyDocumentDir(forKey: key, coordinator: coordinator)
    }

    /// Delete the whole `documents/<key>/` folder — meta, notes, attachments and
    /// chat. The caller separately drops the text-cache entry (the actor owns it)
    /// and the web snapshot artifacts (WebLibrary owns those).
    static func deleteAll(forKey key: String) {
        try? FileManager.default.removeItem(at: documentDir(forKey: key))
    }

    static func deleteAll(forKey key: String, coordinator: StorageCoordinator) async {
        try? await deleteAllSafely(forKey: key, coordinator: coordinator)
    }

    /// Throwing variant used by coordinated destructive actions. Callers must
    /// not re-enable an editor until both active and fallback copies are gone.
    static func deleteAllSafely(
        forKey key: String, coordinator: StorageCoordinator
    ) async throws {
        try await withAccess(coordinator: coordinator) { access in
            try await access.store.remove(
                documentDir(forKey: key, root: access.documentsRoot))
            if let fallbackRoot = access.fallbackRoot {
                try await DirectLibraryFileStore().remove(
                    documentDir(forKey: key, root: fallbackRoot))
            }
        }
    }

    // MARK: - Relink (orphaned entry -> moved source)

    /// Point a document's meta.json at the file the user re-located it to. The
    /// recents list re-resolves dead PDF paths through this stamp
    /// (RecentFilesService.resolvedPath), so updating it here is enough to
    /// reconnect a moved document without re-keying its folder.
    static func relink(forKey key: String, newPath: String) throws {
        guard var meta = loadMeta(forKey: key) else {
            throw DocumentAccessError.missingMetadata(key)
        }
        meta.lastKnownPath = newPath
        meta.lastOpened = WebLibrary.rfc3339Now()
        let data = try WebLibrary.jsonEncoderPretty.encode(meta)
        try writeAtomic(data, to: metaPath(forKey: key), label: "document meta")
    }

    static func relink(
        forKey key: String, newPath: String, coordinator: StorageCoordinator
    ) async throws {
        guard var meta = try await loadMeta(forKey: key, coordinator: coordinator) else {
            throw DocumentAccessError.missingMetadata(key)
        }
        meta.lastKnownPath = newPath
        meta.lastOpened = WebLibrary.rfc3339Now()
        try await replaceData(
            WebLibrary.jsonEncoderPretty.encode(meta), forKey: key,
            relativeName: "meta.json", coordinator: coordinator)
    }

    static func restoreMeta(_ meta: Meta, forKey key: String) throws {
        let data = try WebLibrary.jsonEncoderPretty.encode(meta)
        try writeAtomic(data, to: metaPath(forKey: key), label: "document meta rollback")
    }

    static func restoreMeta(
        _ meta: Meta, forKey key: String, coordinator: StorageCoordinator
    ) async throws {
        try await replaceData(
            WebLibrary.jsonEncoderPretty.encode(meta), forKey: key,
            relativeName: "meta.json", coordinator: coordinator)
    }

    // MARK: - Rename

    /// Set a document's display title without touching anything else.
    ///
    /// `touch(document:)` is the only other title writer, and it is the wrong
    /// tool for a rename: it rewrites `lastKnownPath` and `lastOpened` from the
    /// passed `DocumentInfo`, so renaming through it would either bump the
    /// document's last-opened time (reordering the user's recents as a side
    /// effect of typing a name) or, if the caller assembled the `DocumentInfo`
    /// carelessly, overwrite a good `lastKnownPath` with a stale one. This is
    /// the same narrow read-modify-write shape as `relink`, aimed at the other
    /// field.
    ///
    /// A blank title clears the override rather than storing `""`, so the row
    /// falls back to the filename or host instead of rendering as an empty
    /// line the user cannot click on or search for.
    @discardableResult
    static func setTitle(forKey key: String, title: String?) -> Bool {
        guard var meta = loadMeta(forKey: key) else { return false }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        meta.title = trimmed.isEmpty ? nil : trimmed
        guard let data = try? WebLibrary.jsonEncoderPretty.encode(meta) else { return false }
        do {
            try writeAtomic(data, to: metaPath(forKey: key), label: "document meta")
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func setTitle(
        forKey key: String, title: String?, coordinator: StorageCoordinator
    ) async -> Bool {
        do {
            guard var meta = try await loadMeta(forKey: key, coordinator: coordinator)
            else { return false }
            let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            meta.title = trimmed.isEmpty ? nil : trimmed
            let data = try WebLibrary.jsonEncoderPretty.encode(meta)
            try await replaceData(
                data, forKey: key, relativeName: "meta.json", coordinator: coordinator)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Size helpers

    /// Placeholder-aware size: `WebICloud.size` returns the materialized file's
    /// bytes, or — when the file is iCloud-evicted — the true size recorded on
    /// its `.icloud` placeholder. Without this an evicted note/chat reports 0, so
    /// StorageInventory.joinRows drops the row and the user can't see or delete it.
    private static func fileSize(_ url: URL) -> Int64 {
        WebICloud.size(ofItemAt: url)
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            // An iCloud-evicted attachment surfaces as a `.<name>.icloud`
            // placeholder; report the real bytes it records rather than the tiny
            // placeholder file's own size.
            if file.lastPathComponent.hasPrefix("."), file.pathExtension == "icloud" {
                total += WebICloud.size(ofItemAt: logicalURL(forPlaceholder: file))
                continue
            }
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }

    /// The logical file URL an iCloud placeholder (`.<name>.icloud`) stands in
    /// for — strip the leading dot and the `.icloud` extension.
    private static func logicalURL(forPlaceholder placeholder: URL) -> URL {
        let name = placeholder.deletingPathExtension().lastPathComponent  // ".scratchpad.md"
        let logical = name.hasPrefix(".") ? String(name.dropFirst()) : name
        return placeholder.deletingLastPathComponent().appendingPathComponent(logical)
    }

    // MARK: - Rekey (fallback path-hash key -> stamped docId key)

    /// Move a document's folder from `oldKey` to `newKey` — used when a PDF
    /// acquires its /VellumDocId and its data must migrate off the path-hash
    /// fallback folder. When `newKey` already has a folder (a prior session
    /// stamped it), the two are merged file-by-file, newest modification wins.
    static func rekey(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        moveOrMergeDirectory(
            from: documentDir(forKey: oldKey), into: documentDir(forKey: newKey))
    }

    /// Coordinated path-hash → durable-id rekey. The class-B schema is small
    /// and fixed, so copying its known files through `LibraryFileStore` is both
    /// safer and simpler than exposing a recursive filesystem walk above the
    /// seam. Destination meta is canonical; other collisions use the newest
    /// metadata timestamp and never overwrite an unreadable/not-downloaded file.
    @discardableResult
    static func rekey(
        from oldKey: String,
        to newKey: String,
        coordinator: StorageCoordinator
    ) async -> Bool {
        guard oldKey != newKey else { return true }
        return await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
            forKeys: [oldKey, newKey]
        ) {
            await rekeyExclusively(
                from: oldKey, to: newKey, coordinator: coordinator)
        }
    }

    private static func rekeyExclusively(
        from oldKey: String,
        to newKey: String,
        coordinator: StorageCoordinator
    ) async -> Bool {
        do {
            return try await withAccess(coordinator: coordinator) { access in
                let source = documentDir(forKey: oldKey, root: access.documentsRoot)
                let destination = documentDir(forKey: newKey, root: access.documentsRoot)
                let direct = DirectLibraryFileStore()
                let fallbackSource = access.fallbackRoot.map {
                    documentDir(forKey: oldKey, root: $0)
                }
                let fallbackDestination = access.fallbackRoot.map {
                    documentDir(forKey: newKey, root: $0)
                }

                var sourceEntries = Dictionary(uniqueKeysWithValues:
                    try await access.store.list(source, suffix: nil).map { ($0.name, $0) })
                if let fallbackSource {
                    for entry in try await direct.list(fallbackSource, suffix: nil)
                    where sourceEntries[entry.name] == nil {
                        sourceEntries[entry.name] = entry
                    }
                }
                // There is no migration to perform. Do not inspect the durable
                // destination: it may be temporarily unavailable even though
                // the document has no path-keyed data that could be lost.
                guard !sourceEntries.isEmpty else { return true }

                var destinationEntries = Dictionary(uniqueKeysWithValues:
                    try await access.store.list(destination, suffix: nil).map { ($0.name, $0) })
                if let fallbackDestination {
                    for entry in try await direct.list(fallbackDestination, suffix: nil)
                    where destinationEntries[entry.name] == nil {
                        destinationEntries[entry.name] = entry
                    }
                }

                // Scratchpads are never newest-wins. Reconcile both active and
                // fallback copies on each side first, write the full recovery
                // result to the active durable key, verify it, then remove the
                // hidden fallback/source copies that could otherwise overwrite
                // it when a pending relocation resumes.
                let sourceNoteURL = source.appendingPathComponent("scratchpad.md")
                let fallbackSourceNoteURL = fallbackSource?.appendingPathComponent("scratchpad.md")
                let destinationNoteURL = destination.appendingPathComponent("scratchpad.md")
                let fallbackDestinationNoteURL = fallbackDestination?
                    .appendingPathComponent("scratchpad.md")
                let activeSourceNote = try await access.store.read(sourceNoteURL)
                let fallbackSourceNote: Data?
                if let fallbackSourceNoteURL {
                    fallbackSourceNote = try await direct.read(fallbackSourceNoteURL)
                } else {
                    fallbackSourceNote = nil
                }
                let sourceNote: Data? = switch (activeSourceNote, fallbackSourceNote) {
                case let (active?, fallback?):
                    mergeScratchpadsPreservingBoth(destination: active, source: fallback)
                case let (active?, nil): active
                case let (nil, fallback?): fallback
                case (nil, nil): nil
                }
                let activeDestinationNote = try await access.store.read(destinationNoteURL)
                let fallbackDestinationNote: Data?
                if let fallbackDestinationNoteURL {
                    fallbackDestinationNote = try await direct.read(fallbackDestinationNoteURL)
                } else {
                    fallbackDestinationNote = nil
                }
                let destinationNote: Data? = switch (
                    activeDestinationNote, fallbackDestinationNote
                ) {
                case let (active?, fallback?):
                    mergeScratchpadsPreservingBoth(destination: active, source: fallback)
                case let (active?, nil): active
                case let (nil, fallback?): fallback
                case (nil, nil): nil
                }
                let mergedNote: Data? = switch (destinationNote, sourceNote) {
                case let (destination?, source?):
                    mergeScratchpadsPreservingBoth(destination: destination, source: source)
                case let (destination?, nil): destination
                case let (nil, source?): source
                case (nil, nil): nil
                }
                if let mergedNote, mergedNote != activeDestinationNote {
                    try await access.store.replace(destinationNoteURL, with: mergedNote)
                }
                if let mergedNote {
                    guard try await access.store.read(destinationNoteURL) == mergedNote else {
                        throw LibraryFileError.io("Failed to verify rekeyed Scratchpad")
                    }
                    try await access.store.remove(sourceNoteURL)
                    if let fallbackSourceNoteURL { try await direct.remove(fallbackSourceNoteURL) }
                    if let fallbackDestinationNoteURL {
                        try await direct.remove(fallbackDestinationNoteURL)
                    }
                }

                var relativeNames = sourceEntries.keys.filter {
                    $0 != "attachments" && $0 != "scratchpad.md"
                }
                let sourceAttachments = try await access.store.list(
                    source.appendingPathComponent("attachments", isDirectory: true),
                    suffix: nil)
                var attachmentEntries = Dictionary(uniqueKeysWithValues:
                    sourceAttachments.map { ($0.name, $0) })
                if let fallbackSource {
                    for entry in try await direct.list(
                        fallbackSource.appendingPathComponent("attachments", isDirectory: true),
                        suffix: nil) where attachmentEntries[entry.name] == nil {
                        attachmentEntries[entry.name] = entry
                    }
                }
                relativeNames += attachmentEntries.keys.map { "attachments/\($0)" }

                for relative in relativeNames.sorted() {
                    let sourceURL = source.appendingPathComponent(relative)
                    let fallbackURL = fallbackSource?.appendingPathComponent(relative)
                    var sourceData = try await access.store.read(sourceURL)
                    if sourceData == nil, let fallbackURL {
                        sourceData = try await direct.read(fallbackURL)
                    }
                    guard let sourceData else { continue }
                    let destinationURL = destination.appendingPathComponent(relative)
                    let destinationData = try await access.store.read(destinationURL)
                    if destinationData != nil {
                        if relative == "meta.json" { continue }
                        let name = (relative as NSString).lastPathComponent
                        let sourceEntry = relative.hasPrefix("attachments/")
                            ? attachmentEntries[name] : sourceEntries[name]
                        let destinationDirectory = relative.hasPrefix("attachments/")
                            ? destination.appendingPathComponent("attachments", isDirectory: true)
                            : destination
                        if destinationEntries[name] == nil || relative.hasPrefix("attachments/") {
                            destinationEntries[name] = try await access.store.list(
                                destinationDirectory, suffix: nil).first { $0.name == name }
                        }
                        guard (sourceEntry?.contentModifiedAt ?? .distantPast)
                                > (destinationEntries[name]?.contentModifiedAt ?? .distantPast)
                        else { continue }
                    }
                    try await access.store.replace(destinationURL, with: sourceData)
                }

                for relative in relativeNames {
                    try await access.store.remove(source.appendingPathComponent(relative))
                }
                try await access.store.remove(source)
                if let fallbackSource { try await direct.remove(fallbackSource) }
                return true
            }
        } catch {
            NSLog(
                "[Vellum] Document data rekey from %@ to %@ failed: %@",
                oldKey, newKey, String(describing: error))
            return false
        }
    }

    private static func mergeScratchpadsPreservingBoth(
        destination: Data,
        source: Data
    ) -> Data {
        guard destination != source else { return destination }
        guard !destination.isEmpty else { return source }
        guard !source.isEmpty else { return destination }
        let recovered = String(decoding: source, as: UTF8.self)
        let marker = "\n\n---\n\n## Recovered notes from before document identity changed\n\n"
        let existing = String(decoding: destination, as: UTF8.self)
        guard !existing.contains(marker + recovered) else { return destination }
        return Data((existing + marker + recovered).utf8)
    }

    /// Move `src` folder to `dst`, merging file-by-file (newest modification
    /// wins) when `dst` already exists. The shared primitive behind `rekey`
    /// (path-hash → docId) and the storage-location relocation of `documents/`
    /// (WebStorageMigrator.relocate). Idempotent, best-effort, never throws — a
    /// missing `src` or a failed step just leaves the source for the next pass.
    ///
    /// The source directory is removed ONLY when every file merged cleanly, so a
    /// partial failure (e.g. a target write that could not land) leaves both
    /// copies intact for an idempotent retry rather than destroying the only
    /// remaining data.
    ///
    /// Returns true when the folder is fully relocated (or there was nothing to
    /// move); false when it was SKIPPED because an iCloud-evicted file could not
    /// be downloaded, or a merge step failed. The relocation caller keeps its
    /// pending marker on a false so the launch sweep retries later.
    @discardableResult
    static func moveOrMergeDirectory(from src: URL, into dst: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return true }
        // Download any iCloud-evicted files FIRST so we move real bytes, never
        // `.<name>.icloud` placeholder stubs (moving a stub would strand the real
        // data in the cloud under the old location). A folder that can't fully
        // materialize is left in place for a later sweep.
        guard materializePlaceholders(in: src) else { return false }
        if !fm.fileExists(atPath: dst.path) {
            try? fm.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: src, to: dst)) != nil { return true }
        }
        let merged = mergeDirectory(from: src, into: dst)
        if merged { try? fm.removeItem(at: src) }
        return merged
    }

    /// Download every iCloud-evicted file under `dir` (recursively) so a
    /// subsequent move handles real bytes, not `.<name>.icloud` placeholders.
    /// Returns false when any placeholder could not be materialized (offline or
    /// not downloaded within the timeout) — the caller then leaves the folder for
    /// a later sweep instead of moving stubs. Blocking `WebICloud.materialize`
    /// runs inside the already-detached migrator task.
    private static func materializePlaceholders(in dir: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { return true }
        var allMaterialized = true
        for case let file as URL in enumerator {
            guard file.lastPathComponent.hasPrefix("."), file.pathExtension == "icloud" else { continue }
            let logical = logicalURL(forPlaceholder: file)
            WebICloud.requestDownload(at: logical)
            if !WebICloud.materialize(at: logical, timeout: 10) { allMaterialized = false }
        }
        return allMaterialized
    }

    /// Merge every regular file under `src` into `dst`, returning true only when
    /// ALL of them landed (or were cleanly superseded) so the caller may drop the
    /// source. A collision resolves newest-modification-wins via an atomic swap
    /// (`replaceItemAt`) that can never destroy the destination if the move
    /// fails — no target is deleted before its replacement is durably in place.
    /// meta.json is special-cased: the destination (the stamped docId folder) is
    /// canonical, so its meta always wins and a stale source meta is simply
    /// dropped — this is what lets a leftover meta-only path-hash folder collapse
    /// on rekey instead of surviving as a bogus orphan.
    private static func mergeDirectory(from src: URL, into dst: URL) -> Bool {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        else { return false }
        // Resolve symlinks on both sides so the prefix strip is exact — the
        // enumerator may report `/private/var/...` while `src` was built from a
        // `/var/...` temporary path (or vice versa).
        let srcBase = src.resolvingSymlinksInPath().path
        var allMerged = true
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let filePath = file.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(srcBase) else { continue }
            let relative = String(filePath.dropFirst(srcBase.count).drop(while: { $0 == "/" }))
            let target = dst.appendingPathComponent(relative)
            do {
                try fm.createDirectory(
                    at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                allMerged = false
                continue
            }
            // An iCloud-evicted destination (only its `.<name>.icloud`
            // placeholder on disk) counts as EXISTING — treating it as absent
            // would move the source file in beside the placeholder, leaving two
            // rival copies of the same logical file. Materialize it so the
            // mod-date compare and atomic swap operate on real bytes.
            if WebICloud.itemExists(at: target) {
                // meta.json: destination wins, source dropped (collapses stray
                // meta-only path-hash folders; §8 self-heal).
                if relative == "meta.json" { continue }
                if !WebICloud.materialize(at: target, timeout: 10) {
                    // Can't download the destination to compare/replace safely —
                    // leave both copies for a later retry rather than guess.
                    allMerged = false
                    continue
                }
                if modDate(file) > modDate(target) {
                    // Atomic swap: never removes the destination before the newer
                    // source is durably in its place.
                    if (try? fm.replaceItemAt(target, withItemAt: file)) == nil {
                        allMerged = false
                    }
                }
                // Destination newer-or-equal: keep it, drop the source copy.
            } else if (try? fm.moveItem(at: file, to: target)) == nil {
                allMerged = false
            }
        }
        return allMerged
    }

    private static func modDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    // MARK: - Atomic write

    private static func writeAtomic(_ data: Data, to path: URL, label: String) throws {
        let dir = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to create \(label) dir: \(error.localizedDescription)")
        }
        let tmp = path.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
        } catch {
            throw SessionServiceError.io("Failed to write \(label): \(error.localizedDescription)")
        }
        guard rename(tmp.path, path.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to commit \(label): rename failed")
        }
    }
}
