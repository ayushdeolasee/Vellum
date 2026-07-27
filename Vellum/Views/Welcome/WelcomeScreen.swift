import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeScreen: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    @State private var recentDocuments: [RecentDocument]
    @State private var savedPages: [WebLibraryEntry] = []
    @State private var catalogItems: [LibraryItem]
    @State private var visibleItems: [LibraryItem]
    @State private var urlInput = ""
    @State private var selection: LibraryItem.ID?
    @State private var sort: LibrarySort = .recent
    @State private var searchQuery = ""
    @State private var filter: LibraryFilter = .all
    @FocusState private var searchFocused: Bool

    init() {
        let recentDocuments = RecentFilesService.getRecent()
        let catalogItems = LibraryCatalog.makeItems(recent: recentDocuments, saved: [])
        _recentDocuments = State(initialValue: recentDocuments)
        _catalogItems = State(initialValue: catalogItems)
        _visibleItems = State(initialValue: LibraryCatalog.filteredItems(
            catalogItems,
            query: "",
            filter: .all,
            sort: .recent
        ))
    }

    private var hasLibrary: Bool {
        !recentDocuments.isEmpty || !savedPages.isEmpty
    }

    var body: some View {
        Group {
            if hasLibrary {
                libraryLayout(items: visibleItems)
            } else {
                emptyLayout
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well)
        .task {
            if let pages = try? await appStore.sessions.listSavedWebpages() {
                guard !Task.isCancelled else { return }
                savedPages = pages
                rebuildCatalog()
            }
        }
        .onChange(of: visibleItems.map(\.id)) { _, visibleIDs in
            guard let selection else { return }
            if visibleIDs.contains(selection) == false {
                self.selection = nil
            }
        }
        .onChange(of: searchQuery) {
            refreshVisibleItems()
        }
        .onChange(of: filter) {
            refreshVisibleItems()
        }
        .onChange(of: sort) {
            refreshVisibleItems()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            rebuildCatalog()
        }
    }

    // MARK: - Empty / first-run layout (the calm hero)

    private var emptyLayout: some View {
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

    // MARK: - Library layout (native list, uses the window width)

    private func libraryLayout(items: [LibraryItem]) -> some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()
            libraryList(items: items)
        }
    }

    private var libraryHeader: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "doc.text")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))

                VStack(alignment: .leading, spacing: 2) {
                    Wordmark(size: 22)
                    Text("Pick up where you left off, or open something new.")
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
            }

            HStack(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "globe")
                        .font(.system(size: 14))
                        .foregroundStyle(palette.mutedForeground)
                    TextField("Read a webpage — paste an article URL", text: $urlInput)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(palette.foreground)
                        .disabled(appStore.isLoading)
                        .onSubmit(openUrl)
                        .accessibilityIdentifier("welcome.urlField")
                }
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassEffect(.regular, in: .capsule)

                TextButton(
                    disabled: appStore.isLoading || trimmedUrl.isEmpty,
                    action: openUrl
                ) {
                    Text("Open")
                }
                .accessibilityIdentifier("welcome.openUrl")

                Spacer(minLength: 12)

                sortMenu
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(palette.mutedForeground)
                    TextField("Search title, filename, domain, or URL", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .accessibilityIdentifier("welcome.librarySearch")
                    if searchQuery.isEmpty == false {
                        Button("Clear search", systemImage: "xmark.circle.fill") {
                            searchQuery = ""
                            searchFocused = true
                        }
                        .buttonStyle(.plain)
                        .labelStyle(.iconOnly)
                        .foregroundStyle(palette.mutedForeground)
                        .accessibilityIdentifier("welcome.librarySearch.clear")
                    }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: 420)
                .frame(height: 34)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(.separator)
                }

                Picker("Filter library", selection: $filter) {
                    ForEach(LibraryFilter.allCases) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("welcome.libraryFilter")

                Spacer(minLength: 0)
            }

            if appStore.error != nil {
                errorBanner
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var sortMenu: some View {
        Menu {
            Picker("Sort by", selection: $sort) {
                ForEach(LibrarySort.allCases, id: \.self) { option in
                    Text(option.label).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 12))
                Text(sort.label)
                    .font(.system(size: 12, weight: .medium))
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .foregroundStyle(palette.mutedForeground)
        .help("Change how the library is sorted")
        .accessibilityIdentifier("welcome.sort")
    }

    private func libraryList(items: [LibraryItem]) -> some View {
        Group {
            if items.isEmpty {
                LibraryNoResultsView(
                    query: searchQuery,
                    filter: filter,
                    reset: resetLibrarySearch
                )
            } else {
                List(selection: $selection) {
                    Section("Library") {
                        ForEach(items) { LibraryRow(item: $0) }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(palette.well)
                .environment(\.defaultMinListRowHeight, 52)
                .contextMenu(forSelectionType: LibraryItem.ID.self) { ids in
                    contextMenu(for: ids)
                } primaryAction: { ids in
                    for id in ids { open(id) }
                }
                .onDeleteCommand { removeSelected() }
                .onKeyPress(.return) {
                    guard let selection else { return .ignored }
                    open(selection)
                    return .handled
                }
                .accessibilityIdentifier("welcome.library")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<LibraryItem.ID>) -> some View {
        if let id = ids.first, let item = item(for: id) {
            Button("Open") { open(id) }
            if item.canRevealInFinder {
                Button("Show in Finder") { revealInFinder(item) }
            }
            if item.recordedRecentKey != nil || item.savedKey != nil {
                Divider()
            }
            if item.recordedRecentKey != nil {
                Button("Remove from Recent", role: .destructive) {
                    removeFromRecent(item)
                }
            }
            if item.savedKey != nil {
                Button("Remove from Saved", role: .destructive) {
                    removeFromSaved(item)
                }
            }
        }
    }

    // MARK: - Reusable pieces shared by both layouts

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
                Text("⌘O")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(.separator)
                    }
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
                    .onSubmit(openUrl)
                    .accessibilityIdentifier("welcome.urlField")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)

            TextButton(
                disabled: appStore.isLoading || trimmedUrl.isEmpty,
                action: openUrl
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

    private func item(for id: LibraryItem.ID) -> LibraryItem? {
        catalogItems.first { $0.id == id }
    }

    private func freshItem(for id: LibraryItem.ID) -> LibraryItem? {
        LibraryCatalog.makeItems(
            recent: recentDocuments,
            saved: savedPages
        ).first { $0.id == id }
    }

    // MARK: - Actions

    private var trimmedUrl: String {
        urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openUrl() {
        let value = trimmedUrl
        guard !value.isEmpty else { return }
        urlInput = ""
        Task { await appStore.openUrl(value) }
    }

    private func open(_ id: LibraryItem.ID) {
        guard let item = freshItem(for: id), !appStore.isLoading else { return }
        if item.kind == .web {
            Task { await appStore.openUrl(item.key) }
        } else {
            // A moved PDF re-resolved to a new path: drop the stale entry so
            // the re-record (on successful open) doesn't leave a duplicate.
            if let recordedKey = item.recordedRecentKey, item.key != recordedKey {
                recentDocuments = RecentFilesService.remove(path: recordedKey)
                rebuildCatalog()
            }
            Task { await appStore.openFile(path: item.key) }
        }
    }

    private func removeFromRecent(_ item: LibraryItem) {
        guard let recordedKey = item.recordedRecentKey else { return }
        recentDocuments = RecentFilesService.remove(path: recordedKey)
        rebuildCatalog()
        if selection == item.id { selection = nil }
    }

    private func removeFromSaved(_ item: LibraryItem) {
        guard let savedKey = item.savedKey else { return }
        savedPages.removeAll { $0.url == savedKey }
        rebuildCatalog()
        Task { try? await appStore.sessions.removeSavedWebpage(url: savedKey) }
        if selection == item.id { selection = nil }
    }

    private func removeSelected() {
        guard let selection, let item = item(for: selection) else { return }
        switch LibraryCatalog.removalTarget(for: item, activeFilter: filter) {
        case .recent:
            removeFromRecent(item)
        case .saved:
            removeFromSaved(item)
        case nil:
            break
        }
    }

    private func resetLibrarySearch() {
        searchQuery = ""
        filter = .all
        searchFocused = true
    }

    private func rebuildCatalog() {
        let items = LibraryCatalog.makeItems(
            recent: recentDocuments,
            saved: savedPages
        )
        catalogItems = items
        refreshVisibleItems(from: items)
    }

    private func refreshVisibleItems(from items: [LibraryItem]? = nil) {
        visibleItems = LibraryCatalog.filteredItems(
            items ?? catalogItems,
            query: searchQuery,
            filter: filter,
            sort: sort
        )
    }

    private func revealInFinder(_ item: LibraryItem) {
        guard let item = freshItem(for: item.id), item.canRevealInFinder else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.key)])
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

private struct LibraryRow: View {
    let item: LibraryItem

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 34, height: 34)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.md)
                        .strokeBorder(.separator)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if item.isSaved {
                LibraryBadge("Saved", systemImage: "bookmark.fill")
            }
            if item.isOffline {
                LibraryBadge("Offline", systemImage: "arrow.down.circle.fill")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background {
            // Subtle hover wash — same neutral fill the chrome uses for
            // hovered-but-unselected elements (SelectionStyle.fill). The row
            // content sits inset 5pt within the 52pt row (defaultMinListRowHeight
            // set on the List), so stretch the wash to the full row height —
            // otherwise it reads visibly smaller than the native selection
            // highlight, which fills the row.
            RoundedRectangle(cornerRadius: Radius.md)
                .fill(hovering ? AnyShapeStyle(.quaternary.opacity(0.55)) : AnyShapeStyle(Color.clear))
                .padding(.vertical, -5)
        }
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(item.tooltip)
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
