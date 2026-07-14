import Foundation

/// Per-document scratchpad notes, persisted to UserDefaults keyed by the
/// document's file path — mirrors `AiPersistence`'s per-document model so a
/// note survives closing and reopening the same PDF (or webpage archive).
enum ScratchpadPersistence {
    static let notesKey = "vellum.scratchpad.notes.v1"
    static let maxDocuments = 200
    static let maxCharacters = 200_000

    private struct Entry: Codable {
        var key: String
        var text: String
    }

    /// UserDefaults key for a document — its file path. Nil for the empty
    /// start tab / no document (nothing to persist against).
    static func documentKey(_ document: DocumentInfo?) -> String? {
        guard let key = document?.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func load(for key: String) -> String {
        readEntries().first(where: { $0.key == key })?.text ?? ""
    }

    static func save(for key: String, text: String) {
        var entries = readEntries()
        let bounded = String(text.prefix(maxCharacters))
        // Drop any existing entry for this key; a non-empty write re-appends it
        // to the end so recency is tracked by position (most-recently-written
        // last) and eviction below is true LRU rather than insertion-order.
        if let index = entries.firstIndex(where: { $0.key == key }) {
            entries.remove(at: index)
        }
        if !bounded.isEmpty {
            entries.append(Entry(key: key, text: bounded))
        }
        // Evict least-recently-written documents first once the cap is exceeded.
        if entries.count > maxDocuments {
            entries.removeFirst(entries.count - maxDocuments)
        }
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

    // MARK: - Attachment garbage collection

    /// Every attachment id referenced by any persisted note. Used to prune
    /// orphaned image files (an image whose `![](vellum-scratchpad://id)`
    /// reference the user has since deleted from the note text).
    static func allReferencedAttachmentIds() -> Set<String> {
        var ids = Set<String>()
        for entry in readEntries() {
            ids.formUnion(ScratchpadAttachmentStore.referencedIds(in: entry.text))
        }
        return ids
    }
}

/// Disk-backed store for images snapshotted or dropped into scratchpad notes.
/// The note text (in UserDefaults) only holds a lightweight
/// `vellum-scratchpad://<id>` reference; the bytes live here so a note stays
/// small no matter how many images it carries. Files are flat and globally
/// keyed by a random id, so the editor's WKWebView scheme handler can resolve
/// any reference without needing to know which document owns it.
enum ScratchpadAttachmentStore {
    static let scheme = "vellum-scratchpad"

    /// Test-only redirect for the attachment directory so tests never read or
    /// delete a real user's attachments. Nil in production.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride
            ?? WebLibrary.appDataDir.appendingPathComponent(
                "scratchpad-attachments", isDirectory: true)
    }

    /// Persist `data` and return its id (the token used in note markdown), or
    /// nil if the write failed.
    static func save(data: Data, fileExtension ext: String) -> String? {
        let id = UUID().uuidString.lowercased()
        let dir = directory
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(id).\(ext)"))
            return id
        } catch {
            return nil
        }
    }

    /// Extensions a saved attachment can carry (`save(data:fileExtension:)`
    /// only ever writes one of these), probed directly so a lookup is O(1)
    /// rather than scanning the whole global attachments directory.
    private static let knownExtensions = [
        "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "heic",
    ]

    /// The file backing `id` (`<id>.<known-extension>`), if present. Probes the
    /// candidate extensions instead of listing the directory, so cost is fixed
    /// no matter how many attachments exist across all documents.
    static func fileURL(for id: String) -> URL? {
        let clean = id.lowercased()
        guard !clean.isEmpty else { return nil }
        let dir = directory
        for ext in knownExtensions {
            let url = dir.appendingPathComponent("\(clean).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
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

    /// Delete attachment files not referenced by any persisted note.
    static func collectGarbage(referencedIds: Set<String>) {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return }
        for url in entries {
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            if !referencedIds.contains(id) {
                try? FileManager.default.removeItem(at: url)
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
