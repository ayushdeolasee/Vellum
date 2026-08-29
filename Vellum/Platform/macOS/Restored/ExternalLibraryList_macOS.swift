#if os(macOS)
import AppKit
import SwiftUI

struct ExternalLibraryList: View {
    let provider: IntegrationProvider
    @Binding var search: String
    @Binding var collectionID: String?
    @Binding var sortByName: Bool

    @Environment(AppStore.self) private var appStore
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette

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
        .task(id: provider) { await integrations.providerSelected(provider) }
        .onChange(of: state?.collections.map(\.id) ?? []) { _, ids in collectionID = ExternalLibraryFilter.reconciledCollectionID(collectionID, availableIDs: ids) }
        .overlay(alignment: .bottomTrailing) {
            if let notice = integrations.newestNotice(for: provider) {
                FloatingNotice(
                    message: notice.state.message, progress: notice.state.progress,
                    isActive: notice.state.isActive, isSuccess: notice.state.isSuccess,
                    accessibilityID: notice.isMove ? "integrations.notice" : "integrations.downloadNotice"
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
                            reveal: nil,
                            rename: nil,
                            removals: [])
                        .id(item.id)
                        .accessibilityIdentifier("welcome.external.row.\(item.id)")
                        .contextMenu {
                            Button("Open") { open(item) }
                            Button("Open Original in Browser") {
                                NSWorkspace.shared.open(item.sourceURL)
                            }
                            Button("Copy Link") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(
                                    item.sourceURL.absoluteString, forType: .string)
                            }
                            Divider()
                            MoveToCollectionMenu(item: item, integrations: integrations)
                        }
                    }
                } header: {
                    HomeSectionHeader(section: .readLater, count: items.count)
                }
            }
            .homeContentColumn()
            .padding(.bottom, 24)
        }
            .background(palette.well)
            .accessibilityIdentifier("welcome.external.library")
    }

    private func open(_ item: ReadLaterItem) { Task { do { switch try await integrations.route(for: item) { case .web(let url): await appStore.openUrl(url.absoluteString); case .file(let url): await appStore.openFile(path: url.path) } } catch {} } }
    private func stateView(_ title: String, _ message: String, _ symbol: String) -> some View { ContentUnavailableView(title, systemImage: symbol, description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) }
}
#endif
