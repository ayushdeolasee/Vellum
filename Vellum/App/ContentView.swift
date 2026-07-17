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
            .environment(focused.scratchpad)
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
        if responder is NSTextView || responder is NSTextField || responder is NSSearchField {
            return true
        }
        // The scratchpad editor is a WKWebView (CodeMirror), so typing there
        // makes a private WebKit content view first responder rather than an
        // NSTextView. Walk the responder's view ancestry for the scratchpad's
        // marker WebView so bare-key shortcuts (e.g. `N`) don't fire mid-edit.
        if let view = responder as? NSView {
            var ancestor: NSView? = view
            while let current = ancestor {
                if current is ScratchpadWebView { return true }
                ancestor = current.superview
            }
        }
        return false
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
                                    (WorkspaceStore.SidebarTab.scratchpad, "Scratchpad"),
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
        SidebarPanelStack()
            .onHover { sidebarHovering = $0 }
    }
}

/// The three sidebar panels, stacked. All three stay mounted in a ZStack; only
/// visibility toggles as the tab changes. Keeping them alive (rather than
/// switching, which destroys the inactive ones) preserves each panel's transient
/// state across tab flips — the AI panel's scroll position and half-typed
/// composer draft, and the scratchpad editor's caret/scroll/selection in its
/// live-preview WebView. The persisted text itself already survives via the
/// stores; this keeps the *view* state that the stores don't hold.
///
/// Trade-off mirrored from the AI panel: because the inactive panels no longer
/// unmount on a tab switch, their `onDisappear` fires only when the document
/// (and thus the inspector) closes — not when flipping tabs.
///
/// DRAG-AND-DROP: the whole sidebar has ONE drag destination — a plain AppKit
/// `SidebarDropView` overlaid via `SidebarDropCatcher`. It is NOT a SwiftUI
/// `.onDrop`: `.onDrop` proved unreliable inside the inspector's glass-effect
/// hosting view here — its hidden `_PlatformDraggingDestinationView` (registered
/// for the catch-all types regardless of the `of:` array) outranks the panels'
/// deeper AppKit views yet then refuses real file drags, so drops died with no
/// highlight (minimal repros of the same pattern work — cause never pinned; see
/// `SidebarDropCatcher`). Because that hidden catch-all view would steal and then
/// kill every sidebar drag, there must be NO `.onDrop` anywhere in the sidebar
/// subtree (AI / Scratchpad / Annotations panels). The panels' own AppKit drop
/// code (composer text views, the scratchpad WebView) stays as belt-and-braces
/// but is unreachable by design while the frontmost catcher is present.
///
/// Internal (not `private`) so `SidebarDropRoutingTests` can drive the real
/// stacked hierarchy headlessly.
struct SidebarPanelStack: View {
    @Environment(WorkspaceStore.self) private var workspace
    // The catcher's closures read the SAME store instances the visible panel
    // does — both come from the focused pane's environment injection
    // (ContentView), so a drop always lands in the store the user is looking at.
    @Environment(AiStore.self) private var aiStore
    @Environment(ScratchpadStore.self) private var scratchpadStore
    @Environment(\.palette) private var palette

    /// Drives the single sidebar drop outline, armed by the AppKit catcher's
    /// `onTargeted` callback. The AI panel additionally lights its own outline for
    /// drags that reach its AppKit composer/transcript views directly (only when
    /// the catcher overlay is absent).
    @State private var dropTargeted = false

    var body: some View {
        ZStack {
            panel(.annotations) { AnnotationSidebar() }
            panel(.ai) { AiPanel() }
            panel(.scratchpad) { ScratchpadPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(palette.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        // ONE drag destination for the whole sidebar — a drag-only AppKit overlay
        // (see `SidebarDropCatcher` for why not `.onDrop`). Its closures read the
        // visible tab LIVE at event time: annotations refuses (no attachment
        // target); AI and scratchpad accept an attachment-carrying drag and route
        // the payload to their store. A non-image dropped on the scratchpad still
        // reaches its handler and is explained.
        .overlay {
            SidebarDropCatcher(
                resolveOperation: resolveDropOperation,
                onTargeted: { dropTargeted = $0 },
                onDrop: routeDrop)
        }
    }

    /// The drag operation to report for the current tab, evaluated live when
    /// AppKit calls `draggingEntered`/`draggingUpdated`.
    private func resolveDropOperation(_ sender: NSDraggingInfo) -> NSDragOperation {
        switch workspace.sidebarTab {
        case .annotations:
            return []
        case .ai, .scratchpad:
            return AttachmentDrop.carriesAttachment(sender) ? .copy : []
        }
    }

    /// The one place a sidebar drop is handled: route the payload to whichever
    /// store owns the visible tab. Annotations has no drop support, so it refuses
    /// (belt-and-braces — `resolveDropOperation` already refused it above).
    private func routeDrop(_ payload: AttachmentDropPayload) -> Bool {
        switch workspace.sidebarTab {
        case .ai: return aiStore.handleDrop(payload)
        case .scratchpad: return scratchpadStore.handleDrop(payload)
        case .annotations: return false
        }
    }

    /// Wraps a sidebar panel so only the active tab is visible, hit-testable,
    /// and exposed to accessibility — the inactive panels stay mounted but
    /// inert.
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
