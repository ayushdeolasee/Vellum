import Foundation
import os

/// Per-document scratchpad notes, persisted to UserDefaults keyed by the
/// document's file path — mirrors `AiPersistence`'s per-document model so a
/// note survives closing and reopening the same PDF (or webpage archive).
enum ScratchpadPersistence {
    static let notesKey = "vellum.scratchpad.notes.v1"
    static let maxDocuments = 200
    static let maxCharacters = 200_000

    private struct Entry: Codable, Sendable {
        var key: String
        var text: String
    }

    /// Decode the potentially large UserDefaults blob once per launch. All
    /// scratchpad store calls are main-actor confined; disk encoding/writes are
    /// coalesced below and never block tab interaction.
    @MainActor private static var cachedEntries: [Entry]?

    @MainActor private static func entries() -> [Entry] {
        if let cachedEntries { return cachedEntries }
        let loaded = readEntries()
        cachedEntries = loaded
        return loaded
    }

    /// UserDefaults key for a document — its file path. Nil for the empty
    /// start tab / no document (nothing to persist against).
    static func documentKey(_ document: DocumentInfo?) -> String? {
        guard let key = document?.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    @MainActor static func load(for key: String) -> String {
        let loaded = entries()
        if let exact = loaded.first(where: { $0.key == key })?.text { return exact }
        // Heal across container-UUID changes (reinstall / OS update): the note
        // was saved under the document's old absolute path, which is rooted in a
        // data-container UUID that has since changed, so the exact-key lookup
        // misses even though the note is still there. Imported PDFs keep a unique
        // filename in the library, so a same-filename entry is the same document.
        // Only PDF paths carry a filename worth matching; web keys are URLs
        // (stable across container moves) and never need this.
        let name = (key as NSString).lastPathComponent
        guard name.lowercased().hasSuffix(".pdf") else { return "" }
        return loaded.first { ($0.key as NSString).lastPathComponent == name }?.text ?? ""
    }

    @MainActor static func save(for key: String, text: String) {
        var updated = entries()
        let bounded = String(text.prefix(maxCharacters))
        // Drop any existing entry for this key; a non-empty write re-appends it
        // to the end so recency is tracked by position (most-recently-written
        // last) and eviction below is true LRU rather than insertion-order.
        if let index = updated.firstIndex(where: { $0.key == key }) {
            updated.remove(at: index)
        }
        if !bounded.isEmpty {
            updated.append(Entry(key: key, text: bounded))
        }
        // Evict least-recently-written documents first once the cap is exceeded.
        if updated.count > maxDocuments {
            updated.removeFirst(updated.count - maxDocuments)
        }
        cachedEntries = updated
        scheduleFlush()
    }

    // The notes blob goes through `AppDefaults` for the same reason the recents
    // list and the workspace do: the Storage pane's suites seed and DELETE this
    // key, and on `.standard` that is the real user's notes — and a shared
    // domain any other test process can wipe mid-test (#102). In production
    // `AppDefaults.current` IS `.standard`, so the on-disk key and its bytes are
    // unchanged.
    private static func readEntries() -> [Entry] {
        guard let data = AppDefaults.current.data(forKey: notesKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func writeEntries(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        AppDefaults.current.set(data, forKey: notesKey)
    }

    // MARK: - Legacy blob inventory (Storage pane "Not yet migrated")

    /// Every path-keyed note in the blob, surfaced by the Storage pane so the
    /// user can delete pre-migration data. `bytes` is the note's UTF-8 size (the
    /// blob holds text only; attachments live in the global pool).
    ///
    /// On iPad the blob is still the LIVE store — the `documents/<key>/` layer
    /// (packet 1) has not taken the scratchpad over yet — so what this lists is
    /// every note, not only unmigrated ones. The Storage pane's wording is
    /// already "not yet migrated", which is accurate for exactly that reason.
    // FOLLOW-UP (post-#129, "scratchpad onto DocumentDataStore"): once this
    // type writes through `DocumentDataStore.saveScratchpad(forKey:)` instead of
    // the defaults blob, this becomes a genuine migration-leftovers listing,
    // matching main's `1d9d4469`-era semantics. No signature change is needed
    // then — only the store underneath changes.
    static func listLegacyEntries() -> [(key: String, bytes: Int)] {
        readEntries().map { (key: $0.key, bytes: $0.text.utf8.count) }
    }

    /// Drop one path-keyed note from the blob (Storage-pane delete).
    ///
    /// Reads and writes the defaults blob directly rather than going through the
    /// main-actor cache, so it can run off-main like the pane's other delete
    /// actions — but it then removes the same entry from the cache, or the next
    /// coalesced flush would write the just-deleted note straight back.
    static func removeLegacyEntry(key: String) {
        var entries = readEntries()
        entries.removeAll { $0.key == key }
        writeEntries(entries)
        Task { @MainActor in
            cachedEntries?.removeAll { $0.key == key }
        }
    }

    @MainActor private static var pendingFlush: Task<Void, Never>?
    @MainActor private static var flushRevision = 0

    /// Coalesce rapid edits/tab switches and perform JSON encoding + defaults
    /// I/O off the main actor. A revision loop ensures a newer snapshot cannot
    /// be lost while an older one is being written.
    @MainActor private static func scheduleFlush() {
        flushRevision &+= 1
        guard pendingFlush == nil else { return }
        pendingFlush = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            while true {
                let revision = flushRevision
                let snapshot = entries()
                await Task.detached(priority: .utility) {
                    writeEntries(snapshot)
                }.value
                if flushRevision == revision {
                    pendingFlush = nil
                    return
                }
            }
        }
    }

    @MainActor static func awaitPendingFlush() async {
        while let flush = pendingFlush {
            await flush.value
        }
    }

    // MARK: - Attachment garbage collection

    /// Every attachment id referenced by any persisted note. Used to prune
    /// orphaned image files (an image whose `![](vellum-scratchpad://id)`
    /// reference the user has since deleted from the note text).
    @MainActor static func persistedTextsSnapshot() -> [String] {
        entries().map(\.text)
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

    /// The active document's attachments directory. Always nil on iPad today —
    /// attachments live in one flat pool — but declared so `fileURL(for:)` and
    /// the Markdown exporter's containment check read the same way they do on
    /// macOS, and so a suite can set it without a conditional.
    // FOLLOW-UP (post-#129, "scratchpad onto DocumentDataStore"): set this from
    // `ScratchpadStore.loadForDocument` to
    // `DocumentDataStore.attachmentsDir(forKey:)` once notes move into
    // `documents/<key>/`, and add the matching `writeDirectory` for `save`.
    nonisolated(unsafe) static var activeDirectory: URL?

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
    /// Keyed by id alone. On iPad every sweep covers the one flat pool, so the
    /// cross-document asymmetry main documents here does not arise; either way
    /// an entry can only ever spare a file, never select one for deletion, and
    /// ids are fresh UUIDs so two documents sharing one is not reachable from
    /// the write path.
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

    /// Extensions a saved attachment can carry (`save(data:fileExtension:)`
    /// only ever writes one of these), probed directly so a lookup is O(1)
    /// rather than scanning the whole global attachments directory.
    private static let knownExtensions = [
        "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "heic",
    ]

    /// The file backing `id` (`<id>.<known-extension>`), if present. Probes the
    /// candidate extensions instead of listing the directory, so cost is fixed
    /// no matter how many attachments exist across all documents. `preferredDir`
    /// is probed ahead of the flat pool — nil on iPad today, but the exporter
    /// and the migration path both pass one.
    // FOLLOW-UP (post-#129, "scratchpad onto DocumentDataStore"): fold
    // `activeDirectory` into the preferred element
    // (`preferredDir ?? activeDirectory`) once a document's attachments live in
    // its own folder.
    static func fileURL(for id: String, preferredDir: URL? = nil) -> URL? {
        let clean = id.lowercased()
        guard !clean.isEmpty else { return nil }
        var searched = Set<String>()
        for dir in [preferredDir, directory].compactMap({ $0 }) {
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

    /// Delete attachment files not referenced by any persisted note.
    ///
    /// `referencedIds` is a snapshot of the notes as they read at some moment,
    /// and this sweep can run later — `pruneOrphanedAttachments` dispatches it to
    /// a background task, and a debounced save persists text captured earlier. An
    /// attachment written in that gap is, correctly, not in the snapshot, but it
    /// is also not garbage: it belongs to an edit the snapshot predates. Passing
    /// the moment the snapshot was taken as `referencedAsOf` keeps the sweep
    /// from reaping it. Without that, dropping an image immediately after
    /// opening a document (which sweeps with an empty reference set) could
    /// delete the bytes just written and leave a broken reference in the note
    /// (#104).
    ///
    /// A file spared this way is not leaked: if it really is an orphan, the next
    /// sweep sees it as older than that snapshot and collects it.
    ///
    /// The cutoff cannot cover the *other* half of the race (#105). When an
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
        referencedIds: Set<String>, referencedAsOf: Date? = nil
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
