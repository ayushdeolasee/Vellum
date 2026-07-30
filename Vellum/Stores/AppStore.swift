import AppKit
import Foundation
import Observation
import PDFKit
import UniformTypeIdentifiers

// Tab + viewport state — port of src/stores/pdf-store.ts plus the shell-level
// sidebar state from App.tsx. Action semantics mirror the zustand store 1:1.

/// Closed tabs' in-flight teardowns, keyed by the closed tab id.
///
/// A close's teardown keeps rewriting its document long after the tab left the
/// strip: the `last_page` metadata write is a read + parse + serialize +
/// atomic rename of the whole PDF (~15s on a large document). Opening or
/// writing that same file before the rename lands races it — the reopen reads
/// stale bytes (wrong reading position), and the rename silently replaces
/// anything written in the window (lost annotations, a clobbered Save As).
///
/// The registry is owned by the WORKSPACE and shared by every pane's AppStore,
/// not kept per store, for two reasons:
/// - every pane can open/save any file, so a reopen in pane B must see a
///   teardown started by a close in pane A;
/// - closing a split pane's last tab collapses the pane and drops its store,
///   and the teardown must remain reachable — for the reopen guard and for the
///   quit drain — after the store that started it is gone.
@MainActor
final class TabTeardownRegistry {
    /// One in-flight teardown: the document path it will rewrite (the backend
    /// stores canonical paths, so this one is canonical too) and the task
    /// doing the rewriting.
    private struct Entry {
        let documentPath: String
        let task: Task<Void, Never>
    }

    private var entries: [String: Entry] = [:]

    /// True when no teardown is pending.
    var isEmpty: Bool { entries.isEmpty }

    func register(tabId: String, documentPath: String, task: Task<Void, Never>) {
        entries[tabId] = Entry(documentPath: documentPath, task: task)
    }

    /// Called by each teardown task as its last step.
    func finish(tabId: String) {
        entries[tabId] = nil
    }

    /// Await every pending teardown. `applicationShouldTerminate` drains this
    /// so quitting right after closing a tab still persists its reading
    /// position — including a tab whose close collapsed its pane.
    func awaitAll() async {
        for entry in Array(entries.values) {
            await entry.task.value
        }
    }

    /// Await any pending teardown that still holds the file at `path`. Every
    /// path that opens or writes a document file calls this first. The wait is
    /// bounded by the teardown itself and only bites when the same file is
    /// reused immediately; every other open stays instant.
    func awaitTeardowns(ofDocumentAt path: String) async {
        guard !entries.isEmpty else { return }
        // Teardowns record canonical paths, so resolve the incoming path the
        // same way for the comparison. realpath(2) is a blocking syscall —
        // PR #113 exists to keep those off the main actor — so it runs
        // detached. A path that fails to resolve (e.g. a Save As destination
        // that does not exist yet, which also cannot collide with a file a
        // teardown holds) is compared as given.
        let canonical = await Task.detached(priority: .userInitiated) {
            (try? PdfDocumentLoader.canonicalize(path)) ?? path
        }.value
        // Snapshot before awaiting: finished teardowns remove themselves from
        // the dictionary, and new ones can register across suspension points.
        let pending = entries.values.filter { $0.documentPath == canonical }
        for entry in pending {
            await entry.task.value
        }
    }
}

@MainActor
@Observable
final class AppStore {
    static let minZoom: Double = 0.25
    static let maxZoom: Double = 4.0
    static let zoomStep: Double = 0.1

    let sessions: SessionService

    // MARK: - Prepared PDFs
    //
    // There used to be a three-entry LRU of parsed `PDFDocument`s here, because
    // switching tabs tore down and rebuilt the viewer. Tabs now keep their whole
    // viewer mounted, and the parsed document lives on the tab's
    // `LiveTabRuntime` (issue #52). Keeping a second copy here would be actively
    // harmful: evicting a runtime under memory pressure would free the view but
    // leave the document alive in the LRU, so the memory the eviction existed to
    // reclaim would not actually come back. One owner, one lifetime.

    // Tab state
    private(set) var tabs: [PdfTab] = []
    private(set) var activeTabId: String?

    // Active document state
    private(set) var document: DocumentInfo?
    private(set) var isLoading = false
    var error: String?

    // Active viewport state
    private(set) var currentPage = 1
    private(set) var numPages = 0
    private(set) var zoom = 1.0
    private(set) var visiblePages: [Int] = []
    /// Raw text-offset span currently on screen (web documents only).
    private(set) var webVisibleRange: WebVisibleRange?
    /// Ids of point bookmarks currently on screen (re-anchored by the content
    /// script, so valid across restarts and page reflows).
    private(set) var webVisibleBookmarks: [String] = []

    // Active interaction mode
    private(set) var mode: InteractionMode = .view

    /// AI reply queued for the active tab's next note placement (see
    /// `beginNoteWithContent`). The source of truth lives on `PdfTab`, so this
    /// mirror changes whenever the active tab does.
    private(set) var pendingNoteContent: String?

    // Find bar (⌘F). `findVisible` drives the slim bar under the toolbar; the
    // counts are reported back by whichever viewer is active.
    var findVisible = false
    private(set) var findQuery = ""
    private(set) var findMatchCount = 0
    /// 1-based index of the current match; 0 when there are no matches.
    private(set) var findCurrentMatch = 0

    /// Where the active tab's `.snapshotRegion` drag sends its crop. Both the
    /// AI panel and scratchpad arm the same capture mode; `PdfTab` retains the
    /// value when the user changes tabs mid-gesture.
    private(set) var regionCaptureTarget: RegionCaptureTarget = .ai

    /// The window's workspace. One AppStore now backs one *pane*; app-global
    /// shell state (inspector open/tab, sidebar text size, default highlight
    /// color) lives on WorkspaceStore. Weak to avoid a retain cycle — the
    /// workspace owns the pane which owns this store.
    weak var workspace: WorkspaceStore?

    /// The full identity for an asynchronous webpage action. A tab id by
    /// itself is not enough: in-page navigation deliberately reuses it while
    /// rebinding the tab to a different URL.
    struct WebDocumentActionIdentity: Equatable, Sendable {
        let sessionId: String
        let url: String
    }

    /// Registered by the PDF viewer to zoom anchored on the viewport center
    /// (window.__zoomPdfTo in the original).
    var zoomToHandler: ((Double) -> Void)?
    /// Registered by the viewer to scroll a page into view (window.__scrollToPage).
    var scrollToPageHandler: ((Int) -> Void)?
    /// Registered by the web viewer: scroll to a text-anchored web position;
    /// returns whether the anchor was found (window.__scrollToWebPosition).
    var scrollToWebPositionHandler: ((PositionData, Int) -> Bool)?
    /// Registered by the active viewer to run a find query — highlights every
    /// match and moves to the first, reporting counts back via `setFindResults`.
    var findQueryHandler: ((String) -> Void)?
    /// Step the current find match by +1 (next) / -1 (previous), wrapping.
    var findStepHandler: ((Int) -> Void)?
    /// Clear the viewer's find highlights and state.
    var findClearHandler: (() -> Void)?
    /// Print the active document (PDF print operation / WKWebView print).
    var printHandler: (() -> Void)?
    /// Registered by the PDF viewer: flush pending extracted page text to the
    /// persistent cache. Awaited on quit so a mid-walk document keeps what it
    /// has (issue #37 PR B).
    var flushPageTextCacheHandler: (() async -> Void)?

    /// Closed tabs' in-flight teardowns. Workspace-owned and shared by every
    /// pane's store (see `TabTeardownRegistry`); standalone stores (tests) get
    /// a private one.
    private let teardowns: TabTeardownRegistry

    init(sessions: SessionService, teardowns: TabTeardownRegistry = TabTeardownRegistry()) {
        self.sessions = sessions
        self.teardowns = teardowns
    }

    // MARK: - Opening documents
    //
    // `isLoading` disables EVERY open affordance on the home screen (Open a
    // PDF…, search results, recents, the URL field). An open that never
    // finished therefore used to lock the user out of opening anything at all,
    // for the rest of the session, with nothing on screen explaining why. The
    // helpers below make that impossible: an attempt owns the flag for a
    // bounded time, and whatever happens the flag comes back.

    /// How long an open may hold the home screen's loading state before the UI
    /// is released and the delay surfaced. The work itself is NOT cancelled —
    /// a slow volume that answers late still opens its document normally.
    private static let openLoadingCeiling: Duration = .seconds(20)

    /// Identifies the open attempt that currently owns `isLoading`, so a stale
    /// attempt finishing late cannot clear a newer one's loading state.
    private var openGeneration = 0
    private var openWatchdog: Task<Void, Never>?

    /// Take ownership of the loading state for one open attempt.
    private func beginOpen() -> Int {
        openGeneration += 1
        let generation = openGeneration
        isLoading = true
        error = nil
        openWatchdog?.cancel()
        openWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.openLoadingCeiling)
            guard !Task.isCancelled else { return }
            self?.endOpen(
                generation,
                error: "Opening is taking longer than expected — the file may be on a slow or "
                    + "disconnected volume. It will open if it becomes available.")
        }
        return generation
    }

    /// Release the loading state, if this attempt still owns it. Safe to call
    /// more than once and from either the work or the watchdog.
    private func endOpen(_ generation: Int, error message: String? = nil) {
        guard generation == openGeneration, isLoading else { return }
        isLoading = false
        openWatchdog?.cancel()
        openWatchdog = nil
        if let message { error = message }
    }

    func openFile(path: String) async {
        let generation = beginOpen()
        defer { endOpen(generation) }
        do {
            try await openOneFile(path: path)
            // The watchdog may have already reported a delay; the open landed,
            // so retract it rather than leaving a stale warning on screen.
            if generation == openGeneration { error = nil }
        } catch {
            self.error = String(describing: error.localizedDescription)
        }
    }

    func openFiles(paths: [String]) async {
        guard !paths.isEmpty else { return }
        let generation = beginOpen()
        defer { endOpen(generation) }
        var errors: [String] = []
        for path in paths {
            do {
                try await openOneFile(path: path)
            } catch {
                errors.append("\(path): \(error.localizedDescription)")
            }
        }
        if !errors.isEmpty {
            self.error = errors.joined(separator: "\n")
        } else if generation == openGeneration {
            error = nil
        }
    }

    func openUrl(_ url: String) async {
        let generation = beginOpen()
        defer { endOpen(generation) }
        do {
            let sessionId = UUID().uuidString.lowercased()
            let doc = try await sessions.openWebDocument(url: url, sessionId: sessionId)
            await adoptOpenedDocument(doc, sessionId: sessionId)
            if generation == openGeneration { error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Rebind a webpage tab to a new URL (in-tab link navigation). Reuses the
    /// session id so annotation commands keep working against the same tab.
    @discardableResult
    func webNavigated(tabId: String, url: String) async -> DocumentInfo? {
        guard let tab = tabs.first(where: { $0.id == tabId }), tab.document?.kind == .web else {
            return nil
        }
        do {
            let doc = try await sessions.openWebDocument(url: url, sessionId: tabId)
            RecentFilesService.record(doc)
            updateTab(tabId) { tab in
                tab.document = doc
                tab.currentPage = doc.lastPage ?? 1
                tab.numPages = doc.pageCount ?? 0
                tab.visiblePages = []
                tab.webVisibleRange = nil
                tab.webVisibleBookmarks = []
            }
            if activeTabId == tabId {
                document = doc
                currentPage = doc.lastPage ?? 1
                numPages = doc.pageCount ?? 0
                visiblePages = []
                webVisibleRange = nil
                webVisibleBookmarks = []
            }
            return doc
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    /// Captures the active webpage before an asynchronous action begins.
    /// Callers must validate this identity again after every suspension before
    /// changing visible state or performing a compensating mutation.
    func activeWebDocumentActionIdentity() -> WebDocumentActionIdentity? {
        guard let sessionId = activeTabId,
              let document,
              document.kind == .web else { return nil }
        return WebDocumentActionIdentity(sessionId: sessionId, url: document.pdfPath)
    }

    /// True only while the active tab still represents the exact webpage that
    /// began the action. This rejects a same-tab URL rebind after an `await`.
    func isCurrentWebDocument(_ identity: WebDocumentActionIdentity) -> Bool {
        guard activeTabId == identity.sessionId,
              let tab = tabs.first(where: { $0.id == identity.sessionId }),
              let document = tab.document,
              document.kind == .web else { return false }
        return document.pdfPath == identity.url
    }

    /// Update a tab's document title (reported by the webpage content script).
    func updateDocumentTitle(tabId: String, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let tab = tabs.first(where: { $0.id == tabId }),
              var doc = tab.document,
              doc.title != trimmed else { return }
        doc.title = trimmed
        updateTab(tabId) { $0.document = doc }
        if activeTabId == tabId {
            document = doc
        }
    }

    /// Rename the open document from the tab bar.
    ///
    /// Distinct from `updateDocumentTitle` above, which exists for the webpage
    /// content script reporting the DOM `<title>` and is deliberately
    /// in-memory-only and non-empty-only: a page reporting its own title should
    /// not permanently overwrite a name the user chose, and a page reporting an
    /// empty one should be ignored. A user rename is the opposite on both
    /// counts — it must persist, and clearing it must be allowed to mean
    /// "go back to the filename".
    ///
    /// The file on disk is untouched; see `DocumentRenameService` for why.
    func renameDocument(tabId: String, title: String) async {
        guard let tab = tabs.first(where: { $0.id == tabId }), let document = tab.document else {
            return
        }
        let normalized = DocumentRenameService.normalized(title)
        let target = DocumentRenameService.Target(
            kind: document.kind,
            locator: document.pdfPath,
            recordedPath: document.pdfPath,
            storageKey: DocumentIdentity.storageKey(for: document))

        // `apply` reports whether it wrote anything. The in-memory update below
        // is what the UI reads either way, so the result is intentionally
        // discarded — named here so it isn't an unused-expression warning.
        _ = await Task.detached(priority: .userInitiated) {
            DocumentRenameService.apply(target, title: normalized)
        }.value

        var updated = document
        updated.title = normalized
        updateTab(tabId) { $0.document = updated }
        if activeTabId == tabId { document_setActive(updated) }
    }

    /// Split out so `renameDocument` reads as one thought; assigning
    /// `self.document` inline shadows the local `document` binding above it.
    private func document_setActive(_ info: DocumentInfo) {
        document = info
    }

    /// After a PDF mutation may have lazily stamped /VellumDocId, pull the
    /// resolved id up into the in-memory DocumentInfo so class-B stores can key
    /// off it this session. The stamp itself already happened during the write —
    /// for a just-stamped session the backend returns the id without touching
    /// disk. No-op once the active document already carries an id (web docs are
    /// always stamped at open, so this never fires for them). PaneDocumentIdentity
    /// stays path-based, so setting docId does not re-run loadDocumentState.
    func syncDocumentId(sessionId: String) async {
        guard let tab = tabs.first(where: { $0.id == sessionId }),
              tab.document?.kind == .pdf, tab.document?.docId == nil else { return }
        guard let id = try? await sessions.ensureDocumentId(sessionId: sessionId), !id.isEmpty else { return }
        updateTab(sessionId) { tab in
            if tab.document != nil, tab.document?.docId == nil {
                tab.document?.docId = id
            }
        }
        if activeTabId == sessionId, document?.docId == nil {
            document?.docId = id
        }
    }

    /// Save the PDF in `tabId` to a new location while keeping the existing tab
    /// and backend session identity. Keeping the id stable is important: it is
    /// also the identity used by the viewer, AI conversation, inspector, and
    /// split-pane placement.
    ///
    /// The destination is written before the session is rebound. If reopening
    /// the new location fails, the original session is restored so Save As
    /// cannot strand the live tab.
    @discardableResult
    func savePdfAs(tabId: String, destination: URL) async throws -> DocumentInfo {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let source = tab.document,
              source.kind == .pdf else {
            throw SessionServiceError.invalidDocument("Save As requires an open PDF")
        }

        let sourceURL = URL(fileURLWithPath: source.pdfPath).standardizedFileURL
        let destinationURL = destination.standardizedFileURL
        if sourceURL == destinationURL {
            return source
        }
        // `/var` and `/private/var` can name the same file on macOS without
        // URL standardization making the strings equal. Compare filesystem
        // identities when the destination already exists so choosing the
        // current file in NSSavePanel remains a true no-op.
        let sourceIdentifier = try? sourceURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let destinationIdentifier = try? destinationURL.resourceValues(
            forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        if let sourceIdentifier = sourceIdentifier as? NSObject,
           let destinationIdentifier = destinationIdentifier as? NSObject,
           sourceIdentifier.isEqual(destinationIdentifier) {
            return source
        }

        // Retargeting this tab to a file another tab already owns would leave
        // two independent backend sessions writing the same PDF. That is
        // particularly unsafe across panes, where neither tab is necessarily
        // visible while the other saves. A Save As target must therefore be a
        // genuinely new document location.
        let openTabs = workspace?.root.allLeaves().flatMap { $0.app.tabs } ?? tabs
        if openTabs.contains(where: { other in
            guard other.id != tabId,
                  let otherDocument = other.document,
                  otherDocument.kind == .pdf else { return false }
            return Self.sameFile(sourceURL: URL(fileURLWithPath: otherDocument.pdfPath), destinationURL: destinationURL)
        }) {
            throw SessionServiceError.invalidDocument(
                "That PDF is already open in another tab. Close it before using Save As."
            )
        }

        // Stamp a durable id before copying so document-scoped notes and
        // conversations follow the PDF to its new location.
        let preservedDocumentId = try await sessions.ensureDocumentId(sessionId: tabId)
        await syncDocumentId(sessionId: tabId)
        try await sessions.saveFile(sessionId: tabId)
        let bytes = try await sessions.readPdfBytes(sessionId: tabId)
        // Saving over a file whose tab was just closed: that close's teardown
        // still holds the old bytes and would rename them over this write.
        await awaitTeardowns(ofDocumentAt: destinationURL.path)
        try await Task.detached {
            try bytes.write(to: destinationURL, options: .atomic)
        }.value

        // A read-only, unstamped source resolves to a stable byte-hash fallback
        // rather than a persisted /VellumDocId. Its Save As copy *is* writable,
        // so stamp that fallback into the destination before reopening it. This
        // keeps its conversation/scratchpad identity continuous instead of
        // assigning a fresh id after the source becomes writable by copying.
        //
        // Both calls are a full synchronous read + parse (+ atomic rewrite) of
        // the copy, so they run off the main actor — on it they blocked the UI
        // for the whole cost of the file, which is seconds on a large PDF.
        let destinationPath = destinationURL.path
        try await Task.detached(priority: .userInitiated) {
            if PdfMetadata.documentId(atPath: destinationPath) == nil {
                try PdfMetadata.stampDocumentId(atPath: destinationPath, id: preservedDocumentId)
            }
        }.value

        try await sessions.closeFile(sessionId: tabId)
        let rebound: DocumentInfo
        do {
            rebound = try await sessions.openFile(path: destinationURL.path, sessionId: tabId)
        } catch let reopenError {
            do {
                // The original file is untouched, and a successful rollback
                // restores the exact live tab rather than stranding it.
                let restored = try await sessions.openFile(path: sourceURL.path, sessionId: tabId)
                updateTab(tabId) { $0.document = restored }
                if activeTabId == tabId {
                    document = restored
                }
            } catch let rollbackError {
                // There is no longer a backend for this tab. Remove it rather
                // than showing a document whose actions will all fail; the
                // untouched original remains available to reopen from Recents.
                await closeTab(tabId)
                let terminalError = SessionServiceError.io(
                    "Save As wrote the copy but could not reopen it (\(reopenError.localizedDescription)) or restore the original (\(rollbackError.localizedDescription)). The tab was closed; reopen the original file to continue."
                )
                // `closeTab` may leave this pane on Home. Keep the terminal
                // action error on the store so WindowChrome can present it
                // there as well as above an open document.
                error = terminalError.localizedDescription
                throw terminalError
            }
            throw reopenError
        }

        // Retargeting keeps the tab live (issue #52 residency): its host stays
        // mounted and `isActive` never changes, so the viewer would go on
        // showing the document it parsed from the old location — and the copy's
        // bytes differ from the source's anyway once /VellumDocId is stamped
        // into it. Invalidate the runtime's parsed document so the mounted
        // viewer re-reads the new file.
        workspace?.existingLiveTabRuntime(for: tabId)?.invalidateLoadedPdf()
        updateTab(tabId) { $0.document = rebound }
        if activeTabId == tabId {
            document = rebound
        }
        RecentFilesService.record(rebound)
        workspace?.scheduleSave()
        return rebound
    }

    private static func sameFile(sourceURL: URL, destinationURL: URL) -> Bool {
        let source = sourceURL.standardizedFileURL
        let destination = destinationURL.standardizedFileURL
        guard source != destination else { return true }
        let sourceIdentifier = try? source.resourceValues(
            forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        let destinationIdentifier = try? destination.resourceValues(
            forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
        guard let sourceIdentifier = sourceIdentifier as? NSObject,
              let destinationIdentifier = destinationIdentifier as? NSObject else {
            return false
        }
        return sourceIdentifier.isEqual(destinationIdentifier)
    }

    // MARK: - Closing / switching tabs

    /// Await every close still finishing its metadata write, text flush, and
    /// session close. `applicationShouldTerminate` drains this so quitting right
    /// after closing a tab still persists that tab's reading position.
    func awaitPendingTabTeardowns() async {
        await teardowns.awaitAll()
    }

    /// Await any pending teardown that still holds the file at `path` — in ANY
    /// pane, not just this one. See `TabTeardownRegistry` for why the registry
    /// is workspace-owned.
    private func awaitTeardowns(ofDocumentAt path: String) async {
        await teardowns.awaitTeardowns(ofDocumentAt: path)
    }

    func closeFile() async {
        if let activeTabId {
            await closeTab(activeTabId)
        }
    }

    /// Close a tab and tear its backend session down.
    ///
    /// The tab leaves `tabs` — and therefore the tab strip — BEFORE any of the
    /// teardown work runs. That work is a `last_page` metadata write, which is a
    /// full read + parse + serialize + atomic rewrite of the PDF on the IO actor
    /// (~15s on a large document), plus a page-text flush. Awaiting it first
    /// meant the tab sat visibly in the strip for that whole time after the user
    /// clicked ×, so closing looked broken. Ordering WITHIN the teardown is
    /// unchanged and still matters: metadata (which changes the file's
    /// validation hash) → text flush (re-keys the cache to the bytes that will
    /// reopen) → session close → drop the runtime.
    func closeTab(_ tabId: String) async {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closingTab = tabs[closingIndex]
        // Start tabs carry no backend session — skip the metadata/close round
        // trips that would otherwise fire against a nonexistent session id.
        if let closingDocument = closingTab.document {
            let lastPage = String(closingTab.currentPage)
            // Resolved now: the runtime is dropped from the workspace at the end
            // of the teardown, and holding it here keeps it alive until its
            // pending text has been flushed.
            let runtime = workspace?.existingLiveTabRuntime(for: tabId)
            let sessions = self.sessions
            let workspace = self.workspace
            // ⌘Q immediately after a close must not lose the reading position:
            // the tab is already gone from `tabs`, so the quit path's per-tab
            // metadata loop no longer covers it. The task registers itself in
            // the workspace-wide teardown registry, which quit drains, and
            // records its document path so an immediate reopen or overwrite of
            // the same file — from any pane — waits for it. The registry (not
            // `self`) is captured for the cleanup: closing a split pane's last
            // tab collapses the pane and drops this store, and the entry must
            // outlive it.
            let teardowns = self.teardowns
            teardowns.register(
                tabId: tabId,
                documentPath: closingDocument.pdfPath,
                task: Task { [weak workspace] in
                    try? await sessions.setDocumentMetadata(
                        sessionId: tabId, key: "last_page", value: lastPage)
                    await runtime?.flushPdfText()
                    try? await sessions.closeFile(sessionId: tabId)
                    workspace?.removeLiveTabRuntime(for: tabId)
                    teardowns.finish(tabId: tabId)
                })
        } else {
            workspace?.removeLiveTabRuntime(for: tabId)
        }

        var remaining = tabs
        remaining.removeAll { $0.id == tabId }
        if activeTabId != tabId {
            tabs = remaining
            workspace?.scheduleSave()
            return
        }
        tabs = remaining
        if remaining.isEmpty {
            applyEmptyActiveState()
            // Closing a pane's last tab collapses the pane when the window is
            // split; a lone pane stays open on the Welcome screen.
            workspace?.paneDidEmpty(self)
        } else {
            let next = remaining[min(closingIndex, remaining.count - 1)]
            applyActiveState(from: next)
        }
        workspace?.scheduleSave()
    }

    /// Close every tab except `tabId`. Keeping this operation in the store makes
    /// the tab-strip context menu and any future native command share the same
    /// backend-session cleanup semantics as an ordinary close.
    func closeOtherTabs(keeping tabId: String) async {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        let ids = tabs.map(\.id).filter { $0 != tabId }
        for id in ids {
            await closeTab(id)
        }
        activateTab(tabId)
    }

    /// Close tabs after `tabId` in visual order.
    func closeTabsToRight(of tabId: String) async {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }),
              index + 1 < tabs.count else { return }
        let ids = tabs[(index + 1)...].map(\.id)
        for id in ids.reversed() {
            await closeTab(id)
        }
    }

    /// Open a second live session for a tab, preserving its stable viewport.
    /// Unlike the normal open path this deliberately does not deduplicate by
    /// location: Duplicate means two independently navigable workspaces.
    func duplicateTab(_ tabId: String) async {
        guard let sourceIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let source = tabs[sourceIndex]
        guard let sourceDocument = source.document else {
            newStartTab()
            return
        }
        // PDF mutations are serialized by a per-session IO actor, not a
        // per-path actor. Two live sessions for the same file could therefore
        // overwrite each other's annotation writes. Web sidecar mutations have
        // a per-path lock, so duplicate live webpage sessions are safe.
        guard sourceDocument.kind == .web else { return }

        let generation = beginOpen()
        defer { endOpen(generation) }
        let sessionId = UUID().uuidString.lowercased()
        do {
            // Web only, per the guard above.
            var opened = try await sessions.openWebDocument(
                url: sourceDocument.pdfPath, sessionId: sessionId)
            // Keep the title currently visible in the source tab. Web titles in
            // particular may have been learned after the initial open.
            opened.title = sourceDocument.title ?? opened.title
            // Opening suspends this main-actor method. If the user closed the
            // source tab while its duplicate was loading, do not resurrect it
            // as an unexpected new tab; release the just-opened session.
            guard let currentSourceIndex = tabs.firstIndex(where: { $0.id == tabId }) else {
                try? await sessions.closeFile(sessionId: sessionId)
                return
            }
            let duplicate = PdfTab(
                id: sessionId,
                document: opened,
                currentPage: source.currentPage,
                numPages: source.numPages,
                zoom: source.zoom,
                visiblePages: [],
                webVisibleRange: nil,
                webVisibleBookmarks: [],
                mode: .view
            )
            let insertion = min(currentSourceIndex + 1, tabs.count)
            tabs.insert(duplicate, at: insertion)
            applyActiveState(from: duplicate)
            workspace?.scheduleSave()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func activateTab(_ tabId: String) {
        guard activeTabId != tabId, let tab = tabs.first(where: { $0.id == tabId }) else { return }
        if let current = tabs.first(where: { $0.id == activeTabId }), current.document != nil {
            let sessionId = current.id
            let page = current.currentPage
            Task {
                try? await sessions.setDocumentMetadata(
                    sessionId: sessionId, key: "last_page", value: String(page))
            }
        }
        applyActiveState(from: tab)
    }

    // MARK: - Start tab (new-tab page)

    /// Open a fresh start tab — the lightweight new-tab page offering Recent,
    /// Open PDF…, and Open Webpage…. Backing ⌘T and the tab bar's `+`. A start
    /// tab holds no backend session; opening a document from it replaces the
    /// tab in place (see `adoptOpenedDocument`).
    func newStartTab() {
        let tab = PdfTab(
            id: "start-" + UUID().uuidString.lowercased(),
            document: nil,
            currentPage: 1,
            numPages: 0,
            zoom: 1.0,
            visiblePages: [],
            webVisibleRange: nil,
            webVisibleBookmarks: [],
            mode: .view
        )
        tabs.append(tab)
        applyActiveState(from: tab)
        workspace?.scheduleSave()
    }

    // MARK: - Moving tabs between panes (split screen)

    /// Remove a tab and hand back its `PdfTab` so another pane can adopt it.
    /// Unlike `closeTab`, the backend session is left open — the tab (and its
    /// session id) simply migrates to another pane's store, which shares the one
    /// SessionService. Returns nil if the tab isn't here.
    func detachTab(_ tabId: String) -> PdfTab? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let tab = tabs.remove(at: index)
        if activeTabId == tabId {
            if tabs.isEmpty {
                applyEmptyActiveState()
            } else {
                applyActiveState(from: tabs[min(index, tabs.count - 1)])
            }
        }
        workspace?.scheduleSave()
        return tab
    }

    /// Adopt a tab detached from another pane, appending it and activating it.
    func attachTab(_ tab: PdfTab) {
        tabs.append(tab)
        applyActiveState(from: tab)
        workspace?.scheduleSave()
    }

    /// Rebuild this pane's tabs from persisted descriptors (launch restore).
    /// This deliberately bypasses the regular open path's location
    /// deduplication: two saved web tabs at the same URL are independent live
    /// sessions and must both survive a relaunch. Missing files are skipped;
    /// the saved active index is mapped to its successfully restored tab rather
    /// than used against the compacted `tabs` array.
    func restoreTabs(_ descriptors: [TabDescriptor], activeIndex: Int?) async {
        var restoredTabIds: [Int: String] = [:]

        for (descriptorIndex, descriptor) in descriptors.enumerated() {
            guard let savedDocument = descriptor.document else { continue }
            let sessionId = UUID().uuidString.lowercased()
            do {
                var opened: DocumentInfo
                if savedDocument.kind == .web {
                    if savedDocument.pdfPath.lowercased().hasSuffix(".vellumweb") {
                        opened = try await sessions.openVellumwebFile(
                            path: savedDocument.pdfPath, sessionId: sessionId)
                    } else {
                        opened = try await sessions.openWebDocument(
                            url: savedDocument.pdfPath, sessionId: sessionId)
                    }
                } else {
                    opened = try await sessions.openFile(path: savedDocument.pdfPath, sessionId: sessionId)
                }
                // Preserve a title learned by the prior web session until the
                // re-opened page reports a newer document title.
                opened.title = savedDocument.title ?? opened.title
                RecentFilesService.record(opened)
                let restoredMode: InteractionMode = descriptor.mode == .snapshotRegion ? .view : descriptor.mode
                let tab = PdfTab(
                    id: sessionId,
                    document: opened,
                    currentPage: descriptor.currentPage,
                    numPages: opened.pageCount ?? 0,
                    zoom: descriptor.zoom,
                    visiblePages: [],
                    webVisibleRange: nil,
                    webVisibleBookmarks: [],
                    mode: restoredMode)
                tabs.append(tab)
                restoredTabIds[descriptorIndex] = sessionId
            } catch {
                // One unavailable document must not prevent the rest of the
                // workspace from restoring. The reconciled tree is saved by
                // WorkspaceStore after all panes have finished.
                continue
            }
        }

        if let activeTabId = activeIndex.flatMap({ restoredTabIds[$0] })
            ?? tabs.last?.id,
           let activeTab = tabs.first(where: { $0.id == activeTabId }) {
            applyActiveState(from: activeTab)
        }
    }

    /// Cycle the active tab by `delta`, wrapping at both ends. Backs the
    /// ⌘⇧[ / ⌘⇧] previous/next-tab shortcuts across any mix of tab types.
    func cycleTab(_ delta: Int) {
        guard tabs.count > 1, let activeTabId,
              let index = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        let count = tabs.count
        let next = ((index + delta) % count + count) % count
        activateTab(tabs[next].id)
    }

    // MARK: - Viewport

    func setCurrentPage(_ page: Int) {
        guard currentPage != page else { return }
        currentPage = page
        updateActiveTab { $0.currentPage = page }
    }

    func setNumPages(_ num: Int) {
        numPages = num
        updateActiveTab { $0.numPages = num }
        if let activeTabId {
            Task {
                try? await sessions.setDocumentMetadata(
                    sessionId: activeTabId, key: "page_count", value: String(num))
            }
        }
    }

    func setZoom(_ zoom: Double) {
        let next = min(Self.maxZoom, max(Self.minZoom, zoom))
        self.zoom = next
        updateActiveTab { $0.zoom = next }
    }

    func zoomIn() {
        let next = zoom + Self.zoomStep
        if let zoomToHandler {
            zoomToHandler(next)
        } else {
            setZoom(next)
        }
    }

    func zoomOut() {
        let next = zoom - Self.zoomStep
        if let zoomToHandler {
            zoomToHandler(next)
        } else {
            setZoom(next)
        }
    }

    /// Reset zoom to 100%, anchored on the viewport center when a PDF viewer
    /// has registered its handler (mirrors the toolbar's percentage button).
    func resetZoom() {
        if let zoomToHandler {
            zoomToHandler(1)
        } else {
            setZoom(1)
        }
    }

    // MARK: - Find

    /// Reveal the find bar (⌘F). No-op without a document.
    func showFind() {
        guard document != nil else { return }
        findVisible = true
        updateActiveTab { $0.findVisible = true }
    }

    /// Dismiss the find bar (Escape / close), clearing the viewer highlights.
    func hideFind() {
        guard findVisible else { return }
        findVisible = false
        updateActiveTab {
            $0.findVisible = false
            $0.findMatchCount = 0
            $0.findCurrentMatch = 0
        }
        findMatchCount = 0
        findCurrentMatch = 0
        findClearHandler?()
    }

    /// Run a query. An empty query clears highlights but keeps the bar open.
    func performFind(_ query: String) {
        guard document != nil else { return }
        findQuery = query
        updateActiveTab { $0.findQuery = query }
        if query.isEmpty {
            findMatchCount = 0
            findCurrentMatch = 0
            findClearHandler?()
            return
        }
        findQueryHandler?(query)
    }

    func findNext() { findStepHandler?(1) }
    func findPrev() { findStepHandler?(-1) }

    /// Called by the active viewer with the outcome of a query / step.
    func setFindResults(count: Int, current: Int) {
        findMatchCount = count
        findCurrentMatch = current
        updateActiveTab {
            $0.findMatchCount = count
            $0.findCurrentMatch = current
        }
    }

    // MARK: - Print

    /// Print the active document via the viewer's registered print operation.
    func printDocument() {
        guard document != nil else { return }
        printHandler?()
    }

    private func resetFindState() {
        findVisible = false
        findQuery = ""
        findMatchCount = 0
        findCurrentMatch = 0
    }

    /// Read-only tab lookup used by persistent viewer hosts. A host may finish
    /// preparing while another tab is active, so it must validate its own tab
    /// identity without consulting the window-global active projection.
    func tab(id: String) -> PdfTab? {
        tabs.first { $0.id == id }
    }

    func containsTab(id: String) -> Bool {
        tabs.contains { $0.id == id }
    }

    func setVisiblePages(_ pages: [Int]) {
        guard pages != visiblePages else { return }
        visiblePages = pages
        updateActiveTab { $0.visiblePages = pages }
    }

    func setWebVisibleRange(_ range: WebVisibleRange?) {
        guard range != webVisibleRange else { return }
        webVisibleRange = range
        updateActiveTab { $0.webVisibleRange = range }
    }

    func setWebVisibleBookmarks(_ ids: [String]) {
        guard ids != webVisibleBookmarks else { return }
        webVisibleBookmarks = ids
        updateActiveTab { $0.webVisibleBookmarks = ids }
    }

    func goToPage(_ page: Int) {
        // Before the document reports its page count, clamping would produce
        // page 0 — ignore navigation until pages exist.
        guard numPages >= 1 else { return }
        let clamped = min(numPages, max(1, page))
        setCurrentPage(clamped)
        scrollToPageHandler?(clamped)
    }

    func setMode(_ mode: InteractionMode) {
        self.mode = mode
        switch mode {
        case .snapshotRegion:
            // `beginRegionCapture(target:)` records the destination first. Do
            // not persist this transient interaction across relaunch.
            break
        case .note:
            regionCaptureTarget = .ai
            updateActiveTab {
                $0.mode = .note
                $0.regionCaptureTarget = nil
            }
        case .view:
            pendingNoteContent = nil
            regionCaptureTarget = .ai
            updateActiveTab {
                $0.mode = .view
                $0.pendingNoteContent = nil
                $0.regionCaptureTarget = nil
            }
        }
    }

    /// Arm drag-to-crop region capture, recording which panel asked for it so
    /// the viewer overlay routes the resulting snapshot to the right store.
    func beginRegionCapture(target: RegionCaptureTarget) {
        regionCaptureTarget = target
        pendingNoteContent = nil
        mode = .snapshotRegion
        updateActiveTab {
            // A region capture replaces an armed note placement. Both pieces
            // of state belong to the tab, so its indicator remains accurate
            // while another tab is foregrounded.
            $0.mode = .view
            $0.pendingNoteContent = nil
            $0.regionCaptureTarget = target
        }
    }

    /// Enter note-placement mode carrying an AI reply: the next click on the
    /// page drops a pre-filled sticky note instead of an empty one. Used by the
    /// AI panel's "Add as note" action.
    func beginNoteWithContent(_ content: String) {
        setMode(.note)
        pendingNoteContent = content
        updateActiveTab { $0.pendingNoteContent = content }
    }

    /// Complete a note placement only when its originating session remains the
    /// active note interaction. A delayed save from tab A must never dismiss a
    /// note interaction the user started after switching to tab B.
    func finishNotePlacement(forSessionId sessionId: String) {
        guard activeTabId == sessionId, mode == .note else { return }
        setMode(.view)
    }

    /// Capture the active tab's crop destination before returning it to view
    /// mode, which deliberately clears the transient destination.
    func finishRegionCapture() -> RegionCaptureTarget {
        let target = regionCaptureTarget
        setMode(.view)
        return target
    }

    /// Consumed by the viewer when it places a note; nil once used.
    func consumePendingNoteContent() -> String? {
        let content = pendingNoteContent
        pendingNoteContent = nil
        updateActiveTab { $0.pendingNoteContent = nil }
        return content
    }

    // MARK: - Internals

    private func openOneFile(path: String) async throws {
        // A `.vellum` bundle unpacks into a document (written where the user
        // chooses) + its sidecar; then that document opens through the normal
        // path. Everything else is opened directly.
        if path.lowercased().hasSuffix(".vellum") {
            guard let documentPath = try await importVellumBundle(bundlePath: path) else { return }
            try await openDocumentFile(path: documentPath)
            return
        }
        try await openDocumentFile(path: path)
    }

    private func openDocumentFile(path: String) async throws {
        // Close-then-immediately-reopen: a teardown from a preceding close may
        // still be rewriting this exact file. Opening before it lands would
        // restore a stale reading position and lose any write the new session
        // makes before the teardown's atomic rename.
        await awaitTeardowns(ofDocumentAt: path)
        let sessionId = UUID().uuidString.lowercased()
        // .vellumweb archives import as web documents; everything else is a PDF.
        let isArchive = path.lowercased().hasSuffix(".vellumweb")
        let doc: DocumentInfo
        if isArchive {
            doc = try await sessions.openVellumwebFile(path: path, sessionId: sessionId)
        } else {
            doc = try await sessions.openFile(path: path, sessionId: sessionId)
        }
        await adoptOpenedDocument(doc, sessionId: sessionId)
        if isArchive {
            // The import may have merged annotations into a tab that is already
            // open and active, in which case no document change fires — nudge
            // the annotation store to reload.
            NotificationCenter.default.post(name: .vellumAnnotationsUpdated, object: nil)
        }
    }

    /// Import a `.vellum` bundle: verify it, let the user choose where the
    /// document file lands, then hand off to the panel-free core. Returns nil if
    /// the user cancels the save panel. The read + write + install work lives in
    /// `importVellumBundleCore` so it is unit-testable without the panels.
    private func importVellumBundle(bundlePath: String) async throws -> String? {
        let imported = try VellumBundle.read(at: URL(fileURLWithPath: bundlePath))
        let manifest = imported.manifest
        let kind: DocumentKind = manifest.kind == "web" ? .web : .pdf

        // Bring the app forward before the modal. When the import is triggered by
        // `open`/Finder/an Apple event during launch, the app may not yet be
        // active, and an app-modal panel presented then never comes to front —
        // the process wedges and the open event times out (-1712) with no panel
        // shown. Activating first, then runModal on the main actor, matches the
        // working export flows (exportVellumweb / exportWithNotes).
        NSApplication.shared.activate(ignoringOtherApps: true)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = manifest.documentFile
        if kind == .web, let archive = UTType(filenameExtension: "vellumweb") {
            panel.allowedContentTypes = [archive]
        } else if kind == .pdf {
            panel.allowedContentTypes = [.pdf]
        }
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }

        // The core writes the bundle's document bytes to `destination` before
        // `openDocumentFile` (and its own teardown guard) ever runs. If the
        // user picked a file whose tab was just closed, wait out that close's
        // teardown here so its rename cannot clobber the imported bytes.
        await awaitTeardowns(ofDocumentAt: destination.path)

        let result = try await Self.importVellumBundleCore(imported, to: destination) { title in
            let alert = NSAlert()
            alert.messageText = "Notes already exist for \(title)"
            alert.informativeText =
                "This document already has notes on this Mac. Keep the notes you have, "
                + "or replace them with the imported notes? Your highlights and reading "
                + "position are not affected either way."
            alert.addButton(withTitle: "Keep My Notes")      // default
            alert.addButton(withTitle: "Use Imported Notes")
            return alert.runModal() == .alertFirstButtonReturn ? .keepLocal : .useImported
        }

        // Never a silent success with broken image refs (STAGE F2 #5): name the
        // attachments that could not be installed.
        if !result.failedAttachments.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Some images couldn't be imported"
            alert.informativeText =
                "These attachments couldn't be saved, so their references may appear "
                + "broken in the imported notes:\n" + result.failedAttachments.joined(separator: "\n")
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        return result.path
    }

    /// The panel-free import core (STAGE F2 #2): everything an import does EXCEPT
    /// choosing the destination. Writes the document bytes ATOMICALLY (temp
    /// sibling + rename(2), never a pre-delete — a crash mid-replace must not lose
    /// the file that was already there, #3), stamps an unstamped PDF with the
    /// manifest id, resolves the install key, installs the sidecar under the
    /// merge rules (§5), drops the AI memory cache + broadcasts a reload so an
    /// already-open tab picks up the merge instead of clobbering it (#4), stamps
    /// meta.json, and returns the written path plus any attachments that could
    /// not be installed (#5). Static + panel-free so tests drive it directly.
    @MainActor
    @discardableResult
    static func importVellumBundleCore(
        _ imported: VellumBundle.Imported,
        to destination: URL,
        resolveScratchpadConflict resolveConflict: (_ title: String) -> VellumBundle.ScratchpadDecision
    ) async throws -> (path: String, failedAttachments: [String]) {
        let manifest = imported.manifest
        let kind: DocumentKind = manifest.kind == "web" ? .web : .pdf

        // Atomic write: stage the bytes in a temp sibling, fsync-free rename over
        // the destination. Replacing an existing file never deletes it first, so
        // a failed import leaves the prior file intact.
        let parent = destination.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io(
                "Failed to prepare the import destination: \(error.localizedDescription)")
        }
        let tmp = parent.appendingPathComponent(
            ".\(destination.lastPathComponent).import-\(UUID().uuidString.lowercased())")
        do {
            try imported.documentData.write(to: tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io(
                "Failed to write the imported document: \(error.localizedDescription)")
        }
        guard rename(tmp.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io(
                "Failed to write the imported document: could not replace the destination")
        }

        // An imported PDF that carries no /VellumDocId would, on reopen, resolve
        // to sha256(path) and then be stamped a FRESH UUID — orphaning the
        // sidecar we're about to install under manifest.docId. Stamp
        // manifest.docId into the just-written file now so its reopen key matches
        // (an import is user investment, and the file was just written so it is
        // writable). Best-effort: a stamp failure falls back to the prior
        // behavior — installing under manifest.docId — never failing the import.
        // Web bundles are never stamped (their identity is the URL hash).
        //
        // The stamp and the key resolution below are each a full synchronous
        // read + parse of the just-written PDF (the stamp also rewrites it), so
        // they share ONE hop off the main actor: on it they blocked the UI for
        // the file's whole cost right after the save panel closed. Nothing here
        // touches main-actor state, and no PDFKit/CGPDF value escapes the hop.
        //
        // Key resolution: for a PDF, prefer the written file's own /VellumDocId
        // stamp when it differs from the manifest (the file is authoritative).
        // For web, the identity is the URL hash carried in the manifest.
        let key: String
        if kind == .pdf {
            let destinationPath = destination.path
            let manifestId = manifest.docId
            key = await Task.detached(priority: .userInitiated) {
                if PdfMetadata.documentId(atPath: destinationPath) == nil {
                    try? PdfMetadata.stampDocumentId(atPath: destinationPath, id: manifestId)
                }
                if let raw = try? PdfDocumentLoader.loadRaw(path: destinationPath),
                   let stamped = PdfMetadata.documentId(raw) {
                    return stamped
                }
                return manifestId
            }.value
        } else {
            key = manifest.docId
        }

        let failedAttachments = try VellumBundle.installSidecar(
            imported, forKey: key, resolveScratchpadConflict: resolveConflict)

        // The merge just rewrote conversations.json on disk. The AI memory cache
        // is authoritative (#48 write-behind), so drop this key's entry now — the
        // tab about to open (and any pane already showing this doc, via the
        // broadcast) then re-reads the merge instead of flushing pre-import state
        // back over it (#4).
        AiPersistence.invalidateCachedConversation(forKey: key)
        NotificationCenter.default.post(
            name: .vellumDocumentSidecarImported, object: nil, userInfo: ["key": key])

        // Stamp meta.json with the new location (PDFs — web records are managed
        // by the WebLibrary sidecar the normal open path writes).
        if kind == .pdf {
            let info = DocumentInfo(
                kind: .pdf, pdfPath: destination.path, title: manifest.title,
                pageCount: nil, lastPage: nil, docId: key)
            try? DocumentDataStore.touch(document: info)
        }
        return (destination.path, failedAttachments)
    }

    private func adoptOpenedDocument(_ doc: DocumentInfo, sessionId: String) async {
        RecentFilesService.record(doc)
        // Was the active tab a start tab? If so, opening a document from it
        // replaces that tab in place rather than appending a new one. Track it
        // by id, not index — `tabs` can be mutated by other main-actor work
        // while we're suspended on the backend call below.
        let activeStartId: String? = activeTabId.flatMap { id in
            tabs.first(where: { $0.id == id && $0.document == nil })?.id
        }
        if let existing = tabs.first(where: { $0.document?.pdfPath == doc.pdfPath }) {
            try? await sessions.closeFile(sessionId: sessionId)
            // Discard the start tab we opened from before switching to the
            // already-open document (never remove the target itself).
            if let activeStartId, activeStartId != existing.id {
                tabs.removeAll { $0.id == activeStartId }
            }
            activateTab(existing.id)
            return
        }
        // Reveal the side panel for a genuinely new document. Reopening a
        // document that is already tabbed above is navigation, not a fresh
        // open, and must preserve an explicit user choice to hide the panel.
        workspace?.sidebarOpen = true
        let tab = PdfTab(
            id: sessionId,
            document: doc,
            currentPage: doc.lastPage ?? 1,
            numPages: doc.pageCount ?? 0,
            zoom: 1.0,
            visiblePages: [],
            webVisibleRange: nil,
            webVisibleBookmarks: [],
            mode: .view
        )
        if let activeStartId, let startIndex = tabs.firstIndex(where: { $0.id == activeStartId }) {
            tabs[startIndex] = tab
        } else {
            tabs.append(tab)
        }
        applyActiveState(from: tab)
        workspace?.scheduleSave()
    }

    private func applyActiveState(from tab: PdfTab) {
        // Note-placement state travels with the tab. Find state does too now
        // (#71 era), so the incoming tab's query is restored below rather than
        // reset here.
        pendingNoteContent = tab.pendingNoteContent
        // Pin the incoming tab (never evictable while it is on screen) and
        // restart the outgoing tab's idle countdown from now — it was in use
        // until this instant, so its idle clock starts here, not at activation.
        workspace?.paneDidActivateTab(self, tabId: tab.id)
        activeTabId = tab.id
        document = tab.document
        currentPage = tab.currentPage
        numPages = tab.numPages
        zoom = tab.zoom
        visiblePages = tab.visiblePages
        webVisibleRange = tab.webVisibleRange
        webVisibleBookmarks = tab.webVisibleBookmarks
        regionCaptureTarget = tab.regionCaptureTarget ?? .ai
        mode = tab.regionCaptureTarget == nil ? tab.mode : .snapshotRegion
        findVisible = tab.findVisible
        findQuery = tab.findQuery
        findMatchCount = tab.findMatchCount
        findCurrentMatch = tab.findCurrentMatch
    }

    private func applyEmptyActiveState() {
        resetFindState()
        pendingNoteContent = nil
        // No tab on screen here, so this pane pins nothing.
        workspace?.paneDidActivateTab(self, tabId: nil)
        activeTabId = nil
        document = nil
        currentPage = 1
        numPages = 0
        zoom = 1.0
        visiblePages = []
        webVisibleRange = nil
        webVisibleBookmarks = []
        regionCaptureTarget = .ai
        mode = .view
    }

    private func updateActiveTab(_ mutate: (inout PdfTab) -> Void) {
        guard let activeTabId else { return }
        updateTab(activeTabId, mutate)
    }

    private func updateTab(_ tabId: String, _ mutate: (inout PdfTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        var tab = tabs[index]
        mutate(&tab)
        tabs[index] = tab
    }
}
