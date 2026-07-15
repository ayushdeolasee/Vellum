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
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var addWebpagePresented = false
    @State private var inkRegistry = InkRegistry_iOS()

    /// The pane the single inspector sidebar and shell-level pickers act on.
    private var focused: PaneModel { workspace.focusedPane }

    var body: some View {
        // The focused pane's store-triple is injected here, as an ANCESTOR of
        // the subview that declares `.inspector` — inspector content is hosted
        // separately and only inherits ancestor environment (same trap as the
        // macOS toolbar). Each pane's subtree re-injects its own triple.
        PaneShell_iOS(
            onOpenFile: { presentImporter() },
            onAddWebpage: { addWebpagePresented = true }
        )
        .environment(focused.app)
        .environment(focused.annotations)
        .environment(focused.ai)
        .environment(focused.scratchpad)
        .environment(inkRegistry)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background.ignoresSafeArea())
        .task { await workspace.restoreFromDisk() }
        // Warm the document-picker subsystem shortly after launch so the first
        // "Open a PDF" tap doesn't pay the multi-second service-discovery cost.
        .task {
            try? await Task.sleep(for: .seconds(1))
            DocumentPickerCoordinator_iOS.shared.prewarm()
        }
        .sheet(isPresented: $addWebpagePresented) {
            AddWebpageSheet_iOS { url in
                let app = workspace.focusedPane.app
                Task { await app.openUrl(url) }
            }
        }
        // Keyboard-shortcut / pane routing: ⌘O and every pane's "Open File…"
        // post here since panes and Commands structs can't drive this view's
        // presentation themselves.
        .onReceive(NotificationCenter.default.publisher(for: .vellumOpenFile)) { _ in
            presentImporter()
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
        let workspace = self.workspace
        DocumentPickerCoordinator_iOS.shared.present { urls in
            let paths = DocumentImport.importPicked(urls)
            guard !paths.isEmpty else { return }
            let app = workspace.focusedPane.app
            Task { await app.openFiles(paths: paths) }
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

    private var focused: PaneModel { workspace.focusedPane }

    var body: some View {
        Group {
            if !workspace.isSplit && focused.app.tabs.isEmpty {
                WelcomeLibrary_iOS(onOpen: onOpenFile, onAddWebpage: onAddWebpage)
            } else {
                PaneTreeView(node: workspace.root)
            }
        }
        .inspector(isPresented: inspectorPresented) {
            SidebarContent_iOS(ink: inkRegistry.controllers[workspace.focusedPaneId])
                .inspectorColumnWidth(min: 280, ideal: 360, max: 560)
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
