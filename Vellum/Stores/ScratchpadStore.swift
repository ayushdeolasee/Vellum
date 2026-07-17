import CoreGraphics
import Foundation
import Observation
import UniformTypeIdentifiers

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

    /// The editor coordinator that currently owns `insertMarkdownHandler`. When
    /// SwiftUI recreates the editor it builds the replacement (which installs a
    /// FRESH handler) before dismantling the old one; the old `dismantleNSView`
    /// must only clear the handler if it is still the owner, or it would wipe the
    /// live handler and a dropped image would save but never reach the note. Weak
    /// so a dead coordinator releases; the handler itself already captures the
    /// coordinator weakly, so a stale route is a harmless no-op.
    @ObservationIgnored weak var insertMarkdownOwner: AnyObject?

    /// Transient message the panel shows when the user drops something that
    /// isn't a usable image. Set by `warnUnsupportedDrop`, auto-cleared after a
    /// few seconds; nil when no warning is showing.
    private(set) var dropWarning: String?

    private var currentKey: String?
    private var isRestoring = false
    private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dropWarningTask: Task<Void, Never>?

    /// Restore the note for `document`, first flushing the previous document's
    /// text so switching tabs never drops an unsaved edit.
    func loadForDocument(_ document: DocumentInfo?) {
        flush()
        let key = ScratchpadPersistence.documentKey(document)
        currentKey = key
        setRestored(key.map { ScratchpadPersistence.load(for: $0) } ?? "")
        pruneOrphanedAttachments()
    }

    /// Insert an image (region snapshot or dropped file) into the current note.
    /// Writes the bytes to the attachment store and appends a lightweight
    /// `![label](vellum-scratchpad://id)` reference to the note text.
    func addImage(_ capture: ScratchpadImageCapture, label: String) {
        guard let id = ScratchpadAttachmentStore.save(
            data: capture.data, fileExtension: capture.fileExtension) else {
            // Save failed after we accepted the drop — never let it vanish silently.
            showWarning("Couldn't save that image to the scratchpad. Please try again.")
            return
        }
        // Keep the alt text single-line and free of the `]` that would close it.
        let safeLabel = label
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "]", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = "![\(safeLabel)](\(ScratchpadAttachmentStore.scheme)://\(id))"
        guard let insertMarkdownHandler else {
            // The editor's insert handler is missing — the image was saved but has
            // nowhere to land. This must never happen (the live editor installs it
            // and keeps it across remounts); surface it instead of losing the drop.
            assertionFailure("scratchpad insertMarkdownHandler is nil at addImage")
            showWarning("Couldn't add that image to the note. Please try again.")
            return
        }
        insertMarkdownHandler(markdown)
    }

    /// Take a drop routed here from the sidebar's single AppKit drag catcher (see
    /// `SidebarDropCatcher` / `SidebarPanelStack`) when the scratchpad tab is
    /// visible — the header/margins of the panel; drops on the editor body are
    /// consumed by `ScratchpadWebView` directly. An image (raw bytes from Preview /
    /// a browser, or a Finder image file) is decoded off the main actor and
    /// appended; anything else — including a dropped non-image file — is explained
    /// via `warnUnsupportedDrop`. Returns true — the drop is always "handled", even
    /// when only to warn.
    func handleDrop(_ payload: AttachmentDropPayload) -> Bool {
        switch payload {
        case let .files(urls):
            guard let url = urls.first else {
                warnUnsupportedDrop()
                return true
            }
            // Read + decode off the main actor: a large image (or one on iCloud
            // Drive) must not stall the drop while it materializes.
            Task { [weak self] in
                let capture = await Task.detached(priority: .userInitiated) {
                    () -> ScratchpadImageCapture? in
                    guard let data = try? Data(contentsOf: url) else { return nil }
                    return scratchpadCapture(from: data)
                }.value
                guard let self else { return }
                if let capture { self.addImage(capture, label: "Image") }
                else { self.warnUnsupportedDrop() }
            }
        case let .imageData(data, _):
            Task { [weak self] in
                let capture = await Task.detached(priority: .userInitiated) {
                    scratchpadCapture(from: data)
                }.value
                guard let self else { return }
                if let capture { self.addImage(capture, label: "Image") }
                else { self.warnUnsupportedDrop() }
            }
        }
        return true
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
        // Compute the reference set inside the detached task, not here on the
        // main actor: it reads every persisted note, and deferring it also lets
        // any in-flight debounced save (e.g. from a just-added image) settle
        // before we decide what to collect, avoiding a delete-then-referenced race.
        Task.detached(priority: .utility) {
            let referenced = ScratchpadPersistence.allReferencedAttachmentIds()
            ScratchpadAttachmentStore.collectGarbage(referencedIds: referenced)
        }
    }

    /// Flush the current document's note and reset to an empty editor (used on
    /// tab/document change, mirroring `AiStore.clearDocumentContext`).
    func clearDocumentContext() {
        flush()
        currentKey = nil
        setRestored("")
    }

    /// Persist the current text immediately. Safe to call repeatedly; a no-op
    /// when there is no active document.
    func flush() {
        saveTask?.cancel()
        saveTask = nil
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
