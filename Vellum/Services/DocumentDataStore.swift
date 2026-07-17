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

    static var rootDirectory: URL {
        rootDirectoryOverride
            ?? WebLibrary.appDataDir.appendingPathComponent("documents", isDirectory: true)
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

    /// Atomically write scratchpad.md. Throws on write failure (user data).
    static func saveScratchpad(forKey key: String, text: String) throws {
        try writeAtomic(Data(text.utf8), to: scratchpadPath(forKey: key), label: "scratchpad note")
    }

    /// Delete scratchpad.md (delete-means-delete; §8). Best-effort — a missing
    /// file is already the desired end state.
    static func removeScratchpad(forKey key: String) {
        try? FileManager.default.removeItem(at: scratchpadPath(forKey: key))
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

    /// Atomically write conversations.json. Throws on write failure (user data).
    static func saveConversationsData(forKey key: String, data: Data) throws {
        try writeAtomic(data, to: conversationsPath(forKey: key), label: "conversations")
    }

    /// Delete conversations.json (delete-means-delete; §8). Best-effort — a
    /// missing file is already the desired end state.
    static func removeConversations(forKey key: String) {
        try? FileManager.default.removeItem(at: conversationsPath(forKey: key))
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

    // MARK: - Rekey (fallback path-hash key -> stamped docId key)

    /// Move a document's folder from `oldKey` to `newKey` — used when a PDF
    /// acquires its /VellumDocId and its data must migrate off the path-hash
    /// fallback folder. When `newKey` already has a folder (a prior session
    /// stamped it), the two are merged file-by-file, newest modification wins.
    static func rekey(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        let fm = FileManager.default
        let src = documentDir(forKey: oldKey)
        let dst = documentDir(forKey: newKey)
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
