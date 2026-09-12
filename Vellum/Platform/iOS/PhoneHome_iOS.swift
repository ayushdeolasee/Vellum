#if os(iOS)
import SwiftUI

/// The iPhone's Home: one column, search-first (#153 P4).
///
/// Home is a ROUTE on the phone (D1), not a tab, so this screen is mounted and
/// unmounted constantly — which is exactly why it does not own its corpus. The
/// `HomeSearchStore` is handed in by `PhoneShell_iOS`, which holds it for the
/// life of the shell; a screen-owned store would re-walk the disk on every trip
/// back from reading.
///
/// It is built from the same pieces as the iPad library — `HomeResultRow`,
/// `HomeSectionHeader`, `HomeLinkActionRow`, `HomeFilterChip`,
/// `HomeLibraryActions_iOS`, `HomeOpenResolver` — with a phone layout over the
/// top. Its source switcher opens the same account-specific library used on
/// iPad, including search and collection filters. What it deliberately does
/// not carry, versus `WelcomeLibrary_iOS`:
///
///   * the keyboard affordances (`Keycap`, arrow-key selection, ⌘F hints). They
///     stay reachable — the notification handler below focuses the field — but
///     nothing draws chrome for a keyboard the phone usually does not have;
///   * `homeContentColumn()`. Its 900pt cap and 24pt gutter are an iPad column;
///     the phone uses the full width at a 16pt gutter.
///
/// The field is NOT auto-focused, for the same reason `WelcomeScreen_iOS`
/// documents, only more so: on a phone the software keyboard covers over half
/// the screen, and Home's whole job is to show what is already there.
struct PhoneHome_iOS: View {
    /// Shell-owned so a Home visit is a repaint, not a re-index. `@Bindable`
    /// rather than `@State` for exactly that reason: this screen renders the
    /// store and writes `query`/`filter`/`sort` into it, but it does not own its
    /// lifetime — `PhoneShell_iOS` does.
    @Bindable var store: HomeSearchStore
    /// Shell-owned so returning from an article keeps the selected library.
    @Binding var source: HomeSource
    /// A one-shot "put the keyboard in the search field" request, owned by the
    /// shell and CLEARED here.
    ///
    /// It is a binding rather than a notification this screen listens for
    /// because Home is a route: ⌘F is usually pressed in the reader, where this
    /// view does not exist to hear anything, so the shell routes Home and leaves
    /// the request behind for whenever the screen mounts. Clearing it on arrival
    /// is what keeps the request one-shot — a flag left set would raise the
    /// software keyboard on every later visit to Home, which is precisely the
    /// auto-focus this screen is documented not to do.
    @Binding var focusSearch: Bool
    var onOpen: () -> Void
    var onAddWebpage: () -> Void
    var onShowTabs: () -> Void
    var onDocumentOpened: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var actions: HomeLibraryActions_iOS
    @State private var continueReading: [ContinueReadingItem] = []
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var externalCollectionID: String?
    @State private var externalSortByName = false
    @FocusState private var searchFocused: Bool

    init(
        store: HomeSearchStore,
        source: Binding<HomeSource>,
        focusSearch: Binding<Bool>,
        onOpen: @escaping () -> Void,
        onAddWebpage: @escaping () -> Void,
        onShowTabs: @escaping () -> Void,
        onDocumentOpened: @escaping () -> Void
    ) {
        self.store = store
        _source = source
        _focusSearch = focusSearch
        self.onOpen = onOpen
        self.onAddWebpage = onAddWebpage
        self.onShowTabs = onShowTabs
        self.onDocumentOpened = onDocumentOpened
        _actions = State(initialValue: HomeLibraryActions_iOS(store: store))
    }

    /// Horizontal gutter. The rows carry `HomeLayout.rowInset` (16) of their own
    /// inside their tappable surface, so the page gutter is deliberately
    /// smaller: 16 + 16 would push a result's glyph a third of the way across a
    /// 390pt screen.
    private static let gutter: CGFloat = 8

    /// The calm first-run hero, shown only once we KNOW there is nothing to
    /// browse — never while the first load is still in flight, or the screen
    /// would flash "welcome" at someone with a full library.
    private var showsFirstRun: Bool {
        guard browsedProvider == nil else { return false }
        return !store.isLoading && store.libraryIsEmpty && !store.isSearching
            && integrations.connectedProviders.isEmpty
    }

    private var sources: [HomeSource] {
        HomeSource.options(connected: integrations.connectedProviders)
    }

    private var browsedProvider: IntegrationProvider? {
        if case .provider(let provider) = source { return provider }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if showsFirstRun {
                firstRun
            } else {
                library
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well)
        .task { await reloadLibrary() }
        // One driver for every input that invalidates the results (query,
        // filter, sort). `.task(id:)` cancels the in-flight pass automatically,
        // which is exactly the debounce semantics we want while typing.
        .task(id: store.refreshKey) { await store.refresh() }
        // Publish the read-later corpus into home search whenever it actually
        // changes. Debounced for the same reason the iPad screen debounces it:
        // a sync ticks the revision once per network page and a corpus rebuild
        // is three disk walks.
        .task(id: integrations.searchRevision) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await store.updateReadLater(integrations.searchableItems)
            await reloadContinueReading()
        }
        // Re-index when the app comes back to the front: the corpus is a
        // snapshot of on-disk sources, and a Files.app move or the Storage pane
        // can change all of them while Vellum is backgrounded.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await reloadLibrary() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumCapturedLibraryChanged)) { _ in
            Task { await reloadLibrary() }
        }
        // `initial: true` covers the case the binding exists for: the request
        // was raised in the reader and this screen is only now being built, so
        // there was no change to observe — just a flag that is already set by
        // the time the field appears.
        .onChange(of: focusSearch, initial: true) { _, requested in
            guard requested else { return }
            source = .library
            searchFocused = true
            focusSearch = false
        }
        .onChange(of: integrations.connectedProviders, initial: true) { _, connected in
            source = HomeSource.reconciled(source, connected: connected)
            store.filter = store.filter.reconciled(connected: connected)
        }
        .onChange(of: source) { oldSource, newSource in
            guard oldSource != newSource else { return }
            externalCollectionID = browsedProvider.flatMap { integrations.defaultCollectionID(for: $0) }
        }
        .homeLibraryPresentations(actions, toastAlignment: .bottom)
        .sheet(isPresented: $showSettings) { SettingsSheet_iOS() }
        .sheet(isPresented: $showHelp) { HelpCenterView_iOS() }
        .accessibilityIdentifier("phone.home")
    }

    // MARK: - Header

    /// Wordmark plus Home's persistent actions: Add PDF, the tab switcher when
    /// documents are open, and Settings. Help stays in the first-run hero and
    /// the reader's More menu (P5) rather than crowding this primary pod.
    private var header: some View {
        HStack(spacing: 8) {
            Wordmark(size: 30)
            Spacer(minLength: 12)
            GlassToolPod(label: "Library") {
                GlassToolButton(system: "doc.badge.plus", label: "Add PDF", action: onOpen)
                    .accessibilityIdentifier("phone.home.addPdf")

                // Only when there is something to switch to. Home IS the
                // no-documents state, so an always-present Tabs button would be
                // a control whose only honest answer is "nothing".
                if !appStore.tabs.isEmpty {
                    GlassToolButton(system: "square.on.square", label: tabsLabel) {
                        onShowTabs()
                    }
                    .accessibilityIdentifier("phone.home.tabs")
                    .overlay(alignment: .topTrailing) { tabCountBadge }
                }
                GlassToolButton(system: "gearshape", label: "Settings") {
                    // Setting the section BEFORE presenting is what makes #70's
                    // "route Home to a specific tab" work; `SettingsView`'s
                    // `TabView` binds straight to it.
                    workspace.settingsSection = .general
                    showSettings = true
                }
                .accessibilityIdentifier("phone.home.settings")
            }
        }
        .padding(.horizontal, Self.gutter + 8)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .simultaneousGesture(dismissSearchKeyboardTap)
    }

    private var tabsLabel: String {
        let count = appStore.tabs.count
        if count == 0 { return "Open documents" }
        return count == 1 ? "1 open document" : "\(count) open documents"
    }

    /// The count rides the button as a badge rather than as a second label:
    /// "how many documents are still open" is the only thing that makes the
    /// switcher worth reaching for, and it has to survive being read at a
    /// glance from a 44pt target.
    @ViewBuilder
    private var tabCountBadge: some View {
        let count = appStore.tabs.count
        if count > 0 {
            Text("\(count)")
                .font(.caption2.bold())
                .monospacedDigit()
                .foregroundStyle(palette.primaryForeground)
                .padding(.horizontal, 4)
                .frame(minWidth: 15, minHeight: 15)
                .background(palette.primary, in: Capsule())
                .padding(.trailing, 3)
                .padding(.top, 5)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: - Library

    private var library: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                if sources.count > 1 {
                    ScrollView(.horizontal) {
                        HomeSourceSwitcher_iOS(sources: sources, selection: $source)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .simultaneousGesture(dismissSearchKeyboardTap)
                }

                searchCapsule
                if browsedProvider == nil, appStore.error != nil {
                    errorBanner.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, Self.gutter)
            .padding(.bottom, 8)

            if let provider = browsedProvider {
                ExternalLibraryList_iOS(
                    provider: provider,
                    search: $store.query,
                    collectionID: $externalCollectionID,
                    sortByName: $externalSortByName,
                    onDocumentOpened: documentDidOpenIfSuccessful)
                    .simultaneousGesture(dismissSearchKeyboardTap)
            } else {
                resultList
            }
        }
        .background {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { searchFocused = false }
        }
        // Progress and failures for a read-later PDF opened from a search
        // result — without it, tapping a Readwise row would look like nothing
        // happened for the length of the download.
        .overlay(alignment: .bottom) {
            if browsedProvider == nil { readLaterNotice }
        }
    }

    /// 52pt because this is the phone's primary target and the one control a
    /// reader reaches for one-handed; the iPad's 46 is a pointer-adjacent
    /// height. `GlassToolPod` shares the 48pt family, so the field reads as the
    /// larger sibling of the chrome rather than as a different system.
    private var searchCapsule: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16))
                .foregroundStyle(palette.mutedForeground)
                .accessibilityHidden(true)

            TextField("Search your library — or paste a link", text: $store.query)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(palette.foreground)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(browsedProvider == nil ? .go : .search)
                // `.webSearch` puts "/" and ".com" on the software keyboard,
                // which is right for a field that doubles as an address bar.
                .keyboardType(.webSearch)
                .accessibilityIdentifier("phone.home.search")
                .onSubmit {
                    if browsedProvider == nil { openSelection() }
                }

            if !store.query.isEmpty {
                Button {
                    _ = store.clearQuery()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(palette.mutedForeground)
                        // The whole trailing slot, not the 16pt glyph — the
                        // hit-target rule the toolbar buttons follow.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .accessibilityIdentifier("phone.home.clearSearch")
            }

            HomeSearchFilterMenu_iOS(
                provider: browsedProvider,
                collections: browsedProvider.flatMap { integrations.providers[$0]?.collections } ?? [],
                libraryFilter: $store.filter,
                librarySort: $store.sort,
                collectionID: $externalCollectionID,
                sortByName: $externalSortByName)
        }
        .padding(.leading, HomeLayout.rowInset)
        .padding(.trailing, 4)
        .frame(minHeight: 52)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            Capsule().strokeBorder(
                SelectionStyle.edge(palette, selected: searchFocused), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    private var resultList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                if showsContinueReading {
                    continueReadingSection
                }

                if let link = store.linkSuggestion {
                    HomeLinkActionRow(
                        url: link,
                        isSelected: store.selectedId == HomeSearchStore.linkRowId,
                        open: { openLink(link) }
                    )
                    .padding(.top, 6)
                }

                ForEach(store.sections) { group in
                    Section {
                        ForEach(group.items) { item in
                            HomeResultRow(
                                item: item,
                                isSelected: store.selectedId == item.id,
                                open: { open(item) },
                                share: shareTarget(for: item),
                                rename: actions.renameAction(for: item),
                                removals: actions.removalActions(
                                    for: item, undoManager: undoManager)
                            )
                            .accessibilityIdentifier("phone.home.result")
                        }
                    } header: {
                        HomeSectionHeader(section: group.section, count: group.items.count)
                    }
                }

                // A pinned link IS the answer to a pasted URL, so "no matches"
                // would be both wrong and unhelpful next to it.
                if store.sections.isEmpty, store.linkSuggestion == nil, !store.isLoading {
                    emptyResults
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                }
            }
            .padding(.horizontal, Self.gutter)
            .padding(.bottom, 32)
        }
        .scrollContentBackground(.hidden)
        // Let a scroll put the software keyboard away instead of trapping the
        // reader behind it. On a phone this is the primary dismissal — there is
        // no room for a "Done" bar over the list.
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("phone.home.results")
        .simultaneousGesture(dismissSearchKeyboardTap)
    }

    private var dismissSearchKeyboardTap: some Gesture {
        TapGesture().onEnded { searchFocused = false }
    }

    /// Cross-device position entries are intentionally separate from the
    /// legacy Recents rows below. They use the merged position store, so the
    /// first row can be a page last read on the Mac even when this phone has
    /// never opened it. Search and explicit filters hide this shelf so those
    /// modes contain only the answer the reader asked for.
    private var showsContinueReading: Bool {
        !store.isSearching && store.filter == .all && !continueReading.isEmpty
    }

    private var continueReadingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90")
                    .font(.caption.weight(.semibold))
                Text("Continue Reading")
                    .font(.caption.weight(.semibold))
                    .textCase(.uppercase)
                    .kerning(0.4)
                Text("\(continueReading.count)")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.mutedForeground.opacity(0.7))
                Spacer(minLength: 0)
            }
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, HomeLayout.rowInset)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .accessibilityIdentifier("phone.home.continueReading.header")
            .accessibilityLabel(
                continueReading.count == 1
                    ? "Continue Reading, 1 item"
                    : "Continue Reading, \(continueReading.count) items")

            ForEach(continueReading) { item in
                ContinueReadingRow_iOS(item: item) { open(item.document) }
            }

            Divider()
                .padding(.horizontal, HomeLayout.rowInset)
                .padding(.top, 8)
        }
    }

    /// Two different "nothing here" messages, because they need two different
    /// answers: a failed search wants advice on widening it, an empty filter
    /// wants a way back to All.
    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: store.isSearching ? "magnifyingglass" : "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.mutedForeground)
                .padding(.bottom, 4)
                .accessibilityHidden(true)

            if store.isSearching {
                Text("No matches for “\(store.trimmedQuery)”")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .multilineTextAlignment(.center)
                Text("Search matches titles, filenames, and web addresses. Try fewer words.")
                    .font(.footnote)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nothing in \(store.filter.label) yet")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.foreground)
                    .multilineTextAlignment(.center)
                Text("Open a PDF or add a webpage and it will show up here.")
                    .font(.footnote)
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
            }

            // One button that undoes BOTH constraints: from the outside, a query
            // that matches nothing and a filter that excludes everything produce
            // the identical blank screen.
            if store.isSearching || store.filter != .all {
                TextButton(variant: .secondary, size: .sm) {
                    store.resetSearch()
                } label: {
                    Text(store.isSearching ? "Clear search" : "Search everything")
                }
                .padding(.top, 6)
                .accessibilityIdentifier("phone.home.resetSearch")
            }

            // A source that failed to load has silently narrowed the search —
            // say so rather than letting the user conclude the document is gone.
            ForEach(store.failures, id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(palette.destructive)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityIdentifier("phone.home.emptyResults")
    }

    // MARK: - First run

    /// The hero, stacked rather than side-by-side: two `.lg` buttons in a row do
    /// not fit at 390pt without shrinking their labels to nothing.
    private var firstRun: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 10) {
                    Wordmark(size: 44)
                    Text(PhoneHome_iOS.tagline)
                        .font(.headline)
                        .foregroundStyle(palette.mutedForeground)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 10) {
                    TextButton(variant: .primary, size: .lg, action: onOpen) {
                        Label("Open a PDF", systemImage: "doc.badge.plus")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("phone.home.openPdf")
                    TextButton(variant: .secondary, size: .lg, action: onAddWebpage) {
                        Label("Add Webpage", systemImage: "globe")
                            .frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("phone.home.addWebpage")
                }

                errorBanner
                walkthroughLink
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 40)
            .padding(.bottom, 48)
        }
    }

    /// The first-run promise, named for the device the reader is holding rather
    /// than hard-coded to one of them — the same binary serves both idioms
    /// (#153 D6), and "AI-powered reading for iPad" on an iPhone is the first
    /// sentence the app says being wrong.
    static var tagline: String {
        "AI-powered reading for \(ShellIdiom_iOS.current.deviceName)"
    }

    private var walkthroughLink: some View {
        Button {
            // Routed through the root scene rather than presented here: the
            // walkthrough outlives this screen.
            NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle")
                    .font(.footnote)
                Text("How Vellum works")
                    .font(.footnote)
            }
            .foregroundStyle(palette.mutedForeground)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("phone.home.walkthrough")
        .padding(.top, 16)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = appStore.error {
            Text(error)
                .font(.footnote)
                .foregroundStyle(palette.destructive)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity)
                .background(palette.destructive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(palette.destructive.opacity(0.3))
                }
        }
    }

    /// The newest download/move notice from any connected account, picked by the
    /// store's own monotonic sequence so two accounts working at once still
    /// produce one deterministic notice.
    @ViewBuilder
    private var readLaterNotice: some View {
        if let notice = integrations.connectedProviders
            .compactMap({ integrations.newestNotice(for: $0) })
            .max(by: { $0.state.sequence < $1.state.sequence }) {
            FloatingNotice(
                message: notice.state.message, progress: notice.state.progress,
                isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice",
                actionTitle: integrations.previousRevisionURL(for: notice.id) == nil ? nil : "Open Previous",
                action: {
                    guard let url = integrations.takePreviousRevision(for: notice.id) else { return }
                    Task { await appStore.openFiles(paths: [url.path]) }
                }
            ) {
                if notice.isMove {
                    integrations.dismissMoveNotice(notice.id)
                } else {
                    integrations.dismissDownloadNotice(notice.id)
                }
            }
            .padding(12)
        }
    }

    // MARK: - Actions

    /// Return on a hardware keyboard: open whatever is selected, or the typed
    /// link. With neither, the software keyboard's Go key falls through to the
    /// top hit if there is one.
    private func openSelection() {
        if store.selectedId == HomeSearchStore.linkRowId, let link = store.linkSuggestion {
            openLink(link)
        } else if let item = store.selectedItem {
            open(item)
        } else if let link = store.linkSuggestion {
            openLink(link)
        } else if let first = store.visibleItems.first {
            open(first)
        }
    }

    private func reloadLibrary() async {
        await store.load()
        await reloadContinueReading()
    }

    private func reloadContinueReading() async {
        // Resolve before limiting. The newest merged records can legitimately
        // belong to documents that are not present on this phone, so fetching
        // an arbitrary prefix can leave fewer than three rows even though
        // older, locally openable records exist.
        let recents = await workspace.positions.store.recents(limit: Int.max)
        guard !Task.isCancelled else { return }
        continueReading = ContinueReadingResolver.resolve(
            recents, in: store.corpusItems, limit: 3)
    }

    private func open(_ item: HomeSearchItem) {
        guard !appStore.isLoading else { return }
        // A read-later hit opens the way it would from the account's own list:
        // an article opens its page, a PDF is downloaded (with progress, see
        // `readLaterNotice`) and opened from the cache. The corpus is a
        // snapshot, so the lookup can legitimately miss — and the row's plain
        // URL target is then still the right thing to open.
        if item.section == .readLater,
           let external = integrations.readLaterItem(forOpenDocumentPath: item.target.openKey) {
            openExternal(external)
            return
        }
        switch HomeOpenResolver.intent(
            for: item.target, resolveExisting: DocumentImport.resolveExistingPath
        ) {
        case .url(let url):
            Task {
                await appStore.openUrl(url)
                documentDidOpenIfSuccessful()
            }
        case .file(let path, let staleRecentPath):
            if let staleRecentPath {
                _ = RecentFilesService.remove(path: staleRecentPath)
            }
            Task {
                await appStore.openFiles(paths: [path])
                documentDidOpenIfSuccessful()
            }
        }
    }

    /// Store-owned rather than a bare `Task` — a download outlives this screen,
    /// which the route change tears down mid-flight, and the store's
    /// scene-background drain joins what it started.
    private func openExternal(_ item: ReadLaterItem) {
        integrations.run {
            guard let route = try? await integrations.route(for: item) else { return }
            switch route {
            case .web(let url): await appStore.openUrl(url.absoluteString)
            case .file(let url): await appStore.openFiles(paths: [url.path])
            }
            documentDidOpenIfSuccessful()
        }
    }

    private func openLink(_ link: String) {
        guard !appStore.isLoading else { return }
        store.query = ""
        Task {
            await appStore.openUrl(link)
            documentDidOpenIfSuccessful()
        }
    }

    /// Opening can reactivate an already-mounted tab without changing the
    /// document value. Judge the completed operation by the store's resulting
    /// state rather than by observing a value transition, and never leave Home
    /// when the attempted open reported an error.
    private func documentDidOpenIfSuccessful() {
        guard appStore.document != nil, appStore.error == nil else { return }
        onDocumentOpened()
    }

    /// The phone's answer to "Show in Finder". Only offered when the file is
    /// actually on disk, which is what `canRevealInFinder` records.
    private func shareTarget(for item: HomeSearchItem) -> String? {
        guard item.canRevealInFinder, case .file(let path, _) = item.target else { return nil }
        return path
    }
}

/// A compact, full-width handoff row. It deliberately names both the position
/// and the source device: "Page 42" is the resumption promise, while "From
/// Ayush's Mac" explains why a document the phone has never opened is here.
private struct ContinueReadingRow_iOS: View {
    let item: ContinueReadingItem
    let open: () -> Void

    @Environment(\.palette) private var palette
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: item.document.systemImage)
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                    .frame(width: 34, height: 34)
                    .background(
                        palette.primary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: Radius.md))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(2)
                        .truncationMode(.tail)

                    Group {
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 2) {
                                if !item.progressLabel.isEmpty {
                                    Text(item.progressLabel)
                                }
                                if let device = item.deviceLabel {
                                    Text(device)
                                }
                            }
                        } else {
                            HStack(spacing: 5) {
                                if !item.progressLabel.isEmpty {
                                    Text(item.progressLabel)
                                }
                                if !item.progressLabel.isEmpty, item.deviceLabel != nil {
                                    Text("·").accessibilityHidden(true)
                                }
                                if let device = item.deviceLabel {
                                    Text(device)
                                }
                            }
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                }

                Spacer(minLength: 8)

                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(palette.mutedForeground)
                }
            }
            .padding(.horizontal, HomeLayout.rowInset)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
            .selectionSurface(
                selected: false, hovering: false,
                in: RoundedRectangle(cornerRadius: Radius.md), palette: palette)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("phone.home.continueReading.row")
        .accessibilityLabel(item.title)
        .accessibilityValue(
            [item.progressLabel, item.deviceLabel].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: ", "))
    }
}
#endif
