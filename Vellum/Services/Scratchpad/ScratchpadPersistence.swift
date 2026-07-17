import Foundation

/// Per-document scratchpad notes, persisted to `documents/<key>/scratchpad.md`
/// via `DocumentDataStore` (class-B user data — see plans/storage-design.html
/// §4). The on-disk markdown holds RELATIVE image refs (`attachments/<id>.<ext>`)
/// so a document's folder is portable standard Markdown; the live editor keeps
/// its `vellum-scratchpad://<id>` scheme URLs, and this type rewrites between the
/// two forms on load/save.
///
/// The legacy UserDefaults blob (`vellum.scratchpad.notes.v1`, path-keyed) is now
/// a read-only migration source only: a document's entry is folded into its
/// folder on first load and removed from the blob (§7 lazy migration).
enum ScratchpadPersistence {
    static let notesKey = "vellum.scratchpad.notes.v1"
    static let maxCharacters = 200_000

    private struct Entry: Codable {
        var key: String
        var text: String
    }

    // MARK: - Load / save (folder-backed)

    /// The scheme-form (editor runtime) markdown for `key`, or "" if none.
    static func load(forKey key: String) -> String {
        relativeToScheme(DocumentDataStore.loadScratchpad(forKey: key))
    }

    /// Persist `schemeText` (editor runtime form) for `key`. Converts image refs
    /// to portable relative form, prunes attachments the note no longer
    /// references, and — when the note is empty — deletes scratchpad.md and any
    /// now-orphaned folder (delete-means-delete, §8). Throws on the write itself.
    static func save(forKey key: String, schemeText: String) throws {
        let bounded = String(schemeText.prefix(maxCharacters))
        let referenced = ScratchpadAttachmentStore.referencedIds(in: bounded)
        let relative = schemeToRelative(bounded) {
            ScratchpadAttachmentStore.fileURL(for: $0)?.pathExtension
        }
        if relative.isEmpty {
            DocumentDataStore.removeScratchpad(forKey: key)
        } else {
            try DocumentDataStore.saveScratchpad(forKey: key, text: relative)
        }
        // Prune attachments the note no longer points at, then drop the folder
        // entirely if nothing but meta.json is left.
        ScratchpadAttachmentStore.collectGarbage(
            in: DocumentDataStore.attachmentsDir(forKey: key), referencedIds: referenced)
        DocumentDataStore.pruneEmptyDocumentDir(forKey: key)
    }

    // MARK: - Relative <-> scheme image-ref rewrites

    private static let idPattern = "[0-9a-fA-F-]+"

    /// Rewrite persisted relative refs (`attachments/<id>.<ext>` or a bare
    /// `attachments/<id>`) to the editor's `vellum-scratchpad://<id>` scheme.
    /// Non-matching text (including malformed refs) is left untouched.
    static func relativeToScheme(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let pattern = "attachments/(\(idPattern))(?:\\.[A-Za-z0-9]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length),
            withTemplate: "\(ScratchpadAttachmentStore.scheme)://$1")
    }

    /// Rewrite editor scheme refs (`vellum-scratchpad://<id>`) to the persisted
    /// relative form. `extensionFor` resolves an id to its on-disk file
    /// extension; when it returns nil the ref falls back to a bare
    /// `attachments/<id>` (still portable, still resolvable on reload).
    static func schemeToRelative(_ text: String, extensionFor: (String) -> String?) -> String {
        guard !text.isEmpty else { return text }
        let pattern = "\(ScratchpadAttachmentStore.scheme)://(\(idPattern))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        // Replace back-to-front so earlier match ranges stay valid.
        for match in regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard match.numberOfRanges > 1 else { continue }
            let id = ns.substring(with: match.range(at: 1))
            let ext = extensionFor(id)
            let replacement = ext.map { "attachments/\(id).\($0)" } ?? "attachments/\(id)"
            let full = match.range(at: 0)
            let start = result.index(result.startIndex, offsetBy: full.location)
            let end = result.index(start, offsetBy: full.length)
            result.replaceSubrange(start..<end, with: replacement)
        }
        return result
    }

    // MARK: - Legacy migration (UserDefaults blob -> folder)

    /// If `key`'s folder has no scratchpad.md yet but the legacy blob still
    /// carries an entry for the document's path, migrate it: move referenced
    /// attachments out of the global pool into the doc's `attachments/`, write
    /// scratchpad.md in relative form, and drop the entry from the blob
    /// (§7). The blob read path stays intact for entries not yet migrated.
    static func migrateLegacyIfNeeded(document: DocumentInfo, key: String) {
        guard !DocumentDataStore.scratchpadExists(forKey: key) else { return }
        let legacyKey = document.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else { return }
        var entries = readEntries()
        guard let index = entries.firstIndex(where: { $0.key == legacyKey }) else { return }
        let legacyText = entries[index].text
        // Move the note's attachments into its folder first, so the extension
        // resolver below finds them at the new location.
        let referenced = ScratchpadAttachmentStore.referencedIds(in: legacyText)
        let destDir = DocumentDataStore.attachmentsDir(forKey: key)
        ScratchpadAttachmentStore.migrateAttachments(ids: referenced, toDir: destDir)
        let relative = schemeToRelative(legacyText) {
            ScratchpadAttachmentStore.fileURL(for: $0, preferredDir: destDir)?.pathExtension
        }
        if relative.isEmpty {
            // An empty legacy note carries nothing worth a folder; just drop it.
            entries.remove(at: index)
            writeEntries(entries)
            return
        }
        do {
            try DocumentDataStore.saveScratchpad(forKey: key, text: relative)
        } catch {
            // Leave the blob entry in place so the next open retries the move.
            return
        }
        entries.remove(at: index)
        writeEntries(entries)
    }

    // MARK: - Orphaned legacy blobs (Storage pane "Not yet migrated")

    /// Every path-keyed note still sitting in the legacy blob — surfaced in the
    /// Storage pane's orphans section as pre-migration data the user can delete.
    /// `bytes` is the note's UTF-8 size (the blob holds text only; attachments
    /// stay in the global pool until the doc is opened and migrated).
    static func listLegacyEntries() -> [(key: String, bytes: Int)] {
        readEntries().map { (key: $0.key, bytes: $0.text.utf8.count) }
    }

    /// Drop one path-keyed note from the legacy blob (Storage-pane delete).
    static func removeLegacyEntry(key: String) {
        var entries = readEntries()
        entries.removeAll { $0.key == key }
        writeEntries(entries)
    }

    private static func readEntries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: notesKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func writeEntries(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: notesKey)
    }
}

/// Disk-backed store for images snapshotted or dropped into scratchpad notes.
/// The note text only holds a lightweight `vellum-scratchpad://<id>` reference;
/// the bytes live under the active document's folder
/// (`documents/<key>/attachments/`). Saves go to the active document's dir; a
/// read (`fileURL(for:)`) probes that dir first, then the legacy global pool
/// (`App Support/scratchpad-attachments`) so pre-migration references still
/// resolve. The WKWebView scheme handler in ScratchpadPanel resolves every
/// reference through `fileURL(for:)`, so it keeps working unchanged.
enum ScratchpadAttachmentStore {
    static let scheme = "vellum-scratchpad"

    /// Test-only redirect for the LEGACY global attachment pool so tests never
    /// read or delete a real user's attachments. Nil in production.
    nonisolated(unsafe) static var directoryOverride: URL?

    /// The active document's attachments directory — set by `ScratchpadStore`
    /// on `loadForDocument`. Saves and the primary `fileURL(for:)` probe target
    /// this; nil (no document loaded) falls back to the legacy pool.
    nonisolated(unsafe) static var activeDirectory: URL?

    /// The legacy flat pool: pre-retarget attachments and the read fallback.
    static var directory: URL {
        directoryOverride
            ?? WebLibrary.appDataDir.appendingPathComponent(
                "scratchpad-attachments", isDirectory: true)
    }

    /// Where a new attachment is written: the active document's dir, else the
    /// legacy pool (no document context — e.g. direct test usage).
    static var writeDirectory: URL { activeDirectory ?? directory }

    /// Persist `data` and return its id (the token used in note markdown), or
    /// nil if the write failed.
    static func save(data: Data, fileExtension ext: String) -> String? {
        let id = UUID().uuidString.lowercased()
        let dir = writeDirectory
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(id).\(ext)"))
            return id
        } catch {
            return nil
        }
    }

    /// Extensions a saved attachment can carry, probed directly so a lookup is
    /// O(1) rather than scanning a directory.
    private static let knownExtensions = [
        "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "heic",
    ]

    /// The file backing `id`, probing the active document's dir first and then
    /// the legacy pool. `preferredDir` overrides the primary probe location
    /// (used during migration, before `activeDirectory` is switched over).
    static func fileURL(for id: String, preferredDir: URL? = nil) -> URL? {
        let clean = id.lowercased()
        guard !clean.isEmpty else { return nil }
        var searched = Set<String>()
        for dir in [preferredDir ?? activeDirectory, directory].compactMap({ $0 }) {
            guard searched.insert(dir.path).inserted else { continue }
            for ext in knownExtensions {
                let url = dir.appendingPathComponent("\(clean).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Every attachment id referenced by `text`.
    static func referencedIds(in text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        let pattern = "\(scheme)://([0-9a-fA-F-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var ids = Set<String>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.numberOfRanges > 1 {
                ids.insert(ns.substring(with: match.range(at: 1)).lowercased())
            }
        }
        return ids
    }

    /// Delete files in `directory` whose id isn't in `referencedIds`. Scoped to
    /// one document's attachments dir, so it can never touch another document's
    /// still-referenced images.
    static func collectGarbage(in directory: URL, referencedIds: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            if !referencedIds.contains(id) {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Move the given ids' files from the legacy global pool into `dir` (lazy
    /// migration). A file already present at the destination is left in place
    /// and the pool copy removed.
    static func migrateAttachments(ids: Set<String>, toDir dir: URL) {
        guard !ids.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for id in ids {
            let clean = id.lowercased()
            for ext in knownExtensions {
                let src = directory.appendingPathComponent("\(clean).\(ext)")
                guard fm.fileExists(atPath: src.path) else { continue }
                let dest = dir.appendingPathComponent("\(clean).\(ext)")
                if fm.fileExists(atPath: dest.path) {
                    try? fm.removeItem(at: src)
                } else {
                    try? fm.moveItem(at: src, to: dest)
                }
                break
            }
        }
    }

    /// MIME type inferred from a file's extension.
    static func mediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}
