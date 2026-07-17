import CoreGraphics
import Foundation
import Observation

/// An image captured for the scratchpad — a PDF region snapshot or an
/// externally dropped file. Raw bytes (not base64) so the attachment store can
/// write them straight to disk.
struct ScratchpadImageCapture: Sendable {
    var data: Data
    /// File extension without a dot, e.g. "jpg" / "png".
    var fileExtension: String
    var mediaType: String
    var width: Int
    var height: Int
    /// Source page for a region snapshot; nil for a dropped file.
    var pageNumber: Int?
}

/// Markdown + LaTeX scratchpad notes for the active document. State mirrors the
/// AI store's per-document lifecycle: `loadForDocument` on tab/document change,
/// `clearDocumentContext` when leaving. Edits autosave on a short debounce, and
/// are flushed immediately on document switch and app quit so nothing is lost.
///
/// Notes are stored per document under `documents/<key>/scratchpad.md`
/// (`DocumentDataStore`), keyed by `DocumentIdentity.storageKey`. `text` holds
/// the editor's `vellum-scratchpad://` runtime form; the persistence layer
/// rewrites to/from portable relative refs.
@MainActor
@Observable
final class ScratchpadStore {
    /// The editor binds to this. Every external mutation schedules a save
    /// unless we are mid-restore (loading persisted text back in).
    var text: String = "" {
        didSet {
            guard !isRestoring, text != oldValue else { return }
            scheduleSave()
        }
    }

    /// The pane's AppStore — used only to resolve/stamp the document's stable
    /// identity on first write (lazy /VellumDocId stamp). Weak like `AiStore.app`
    /// to avoid a retain cycle; nil is tolerated (falls back to the path key).
    @ObservationIgnored weak var app: AppStore?

    /// Registered by the editor's WebView coordinator: append markdown at the
    /// end of the note (with surrounding blank lines) and scroll it into view.
    /// The resulting doc change flows back through the normal `change` message,
    /// so `text` and persistence update themselves — no manual mutation here.
    @ObservationIgnored var insertMarkdownHandler: ((String) -> Void)?

    /// Transient message the panel shows when the user drops something that
    /// isn't a usable image. Set by `warnUnsupportedDrop`, auto-cleared after a
    /// few seconds; nil when no warning is showing. Also used for the persistent
    /// "editing paused" banner when the note is stuck in iCloud (see
    /// `isPersistencePaused`).
    private(set) var dropWarning: String?

    /// True when this document's note is present only as an unmaterialized iCloud
    /// placeholder that couldn't be downloaded — editing is paused so a save
    /// can't silently vanish (the write would be refused by `guardEvicted`) or
    /// clobber the real-but-evicted copy. Cleared once a document whose note is
    /// available loads. Persistence (`scheduleSave`/`flush`) short-circuits while
    /// this is set.
    private(set) var isPersistencePaused = false

    private var currentKey: String?
    private var currentDocument: DocumentInfo?
    /// The session (tab) id the current document was loaded under, captured at
    /// load so a first-write stamp targets the right tab even if the active tab
    /// changed while the debounce was pending.
    private var currentSessionId: String?
    private var isRestoring = false
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dropWarningTask: Task<Void, Never>?

    /// Restore the note for `document`, first flushing the previous document's
    /// text so switching tabs never drops an unsaved edit.
    func loadForDocument(_ document: DocumentInfo?) {
        flush()
        restore(document: document)
    }

    /// Reload this document's note from disk WITHOUT first flushing the stale
    /// in-memory text — used when a `.vellum` import rewrote scratchpad.md on
    /// disk under this document's key. The normal `loadForDocument` FLUSHES the
    /// current text first, which would rewrite the just-imported file with the
    /// pre-import note before reading it back (the mirror of the DELETE path's
    /// `discardNotesForExternalDelete` trap). This cancels any pending debounced
    /// save so a write armed before the import can never fire afterward, then
    /// restores from disk under the restore guard (so the reload itself never
    /// schedules a write).
    func discardAndReload(for document: DocumentInfo?) {
        cancelPendingSave()
        restore(document: document)
    }

    /// Shared body of `loadForDocument` / `discardAndReload`: retarget the store
    /// to `document` and load its note from disk. Assumes the caller has already
    /// dealt with the previous document's in-memory text (either flushing it or
    /// deliberately discarding it) — this method itself never persists.
    private func restore(document: DocumentInfo?) {
        currentDocument = document
        currentSessionId = app?.activeTabId
        let key = document.map { DocumentIdentity.storageKey(for: $0) }
        currentKey = key

        if let document, let key {
            // A PDF that acquired its /VellumDocId in a previous session may
            // still have its data in the old path-hash folder — carry it over.
            if let docId = document.docId, !docId.isEmpty {
                let pathKey = DocumentIdentity.sha256Hex(document.pdfPath)
                if pathKey != key { DocumentDataStore.rekey(from: pathKey, to: key) }
            }
            try? DocumentDataStore.touch(document: document)
            // Point the attachment store at this doc's dir before migrating, so
            // the migration's extension lookups resolve at the new location.
            ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: key)
            ScratchpadPersistence.migrateLegacyIfNeeded(document: document, key: key)
        } else {
            ScratchpadAttachmentStore.activeDirectory = key.map {
                DocumentDataStore.attachmentsDir(forKey: $0)
            }
        }

        // If the note is stuck in iCloud (an unmaterialized placeholder that
        // PaneView's `materializeIfNeeded` couldn't download), pause persistence
        // and show a banner instead of presenting an editable empty note whose
        // saves would be silently refused. A note available anywhere (active dir
        // or the local fallback) clears the pause.
        let paused = key.map { DocumentDataStore.scratchpadUnavailableEvicted(forKey: $0) } ?? false
        isPersistencePaused = paused
        if paused {
            dropWarningTask?.cancel()
            dropWarning = "This note is in iCloud and hasn’t downloaded yet — editing is paused until it syncs."
        } else {
            dropWarningTask?.cancel()
            dropWarning = nil
        }

        setRestored(key.map { ScratchpadPersistence.load(forKey: $0) } ?? "")
        pruneOrphanedAttachments()
    }

    /// Insert an image (region snapshot or dropped file) into the current note.
    /// Writes the bytes to the attachment store and appends a lightweight
    /// `![label](vellum-scratchpad://id)` reference to the note text.
    func addImage(_ capture: ScratchpadImageCapture, label: String) {
        guard let id = ScratchpadAttachmentStore.save(
            data: capture.data, fileExtension: capture.fileExtension) else { return }
        // Keep the alt text single-line and free of the `]` that would close it.
        let safeLabel = label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = "![\(safeLabel)](\(ScratchpadAttachmentStore.scheme)://\(id))"
        insertMarkdownHandler?(markdown)
    }

    /// Show the "only image files are accepted" notice for a few seconds.
    /// Re-dropping resets the timer so the message stays visible.
    func warnUnsupportedDrop() {
        showWarning("Only image files (PNG, JPEG, HEIC, GIF…) can be added to the scratchpad.")
    }

    /// Show a notice when a region-snapshot crop produced nothing — the drag
    /// missed a page or was too small — so a failed crop isn't silent.
    func warnRegionCaptureFailed() {
        showWarning("Couldn't capture that region. Drag a larger rectangle over the page.")
    }

    /// Display `message` in the panel banner for a few seconds; re-showing
    /// resets the timer so the latest message stays visible.
    private func showWarning(_ message: String) {
        dropWarning = message
        dropWarningTask?.cancel()
        dropWarningTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.dropWarning = nil
        }
    }

    /// Best-effort removal of attachment files no longer referenced by THIS
    /// document's note. Scoped to the active document's attachments dir, so it
    /// can never delete another document's images. Runs off the main actor.
    private func pruneOrphanedAttachments() {
        guard let dir = ScratchpadAttachmentStore.activeDirectory else { return }
        // Distinguish a genuinely EMPTY note from one that FAILED to load: a read
        // error or an iCloud-evicted scratchpad.md both surface as "". GCing an
        // empty `text` against a note that is really on disk (just unreadable
        // right now) would reap its still-referenced attachments. Only GC when
        // the note is truly empty — i.e. no scratchpad.md exists for this key.
        if text.isEmpty, let key = currentKey,
           DocumentDataStore.scratchpadExists(forKey: key) { return }
        let referenced = ScratchpadAttachmentStore.referencedIds(in: text)
        Task.detached(priority: .utility) {
            ScratchpadAttachmentStore.collectGarbage(in: dir, referencedIds: referenced)
        }
    }

    /// Flush the current document's note and reset to an empty editor (used on
    /// tab/document change, mirroring `AiStore.clearDocumentContext`).
    func clearDocumentContext() {
        flush()
        currentKey = nil
        currentDocument = nil
        currentSessionId = nil
        isPersistencePaused = false
        ScratchpadAttachmentStore.activeDirectory = nil
        setRestored("")
    }

    /// Discard the in-memory note WITHOUT persisting, when an external actor (the
    /// Storage pane) deleted this document's notes on disk. A plain reload would
    /// `flush()` the current text first and resurrect the just-deleted file, so
    /// this cancels any pending save and resets the editor under the restore
    /// guard (which suppresses the `didSet` autosave). No-op unless the deleted
    /// key is the one this store is showing.
    func discardNotesForExternalDelete(matchingKey key: String) {
        guard currentKey == key else { return }
        cancelPendingSave()
        setRestored("")
    }

    /// Cancel any armed debounced save WITHOUT persisting. The shared discard
    /// primitive behind `discardNotesForExternalDelete` and `discardAndReload`:
    /// a save scheduled (armed 400 ms) before an external delete/import must
    /// never fire afterward and rewrite the file another actor just replaced.
    private func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    /// Persist the current text immediately. Safe to call repeatedly; a no-op
    /// when there is no active document.
    ///
    /// Kept SYNCHRONOUS on purpose: it is called from `applicationShouldTerminate`
    /// before the async quit continuation, and writing one small scratchpad.md
    /// atomically is cheap enough to do inline. It cannot await a lazy docId
    /// stamp, so a not-yet-stamped PDF flushes to its path-hash fallback key —
    /// no data is dropped; the next open rekeys it to the stamped folder.
    func flush() {
        cancelPendingSave()
        // A note stuck in iCloud is read-only for this session: never write over
        // the real-but-evicted copy (the save would be refused anyway, and the
        // in-memory text is the empty placeholder state, not the user's note).
        guard !isPersistencePaused, let currentKey else { return }
        persist(key: currentKey)
    }

    /// Save the note and, when it left real data behind, ensure meta.json exists
    /// so the document re-resolves from recents even if its source file later
    /// moves. An empty note prunes the folder — nothing to stamp — so the meta
    /// write is gated on the note actually persisting (§6/§8).
    private func persist(key: String) {
        try? ScratchpadPersistence.save(forKey: key, schemeText: text)
        if let currentDocument, DocumentDataStore.scratchpadExists(forKey: key) {
            try? DocumentDataStore.touch(document: currentDocument, force: true)
        }
    }

    private func setRestored(_ value: String) {
        isRestoring = true
        text = value
        isRestoring = false
    }

    private func scheduleSave() {
        // Editing is paused while the note is stuck in iCloud — drop the edit
        // rather than schedule a write that would be refused or clobber real data.
        guard !isPersistencePaused else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard let self, !Task.isCancelled else { return }
            await self.ensureIdentityForFirstWriteIfNeeded()
            guard !Task.isCancelled, let key = self.currentKey else { return }
            self.persist(key: key)
        }
    }

    /// Before the first non-empty persist of a PDF note whose docId is nil,
    /// stamp /VellumDocId through the session so the note lands in a stable,
    /// rename-proof folder. Re-targets `currentKey`/attachments and migrates any
    /// data already written to the path-hash folder. On failure or when the app
    /// wiring is unavailable, leaves the path-hash key in place (data is never
    /// dropped — the caller still saves under `currentKey`).
    private func ensureIdentityForFirstWriteIfNeeded() async {
        guard let document = currentDocument, document.kind == .pdf,
              (document.docId?.isEmpty ?? true),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let app, let sessionId = currentSessionId else { return }
        await app.syncDocumentId(sessionId: sessionId)
        let stamped = app.tabs.first(where: { $0.id == sessionId })?.document?.docId
        guard let stamped, !stamped.isEmpty, stamped != currentKey else { return }
        let oldKey = currentKey
        currentDocument?.docId = stamped
        currentKey = stamped
        if let oldKey, oldKey != stamped {
            DocumentDataStore.rekey(from: oldKey, to: stamped)
        }
        ScratchpadAttachmentStore.activeDirectory = DocumentDataStore.attachmentsDir(forKey: stamped)
    }
}
