#if os(iOS)
import SwiftUI

/// Root shell for the iPad app. Empty state shows the full-screen library;
/// once documents are open it becomes the split-screen pane tree — each pane a
/// tabbed reader with its own Liquid Glass toolbar — plus one adaptive
/// inspector sidebar bound to the focused pane. File pickers and sheets are
/// presented here, at the shell, and route to the focused pane.
struct ContentView_iOS: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(ThemeStore.self) private var themeStore
    @Environment(InkRegistry_iOS.self) private var inkRegistry
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var addWebpagePresented = false
    @State private var isImporting = false

    /// The pane the single inspector sidebar and shell-level pickers act on.
    private var focused: PaneModel { workspace.focusedPane }

    var body: some View {
        // The focused pane's store-triple is injected here, as an ANCESTOR of
        // the subview that declares `.inspector` — inspector content is hosted
        // separately and only inherits ancestor environment (same trap as the
        // macOS toolbar). Each pane's subtree re-injects its own triple.
        PaneShell_iOS(
            onOpenFile: { presentImporter() },
            onAddWebpage: { addWebpagePresented = true },
            initialColumnWidth: workspace.sidebarWidth
        )
        .environment(focused.app)
        .environment(focused.annotations)
        .environment(focused.ai)
        .environment(focused.scratchpad)
        .environment(inkRegistry)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.12).ignoresSafeArea()
                    ProgressView("Importing PDF…")
                        .padding(.horizontal, 24)
                        .padding(.vertical, 18)
                        .background(.regularMaterial, in: .rect(cornerRadius: Radius.md))
                }
            }
        }
        .task { await workspace.restoreFromDisk() }
        // Warm the document-picker subsystem shortly after launch so the first
        // "Open a PDF" tap doesn't pay the multi-second service-discovery cost.
        .task {
            try? await Task.sleep(for: .seconds(1))
            DocumentPickerCoordinator_iOS.shared.prewarm()
        }
        // `AddWebpageSheet_iOS` takes its destination as a closure and reads no
        // store from the environment — deliberately. macOS's equivalent read
        // `@Environment(AppStore.self)` and trapped when this `.sheet` was
        // chained after the `.environment` writes (modifiers compose
        // outside-in, so the presentation sat above them — main PR #116). Keep
        // the closure form, or move this `.sheet` above the `.environment`
        // block before adding any store lookup inside the sheet.
        .sheet(isPresented: $addWebpagePresented) {
            AddWebpageSheet_iOS { url in
                let app = workspace.focusedPane.app
                Task { await app.openUrl(url) }
            }
        }
        // Keyboard-shortcut / pane routing: ⌘O and every pane's "Open File…"
        // post here since panes and Commands structs can't drive this view's
        // presentation themselves.
        .onReceive(NotificationCenter.default.publisher(for: .vellumOpenFile)) { note in
            // A payload means "open these files" (a Files-app open routed here
            // by VellumApp_iOS); no payload keeps the original meaning,
            // "present the importer" (⌘O and a pane's Open File…).
            if let paths = note.userInfo?["paths"] as? [String], !paths.isEmpty {
                let app = workspace.focusedPane.app
                Task { await app.openFiles(paths: paths) }
            } else {
                presentImporter()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
            addWebpagePresented = true
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            themeStore.systemAppearanceChanged(isDark: scheme == .dark)
        }
        #if DEBUG
        .task { await autoOpenForTesting() }
        #endif
    }

    private func presentImporter() {
        // The picker belongs to the pane that presented it. Focus may move to
        // the other pane while security-scoped files are being copied, so
        // capture the destination before any asynchronous work begins.
        let app = workspace.focusedPane.app
        DocumentPickerCoordinator_iOS.shared.present { urls in
            Task { @MainActor in
                isImporting = true
                defer { isImporting = false }
                let paths = await Task.detached(priority: .userInitiated) {
                    DocumentImport.importPicked(urls)
                }.value
                guard !paths.isEmpty else { return }
                await app.openFiles(paths: paths)
            }
        }
    }

    #if DEBUG
    private func autoOpenForTesting() async {
        let app = focused.app
        guard app.document == nil, app.tabs.isEmpty else { return }
        if let url = ProcessInfo.processInfo.environment["VELLUM_AUTOOPEN_URL"] {
            await app.openUrl(url)
            await autoSplitForTesting()
            return
        }
        guard let path = ProcessInfo.processInfo.environment["VELLUM_AUTOOPEN_PDF"],
              FileManager.default.fileExists(atPath: path) else { return }
        let paths = DocumentImport.importPicked([URL(fileURLWithPath: path)])
        guard !paths.isEmpty else { return }
        await app.openFiles(paths: paths)
        await autoSplitForTesting()
    }

    /// QA hook: headless environments can't synthesize touches, so this stands
    /// in for the More-menu "Split Right" tap when VELLUM_AUTOSPLIT is set.
    private func autoSplitForTesting() async {
        guard ProcessInfo.processInfo.environment["VELLUM_AUTOSPLIT"] != nil,
              !workspace.isSplit else { return }
        try? await Task.sleep(for: .seconds(1))
        workspace.splitFocused(.horizontal)
    }
    #endif
}

// MARK: - Pane shell

/// Hosts the pane tree (or the full-screen library when nothing is open) and
/// declares the one inspector sidebar, bound to the focused pane's stores.
private struct PaneShell_iOS: View {
    var onOpenFile: () -> Void
    var onAddWebpage: () -> Void

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(InkRegistry_iOS.self) private var inkRegistry

    /// The width the inspector column opens at, frozen in `@State` rather than
    /// read live from `workspace.sidebarWidth`.
    ///
    /// SwiftUI re-applies `ideal:` to the column whenever that argument changes
    /// between updates, and `.onGeometryChange` below writes every width it
    /// measures back into the store — so a live read closes a loop through the
    /// layout system, and a body re-run landing mid-drag re-applies a stale
    /// width over the one the user is dragging to.
    ///
    /// `sidebarWidth` being `@ObservationIgnored` does not cover this on its
    /// own: it only stops the *store write* from invalidating the view. Anything
    /// else that re-runs this body — a toolbar change, a tab switch — would
    /// still re-read the property and hand SwiftUI a new `ideal:`.
    ///
    /// Re-seeded from the store in `.onChange` below only when the column is
    /// (re)presented, which is the one moment `ideal:` is legitimately
    /// consulted — so reopening a document still restores the user's width.
    @State private var idealColumnWidth: CGFloat

    init(onOpenFile: @escaping () -> Void, onAddWebpage: @escaping () -> Void,
         initialColumnWidth: CGFloat) {
        self.onOpenFile = onOpenFile
        self.onAddWebpage = onAddWebpage
        _idealColumnWidth = State(initialValue: initialColumnWidth)
    }

    private var focused: PaneModel { workspace.focusedPane }

    var body: some View {
        Group {
            if !workspace.isSplit && focused.app.tabs.isEmpty {
                WelcomeLibrary_iOS(
                    onOpen: onOpenFile,
                    onAddWebpage: onAddWebpage,
                    store: focused.homeSearch)
            } else {
                PaneTreeView(node: workspace.root)
            }
        }
        .inspector(isPresented: inspectorPresented) {
            SidebarContent_iOS(ink: inkRegistry.controllers[workspace.focusedPaneId])
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                    workspace.rememberSidebarWidth(width)
                }
                // MUST STAY THE OUTERMOST MODIFIER ON THE INSPECTOR CONTENT —
                // the column-width envelope is a view trait read off the ROOT of
                // this closure and does not survive being wrapped. (Measured on
                // macOS in #122: with `.onGeometryChange` applied after it, the
                // host fell back to its built-in width and registered NO
                // min/max, so the divider had nothing to drag between.)
                .inspectorColumnWidth(
                    min: InspectorLayout.minimumWidth,
                    ideal: idealColumnWidth,
                    max: InspectorLayout.maximumWidth)
        }
        .onChange(of: workspace.inspectorPresented) { _, isPresented in
            if isPresented { idealColumnWidth = workspace.sidebarWidth }
        }
    }

    /// Inspector only makes sense with a document in the focused pane; the open
    /// state itself is window-global (WorkspaceStore) so it survives focus
    /// changes. `setInspectorPresented` is what makes that true: when focus
    /// moves to a start tab SwiftUI writes `false` because the inspector became
    /// conditionally unavailable, and the store ignores that write — so the
    /// user's chosen panel and column width survive a trip through Home.
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { workspace.inspectorPresented },
            set: { workspace.setInspectorPresented($0) }
        )
    }
}

// MARK: - Add webpage sheet

struct AddWebpageSheet_iOS: View {
    var onSubmit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var url = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Text("Enter a URL to read it in Vellum. The page is captured for offline reading and annotation.")
                    .font(.subheadline)
                    .foregroundStyle(palette.mutedForeground)
                TextField("https://example.com", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .font(.system(size: 17))
                    .focused($focused)
                    .onSubmit(submit)
                    .accessibilityIdentifier("addWebpage.urlField")
                Spacer()
            }
            .padding(20)
            .navigationTitle("Add Webpage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Open", action: submit)
                        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium])
    }

    private func submit() {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onSubmit(trimmed)
        dismiss()
    }
}
#endif
