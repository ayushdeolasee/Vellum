import Foundation
import Observation

// Tab + viewport state — port of src/stores/pdf-store.ts plus the shell-level
// sidebar state from App.tsx. Action semantics mirror the zustand store 1:1.

@MainActor
@Observable
final class AppStore {
    static let minZoom: Double = 0.25
    static let maxZoom: Double = 4.0
    static let zoomStep: Double = 0.1

    let sessions: SessionService

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

    // Shell state (App.tsx locals)
    var sidebarOpen = true
    var sidebarTab: SidebarTab = .annotations

    enum SidebarTab { case annotations, ai }

    // Sidebar text size — ⌘+/⌘− while the pointer is over the side panel.
    static let minSidebarFontSize: Double = 10
    static let maxSidebarFontSize: Double = 24
    private static let sidebarFontSizeKey = "sidebarFontSize"

    var sidebarFontSize: Double = {
        let stored = UserDefaults.standard.double(forKey: "sidebarFontSize")
        return stored == 0 ? 14 : min(AppStore.maxSidebarFontSize, max(AppStore.minSidebarFontSize, stored))
    }() {
        didSet {
            UserDefaults.standard.set(sidebarFontSize, forKey: Self.sidebarFontSizeKey)
        }
    }

    func increaseSidebarFont() {
        sidebarFontSize = min(Self.maxSidebarFontSize, sidebarFontSize + 1)
    }

    func decreaseSidebarFont() {
        sidebarFontSize = max(Self.minSidebarFontSize, sidebarFontSize - 1)
    }

    /// Registered by the PDF viewer to zoom anchored on the viewport center
    /// (window.__zoomPdfTo in the original).
    var zoomToHandler: ((Double) -> Void)?
    /// Registered by the viewer to scroll a page into view (window.__scrollToPage).
    var scrollToPageHandler: ((Int) -> Void)?
    /// Registered by the web viewer: scroll to a text-anchored web position;
    /// returns whether the anchor was found (window.__scrollToWebPosition).
    var scrollToWebPositionHandler: ((PositionData, Int) -> Bool)?

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
            return
        }
        tabs = remaining
        if remaining.isEmpty {
            applyEmptyActiveState()
        } else {
            let next = remaining[min(closingIndex, remaining.count - 1)]
            applyActiveState(from: next)
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
        sidebarOpen = true
        // Was the active tab a start tab? If so, opening a document from it
        // replaces that tab in place rather than appending a new one.
        let activeStartIndex: Int? = activeTabId.flatMap { id in
            tabs.firstIndex(where: { $0.id == id && $0.document == nil })
        }
        if let existing = tabs.first(where: { $0.document?.pdfPath == doc.pdfPath }) {
            try? await sessions.closeFile(sessionId: sessionId)
            // Discard the start tab we opened from before switching to the
            // already-open document (never remove the target itself).
            if let activeStartIndex, tabs[activeStartIndex].id != existing.id {
                tabs.remove(at: activeStartIndex)
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
        if let activeStartIndex {
            tabs[activeStartIndex] = tab
        } else {
            tabs.append(tab)
        }
        applyActiveState(from: tab)
    }

    private func applyActiveState(from tab: PdfTab) {
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
