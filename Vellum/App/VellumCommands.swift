import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Bundle of the stores the menu commands act on, published as a focused value
/// by the main window's `ContentView`. Routing through `@FocusedValue` gives us
/// free menu validation: when the Settings window (or any scene that does not
/// publish this value) is key, the value is nil and every command disables.
struct VellumFocus: Equatable {
    var appStore: AppStore
    var annotationStore: AnnotationStore

    // Compare by object identity so re-publishing the same singletons each
    // render does not thrash SwiftUI's focus machinery.
    static func == (lhs: VellumFocus, rhs: VellumFocus) -> Bool {
        lhs.appStore === rhs.appStore && lhs.annotationStore === rhs.annotationStore
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

    // MARK: Availability (drives menu validation)

    private var hasFocus: Bool { focus != nil }
    private var appStore: AppStore? { focus?.appStore }
    private var hasDocument: Bool { appStore?.document != nil }
    private var isWeb: Bool { appStore?.document?.kind == .web }
    private var isPdf: Bool { hasDocument && !isWeb }

    var body: some Commands {
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
            .disabled(!hasDocument)
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
                appStore?.sidebarOpen.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .disabled(!hasDocument)
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

        // MARK: Annotations
        CommandMenu("Annotations") {
            Button(isBookmarked ? "Remove Bookmark" : "Bookmark Page") {
                if let store = focus?.annotationStore { Task { await store.toggleBookmark() } }
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!hasDocument)
        }
    }

    // MARK: - Derived state

    private var inspectorOpen: Bool {
        guard let appStore else { return false }
        return appStore.document != nil && appStore.sidebarOpen
    }

    private var isBookmarked: Bool {
        guard let appStore, let store = focus?.annotationStore else { return false }
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
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        if let appStore { Task { await appStore.openFiles(paths: paths) } }
    }
}
