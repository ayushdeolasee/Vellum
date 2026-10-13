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

/// Identifies one pane's frozen state for a coordinated external delete. The
/// generation prevents a late completion from unpausing a pane that has since
/// switched documents or started a newer destructive action.
struct ScratchpadExternalDeleteToken: Equatable, Sendable {
    var key: String
    var generation: Int
}

/// Per-pane attachment bytes for the live editor and Markdown export. WebKit
/// may invoke its scheme handler off the main actor, so this resolver uses a
/// small lock and never exposes a coordinated documents-root URL.
final class ScratchpadAttachmentResolver: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: ScratchpadStagedAttachment] = [:]

    func replace(with attachments: [ScratchpadStagedAttachment]) {
        lock.withLock {
            values = Dictionary(attachments.sorted { $0.name < $1.name }.map {
                (ScratchpadAttachmentIdentity.canonicalID(forName: $0.name), $0)
            }, uniquingKeysWith: { first, _ in first })
        }
    }

    func upsert(_ attachment: ScratchpadStagedAttachment) {
        lock.withLock { values[attachment.id] = attachment }
    }

    func attachment(for id: String) -> ScratchpadStagedAttachment? {
        lock.withLock { values[id.lowercased()] }
    }

    func snapshot() -> [ScratchpadStagedAttachment] {
        lock.withLock { Array(values.values) }
    }
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
            pendingMarkdownInsertions.removeAll { text.contains($0) }
            guard !isRestoring, text != oldValue else { return }
            scheduleSave()
        }
    }

    /// Registered by the editor's WebView coordinator: append markdown at the
    /// end of the note (with surrounding blank lines) and scroll it into view.
    /// The resulting doc change flows back through the normal `change` message,
    /// so `text` and persistence update themselves — no manual mutation here.
    @ObservationIgnored var insertMarkdownHandler: ((String) -> Void)?
    @ObservationIgnored weak var editorUndoManager: UndoManager?

    /// Transient message the panel shows when the user drops something that
    /// isn't a usable image. Set by `warnUnsupportedDrop`, auto-cleared after a
    /// few seconds; nil when no warning is showing.
    private(set) var dropWarning: String?
    private(set) var isPersistencePaused = false
    /// Ephemeral identity for the editor bridge. It changes when an
    /// authoritative note belongs to a different document or tab, so queued
    /// WebKit messages cannot edit the note loaded after them.
    private(set) var editorContext = UUID().uuidString
    private var editorDocument: DocumentInfo?
    private var editorSessionId: String?
    private var resetsEditorContextOnLoad = false
    var editorAcceptsChanges: Bool {
        guard !isPersistencePaused, !isLoadingDocument else { return false }
        guard app != nil else { return true }
        return isShowingCurrentDocument
    }
    private(set) var isLoadingDocument = false

    /// Weak like `AiStore.app` — the store is owned by the pane, which owns the
    /// AppStore too, so a strong reference here would be a cycle.
    @ObservationIgnored weak var app: AppStore?
    @ObservationIgnored private let coordinator: StorageCoordinator?
    @ObservationIgnored let attachmentResolver = ScratchpadAttachmentResolver()

    private var currentKey: String?
    private var currentDocument: DocumentInfo?
    /// The session (tab) id the current document was loaded under, captured at
    /// load so a clear registered now can be undone against the right tab even
    /// if the active tab changed in the meantime.
    private var currentSessionId: String?
    private var isRestoring = false
    private var debounceTask: Task<Void, Never>?
    /// Per-pane commit tail. A second flush awaits the first before it snapshots
    /// `persistedBaseline`, text, or attachments, so one pane cannot conflict
    /// with its own in-flight save.
    private var flushTail: Task<Void, Never>?
    /// Drawing serialization/preview work belongs to the same document as the
    /// stroke that started it. Flush, clear and document teardown join this tail.
    private var attachmentUpdateTail: Task<Void, Never>?
    private var pendingAttachmentUpdates: [String: @Sendable () -> [ScratchpadStagedAttachment]] = [:]
    private var failedAttachmentUpdates: Set<String> = []
    private(set) var attachmentRevision = 0
    private var stateGeneration = 0
    private(set) var documentLoadGeneration = 0
    private var externalDeleteToken: ScratchpadExternalDeleteToken?
    /// Coordinated storage is intentionally write-on-change. A clean load must
    /// not stamp a PDF identity, touch metadata, or rewrite scratchpad.md merely
    /// because the pane switched or the app entered the background.
    private var hasCoordinatedChanges = false
    var hasUncommittedChanges: Bool { hasCoordinatedChanges }
    /// A closed pane can still own a failed-save draft; recovery must not
    /// replace its file merely because its tab has disappeared.
    func hasPendingChanges(forKey key: String?) -> Bool {
        guard hasCoordinatedChanges else { return false }
        guard let key else { return true }
        return currentKey == key || currentDocument.map { DocumentIdentity.storageKey(for: $0) == key } == true
    }

    private var coordinatedChangeRevision = 0
    private(set) var editRevision = 0
    /// Last authoritative text loaded/saved for this pane. When a first edit
    /// stamps a PDF and rekey merges a distinct durable-key note, this lets the
    /// edit replace only its old source copy inside that merged result.
    private var persistedBaseline = ""
    private var pendingRebaseBaseline: String?
    private var dirtyAttachmentNames: Set<String> = []
    /// Image snippets waiting for the WebView's change callback. They are part
    /// of the authoritative save snapshot immediately, even while the visible
    /// editor is still applying the insertion asynchronously.
    private var pendingMarkdownInsertions: [String] = []
    @ObservationIgnored private var dropWarningTask: Task<Void, Never>?
    /// The tail of this store's chain of background attachment sweeps (see
    /// `pruneOrphanedAttachments`). Kept rather than dropped so the sweep is
    /// joinable: production never waits on it — it is best-effort and must not
    /// delay a document open — but a test can join it instead of racing it
    /// (#100). Each sweep awaits its predecessor, so this one handle covers
    /// every sweep the store has armed.
    @ObservationIgnored private(set) var attachmentSweepTask: Task<Void, Never>?

    init(coordinator: StorageCoordinator? = nil) {
        self.coordinator = coordinator
    }

    /// Restore the note for `document`, first flushing the previous document's
    /// text so switching tabs never drops an unsaved edit.
    @discardableResult
    func loadForDocument(_ document: DocumentInfo?) -> Task<Void, Never> {
        let generation = beginDocumentLoad()
        let sessionId = app?.activeTabId
        if coordinator == nil {
            flushDirect()
            restoreDirect(document: document, sessionId: sessionId)
            isLoadingDocument = false
            return Task {}
        }
        return Task { [weak self] in
            guard let self else { return }
            defer { self.finishDocumentLoad(generation) }
            await self.enqueueCoordinatedFlush().value
            guard generation == self.documentLoadGeneration else { return }
            await self.restoreCoordinated(
                document: document, sessionId: sessionId, loadGeneration: generation)
        }
    }

    /// Reload this document's note from disk WITHOUT first flushing the stale
    /// in-memory text — used when a `.vellum` import rewrote scratchpad.md on
    /// disk under this document's key. The normal `loadForDocument` FLUSHES the
    /// current text first, which would rewrite the just-imported file with the
    /// pre-import note before reading it back (the mirror of the DELETE path's
    /// trap). This cancels any pending debounced save so a write armed before
    /// the import can never fire afterward, then restores from disk under the
    /// restore guard (so the reload itself never schedules a write).
    @discardableResult
    func discardAndReload(for document: DocumentInfo?) -> Task<Void, Never> {
        let generation = beginDocumentLoad()
        let sessionId = app?.activeTabId
        invalidatePendingWrite(matchingKey: currentKey)
        if coordinator == nil {
            restoreDirect(document: document, sessionId: sessionId)
            isLoadingDocument = false
            return Task {}
        }
        isPersistencePaused = true
        // The loading editor may already have observed the invalidation token.
        // Give the authoritative replacement its own history when it arrives.
        resetsEditorContextOnLoad = true
        return Task { [weak self] in
            guard let self else { return }
            defer { self.finishDocumentLoad(generation) }
            guard generation == self.documentLoadGeneration else { return }
            await self.restoreCoordinated(
                document: document, sessionId: sessionId, loadGeneration: generation)
        }
    }

    /// Shared body of `loadForDocument` / `discardAndReload`: retarget the store
    /// to `document` and load its note from disk. Assumes the caller has already
    /// dealt with the previous document's in-memory text (either flushing it or
    /// deliberately discarding it) — this method itself never persists.
    private func restoreDirect(document: DocumentInfo?, sessionId: String?) {
        let key = ScratchpadPersistence.documentKey(document)
        currentKey = key
        currentDocument = document
        currentSessionId = sessionId
        setLoaded(key.map { ScratchpadPersistence.load(for: $0) } ?? "")
        pruneOrphanedAttachments()
    }

    private func restoreCoordinated(
        document: DocumentInfo?, sessionId: String?, loadGeneration: Int
    ) async {
        guard let coordinator else { return }
        await awaitAttachmentUpdates()
        guard loadGeneration == documentLoadGeneration else { return }
        stateGeneration &+= 1
        let generation = stateGeneration
        isPersistencePaused = true
        currentDocument = document
        currentSessionId = sessionId
        guard let document else {
            currentKey = nil
            isPersistencePaused = false
            attachmentResolver.replace(with: [])
            clearCoordinatedChanges()
            setLoaded("")
            return
        }

        let key = DocumentIdentity.storageKey(for: document)
        currentKey = key
        if let docId = document.docId, !docId.isEmpty {
            let pathKey = DocumentIdentity.sha256Hex(document.pdfPath)
            if pathKey != key {
                guard await DocumentDataStore.rekey(
                    from: pathKey, to: key, coordinator: coordinator) else {
                    guard generation == stateGeneration,
                          loadGeneration == documentLoadGeneration else { return }
                    isPersistencePaused = true
                    attachmentResolver.replace(with: [])
                    clearCoordinatedChanges()
                    setLoaded("")
                    showPersistentWarning(
                        "This Scratchpad could not be moved to the document's saved identity. Editing is paused so neither copy is overwritten.")
                    return
                }
            }
        }
        guard generation == stateGeneration,
              loadGeneration == documentLoadGeneration else { return }

        let migration = await ScratchpadPersistence.migrateLegacyIfNeeded(
            document: document, key: key, coordinator: coordinator)
        guard generation == stateGeneration,
              loadGeneration == documentLoadGeneration else { return }
        if case .retainedForRetry(let legacy) = migration {
            attachmentResolver.replace(with: legacy.attachments)
            clearCoordinatedChanges()
            isPersistencePaused = true
            setLoaded(legacy.text)
            showPersistentWarning(
                "This older Scratchpad could not be moved safely. Editing is paused and the original is kept for retry.")
            return
        }

        do {
            let note = try await ScratchpadPersistence.load(
                forKey: key, coordinator: coordinator)
            let loaded = try await DocumentDataStore.loadAttachments(
                forKey: key, coordinator: coordinator).map { value in
                ScratchpadStagedAttachment(
                    id: (value.name as NSString).deletingPathExtension.lowercased(),
                    name: value.name, data: value.data)
            }
            guard generation == stateGeneration,
                  loadGeneration == documentLoadGeneration else { return }
            attachmentResolver.replace(with: loaded)
            clearCoordinatedChanges()
            isPersistencePaused = false
            dropWarningTask?.cancel()
            dropWarning = nil
            setLoaded(note)
        } catch {
            guard generation == stateGeneration,
                  loadGeneration == documentLoadGeneration else { return }
            isPersistencePaused = true
            attachmentResolver.replace(with: [])
            clearCoordinatedChanges()
            setLoaded("")
            showPersistentWarning(
                "This note is unavailable or still downloading from iCloud. Editing is paused until it can be read safely.")
        }
    }

    /// Insert an image (region snapshot or dropped file) into the current note.
    /// Writes the bytes to the attachment store and appends a lightweight
    /// `![label](vellum-scratchpad://id)` reference to the note text.
    func addImage(_ capture: ScratchpadImageCapture, label: String) {
        guard !isPersistencePaused else { return }
        let id: String
        if coordinator == nil {
            guard let saved = ScratchpadAttachmentStore.save(
                data: capture.data, fileExtension: capture.fileExtension) else { return }
            id = saved
        } else {
            id = UUID().uuidString.lowercased()
            let attachment = ScratchpadStagedAttachment(
                id: id,
                name: "\(id).\(capture.fileExtension.lowercased())",
                data: capture.data)
            attachmentResolver.upsert(attachment)
            dirtyAttachmentNames.insert(attachment.name)
            markCoordinatedChanged()
        }
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
        pendingMarkdownInsertions.append(markdown)
        scheduleSave()
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

    /// Stage native drawing bytes and previews off the main actor before the
    /// existing save lane publishes their Markdown references.
    func queueAttachmentUpdate(
        id: String,
        context: String,
        operation: @escaping @Sendable () -> [ScratchpadStagedAttachment]
    ) {
        guard coordinator != nil, context == editorContext, editorAcceptsChanges else { return }
        let generation = stateGeneration
        pendingAttachmentUpdates[id] = operation
        scheduleSave()
        guard attachmentUpdateTail == nil else { return }
        attachmentUpdateTail = Task { [weak self] in
            guard let self else { return }
            defer { self.attachmentUpdateTail = nil }
            while let (id, operation) = self.pendingAttachmentUpdates.first {
                self.pendingAttachmentUpdates.removeValue(forKey: id)
                let attachments = await Task.detached(priority: .userInitiated, operation: operation).value
                guard generation == self.stateGeneration, !self.isPersistencePaused else {
                    self.pendingAttachmentUpdates.removeAll()
                    return
                }
                // A newer stroke replaces work queued for the same region.
                guard self.pendingAttachmentUpdates[id] == nil else { continue }
                guard !attachments.isEmpty else {
                    self.failedAttachmentUpdates.insert(id)
                    self.showWarning("Couldn't prepare this drawing for saving. Your strokes remain open; try editing the region again.")
                    continue
                }
                self.failedAttachmentUpdates.remove(id)
                let referenced = ScratchpadAttachmentStore.referencedIds(in: self.text)
                for attachment in attachments where referenced.contains(attachment.id) {
                    self.attachmentResolver.upsert(attachment)
                    self.dirtyAttachmentNames.insert(attachment.name)
                }
                self.attachmentRevision &+= 1
            }
        }
    }

    func awaitAttachmentUpdates() async {
        await attachmentUpdateTail?.value
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

    private func showPersistentWarning(_ message: String) {
        dropWarningTask?.cancel()
        dropWarning = message
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
    @discardableResult
    func clearDocumentContext() -> Task<Void, Never> {
        let generation = beginDocumentLoad()
        if coordinator != nil {
            let task = flush()
            return Task { [weak self] in
                await task.value
                guard let self else { return }
                defer { self.finishDocumentLoad(generation) }
                guard generation == self.documentLoadGeneration else { return }
                self.resetDocumentContext()
            }
        }
        _ = flush()
        resetDocumentContext()
        isLoadingDocument = false
        return Task {}
    }

    private func beginDocumentLoad() -> Int {
        documentLoadGeneration &+= 1
        isLoadingDocument = true
        editorContext = UUID().uuidString
        resetsEditorContextOnLoad = true
        cancelPendingSave()
        return documentLoadGeneration
    }

    private func finishDocumentLoad(_ generation: Int) {
        if generation == documentLoadGeneration { isLoadingDocument = false }
    }

    /// WebKit callbacks may arrive after the pane has switched sources.
    var isShowingCurrentDocument: Bool {
        guard !isLoadingDocument,
              currentSessionId == app?.activeTabId,
              let currentDocument, let document = app?.document else { return false }
        return isSameDocument(currentDocument, document)
    }

    func updateFromEditor(_ value: String, generation: Int) {
        guard isShowingCurrentDocument, !isPersistencePaused,
              generation == documentLoadGeneration else { return }
        text = value
    }

    private func resetDocumentContext() {
        currentKey = nil
        currentDocument = nil
        currentSessionId = nil
        isPersistencePaused = false
        attachmentResolver.replace(with: [])
        clearCoordinatedChanges()
        setLoaded("")
    }

    /// Close the local debounce window before an import/delete invalidates the
    /// shared per-key write lane.
    func invalidatePendingWrite(matchingKey key: String?) {
        guard key == nil || currentKey == key else { return }
        stateGeneration &+= 1
        cancelPendingSave()
    }

    /// Freeze a matching pane before an import enters the shared write lane.
    /// If the import fails, its completion notification still reloads the old
    /// authoritative bytes and re-enables editing.
    func prepareForExternalImport(matchingKey key: String) {
        guard currentKey == key else { return }
        invalidatePendingWrite(matchingKey: key)
        isPersistencePaused = true
        showPersistentWarning("Importing this document's Scratchpad…")
    }

    /// Drop editable state before a destructive barrier starts. Doing this on
    /// the main actor closes the window where a user edit could queue behind the
    /// delete and become the first write after it.
    @discardableResult
    func prepareForExternalDelete(
        matchingKey key: String
    ) -> ScratchpadExternalDeleteToken? {
        guard currentKey == key else { return nil }
        if let token = externalDeleteToken,
           token.key == key,
           token.generation == stateGeneration {
            return token
        }
        invalidatePendingWrite(matchingKey: key)
        let token = ScratchpadExternalDeleteToken(
            key: key, generation: stateGeneration)
        externalDeleteToken = token
        attachmentResolver.replace(with: [])
        clearCoordinatedChanges()
        isPersistencePaused = true
        setLoaded("")
        showPersistentWarning("Deleting this document's Scratchpad…")
        return token
    }

    /// Finish only the exact frozen delete that produced `token`. A failure
    /// reloads authoritative storage; if that read is unavailable, the normal
    /// restore path leaves editing paused instead of risking resurrection.
    func finishExternalDelete(
        _ token: ScratchpadExternalDeleteToken,
        succeeded: Bool
    ) async {
        guard externalDeleteToken == token else { return }
        externalDeleteToken = nil
        guard currentKey == token.key,
              stateGeneration == token.generation else { return }

        if succeeded {
            attachmentResolver.replace(with: [])
            clearCoordinatedChanges()
            setLoaded("")
            isPersistencePaused = false
            dropWarningTask?.cancel()
            dropWarning = nil
            return
        }

        showPersistentWarning(
            "Couldn't finish deleting this Scratchpad. Reloading the saved note…")
        let generation = beginDocumentLoad()
        defer { finishDocumentLoad(generation) }
        if coordinator == nil {
            restoreDirect(document: currentDocument, sessionId: currentSessionId)
            isPersistencePaused = false
        } else {
            await restoreCoordinated(
                document: currentDocument, sessionId: currentSessionId,
                loadGeneration: generation)
        }
    }

    /// An external delete already removed the file. Join any write that had
    /// crossed its cancellation check, then repeat the remove so stale text can
    /// never become the final state.
    func discardNotesForExternalDelete(matchingKey key: String) {
        guard currentKey == key else { return }
        if let token = externalDeleteToken,
           token.key == key,
           token.generation == stateGeneration {
            // StorageSettings already owns the barrier. Its notification is
            // posted while this token is active so the observer cannot start a
            // duplicate delete or unfreeze the pane early.
            return
        }
        guard let token = prepareForExternalDelete(matchingKey: key) else { return }
        guard let coordinator else {
            flushTail = Task { [weak self] in
                await self?.finishExternalDelete(token, succeeded: true)
            }
            return
        }
        flushTail = Task { [weak self] in
            let deleted = await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
                forKeys: [key]
            ) {
                do {
                    try await DocumentDataStore.deleteNotesSafely(
                        forKey: key, coordinator: coordinator)
                    return true
                } catch {
                    return false
                }
            }
            await self?.finishExternalDelete(token, succeeded: deleted)
        }
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
            if coordinator != nil {
                guard let attachment = attachmentResolver.attachment(for: id) else {
                    showWarning("Couldn't safely clear this note because one of its images is unavailable.")
                    return nil
                }
                attachments.append(.init(
                    id: id,
                    fileExtension: (attachment.name as NSString).pathExtension.lowercased(),
                    data: attachment.data))
            } else {
                guard let url = ScratchpadAttachmentStore.fileURL(for: id),
                      let data = try? Data(contentsOf: url) else {
                    showWarning("Couldn't safely clear this note because one of its images is unavailable.")
                    return nil
                }
                attachments.append(.init(
                    id: id, fileExtension: url.pathExtension.lowercased(), data: data))
            }
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
        guard coordinator == nil || showing else {
            showWarning("Return to this document before undoing its Scratchpad clear.")
            return nil
        }
        if showing { cancelPendingSave() }
        let current = showing ? text : ScratchpadPersistence.load(for: transaction.key)
        let separator = current.isEmpty ? "" : "\n\n"
        let prefix = transaction.removedText + separator
        let restored = prefix + current
        // Direct compatibility uses the old flat pool. A live coordinated pane
        // restores the same bytes into its resolver and the next serialized save
        // publishes them before the markdown that references them.
        let directory = ScratchpadAttachmentStore.directory
        do {
            for attachment in transaction.attachments {
                if coordinator != nil {
                    let staged = ScratchpadStagedAttachment(
                        id: attachment.id,
                        name: "\(attachment.id).\(attachment.fileExtension)",
                        data: attachment.data)
                    attachmentResolver.upsert(staged)
                    dirtyAttachmentNames.insert(staged.name)
                    markCoordinatedChanged()
                } else {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true)
                    try attachment.data.write(
                        to: directory.appendingPathComponent(
                            "\(attachment.id).\(attachment.fileExtension)"),
                        options: .atomic)
                }
            }
        } catch {
            showWarning("Couldn't restore the cleared note. Its recovery data is still available in Undo.")
            return nil
        }
        // Unlike main's, this `save` cannot throw — it writes the in-memory
        // cache and schedules a coalesced defaults flush — so it sits outside
        // the `do` block. The failure that actually matters, the attachment
        // write, still raises the banner above.
        if coordinator == nil {
            ScratchpadPersistence.save(for: transaction.key, text: restored)
        }
        if showing {
            setRestored(restored)
            if coordinator != nil {
                markCoordinatedChanged()
                scheduleSave()
            }
        }
        return ScratchpadClearRestoration(transaction: transaction, insertedPrefix: prefix)
    }

    /// Remove only the prefix reinserted by Undo. If the restored portion was
    /// edited in place, fail closed rather than deleting ambiguous content.
    @discardableResult
    func redoClear(_ restoration: ScratchpadClearRestoration) -> Bool {
        let transaction = restoration.transaction
        guard let document = currentDocument(for: transaction) else { return false }
        let showing = isShowing(transaction, document: document)
        guard coordinator == nil || showing else {
            showWarning("Return to this document before redoing its Scratchpad clear.")
            return false
        }
        if showing { cancelPendingSave() }
        let current = showing ? text : ScratchpadPersistence.load(for: transaction.key)
        guard current.hasPrefix(restoration.insertedPrefix) else {
            showWarning("Couldn't redo Clear Scratchpad because the restored text was edited.")
            return false
        }
        let remaining = String(current.dropFirst(restoration.insertedPrefix.count))
        if coordinator == nil {
            ScratchpadPersistence.save(for: transaction.key, text: remaining)
        }
        if showing {
            setRestored(remaining)
            if coordinator != nil {
                markCoordinatedChanged()
                scheduleSave()
            }
        }
        return true
    }

    /// Resolve through the transaction's tab. The path/kind guard keeps a stale
    /// undo transaction from following a reused tab into another document.
    ///
    /// The transaction follows its originating tab across a path-key →
    /// durable-id rekey; only the visible tab/path check belongs here.
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
        debounceTask?.cancel()
        debounceTask = nil
    }

    @discardableResult
    func flush() -> Task<Void, Never> {
        cancelPendingSave()
        if coordinator == nil {
            flushDirect()
            return Task {}
        }
        return enqueueCoordinatedFlush()
    }

    private func enqueueCoordinatedFlush() -> Task<Void, Never> {
        let previous = flushTail
        let task = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            await self.awaitAttachmentUpdates()
            await self.flushCoordinated()
        }
        flushTail = task
        return task
    }

    private func flushDirect() {
        guard let currentKey else { return }
        ScratchpadPersistence.save(for: currentKey, text: textIncludingPendingInsertions())
    }

    private func flushCoordinated() async {
        guard hasCoordinatedChanges,
              !isPersistencePaused,
              let coordinator,
              var document = currentDocument,
              let sessionId = currentSessionId,
              var key = currentKey else { return }
        let generation = stateGeneration
        let changeRevision = coordinatedChangeRevision

        // First real note edit adopts the session's durable PDF identity before
        // writing class-B data. The coordinated rekey preserves both notes on a
        // collision (DocumentDataStore), then this edit lands at the durable key.
        if document.kind == .pdf, document.docId?.isEmpty ?? true {
            await app?.syncDocumentId(sessionId: sessionId)
            guard generation == stateGeneration,
                  currentSessionId == sessionId else { return }
            document = app?.tabs.first(where: { $0.id == sessionId })?.document ?? document
            let adoptedKey = DocumentIdentity.storageKey(for: document)
            if adoptedKey != key {
                guard await DocumentDataStore.rekey(
                    from: key, to: adoptedKey, coordinator: coordinator) else {
                    showWarning("Couldn't safely adopt this document's Scratchpad identity. Please try again.")
                    return
                }
                key = adoptedKey
                currentKey = adoptedKey
                currentDocument = document
                pendingRebaseBaseline = persistedBaseline
                do {
                    let loaded = try await loadCoordinatedAttachments(
                        forKey: adoptedKey, coordinator: coordinator)
                    guard generation == stateGeneration,
                          currentSessionId == sessionId,
                          currentKey == adoptedKey else { return }
                    replaceAttachmentsWithDurableSnapshot(loaded)
                } catch {
                    showWarning(
                        "Couldn't verify the rekeyed Scratchpad images. Your edit remains open for retry.")
                    return
                }
            }
        }

        if let baseline = pendingRebaseBaseline {
            do {
                let merged = try await ScratchpadPersistence.load(
                    forKey: key, coordinator: coordinator)
                guard generation == stateGeneration else { return }
                setRestored(rebasingCurrentEdit(text, from: baseline, onto: merged))
                persistedBaseline = merged
                pendingRebaseBaseline = nil
            } catch {
                showWarning(
                    "Couldn't verify the rekeyed Scratchpad. Your edit remains open for retry.")
                return
            }
        }

        await awaitAttachmentUpdates()
        guard generation == stateGeneration, currentSessionId == sessionId,
              currentKey == key, !isPersistencePaused,
              failedAttachmentUpdates.isDisjoint(with: ScratchpadAttachmentStore.referencedIds(in: text)) else { return }
        let attachments = attachmentResolver.snapshot()
        let dirty = dirtyAttachmentNames
        let expectedBaseline = persistedBaseline
        let schemeSnapshot = textIncludingPendingInsertions()
        let committed = await ScratchpadPersistence.save(
            forKey: key, document: document,
            schemeText: schemeSnapshot,
            expectedBaseline: expectedBaseline,
            attachments: attachments, dirtyAttachmentNames: dirty,
            coordinator: coordinator)
        guard generation == stateGeneration,
              currentSessionId == sessionId,
              currentKey == key else { return }
        if let committed {
            persistedBaseline = committed
            if committed != schemeSnapshot {
                do {
                    let loaded = try await loadCoordinatedAttachments(
                        forKey: key, coordinator: coordinator)
                    guard generation == stateGeneration,
                          currentSessionId == sessionId,
                          currentKey == key else { return }
                    // Snapshot the resolver and dirty names only after the
                    // awaited load. No suspension occurs before replacement,
                    // so a newer staged image always wins over durable bytes.
                    replaceAttachmentsWithDurableSnapshot(loaded)
                } catch {
                    showWarning(
                        "The note was saved, but some images could not be refreshed yet.")
                }
            }
            dirtyAttachmentNames.subtract(dirty)
            if changeRevision == coordinatedChangeRevision {
                setRestored(committed)
                clearCoordinatedChanges()
            }
        } else {
            showWarning("Couldn't save this Scratchpad yet. Your edit remains open for retry.")
        }
    }

    private func setRestored(_ value: String) {
        isRestoring = true
        text = value
        isRestoring = false
    }

    private func setLoaded(_ value: String) {
        let sameDocument: Bool
        switch (editorDocument, currentDocument) {
        case (nil, nil): sameDocument = true
        case let (previous?, current?):
            if let previousId = previous.docId, !previousId.isEmpty,
               let currentId = current.docId, !currentId.isEmpty {
                sameDocument = previous.kind == current.kind && previousId == currentId
            } else {
                sameDocument = isSameDocument(previous, current)
            }
        default: sameDocument = false
        }
        if !sameDocument || editorSessionId != currentSessionId || resetsEditorContextOnLoad {
            editorContext = UUID().uuidString
        }
        resetsEditorContextOnLoad = false
        editorDocument = currentDocument
        editorSessionId = currentSessionId
        persistedBaseline = value
        pendingRebaseBaseline = nil
        pendingMarkdownInsertions.removeAll()
        setRestored(value)
    }

    /// The editor's event carries the context that produced it, rather than
    /// implicitly following the coordinator's newest SwiftUI binding.
    @discardableResult
    func acceptEditorChange(_ value: String, context: String, generation: Int? = nil) -> Bool {
        guard context == editorContext, editorAcceptsChanges else { return false }
        if let generation, generation != documentLoadGeneration { return false }
        if text != value { text = value }
        return true
    }

    private func loadCoordinatedAttachments(
        forKey key: String,
        coordinator: StorageCoordinator
    ) async throws -> [ScratchpadStagedAttachment] {
        try await DocumentDataStore.loadAttachments(
            forKey: key, coordinator: coordinator).map { value in
                ScratchpadStagedAttachment(
                    id: (value.name as NSString).deletingPathExtension.lowercased(),
                    name: value.name,
                    data: value.data)
            }
    }

    /// Main-actor, non-suspending merge used after an awaited durable load.
    private func replaceAttachmentsWithDurableSnapshot(
        _ loaded: [ScratchpadStagedAttachment]
    ) {
        var merged = Dictionary(loaded.sorted { $0.name < $1.name }.map {
            (ScratchpadAttachmentIdentity.canonicalID(forName: $0.name), $0)
        }, uniquingKeysWith: { first, _ in first })
        let staged = attachmentResolver.snapshot()
        let dirty = dirtyAttachmentNames
        for attachment in staged where dirty.contains(attachment.name) {
            merged[attachment.id] = attachment
        }
        attachmentResolver.replace(with: Array(merged.values))
    }

    private func textIncludingPendingInsertions() -> String {
        pendingMarkdownInsertions.reduce(text) { result, markdown in
            guard !result.contains(markdown) else { return result }
            if result.isEmpty { return markdown + "\n" }
            if result.hasSuffix("\n\n") { return result + markdown + "\n" }
            if result.hasSuffix("\n") { return result + "\n" + markdown + "\n" }
            return result + "\n\n" + markdown + "\n"
        }
    }

    private func rebasingCurrentEdit(
        _ edited: String,
        from baseline: String,
        onto merged: String
    ) -> String {
        guard merged != baseline else { return edited }
        if !baseline.isEmpty,
           let range = merged.range(of: baseline, options: .backwards) {
            var result = merged
            result.replaceSubrange(range, with: edited)
            return result
        }
        guard !edited.isEmpty else { return merged }
        let marker = "\n\n---\n\n## Recovered edits from before document identity changed\n\n"
        guard !merged.contains(marker + edited) else { return merged }
        return merged + marker + edited
    }

    private func markCoordinatedChanged() {
        editRevision &+= 1
        guard coordinator != nil else { return }
        hasCoordinatedChanges = true
        coordinatedChangeRevision &+= 1
    }

    private func clearCoordinatedChanges() {
        hasCoordinatedChanges = false
        failedAttachmentUpdates.removeAll()
        dirtyAttachmentNames.removeAll()
        pendingMarkdownInsertions.removeAll()
    }

    private func scheduleSave() {
        guard !isPersistencePaused else {
            editRevision &+= 1
            return
        }
        markCoordinatedChanged()
        debounceTask?.cancel()
        let generation = stateGeneration
        debounceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self,
                  generation == self.stateGeneration else { return }
            if self.coordinator == nil {
                self.flushDirect()
            } else {
                await self.enqueueCoordinatedFlush().value
            }
        }
    }
}
