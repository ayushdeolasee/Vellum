#if os(iOS)
import SwiftUI

/// The compact-width (iPhone) shell (#153).
///
/// Two routes, one window: Home (search-first library) and the reader (one
/// full-bleed document). There is no pane tree here and no inspector column —
/// the phone workspace is `.singlePane` by construction (D4) and the inspector
/// arrives as a sheet in P6. What this view owns is everything that has to sit
/// ABOVE both routes: the pane's store-triple, the ink registry, the shell
/// store, the document-picker/import plumbing, and the notification channels
/// `ContentView_iOS` serves on the iPad (only one of the two shells is ever
/// mounted, so each has to carry the whole set).
///
/// It is a thin wrapper so that `PhoneShellRoot_iOS` below can take the
/// `WorkspaceStore` as an init parameter: `PhoneShellStore` needs the workspace
/// at construction (it applies D3 there), and a `@State` cannot be seeded from
/// the environment in the same view that declares it.
struct PhoneShell_iOS: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        PhoneShellRoot_iOS(workspace: workspace)
    }
}

private struct PhoneShellRoot_iOS: View {
    /// Passed in rather than read from the environment here so it is available
    /// to `init`. Same object either way.
    let workspace: WorkspaceStore

    @Environment(InkRegistry_iOS.self) private var inkRegistry
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var shell: PhoneShellStore

    /// Home's corpus, held at the SHELL rather than inside the Home screen.
    ///
    /// Home is a route, so the screen is unmounted the moment a document opens
    /// and remounted on every visit. A store owned by the screen would be
    /// rebuilt — three disk walks and a re-index — each time the user came back
    /// from reading, which on a phone is constantly. Held here it outlives the
    /// route and a return to Home is a repaint.
    @State private var homeSearch = HomeSearchStore()

    @State private var addWebpagePresented = false
    @State private var isImporting = false

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
        _shell = State(initialValue: PhoneShellStore(workspace: workspace))
    }

    /// The one pane. `.singlePane` means `focusedPane` can never change out
    /// from under the shell, so unlike `ContentView_iOS` there is no "the
    /// picker belongs to the pane that presented it" hazard — but the
    /// destination is still captured before any `await` below, because that is
    /// cheap and the day this stops being single-pane is not the day anyone
    /// wants to rediscover why.
    private var pane: PaneModel { workspace.focusedPane }

    var body: some View {
        // The store-triple is injected as an ANCESTOR of both routes and of
        // every sheet the shell presents. Same trap `ContentView_iOS:22-26`
        // documents: presented content is hosted separately and only inherits
        // ancestor environment, so anything injected further down would be
        // invisible to the inspector sheet (P6) and to the tab switcher (P7).
        route
            .environment(pane.app)
            .environment(pane.annotations)
            .environment(pane.ai)
            .environment(pane.scratchpad)
            .environment(inkRegistry)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background.ignoresSafeArea())
            // Document-scoped store loading plus the sidecar-import /
            // data-deleted invalidation handlers, shared verbatim with the iPad
            // pane (`PaneDocumentState_iOS`). Applied at the SHELL, above the
            // route switch: mounted on the reader route alone it would be torn
            // down and rebuilt by every trip to Home, and its `.task(id:)`
            // clears the annotation/AI/scratchpad stores before reloading them
            // — so returning to a document would blank its highlights for a
            // beat and re-read three files, for a document that never closed.
            .paneDocumentState(pane: pane)
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
            // Warm the document-picker subsystem shortly after launch so the
            // first "Open a PDF" tap doesn't pay the multi-second
            // service-discovery cost.
            .task {
                try? await Task.sleep(for: .seconds(1))
                DocumentPickerCoordinator_iOS.shared.prewarm()
            }
            // Closure form, and no store read inside the sheet — see the
            // `ContentView_iOS:57-63` comment for the macOS crash that rule
            // comes from (modifiers compose outside-in, so a presentation
            // chained after the `.environment` writes sits above them).
            .sheet(isPresented: $addWebpagePresented) {
                AddWebpageSheet_iOS { url in
                    let app = pane.app
                    Task {
                        await app.openUrl(url)
                        shell.didOpenDocument()
                    }
                }
            }
            // The phone is an "Open in" / share-sheet destination and a
            // hardware ⌘O reaches it too. `ContentView_iOS` is the only other
            // listener on this channel and it is never in the tree here, so
            // without this a shared PDF would be copied into the library and
            // vanish.
            .onReceive(NotificationCenter.default.publisher(for: .vellumOpenFile)) { note in
                // A payload means "open these files" (a Files-app open routed
                // here by `VellumApp_iOS`); no payload keeps the original
                // meaning, "present the importer" (⌘O and Home's Open File).
                if let paths = note.userInfo?["paths"] as? [String], !paths.isEmpty {
                    let app = pane.app
                    Task {
                        await app.openFiles(paths: paths)
                        shell.didOpenDocument()
                    }
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
            // Safety net for opens the shell did not initiate: a Files-app
            // hand-off that raced the route, a restored session at launch, ⌘O,
            // later widgets and Spotlight. Home's own actions call
            // `didOpenDocument()` directly (they know when their `await`
            // finished); this catches everything else, including the tab
            // `restoreFromDisk` reactivates.
            .onChange(of: pane.app.activeTabId) { _, tabId in
                guard tabId != nil, pane.app.document != nil else { return }
                shell.didOpenDocument()
            }
            #if DEBUG
            .task { await autoOpenForTesting() }
            #endif
    }

    // MARK: - Routes

    @ViewBuilder
    private var route: some View {
        switch shell.route {
        case .home:
            homeRoute
        case .reader:
            readerRoute
        }
    }

    /// Home: search-first, phone-native (P4). The corpus is the shell-held one,
    /// so leaving and returning is a repaint rather than three disk walks.
    ///
    /// `onShowTabs` becomes `shell.switcherPresented = true` in P7, when there is
    /// a full-screen card grid to present. Until then it does the useful half of
    /// what that button will do — go back to the document — because Home only
    /// offers it when a document is open (see `PhoneHome_iOS.header`), and a
    /// visible control that does nothing is worse than one that does less.
    private var homeRoute: some View {
        PhoneHome_iOS(
            store: homeSearch,
            onOpen: { presentImporter() },
            onAddWebpage: { addWebpagePresented = true },
            onShowTabs: {
                guard pane.app.document != nil else { return }
                shell.showReader()
            })
    }

    /// The reader: the SAME multiplexed live-tab stack the iPad pane mounts
    /// (D7), not a single viewer keyed on `activeTabId` — the hot/warm/evicted
    /// states in `LiveTabStack_iOS` are what make the tab switcher instant.
    ///
    /// Full-bleed by `.ignoresSafeArea()`, and that is load-bearing rather than
    /// cosmetic: presenting the inspector sheet (P6) changes the safe-area
    /// insets the hosted `PDFView` sees, and a viewer whose frame depends on
    /// them relayouts and jumps the scroll position mid-drag.
    ///
    /// The page itself is fit to the viewport's width — declared once by
    /// `RootShell_iOS` as `.pdfZoomMode(.fitWidth)` (#152) and read by the
    /// viewer, not applied here as a zoom number. There is deliberately no
    /// zoom control in the phone chrome as a result.
    ///
    /// The chrome is a ZStack SIBLING of the stack rather than an `.overlay` on
    /// it: an overlay applied after `.ignoresSafeArea()` inherits the ignoring
    /// geometry, and the bars have to respect the safe area while the document
    /// under them must not.
    private var readerRoute: some View {
        ZStack {
            LiveTabStack_iOS(app: pane.app)
                .ignoresSafeArea()

            // Never in the touch path (see `ChromeTapCatcher_iOS`) — it is a
            // window-level recognizer plus a geometry probe, which is why it can
            // sit above the viewer without taking anything from it.
            ChromeTapCatcher_iOS(
                isActive: !shell.switcherPresented,
                chromeVisible: shell.chromeVisible
            ) {
                shell.toggleChrome()
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)

            PhoneReaderChrome_iOS(
                shell: shell,
                onOpenFile: { presentImporter() },
                onAddWebpage: { addWebpagePresented = true })
        }
        // Immersive reading is the absence of chrome, and that has to include
        // the system's own: the status bar and the home indicator are the two
        // remaining pieces of furniture over a full-bleed page.
        .statusBarHidden(!shell.chromeVisible)
        .persistentSystemOverlays(shell.chromeVisible ? .automatic : .hidden)
        // The inspector (P6). Presented from the READER, not from the shell
        // root, for two reasons. It scopes the presentation to the route that
        // owns it, so a trip to Home takes the sheet down with the screen it
        // belongs to rather than leaving UIKit to dismiss a sheet whose
        // presenter is still on screen. And it keeps this `.sheet` on a
        // different view from the shell's `AddWebpageSheet_iOS` — two
        // `.sheet(isPresented:)` modifiers on one view is the SwiftUI
        // arrangement where the second one silently fails to present.
        //
        // Nothing is read from the environment inside the closure: the sheet
        // takes its stores as parameters and re-injects them itself (see
        // `PhoneInspectorSheet_iOS`), which is the same discipline the
        // `ContentView_iOS:57-63` comment imposes on the webpage sheet.
        .sheet(isPresented: inspectorPresented) {
            PhoneInspectorSheet_iOS(
                shell: shell, workspace: workspace, pane: pane, themeStore: themeStore)
        }
    }

    /// The sheet's presentation, per D2.
    ///
    /// Both halves go through `PhoneShellStore` rather than through
    /// `WorkspaceStore` directly. The getter adds the phone's own term (the
    /// sheet belongs over the document, so `route == .reader`), and the setter
    /// is the guard that makes state preservation work: when the route flips to
    /// Home, SwiftUI dismisses this sheet and writes `false` back through the
    /// binding, and that write must not be mistaken for the user closing the
    /// panel. `WorkspaceStore.setInspectorPresented`'s own guard does not cover
    /// it — on Home the document is still open (D1).
    private var inspectorPresented: Binding<Bool> {
        Binding(
            get: { shell.inspectorPresented },
            set: { shell.setInspectorPresented($0) }
        )
    }

    // MARK: - Opening

    private func presentImporter() {
        let app = pane.app
        DocumentPickerCoordinator_iOS.shared.present { urls in
            Task { @MainActor in
                isImporting = true
                defer { isImporting = false }
                let paths = await Task.detached(priority: .userInitiated) {
                    DocumentImport.importPicked(urls)
                }.value
                guard !paths.isEmpty else { return }
                await app.openFiles(paths: paths)
                shell.didOpenDocument()
            }
        }
    }

    #if DEBUG
    /// QA hook, shared with the iPad shell: headless runs can't drive a
    /// document picker. P8 composes `VELLUM_PHONE_STATE` on top of this.
    private func autoOpenForTesting() async {
        let app = pane.app
        guard app.document == nil, app.tabs.isEmpty else { return }
        if let url = ProcessInfo.processInfo.environment["VELLUM_AUTOOPEN_URL"] {
            await app.openUrl(url)
            return
        }
        guard let path = ProcessInfo.processInfo.environment["VELLUM_AUTOOPEN_PDF"],
              FileManager.default.fileExists(atPath: path) else { return }
        let paths = DocumentImport.importPicked([URL(fileURLWithPath: path)])
        guard !paths.isEmpty else { return }
        await app.openFiles(paths: paths)
    }
    #endif
}
#endif
