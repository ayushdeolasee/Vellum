import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(WorkspaceStore.self) private var workspace

    @State private var keyMonitor: Any?
    /// Whether this window is currently showing a sheet, so the focus value
    /// below can go away while one is up (issue #98).
    @State private var sheets = SheetPresenceMonitor()
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
        WindowChrome(
            sidebarHovering: $sidebarHovering,
            initialColumnWidth: workspace.sidebarWidth)
            // BEFORE the `.environment` writes below, so those writes are applied
            // OUTSIDE this presentation and the sheet's content inherits them.
            // Modifiers compose outside-in: a `.sheet` chained *after* an
            // `.environment` sits above it, so `AddWebpageSheet`'s
            // `@Environment(AppStore.self)` would find nothing and SwiftUI would
            // trap the moment the sheet is presented.
            .sheet(isPresented: $addWebpagePresented) {
                AddWebpageSheet()
            }
            .environment(focused.app)
            .environment(focused.annotations)
            .environment(focused.ai)
            .environment(focused.scratchpad)
            .task { await workspace.restoreFromDisk() }
            .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
                addWebpagePresented = true
            }
            // Every sheet on this window, whoever presents it — the two
            // first-run sheets in `VellumApp`, this one, the rename and export
            // sheets deeper in the tree, and the ones Vellum does not own at
            // all (`.fileImporter`'s open panel, PDFKit's print panel).
            // `SheetPresenceMonitor` explains why this asks AppKit rather than
            // watching presentation flags.
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.willBeginSheetNotification)
            ) { notification in
                sheets.noteSheetBegan(on: notification.object as? NSWindow, host: hostWindow)
            }
            .onReceive(
                NotificationCenter.default.publisher(for: NSWindow.didEndSheetNotification)
            ) { notification in
                sheets.noteSheetEnded(on: notification.object as? NSWindow, host: hostWindow)
            }
            // Commands belong to the main window, not whichever nested
            // PDFKit/WebKit/AppKit responder happens to own keyboard focus.
            // A scene-focused value remains available throughout this window
            // and automatically disappears when Settings becomes key.
            //
            // ...and while a sheet is up, because a sheet belongs to the scene
            // that presents it and so does NOT displace a scene value the way
            // it displaced the old view-focused one. Publishing nil disables
            // every document command for as long as the sheet is attached; a
            // disabled item does not claim its key equivalent, so ⌘W stops
            // closing the tab behind the sheet (issue #98).
            .focusedSceneValue(
                \.vellumFocus, sheets.sheetPresented ? nil : VellumFocus(workspace: workspace))
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
        if let bundle = UTType(filenameExtension: "vellum") { types.append(bundle) }
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

    /// The `ideal:` handed to `.inspectorColumnWidth`, held FROZEN for as long as
    /// the column is on screen.
    ///
    /// This is belt-and-braces, not the resize bug itself — that was the
    /// modifier ORDER, documented at the call site. But it becomes load-bearing
    /// the moment the envelope actually reaches the inspector host, so it lands
    /// with it: `ideal:` must not be `workspace.sidebarWidth` read live.
    /// SwiftUI re-applies `ideal:` to the column whenever that argument changes
    /// between updates, and `.onGeometryChange` below writes every width it
    /// measures back into the store — so a live read closes a loop through
    /// AppKit's layout, and a body re-run landing mid-drag re-applies a stale
    /// width over the one the user is dragging to.
    ///
    /// `sidebarWidth` being `@ObservationIgnored` does not cover this on its
    /// own: it only stops the *store write* from invalidating the view.
    /// Anything else that re-runs this body — hovering the panel, a toolbar
    /// change, a tab switch — still re-reads the property and hands SwiftUI a
    /// new `ideal:`.
    ///
    /// Re-seeded from the store in `.onChange` below only when the column is
    /// (re)presented, which is the one moment `ideal:` is legitimately
    /// consulted — so reopening a document still restores the user's width.
    @State private var idealColumnWidth: CGFloat

    init(sidebarHovering: Binding<Bool>, initialColumnWidth: CGFloat) {
        _sidebarHovering = sidebarHovering
        _idealColumnWidth = State(initialValue: initialColumnWidth)
    }

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
        // Only over a document. Home renders the same `app.error` in its own
        // banner (#68), so an unconditional overlay would show every error
        // twice — including the terminal Save As rollback, which is precisely
        // the case that ends up back on Home.
        .overlay(alignment: .top) {
            if focused.app.document != nil, let error = focused.app.error {
                DocumentErrorNotice(message: error) {
                    focused.app.error = nil
                }
                .padding(.top, 12)
            }
        }
        .toolbar {
            VellumToolbar()
        }
        .inspector(isPresented: inspectorPresented) {
            // The whole column, switcher header included, is one view: the
            // header used to be assembled here, above `SidebarPanelStack`, which
            // left it outside the stack's AppKit drop catcher and so made the
            // inspector's top ~46pt the one strip of the sidebar that refused
            // drags (issue #101). `SidebarPanelStack` now owns the switcher and
            // documents why it lives inside the inspector at all.
            sidebar
                // Feeds the user's splitter drag back to the store so the next
                // document reopens the column where they left it. The store
                // rejects the collapsed measurements a start tab produces. Safe
                // to write from here only because `ideal:` below is frozen —
                // see `idealColumnWidth`.
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    workspace.rememberSidebarWidth(width)
                }
                // MUST STAY THE OUTERMOST MODIFIER ON THE INSPECTOR CONTENT.
                // This is not a style preference: the column-width envelope is a
                // view trait the inspector host reads off the ROOT of this
                // closure, and it does not survive being wrapped. With
                // `.onGeometryChange` applied after it (as it was), the trait
                // was invisible to the host, which then fell back to its
                // built-in 270pt column and — far worse — registered NO min/max
                // envelope, so AppKit gave the divider nothing to drag between
                // and the side panel could not be resized at all. Measured:
                // identical 270pt column whether this said 280/360/700 or
                // 450/500/700; moved out here, the column lands on exactly the
                // width asked for.
                .inspectorColumnWidth(
                    min: InspectorLayout.minimumWidth,
                    ideal: idealColumnWidth,
                    max: InspectorLayout.maximumWidth)
        }
        // The column is inserted (and `ideal:` consulted) when this flips true,
        // so this is the one safe moment to adopt the width the user last left.
        // Reading the store anywhere else would re-open the loop described on
        // `idealColumnWidth`.
        .onChange(of: workspace.inspectorPresented) { _, isPresented in
            if isPresented { idealColumnWidth = workspace.sidebarWidth }
        }
    }

    /// Inspector only makes sense with a document in the focused pane; the open
    /// state itself is window-global (WorkspaceStore) so it survives focus and
    /// start-tab changes.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { workspace.inspectorPresented },
            set: { workspace.setInspectorPresented($0) }
        )
    }

    private var sidebar: some View {
        SidebarPanelStack()
            .onHover { sidebarHovering = $0 }
    }
}

/// Document-action failures stay visible in whichever surface remains after
/// the action. In particular, a terminal Save As rollback can close the last
/// tab and leave this pane on Home.
private struct DocumentErrorNotice: View {
    @Environment(\.palette) private var palette
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .lineLimit(3)
            Button(action: dismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss error")
        }
        .font(.system(size: 12))
        .foregroundStyle(palette.destructive)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(palette.destructive.opacity(0.12), in: Capsule())
        .overlay {
            Capsule().strokeBorder(palette.destructive.opacity(0.3))
        }
        .padding(.horizontal, 24)
        .accessibilityIdentifier("document.errorNotice")
    }
}

/// The whole inspector column: the tab switcher header, then the three sidebar
/// panels. All three panels stay mounted in a ZStack; only their
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
/// The header is assembled HERE rather than by the caller so that it sits under
/// the same catcher overlay as the panels. Built above it — as it was until
/// #101 — the switcher row was the one strip of the inspector that would not
/// take a drop, because the catcher's NSView only ever covered the panels.
///
/// Two deliberate consequences of that move: the drop outline now traces the
/// whole column rather than stopping under the header, and the caller's
/// `.onHover` (which arms the ⌘+/⌘− sidebar text sizing) now covers the header
/// too — right, since the header is part of the sidebar, but it does mean ⌘+
/// over the switcher resizes sidebar text instead of zooming the document.
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
        VStack(spacing: 0) {
            // The tab switcher lives INSIDE the inspector, not in its window
            // toolbar: AppKit collapses toolbar items into an overflow menu at
            // narrow window widths, and that synthesized overflow exposed only
            // one of the three sections — so a narrow window could strand the
            // user on whichever panel was already selected. Here every
            // destination stays reachable at every width.
            InspectorTabSwitcher(selection: sidebarTabBinding)
                .padding(.horizontal, InspectorLayout.switcherHorizontalPadding)
                .padding(.vertical, InspectorLayout.switcherVerticalPadding)
            Divider()
            ZStack {
                panel(.annotations) { AnnotationSidebar() }
                panel(.ai) { AiPanel() }
                panel(.scratchpad) { ScratchpadPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        //
        // Overlaid on the VStack, so it spans the switcher header too. The
        // catcher's `hitTest` returns nil for every point, so the header's
        // buttons keep receiving clicks exactly as the panels' controls do.
        .overlay {
            SidebarDropCatcher(
                resolveOperation: resolveDropOperation,
                onTargeted: { dropTargeted = $0 },
                onDrop: routeDrop)
        }
    }

    private var sidebarTabBinding: Binding<WorkspaceStore.SidebarTab> {
        Binding(
            get: { workspace.sidebarTab },
            set: { workspace.sidebarTab = $0 }
        )
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
