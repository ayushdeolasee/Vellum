#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

// iPad reading chrome: a touch-first Liquid Glass toolbar (page nav, zoom, find,
// note tool, bookmark, sidebar, more), a tab strip, and the sidebar content —
// the iPad analogue of the macOS VellumToolbar / TabBarView. Tap targets are
// 44pt; low-frequency file actions collect in a "More" menu.

// MARK: - Toolbar

struct PdfToolbar_iOS: View {
    var ink: InkController_iOS
    var onOpenFile: () -> Void
    var onAddWebpage: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    @State private var pageFieldText = ""
    @State private var showPageJump = false
    @State private var showSettings = false
    @State private var toolbarWidth: CGFloat = 0

    // Web-tab offline-copy state, mirroring the macOS OverflowMenu.
    @State private var pageSaved = false
    @State private var exporting = false
    /// Serializes save/remove so a rapid Remove can't finish before a slow
    /// Save's archive write and get its deletion undone by it.
    @State private var saveToggleTask: Task<Void, Never>?
    /// Identifies the newest queued toggle, so a superseded one's failure can't
    /// revert the toolbar to a state the user has already toggled away from.
    @State private var saveToggleGeneration = 0

    private var isWeb: Bool { appStore.document?.kind == .web }
    // The pods have fixed 44pt targets, so when the sidebar squeezes the row
    // the lowest-value pods yield instead of clipping at the edges: the zoom
    // pod first (pinch still works for PDFs and web pages; More keeps the
    // commands), then the page-step chevrons (the page field still jumps
    // anywhere).
    private var showZoomPod: Bool { toolbarWidth == 0 || toolbarWidth >= 740 }
    private var showPageChevrons: Bool { toolbarWidth == 0 || toolbarWidth >= 590 }
    // Narrowest tier: when a split pane is squeezed by the open inspector, fold
    // the find/note/ink/bookmark pod into the More menu so the trailing
    // sidebar-toggle + More pod always fits inside the pane instead of being
    // pushed under (and clipped by) the sidebar where it can't be tapped.
    private var showActionsPod: Bool { toolbarWidth == 0 || toolbarWidth >= 500 }
    private var isBookmarked: Bool {
        findCurrentBookmark(
            annotations: annotationStore.annotations,
            docKind: appStore.document?.kind,
            currentPage: appStore.currentPage,
            webVisibleBookmarks: appStore.webVisibleBookmarks
        ) != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            // Leading pod: close current tab (return to library when last).
            GlassToolPod {
                GlassToolButton(system: "chevron.backward", label: "Close") {
                    if let id = appStore.activeTabId {
                        Task { await appStore.closeTab(id) }
                    }
                }
            }

            if isWeb {
                GlassToolPod {
                    GlassToolButton(system: "arrow.left", label: "Back") {
                        webHistory(-1)
                    }
                    GlassToolButton(system: "arrow.right", label: "Forward") {
                        webHistory(1)
                    }
                }
            } else {
                GlassToolPod {
                    if showPageChevrons {
                        GlassToolButton(system: "chevron.left", label: "Previous page") {
                            appStore.goToPage(appStore.currentPage - 1)
                        }
                    }
                    pageField
                    if showPageChevrons {
                        GlassToolButton(system: "chevron.right", label: "Next page") {
                            appStore.goToPage(appStore.currentPage + 1)
                        }
                    }
                }
            }

            if showZoomPod {
                GlassToolPod {
                    GlassToolButton(system: "minus.magnifyingglass", label: "Zoom out") {
                        appStore.zoomOut()
                    }
                    Button {
                        appStore.setZoom(1.0)
                        appStore.zoomToHandler?(1.0)
                    } label: {
                        Text("\(Int((appStore.zoom * 100).rounded()))%")
                            .font(.system(size: 14, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(palette.foreground)
                            .frame(minWidth: 52, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Reset zoom to 100%")
                    GlassToolButton(system: "plus.magnifyingglass", label: "Zoom in") {
                        appStore.zoomIn()
                    }
                }
            }

            Spacer(minLength: 4)

            if showActionsPod {
                GlassToolPod {
                    GlassToolButton(system: "magnifyingglass", label: "Find") {
                        appStore.findVisible ? appStore.hideFind() : appStore.showFind()
                    }
                    GlassToolButton(
                        system: "note.text", label: "Sticky note tool",
                        active: appStore.mode == .note
                    ) {
                        ink.isActive = false
                        appStore.setMode(appStore.mode == .note ? .view : .note)
                    }
                    if !isWeb {
                        GlassToolButton(
                            system: "pencil.tip.crop.circle", label: "Apple Pencil ink",
                            active: ink.isActive
                        ) {
                            if !ink.isActive { appStore.setMode(.view) }
                            ink.isActive.toggle()
                        }
                    }
                    GlassToolButton(
                        system: isBookmarked ? "bookmark.fill" : "bookmark",
                        label: isBookmarked ? "Remove bookmark" : "Bookmark",
                        tint: isBookmarked ? palette.gold : nil
                    ) {
                        Task { await annotationStore.toggleBookmark() }
                    }
                }
            }

            GlassToolPod {
                GlassToolButton(
                    system: "sidebar.right", label: "Toggle sidebar",
                    active: workspace.sidebarOpen
                ) {
                    workspace.sidebarOpen.toggle()
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            toolbarWidth = width
        }
        .alert("Go to page", isPresented: $showPageJump) {
            TextField("Page", text: $pageFieldText)
                .keyboardType(.numberPad)
            Button("Go", action: commitPageField)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a page number (1–\(appStore.numPages)).")
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack {
                SettingsView()
                    .navigationTitle("Settings")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showSettings = false }
                        }
                    }
            }
            // The Settings AI tab edits the workspace's dedicated settings
            // store (not this pane's conversation), mirroring the macOS
            // Settings scene; changes broadcast to every pane's AiStore.
            .environment(workspace.settingsAi)
            .environment(workspace.openRouterCatalog)
            .environment(workspace.chatgptAuth)
            .presentationDetents([.large])
        }
    }

    /// Tappable "p / N" indicator that opens a jump prompt.
    private var pageField: some View {
        Button {
            pageFieldText = String(appStore.currentPage)
            showPageJump = true
        } label: {
            HStack(spacing: 4) {
                Text("\(appStore.currentPage)")
                    .foregroundStyle(palette.foreground)
                Text("/ \(appStore.numPages)")
                    .foregroundStyle(palette.mutedForeground)
            }
            .font(.system(size: 15, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Page \(appStore.currentPage) of \(appStore.numPages). Tap to jump.")
    }

    private var moreMenu: some View {
        Menu {
            // When the pane is too narrow to show the actions pod, its controls
            // live here so Find / Note / Ink / Bookmark stay reachable.
            if !showActionsPod {
                Button {
                    appStore.findVisible ? appStore.hideFind() : appStore.showFind()
                } label: { Label("Find", systemImage: "magnifyingglass") }
                Button {
                    ink.isActive = false
                    appStore.setMode(appStore.mode == .note ? .view : .note)
                } label: {
                    Label(
                        appStore.mode == .note ? "Exit Sticky Note Tool" : "Sticky Note",
                        systemImage: "note.text")
                }
                if !isWeb {
                    Button {
                        if !ink.isActive { appStore.setMode(.view) }
                        ink.isActive.toggle()
                    } label: {
                        Label(
                            ink.isActive ? "Exit Apple Pencil Ink" : "Apple Pencil Ink",
                            systemImage: "pencil.tip.crop.circle")
                    }
                }
                Button {
                    Task { await annotationStore.toggleBookmark() }
                } label: {
                    Label(
                        isBookmarked ? "Remove Bookmark" : "Bookmark",
                        systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                }
                Divider()
            }
            Button(action: onOpenFile) { Label("Open File…", systemImage: "folder") }
            Button(action: onAddWebpage) { Label("Add Webpage…", systemImage: "globe") }
            if !isWeb {
                Button {
                    if let id = appStore.activeTabId {
                        Task { try? await appStore.sessions.saveFile(sessionId: id) }
                    }
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
            }
            if isWeb {
                Button(action: toggleSavedPage) {
                    Label(
                        pageSaved ? "Remove Offline Copy" : "Save for Offline Use",
                        systemImage: pageSaved ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityIdentifier("toolbar.saveForOffline")
                Button(action: exportVellumweb) {
                    Label("Export a Copy…", systemImage: "square.and.arrow.up")
                }
                .disabled(exporting)
            }
            if !showZoomPod {
                Divider()
                Button { appStore.zoomIn() } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                Button { appStore.zoomOut() } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                Button {
                    appStore.setZoom(1.0)
                    appStore.zoomToHandler?(1.0)
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
            }
            Divider()
            // Split-screen: this menu belongs to a pane, and tapping it focuses
            // that pane (the pane's touch catcher fires first), so the focused-
            // pane operations below always target the pane the menu lives in.
            Button {
                workspace.splitFocused(.horizontal)
            } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
            Button {
                workspace.splitFocused(.vertical)
            } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
            if workspace.isSplit {
                Button {
                    workspace.mergeAll()
                } label: { Label("Merge Panes", systemImage: "rectangle") }
                Button {
                    workspace.closePane(workspace.focusedPaneId)
                } label: { Label("Close Pane", systemImage: "xmark.rectangle") }
            }
            Divider()
            Button { showSettings = true } label: { Label("Settings…", systemImage: "gearshape") }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
        // Toolbar state (offline-copy flag) resets whenever the active tab or
        // its backing document changes.
        .task(id: DocumentKey_iOS(appStore)) {
            await loadSavedState(for: DocumentKey_iOS(appStore))
        }
    }

    /// In-page history for web tabs — same channel the macOS toolbar uses.
    private func webHistory(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }

    private func commitPageField() {
        let trimmed = pageFieldText.trimmingCharacters(in: .whitespaces)
        if let page = Int(trimmed) {
            appStore.goToPage(page)
        }
        pageFieldText = String(appStore.currentPage)
    }

    // MARK: - Web offline copy

    private func loadSavedState(for identity: DocumentKey_iOS) async {
        pageSaved = false
        guard isWeb, let sessionId = appStore.activeTabId else { return }
        let saved = (try? await appStore.sessions.getWebpageSaved(sessionId: sessionId)) ?? false
        if DocumentKey_iOS(appStore) == identity {
            pageSaved = saved
        }
    }

    /// Save = mark the page kept AND make sure its offline copy exists (the
    /// re-archive covers a copy the user deleted from Settings ▸ Storage).
    /// Remove = un-keep and delete the offline copy; the record — highlights,
    /// notes, reading position — always survives.
    private func toggleSavedPage() {
        guard let sessionId = appStore.activeTabId else { return }
        let next = !pageSaved
        pageSaved = next
        let expectedUrl = appStore.document?.pdfPath ?? ""
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        let prior = saveToggleTask
        saveToggleGeneration += 1
        let generation = saveToggleGeneration
        saveToggleTask = Task {
            await prior?.value
            do {
                try await appStore.sessions.setWebpageSaved(sessionId: sessionId, saved: next)
                if next {
                    // Best-effort: membership is saved even if the archive
                    // write fails (offline, no snapshot yet) — the copy is
                    // rewritten on the next open of the page.
                    _ = try? await appStore.sessions.archiveWebpageDefault(
                        sessionId: sessionId, pages: pages, expectedUrl: expectedUrl)
                }
            } catch {
                // Only the newest toggle owns the button: an older one failing
                // behind a queued newer one must not resurrect its own state.
                if appStore.activeTabId == sessionId, generation == saveToggleGeneration {
                    pageSaved = !next
                }
            }
        }
    }

    /// Export the active webpage as a .vellumweb archive. macOS uses NSSavePanel;
    /// iOS writes the archive to a temporary file and hands it to the Files
    /// export picker, which copies it to the destination the user chooses.
    private func exportVellumweb() {
        guard !exporting,
              let sessionId = appStore.activeTabId,
              appStore.document?.kind == .web else { return }

        let slug = slugifiedTitle()
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        exporting = true
        Task {
            defer { exporting = false }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(slug).vellumweb")
            try? FileManager.default.removeItem(at: tmp)
            guard (try? await appStore.sessions.exportVellumweb(
                sessionId: sessionId, destPath: tmp.path, pages: pages)) != nil else { return }
            DocumentPickerCoordinator_iOS.shared.presentExport(urls: [tmp])
        }
    }

    /// Slug for the export default filename: lowercased title, non-alphanumeric
    /// runs collapsed to "-", trimmed, max 60 chars, fallback "article".
    private func slugifiedTitle() -> String {
        let title = appStore.document?.title ?? ""
        var slug = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 60 {
            slug = String(slug.prefix(60))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "article" : slug
    }
}

/// Identity of the active document — web offline-copy state resets whenever the
/// tab or backing file changes. Mirrors ToolbarView's `DocumentKey` on macOS.
private struct DocumentKey_iOS: Hashable {
    var tabId: String?
    var path: String?

    @MainActor
    init(_ appStore: AppStore) {
        tabId = appStore.activeTabId
        path = appStore.document?.pdfPath
    }
}

// MARK: - Glass tool primitives

/// A Liquid Glass capsule that groups related buttons into one pod.
struct GlassToolPod<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
    }
}

/// A 44pt touch icon button; tints/fills when active.
struct GlassToolButton: View {
    let system: String
    let label: String
    var active = false
    var tint: Color? = nil
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background {
                    if active {
                        Circle().fill(palette.primary.opacity(0.16))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var foreground: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return active ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground)
    }
}

// MARK: - Tab strip

struct TabStrip_iOS: View {
    /// The pane this strip belongs to — carried in the tab drag payload so a
    /// drop on another pane knows where the tab came from.
    let paneId: String
    var onNewTab: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var joinTargeted = false

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(appStore.tabs) { tab in
                    TabChip_iOS(tab: tab, paneId: paneId, isActive: tab.id == appStore.activeTabId)
                }
                Button(action: onNewTab) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 40, height: 36)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New tab")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .background(.bar)
        // Dropping a tab onto this strip moves it into this pane's group. When
        // it empties the source pane, that pane collapses — this is how you undo
        // a split: drag one pane's tab into the other pane's tab strip.
        .background {
            if joinTargeted && workspace.draggingTab != nil {
                Rectangle().fill(palette.primary.opacity(0.16))
            }
        }
        .onDrop(of: [.vellumTab], isTargeted: $joinTargeted) { providers in
            guard let provider = providers.first else { return false }
            let targetPane = paneId
            let workspace = self.workspace
            _ = provider.loadDataRepresentation(for: .vellumTab) { data, _ in
                guard let data,
                      let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data) else { return }
                Task { @MainActor in
                    workspace.moveTab(tabId: payload.tabId, from: payload.paneId, to: targetPane)
                    workspace.endTabDrag()
                }
            }
            return true
        }
    }
}

private struct TabChip_iOS: View {
    let tab: PdfTab
    let paneId: String
    let isActive: Bool

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    private var title: String {
        if let doc = tab.document {
            if doc.kind == .web {
                return RecentFilesService.webpageDisplayName(for: doc.pdfPath)
            }
            return doc.title ?? RecentFilesService.fileName(for: doc.pdfPath)
        }
        return "New Tab"
    }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { appStore.activateTab(tab.id) }) {
                HStack(spacing: 6) {
                    Image(systemName: tab.document?.kind == .web ? "globe" : "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(
                            isActive ? AnyShapeStyle(palette.primary) : AnyShapeStyle(.secondary))
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isActive ? palette.foreground : palette.mutedForeground)
                        .frame(maxWidth: 160)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(isActive ? "Selected" : "")

            Button {
                Task { await appStore.closeTab(tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 44)
        .selectionSurface(selected: isActive, in: Capsule(), palette: palette)
        // Long-press lifts the chip into a drag; dropping on another pane's
        // strip joins that group, dropping on a pane edge splits it.
        .onDrag {
            let payload = TabDragPayload(paneId: paneId, tabId: tab.id)
            workspace.beginTabDrag(payload)
            let provider = NSItemProvider()
            if let data = try? JSONEncoder().encode(payload) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.vellumTab.identifier, visibility: .ownProcess
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        }
    }
}

// MARK: - Sidebar content (hosted by the adaptive inspector)

struct SidebarContent_iOS: View {
    /// The focused pane's ink controller, from the registry — nil only in the
    /// instant before that pane has appeared, so the Handwriting section just
    /// skips rendering rather than holding a stale controller.
    var ink: InkController_iOS?

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 0) {
            GlassSegmentedPicker(
                options: [
                    (WorkspaceStore.SidebarTab.annotations, "Annotations"),
                    (WorkspaceStore.SidebarTab.ai, "AI"),
                    (WorkspaceStore.SidebarTab.scratchpad, "Scratchpad"),
                ],
                selection: Binding(
                    get: { workspace.sidebarTab },
                    set: { workspace.sidebarTab = $0 }
                ),
                accessibilityIdentifierPrefix: "sidebarTab"
            )
            .padding(.vertical, 10)
            Divider()
            // All three panels stay mounted; only visibility toggles as the tab
            // changes. Keeping them alive (rather than switching, which destroys
            // the inactive ones) preserves each panel's transient view state
            // across tab flips — the scratchpad editor's caret/scroll/selection
            // in its live-preview WebView (a reload on every visit would flash
            // and lose the caret), and the AI panel's scroll/composer draft. The
            // persisted text itself already survives via the stores; this keeps
            // the *view* state the stores don't hold.
            ZStack {
                panel(.annotations) {
                    VStack(spacing: 0) {
                        if let ink {
                            InkPagesSection_iOS(ink: ink)
                        }
                        AnnotationSidebar()
                    }
                }
                panel(.ai) { AiPanel_iOS() }
                panel(.scratchpad) { ScratchpadPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.surface)
    }

    /// Wraps a sidebar panel so only the active tab is visible, hit-testable,
    /// and exposed to accessibility — the inactive panels stay mounted but
    /// inert (mirrors macOS `WindowChrome.panel`).
    @ViewBuilder
    private func panel<Content: View>(
        _ tab: WorkspaceStore.SidebarTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isActive = workspace.sidebarTab == tab
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

/// Handwritten-ink summary for the annotations sidebar: one jump-to-page row
/// per inked page. Ink lives outside the shared Annotation model (it's stored
/// as native /Ink in the PDF), so this section derives straight from the
/// display document.
private struct InkPagesSection_iOS: View {
    var ink: InkController_iOS

    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    private var pagesWithInk: [Int] {
        // drawingVersion ties this computed list to live stroke edits.
        _ = ink.drawingVersion
        guard appStore.document?.kind == .pdf,
              let document = ink.pdfController?.document else { return [] }
        return (0..<document.pageCount).compactMap { index in
            let pageNumber = index + 1
            // A cached canvas is the live source of truth for its page; only fall
            // back to the display document's native ink when no canvas exists yet.
            if let hasStrokes = ink.inkProvider.cachedStrokes(forPage: pageNumber) {
                return hasStrokes ? pageNumber : nil
            }
            guard let page = document.page(at: index) else { return nil }
            return PdfInk.hasInk(on: page) ? pageNumber : nil
        }
    }

    var body: some View {
        let pages = pagesWithInk
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Handwriting")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(palette.mutedForeground)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pages, id: \.self) { page in
                            Button {
                                appStore.goToPage(page)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "pencil.and.scribble")
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.primary)
                                    Text("p. \(page)")
                                        .font(.system(size: 13, weight: .medium))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.foreground)
                                }
                                .padding(.horizontal, 12)
                                .frame(height: 34)
                                .background(palette.muted, in: Capsule())
                                .overlay(Capsule().strokeBorder(palette.border))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Handwriting on page \(page). Tap to jump.")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
#endif
