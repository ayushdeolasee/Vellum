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

/// One attachment's bytes, captured before a clear so Undo can put the file
/// back even if the sweep collected it in the meantime.
struct ScratchpadAttachmentSnapshot: Equatable, Sendable {
    var id: String
    var fileExtension: String
    var data: Data
}

/// Everything a Clear removed, tied to the exact document and tab that owned it
/// so Undo repairs that note rather than whichever one is visible later.
struct ScratchpadClearTransaction: Equatable, Sendable {
    var document: DocumentInfo
    var key: String
    var sessionId: String
    var removedText: String
    var attachments: [ScratchpadAttachmentSnapshot]
}

struct ScratchpadClearRestoration: Equatable, Sendable {
    var transaction: ScratchpadClearTransaction
    /// Exact prefix inserted by Undo. Redo removes only this prefix, preserving
    /// work appended after the clear or after Undo.
    var insertedPrefix: String
}

/// Markdown + LaTeX scratchpad notes for the active document. State mirrors the
/// AI store's per-document lifecycle: `loadForDocument` on tab/document change,
/// `clearDocumentContext` when leaving. Edits autosave on a short debounce, and
/// are flushed immediately on document switch and app quit so nothing is lost.
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

    /// Registered by the editor's WebView coordinator: append markdown at the
    /// end of the note (with surrounding blank lines) and scroll it into view.
    /// The resulting doc change flows back through the normal `change` message,
    /// so `text` and persistence update themselves — no manual mutation here.
    @ObservationIgnored var insertMarkdownHandler: ((String) -> Void)?

    /// Transient message the panel shows when the user drops something that
    /// isn't a usable image. Set by `warnUnsupportedDrop`, auto-cleared after a
    /// few seconds; nil when no warning is showing.
    private(set) var dropWarning: String?

    /// Weak like `AiStore.app` — the store is owned by the pane, which owns the
    /// AppStore too, so a strong reference here would be a cycle.
    @ObservationIgnored weak var app: AppStore?

    private var currentKey: String?
    private var currentDocument: DocumentInfo?
    /// The session (tab) id the current document was loaded under, captured at
    /// load so a clear registered now can be undone against the right tab even
    /// if the active tab changed in the meantime.
    private var currentSessionId: String?
    private var isRestoring = false
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dropWarningTask: Task<Void, Never>?
    /// The tail of this store's chain of background attachment sweeps (see
    /// `pruneOrphanedAttachments`). Kept rather than dropped so the sweep is
    /// joinable: production never waits on it — it is best-effort and must not
    /// delay a document open — but a test can join it instead of racing it
    /// (#100). Each sweep awaits its predecessor, so this one handle covers
    /// every sweep the store has armed.
    @ObservationIgnored private(set) var attachmentSweepTask: Task<Void, Never>?

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
    /// trap). This cancels any pending debounced save so a write armed before
    /// the import can never fire afterward, then restores from disk under the
    /// restore guard (so the reload itself never schedules a write).
    func discardAndReload(for document: DocumentInfo?) {
        cancelPendingSave()
        restore(document: document)
    }

    /// Shared body of `loadForDocument` / `discardAndReload`: retarget the store
    /// to `document` and load its note from disk. Assumes the caller has already
    /// dealt with the previous document's in-memory text (either flushing it or
    /// deliberately discarding it) — this method itself never persists.
    private func restore(document: DocumentInfo?) {
        let key = ScratchpadPersistence.documentKey(document)
        currentKey = key
        currentDocument = document
        currentSessionId = app?.activeTabId
        setRestored(key.map { ScratchpadPersistence.load(for: $0) } ?? "")
        pruneOrphanedAttachments()
    }

    /// Insert an image (region snapshot or dropped file) into the current note.
    /// Writes the bytes to the attachment store and appends a lightweight
    /// `![label](vellum-scratchpad://id)` reference to the note text.
    func addImage(_ capture: ScratchpadImageCapture, label: String) {
        guard let id = ScratchpadAttachmentStore.save(
            data: capture.data, fileExtension: capture.fileExtension) else { return }
        // Claim the GC exemption before the snippet goes anywhere (#105). The
        // bytes are on disk but no saved note mentions them yet, so a sweep
        // running right now would see a perfectly ordinary orphan. It has to
        // happen before `insertMarkdownHandler`, which can hand the snippet
        // straight to a ready editor — "after" is already too late.
        ScratchpadAttachmentStore.markPending(id)
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

    /// Best-effort removal of attachment files no longer referenced by any
    /// note. Runs off the main actor on document load; cheap and idempotent.
    private func pruneOrphanedAttachments() {
        // Snapshot the in-memory cache cheaply, then scan markdown and touch the
        // filesystem off-main. Re-decoding every note here made each tab switch
        // pay the full persistence cost.
        let texts = ScratchpadPersistence.persistedTextsSnapshot()
        // The sweep runs on a background task while this actor keeps going, so
        // an attachment saved right after this line (a drop or region snapshot
        // landing on a freshly opened note) would not be in `referenced` and
        // would be deleted out from under the note. Collect only against files
        // that already existed when the snapshot was taken.
        let referencedAsOf = Date()
        // Chain onto the previous sweep rather than running alongside it: two
        // sweeps interleaving over one directory is pointless work, and it keeps
        // `attachmentSweepTask` a handle on ALL of this store's sweeps, not just
        // the latest — a document can be loaded more than once.
        let previous = attachmentSweepTask
        attachmentSweepTask = Task.detached(priority: .utility) {
            await previous?.value
            var referenced = Set<String>()
            for text in texts {
                referenced.formUnion(ScratchpadAttachmentStore.referencedIds(in: text))
            }
            ScratchpadAttachmentStore.collectGarbage(
                referencedIds: referenced, referencedAsOf: referencedAsOf)
        }
    }

    /// Flush the current document's note and reset to an empty editor (used on
    /// tab/document change, mirroring `AiStore.clearDocumentContext`).
    func clearDocumentContext() {
        flush()
        currentKey = nil
        currentDocument = nil
        currentSessionId = nil
        setRestored("")
    }

    // MARK: - Undoable clear

    /// Capture the note and every referenced attachment before clearing. If any
    /// referenced byte cannot be read, fail closed: leaving the note untouched
    /// is safer than offering an Undo that restores broken image references.
    @discardableResult
    func clearText() -> ScratchpadClearTransaction? {
        guard !text.isEmpty,
              let currentDocument,
              let currentKey,
              let currentSessionId else { return nil }
        let ids = ScratchpadAttachmentStore.referencedIds(in: text)
        var attachments: [ScratchpadAttachmentSnapshot] = []
        for id in ids {
            guard let url = ScratchpadAttachmentStore.fileURL(for: id),
                  let data = try? Data(contentsOf: url) else {
                showWarning("Couldn't safely clear this note because one of its images is unavailable.")
                return nil
            }
            attachments.append(.init(
                id: id, fileExtension: url.pathExtension.lowercased(), data: data))
        }
        let transaction = ScratchpadClearTransaction(
            document: currentDocument, key: currentKey, sessionId: currentSessionId,
            removedText: text, attachments: attachments)
        text = ""
        return transaction
    }

    /// Restore the cleared note ahead of any work created afterward. Attachment
    /// bytes are restored before the markdown is persisted.
    @discardableResult
    func undoClear(_ transaction: ScratchpadClearTransaction) -> ScratchpadClearRestoration? {
        guard let document = currentDocument(for: transaction) else { return nil }
        let showing = isShowing(transaction, document: document)
        if showing { cancelPendingSave() }
        let current = showing ? text : ScratchpadPersistence.load(for: transaction.key)
        let separator = current.isEmpty ? "" : "\n\n"
        let prefix = transaction.removedText + separator
        let restored = prefix + current
        // The iPad keeps one flat attachment pool, so this is where the bytes
        // came from and where they go back.
        //
        // FOLLOW-UP (post-#129, "scratchpad onto DocumentDataStore"): this
        // becomes `DocumentDataStore.attachmentsDir(forKey:)` once a document's
        // attachments live in `documents/<key>/attachments/` (main dc3ac525).
        // Blocked on the storage migration itself, not on any single symbol:
        // `ScratchpadPersistence` is still the LIVE defaults-blob store keyed by
        // `document.pdfPath`, so moving this alone would write restored bytes
        // into a folder nothing reads. See the matching notes in
        // `ScratchpadPersistence` and `ScratchpadAttachmentStore`.
        let directory = ScratchpadAttachmentStore.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for attachment in transaction.attachments {
                try attachment.data.write(
                    to: directory.appendingPathComponent(
                        "\(attachment.id).\(attachment.fileExtension)"),
                    options: .atomic)
            }
        } catch {
            showWarning("Couldn't restore the cleared note. Its recovery data is still available in Undo.")
            return nil
        }
        // Unlike main's, this `save` cannot throw — it writes the in-memory
        // cache and schedules a coalesced defaults flush — so it sits outside
        // the `do` block. The failure that actually matters, the attachment
        // write, still raises the banner above.
        ScratchpadPersistence.save(for: transaction.key, text: restored)
        if showing { setRestored(restored) }
        return ScratchpadClearRestoration(transaction: transaction, insertedPrefix: prefix)
    }

    /// Remove only the prefix reinserted by Undo. If the restored portion was
    /// edited in place, fail closed rather than deleting ambiguous content.
    @discardableResult
    func redoClear(_ restoration: ScratchpadClearRestoration) -> Bool {
        let transaction = restoration.transaction
        guard let document = currentDocument(for: transaction) else { return false }
        let showing = isShowing(transaction, document: document)
        if showing { cancelPendingSave() }
        let current = showing ? text : ScratchpadPersistence.load(for: transaction.key)
        guard current.hasPrefix(restoration.insertedPrefix) else {
            showWarning("Couldn't redo Clear Scratchpad because the restored text was edited.")
            return false
        }
        let remaining = String(current.dropFirst(restoration.insertedPrefix.count))
        ScratchpadPersistence.save(for: transaction.key, text: remaining)
        if showing { setRestored(remaining) }
        return true
    }

    /// Resolve through the transaction's tab. The path/kind guard keeps a stale
    /// undo transaction from following a reused tab into another document.
    ///
    /// Main additionally re-stamps the document's storage key here, because a
    /// clear can be undone after doc-ID stamping has rekeyed the folder. On iPad
    /// the key is `document.pdfPath` and never changes mid-session, so the whole
    /// resolution collapses to this tab lookup.
    // FOLLOW-UP (post-#129, "scratchpad onto DocumentDataStore"): reinstate
    // main's `adoptVisibleIdentity` + `DocumentDataStore.rekey` +
    // `DocumentIdentity.storageKey` resolution here (main dc3ac525). Needs two
    // things this tree does not have: `AppStore.adoptVisibleIdentity` (no such
    // symbol on iPad) and a scratchpad keyed by `DocumentIdentity.storageKey`
    // rather than `document.pdfPath`. Both arrive with the storage migration.
    private func currentDocument(for transaction: ScratchpadClearTransaction) -> DocumentInfo? {
        guard let document = app?.tabs.first(where: { $0.id == transaction.sessionId })?.document,
              isSameDocument(document, transaction.document) else { return nil }
        return document
    }

    private func isShowing(_ transaction: ScratchpadClearTransaction, document: DocumentInfo) -> Bool {
        guard currentSessionId == transaction.sessionId, let currentDocument else { return false }
        return isSameDocument(currentDocument, document)
    }

    private func isSameDocument(_ lhs: DocumentInfo, _ rhs: DocumentInfo) -> Bool {
        lhs.kind == rhs.kind && lhs.pdfPath == rhs.pdfPath
    }

    private func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }

    /// Commit the current text to the authoritative in-memory cache immediately;
    /// the persistence layer coalesces the disk write off-main.
    func flush() {
        cancelPendingSave()
        guard let currentKey else { return }
        ScratchpadPersistence.save(for: currentKey, text: text)
    }

    private func setRestored(_ value: String) {
        isRestoring = true
        text = value
        isRestoring = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let key = currentKey
        let value = text
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, self != nil else { return }
            guard let key else { return }
            ScratchpadPersistence.save(for: key, text: value)
        }
    }
}
