import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bundle of the stores the menu commands act on, published as a scene-focused
/// value by the main window's `ContentView`. `@FocusedValue` reads the value
/// from the key scene, so nested PDFKit/WebKit responders cannot make the menu
/// lose its target. When Settings (which does not publish the value) is key,
/// the value is nil and document commands disable.
struct VellumFocus: Equatable {
    var workspace: WorkspaceStore

    // Compare by object identity so re-publishing the same workspace each render
    // does not thrash SwiftUI's focus machinery. The focused pane is resolved
    // live off the workspace, so commands always target the current pane.
    static func == (lhs: VellumFocus, rhs: VellumFocus) -> Bool {
        lhs.workspace === rhs.workspace
    }
}

private struct VellumFocusKey: FocusedValueKey {
    typealias Value = VellumFocus
}

extension FocusedValues {
    var vellumFocus: VellumFocus? {
        get { self[VellumFocusKey.self] }
        set { self[VellumFocusKey.self] = newValue }
    }
}

/// The real native command/menu surface (audit P0 "Add a real native command
/// and menu model"). Everything routes to the focused main window; the local
/// NSEvent monitor in ContentView now only handles what menus cannot express
/// (bare N for note mode, Escape, and the pointer-contextual sidebar font size).
struct VellumCommands: Commands {
    @FocusedValue(\.vellumFocus) private var focus
    /// Only used by the Help menu. The Help centre is a scene of its own rather
    /// than a sheet, so it is opened by id instead of by a presentation flag.
    @Environment(\.openWindow) private var openWindow
    /// The update commands are app-global rather than focused-document scoped:
    /// the app owns exactly one window and one `WorkspaceStore`, so they are
    /// injected directly instead of read from `vellumFocus`, which would make
    /// them go dead whenever Settings or the Help centre is key.
    let appWorkspace: WorkspaceStore

    // MARK: Availability (drives menu validation)

    private var hasFocus: Bool { focus != nil }
    private var workspace: WorkspaceStore? { focus?.workspace }
    private var appStore: AppStore? { focus?.workspace.focusedPane.app }
    private var annotationStore: AnnotationStore? { focus?.workspace.focusedPane.annotations }
    private var hasDocument: Bool { appStore?.document != nil }
    private var isSplit: Bool { workspace?.isSplit ?? false }
    /// Any tab at all, including a document-less start tab — Close Tab must
    /// work on a lone start tab too, not just on open documents.
    private var hasTab: Bool { !(appStore?.tabs.isEmpty ?? true) }
    private var isWeb: Bool { appStore?.document?.kind == .web }
    private var isPdf: Bool { hasDocument && !isWeb }
    private var findVisible: Bool { appStore?.findVisible ?? false }

    var body: some Commands {
        // MARK: App-wide
        // This remains available with a document open, unlike the Home toolbar
        // control, and shares its durable state with that control.
        CommandGroup(after: .appInfo) {
            if appWorkspace.updateChecker.state == .available,
               let version = appWorkspace.updateChecker.availableVersion {
                Button("Install Update \(version)", action: appWorkspace.updateChecker.install)
            }
            Button("Check for Updates…") {
                Task { await appWorkspace.updateChecker.check() }
            }
            .disabled(appWorkspace.updateChecker.state == .checking)
        }

        // MARK: File
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { appStore?.newStartTab() }
                .keyboardShortcut("t", modifiers: .command)
                .disabled(!hasFocus)

            Button("Open…") { openPanel() }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(!hasFocus)

            Button("Add Webpage…") {
                NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(!hasFocus)

            Divider()

            Button("Close Tab") {
                if let appStore { Task { await appStore.closeFile() } }
            }
            .keyboardShortcut("w", modifiers: .command)
            .disabled(!hasTab)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") { appStore?.printDocument() }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(!hasDocument)
        }

        // MARK: Edit → Find
        CommandGroup(after: .textEditing) {
            Button("Find…") { appStore?.showFind() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(!hasDocument)

            Button("Find Next") { appStore?.findNext() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(!findVisible)

            Button("Find Previous") { appStore?.findPrev() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(!findVisible)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Save") {
                guard let appStore, let sessionId = appStore.activeTabId else { return }
                Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
            }
            .keyboardShortcut("s", modifiers: .command)
            // Save writes annotations back into the PDF; web tabs persist via
            // export, not Save, so the command is PDF-only.
            .disabled(!isPdf)
        }

        // MARK: View (zoom + inspector live alongside the built-in sidebar group)
        CommandGroup(after: .sidebar) {
            Button("Zoom In") { appStore?.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(!hasDocument)

            Button("Zoom Out") { appStore?.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(!hasDocument)

            Button("Actual Size") { appStore?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(!hasDocument)

            Divider()

            Button(inspectorOpen ? "Hide Inspector" : "Show Inspector") {
                workspace?.sidebarOpen.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!hasDocument)

            Divider()

            // Split shortcuts avoid the arrow keys, which ⌘⌥↑/↓ already use for
            // First/Last Page. ⌘\ mirrors VS Code's "Split Editor".
            Button("Split Right") { workspace?.splitFocused(.horizontal) }
                .keyboardShortcut("\\", modifiers: .command)
                .disabled(!hasFocus)

            Button("Split Down") { workspace?.splitFocused(.vertical) }
                .keyboardShortcut("\\", modifiers: [.command, .option])
                .disabled(!hasFocus)

            Button("Merge Panes") { workspace?.mergeAll() }
                .keyboardShortcut("j", modifiers: [.command, .option])
                .disabled(!isSplit)

            Button("Close Pane") { if let workspace { workspace.closePane(workspace.focusedPaneId) } }
                .keyboardShortcut("\\", modifiers: [.command, .shift])
                .disabled(!isSplit)
        }

        // MARK: Navigate
        CommandMenu("Navigate") {
            // PDF page navigation.
            Button("Previous Page") { goToPage(-1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!isPdf || (appStore?.currentPage ?? 1) <= 1)

            Button("Next Page") { goToPage(1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!isPdf || (appStore?.currentPage ?? 0) >= (appStore?.numPages ?? 0))

            Button("First Page") { appStore?.goToPage(1) }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!isPdf)

            Button("Last Page") { appStore.map { $0.goToPage($0.numPages) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!isPdf)

            Divider()

            // Web in-page history.
            Button("Back") { webHistory(-1) }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(!isWeb)

            Button("Forward") { webHistory(1) }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(!isWeb)

            Divider()

            // Tab cycling ⌘⇧[ / ⌘⇧], wrapping at the ends across any mix of
            // PDF / web / start tabs.
            Button("Show Previous Tab") { appStore?.cycleTab(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled((appStore?.tabs.count ?? 0) < 2)

            Button("Show Next Tab") { appStore?.cycleTab(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled((appStore?.tabs.count ?? 0) < 2)

            Divider()

            // Tab switching ⌘1…⌘9.
            ForEach(1...9, id: \.self) { number in
                Button(tabTitle(index: number - 1)) { activateTab(index: number - 1) }
                    .keyboardShortcut(
                        KeyEquivalent(Character("\(number)")), modifiers: .command)
                    .disabled(!tabExists(index: number - 1))
            }
        }

        // MARK: Help
        // Replaces the stock "Vellum Help" item, which opens Help Viewer and
        // reports that no help book is installed — Vellum ships none (there is
        // no CFBundleHelpBookName in Info.plist and nothing calls
        // NSHelpManager, so nothing depended on the item being there).
        //
        // Two items, because they answer two different questions. "Vellum Help"
        // is the searchable reference and keeps the stock item's name and its
        // ⌘? key equivalent, so muscle memory lands somewhere sensible rather
        // than on a tour a returning user has already seen. "Vellum
        // Walkthrough" is the first-run tour, replayable but unbound — it is
        // the rarer of the two once you have used the app once.
        //
        // Neither is gated on `hasFocus`: unlike every command above, these
        // target no document, and someone who has just closed their last tab is
        // exactly who wants them.
        CommandGroup(replacing: .help) {
            Button("Vellum Help") { openWindow(id: HelpScene.windowId) }
                .keyboardShortcut("?", modifiers: .command)

            Button("Vellum Walkthrough") {
                NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
            }
        }

        // MARK: Annotations
        CommandMenu("Annotations") {
            Button(isBookmarked ? "Remove Bookmark Position" : "Bookmark Position") {
                if let store = annotationStore { Task { await store.toggleBookmark() } }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!hasDocument)
        }
    }

    // MARK: - Derived state

    private var inspectorOpen: Bool {
        guard let appStore, let workspace else { return false }
        return appStore.document != nil && workspace.sidebarOpen
    }

    private var isBookmarked: Bool {
        guard let appStore, let store = annotationStore else { return false }
        return findCurrentBookmark(
            annotations: store.annotations,
            docKind: appStore.document?.kind,
            currentPage: appStore.currentPage,
            webVisibleBookmarks: appStore.webVisibleBookmarks
        ) != nil
    }

    private func tabExists(index: Int) -> Bool {
        appStore?.tabs.indices.contains(index) ?? false
    }

    private func tabTitle(index: Int) -> String {
        guard let appStore, appStore.tabs.indices.contains(index) else {
            return "Tab \(index + 1)"
        }
        let tab = appStore.tabs[index]
        guard let document = tab.document else { return "New Tab" }
        let title = document.title ?? ""
        return title.isEmpty ? "Tab \(index + 1)" : title
    }

    // MARK: - Actions

    private func goToPage(_ delta: Int) {
        guard let appStore else { return }
        appStore.goToPage(appStore.currentPage + delta)
    }

    private func webHistory(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }

    private func activateTab(index: Int) {
        guard let appStore, appStore.tabs.indices.contains(index) else { return }
        appStore.activateTab(appStore.tabs[index].id)
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") { types.append(archive) }
        if let bundle = UTType(filenameExtension: "vellum") { types.append(bundle) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        if let appStore { Task { await appStore.openFiles(paths: paths) } }
    }
}
