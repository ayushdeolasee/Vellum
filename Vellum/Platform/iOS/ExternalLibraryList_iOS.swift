import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Deliberately outside the `#if os(iOS)` guard below: this is pure logic with
/// no platform surface, and `Tests/Integrations/ExternalLibraryFilteringTests`
/// asserts on it directly. Keeping it unconditional means the suite compiles
/// even if the view around it is ever re-gated.
enum ExternalLibraryFilter {
    static func reconciledCollectionID(_ selected: String?, availableIDs: [String]) -> String? {
        guard let selected else { return nil }
        return availableIDs.contains(selected) ? selected : nil
    }
}

#if os(iOS)

/// One connected read-later account's library, as the home screen's alternate
/// source.
///
/// Touch rebuild of `main:Vellum/Views/Welcome/ExternalLibraryList.swift`. The
/// filtering, the empty states, the freshness check, the collection
/// reconciliation and the notice overlay are behaviourally identical; the
/// selection-driven `List(selection:)` + `contextMenu(forSelectionType:)` +
/// `primaryAction:` machinery is replaced by per-row buttons, because on iPad
/// the tap *is* the primary action and there is no selection to hang a menu on.
struct ExternalLibraryList_iOS: View {
    let provider: IntegrationProvider
    @Binding var search: String
    @Binding var collectionID: String?
    @Binding var sortByName: Bool
    var onDocumentOpened: (() -> Void)?

    init(
        provider: IntegrationProvider,
        search: Binding<String>,
        collectionID: Binding<String?>,
        sortByName: Binding<Bool>,
        onDocumentOpened: (() -> Void)? = nil
    ) {
        self.provider = provider
        _search = search
        _collectionID = collectionID
        _sortByName = sortByName
        self.onDocumentOpened = onDocumentOpened
    }

    @Environment(AppStore.self) private var appStore
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    private var state: IntegrationProviderViewState? { integrations.providers[provider] }
    private var failureMessage: String? { if case .failed(let message)? = state?.connection { message } else { nil } }
    private var warningMessage: String? {
        switch state?.connection {
        case .tokenRejected: "Authentication required — showing cached items"
        case .offlineCache: "Offline — showing cached items"
        case .failed(let message): "Sync failed — \(message)"
        default: nil
        }
    }
    private var items: [ReadLaterItem] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let values = (state?.items ?? []).filter { item in
            (collectionID == nil || item.collectionIDs.contains(collectionID!)) && (query.isEmpty || item.title.localizedCaseInsensitiveContains(query) || item.author?.localizedCaseInsensitiveContains(query) == true || item.tags.contains(where: { $0.localizedCaseInsensitiveContains(query) }))
        }
        return sortByName
            ? values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            : values.sorted { $0.savedAt > $1.savedAt }
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                if state?.connection == .tokenRejected, state?.items.isEmpty == true { stateView("Authentication required", "Reconnect this service in Settings.", "key.slash") }
                else if let failureMessage, state?.items.isEmpty == true { stateView("Sync failed", failureMessage, "exclamationmark.triangle") }
                else { stateView(search.isEmpty ? "Nothing saved yet" : "No results", search.isEmpty ? "Sync this service or save an item there first." : "Try another search or collection.", "tray") }
            } else if let warningMessage {
                list.overlay(alignment: .top) { Text(warningMessage).font(.caption).padding(6).background(.regularMaterial, in: Capsule()).padding(.top, 8) }
            } else { list }
        }
        // A 5-minute freshness check whenever this account is selected.
        .task(id: provider) { await integrations.providerSelected(provider) }
        .onChange(of: state?.collections.map(\.id) ?? []) { _, ids in collectionID = ExternalLibraryFilter.reconciledCollectionID(collectionID, availableIDs: ids) }
        .overlay(alignment: .bottomTrailing) {
            if let notice = integrations.newestNotice(for: provider) {
                FloatingNotice(
                    message: notice.state.message, progress: notice.state.progress,
                    isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                    accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice",
                    actionTitle: integrations.previousRevisionURL(for: notice.id) == nil ? nil : "Open Previous",
                    action: {
                        guard let url = integrations.takePreviousRevision(for: notice.id) else { return }
                        Task { await appStore.openFile(path: url.path) }
                    }
                ) {
                    if notice.isMove { integrations.dismissMoveNotice(notice.id) } else { integrations.dismissDownloadNotice(notice.id) }
                }
                .padding(18)
            }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(items) { item in
                        HomeResultRow(
                            item: ReadLaterSearchProvider.searchItem(for: item),
                            isSelected: false,
                            open: { open(item) },
                            share: nil,
                            rename: nil,
                            removals: [])
                    .accessibilityIdentifier("welcome.external.row.\(item.id)")
                    .contextMenu {
                        Button("Open") { open(item) }
                        Button("Open Original in Browser") { UIApplication.shared.open(item.sourceURL) }
                        Button("Copy Link") { UIPasteboard.general.string = item.sourceURL.absoluteString }
                        Divider()
                        MoveToCollectionMenu(item: item, integrations: integrations)
                    }
                    }
                } header: {
                    HomeSectionHeader(section: .readLater, count: items.count)
                }
            }
            .frame(maxWidth: HomeLayout.contentMaxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, horizontalSizeClass == .compact ? 8 : HomeLayout.columnPadding)
            .padding(.bottom, 32)
        }
        .background(palette.well)
        .scrollDismissesKeyboard(.interactively)
        .accessibilityIdentifier("welcome.external.library")
    }

    /// Routing through `integrations.route(for:)` is what makes a synced item
    /// open as an ordinary Vellum tab: an article becomes a normal web tab, a
    /// PDF is downloaded into the integrations cache and opened as a normal PDF
    /// tab through `AppStore.openFile` (and so inherits `PdfFileGate`). There is
    /// deliberately no bespoke reader path here.
    private func open(_ item: ReadLaterItem) {
        integrations.run {
            guard let route = try? await integrations.route(for: item) else { return }
            switch route {
            case .web(let url): await appStore.openUrl(url.absoluteString)
            case .file(let url): await appStore.openFile(path: url.path)
            }
            guard appStore.document != nil, appStore.error == nil else { return }
            onDocumentOpened?()
        }
    }
    private func stateView(_ title: String, _ message: String, _ symbol: String) -> some View { ContentUnavailableView(title, systemImage: symbol, description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

/// One filter button shared by Library, Raindrop.io and Readwise Reader.
/// The button never moves; only the menu choices change with the selected source.
struct HomeSearchFilterMenu_iOS: View {
    let provider: IntegrationProvider?
    let collections: [ReadLaterCollection]
    @Binding var libraryFilter: HomeSearchFilter
    @Binding var librarySort: HomeSearchSortOrder
    @Binding var collectionID: String?
    @Binding var sortByName: Bool

    @Environment(\.palette) private var palette
    @Environment(IntegrationsStore.self) private var integrations

    private var hasActiveFilter: Bool {
        if provider != nil {
            return collectionID != nil || sortByName
        }
        return libraryFilter != .all || librarySort != .recent
    }

    var body: some View {
        Menu {
            if let provider {
                Picker(provider == .raindrop ? "Folder" : "Location", selection: $collectionID) {
                    Text(provider == .raindrop ? "All folders" : "All locations")
                        .tag(String?.none)
                    ForEach(collections) { collection in
                        Text(String(repeating: "  ", count: collection.depth) + collection.title)
                            .tag(Optional(collection.id))
                    }
                }

                Picker("Sort by", selection: $sortByName) {
                    Text("Recently saved").tag(false)
                    Text("Name").tag(true)
                }

                Divider()

                Button {
                    integrations.run { await integrations.sync(provider) }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(integrations.providers[provider]?.connection == .syncing)
            } else {
                Picker("Show", selection: $libraryFilter) {
                    ForEach(
                        HomeSearchFilter.options(connected: integrations.connectedProviders),
                        id: \.self
                    ) { option in
                        Text(option.label).tag(option)
                    }
                }

                Picker("Sort by", selection: $librarySort) {
                    ForEach(HomeSearchSortOrder.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }
            }
        } label: {
            Image(systemName: hasActiveFilter
                ? "line.3.horizontal.decrease.circle.fill"
                : "line.3.horizontal.decrease")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(hasActiveFilter ? palette.primary : palette.mutedForeground)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Search filters")
        .accessibilityValue(hasActiveFilter ? "Filtered" : "No filters applied")
        .accessibilityIdentifier("welcome.searchFilters")
    }
}

#endif
