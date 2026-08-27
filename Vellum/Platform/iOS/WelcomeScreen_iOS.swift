#if os(iOS)
import SwiftUI

/// The iPad Home screen: search-first, with the library underneath.
///
/// Rebuilt from main's `Views/Welcome/WelcomeScreen.swift` (#68/#70/#82/#103).
/// The screen owns no matching logic at all — it renders `HomeSearchStore`,
/// which drives `HomeSearchEngine` and its providers off the main thread.
///
/// The public shape (`onOpen` / `onAddWebpage` / `compact`) is unchanged so
/// both existing call sites — `ContentView_iOS` full-screen and
/// `PaneView_iOS(compact: true)` as a start tab — keep compiling.
///
/// iPad deltas from main, each deliberate:
///   * no hover anywhere (see `HomeResultViews_iOS`);
///   * the field is **not** auto-focused on appear. On a Mac focusing a text
///     field costs nothing; on iPad it summons the software keyboard over half
///     the screen every time Home appears. ⌘F focuses it instead;
///   * `NSApplication.didBecomeActiveNotification` → `scenePhase`;
///   * `NSOpenPanel` → the existing `DocumentPickerCoordinator_iOS` behind
///     `onOpen`; "Show in Finder" → `ShareLink`;
///   * a removal toast, because iPad has no Edit ▸ Undo menu without a
///     keyboard attached — see `performRemoval`.
struct WelcomeLibrary_iOS: View {
    var onOpen: () -> Void
    var onAddWebpage: () -> Void
    var compact = false

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var store: HomeSearchStore

    /// `store` is injectable so a shell that unmounts this screen can keep the
    /// corpus alive across visits (the phone's Home is a route, not a tab — see
    /// `PhoneShellRoot_iOS.homeSearch`). Defaulted to nil, so both iPad call
    /// sites keep their own screen-owned store and behave exactly as before.
    init(
        onOpen: @escaping () -> Void,
        onAddWebpage: @escaping () -> Void,
        compact: Bool = false,
        store: HomeSearchStore? = nil
    ) {
        self.onOpen = onOpen
        self.onAddWebpage = onAddWebpage
        self.compact = compact
        let corpus = store ?? HomeSearchStore()
        _store = State(initialValue: corpus)
        _actions = State(initialValue: HomeLibraryActions_iOS(store: corpus))
    }

    /// Which library the screen is showing: the local one, or a connected
    /// read-later account's. Reset to `.library` when the account being browsed
    /// is disconnected — see the `connectedProviders` change handler.
    @State private var source: HomeSource = .library
    /// Rename sheet, removal confirmation, undo toast and the `UndoManager`
    /// registrations — all four extracted to `HomeLibraryActions_iOS` in #153 P4
    /// so the phone Home drives exactly the same orchestration.
    @State private var actions: HomeLibraryActions_iOS
    @State private var showSettings = false
    @State private var showHelp = false
    @FocusState private var searchFocused: Bool

    /// The calm first-run hero, shown only once we KNOW there is nothing to
    /// browse — never while the first load is still in flight, or the screen
    /// would flash "welcome" at someone with a full library.
    private var showsFirstRun: Bool {
        // Someone who has switched to an account is browsing, whatever the
        // local library holds — and that account's list has its own, better
        // empty state. Yanking them to the hero because a sync briefly emptied
        // the list would also take the switcher away, leaving no way back.
        guard browsedProvider == nil else { return false }
        return !store.isLoading && store.libraryIsEmpty && !store.isSearching
            && integrations.connectedProviders.isEmpty
    }

    /// Library plus one entry per connected account, in `IntegrationProvider`
    /// order. One entry means nothing is connected and the switcher never
    /// appears — a reader with no integrations sees Home unchanged.
    private var sources: [HomeSource] {
        HomeSource.options(connected: integrations.connectedProviders)
    }

    /// The account whose own library is on screen, if any. Nil is the local
    /// library — i.e. everything packet 3's Home already does.
    private var browsedProvider: IntegrationProvider? {
        if case .provider(let provider) = source { return provider }
        return nil
    }

    /// Whether this instance is the one a keyboard chord should talk to. A
    /// split with two start tabs hosts two copies of this screen, and both
    /// would otherwise grab the keyboard on ⌘F. Comparing the injected pane
    /// store against the focused pane's is the iPad analogue of main's
    /// `isPaneFocused`, and needs no change to the view's signature.
    private var isPaneFocused: Bool {
        !compact || appStore === workspace.focusedPane.app
    }

    var body: some View {
        VStack(spacing: 0) {
            // In compact mode the pane already has its own chrome, so the Home
            // bar would be a second title row inside a split. Help and Settings
            // stay reachable from the pane's own menu.
            if !compact {
                homeHeader
                Divider()
            }
            Group {
                if showsFirstRun {
                    firstRunLayout
                } else {
                    libraryLayout
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well)
        .task { await store.load() }
        // One driver for every input that invalidates the results (query,
        // filter, sort). `.task(id:)` cancels the in-flight pass automatically,
        // which is exactly the debounce semantics we want while typing.
        .task(id: store.refreshKey) { await store.refresh() }
        // Publish the read-later corpus into home search whenever it actually
        // changes (connect, sync page, move, disconnect). The revision only
        // moves alongside an observable `providers` write, so this re-fires
        // exactly as often as the items can differ — and runs once on arrival,
        // covering a corpus a previous screen already synced. Debounced,
        // because a sync ticks the revision once per network page and a corpus
        // rebuild is three disk walks: `.task(id:)` cancels the sleeping pass
        // on the next tick, so a paging burst costs one rebuild, not forty.
        .task(id: integrations.searchRevision) {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await store.updateReadLater(integrations.searchableItems)
        }
        // A disconnected account has no library left to show — and its state is
        // wiped by `IntegrationsStore.disconnect`, so leaving the screen on it
        // would park the reader in front of a permanently empty list. The
        // fallback is the local library, which always exists.
        .onChange(of: integrations.connectedProviders) { _, connected in
            source = HomeSource.reconciled(source, connected: connected)
        }
        // Re-index when the app comes back to the front. The corpus is a
        // snapshot of on-disk sources, and all of them can change while Vellum
        // is backgrounded — a Files.app move, the other pane, the Storage pane.
        // Without this Home keeps confidently offering rows that no longer
        // exist. The reload runs off the main thread on `HomeSearchEngine` and
        // leaves the current results on screen while it runs.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await store.load() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumFocusHomeSearch)) { _ in
            guard isPaneFocused else { return }
            // ⌘F means "search my library", so it comes back from a connected
            // account's list first. Focusing a field that is not on screen
            // would otherwise make the chord look dead in exactly the place a
            // reader is most likely to try it.
            source = .library
            searchFocused = true
        }
        // The rename sheet, the removal confirmation, the undo toast and the
        // `onDisappear` that drops this screen's undo registrations. The toast
        // stays bottom-trailing, where it was before the extraction.
        .homeLibraryPresentations(actions)
        .sheet(isPresented: $showSettings) { SettingsSheet_iOS() }
        .sheet(isPresented: $showHelp) { HelpCenterView_iOS() }
    }

    // MARK: - Library layout

    private var libraryLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                // A connected account's list owns its own search field (and its
                // own collection filter and sort), so the library's field steps
                // aside instead of sitting above a list it cannot drive. ⌘F
                // still means "search my library" — it comes back here first,
                // see the `.vellumFocusHomeSearch` handler.
                if browsedProvider == nil {
                    searchField
                }
                controlBar
                if appStore.error != nil {
                    errorBanner.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .homeContentColumn()
            .padding(.top, 22)
            .padding(.bottom, 12)

            Divider()

            if let provider = browsedProvider {
                // Deliberately NOT in `homeContentColumn()`: this list carries
                // its own insets and full-width list chrome (it is the same
                // view the Settings pane shows), and nesting it in the capped
                // column would double every horizontal inset it applies.
                //
                // `.id(provider)` so switching accounts rebuilds it: its search
                // text and collection selection belong to one account, and
                // carrying them across would filter Raindrop by a Readwise
                // collection that does not exist there.
                ExternalLibraryList_iOS(provider: provider)
                    .id(provider)
            } else {
                resultList
            }
        }
        // Progress and failures for a read-later PDF opened from a SEARCH
        // result. `ExternalLibraryList_iOS` floats this itself, so it is only
        // added under the library list — without it, tapping a Readwise PDF row
        // here would look like nothing happened for the length of the download.
        .overlay(alignment: .bottomTrailing) {
            if browsedProvider == nil {
                readLaterNotice
            }
        }
    }

    /// The newest download/move notice from any connected account. Picked by
    /// the store's own monotonic sequence, so two accounts working at once
    /// still produce one deterministic notice rather than a dictionary-order
    /// pick.
    @ViewBuilder
    private var readLaterNotice: some View {
        if let notice = integrations.connectedProviders
            .compactMap({ integrations.newestNotice(for: $0) })
            .max(by: { $0.state.sequence < $1.state.sequence }) {
            FloatingNotice(
                message: notice.state.message, progress: notice.state.progress,
                isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice"
            ) {
                if notice.isMove {
                    integrations.dismissMoveNotice(notice.id)
                } else {
                    integrations.dismissDownloadNotice(notice.id)
                }
            }
            .padding(18)
        }
    }

    // MARK: - Home chrome (from #70)

    /// Home's own bar. Main also carries update affordances here; iPad drops
    /// them — `UpdateChecker` is a Sparkle-style self-updater, which is
    /// meaningless in an App Store app.
    ///
    /// This is the app's settings entry point when no document is open, so it
    /// has to survive the search revamp.
    private var homeHeader: some View {
        HStack(spacing: 8) {
            Text("Home")
                .font(.headline)
                .foregroundStyle(palette.foreground)
            Spacer()
            Button {
                showHelp = true
            } label: {
                Label("Help", systemImage: "questionmark.circle").labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("welcome.help")
            Button {
                // Setting the section BEFORE presenting is what makes #70's
                // "route Home to a specific tab" work; `SettingsView`'s
                // `TabView` binds straight to it.
                workspace.settingsSection = .general
                showSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape").labelStyle(.iconOnly)
            }
            .accessibilityIdentifier("welcome.settings")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(palette.background)
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15))
                .foregroundStyle(palette.mutedForeground)

            TextField("Search your library — or paste a link", text: $store.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(palette.foreground)
                .focused($searchFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.go)
                // `.webSearch` puts "/" and ".com" on the software keyboard,
                // which is right for a field that doubles as an address bar.
                .keyboardType(.webSearch)
                .accessibilityIdentifier("welcome.search")
                .onSubmit { _ = openSelection() }
                // Arrow keys walk the results while the caret stays in the
                // field, so a Magic Keyboard user never has to leave it.
                // Supported on iOS 17+. Return is handled by `.onSubmit`
                // above, so main's `.onKeyPress(.return)` is redundant here.
                .onKeyPress(.downArrow) {
                    store.moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    store.moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.escape) {
                    if store.clearQuery() { return .handled }
                    searchFocused = false
                    return .handled
                }

            if store.query.isEmpty {
                // Meaningful with a keyboard attached, and harmless without.
                Keycap(keys: "⌘F")
            } else {
                IconButton(help: "Clear search") {
                    _ = store.clearQuery()
                } icon: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 13))
                }
                .accessibilityIdentifier("welcome.clearSearch")
            }
        }
        .padding(.horizontal, HomeLayout.rowInset)
        .frame(height: 46)
        .glassEffect(.regular, in: .capsule)
        .overlay {
            // A hairline primary edge on focus, the same "this is current"
            // language `SelectionStyle` uses everywhere else.
            Capsule().strokeBorder(
                SelectionStyle.edge(palette, selected: searchFocused), lineWidth: 1)
        }
        .animation(.easeOut(duration: 0.12), value: searchFocused)
    }

    /// One row for "which library, and how am I looking at it": the source
    /// switcher, then the filters, then either the result count (while
    /// searching) or the sort menu.
    ///
    /// The switcher leads because it is the outer choice — it changes WHICH
    /// library is on screen, where the chips only narrow the one already there.
    /// A hairline sits between them so two adjacent groups of small pills do
    /// not read as one long row. Everything after the switcher belongs to the
    /// local library and leaves with it; a browsed account gets its sync state
    /// in that slot instead.
    ///
    /// Wrapped in a horizontal `ScrollView` because a start tab can be a third
    /// of a 13" screen wide, and four chips plus a sort menu clip there.
    private var controlBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                if sources.count > 1 {
                    HomeSourceSwitcher_iOS(sources: sources, selection: $source)

                    if browsedProvider == nil {
                        Divider()
                            .frame(height: 18)
                            .padding(.horizontal, 2)
                    }
                }

                if let provider = browsedProvider {
                    Spacer(minLength: 12)
                    sourceStatus(for: provider)
                } else {
                    ForEach(HomeSearchFilter.allCases, id: \.self) { option in
                        HomeFilterChip(label: option.label, isSelected: store.filter == option) {
                            // Main also hands first responder back to the field
                            // here; on iOS that would raise the software
                            // keyboard every time a chip is tapped, so it is
                            // dropped.
                            store.filter = option
                        }
                        .accessibilityIdentifier("welcome.filter.\(option.label)")
                    }

                    Spacer(minLength: 12)

                    if store.isSearching {
                        Text(store.resultCount == 1 ? "1 result" : "\(store.resultCount) results")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(palette.mutedForeground)
                            .accessibilityIdentifier("welcome.resultCount")
                    } else {
                        sortMenu
                    }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    /// Where the browsed account's sync stands, plus a way to push it.
    ///
    /// Takes the slot the sort menu holds for the local library, because it
    /// answers the same question that control does — "is what I'm looking at
    /// what I think it is?". Kept to one muted line: `ExternalLibraryList_iOS`
    /// already states the loud cases (authentication required, sync failed)
    /// over the list itself.
    private func sourceStatus(for provider: IntegrationProvider) -> some View {
        let state = integrations.providers[provider]
        let isSyncing = state?.connection == .syncing
        return HStack(spacing: 6) {
            if isSyncing {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
            }
            Text(syncLabel(for: state))
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .accessibilityIdentifier("welcome.source.status")

            IconButton(help: "Sync \(provider.name) now", disabled: isSyncing) {
                // Store-owned rather than a bare `Task`: this is background work
                // started from a view a pane change can tear down at any moment,
                // and the store's scene-background drain joins what it started
                // (root CLAUDE.md — never drop the handle).
                integrations.run { await integrations.sync(provider) }
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .accessibilityIdentifier("welcome.source.sync")
        }
        // Main hangs the full `statusMessage` off `.help`; iPad has no hover, so
        // the sentence-length form becomes a VoiceOver hint on the short one.
        .accessibilityHint(state?.statusMessage ?? syncLabel(for: state))
    }

    /// The short form of a provider's connection state. `nil`/`.connected`
    /// falls through to when the account last synced, because a healthy
    /// integration's only interesting fact is its freshness.
    private func syncLabel(for state: IntegrationProviderViewState?) -> String {
        switch state?.connection {
        case .syncing: "Syncing…"
        case .connecting: "Connecting…"
        case .tokenRejected: "Reconnect in Settings"
        case .offlineCache: "Offline — cached"
        case .failed: "Sync failed"
        default:
            state?.lastSuccessfulSync
                .map { "Synced \($0.formatted(.relative(presentation: .numeric)))" }
                ?? "Not synced yet"
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $store.sort) {
                ForEach(HomeSearchSortOrder.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12))
                Text(store.sort.label)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        // `.borderlessButton` is macOS-only.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .fixedSize()
        .foregroundStyle(palette.mutedForeground)
        .accessibilityIdentifier("welcome.sort")
    }

    // MARK: - Results

    private var resultList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if let link = store.linkSuggestion {
                        HomeLinkActionRow(
                            url: link,
                            isSelected: store.selectedId == HomeSearchStore.linkRowId,
                            open: { openLink(link) }
                        )
                        .id(HomeSearchStore.linkRowId)
                        .padding(.top, 10)
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
                                .id(item.id)
                            }
                        } header: {
                            HomeSectionHeader(section: group.section, count: group.items.count)
                        }
                    }

                    // A pinned link IS the answer to a pasted URL, so "no
                    // matches" would be both wrong and unhelpful next to it.
                    if store.sections.isEmpty, store.linkSuggestion == nil, !store.isLoading {
                        emptyResults
                            .frame(maxWidth: .infinity)
                            .padding(.top, 56)
                    }
                }
                .homeContentColumn()
                .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            // Let a scroll put the software keyboard away instead of trapping
            // the reader behind it.
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("welcome.results")
            .onChange(of: store.selectedId) { _, id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
    }

    /// Two different "nothing here" messages, because they need two different
    /// answers: a failed search wants advice on widening it, an empty filter
    /// wants a way back to All.
    @ViewBuilder
    private var emptyResults: some View {
        VStack(spacing: 8) {
            Image(systemName: store.isSearching ? "magnifyingglass" : "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(palette.mutedForeground)
                .padding(.bottom, 4)

            if store.isSearching {
                Text("No matches for “\(store.trimmedQuery)”")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.foreground)
                Text("Search matches titles, filenames, and web addresses. Try fewer words.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .multilineTextAlignment(.center)
            } else {
                Text("Nothing in \(store.filter.label) yet")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.foreground)
                Text("Open a PDF or add a webpage and it will show up here.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
            }

            // One button that undoes BOTH constraints, because from the outside
            // a query that matches nothing and a filter that excludes
            // everything produce the identical blank screen — asking the user
            // to work out which one to lift is a puzzle. The label names
            // whichever is the likelier culprit.
            if store.isSearching || store.filter != .all {
                TextButton(variant: .secondary, size: .sm) {
                    store.resetSearch()
                } label: {
                    Text(store.isSearching ? "Clear search" : "Search everything")
                }
                .padding(.top, 6)
                .accessibilityIdentifier("welcome.resetSearch")
            }

            // A source that failed to load has silently narrowed the search —
            // say so rather than letting the user conclude the document is gone.
            ForEach(store.failures, id: \.self) { failure in
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.destructive)
            }
        }
        .frame(maxWidth: 420)
        .accessibilityIdentifier("welcome.emptyResults")
    }

    // MARK: - First run

    /// The iPad keeps its own hero identity rather than main's: it cannot show
    /// an `NSOpenPanel`, and opening already routes through
    /// `DocumentPickerCoordinator_iOS` behind `onOpen`. Main's error banner and
    /// walkthrough link are added to it.
    private var firstRunLayout: some View {
        ScrollView {
            VStack(spacing: compact ? 24 : 36) {
                VStack(spacing: 12) {
                    Wordmark(size: compact ? 40 : 60)
                    // Derived from the idiom rather than hard-coded (#153 P4):
                    // one binary serves both device families, and this screen
                    // is still reachable on a phone through `PaneView_iOS`'s
                    // compact start tab.
                    Text(PhoneHome_iOS.tagline)
                        .font(compact ? .headline : .title3)
                        .foregroundStyle(palette.mutedForeground)
                }

                HStack(spacing: 12) {
                    TextButton(variant: .primary, size: .lg, action: onOpen) {
                        Label("Open a PDF", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("welcome.openPdf")
                    TextButton(variant: .secondary, size: .lg, action: onAddWebpage) {
                        Label("Add Webpage", systemImage: "globe")
                    }
                    .accessibilityIdentifier("welcome.addWebpage")
                }

                errorBanner
                walkthroughLink
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, compact ? 32 : 72)
            .padding(.bottom, 48)
        }
    }

    private var walkthroughLink: some View {
        Button(action: openWalkthrough) {
            HStack(spacing: 5) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                Text("How Vellum works")
                    .font(.system(size: 12))
            }
            .foregroundStyle(palette.mutedForeground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("welcome.walkthrough")
        .padding(.top, 28)
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let error = appStore.error {
            Text(error)
                .font(.system(size: 14))
                .foregroundStyle(palette.destructive)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .frame(maxWidth: 448)
                .background(palette.destructive.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(palette.destructive.opacity(0.3))
                }
                .padding(.top, 20)
        }
    }

    // MARK: - Actions

    /// Routed through the root scene rather than presented here: the
    /// walkthrough outlives this screen (it stays reachable once a document is
    /// open), so `VellumApp_iOS` owns its presentation state.
    private func openWalkthrough() {
        NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
    }

    /// Return: open whatever the keyboard is on. With nothing selected but a
    /// link typed, open the link — that is the ⌘V ↩ path.
    @discardableResult
    private func openSelection() -> KeyPress.Result {
        if store.selectedId == HomeSearchStore.linkRowId, let link = store.linkSuggestion {
            openLink(link)
            return .handled
        }
        if let item = store.selectedItem {
            open(item)
            return .handled
        }
        if let link = store.linkSuggestion {
            openLink(link)
            return .handled
        }
        return .ignored
    }

    private func open(_ item: HomeSearchItem) {
        guard !appStore.isLoading else { return }
        // A read-later hit opens the way it would from the account's own list:
        // an article opens its page, a PDF is downloaded (with progress, see
        // `readLaterNotice`) and opened from the cache. The corpus is a
        // snapshot, so the lookup can legitimately miss — the article was
        // un-saved, or the account disconnected, since it was indexed — and the
        // row's plain URL target is then still the right thing to open.
        if item.section == .readLater,
           let external = integrations.readLaterItem(forOpenDocumentPath: item.target.openKey) {
            openExternal(external)
            return
        }
        // The moved-PDF and reinstalled-container rules now live in
        // `HomeOpenResolver` (#153 P4), which the phone Home shares — they are
        // both invisible until they misfire, which is precisely why they must
        // not exist twice.
        switch HomeOpenResolver.intent(
            for: item.target, resolveExisting: DocumentImport.resolveExistingPath
        ) {
        case .url(let url):
            Task { await appStore.openUrl(url) }
        case .file(let path, let staleRecentPath):
            if let staleRecentPath {
                _ = RecentFilesService.remove(path: staleRecentPath)
            }
            Task { await appStore.openFiles(paths: [path]) }
        }
    }

    /// The same route `ExternalLibraryList_iOS` takes, so a row opened from
    /// search and the identical row opened from the account's library cannot
    /// diverge: `route(for:)` returns the web address for an article and
    /// downloads a PDF (or reuses an existing download) before handing back its
    /// file URL.
    ///
    /// Store-owned rather than a bare `Task` — a download outlives this screen,
    /// which a pane change can tear down mid-flight, and the store's
    /// scene-background drain joins what it started. The error is not
    /// swallowed: `route(for:)` parks it as a notice, which `readLaterNotice`
    /// is here to show.
    private func openExternal(_ item: ReadLaterItem) {
        integrations.run {
            guard let route = try? await integrations.route(for: item) else { return }
            switch route {
            case .web(let url): await appStore.openUrl(url.absoluteString)
            case .file(let url): await appStore.openFiles(paths: [url.path])
            }
        }
    }

    private func openLink(_ link: String) {
        guard !appStore.isLoading else { return }
        store.query = ""
        Task { await appStore.openUrl(link) }
    }

    /// iPad's answer to "Show in Finder". Only offered when the file is
    /// actually on disk, which is what `canRevealInFinder` records.
    private func shareTarget(for item: HomeSearchItem) -> String? {
        guard item.canRevealInFinder, case .file(let path, _) = item.target else { return nil }
        return path
    }
}

// MARK: - Source switcher

/// Which library the home screen is showing.
///
/// A source is a MODE, not a facet: picking an account swaps the entire result
/// area for that provider's list, where a `HomeSearchFilter` only narrows the
/// rows already on screen. Keeping them different controls (a segmented track
/// versus flat chips) is what keeps that difference legible.
enum HomeSource: Hashable {
    case library
    case provider(IntegrationProvider)

    var title: String {
        switch self {
        case .library: "Library"
        case .provider(let provider): provider.name
        }
    }

    /// Same SF Symbols vocabulary as the result sections: the local library is
    /// the tray everything lands in, an account keeps the glyph it already uses
    /// in Settings.
    var systemImage: String {
        switch self {
        case .library: "tray.full"
        case .provider(let provider): provider.symbol
        }
    }

    /// Automation identifier, derived from the CASE and never from the display
    /// label — the convention `InspectorTabSwitcher` settled on after the old
    /// `GlassSegmentedPicker` interpolated titles and silently emitted
    /// identifiers no lookup could match. (That picker is gone from this tree
    /// entirely; packet 4 retired it in Stage F.)
    var accessibilityIdentifier: String {
        switch self {
        case .library: "welcome.source.library"
        case .provider(let provider): "welcome.source.\(provider.rawValue)"
        }
    }

    /// The switcher's options: the local library, then one per connected
    /// account in `IntegrationProvider.allCases` order so the row never
    /// reshuffles between launches.
    static func options(connected: [IntegrationProvider]) -> [HomeSource] {
        [.library] + connected.map(HomeSource.provider)
    }

    /// Keep a selection meaningful when the connected set changes: an account
    /// that has just been disconnected has no library to show, so the screen
    /// falls back to the local one. Mirrors
    /// `ExternalLibraryFilter.reconciledCollectionID`, which does the same job
    /// for a collection that disappeared underneath its filter.
    static func reconciled(
        _ selection: HomeSource, connected: [IntegrationProvider]
    ) -> HomeSource {
        if case .provider(let provider) = selection, !connected.contains(provider) {
            return .library
        }
        return selection
    }
}

/// Library plus one segment per connected read-later account.
///
/// An `HStack` of plain buttons over a `palette.muted` track — the segmented
/// idiom `InspectorTabSwitcher` landed on when `GlassSegmentedPicker` was
/// retired, and the language `HomeFilterChip` beside it already speaks.
///
/// Main's macOS twin wraps this in `ViewThatFits` with three tiers (full
/// labels → icons → menu) because "Readwise Reader" and "Raindrop.io" are long
/// labels sharing a fixed-width row with four filter chips and a sort menu.
/// That tiering is deliberately NOT ported: packet 3's iPad control row is a
/// horizontal `ScrollView`, which proposes unbounded width, so `ViewThatFits`
/// would always pick the first tier and the other two would be dead code. The
/// scroll IS this screen's overflow answer, and it keeps every label readable
/// instead of degrading them to glyphs.
///
/// Segment height matches `HomeFilterChip`'s 32pt rather than main's 26 — the
/// same reason that chip gives: 26 is a pointer target, 32 is the smallest
/// honest touch target that still reads as a chip.
struct HomeSourceSwitcher_iOS: View {
    let sources: [HomeSource]
    @Binding var selection: HomeSource

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sources, id: \.self) { source in
                segment(source)
            }
        }
        .padding(2)
        // The recessed track, from the palette rather than a scheme-derived
        // `.quaternary`: the latter washes out against the light parchment
        // chrome, which is what sent `Keycap` to `palette.muted` in #70.
        .background(palette.muted, in: Capsule())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library source")
        .accessibilityValue(selection.title)
    }

    private func segment(_ source: HomeSource) -> some View {
        let isSelected = selection == source
        return Button {
            withAnimation(.snappy) { selection = source }
        } label: {
            Label(source.title, systemImage: source.systemImage)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(
                    SelectionStyle.foreground(palette, selected: isSelected, hovering: false))
                // Padding, frame, surface and shape all INSIDE the label: a
                // `.plain` button hit-tests against its label's rendered
                // content on macOS, and keeping the two platforms structurally
                // identical is what stops the next port re-introducing #112.
                .padding(.horizontal, 10)
                .frame(height: 32)
                .selectionSurface(
                    selected: isSelected, hovering: false, in: Capsule(), palette: palette)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(source.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(source.accessibilityIdentifier)
    }
}

#endif
