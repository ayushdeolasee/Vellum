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
    @Environment(\.palette) private var palette
    @Environment(\.undoManager) private var undoManager
    @Environment(\.scenePhase) private var scenePhase

    @State private var store = HomeSearchStore()
    /// The row whose rename sheet is open, if any.
    @State private var renamingItem: HomeSearchItem?
    /// The removal waiting on its confirmation dialog, if any.
    @State private var confirmingRemoval: PendingRemoval?
    /// Title for the confirmation, held separately and never cleared on
    /// dismissal: `confirmingRemoval` goes nil the instant the dialog starts
    /// closing, and reading it for the title (which is evaluated outside
    /// `presenting:`) would blank the heading mid-animation while the buttons
    /// and message still render.
    @State private var confirmingTitle = ""
    /// The most recent undoable recents removal, shown as a toast.
    @State private var undoableRemoval: HomeRecentRemovalTransaction?
    @State private var showSettings = false
    @State private var showHelp = false
    @FocusState private var searchFocused: Bool

    /// A destructive removal held back until the user confirms it. Carries the
    /// row as well as the action so the dialog can name what it is about to
    /// un-save.
    private struct PendingRemoval {
        let item: HomeSearchItem
        let removal: HomeSearchRemoval
    }

    /// The calm first-run hero, shown only once we KNOW there is nothing to
    /// browse — never while the first load is still in flight, or the screen
    /// would flash "welcome" at someone with a full library.
    private var showsFirstRun: Bool {
        !store.isLoading && store.libraryIsEmpty && !store.isSearching
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
            searchFocused = true
        }
        .onDisappear {
            // `registerUndo(withTarget:)` does NOT retain its target, and this
            // screen owns `store` as `@State` — opening a document swaps the
            // whole view out and deallocates it. Leaving the registration in
            // place would leave a dead target on the undo stack, and an "Undo
            // Remove from Recent" entry in a reader that has no recents list on
            // screen. The undo's session is this screen's lifetime, so it
            // leaves with it.
            undoManager?.removeAllActions(withTarget: store)
        }
        .sheet(item: $renamingItem) { item in
            RenameDocumentSheet_iOS(
                currentTitle: item.title,
                // `subtitle` is the filename for a PDF and host+path for a
                // page — exactly what the row falls back to with no override.
                fallbackName: item.subtitle,
                commit: { newTitle in
                    Task { await store.rename(item, to: newTitle) }
                })
        }
        .sheet(isPresented: $showSettings) { SettingsSheet_iOS() }
        .sheet(isPresented: $showHelp) { HelpCenterView_iOS() }
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
    }

    // MARK: - Library layout

    private var libraryLayout: some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                searchField
                controlBar
                if appStore.error != nil {
                    errorBanner.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .homeContentColumn()
            .padding(.top, 22)
            .padding(.bottom, 12)

            Divider()

            resultList
        }
        .overlay(alignment: .bottomTrailing) { undoToast }
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

    /// Filters, then either the result count (while searching) or the sort menu.
    ///
    /// Wrapped in a horizontal `ScrollView` because a start tab can be a third
    /// of a 13" screen wide, and four chips plus a sort menu clip there.
    private var controlBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(HomeSearchFilter.allCases, id: \.self) { option in
                    HomeFilterChip(label: option.label, isSelected: store.filter == option) {
                        // Main also hands first responder back to the field
                        // here; on iOS that would raise the software keyboard
                        // every time a chip is tapped, so it is dropped.
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
            .frame(minWidth: 0, maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
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
                    Text("AI-powered reading for iPad")
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

    // MARK: - Undo toast

    /// iPad has no Edit ▸ Undo without a hardware keyboard, so the undo the
    /// store registers would be reachable only by shake-to-undo or ⌘Z. This
    /// toast is the primary affordance; the `UndoManager` registration in
    /// `performRemoval` stays, so both routes drive the same transaction.
    @ViewBuilder
    private var undoToast: some View {
        if let transaction = undoableRemoval {
            HStack(spacing: 12) {
                Text("Removed from Recent")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.foreground)
                Button("Undo") {
                    guard store.undoRecentRemoval(transaction) else { return }
                    undoableRemoval = nil
                    Task { await store.load() }
                }
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("welcome.undoRemoval")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(palette.border)
            }
            .shadow(radius: 8, y: 2)
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("welcome.removalToast")
            .task(id: transaction) {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation { undoableRemoval = nil }
            }
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
        switch item.target {
        case .url(let url):
            Task { await appStore.openUrl(url) }
        case .file(let path, let recordedPath):
            // A moved PDF re-resolved to a new path: drop the stale recents
            // entry so the re-record on open can't leave a duplicate (§7).
            if path != recordedPath {
                _ = RecentFilesService.remove(path: recordedPath)
            }
            // Resolve against the current container so a recent recorded before
            // a reinstall still opens (its path's container UUID may differ).
            let resolved = DocumentImport.resolveExistingPath(path) ?? path
            Task { await appStore.openFiles(paths: [resolved]) }
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

    /// Context-menu actions are built here rather than inline in the row's
    /// argument list: a ternary between a closure literal and `nil` gives the
    /// type checker no way to resolve the closure's own body.
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
                // the tap and offers undo (see `performRemoval`).
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
    /// undo stack and raise the toast.
    private func performRemoval(_ item: HomeSearchItem, from removal: HomeSearchRemoval) {
        switch removal {
        case .recent:
            // Registered synchronously, before the reload: `load()` rebuilds the
            // whole corpus, and a ⌘Z landing during it would pop whatever was on
            // the stack beforehand instead of this removal.
            let transaction = store.removeFromRecent(item)
            if let transaction {
                // SwiftUI only supplies `\.undoManager` where the environment
                // supports it; without one the removal simply stands. The toast
                // is offered either way.
                if let undoManager {
                    registerRecentRemovalUndo(transaction, store: store, undoManager: undoManager)
                }
                withAnimation { undoableRemoval = transaction }
            }
            Task { await store.load() }
        case .saved:
            Task { await store.removeFromSaved(item) }
        }
    }
}

// MARK: - Session undo

// Each step registers its counterpart, so ⌘Z / ⇧⌘Z alternate for as long as the
// screen lives. A step that reports `false` — the entry came back, or was never
// there — ends the chain rather than registering a counterpart that would
// silently do nothing.

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
#endif
