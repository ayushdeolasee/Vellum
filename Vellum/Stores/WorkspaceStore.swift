#if os(macOS)
import AppKit
#endif
import Foundation
import Observation

// Window-level owner of the split-screen layout. Holds the pane tree, which pane
// is focused, the one shared SessionService, and the app-global shell state that
// used to live on AppStore (inspector open/tab, sidebar text size, default
// highlight color). The toolbar and the single Annotations/AI inspector point at
// the *focused* pane's store-triple; each pane's own subtree injects its own.

/// Whether this workspace's window is allowed to hold more than one pane.
///
/// The iPhone shell (#153) has exactly one pane, and that is enforced HERE
/// rather than by leaving the split affordances out of the phone's chrome. Two
/// reasons. First, the split paths are reachable without any chrome at all — a
/// hardware keyboard's ⌃⌘D, a persisted split restored from a workspace the user
/// last opened on an iPad, a tab drag — so a view-layer omission is not a
/// guarantee. Second, "one pane" is a property of the workspace that the pane
/// tree, the residency pins and the persisted layout all have to agree on, which
/// makes the store the only place it can be stated once and tested without a
/// view.
enum PaneLayoutCapability: Sendable {
    /// iPad / Mac: `splitFocused`, `splitWithTab` and `moveTab` all work, and a
    /// persisted split is restored as a split.
    case splitScreen
    /// iPhone: every split operation is a no-op and a persisted split is
    /// flattened into one pane on restore.
    case singlePane
}

@MainActor
@Observable
final class WorkspaceStore {
    /// Which tab the Settings sheet opens on. Held here rather than as `@State`
    /// inside `SettingsView` so callers that present Settings for a reason —
    /// Home's gear button, "Configure AI…", the Storage warning — can route to
    /// the right tab instead of dumping the user on General.
    ///
    /// `integrations` ships even though iPad has no read-later integrations
    /// yet: an unreachable case costs nothing and means the integrations packet
    /// adds its tab without editing this enum.
    enum SettingsSection: Hashable, Sendable {
        case general
        case reading
        case annotations
        case ai
        case storage
        case integrations
    }

    /// The Settings tab currently selected. Set it *before* presenting the
    /// sheet; `SettingsView`'s `TabView` binds straight to it.
    var settingsSection: SettingsSection = .general

    let sessions: SessionService

    /// Whether this window may split. Fixed at construction from the shell
    /// idiom (`ShellIdiom_iOS.current.paneLayout`) — the idiom cannot change for
    /// the life of the process, so neither can this.
    let layout: PaneLayoutCapability

    /// The read-later integrations store. Window-global like the rest of the
    /// shell state, and injected rather than constructed inline so tests and
    /// previews can hand in a store with stubbed clients.
    let integrations: IntegrationsStore

    /// Window-owned position service. The underlying store is per device, but
    /// owning the facade here gives every pane the same key resolver and flush
    /// boundary.
    let positions: DocumentPositionService

    /// App-level coordinated-storage owner. Local/custom modes never install a
    /// container; iCloud mode owns exactly one container and one conflict
    /// consumer through this service.
    @ObservationIgnored let storageCoordinator: StorageCoordinator

    /// Closed tabs' in-flight teardowns, shared by every pane's AppStore so a
    /// reopen or Save As in one pane waits out a close started in another —
    /// including a pane that has since collapsed. The scene-background flush
    /// drains it directly.
    let tabTeardowns = TabTeardownRegistry()

    /// The layout tree. Reassigned wholesale on every structural change.
    private(set) var root: PaneNode
    /// Id of the focused leaf — drives the toolbar, inspector, and menu commands.
    private(set) var focusedPaneId: String

    // MARK: Shell state (moved out of AppStore — these are window-global)

    var sidebarOpen = true
    var sidebarTab: SidebarTab = .annotations
    enum SidebarTab: Sendable, CaseIterable, Hashable { case annotations, ai, scratchpad }

    // MARK: Inspector column width

    // The resize envelope has a single owner: `InspectorLayout`, next to the
    // responsive breakpoints that share its numbers. It lives there rather than
    // here because this store is `@MainActor` and that enum is not — a
    // main-actor-isolated static cannot seed a nonisolated type's defaults.

    /// The width to reopen the inspector at, tracking the user's last drag.
    ///
    /// Deliberately NOT observed. It seeds the `ideal:` of
    /// `.inspectorColumnWidth`, and is written from `PaneShell_iOS`'s
    /// `.onGeometryChange` — once per frame while the splitter is being dragged.
    /// Were it observed, each of those writes would invalidate the whole window
    /// chrome (pane tree and toolbar included) mid-drag, and feed a fresh
    /// `ideal:` back into the very layout pass that produced the measurement.
    ///
    /// Not observing it is necessary but NOT sufficient, so `PaneShell_iOS` does
    /// not read it live either: it copies this value into `@State` and holds
    /// that frozen while the column is on screen, re-seeding only when the
    /// inspector is (re)presented — the one moment `ideal:` is consulted. See
    /// `PaneShell_iOS.idealColumnWidth` for why a live read reopens the loop.
    @ObservationIgnored
    private(set) var sidebarWidth: CGFloat = InspectorLayout.idealWidth

    /// Whether SwiftUI should currently present the document inspector.
    ///
    /// `sidebarOpen` is the user's window-level preference. A start tab has no
    /// document, so it temporarily suppresses the inspector without changing
    /// that preference. Keeping these concepts separate preserves the selected
    /// panel and the column width when the user returns to a document.
    var inspectorPresented: Bool {
        focusedPane.app.document != nil && sidebarOpen
    }

    /// Applies a presentation change originating from SwiftUI's inspector host.
    /// When focus moves to a start tab SwiftUI writes `false` because the
    /// inspector is conditionally unavailable; that is not a user request to
    /// close it, so ignore the write until a document is focused.
    func setInspectorPresented(_ isPresented: Bool) {
        guard focusedPane.app.document != nil else { return }
        sidebarOpen = isPresented
    }

    /// Selects an inspector panel and makes sure it is actually on screen.
    ///
    /// The ⌥⌘1/2/3 shortcuts route here rather than assigning `sidebarTab`
    /// directly: selecting a panel in a closed inspector would change nothing
    /// the user can see, so choosing one from the keyboard has to open the
    /// column too. Reveal only — it never closes an inspector that is already
    /// open, because ⌥⌘S is the toggle and a panel command that sometimes hid
    /// the panel would be a trap.
    ///
    /// Nothing is done without a document: the inspector cannot be presented
    /// then (`inspectorPresented`), so opening it would silently flip the user's
    /// preference for whenever they next open one.
    func revealSidebarTab(_ tab: SidebarTab) {
        guard focusedPane.app.document != nil else { return }
        sidebarTab = tab
        sidebarOpen = true
    }

    /// Remembers user resizing while the inspector is genuinely visible.
    /// Geometry briefly collapses when a start tab suppresses the inspector;
    /// rejecting that transient measurement lets the next document reopen at
    /// the user's prior width.
    func rememberSidebarWidth(_ width: CGFloat) {
        guard inspectorPresented,
              (InspectorLayout.minimumWidth...InspectorLayout.maximumWidth).contains(width)
        else { return }
        sidebarWidth = width
    }

    /// A dedicated AiStore backing the Settings window's AI tab. Not tied to a
    /// document; only its `settings` are used. Changes broadcast to every pane.
    let settingsAi: AiStore

    /// Window-wide, shared by every pane's AiStore: the OpenRouter model catalog
    /// (fetched once, capability lookups) and the ChatGPT-subscription OAuth
    /// session (sign-in state + token refresh).
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
    /// iOS has no global touch state to poll, so the drag instead expires on a
    /// watchdog that drop-delegate activity (`noteDragActivity`) keeps alive.
    func beginTabDrag(_ payload: TabDragPayload) {
        draggingTab = payload
        dragPollTask?.cancel()
        #if os(macOS)
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
        #else
        scheduleDragExpiry()
        #endif
    }

    #if os(iOS)
    /// Keeps an in-flight tab drag alive. A cancelled UIKit drag (finger lifted
    /// outside any drop target) fires no callback at all, so without a refresh
    /// the drop-catcher overlays would keep intercepting touches forever.
    func noteDragActivity() {
        guard draggingTab != nil else { return }
        scheduleDragExpiry()
    }

    private func scheduleDragExpiry() {
        dragPollTask?.cancel()
        dragPollTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.endTabDrag()
        }
    }
    #endif

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

    // MARK: - Workspace-owned live tab runtimes
    //
    // Every open tab gets a `LiveTabRuntime` that owns its PDFView/WKWebView, so
    // `PaneView_iOS` can keep a host mounted per tab and a switch costs nothing
    // (issue #52). How long that native state is allowed to live is entirely the
    // residency policy's business — see Services/TabResidency.swift. This store
    // owns the runtime *objects* (cheap: a tab id and a page-text dict); the
    // policy owns their expensive contents.

    /// The window's retention policy. Not a singleton: owning it here means a
    /// discarded workspace (one per unit test) takes its sweeper and its
    /// memory-warning observer down with it, and a test can inject a hand-driven
    /// clock. Vellum ships a single scene, so in production there is exactly one
    /// of these.
    @ObservationIgnored let residency: TabResidencyManager
    @ObservationIgnored private var liveTabRuntimes: [String: LiveTabRuntime] = [:]

    /// The runtime for a tab, created on first ask. Deliberately does *not*
    /// touch the residency policy: `PaneView_iOS` calls this during layout for
    /// every open tab, and a tab that has never been looked at owns no PDFView
    /// and no WKWebView, so it must not count against a ceiling or start a
    /// sweeper.
    func liveTabRuntime(for tabId: String) -> LiveTabRuntime {
        liveTabRuntimes[tabId] ?? {
            let created = LiveTabRuntime(tabId: tabId)
            liveTabRuntimes[tabId] = created
            return created
        }()
    }

    /// The tab is being shown: undo any previous eviction and hand the runtime
    /// to the residency policy, which is the moment it starts counting against
    /// the ceilings and the idle window.
    func activateLiveTabRuntime(_ runtime: LiveTabRuntime) {
        runtime.reactivate()
        residency.store(runtime, tabId: runtime.tabId)
    }

    func existingLiveTabRuntime(for tabId: String) -> LiveTabRuntime? {
        liveTabRuntimes[tabId]
    }

    /// The tab is gone for good (closed, or its pane was discarded): hand the
    /// memory back now rather than letting the retention window run.
    func removeLiveTabRuntime(for tabId: String) {
        residency.release(tabId: tabId)
        liveTabRuntimes.removeValue(forKey: tabId)?.releaseResidency()
    }

    func flushLivePageTextCaches() async {
        for runtime in liveTabRuntimes.values {
            await runtime.flushPdfText()
        }
    }

    /// Report a pane's current tab to the residency policy, which pins it. Keyed
    /// on the pane's `AppStore` identity so a split window pins one tab *per
    /// pane* and neither visible document can be evicted.
    func paneDidActivateTab(_ app: AppStore, tabId: String?) {
        residency.markActive(tabId: tabId, owner: ObjectIdentifier(app))
    }

    /// A pane is being discarded (split collapsed / panes merged). Drop its pin
    /// so whatever it last showed stops being exempt from eviction.
    private func forgetPanePin(_ app: AppStore) {
        residency.forgetOwner(ObjectIdentifier(app))
    }

    // MARK: - Init

    /// `integrations`, `residency` and `layout` are all injectable rather than
    /// constructed inline, so tests and previews can hand in a store with
    /// stubbed clients, drive a hand-advanced clock, or ask for the phone's
    /// single-pane workspace. All three default, which keeps every existing
    /// `WorkspaceStore(sessions:)`, `WorkspaceStore(sessions:residency:)` and
    /// `WorkspaceStore(sessions:integrations:)` call site compiling unchanged
    /// and on the iPad's behaviour.
    init(
        sessions: SessionService, integrations: IntegrationsStore = IntegrationsStore(),
        residency: TabResidencyManager = TabResidencyManager(),
        layout: PaneLayoutCapability = .splitScreen,
        positions: DocumentPositionService = DocumentPositionService(),
        storageCoordinator: StorageCoordinator = StorageCoordinator()
    ) {
        self.residency = residency
        self.sessions = sessions
        self.integrations = integrations
        self.layout = layout
        self.positions = positions
        self.storageCoordinator = storageCoordinator
        let catalog = OpenRouterCatalog()
        let auth = ChatGPTAuth()
        let settingsAi = AiStore()
        settingsAi.openRouterCatalog = catalog
        settingsAi.chatgptAuth = auth
        self.settingsAi = settingsAi
        self.openRouterCatalog = catalog
        self.chatgptAuth = auth
        let pane = PaneModel(
            sessions: sessions, teardowns: tabTeardowns,
            openRouterCatalog: catalog, chatgptAuth: auth)
        self.root = .leaf(pane)
        self.focusedPaneId = pane.id
        // `self` is fully initialized now: give the pane its workspace back-ref.
        pane.app.workspace = self
    }

    func awaitPendingPositionRecords() async {
        for leaf in root.allLeaves() {
            await leaf.app.flushPendingPositionRecords()
        }
    }

    func flushOpenTabPositions(markClosed: Bool = false) async {
        await awaitPendingPositionRecords()
        for leaf in root.allLeaves() {
            for tab in leaf.app.tabs {
                guard let document = tab.document else { continue }
                await positions.recordMoved(
                    document: document,
                    position: Self.readingPosition(for: tab))
                if markClosed {
                    await positions.recordClosed(document: document)
                }
            }
        }
        await positions.flush()
    }

    func startStorageCoordinator() async {
        await storageCoordinator.start()
    }

    func foregroundStorageCoordinator() async {
        await storageCoordinator.foreground()
    }

    func reconfigureStorageCoordinator() async {
        await storageCoordinator.reconfigure()
    }

    @discardableResult
    func backgroundStorageCoordinator(
        timeout: TimeInterval? = nil,
        finalSuspensionAllowed: @escaping @Sendable () async -> Bool = { true }
    ) async -> StorageCoordinator.BackgroundDrainOutcome {
        await storageCoordinator.background(
            timeout: timeout,
            finalSuspensionAllowed: finalSuspensionAllowed)
    }

    func stopStorageCoordinator(timeout: TimeInterval? = nil) async {
        await storageCoordinator.stop(timeout: timeout)
    }

    static func readingPosition(for tab: PdfTab) -> ReadingPosition {
        ReadingPosition(
            page: max(1, tab.currentPage),
            pageCount: tab.numPages > 0 ? tab.numPages : tab.document?.pageCount)
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

    /// Every live tab in this window, in pane-tree order. The pane id travels
    /// with the tab so workspace-level UI never accidentally activates or
    /// closes an identically positioned tab in the pane that opened it.
    var allTabs: [WorkspaceTab] {
        root.allLeaves().enumerated().flatMap { paneIndex, pane in
            pane.app.tabs.map { tab in
                WorkspaceTab(paneId: pane.id, paneIndex: paneIndex, tab: tab)
            }
        }
    }

    func activateWorkspaceTab(paneId: String, tabId: String) {
        guard let pane = root.leaf(id: paneId),
              pane.app.tabs.contains(where: { $0.id == tabId }) else { return }
        focus(paneId)
        pane.app.activateTab(tabId)
    }

    func closeWorkspaceTab(paneId: String, tabId: String) async {
        guard let pane = root.leaf(id: paneId),
              pane.app.tabs.contains(where: { $0.id == tabId }) else { return }
        await pane.app.closeTab(tabId)
    }

    // MARK: - Pane construction

    private func makePane(startTab: Bool) -> PaneModel {
        let pane = PaneModel(
            sessions: sessions, teardowns: tabTeardowns,
            openRouterCatalog: openRouterCatalog, chatgptAuth: chatgptAuth)
        pane.app.workspace = self
        if startTab { pane.app.newStartTab() }
        return pane
    }

    // MARK: - Split / close / merge

    /// Split the focused pane, opening a fresh new-tab page beside it and moving
    /// focus there (menu / shortcut / toolbar-button path).
    func splitFocused(_ direction: SplitDirection) {
        guard layout == .splitScreen, let target = root.leaf(id: focusedPaneId) else { return }
        let newPane = makePane(startTab: true)
        let split = PaneNode.split(
            id: "split-" + UUID().uuidString.lowercased(),
            direction: direction,
            children: [.leaf(target), .leaf(newPane)],
            sizes: [50, 50])
        root = replacingLeaf(root, id: target.id, with: split)
        focusedPaneId = newPane.id
        scheduleSave()
    }

    /// Move a tab out of its pane into a brand-new pane created by splitting the
    /// target pane along `direction` (drag-to-edge path). `before` puts the new
    /// pane ahead of the target (left/top) vs. after (right/bottom).
    func splitWithTab(tabId: String, from: String, target: String, direction: SplitDirection, before: Bool) {
        // Before `detachTab`, not after: a refused split must leave the tab
        // exactly where it was rather than stranding it in no pane at all.
        guard layout == .splitScreen,
              let source = root.leaf(id: from),
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
    ///
    /// Under `.singlePane` there is no second pane to move into, so this is
    /// unreachable through the UI; the guard is here because the capability
    /// check belongs with the other two rather than being the one path that
    /// relies on the tree's shape to save it — and because it runs BEFORE
    /// `detachTab`, so a stale drag payload cannot strand a tab.
    func moveTab(tabId: String, from: String, to: String) {
        guard layout == .splitScreen,
              from != to,
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
        guard let closingPane = root.leaf(id: paneId) else { return }
        // The pane is going away, so its "this tab is on screen" pin must go with
        // it — otherwise whatever it last showed stays exempt from eviction for
        // the life of the process — and any tab it still holds is unreachable
        // from here on, so its native state is released now rather than in half
        // an hour. (In the common case — a pane emptied by a tab drag — `tabs`
        // is already empty and only the pin matters.)
        closingPane.app.discardAllTabsForPaneClosure()
        forgetPanePin(closingPane.app)
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
            // Ownership is *transferred*, exactly as in `moveTab` — detach from
            // the donor before attaching to `keep`. Copying instead would leave
            // two AppStores claiming the same tab id, and anything keyed on
            // tab-to-pane ownership (the web controller's mount guard, the ink
            // registry, find and note-placement state, the residency pin) would
            // still resolve the tab to the pane it just left (issue #91). Ids
            // are snapshotted first because `detachTab` mutates the array being
            // walked.
            for tabId in leaf.app.tabs.map(\.id) {
                guard let tab = leaf.app.detachTab(tabId) else {
                    // Unreachable: the ids came from this pane a line ago and
                    // nothing between here and there can remove one. Losing a
                    // tab silently is the worst outcome available, so say so.
                    assertionFailure("mergeAll: \(tabId) vanished from its own pane mid-merge")
                    continue
                }
                keep.app.attachTab(tab)
            }
            // Same reasoning as closePane: the absorbed pane is discarded, so
            // drop its residency pin. Its tabs are now pinned (or not) by `keep`.
            // Their runtimes are workspace-owned and keyed by tab id, so they
            // migrate with the tabs untouched.
            //
            // Emptying the pane above has in fact already dropped the pin —
            // the last `detachTab` re-points the pane at nothing, which reports
            // `markActive(nil)` — so this is normally a no-op. It stays because
            // the one case it isn't is a donor whose `activeTabId` disagrees
            // with its `tabs`: the pin would then outlive the pane, and a stale
            // `ObjectIdentifier` key aliases whatever AppStore is allocated at
            // that address next.
            forgetPanePin(leaf.app)
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
            // Start tabs are a transient navigation surface, not documents.
            // Persisting them strands abandoned "New Tab" entries among the
            // user's reading tabs after relaunch.
            let liveTabs = pane.app.tabs.filter { $0.document != nil }
            let tabs = liveTabs.map {
                TabDescriptor(
                    document: $0.document,
                    currentPage: $0.currentPage,
                    zoom: $0.zoom,
                    mode: $0.regionCaptureTarget == nil ? $0.mode : .view)
            }
            let activeIndex = pane.app.activeTabId.flatMap { id in
                liveTabs.firstIndex { $0.id == id }
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

    func saveNowAfterPendingPositionRecords() async {
        await awaitPendingPositionRecords()
        saveNow()
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
        flattenRestoredSplitIfSinglePane(focusedLeafIndex: state.focusedLeafIndex)
        let restoredFocusedPaneId = root.allLeaves().indices.contains(state.focusedLeafIndex)
            ? root.allLeaves()[state.focusedLeafIndex].id
            : nil
        pruneAbandonedEmptyPanes()
        if let restoredFocusedPaneId, root.leaf(id: restoredFocusedPaneId) != nil {
            focusedPaneId = restoredFocusedPaneId
        }
        isRestoring = false
        // Persist the reconciled state (some tabs may have failed to reopen).
        scheduleSave()
    }

    /// Collapse a restored split into one pane when this window cannot hold two.
    ///
    /// The persisted layout is shared with the iPad — same defaults domain, same
    /// blob — so a phone launching after an iPad session routinely finds a split
    /// on disk. Restoring it and *then* refusing to draw the second pane would
    /// leave that pane's tabs unreachable and its residency pin live forever, so
    /// the flatten happens here, at the store, the moment the tabs are back.
    ///
    /// Deliberately reuses `mergeAll()` rather than rebuilding the tree by hand:
    /// merging is the operation that already transfers tab OWNERSHIP (rather
    /// than copying, #91) and drops each absorbed pane's residency pin. Focus is
    /// moved to the first leaf first so `mergeAll` keeps that pane — the one at
    /// the head of the persisted tab order — and the tab the user was actually on
    /// is re-activated afterwards, since it may have lived in a pane that just
    /// stopped existing.
    private func flattenRestoredSplitIfSinglePane(focusedLeafIndex: Int) {
        guard layout == .singlePane, !root.isLeaf else { return }
        let leaves = root.allLeaves()
        let persistedActiveTabId = leaves.indices.contains(focusedLeafIndex)
            ? leaves[focusedLeafIndex].app.activeTabId
            : nil
        focusedPaneId = root.firstLeafId
        mergeAll()
        if let persistedActiveTabId {
            focusedPane.app.activateTab(persistedActiveTabId)
        }
    }

    /// A persisted split can become partially empty when documents disappear
    /// before the next launch. Empty leaves are not useful split targets, so
    /// collapse them after restore while preserving one Welcome pane if every
    /// saved document was unavailable.
    func pruneAbandonedEmptyPanes() {
        let before = root.allLeaves()
        let fallback = before.first
        if let pruned = pruningEmptyLeaves(root) {
            root = pruned
        } else if let fallback {
            root = .leaf(fallback)
        }
        // Same contract as `closePane` and `mergeAll`: a pane that stops
        // existing must drop its residency pin, or whatever it last showed
        // stays exempt from eviction for the life of the process (issue #52).
        let survivors = Set(root.allLeaves().map(\.id))
        for pane in before where !survivors.contains(pane.id) {
            pane.app.discardAllTabsForPaneClosure()
            forgetPanePin(pane.app)
        }
        if root.leaf(id: focusedPaneId) == nil {
            focusedPaneId = root.firstLeafId
        }
    }

    func hasOpenDocument(key: DocumentKey, excludingTabIds: Set<String> = []) -> Bool {
        root.allLeaves().contains { pane in
            pane.app.containsOpenDocument(key: key, excludingTabIds: excludingTabIds)
        }
    }

    private func pruningEmptyLeaves(_ node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf(let pane):
            return pane.app.tabs.isEmpty ? nil : node
        case .split(let id, let direction, let children, let sizes):
            var keptChildren: [PaneNode] = []
            var keptSizes: [Double] = []
            for (index, child) in children.enumerated() {
                if let survivor = pruningEmptyLeaves(child) {
                    keptChildren.append(survivor)
                    keptSizes.append(sizes.indices.contains(index) ? sizes[index] : 1)
                }
            }
            if keptChildren.isEmpty { return nil }
            if keptChildren.count == 1 { return keptChildren[0] }
            return .split(id: id, direction: direction, children: keptChildren, sizes: normalized(keptSizes))
        }
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

struct WorkspaceTab: Identifiable, Equatable {
    let paneId: String
    let paneIndex: Int
    let tab: PdfTab

    var id: String { "\(paneId):\(tab.id)" }
    var paneLabel: String { "Pane \(paneIndex + 1)" }
}
