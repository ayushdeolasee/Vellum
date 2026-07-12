import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @State private var keyMonitor: Any?
    @State private var sidebarHovering = false
    @State private var addWebpagePresented = false
    @State private var hostWindow: NSWindow?

    /// The pane the single toolbar, inspector, find bar, and menu commands act on.
    private var focused: PaneModel { workspace.focusedPane }

    var body: some View {
        // The focused pane's store-triple is injected here, as an ANCESTOR of the
        // subview that declares `.toolbar`/`.inspector`. Toolbar/inspector content
        // is hosted separately and only inherits ancestor environment — injecting
        // inside WindowChrome's own body would leave the toolbar without an
        // AppStore. Each pane's subtree re-injects its own triple, overriding this.
        WindowChrome(sidebarHovering: $sidebarHovering)
            .environment(focused.app)
            .environment(focused.annotations)
            .environment(focused.ai)
            .task { await workspace.restoreFromDisk() }
            .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
                addWebpagePresented = true
            }
            .sheet(isPresented: $addWebpagePresented) {
                AddWebpageSheet()
            }
            .focusedValue(\.vellumFocus, VellumFocus(workspace: workspace))
            .background(WindowAccessor { hostWindow = $0 })
            .onAppear(perform: installKeyMonitor)
            .onDisappear(perform: removeKeyMonitor)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Returns true when the event matches a Vellum shortcut and must not be
    /// passed on to AppKit. Everything document-scoped routes to the *focused*
    /// pane's store; sidebar text size is window-global (WorkspaceStore).
    ///
    /// The interactions handled here are the ones `.commands` cannot express,
    /// plus the ⌘-key shortcuts a focused PDFView/WKWebView can swallow via
    /// performKeyEquivalent before the menu ever sees them (⌘F/⌘G/⌘P/⌘L/⌘O and
    /// the tab-cycle chords).
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === hostWindow else { return false }
        let app = focused.app
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let key = event.charactersIgnoringModifiers ?? ""
        let lowerKey = key.lowercased()

        if (key == "\u{1b}" || event.keyCode == 53), app.findVisible {
            app.hideFind()
            return true
        }

        if modifiers == .command && lowerKey == "f" {
            guard app.document != nil else { return false }
            app.showFind()
            return true
        }
        if modifiers == [.command, .shift] && lowerKey == "g" {
            guard app.findVisible else { return false }
            app.findPrev()
            return true
        }
        if modifiers == .command && lowerKey == "g" {
            guard app.findVisible else { return false }
            app.findNext()
            return true
        }
        if modifiers == .command && lowerKey == "p" {
            guard app.document != nil else { return false }
            app.printDocument()
            return true
        }

        if modifiers == .command && key == "l" {
            NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            return true
        }
        if modifiers == .command && key == "o" {
            openFilePanel()
            return true
        }

        if modifiers == [.command, .shift] {
            if key == "[" || key == "{" {
                app.cycleTab(-1)
                return true
            }
            if key == "]" || key == "}" {
                app.cycleTab(1)
                return true
            }
        }

        // Sidebar text sizing: only intercept ⌘+/⌘− while hovering the open side
        // panel. Otherwise fall through so the View-menu zoom command handles it.
        if command && !modifiers.contains(.option) && (key == "=" || key == "+") {
            guard sidebarHovering && workspace.sidebarOpen else { return false }
            workspace.increaseSidebarFont()
            return true
        }
        if command && !modifiers.contains(.option) && key == "-" {
            guard sidebarHovering && workspace.sidebarOpen else { return false }
            workspace.decreaseSidebarFont()
            return true
        }
        if key == "\u{1b}" || event.keyCode == 53 {
            guard !isTextInputFirstResponder else { return false }
            focused.annotations.selectAnnotation(nil)
            app.setMode(.view)
            return false
        }
        if !command && !modifiers.contains(.control) && key == "n" {
            guard !isTextInputFirstResponder, app.document != nil else { return false }
            app.setMode(app.mode == .note ? .view : .note)
            return true
        }
        return false
    }

    private var isTextInputFirstResponder: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }

    /// Mirrors `VellumCommands.openPanel()`. Opens into the focused pane.
    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") { types.append(archive) }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        let app = focused.app
        Task { await app.openFiles(paths: paths) }
    }
}

/// The window chrome (find bar, pane tree, toolbar, inspector). Split out from
/// ContentView so the focused-pane environment injection lives on an ancestor of
/// the `.toolbar`/`.inspector` declarations — those are hosted separately and
/// only see ancestor environment.
private struct WindowChrome: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @Binding var sidebarHovering: Bool

    private var focused: PaneModel { workspace.focusedPane }

    var body: some View {
        VStack(spacing: 0) {
            if focused.app.findVisible && focused.app.document != nil {
                FindBar()
            }
            PaneTreeView(node: workspace.root)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .toolbar {
            VellumToolbar()
        }
        .inspector(isPresented: inspectorPresented) {
            sidebar
                .inspectorColumnWidth(min: 240, ideal: 340, max: 700)
                .toolbar {
                    if inspectorPresented.wrappedValue {
                        ToolbarSpacer(.flexible)
                        ToolbarItem {
                            GlassSegmentedPicker(
                                options: [
                                    (WorkspaceStore.SidebarTab.annotations, "Annotations"),
                                    (WorkspaceStore.SidebarTab.ai, "AI"),
                                ],
                                selection: sidebarTabBinding,
                                accessibilityIdentifierPrefix: "sidebarTab"
                            )
                        }
                        ToolbarSpacer(.flexible)
                    }
                }
        }
    }

    /// Inspector only makes sense with a document in the focused pane; the open
    /// state itself is window-global (WorkspaceStore) so it survives focus changes.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { focused.app.document != nil && workspace.sidebarOpen },
            set: { workspace.sidebarOpen = $0 }
        )
    }

    private var sidebarTabBinding: Binding<WorkspaceStore.SidebarTab> {
        Binding(
            get: { workspace.sidebarTab },
            set: { workspace.sidebarTab = $0 }
        )
    }

    private var sidebar: some View {
        Group {
            if workspace.sidebarTab == .annotations {
                AnnotationSidebar()
            } else {
                AiPanel()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onHover { sidebarHovering = $0 }
    }
}

/// Reports the NSWindow hosting this view so the key monitor can positively
/// identify events belonging to the main content window.
private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in onWindow(view?.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in onWindow(nsView?.window) }
    }
}
