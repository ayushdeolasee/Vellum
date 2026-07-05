import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeScreen: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    @State private var recentDocuments = RecentFilesService.getRecent()
    @State private var savedPages: [WebLibraryEntry] = []
    @State private var urlInput = ""
    @State private var selection: LibraryItem.ID?
    @State private var sort: LibrarySort = .recent

    private var hasLibrary: Bool {
        !recentDocuments.isEmpty || !savedPages.isEmpty
    }

    var body: some View {
        Group {
            if hasLibrary {
                libraryLayout
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
            }
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

    private var libraryLayout: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()
            libraryList
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

    private var libraryList: some View {
        List(selection: $selection) {
            if !recentItems.isEmpty {
                Section("Recent") {
                    ForEach(recentItems) { LibraryRow(item: $0) }
                }
            }
            if !savedItems.isEmpty {
                Section("Saved") {
                    ForEach(savedItems) { LibraryRow(item: $0) }
                }
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

    @ViewBuilder
    private func contextMenu(for ids: Set<LibraryItem.ID>) -> some View {
        if let id = ids.first, let item = item(for: id) {
            Button("Open") { open(id) }
            if item.canRevealInFinder {
                Button("Show in Finder") { revealInFinder(item) }
            }
            Divider()
            Button(item.section == .saved ? "Remove from Saved" : "Remove from Recent", role: .destructive) {
                remove(id)
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

    // MARK: - Library item model

    private var recentItems: [LibraryItem] {
        let items = recentDocuments.map(LibraryItem.init(recent:))
        return sort == .name
            ? items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            : items
    }

    private var savedItems: [LibraryItem] {
        let items = savedPages.map(LibraryItem.init(saved:))
        return sort == .name
            ? items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            : items
    }

    private func item(for id: LibraryItem.ID) -> LibraryItem? {
        recentItems.first { $0.id == id } ?? savedItems.first { $0.id == id }
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
        guard let item = item(for: id), !appStore.isLoading else { return }
        switch item.section {
        case .recent:
            if item.kind == .web {
                Task { await appStore.openUrl(item.key) }
            } else {
                Task { await appStore.openFile(path: item.key) }
            }
        case .saved:
            Task { await appStore.openUrl(item.key) }
        }
    }

    private func remove(_ id: LibraryItem.ID) {
        guard let item = item(for: id) else { return }
        switch item.section {
        case .recent:
            recentDocuments = RecentFilesService.remove(path: item.key)
        case .saved:
            savedPages.removeAll { $0.url == item.key }
            Task { try? await appStore.sessions.removeSavedWebpage(url: item.key) }
        }
        if selection == id { selection = nil }
    }

    private func removeSelected() {
        guard let selection else { return }
        remove(selection)
    }

    private func revealInFinder(_ item: LibraryItem) {
        guard item.canRevealInFinder else { return }
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
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await appStore.openFiles(paths: paths) }
    }
}

// MARK: - Library sort

private enum LibrarySort: String, CaseIterable {
    case recent
    case name

    var label: String {
        switch self {
        case .recent: "Recently opened"
        case .name: "Name"
        }
    }
}

// MARK: - Unified library item

private struct LibraryItem: Identifiable, Hashable {
    enum Section { case recent, saved }

    let id: String
    let section: Section
    let kind: DocumentKind
    let key: String
    let icon: String
    let title: String
    let subtitle: String
    let tooltip: String
    let canRevealInFinder: Bool

    init(recent entry: RecentDocument) {
        let fileName = entry.kind == .web
            ? RecentFilesService.webpageDisplayName(for: entry.pdfPath)
            : RecentFilesService.fileName(for: entry.pdfPath)
        let trimmedTitle = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayTitle = trimmedTitle.isEmpty ? fileName : trimmedTitle

        var pieces: [String] = []
        if displayTitle != fileName { pieces.append(fileName) }
        if entry.kind == .pdf, let count = entry.pageCount, count != 0 {
            pieces.append("\(count) \(count == 1 ? "page" : "pages")")
        }
        pieces.append(Self.formatOpenedDate(entry.openedAt))

        let onDisk = entry.kind == .pdf && FileManager.default.fileExists(atPath: entry.pdfPath)

        id = "recent:\(entry.pdfPath)"
        section = .recent
        kind = entry.kind
        key = entry.pdfPath
        icon = entry.kind == .web ? "globe" : "doc.text"
        title = displayTitle
        subtitle = pieces.joined(separator: " · ")
        tooltip = entry.pdfPath
        canRevealInFinder = onDisk
    }

    init(saved page: WebLibraryEntry) {
        let displayName = RecentFilesService.webpageDisplayName(for: page.url)
        let trimmedTitle = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayTitle = trimmedTitle.isEmpty ? displayName : trimmedTitle

        id = "saved:\(page.url)"
        section = .saved
        kind = .web
        key = page.url
        icon = "globe"
        title = displayTitle
        subtitle = displayName + (page.hasSnapshot ? " · available offline" : "")
        tooltip = page.url
        canRevealInFinder = false
    }

    private static func formatOpenedDate(_ openedAt: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: openedAt) ?? ISO8601DateFormatter().date(from: openedAt)
        guard let date else { return "Recently opened" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
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
