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

struct WelcomeScreen: View {
    /// Whether the pane hosting this screen is the focused one. A split window
    /// can show two welcome screens; only the focused one may grab the keyboard.
    var isPaneFocused = true

    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    @State private var store = HomeSearchStore()
    /// First-run hero only. The library layout uses the search field itself for
    /// links (see `HomeSearchLinkDetector`) plus the Add Webpage button.
    @State private var urlInput = ""
    @FocusState private var searchFocused: Bool

    /// Widest the content column is allowed to get. Past roughly this, a row's
    /// title and its date column drift so far apart that they stop reading as
    /// one line.
    private let contentMaxWidth: CGFloat = 900

    /// The calm first-run hero, shown only once we KNOW there is nothing to
    /// browse — never while the first load is still in flight, or the screen
    /// would flash "welcome" at someone with a full library.
    private var showsFirstRun: Bool {
        !store.isLoading && store.libraryIsEmpty && !store.isSearching
    }

    var body: some View {
        Group {
            if showsFirstRun {
                firstRunLayout
            } else {
                libraryLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well)
        .task { await store.load() }
        // One driver for every input that invalidates the results (query,
        // filter, sort). `.task(id:)` cancels the in-flight pass automatically,
        // which is exactly the debounce semantics we want while typing.
        .task(id: store.refreshKey) { await store.refresh() }
        .onAppear {
            // Focus the field on arrival so the front door is type-ready — but
            // only in the focused pane, or two side-by-side welcome screens
            // would fight over first responder.
            if isPaneFocused { searchFocused = true }
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
                searchField
                controlBar
                if appStore.error != nil {
                    errorBanner.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 12)

            Divider()

            resultList
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
                KeyCapsule(label: "⌘F")
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
        .padding(.horizontal, 16)
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

    private var controlBar: some View {
        HStack(spacing: 8) {
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
                .frame(maxWidth: contentMaxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
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
                KeyCapsule(label: "⌘O")
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.mutedForeground)
        }
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

    private func focusSearchField() {
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

    private func removalActions(
        for item: HomeSearchItem
    ) -> [(removal: HomeSearchRemoval, action: () -> Void)] {
        store.removalOptions(for: item).map { removal in
            // The closure is annotated rather than inferred: a bare
            // `{ Task { … } }` reads as returning the Task, which makes the
            // `Task.init` overload set ambiguous.
            let action: () -> Void = { Task { await store.remove(item, from: removal) } }
            return (removal, action)
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
