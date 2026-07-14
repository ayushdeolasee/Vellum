import AppKit
import Foundation
import Observation

// Window-level owner of the split-screen layout. Holds the pane tree, which pane
// is focused, the one shared SessionService, and the app-global shell state that
// used to live on AppStore (inspector open/tab, sidebar text size, default
// highlight color). The toolbar and the single Annotations/AI inspector point at
// the *focused* pane's store-triple; each pane's own subtree injects its own.

@MainActor
@Observable
final class WorkspaceStore {
    let sessions: SessionService

    /// The layout tree. Reassigned wholesale on every structural change.
    private(set) var root: PaneNode
    /// Id of the focused leaf — drives the toolbar, inspector, and menu commands.
    private(set) var focusedPaneId: String

    // MARK: Shell state (moved out of AppStore — these are window-global)

    var sidebarOpen = true
    var sidebarTab: SidebarTab = .annotations
    enum SidebarTab: Sendable { case annotations, ai }

    /// A dedicated AiStore backing the Settings window's AI tab. Not tied to a
    /// document; only its `settings` are used. Changes broadcast to every pane.
    let settingsAi: AiStore

    /// App-wide AI services, owned here because this store creates every pane's
    /// AiStore (which holds them weakly) and both scenes inject them into the
    /// environment for the AI settings UI.
    let openRouterCatalog: OpenRouterCatalog
    let chatgptAuth: ChatGPTAuth

    // MARK: Sidebar text size — ⌘+/⌘− while the pointer is over the side panel.

    static let minSidebarFontSize: Double = 10
    static let maxSidebarFontSize: Double = 24
    private static let sidebarFontSizeKey = "sidebarFontSize"

    var sidebarFontSize: Double = {
        let stored = UserDefaults.standard.double(forKey: WorkspaceStore.sidebarFontSizeKey)
        return stored == 0 ? 14 : min(WorkspaceStore.maxSidebarFontSize, max(WorkspaceStore.minSidebarFontSize, stored))
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

    // MARK: Default highlight color — Settings ▸ Annotations. Window-global.

    static let defaultHighlightColorKey = "vellum.defaultHighlightColor"

    var defaultHighlightColor: String = {
        let stored = UserDefaults.standard.string(forKey: WorkspaceStore.defaultHighlightColorKey)
        if let stored, HIGHLIGHT_COLORS.contains(where: { $0.value.caseInsensitiveCompare(stored) == .orderedSame }) {
            return stored
        }
        return HIGHLIGHT_COLORS[0].value
    }() {
        didSet {
            UserDefaults.standard.set(defaultHighlightColor, forKey: Self.defaultHighlightColorKey)
        }
    }

    /// The persisted default highlight color read without an instance (services
    /// that create annotations off the main store, e.g. web sidecars, the AI).
    static func storedDefaultHighlightColor() -> String {
        let stored = UserDefaults.standard.string(forKey: defaultHighlightColorKey)
        if let stored, HIGHLIGHT_COLORS.contains(where: { $0.value.caseInsensitiveCompare(stored) == .orderedSame }) {
            return stored
        }
        return HIGHLIGHT_COLORS[0].value
    }

    /// The tab currently being dragged, or nil. Drives whether panes show their
    /// drop-zone overlays — gating on this (rather than the per-pane DropDelegate
    /// state, which can go stale when a drag is cancelled) guarantees the
    /// highlight always clears the moment the mouse is released.
    private(set) var draggingTab: TabDragPayload?
    @ObservationIgnored private var dragPollTask: Task<Void, Never>?

    /// Called when a tab drag begins. Starts polling the physical mouse-button
    /// state so the drag is considered over the instant the button is released —
    /// SwiftUI gives `.onDrag` no end callback, and a cancelled drag fires no
    /// drop, so `NSEvent.pressedMouseButtons` is the only reliable end signal.
    func beginTabDrag(_ payload: TabDragPayload) {
        draggingTab = payload
        dragPollTask?.cancel()
        dragPollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            while !Task.isCancelled {
                if NSEvent.pressedMouseButtons & 0x1 == 0 {
                    self?.endTabDrag()
                    return
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
        }
    }

    func endTabDrag() {
        draggingTab = nil
        dragPollTask?.cancel()
        dragPollTask = nil
    }

    /// True once `restoreFromDisk` has run — gates saving so an early mutation
    /// can't clobber the persisted layout before we've had a chance to load it.
    private(set) var didRestore = false
    /// Suppresses saves while a restore is populating panes.
    @ObservationIgnored private var isRestoring = false
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    // MARK: - Init

    init(sessions: SessionService) {
        let catalog = OpenRouterCatalog()
        let auth = ChatGPTAuth()
        let settingsAi = AiStore()
        settingsAi.openRouterCatalog = catalog
        settingsAi.chatgptAuth = auth
        self.sessions = sessions
        self.openRouterCatalog = catalog
        self.chatgptAuth = auth
        self.settingsAi = settingsAi
        let pane = PaneModel(sessions: sessions, openRouterCatalog: catalog, chatgptAuth: auth)
        self.root = .leaf(pane)
        self.focusedPaneId = pane.id
        // `self` is fully initialized now: give the pane its workspace back-ref.
        pane.app.workspace = self
    }

    // MARK: - Focus

    var focusedPane: PaneModel {
        root.leaf(id: focusedPaneId) ?? root.allLeaves()[0]
    }

    func focus(_ paneId: String) {
        guard root.leaf(id: paneId) != nil else { return }
        focusedPaneId = paneId
        scheduleSave()
    }

    /// True when the window shows more than one pane (drives focus rings etc.).
    var isSplit: Bool { !root.isLeaf }

    // MARK: - Pane construction

    private func makePane(startTab: Bool) -> PaneModel {
        let pane = PaneModel(
            sessions: sessions, openRouterCatalog: openRouterCatalog, chatgptAuth: chatgptAuth)
        pane.app.workspace = self
        if startTab { pane.app.newStartTab() }
        return pane
    }

    // MARK: - Split / close / merge

    /// Split the focused pane, opening a fresh new-tab page beside it and moving
    /// focus there (menu / shortcut / toolbar-button path).
    func splitFocused(_ direction: SplitDirection) {
        guard let target = root.leaf(id: focusedPaneId) else { return }
        let newPane = makePane(startTab: true)
        let split = PaneNode.split(
            id: "split-" + UUID().uuidString.lowercased(),
            direction: direction,
            children: [.leaf(target), .leaf(newPane)],
            sizes: [50, 50])
        root = replacingLeaf(root, id: target.id, with: split)
        focusedPaneId = newPane.id
        sidebarOpen = true
        scheduleSave()
    }

    /// Move a tab out of its pane into a brand-new pane created by splitting the
    /// target pane along `direction` (drag-to-edge path). `before` puts the new
    /// pane ahead of the target (left/top) vs. after (right/bottom).
    func splitWithTab(tabId: String, from: String, target: String, direction: SplitDirection, before: Bool) {
        guard let source = root.leaf(id: from),
              let targetPane = root.leaf(id: target) else { return }
        // Dragging a pane's only tab onto its own edge is a no-op.
        if from == target && source.app.tabs.count <= 1 { return }
        guard let tab = source.app.detachTab(tabId) else { return }
        let newPane = makePane(startTab: false)
        newPane.app.attachTab(tab)
        let children: [PaneNode] = before
            ? [.leaf(newPane), .leaf(targetPane)]
            : [.leaf(targetPane), .leaf(newPane)]
        let split = PaneNode.split(
            id: "split-" + UUID().uuidString.lowercased(),
            direction: direction,
            children: children,
            sizes: [50, 50])
        root = replacingLeaf(root, id: target, with: split)
        focusedPaneId = newPane.id
        if from != target && source.app.tabs.isEmpty {
            closePane(from)
        }
        scheduleSave()
    }

    /// Move a tab into an existing pane (drag-to-center path).
    func moveTab(tabId: String, from: String, to: String) {
        guard from != to,
              let source = root.leaf(id: from),
              let dest = root.leaf(id: to),
              let tab = source.app.detachTab(tabId) else { return }
        dest.app.attachTab(tab)
        focusedPaneId = to
        if source.app.tabs.isEmpty { closePane(from) }
        scheduleSave()
    }

    /// Collapse a pane; its sibling reclaims the space. Closing the last pane
    /// resets the window to a single empty pane.
    func closePane(_ paneId: String) {
        guard root.leaf(id: paneId) != nil else { return }
        if root.isLeaf {
            let pane = makePane(startTab: false)
            root = .leaf(pane)
            focusedPaneId = pane.id
            scheduleSave()
            return
        }
        if let pruned = removingLeaf(root, id: paneId) {
            root = pruned
        }
        if root.leaf(id: focusedPaneId) == nil {
            focusedPaneId = root.firstLeafId
        }
        scheduleSave()
    }

    /// Called by a pane's AppStore when it just closed its last tab. In a split
    /// window the now-empty pane collapses and its sibling reclaims the space; a
    /// lone pane stays open (showing the Welcome screen).
    func paneDidEmpty(_ app: AppStore) {
        guard isSplit, let leaf = root.allLeaves().first(where: { $0.app === app }) else { return }
        closePane(leaf.id)
    }

    /// Flatten every split back to a single pane (View ▸ Merge Panes). Keeps the
    /// focused pane; other panes' tabs migrate into it so nothing is lost.
    func mergeAll() {
        let leaves = root.allLeaves()
        guard leaves.count > 1 else { return }
        let keep = root.leaf(id: focusedPaneId) ?? leaves[0]
        // Preserve whatever `keep` was showing: each attachTab activates the tab
        // it adopts, so without restoring this the surviving pane would end up on
        // the last migrated tab instead of the user's current document.
        let keepActiveTabId = keep.app.activeTabId
        for leaf in leaves where leaf.id != keep.id {
            for tab in leaf.app.tabs {
                keep.app.attachTab(tab)
            }
        }
        if let keepActiveTabId {
            keep.app.activateTab(keepActiveTabId)
        }
        root = .leaf(keep)
        focusedPaneId = keep.id
        scheduleSave()
    }

    // MARK: - Resize

    /// Replace a split node's size weights (from a divider drag).
    func setSizes(splitId: String, sizes: [Double]) {
        root = updatingSizes(root, splitId: splitId, sizes: sizes)
        scheduleSave()
    }

    // MARK: - Tree transforms (pure)

    private func replacingLeaf(_ node: PaneNode, id: String, with replacement: PaneNode) -> PaneNode {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? replacement : node
        case .split(let sid, let dir, let children, let sizes):
            return .split(id: sid, direction: dir,
                          children: children.map { replacingLeaf($0, id: id, with: replacement) },
                          sizes: sizes)
        }
    }

    /// Remove the leaf `id`; returns nil if the whole subtree vanishes, collapses
    /// a split down to its sole survivor, and renormalizes sibling sizes.
    private func removingLeaf(_ node: PaneNode, id: String) -> PaneNode? {
        switch node {
        case .leaf(let pane):
            return pane.id == id ? nil : node
        case .split(let sid, let dir, let children, let sizes):
            var keptChildren: [PaneNode] = []
            var keptSizes: [Double] = []
            for (index, child) in children.enumerated() {
                if let survivor = removingLeaf(child, id: id) {
                    keptChildren.append(survivor)
                    keptSizes.append(sizes.indices.contains(index) ? sizes[index] : 1)
                }
            }
            if keptChildren.isEmpty { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            return .split(id: sid, direction: dir, children: keptChildren, sizes: normalized(keptSizes))
        }
    }

    private func updatingSizes(_ node: PaneNode, splitId: String, sizes: [Double]) -> PaneNode {
        switch node {
        case .leaf:
            return node
        case .split(let sid, let dir, let children, let existing):
            if sid == splitId, sizes.count == children.count {
                return .split(id: sid, direction: dir, children: children, sizes: sizes)
            }
            return .split(id: sid, direction: dir,
                          children: children.map { updatingSizes($0, splitId: splitId, sizes: sizes) },
                          sizes: existing)
        }
    }

    private func normalized(_ sizes: [Double]) -> [Double] {
        let total = sizes.reduce(0, +)
        guard total > 0 else { return Array(repeating: 100.0 / Double(sizes.count), count: sizes.count) }
        return sizes.map { $0 / total * 100 }
    }

    // MARK: - Persistence

    /// Snapshot the current layout for disk.
    func serialize() -> WorkspaceState {
        let leaves = root.allLeaves()
        let focusIndex = leaves.firstIndex { $0.id == focusedPaneId } ?? 0
        return WorkspaceState(root: dto(from: root), focusedLeafIndex: focusIndex)
    }

    private func dto(from node: PaneNode) -> PaneNodeDTO {
        switch node {
        case .leaf(let pane):
            let tabs = pane.app.tabs.map {
                TabDescriptor(document: $0.document, currentPage: $0.currentPage, zoom: $0.zoom, mode: $0.mode)
            }
            let activeIndex = pane.app.activeTabId.flatMap { id in
                pane.app.tabs.firstIndex { $0.id == id }
            }
            return .leaf(tabs: tabs, activeTabIndex: activeIndex)
        case .split(_, let direction, let children, let sizes):
            return .split(direction: direction, children: children.map { dto(from: $0) }, sizes: sizes)
        }
    }

    /// Debounced background save. No-op until a restore has run.
    func scheduleSave() {
        guard didRestore, !isRestoring else { return }
        let snapshot = serialize()
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            WorkspaceService.save(snapshot)
        }
    }

    /// Synchronous save for app termination.
    func saveNow() {
        guard didRestore else { return }
        WorkspaceService.save(serialize())
    }

    /// Rebuild the layout from disk once, at launch. Paints the pane structure
    /// immediately, then asynchronously reopens each tab's document (fresh
    /// sessions). Missing files simply drop their tab.
    func restoreFromDisk() async {
        guard !didRestore else { return }
        didRestore = true
        guard let state = WorkspaceService.load() else { return }
        isRestoring = true
        var leafWork: [(pane: PaneModel, tabs: [TabDescriptor], activeIndex: Int?)] = []
        let tree = buildNode(state.root, collecting: &leafWork)
        root = tree
        focusedPaneId = root.firstLeafId
        for work in leafWork {
            await work.pane.app.restoreTabs(work.tabs, activeIndex: work.activeIndex)
        }
        let leaves = root.allLeaves()
        if leaves.indices.contains(state.focusedLeafIndex) {
            focusedPaneId = leaves[state.focusedLeafIndex].id
        }
        isRestoring = false
        // Persist the reconciled state (some tabs may have failed to reopen).
        scheduleSave()
    }

    private func buildNode(
        _ dto: PaneNodeDTO,
        collecting leafWork: inout [(pane: PaneModel, tabs: [TabDescriptor], activeIndex: Int?)]
    ) -> PaneNode {
        switch dto {
        case .leaf(let tabs, let activeIndex):
            let pane = makePane(startTab: false)
            leafWork.append((pane, tabs, activeIndex))
            return .leaf(pane)
        case .split(let direction, let children, let sizes):
            return .split(
                id: "split-" + UUID().uuidString.lowercased(),
                direction: direction,
                children: children.map { buildNode($0, collecting: &leafWork) },
                sizes: sizes)
        }
    }
}
