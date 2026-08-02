import Foundation
import Observation
import PDFKit

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

    /// Await every pending teardown. The scene-background flush drains this so
    /// suspending right after closing a tab still persists its reading
    /// position — including a tab whose close collapsed its pane. (macOS drains
    /// the same registry from `applicationShouldTerminate`; iOS has no quit, so
    /// `flushOnBackground` is the equivalent last chance.)
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
    // `LiveTabRuntime`. Keeping a second copy here would be actively harmful:
    // evicting a runtime under memory pressure would free the view but leave the
    // document alive in the LRU, so the memory the eviction existed to reclaim
    // would not actually come back. One owner, one lifetime.

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
    /// value when the user changes tabs mid-gesture. The enum itself is now
    /// top-level (`Models.swift`) because `PdfTab` carries it.
    private(set) var regionCaptureTarget: RegionCaptureTarget = .ai

    /// The window's workspace. One AppStore now backs one *pane*; app-global
    /// shell state (inspector open/tab, sidebar text size, default highlight
    /// color) lives on WorkspaceStore. Weak to avoid a retain cycle — the
    /// workspace owns the pane which owns this store.
    weak var workspace: WorkspaceStore?

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

    func openFile(path: String) async {
        isLoading = true
        error = nil
        do {
            try await openOneFile(path: path)
            isLoading = false
        } catch {
            isLoading = false
            self.error = String(describing: error.localizedDescription)
        }
    }

    func openFiles(paths: [String]) async {
        guard !paths.isEmpty else { return }
        isLoading = true
        error = nil
        var errors: [String] = []
        for path in paths {
            do {
                try await openOneFile(path: path)
            } catch {
                errors.append("\(path): \(error.localizedDescription)")
            }
        }
        isLoading = false
        self.error = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    func openUrl(_ url: String) async {
        isLoading = true
        error = nil
        do {
            let sessionId = UUID().uuidString.lowercased()
            let doc = try await sessions.openWebDocument(url: url, sessionId: sessionId)
            await adoptOpenedDocument(doc, sessionId: sessionId)
            isLoading = false
        } catch {
            isLoading = false
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
    /// always stamped at open, so this never fires for them).
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

    // MARK: - Closing / switching tabs

    /// Await every close still finishing its metadata write, text flush, and
    /// session close. The scene-background flush drains this so suspending
    /// right after closing a tab still persists that tab's reading position.
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
    /// tapped ×, so closing looked broken.
    ///
    /// The teardown registers itself in the workspace-wide registry before it
    /// starts. The tab is already gone from `tabs`, so nothing else would await
    /// it: not the scene-background flush's per-tab loop, and not a reopen of
    /// the same file. The registry (not `self`) is captured for the cleanup —
    /// closing a split pane's last tab collapses the pane and drops this store,
    /// and the entry has to outlive it.
    func closeTab(_ tabId: String) async {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closingTab = tabs[closingIndex]

        // Backend teardown can involve metadata/file I/O. The tab has already
        // disappeared from the UI, so finish that work asynchronously instead
        // of making the close gesture look frozen (an iPad divergence — main
        // awaits it inline). Start tabs have no session.
        //
        // Ordering WITHIN the teardown matters and is main's: metadata (which
        // rewrites the PDF and therefore its validation hash) → text flush
        // (re-keys the page-text cache to the bytes that will reopen) → session
        // close → drop the runtime.
        //
        // ⚠ If the user reopens the same document before this task finishes,
        // `openFile` mints a FRESH session id, so `removeLiveTabRuntime` below
        // targets the old id only and cannot reach into the new tab. That is
        // safe today and would stop being safe the moment tab ids are reused.
        if let closingDocument = closingTab.document {
            let lastPage = String(closingTab.currentPage)
            // Resolved now: the runtime is dropped from the workspace at the end
            // of the teardown, and holding it here keeps it alive until its
            // pending text has been flushed.
            let runtime = workspace?.existingLiveTabRuntime(for: tabId)
            let sessions = self.sessions
            let workspace = self.workspace
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
            // A start tab has no session and nothing to flush: hand its (empty)
            // runtime back now rather than leaving it against the ceiling.
            workspace?.removeLiveTabRuntime(for: tabId)
        }

        var remaining = tabs
        remaining.removeAll { $0.id == tabId }
        if activeTabId != tabId {
            tabs = remaining
        } else {
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
        }
        workspace?.scheduleSave()
    }

    /// Close every tab except `tabId`. Keeping this operation in the store makes
    /// the tab-strip context menu and any future native command share the same
    /// backend-session cleanup semantics as an ordinary close — including the
    /// teardown registration `closeTab` performs, which these inherit for free.
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

        // Main brackets this in `beginOpen()`/`endOpen(_:)`, its open-watchdog
        // generation guard. The iPad store has no watchdog yet, so this uses the
        // same plain `isLoading` bracket every other open on this store uses.
        isLoading = true
        error = nil
        defer { isLoading = false }
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
    ///
    /// Start tabs (a nil `document`) are no longer restored — `WorkspaceStore`
    /// stopped persisting them, so a descriptor without a document is an old
    /// saved file and its `New Tab` placeholder is not worth resurrecting.
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
                    // Resolution order (an iPad divergence main has no need
                    // for): the saved bookmark first — it survives both a
                    // container-UUID change and a move/rename — then the path
                    // heal, then the raw saved path. The persisted path is
                    // absolute and rooted in the app's data container, whose
                    // UUID changes across reinstalls and OS updates, so without
                    // the heal a PDF tab silently drops on the next launch after
                    // an update while its sibling web tab survives, collapsing
                    // the split and orphaning the pad.
                    //
                    // Access only needs to stay open for the read that opens the
                    // file; PDFKit/CGPDF have finished parsing what they need by
                    // the time `openFile` returns.
                    var resolvedPath = savedDocument.pdfPath
                    var resolvedURL: URL?
                    var bookmarkNeedsRefresh = false
                    if let bookmarkData = savedDocument.bookmarkData,
                       let resolved = SecurityScopedBookmark.resolve(bookmarkData) {
                        resolvedPath = resolved.url.path
                        resolvedURL = resolved.url
                        bookmarkNeedsRefresh = resolved.isStale
                    } else {
                        resolvedPath = DocumentImport.resolveExistingPath(savedDocument.pdfPath)
                            ?? savedDocument.pdfPath
                    }
                    let accessStarted = resolvedURL?.startAccessingSecurityScopedResource() ?? false
                    defer { if accessStarted { resolvedURL?.stopAccessingSecurityScopedResource() } }
                    opened = try await sessions.openFile(path: resolvedPath, sessionId: sessionId)
                    opened.bookmarkData = bookmarkNeedsRefresh || savedDocument.bookmarkData == nil
                        ? SecurityScopedBookmark.make(forPath: resolvedPath)
                        : savedDocument.bookmarkData
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
    /// note interaction the user started after switching to tab B — reachable
    /// on iPad too now that several tabs are mounted at once.
    func finishNotePlacement(forSessionId sessionId: String) {
        guard activeTabId == sessionId, mode == .note else { return }
        setMode(.view)
    }

    /// Capture the active tab's crop destination before returning it to view
    /// mode, which deliberately clears the transient destination.
    @discardableResult
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

    /// Put an unplaced note draft back on the queue and re-arm placement, so
    /// the next tap on the page offers the same text again.
    ///
    /// Issue #92: the web viewer's placement tap only opens a composer — the
    /// note is not written until the user submits — so between those two steps
    /// the composer holds the *only* copy of a queued AI reply
    /// (`consumePendingNoteContent` already cleared the store). A stray tap, a
    /// page scroll, a misdirected link, or a tab switch all unmount that
    /// composer, and the reply used to go with it. The PDF viewer has no such
    /// window: it writes the note on the placement tap itself. Handing the
    /// draft back here closes the gap — a mis-tap now costs one more tap
    /// instead of the whole reply.
    ///
    /// Empty (or whitespace-only) drafts are dropped — a plain note-tool
    /// placement the user tapped away from has nothing worth preserving, and
    /// re-arming note mode for it would be friction with no payoff.
    ///
    /// Scoped to the originating tab rather than the active one: the dismissal
    /// may be the *reason* the tab is going away (switching tabs unmounts the
    /// composer), and note-placement state travels with the tab anyway, so the
    /// draft is waiting when the user comes back. A late message from a tab
    /// that has since been closed lands nowhere.
    func restorePendingNote(_ content: String, forSessionId sessionId: String) {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // While the tab is the one on screen this is exactly "arm placement
        // again", so it goes through the same door rather than restating it —
        // anything `setMode(.note)` grows later applies to restores too.
        guard activeTabId != sessionId else { return beginNoteWithContent(content) }
        // Otherwise write the tab record only; `applyActiveState` picks the
        // state up on the way back in.
        updateTab(sessionId) {
            $0.mode = .note
            $0.pendingNoteContent = content
            $0.regionCaptureTarget = nil
        }
    }

    // MARK: - Internals

    private func openOneFile(path: String) async throws {
        // A `.vellum` bundle unpacks into a document (written into the library)
        // + its sidecar; then that document opens through the normal path.
        // Everything else is opened directly.
        if path.lowercased().hasSuffix(".vellum") {
            guard let documentPath = try await importVellumBundle(bundlePath: path) else { return }
            #if os(iOS)
            // A bundle picked from Files is staged into its own tmp/ directory
            // (see DocumentImport.stagingDestination): it is a container, not a
            // document, so it must not linger.
            if path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
            #endif
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
        //
        // Anchored here rather than in `openOneFile` so it sees the *document*
        // path: a `.vellum` open arrives as a bundle container, and awaiting
        // teardowns on that path would guard a file no session ever held.
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

    // MARK: - `.vellum` import

    /// Phase 1 of an import: write the document bytes ATOMICALLY (temp sibling +
    /// rename(2), never a pre-delete), stamp an unstamped PDF with the manifest
    /// id, and resolve the storage key the sidecar will install under.
    /// Split out of `importVellumBundleCore` so iOS can await a merge prompt
    /// between the two halves — a UIAlertController can't be run modally the
    /// way `NSAlert.runModal()` can, so the codec's synchronous resolver has to
    /// be handed a decision that was already made.
    @MainActor
    static func writeImportedDocument(
        _ imported: VellumBundle.Imported, to destination: URL
    ) async throws -> String {
        let manifest = imported.manifest
        let kind: DocumentKind = manifest.kind == "web" ? .web : .pdf

        // Atomic write: stage the bytes in a temp sibling, rename over the
        // destination. Replacing an existing file never deletes it first, so a
        // failed import leaves the prior file intact.
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
        // the file's whole cost. Nothing here touches main-actor state, and no
        // PDFKit/CGPDF value escapes the hop.
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
        return key
    }

    /// Phase 2: install the sidecar under the merge rules, drop the AI memory
    /// cache, broadcast the reload, and stamp meta.json.
    @MainActor
    static func finishImportedBundle(
        _ imported: VellumBundle.Imported,
        to destination: URL,
        key: String,
        resolveScratchpadConflict resolveConflict: (_ title: String) -> VellumBundle.ScratchpadDecision
    ) throws -> (path: String, failedAttachments: [String]) {
        let failedAttachments = try VellumBundle.installSidecar(
            imported, forKey: key, resolveScratchpadConflict: resolveConflict)

        // The merge just rewrote conversations.json on disk. The AI memory cache
        // is authoritative (write-behind), so drop this key's entry now — the tab
        // about to open (and any pane already showing this doc, via the
        // broadcast) then re-reads the merge instead of flushing pre-import state
        // back over it.
        AiPersistence.invalidateCachedConversation(forKey: key)
        NotificationCenter.default.post(
            name: .vellumDocumentSidecarImported, object: nil, userInfo: ["key": key])

        // Stamp meta.json with the new location (PDFs — web records are managed
        // by the WebLibrary sidecar the normal open path writes).
        if imported.manifest.kind != "web" {
            let info = DocumentInfo(
                kind: .pdf, pdfPath: destination.path, title: imported.manifest.title,
                pageCount: nil, lastPage: nil, docId: key)
            try? DocumentDataStore.touch(document: info)
        }
        return (destination.path, failedAttachments)
    }

    /// The panel-free import core, in main's exact shape. Kept so the two-phase
    /// split above can be asserted against it and can never drift.
    @MainActor
    @discardableResult
    static func importVellumBundleCore(
        _ imported: VellumBundle.Imported,
        to destination: URL,
        resolveScratchpadConflict resolveConflict: (_ title: String) -> VellumBundle.ScratchpadDecision
    ) async throws -> (path: String, failedAttachments: [String]) {
        let key = try await writeImportedDocument(imported, to: destination)
        return try finishImportedBundle(
            imported, to: destination, key: key, resolveScratchpadConflict: resolveConflict)
    }

    #if os(iOS)
    /// Import a `.vellum` bundle: verify it, place the document in the app's
    /// library, then install the sidecar — pausing between the two for the merge
    /// prompt when the local note differs. Returns nil if the user cancels.
    ///
    /// macOS asks the user where the document lands (NSSavePanel). iOS has no
    /// save panel and the whole path layer expects writable in-container files,
    /// so the document lands in `DocumentImport.libraryDirectory` — the same
    /// place every picked PDF is copied to.
    private func importVellumBundle(bundlePath: String) async throws -> String? {
        do {
            return try await importVellumBundleShowingErrors(bundlePath: bundlePath)
        } catch {
            // `openFiles` only collects error strings into `AppStore.error`,
            // which the iPad shell never renders — so a bundle rejected for
            // failing its integrity check, carrying an unsafe entry path, or
            // being written by a newer Vellum would fail silently, which reads
            // as a broken app. Safe rejection has to be VISIBLE rejection.
            await BundleImportPrompts_iOS.importFailed(error.localizedDescription)
            throw error
        }
    }

    private func importVellumBundleShowingErrors(bundlePath: String) async throws -> String? {
        let imported = try VellumBundle.read(at: URL(fileURLWithPath: bundlePath))
        let destination = DocumentImport.bundleDestination(
            documentFile: imported.manifest.documentFile, docId: imported.manifest.docId)

        // Re-importing over a document whose tab was just closed: that tab's
        // teardown is a full read + atomic rewrite of this exact file, so a
        // rename(2) landing after ours would put PRE-import bytes back. The
        // open path guards itself the same way; the import writes first, so it
        // has to guard too.
        await awaitTeardowns(ofDocumentAt: destination.path)

        let key = try await Self.writeImportedDocument(imported, to: destination)

        // Resolve the scratchpad conflict BEFORE installSidecar, because the
        // codec's resolver is synchronous (NSAlert.runModal on the Mac) and an
        // iOS alert can only be awaited.
        var decision = VellumBundle.ScratchpadDecision.keepLocal
        if let incoming = imported.scratchpad, !incoming.isEmpty,
           DocumentDataStore.scratchpadExists(forKey: key),
           DocumentDataStore.loadScratchpad(forKey: key) != incoming {
            decision = await BundleImportPrompts_iOS.scratchpadConflict(
                title: imported.manifest.title ?? "this document")
        }

        let result = try Self.finishImportedBundle(
            imported, to: destination, key: key) { _ in decision }

        // Never a silent success with broken image refs: name the attachments
        // that could not be installed.
        if !result.failedAttachments.isEmpty {
            await BundleImportPrompts_iOS.failedAttachments(result.failedAttachments)
        }
        return result.path
    }
    #endif

    private func adoptOpenedDocument(_ doc: DocumentInfo, sessionId: String) async {
        var doc = doc
        // Mint a security-scoped bookmark right now, while the just-completed
        // open guarantees read access. Web docs have no filesystem path.
        if doc.kind == .pdf {
            doc.bookmarkData = SecurityScopedBookmark.make(forPath: doc.pdfPath)
        }
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
        // Note-placement state travels with the tab. Find state does too now,
        // so the incoming tab's query is restored below rather than reset here.
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
