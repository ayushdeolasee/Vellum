import AppKit
import SwiftUI
import UniformTypeIdentifiers

// The app's front door (issue #62).
//
// The old welcome screen listed Recent and Saved and nothing else, which meant
// anything past the eighth document was unreachable without the Finder. This
// version is built around one prominent search field that ranks EVERY source
// the app knows about — recents, saved webpages, and every document carrying
// notes in the library — plus a browse view for when the field is empty.
//
// Layout: a single centered content column (capped, so a wide window doesn't
// stretch rows into an unreadable ribbon) holding a compact header, the search
// field, a filter/sort bar, and the result list.
//
// Search architecture: this view owns no matching logic at all. It reads
// `HomeSearchStore` (main-actor, observable, debounced selection + query),
// which talks to `HomeSearchEngine` (an actor), which fans out to
// `HomeSearchProvider`s. See `HomeSearchProvider.swift` for how a connected
// read-later account will slot in.
//
// Connected read-later accounts (Readwise, Raindrop) reach this screen twice,
// and the two paths are deliberately different:
//
//  1. BROWSING. The control bar grows a source switcher — Library plus one
//     segment per connected account — and picking an account swaps the result
//     area for that provider's own `ExternalLibraryList`. That list brings its
//     own search field, collection filter and context menus, so the library's
//     search field and filter chips step aside while it is on screen rather
//     than sitting above a list they cannot drive.
//  2. SEARCHING. A read-later `HomeSearchProvider` — the extension point
//     `HomeSearchProvider.swift` describes — puts those articles in the
//     ordinary corpus, ranked against everything else under the `.readLater`
//     section. This screen's half of that is `open(_:)`, which routes a
//     `.readLater` row back through `IntegrationsStore` (an article opens its
//     page, a PDF is downloaded first) so a search hit behaves exactly like
//     the same row clicked inside the provider's own library.

struct WelcomeScreen: View {
    /// Whether the pane hosting this screen is the focused one. A split window
    /// can show two welcome screens; only the focused one may grab the keyboard.
    var isPaneFocused = true

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette
    @Environment(\.openSettings) private var openSettings
    /// Session-scoped Undo for "Remove from Recent" (issue #103), registered
    /// the same way PR #79 registers clear-conversation and clear-scratchpad.
    @Environment(\.undoManager) private var undoManager

    @State private var store = HomeSearchStore()
    /// Which library the screen is showing: the local one, or a connected
    /// read-later account's. Reset to `.library` when the account being browsed
    /// is disconnected — see the `connectedProviders` change handler.
    @State private var source: HomeSource = .library
    /// First-run hero only. The library layout uses the search field itself for
    /// links (see `HomeSearchLinkDetector`) plus the Add Webpage button.
    @State private var urlInput = ""
    /// The row whose rename sheet is open, if any.
    @State private var renamingItem: HomeSearchItem?
    /// The removal waiting on its confirmation dialog, if any.
    @State private var confirmingRemoval: PendingRemoval?
    @FocusState private var searchFocused: Bool

    /// Title for the confirmation, held separately and never cleared on
    /// dismissal: `confirmingRemoval` goes nil the instant the dialog starts
    /// closing, and reading it for the title (which is evaluated outside
    /// `presenting:`) would blank the heading mid-animation while the buttons
    /// and message still render.
    @State private var confirmingTitle = ""

    /// A destructive removal held back until the user confirms it. Carries the
    /// row as well as the action so the dialog can name what it is about to
    /// un-save.
    private struct PendingRemoval {
        let item: HomeSearchItem
        let removal: HomeSearchRemoval
    }

    private var updateChecker: UpdateChecker { workspace.updateChecker }

    /// The calm first-run hero, shown only once we KNOW there is nothing to
    /// browse — never while the first load is still in flight, or the screen
    /// would flash "welcome" at someone with a full library.
    ///
    /// This replaces main's `hasLibrary` (which read `recentDocuments` /
    /// `savedPages` directly): the corpus now comes from `HomeSearchStore`,
    /// which knows about library documents too, not just recents and saved
    /// pages, and which can distinguish "empty" from "not loaded yet".
    private var showsFirstRun: Bool {
        // Someone who has switched to an account is browsing, whatever the
        // local library holds — and that account's list has its own, better
        // empty state ("Nothing saved yet — sync this service…"). Yanking them
        // to the hero because a sync briefly emptied the list would also take
        // the switcher away, leaving no way back.
        guard browsedProvider == nil else { return false }
        return !store.isLoading && store.libraryIsEmpty && !store.isSearching
            && !hasConnectedLibrary
    }

    /// Whether a connected account is holding anything to read.
    ///
    /// It counts as "has a library" for the same reason recents and saved pages
    /// do: the hero is for someone with nothing to open, and this reader has a
    /// shelf of articles one click away. The corpus gets there on its own once
    /// the read-later provider has been indexed — this term is what stops the
    /// hero flashing in the window before that lands, and what keeps the source
    /// switcher reachable for a reader whose ONLY content is a connected
    /// account. A connected account with nothing in it is not a library, so it
    /// still gets the hero (and its "open a PDF" affordances) rather than an
    /// empty list.
    private var hasConnectedLibrary: Bool {
        integrations.connectedProviders.contains { provider in
            !(integrations.providers[provider]?.items.isEmpty ?? true)
        }
    }

    /// Library plus one entry per connected account, in `IntegrationProvider`
    /// order. One entry means nothing is connected, and the switcher never
    /// appears — a reader with no integrations sees the home screen unchanged.
    private var sources: [HomeSource] {
        HomeSource.options(connected: integrations.connectedProviders)
    }

    /// The account whose own library is on screen, if any. Nil is the local
    /// library — i.e. everything main's home screen already does.
    private var browsedProvider: IntegrationProvider? {
        if case .provider(let provider) = source { return provider }
        return nil
    }

    var body: some View {
        // #70's Home chrome — title, update affordances, settings gear — stays
        // above BOTH layouts exactly as it did on main. The search revamp
        // replaces only what used to live below this divider.
        VStack(spacing: 0) {
            homeHeader
            Divider()
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
        // covering the corpus a previous screen already synced.
        .task(id: integrations.searchRevision) {
            await store.updateReadLater(integrations.searchableItems)
        }
        .onAppear {
            // Focus the field on arrival so the front door is type-ready — but
            // only in the focused pane, or two side-by-side welcome screens
            // would fight over first responder.
            if isPaneFocused { searchFocused = true }
        }
        .onDisappear {
            // `registerUndo(withTarget:)` does NOT retain its target, and this
            // screen owns `store` as `@State` — opening a document swaps the
            // whole view out and deallocates it. Leaving the registration in
            // place would leave a dead target on the window-wide undo stack,
            // and "Undo Remove from Recent" sitting in the Edit menu of a
            // reader that has no recents list on screen. The undo's session is
            // this screen's lifetime, so it leaves with it.
            undoManager?.removeAllActions(withTarget: store)
        }
        // A disconnected account has no library left to show — and its state is
        // wiped by `IntegrationsStore.disconnect`, so leaving the screen on it
        // would park the reader in front of a permanently empty list. The
        // fallback is the local library, which always exists.
        .onChange(of: integrations.connectedProviders) { _, connected in
            source = HomeSource.reconciled(source, connected: connected)
        }
        // Re-index when the app comes back to the front. The corpus is a
        // snapshot of three on-disk sources, and all three can change while
        // Vellum is in the background — the other pane opens a document, the
        // Storage pane deletes one, a file is moved or deleted in the Finder.
        // Without this the home screen keeps confidently offering rows that no
        // longer exist until the pane is rebuilt. The reload is off the main
        // thread on `HomeSearchEngine` and leaves the current results on screen
        // while it runs, so the cost of being wrong here is far higher than the
        // cost of the walk.
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            Task { await store.load() }
        }
        .sheet(item: $renamingItem) { item in
            RenameDocumentSheet(
                currentTitle: item.title,
                // `subtitle` is the filename for a PDF and host+path for a
                // page — exactly what the row falls back to with no override.
                fallbackName: item.subtitle,
                commit: { newTitle in
                    Task { await store.rename(item, to: newTitle) }
                })
        }
        .confirmationDialog(
            Text(confirmingTitle),
            isPresented: Binding(
                get: { confirmingRemoval != nil },
                set: { if !$0 { confirmingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: confirmingRemoval
        ) { pending in
            Button(pending.removal.confirmLabel, role: .destructive) {
                performRemoval(pending.item, from: pending.removal)
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            if let message = pending.removal.confirmationMessage {
                Text(message)
            }
        }
        .background {
            // ⌘F focuses the search field here. The menu's Find… command and the
            // window's key monitor both bail out when there is no document open
            // (which is exactly when this screen is on screen), so the chord is
            // free to mean "search my library".
            Button("Search Library", action: focusSearchField)
                .keyboardShortcut("f", modifiers: .command)
                .buttonStyle(.plain)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                // A split window can host TWO welcome screens, and each would
                // otherwise register the same ⌘F. SwiftUI picks between
                // duplicate shortcuts arbitrarily, so ⌘F could hand the
                // keyboard to the pane the user is not looking at. Disabling
                // the shortcut in the unfocused pane leaves exactly one
                // claimant. (`.disabled` suppresses the key equivalent too,
                // which is the whole point — `.hidden()` would also drop it
                // but would take the button out of the layout.)
                .disabled(!isPaneFocused)
        }
    }

    // MARK: - Library layout

    private var libraryLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                header
                // A connected account's list owns its own search field (and its
                // own collection filter and sort), so the library's field steps
                // aside instead of sitting above a list it cannot drive. ⌘F
                // still means "search my library" — it comes back here first,
                // see `focusSearchField`.
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
                // its own insets and full-width list chrome (it is the same view
                // the settings pane shows), and nesting it in the capped column
                // would double every horizontal inset it applies.
                //
                // `.id(provider)` so switching accounts rebuilds it: its search
                // text and collection selection belong to one account, and
                // carrying them across would filter Raindrop by a Readwise
                // location that does not exist there.
                ExternalLibraryList(provider: provider)
                    .id(provider)
            } else {
                resultList
            }
        }
        // Progress and failures for a read-later PDF opened from a SEARCH
        // result. `ExternalLibraryList` floats this itself, so it is only added
        // under the library list — without it, clicking a Readwise PDF row here
        // would look like nothing happened for the length of the download.
        .overlay(alignment: .bottomTrailing) {
            if browsedProvider == nil {
                readLaterNotice
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "doc.text")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 44, height: 44)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))

            VStack(alignment: .leading, spacing: 2) {
                Wordmark(size: 22)
                Text("Everything you've read, in one place.")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
            }

            Spacer(minLength: 12)

            TextButton(disabled: appStore.isLoading, action: openDocuments) {
                Image(systemName: "folder")
                    .font(.system(size: 14))
                Text(appStore.isLoading ? "Opening…" : "Open a PDF")
            }
            .accessibilityIdentifier("welcome.openPdf")

            TextButton(variant: .secondary, disabled: appStore.isLoading) {
                NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 14))
                Text("Add Webpage")
            }
            .help("Open a webpage by URL (⌘L)")
            .accessibilityIdentifier("welcome.addWebpage")

            // #65's walkthrough entry point. Returning users get the compact
            // icon form — this header is already dense, and they've seen the
            // offer before; the first-run hero spells it out as a text link
            // instead. The two layouts are mutually exclusive, so exactly one
            // `welcome.walkthrough` is ever on screen.
            IconButton(help: "A short walkthrough of Vellum's features", action: openWalkthrough) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 14))
            }
            .accessibilityIdentifier("welcome.walkthrough")
        }
    }

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
                .accessibilityIdentifier("welcome.search")
                // Arrow keys walk the results while the caret stays in the
                // field, so the user never has to leave the keyboard or tab
                // into the list. Return opens; Escape clears then unfocuses.
                .onKeyPress(.downArrow) {
                    store.moveSelection(1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    store.moveSelection(-1)
                    return .handled
                }
                .onKeyPress(.return) { openSelection() }
                .onKeyPress(.escape) {
                    if store.clearQuery() { return .handled }
                    searchFocused = false
                    return .handled
                }

            if store.query.isEmpty {
                Keycap(keys: "⌘F")
            } else {
                IconButton(help: "Clear search") {
                    store.clearQuery()
                    focusSearchField()
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

    /// One row for "which library, and how am I looking at it".
    ///
    /// The source switcher leads it because it is the outer choice: it changes
    /// WHICH library is on screen, where the chips only narrow the one already
    /// there. That difference is why they are not all chips — the switcher is
    /// the segmented control, sitting on its own track, with a hairline between
    /// it and the filters so two adjacent groups of small pills do not read as
    /// one seven-option row. Everything after the switcher belongs to the local
    /// library and leaves with it; a browsed account gets its sync state there
    /// instead.
    private var controlBar: some View {
        HStack(spacing: 8) {
            if sources.count > 1 {
                HomeSourceSwitcher(sources: sources, selection: $source)

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
                        store.filter = option
                        // Clicking a chip moves first responder to the button; hand
                        // the keyboard straight back so typing continues to search.
                        focusSearchField()
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
    }

    /// Where the browsed account's sync stands, plus a way to push it.
    ///
    /// Takes the slot the sort menu holds for the local library, because it
    /// answers the same question that control does — "is what I'm looking at
    /// what I think it is?". Kept to one muted line: `ExternalLibraryList`
    /// already states the loud cases (authentication required, sync failed)
    /// over the list itself, so repeating them at full volume here would say
    /// the same thing twice.
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
                // started from a view that a pane change can tear down at any
                // moment, and the store's quit barrier drains it (root
                // CLAUDE.md — never drop the handle).
                integrations.run { await integrations.sync(provider) }
            } icon: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12))
            }
            .accessibilityIdentifier("welcome.source.sync")
        }
        // The full statusMessage can be a sentence ("malformed records were
        // skipped…"), which is more than the row has space for but exactly what
        // someone hovering the short form is asking for.
        .help(state?.statusMessage ?? syncLabel(for: state))
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
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(palette.mutedForeground)
        .help("Change how the library is sorted")
        .accessibilityIdentifier("welcome.sort")
    }

    // MARK: - Home chrome (from #70)

    /// The window's Home bar. Carried over from #70 unchanged: it is the app's
    /// only settings entry point outside ⌘, so it has to survive the revamp.
    private var homeHeader: some View {
        HStack(spacing: 8) {
            Text("Home")
                .font(.headline)
                .foregroundStyle(palette.foreground)
            Spacer()
            if updateChecker.state == .available,
               let version = updateChecker.availableVersion {
                Button {
                    updateChecker.install()
                } label: {
                    Label("Install Update \(version)", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.borderless)
                .help(updateChecker.tooltip)
                .accessibilityIdentifier("welcome.installUpdate")
            }
            Button {
                Task { await updateChecker.check() }
            } label: {
                Label("Check for Updates", systemImage: "arrow.clockwise")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .disabled(updateChecker.state == .checking)
            .help(updateChecker.tooltip)
            .accessibilityIdentifier("welcome.checkForUpdates")

            Button(action: showSettings) {
                Label("Settings", systemImage: "gearshape")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Settings… (⌘,)")
            .accessibilityIdentifier("welcome.settings")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(palette.background)
    }

    private func showSettings() {
        workspace.settingsSection = .general
        openSettings()
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
                                    reveal: revealAction(for: item),
                                    rename: renameAction(for: item),
                                    removals: removalActions(for: item)
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
                    focusSearchField()
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

    // MARK: - First-run hero

    private var firstRunLayout: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                openControls
                urlControls
                errorBanner
                walkthroughLink
            }
            .frame(maxWidth: 672)
            .padding(.horizontal, 24)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.xxl))
                .padding(.bottom, 12)

            Wordmark(size: 36)

            Text("A quiet place to read, annotate, and think alongside your documents.")
                .font(.system(size: 14))
                .foregroundStyle(palette.mutedForeground)
                .padding(.top, 8)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            TextButton(size: .lg, disabled: appStore.isLoading, action: openDocuments) {
                Image(systemName: "folder")
                    .font(.system(size: 18))
                Text(appStore.isLoading ? "Opening…" : "Open a PDF")
            }
            .accessibilityIdentifier("welcome.openPdf")

            HStack(spacing: 4) {
                Text("or press")
                Keycap(keys: "⌘O")
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.mutedForeground)
        }
        .padding(.top, 28)
    }

    /// First-run readers land on this screen with nothing open, so the empty
    /// layout gets the walkthrough as a full text link rather than an icon —
    /// it's the one moment the offer is worth spelling out.
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
        .help("A short walkthrough of Vellum's features")
        .accessibilityIdentifier("welcome.walkthrough")
        .padding(.top, 28)
    }

    private var urlControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.mutedForeground)
                TextField("Or read a webpage — paste an article URL", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.foreground)
                    .disabled(appStore.isLoading)
                    .onSubmit(openTypedUrl)
                    .accessibilityIdentifier("welcome.urlField")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)

            TextButton(
                disabled: appStore.isLoading || trimmedUrlInput.isEmpty,
                action: openTypedUrl
            ) {
                Text("Open")
            }
            .accessibilityIdentifier("welcome.openUrl")
        }
        .frame(maxWidth: 448)
        .padding(.top, 16)
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

    private var trimmedUrlInput: String {
        urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Routed through the window rather than presented here: the walkthrough
    /// outlives this screen (it stays reachable once a document is open), so
    /// the window owns its presentation state.
    private func openWalkthrough() {
        NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
    }

    /// ⌘F (and every control that hands the keyboard back) means "search my
    /// library", so it returns from a connected account's list first. Focusing
    /// a field that is not on screen would otherwise make the chord look dead
    /// in exactly the place a reader is most likely to try it.
    private func focusSearchField() {
        source = .library
        searchFocused = true
    }

    /// Return: open whatever the keyboard is on. With nothing selected but a
    /// link typed, open the link — that is the ⌘V ↩ path.
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
        switch item.target {
        case .url(let url):
            Task { await appStore.openUrl(url) }
        case .file(let path, let recordedPath):
            // A moved PDF re-resolved to a new path: drop the stale recents
            // entry so the re-record on open can't leave a duplicate (§7).
            if path != recordedPath {
                _ = RecentFilesService.remove(path: recordedPath)
            }
            Task { await appStore.openFile(path: path) }
        }
    }

    /// The same route `ExternalLibraryList` takes, so a row opened from search
    /// and the identical row opened from the account's library cannot diverge:
    /// `route(for:)` returns the web address for an article and downloads a PDF
    /// (or reuses an existing download) before handing back its file URL.
    ///
    /// Store-owned rather than a bare `Task` — a download outlives this screen,
    /// which a pane change can tear down mid-flight, and the store's quit
    /// barrier drains what it started. The error is not swallowed: `route(for:)`
    /// parks it as a notice, which `readLaterNotice` is here to show.
    private func openExternal(_ item: ReadLaterItem) {
        integrations.run {
            guard let route = try? await integrations.route(for: item) else { return }
            switch route {
            case .web(let url): await appStore.openUrl(url.absoluteString)
            case .file(let url): await appStore.openFile(path: url.path)
            }
        }
    }

    private func openLink(_ link: String) {
        guard !appStore.isLoading else { return }
        store.query = ""
        Task { await appStore.openUrl(link) }
    }

    private func openTypedUrl() {
        let value = trimmedUrlInput
        guard !value.isEmpty else { return }
        urlInput = ""
        Task { await appStore.openUrl(value) }
    }

    /// Context-menu actions are built here rather than inline in the row's
    /// argument list: a ternary between a closure literal and `nil` gives the
    /// type checker no way to resolve the closure's own body.
    private func revealAction(for item: HomeSearchItem) -> (() -> Void)? {
        guard item.canRevealInFinder, case .file(let path, _) = item.target else { return nil }
        return { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    }

    private func renameAction(for item: HomeSearchItem) -> (() -> Void)? {
        guard store.canRename(item) else { return nil }
        return { renamingItem = item }
    }

    private func removalActions(
        for item: HomeSearchItem
    ) -> [(removal: HomeSearchRemoval, action: () -> Void)] {
        store.removalOptions(for: item).map { removal in
            // The closure is annotated rather than inferred so the type checker
            // resolves its body independently of the surrounding `map`.
            let action: () -> Void = {
                // Issue #103: neither removal used to stop for anything. The
                // irreversible one now asks; the reversible one still fires on
                // the click and offers ⌘Z (see `performRemoval`).
                if removal.requiresConfirmation {
                    confirmingTitle = removal.confirmationTitle(for: item.title)
                    confirmingRemoval = PendingRemoval(item: item, removal: removal)
                } else {
                    performRemoval(item, from: removal)
                }
            }
            return (removal, action)
        }
    }

    /// Do the removal and, when it produced something undoable, put it on the
    /// window's undo stack.
    private func performRemoval(_ item: HomeSearchItem, from removal: HomeSearchRemoval) {
        switch removal {
        case .recent:
            // Registered synchronously, before the reload: `load()` rebuilds the
            // whole corpus, and a ⌘Z landing during it would pop whatever was on
            // the window's stack beforehand instead of this removal.
            let transaction = store.removeFromRecent(item)
            // SwiftUI only supplies `\.undoManager` where the environment
            // supports it; without one the removal simply stands, exactly as it
            // did before. Same fallback as the AI panel and scratchpad.
            if let transaction, let undoManager {
                registerRecentRemovalUndo(transaction, store: store, undoManager: undoManager)
            }
            Task { await store.load() }
        case .saved:
            Task { await store.removeFromSaved(item) }
        }
    }

    private func openDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") {
            types.append(archive)
        }
        if let bundle = UTType(filenameExtension: "vellum") {
            types.append(bundle)
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await appStore.openFiles(paths: paths) }
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
    /// identifiers no lookup could match.
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
/// An `HStack` of plain buttons over a `palette.muted` track: the segmented
/// idiom `InspectorTabSwitcher` landed on when `GlassSegmentedPicker` was
/// removed, and the same three-tier degradation — full labels, then icons, then
/// a menu — because "Readwise Reader" and "Raindrop.io" are long labels sharing
/// a row with four filter chips and a sort menu. `ViewThatFits` decides instead
/// of `GeometryReader` + width thresholds precisely because of that: what this
/// control has to fit into is whatever its neighbours leave it, which is not a
/// number it can be told in advance.
struct HomeSourceSwitcher: View {
    let sources: [HomeSource]
    @Binding var selection: HomeSource

    @Environment(\.palette) private var palette
    /// Hovered segment, so an unselected one previews the selection surface the
    /// way the filter chips beside it do.
    @State private var hovering: HomeSource?

    var body: some View {
        ViewThatFits(in: .horizontal) {
            track(showTitles: true)
            track(showTitles: false)
            menu
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library source")
        .accessibilityValue(selection.title)
    }

    private func track(showTitles: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(sources, id: \.self) { source in
                segment(source, showTitle: showTitles)
            }
        }
        .padding(2)
        // The recessed track, from the palette rather than a scheme-derived
        // `.quaternary`: the latter washes out against the light parchment
        // chrome, which is what sent `Keycap` to `palette.muted` in #70.
        .background(palette.muted, in: Capsule())
    }

    private func segment(_ source: HomeSource, showTitle: Bool) -> some View {
        let isSelected = selection == source
        let isHovering = hovering == source
        return Button {
            withAnimation(.snappy) { selection = source }
        } label: {
            Group {
                if showTitle {
                    Label(source.title, systemImage: source.systemImage)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                } else {
                    Label(source.title, systemImage: source.systemImage)
                        .labelStyle(.iconOnly)
                }
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(
                SelectionStyle.foreground(palette, selected: isSelected, hovering: isHovering))
            // Padding, frame, surface and shape all INSIDE the label: a
            // `.plain` button hit-tests against its label's rendered content,
            // so the same chain applied to the Button would move the layout
            // and leave the clickable region on the glyph (the trap both
            // `InspectorTabSwitcher` and `HomeFilterChip` document).
            .padding(.horizontal, 10)
            .frame(height: 26)
            .selectionSurface(
                selected: isSelected, hovering: isHovering, in: Capsule(), palette: palette)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 ? source : nil }
        // The icons-only tier is unreadable without this, and it costs the
        // full-label tier nothing.
        .help(source.title)
        .accessibilityLabel(source.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(source.accessibilityIdentifier)
    }

    /// Last resort, and reachable in a narrow pane rather than only in theory —
    /// two accounts plus the filter chips is genuinely more than a split pane's
    /// control row can hold. Styled as the sort menu beside it.
    private var menu: some View {
        Menu {
            ForEach(sources, id: \.self) { source in
                Button {
                    selection = source
                } label: {
                    Label {
                        Text(source.title)
                    } icon: {
                        Image(
                            systemName: selection == source ? "checkmark" : source.systemImage)
                    }
                }
                .accessibilityIdentifier(source.accessibilityIdentifier)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: selection.systemImage)
                    .font(.system(size: 12))
                Text(selection.title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(palette.mutedForeground)
        .help("Choose which library to browse")
        .accessibilityIdentifier("welcome.source.menu")
    }
}

/// Undo/redo registration for "Remove from Recent", mirroring
/// `registerConversationUndo` / `registerScratchpadUndo` from PR #79: each step
/// registers its counterpart, so ⌘Z and ⇧⌘Z alternate for as long as the window
/// lives. A step that reports `false` — the document was re-opened, so the
/// removal has been overtaken — registers nothing and ends the chain rather
/// than duplicating the row.
@MainActor
private func registerRecentRemovalUndo(
    _ transaction: HomeRecentRemovalTransaction,
    store: HomeSearchStore,
    undoManager: UndoManager
) {
    undoManager.registerUndo(withTarget: store) { target in
        guard target.undoRecentRemoval(transaction) else { return }
        registerRecentRemovalRedo(transaction, store: target, undoManager: undoManager)
    }
    undoManager.setActionName("Remove from Recent")
}

@MainActor
private func registerRecentRemovalRedo(
    _ transaction: HomeRecentRemovalTransaction,
    store: HomeSearchStore,
    undoManager: UndoManager
) {
    undoManager.registerUndo(withTarget: store) { target in
        guard target.redoRecentRemoval(transaction) else { return }
        registerRecentRemovalUndo(transaction, store: target, undoManager: undoManager)
    }
    undoManager.setActionName("Remove from Recent")
}

#Preview("Hero wordmark") {
    VStack(spacing: 12) {
        Image(systemName: "doc.text")
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.tint)
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.xxl))
        Wordmark(size: 36)
    }
    .padding(40)
    .background(Color(hex: "#1a1a1a"))
    .environment(\.palette, .dark)
    .preferredColorScheme(.dark)
    .tint(ThemePalette.dark.primary)
}
