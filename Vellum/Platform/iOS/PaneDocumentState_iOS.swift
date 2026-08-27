#if os(iOS)
import SwiftUI

// Per-document store loading for one pane's store-triple, lifted verbatim out
// of `PaneView_iOS` (issue #153, P2) so the phone shell — which has no pane
// chrome at all — gets the identical annotations / AI / scratchpad lifecycle
// instead of a second, drifting copy. The sidecar-import and data-deleted
// handlers below are subtle enough that retyping them is the bug.

/// Drives the pane's document-scoped stores: reload on document identity
/// change, plus the three cross-process notifications that can invalidate what
/// those stores hold while the document stays open.
struct PaneDocumentState_iOS: ViewModifier {
    let pane: PaneModel

    @Environment(WorkspaceStore.self) private var workspace

    private var app: AppStore { pane.app }

    func body(content: Content) -> some View {
        content
            .task(id: documentIdentity) { await loadDocumentState() }
            .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)) { _ in
                guard app.document != nil else { return }
                Task { await pane.annotations.loadAnnotations() }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentSidecarWillImport)) { note in
                guard let key = note.userInfo?["key"] as? String else { return }
                pane.scratchpad.prepareForExternalImport(matchingKey: key)
            }
            .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentSidecarImported)) { note in
                // A `.vellum` import merged notes/chat into this document's sidecar
                // on disk. If THIS pane is showing it, the live stores still hold
                // pre-import state whose next flush would overwrite the merge —
                // `discardAndReload` (never `loadForDocument`, which flushes first).
                guard let key = note.userInfo?["key"] as? String,
                      let document = app.document,
                      DocumentIdentity.storageKey(for: document) == key else { return }
                AiPersistence.invalidateCachedConversation(forKey: key)
                Task {
                    await pane.ai.loadConversationForDocument(
                        document, coordinator: workspace.storageCoordinator)
                }
                Task { await pane.scratchpad.discardAndReload(for: document).value }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentDataDeleted)) { note in
                // The Storage pane deleted this document's notes/chat on disk. If THIS
                // pane shows it, drop the matching in-memory state WITHOUT saving so a
                // live writer's next flush can't resurrect the just-deleted file.
                guard let keys = note.userInfo?["keys"] as? [String],
                      let document = app.document else { return }
                let key = DocumentIdentity.storageKey(for: document)
                guard keys.contains(key) else { return }
                // FOLLOW-UP (post-#129): the notes branch is still missing. It needs
                // `ScratchpadStore.discardNotesForExternalDelete(matchingKey:)`,
                // which does not exist here because the scratchpad has no
                // per-document file for the Storage pane to have deleted — it is
                // still one UserDefaults blob (see the "scratchpad onto
                // DocumentDataStore" notes in `ScratchpadPersistence`). Land it with
                // that migration. Do NOT call `pane.scratchpad.loadForDocument`
                // here as a stopgap — that flushes the stale note back over the file
                // that was just deleted, which is the exact bug the discard path
                // exists to prevent.
                if note.userInfo?["chat"] as? Bool == true {
                    // Cache already invalidated by the poster; reload re-reads the now
                    // empty disk without writing.
                    Task {
                        await pane.ai.loadConversationForDocument(
                        document, coordinator: workspace.storageCoordinator)
                    }
                }
                if note.userInfo?["notes"] as? Bool == true {
                    pane.scratchpad.discardNotesForExternalDelete(matchingKey: key)
                }
            }
    }

    // MARK: - Per-pane document lifecycle

    private func loadDocumentState() async {
        // This task can run before the app root's startup task. Wait for the
        // coordinator here so restored documents never treat that launch race
        // as an unavailable identity migration.
        await workspace.startStorageCoordinator()
        pane.annotations.clearAnnotations()
        pane.ai.clearDocumentContext()
        await pane.scratchpad.clearDocumentContext().value
        guard app.document != nil else { return }
        await pane.annotations.loadAnnotations()
        guard !Task.isCancelled else { return }
        // In iCloud mode the document's notes/conversations may be evicted
        // placeholders — download them off-main before the sync reads below so
        // they load real bytes rather than degrading to empty.
        await pane.ai.loadConversationForDocument(
            app.document, coordinator: workspace.storageCoordinator)
        // The incoming tab may already have walked its pages; its runtime is
        // where that survived the switch (`AiStore` only ever holds the pane's
        // current document).
        if let tabId = app.activeTabId,
           let runtime = workspace.existingLiveTabRuntime(for: tabId) {
            pane.ai.restorePageTexts(runtime.pageTexts)
        }
        await pane.scratchpad.loadForDocument(app.document).value
    }

    private var documentIdentity: PaneDocumentIdentity_iOS {
        PaneDocumentIdentity_iOS(tabId: app.activeTabId, path: app.document?.pdfPath)
    }
}

extension View {
    /// Loads and invalidates `pane`'s document-scoped stores. Apply once per
    /// mounted pane, on an ancestor of everything that reads them.
    func paneDocumentState(pane: PaneModel) -> some View {
        modifier(PaneDocumentState_iOS(pane: pane))
    }
}
#endif
