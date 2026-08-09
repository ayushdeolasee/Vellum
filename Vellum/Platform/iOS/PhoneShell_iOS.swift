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
    @State private var homeSearch: HomeSearchStore

    @State private var addWebpagePresented = false
    @State private var isImporting = false

    /// A one-shot request to put the keyboard in Home's search field, raised
    /// when ⌘F arrives with nothing to find (#153 P8).
    ///
    /// It is a *flag on the shell* rather than a notification Home listens for,
    /// because Home is a route: the chord is reachable from the reader, where the
    /// field does not exist yet, so the request has to survive the route change
    /// and be consumed by the screen once it mounts. `PhoneHome_iOS` clears it,
    /// which is what stops every later visit to Home from raising the keyboard.
    @State private var focusHomeSearch = false

    init(workspace: WorkspaceStore) {
        self.workspace = workspace
        _shell = State(initialValue: PhoneShellStore(workspace: workspace))
        _homeSearch = State(initialValue: workspace.focusedPane.homeSearch)
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
                        routeToOpenedDocumentIfSuccessful(app)
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
                        routeToOpenedDocumentIfSuccessful(app)
                    }
                } else {
                    presentImporter()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .vellumAddWebpage)) { _ in
                addWebpagePresented = true
            }
            // ⌘T on a single-pane workspace. The router refuses to mint a start
            // tab there (#153 D1) and posts this instead, because the route lives
            // here and the router — shared with the iPad, and reachable from a
            // `UIKeyCommand` on the PDF surface — has no handle on the shell.
            .onReceive(NotificationCenter.default.publisher(for: .vellumShowHome)) { _ in
                shell.showHome()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: .vellumSystemRouteDidOpenDocument)
            ) { _ in
                routeToOpenedDocumentIfSuccessful(pane.app)
            }
            // ⌘F with no document: "Find…" has nothing to find and the chord
            // means "search my library" instead. Both halves are done here —
            // route to Home, then ask the field for the keyboard — because the
            // reader is where the chord is usually pressed and Home is not in
            // the tree yet to hear the notification for itself.
            .onReceive(NotificationCenter.default.publisher(for: .vellumFocusHomeSearch)) { _ in
                focusHomeSearch = true
                shell.showHome()
            }
            // The tab switcher (P7). A cover rather than a sheet: it replaces
            // the document rather than sitting over it, so there is nothing
            // behind it worth peeking at, and no detent to get wrong.
            //
            // Mounted at the SHELL, not on the reader route, because Home
            // offers the switcher too (`PhoneHome_iOS.header`) — and Home is
            // where someone with three documents open and none of them on
            // screen actually is. It coexists with the inspector's `.sheet`
            // (presented from the reader, a descendant) because the two are
            // mutually exclusive by construction: `inspectorPresented` is false
            // whenever `switcherPresented` is true, so the sheet is on its way
            // out in the same transaction this presents.
            //
            // Handed its stores rather than reading them, like every other
            // presentation here: a cover is its own hosting boundary.
            .fullScreenCover(isPresented: switcherPresented) {
                PhoneTabSwitcher_iOS(
                    shell: shell, workspace: workspace, app: pane.app, themeStore: themeStore)
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
                guard tabId != nil else { return }
                routeToOpenedDocumentIfSuccessful(pane.app)
            }
            #if DEBUG
            .task { await applyLaunchPlan() }
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
    /// Home's Tabs button raises the switcher (P7) rather than jumping straight
    /// back to the current document: from Home, "which of my documents" is the
    /// question being asked, and the grid is the answer. Tapping a card is what
    /// returns to the reader.
    private var homeRoute: some View {
        PhoneHome_iOS(
            store: homeSearch,
            focusSearch: $focusHomeSearch,
            onOpen: { presentImporter() },
            onAddWebpage: { addWebpagePresented = true },
            onShowTabs: {
                guard !pane.app.tabs.isEmpty else { return }
                shell.switcherPresented = true
            },
            onDocumentOpened: { shell.didOpenDocument() })
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

            // Immersive reading keeps one explicit, system-safe way to restore
            // the bars. This consumes only its own 44pt button instead of
            // observing every tap delivered to PDFKit or WebKit.
            ChromeRevealControl_iOS(
                isActive: !shell.switcherPresented,
                chromeVisible: shell.chromeVisible
            ) {
                shell.showChrome()
            }

            PhoneReaderChrome_iOS(
                shell: shell,
                onOpenFile: { presentImporter() },
                onAddWebpage: { addWebpagePresented = true })
        }
        // The route's own handle, so a UI test can assert "the reader is on
        // screen" without depending on which chrome happens to be visible —
        // `phone.reader.title` and friends are absent in immersive mode, which
        // is exactly one of the states `VELLUM_PHONE_STATE` exists to screenshot.
        .accessibilityIdentifier("phone.reader")
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

    /// The switcher's presentation. Written by hand rather than with
    /// `@Bindable` because `shell` is `@State`-owned here and the setter has one
    /// rule of its own: a `false` arriving from the cover's own dismissal
    /// (swipe-down, or the system taking it away) is the user leaving the
    /// switcher, which is exactly what the flag means — but it must go through
    /// the store so the shell has a single writer for it.
    private var switcherPresented: Binding<Bool> {
        Binding(
            get: { shell.switcherPresented },
            set: { shell.switcherPresented = $0 }
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
                routeToOpenedDocumentIfSuccessful(app)
            }
        }
    }

    /// An awaited open may fail while an older document remains mounted, so a
    /// non-nil document alone is not proof the requested target opened. The
    /// absence of an AppStore error is the completed-open success signal. It
    /// also covers reactivating an already-open tab, where no document-value
    /// change is emitted for the safety-net observer above to notice.
    private func routeToOpenedDocumentIfSuccessful(_ app: AppStore) {
        guard app.document != nil, app.error == nil else { return }
        shell.didOpenDocument()
    }

    #if DEBUG
    /// The launch-environment QA hook (#153 P8) — the one place the phone reads
    /// `VELLUM_AUTOOPEN_URL` / `VELLUM_AUTOOPEN_PDF` / `VELLUM_PHONE_STATE`.
    ///
    /// Parsing and composition live in `PhoneLaunchPlan`, which is a pure
    /// function of the environment dictionary and therefore unit-tested; this
    /// method is only the effects — open the document, then land on the surface.
    /// Splitting it that way is deliberate: the interesting rule ("a state that
    /// needs a document, with no document anywhere, degrades to Home") is
    /// exactly the part a simulator cannot check cheaply.
    private func applyLaunchPlan() async {
        let plan = PhoneLaunchPlan.parse(environment: ProcessInfo.processInfo.environment)
        guard !plan.isEmpty else { return }

        let app = pane.app
        // Only into an empty shell, matching the hook this replaces: a restored
        // session already has the document the run wants to photograph, and
        // importing a second copy over it would change what the screenshot shows.
        if app.document == nil, app.tabs.isEmpty, let open = plan.open {
            switch open {
            case .url(let url):
                await app.openUrl(url)
            case .pdf(let path):
                guard FileManager.default.fileExists(atPath: path) else { break }
                let paths = DocumentImport.importPicked([URL(fileURLWithPath: path)])
                guard !paths.isEmpty else { break }
                await app.openFiles(paths: paths)
            }
        }

        guard let state = plan.resolvedState(hasDocument: app.document != nil) else { return }

        // Opening a document lands the shell on the reader by way of the
        // `activeTabId` safety net above, and that runs on SwiftUI's schedule
        // rather than ours — `showReader()` resets the chrome, which would undo
        // `.immersive` if we raced it. `restoreFromDisk` can activate a tab late
        // for the same reason. One turn of the runloop after the opens have
        // settled is enough, and this is a DEBUG screenshot hook: a coordination
        // channel built to make it exact would be more machinery than the thing
        // it coordinates.
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }

        switch state {
        case .home:
            shell.showHome()
        case .reader:
            shell.showReader()
        case .immersive:
            shell.showReader()
            shell.setChrome(false)
        case .inspector:
            // Whatever panel the workspace last selected, so a run can pick one
            // with the ⌥⌘1/2/3 chords and still use this to present it.
            shell.revealInspector(shell.inspectorTab)
        case .tabs:
            shell.showReader()
            shell.switcherPresented = true
        }
    }
    #endif
}
#endif
