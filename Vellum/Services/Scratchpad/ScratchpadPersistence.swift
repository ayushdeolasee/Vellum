import Foundation
import os

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
        let attachmentDirectory = DocumentDataStore.attachmentsDir(forKey: key)
        let relative = schemeToRelative(bounded) {
            ScratchpadAttachmentStore.fileURL(
                for: $0, preferredDir: attachmentDirectory)?.pathExtension
        }
        if relative.isEmpty {
            DocumentDataStore.removeScratchpad(forKey: key)
        } else {
            try DocumentDataStore.saveScratchpad(forKey: key, text: relative)
        }
        // Prune attachments the note no longer points at, then drop the folder
        // entirely if nothing but meta.json is left.
        ScratchpadAttachmentStore.collectGarbage(
            in: attachmentDirectory, referencedIds: referenced)
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
        // Replace back-to-front so earlier match ranges stay valid. Convert the
        // regex's UTF-16 offsets with `Range(_:in:)`, NOT `String.index(offsetBy:)`
        // — the latter counts Characters (grapheme clusters), so an emoji before
        // a ref shifts every subsequent replacement and corrupts the rewrite.
        // Processing back-to-front keeps `result`'s prefix identical to `text`'s
        // up to each match, so the UTF-16 offset still maps to the right index.
        for match in regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let id = ns.substring(with: match.range(at: 1))
            let ext = extensionFor(id)
            let replacement = ext.map { "attachments/\(id).\($0)" } ?? "attachments/\(id)"
            result.replaceSubrange(fullRange, with: replacement)
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
        let referenced = ScratchpadAttachmentStore.referencedIds(in: legacyText)
        let destDir = DocumentDataStore.attachmentsDir(forKey: key)
        // Resolve each ref's extension from the shared pool (fileURL falls back
        // to it) so we can compute the relative form BEFORE anything is copied —
        // the attachments still live in the pool at this point.
        let relative = schemeToRelative(legacyText) {
            ScratchpadAttachmentStore.fileURL(for: $0, preferredDir: destDir)?.pathExtension
        }
        if relative.isEmpty {
            // An empty legacy note carries nothing worth a folder; just drop it.
            entries.remove(at: index)
            writeEntries(entries)
            reclaimLegacyPoolIfBlobEmpty(entries)
            return
        }
        // Order matters: write scratchpad.md FIRST, then copy attachments, then
        // drop the blob entry. If the note write fails we return having touched
        // nothing in the doc's folder — so the load path sees an absent note (not
        // a half-migrated one whose just-copied attachments per-doc GC would
        // reap), and the blob entry stays for the next open to retry.
        do {
            try DocumentDataStore.saveScratchpad(forKey: key, text: relative)
        } catch {
            return
        }
        ScratchpadAttachmentStore.migrateAttachments(ids: referenced, toDir: destDir)
        entries.remove(at: index)
        writeEntries(entries)
        reclaimLegacyPoolIfBlobEmpty(entries)
    }

    /// Once the legacy blob holds no more path-keyed notes, the shared attachment
    /// pool can be reclaimed wholesale — migration COPIES attachments into each
    /// document's folder, so nothing outside the (now empty) blob references it.
    private static func reclaimLegacyPoolIfBlobEmpty(_ entries: [Entry]) {
        guard entries.isEmpty else { return }
        try? FileManager.default.removeItem(at: ScratchpadAttachmentStore.directory)
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

    // MARK: - Pending attachments (written, reference not landed yet)

    /// Ids written but not yet seen in any saved note text, mapped to the moment
    /// their exemption lapses.
    ///
    /// A lock rather than main-actor isolation because the readers are not all
    /// on the main actor: `pruneOrphanedAttachments` dispatches `collectGarbage`
    /// to a detached task. The state is a plain Sendable dictionary, so this
    /// stays a lock around a value — no actor hop on the drop path.
    private static let pendingAttachments = OSAllocatedUnfairLock<[String: Date]>(
        initialState: [:])

    /// How long a written attachment stays exempt from collection while its
    /// reference is in flight.
    ///
    /// The window it has to cover is the editor delivering the snippet, posting
    /// its "change" message back, and the 400 ms save debounce — a fraction of a
    /// second. It deliberately does NOT have to cover the editor's WebView still
    /// loading: an insert requested before the bundle is ready is buffered, and
    /// the mark is re-armed when it is finally delivered (see
    /// `ScratchpadLiveEditor.Coordinator.flush`), so a slow cold start cannot eat
    /// the budget. A minute against a sub-second window is generous on purpose,
    /// because the failure modes are not symmetric: an exemption held too long
    /// only delays a sweep that will collect the file anyway, while one released
    /// too early deletes bytes the note is about to point at. Settable so a test
    /// can exercise the lapse without waiting a minute.
    nonisolated(unsafe) static var pendingGracePeriod: TimeInterval = 60

    /// Declare that `id`'s bytes are on disk and its markdown reference is on
    /// its way. Until that reference lands in saved text (or `pendingGracePeriod`
    /// elapses), `collectGarbage` will not reap the file.
    ///
    /// Called by the code that is *about to* insert a reference, not by `save`
    /// itself: writing bytes does not on its own imply a reference is coming
    /// (imports and tests write attachments whose text already exists, or none).
    static func markPending(_ id: String) {
        let deadline = Date().addingTimeInterval(pendingGracePeriod)
        pendingAttachments.withLock { $0[id.lowercased()] = deadline }
    }

    /// Drop every pending id that has now been observed in saved text — its
    /// reference landed, so ordinary reachability governs it from here — along
    /// with any whose grace period has lapsed. Returns what is still exempt.
    ///
    /// Keyed by id alone, so this registry spans documents while a sweep is
    /// scoped to one. That asymmetry is safe in the direction that matters: an
    /// entry can only ever spare a file, and a sweep only deletes from its own
    /// directory, so a document can neither reap another's pending attachment
    /// nor be made to keep a file it has no entry for. Ids are fresh UUIDs, so
    /// two documents sharing one is not reachable from the write path.
    private static func settlePending(observing referencedIds: Set<String>) -> Set<String> {
        let now = Date()
        return pendingAttachments.withLock { pending in
            pending = pending.filter { !referencedIds.contains($0.key) && $0.value > now }
            return Set(pending.keys)
        }
    }

    /// Test seam: the registry is process-global (#102), so a suite touching it
    /// must not inherit or leak entries.
    static func resetPending() {
        pendingAttachments.withLock { $0.removeAll() }
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

    /// Delete files in `directory` whose id isn't in `referencedIds`. Deletion is
    /// scoped to one document's attachments dir, so it can never touch another
    /// document's images. (The pending registry consulted below is *not* so
    /// scoped — see `settlePending` — but it can only ever spare a file, never
    /// select one for deletion.)
    ///
    /// `referencedIds` is a snapshot of the note as it read at some moment, and
    /// this sweep can run later — `pruneOrphanedAttachments` dispatches it to a
    /// background task, and a debounced save persists text captured earlier. An
    /// attachment written in that gap is, correctly, not in the snapshot, but it
    /// is also not garbage: it belongs to an edit the snapshot predates. Passing
    /// the moment the snapshot was taken as `referencedAsOf` keeps the sweep
    /// from reaping it. Without that, dropping an image immediately after
    /// opening a document (which sweeps with an empty reference set) could
    /// delete the bytes just written and leave a broken reference in the note.
    ///
    /// A file spared this way is not leaked: if it really is an orphan, the next
    /// sweep sees it as older than that snapshot and collects it.
    ///
    /// The cutoff cannot cover the *other* half of the race (issue #105). When an
    /// image is dropped, the bytes are written first and the markdown reference
    /// arrives afterwards, through the editor's WebView round trip. A debounced
    /// save landing in between computes a reference set that is genuinely current
    /// and genuinely does not mention the new attachment — nothing about the
    /// timestamps distinguishes it from an orphan. `markPending` closes that
    /// window instead, by naming the attachment before its reference exists; this
    /// sweep also settles pending ids it can now see referenced, so the exemption
    /// lasts until the first save that observes the reference rather than for a
    /// fixed span.
    static func collectGarbage(
        in directory: URL, referencedIds: Set<String>, referencedAsOf: Date? = nil
    ) {
        let stillPending = settlePending(observing: referencedIds)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [
                .creationDateKey, .contentModificationDateKey,
            ]) else { return }
        for url in entries {
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !referencedIds.contains(id) else { continue }
            guard !stillPending.contains(id) else { continue }
            if let referencedAsOf, isNewerThan(referencedAsOf, url: url) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True when the file was created or last written at or after `date` — i.e.
    /// it may postdate the reference snapshot being collected against.
    private static func isNewerThan(_ date: Date, url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey])
        else {
            // Unreadable timestamps: keep the file. A missed collection is
            // recoverable, deleting a live attachment is not.
            return true
        }
        return [values.creationDate, values.contentModificationDate]
            .compactMap { $0 }
            .contains { $0 >= date }
    }

    /// Copy the given ids' files from the legacy global pool into `dir` (lazy
    /// migration). COPY, not move: the pool is shared, so a second still-unmigrated
    /// note referencing the same id must still find it there. The whole pool is
    /// reclaimed at once by `ScratchpadPersistence.migrateLegacyIfNeeded` when the
    /// legacy blob goes empty (nothing can reference it anymore). A file already
    /// present at the destination is left as-is.
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
                if !fm.fileExists(atPath: dest.path) {
                    try? fm.copyItem(at: src, to: dest)
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
