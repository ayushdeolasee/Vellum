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

    static func documentDir(forKey key: String) -> URL {
        rootDirectory.appendingPathComponent(key, isDirectory: true)
    }

    static func attachmentsDir(forKey key: String) -> URL {
        documentDir(forKey: key).appendingPathComponent("attachments", isDirectory: true)
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
        guard let data = try? Data(contentsOf: metaPath(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(Meta.self, from: data)
    }

    /// Upsert the document's meta.json, refreshing `last_opened`. Called from the
    /// per-pane document load path. A previously stored title is kept when the
    /// incoming document has none.
    static func touch(document: DocumentInfo) throws {
        let key = DocumentIdentity.storageKey(for: document)
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

    // MARK: - scratchpad.md

    static func scratchpadExists(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: scratchpadPath(forKey: key).path)
    }

    /// The persisted (relative-ref) markdown for a document, or "" if none.
    static func loadScratchpad(forKey key: String) -> String {
        (try? String(contentsOf: scratchpadPath(forKey: key), encoding: .utf8)) ?? ""
    }

    /// Atomically write scratchpad.md. Throws on write failure (user data) — and
    /// refuses to clobber a real-but-evicted iCloud copy (see `guardEvicted`).
    static func saveScratchpad(forKey key: String, text: String) throws {
        let path = scratchpadPath(forKey: key)
        try guardEvicted(at: path, label: "notes")
        try writeAtomic(Data(text.utf8), to: path, label: "scratchpad note")
    }

    /// Delete scratchpad.md (delete-means-delete; §8). Best-effort — a missing
    /// file is already the desired end state. Skips an iCloud-evicted copy: an
    /// empty-note save must not delete real notes that just haven't downloaded
    /// (explicit Storage-pane deletes bypass this via their own removeItem).
    static func removeScratchpad(forKey key: String) {
        let path = scratchpadPath(forKey: key)
        guard !isEvictedPlaceholder(at: path) else { return }
        try? FileManager.default.removeItem(at: path)
    }

    // MARK: - conversations.json

    static func conversationsPath(forKey key: String) -> URL {
        documentDir(forKey: key).appendingPathComponent("conversations.json")
    }

    static func conversationsExist(forKey key: String) -> Bool {
        FileManager.default.fileExists(atPath: conversationsPath(forKey: key).path)
    }

    /// Raw conversations.json bytes for a document, or nil if none.
    static func loadConversationsData(forKey key: String) -> Data? {
        try? Data(contentsOf: conversationsPath(forKey: key))
    }

    /// Atomically write conversations.json. Throws on write failure (user data) —
    /// and refuses to clobber a real-but-evicted iCloud copy (see `guardEvicted`).
    static func saveConversationsData(forKey key: String, data: Data) throws {
        let path = conversationsPath(forKey: key)
        try guardEvicted(at: path, label: "AI conversations")
        try writeAtomic(data, to: path, label: "conversations")
    }

    /// Delete conversations.json (delete-means-delete; §8). Best-effort — a
    /// missing file is already the desired end state. Skips an iCloud-evicted
    /// copy so an empty save can't delete real chat that hasn't downloaded.
    static func removeConversations(forKey key: String) {
        let path = conversationsPath(forKey: key)
        guard !isEvictedPlaceholder(at: path) else { return }
        try? FileManager.default.removeItem(at: path)
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

    /// Remove the whole document folder when it holds no data files (§8).
    static func pruneEmptyDocumentDir(forKey key: String) {
        guard !hasDataFiles(forKey: key) else { return }
        try? FileManager.default.removeItem(at: documentDir(forKey: key))
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
    static func listDocuments() -> [DocumentDataEntry] {
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
                return fm.fileExists(atPath: meta.lastKnownPath)
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

    /// scratchpad.md + everything under attachments/ (the note's full footprint).
    static func notesBytes(forKey key: String) -> Int64 {
        fileSize(scratchpadPath(forKey: key)) + directorySize(at: attachmentsDir(forKey: key))
    }

    // MARK: - Storage-pane deletes (delete-means-delete, §8)

    /// Delete the note and all its attachments, then prune a now-empty folder.
    static func deleteNotes(forKey key: String) {
        try? FileManager.default.removeItem(at: scratchpadPath(forKey: key))
        try? FileManager.default.removeItem(at: attachmentsDir(forKey: key))
        pruneEmptyDocumentDir(forKey: key)
    }

    /// Delete conversations.json, then prune a now-empty folder.
    static func deleteConversation(forKey key: String) {
        removeConversations(forKey: key)
        pruneEmptyDocumentDir(forKey: key)
    }

    /// Delete the whole `documents/<key>/` folder — meta, notes, attachments and
    /// chat. The caller separately drops the text-cache entry (the actor owns it)
    /// and the web snapshot artifacts (WebLibrary owns those).
    static func deleteAll(forKey key: String) {
        try? FileManager.default.removeItem(at: documentDir(forKey: key))
    }

    // MARK: - Relink (orphaned entry -> moved source)

    /// Point a document's meta.json at the file the user re-located it to. The
    /// recents list re-resolves dead PDF paths through this stamp
    /// (RecentFilesService.resolvedPath), so updating it here is enough to
    /// reconnect a moved document without re-keying its folder.
    static func relink(forKey key: String, newPath: String) {
        guard var meta = loadMeta(forKey: key) else { return }
        meta.lastKnownPath = newPath
        meta.lastOpened = WebLibrary.rfc3339Now()
        guard let data = try? WebLibrary.jsonEncoderPretty.encode(meta) else { return }
        try? writeAtomic(data, to: metaPath(forKey: key), label: "document meta")
    }

    // MARK: - Size helpers

    private static func fileSize(_ url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private static func directorySize(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
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

    /// Move `src` folder to `dst`, merging file-by-file (newest modification
    /// wins) when `dst` already exists. The shared primitive behind `rekey`
    /// (path-hash → docId) and the storage-location relocation of `documents/`
    /// (WebStorageMigrator.relocate). Idempotent, best-effort, never throws — a
    /// missing `src` or a failed step just leaves the source for the next pass.
    static func moveOrMergeDirectory(from src: URL, into dst: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: src.path) else { return }
        if !fm.fileExists(atPath: dst.path) {
            try? fm.createDirectory(
                at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.moveItem(at: src, to: dst)) != nil { return }
        }
        mergeDirectory(from: src, into: dst)
        try? fm.removeItem(at: src)
    }

    private static func mergeDirectory(from src: URL, into dst: URL) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: src,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey])
        else { return }
        // Resolve symlinks on both sides so the prefix strip is exact — the
        // enumerator may report `/private/var/...` while `src` was built from a
        // `/var/...` temporary path (or vice versa).
        let srcBase = src.resolvingSymlinksInPath().path
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
            else { continue }
            let filePath = file.resolvingSymlinksInPath().path
            guard filePath.hasPrefix(srcBase) else { continue }
            let relative = String(filePath.dropFirst(srcBase.count).drop(while: { $0 == "/" }))
            let target = dst.appendingPathComponent(relative)
            try? fm.createDirectory(
                at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: target.path) {
                let srcDate = modDate(file)
                let dstDate = modDate(target)
                if srcDate > dstDate {
                    try? fm.removeItem(at: target)
                    try? fm.moveItem(at: file, to: target)
                }
            } else {
                try? fm.moveItem(at: file, to: target)
            }
        }
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
