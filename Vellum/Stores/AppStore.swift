import Foundation
import Observation
import PDFKit

// Tab + viewport state — port of src/stores/pdf-store.ts plus the shell-level
// sidebar state from App.tsx. Action semantics mirror the zustand store 1:1.

@MainActor
@Observable
final class AppStore {
    static let minZoom: Double = 0.25
    static let maxZoom: Double = 4.0
    static let zoomStep: Double = 0.1

    let sessions: SessionService

    // MARK: - Prepared-PDF cache
    //
    // Switching tabs tears down and rebuilds the viewer (`.id(activeTabId)`), so
    // without a cache every switch re-reads + re-parses + re-strips the whole PDF
    // (now off-main, but still a visible delay for large docs). Cache the display-
    // ready PDFDocument per tab so switching back is instant. A stripped display
    // doc stays valid across annotation edits (annotations render from overlays,
    // page content is unchanged), so no invalidation is needed beyond close/LRU.
    private static let maxPreparedCache = 3
    @ObservationIgnored private var preparedPdfCache: [(tabId: String, doc: PDFDocument)] = []

    func cachedPreparedPdf(tabId: String) -> PDFDocument? {
        guard let index = preparedPdfCache.firstIndex(where: { $0.tabId == tabId }) else { return nil }
        // Touch: move to most-recently-used.
        let entry = preparedPdfCache.remove(at: index)
        preparedPdfCache.append(entry)
        return entry.doc
    }

    func storePreparedPdf(_ doc: PDFDocument, tabId: String) {
        preparedPdfCache.removeAll { $0.tabId == tabId }
        preparedPdfCache.append((tabId, doc))
        if preparedPdfCache.count > Self.maxPreparedCache {
            preparedPdfCache.removeFirst()
        }
    }

    func evictPreparedPdf(tabId: String) {
        preparedPdfCache.removeAll { $0.tabId == tabId }
    }

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

    // Find bar (⌘F). `findVisible` drives the slim bar under the toolbar; the
    // counts are reported back by whichever viewer is active.
    var findVisible = false
    private(set) var findMatchCount = 0
    /// 1-based index of the current match; 0 when there are no matches.
    private(set) var findCurrentMatch = 0

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

    init(sessions: SessionService) {
        self.sessions = sessions
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

    // MARK: - Closing / switching tabs

    func closeFile() async {
        if let activeTabId {
            await closeTab(activeTabId)
        }
    }

    func closeTab(_ tabId: String) async {
        guard let closingIndex = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let closingTab = tabs[closingIndex]
        evictPreparedPdf(tabId: tabId)
        // Start tabs carry no backend session — skip the metadata/close round
        // trips that would otherwise fire against a nonexistent session id.
        if closingTab.document != nil {
            try? await sessions.setDocumentMetadata(
                sessionId: closingTab.id, key: "last_page", value: String(closingTab.currentPage))
            try? await sessions.closeFile(sessionId: closingTab.id)
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
    /// Opens each document with a fresh session; missing files are skipped.
    /// Applies each tab's saved page/zoom/mode, then activates the saved tab.
    func restoreTabs(_ descriptors: [TabDescriptor], activeIndex: Int?) async {
        for descriptor in descriptors {
            guard let doc = descriptor.document else {
                newStartTab()
                continue
            }
            let before = tabs.count
            if doc.kind == .web {
                await openUrl(doc.pdfPath)
            } else {
                await openFiles(paths: [doc.pdfPath])
            }
            // Apply the saved viewport only if a new tab actually opened.
            if tabs.count > before {
                setZoom(descriptor.zoom)
                setCurrentPage(descriptor.currentPage)
                setMode(descriptor.mode)
            }
        }
        if let activeIndex, tabs.indices.contains(activeIndex) {
            activateTab(tabs[activeIndex].id)
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
    }

    /// Dismiss the find bar (Escape / close), clearing the viewer highlights.
    func hideFind() {
        guard findVisible else { return }
        findVisible = false
        findMatchCount = 0
        findCurrentMatch = 0
        findClearHandler?()
    }

    /// Run a query. An empty query clears highlights but keeps the bar open.
    func performFind(_ query: String) {
        guard document != nil else { return }
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
    }

    // MARK: - Print

    /// Print the active document via the viewer's registered print operation.
    func printDocument() {
        guard document != nil else { return }
        printHandler?()
    }

    private func resetFindState() {
        findVisible = false
        findMatchCount = 0
        findCurrentMatch = 0
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
        updateActiveTab { $0.mode = mode }
    }

    // MARK: - Internals

    private func openOneFile(path: String) async throws {
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

    private func adoptOpenedDocument(_ doc: DocumentInfo, sessionId: String) async {
        RecentFilesService.record(doc)
        // Reveal the side panel by default whenever a document is opened.
        workspace?.sidebarOpen = true
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
        // The find bar belongs to the outgoing viewer; the incoming one
        // registers its own handlers on mount.
        resetFindState()
        activeTabId = tab.id
        document = tab.document
        currentPage = tab.currentPage
        numPages = tab.numPages
        zoom = tab.zoom
        visiblePages = tab.visiblePages
        webVisibleRange = tab.webVisibleRange
        webVisibleBookmarks = tab.webVisibleBookmarks
        mode = tab.mode
    }

    private func applyEmptyActiveState() {
        resetFindState()
        activeTabId = nil
        document = nil
        currentPage = 1
        numPages = 0
        zoom = 1.0
        visiblePages = []
        webVisibleRange = nil
        webVisibleBookmarks = []
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
