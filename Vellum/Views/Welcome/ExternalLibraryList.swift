import AppKit
import SwiftUI

enum ExternalLibraryFilter {
    static func reconciledCollectionID(_ selected: String?, availableIDs: [String]) -> String? {
        guard let selected else { return nil }
        return availableIDs.contains(selected) ? selected : nil
    }
}

struct ExternalLibraryList: View {
    let provider: IntegrationProvider

    @Environment(AppStore.self) private var appStore
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette
    @State private var selection: ReadLaterItem.ID?
    @State private var search = ""
    @State private var collectionID: String?
    @State private var sortByName = false

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
        return sortByName ? values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } : values
    }

    var body: some View {
        VStack(spacing: 0) {
            controls.padding(.horizontal, 24).padding(.vertical, 12)
            Divider()
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

    private var controls: some View {
        HStack(spacing: 10) {
            TextField("Search \(provider.name)", text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("welcome.external.search")
            Menu(collectionID == nil ? "All locations" : state?.collections.first(where: { $0.id == collectionID })?.title ?? "Location") {
                Button("All locations") { collectionID = nil }
                ForEach(state?.collections ?? []) { collection in Button { collectionID = collection.id } label: { Text(String(repeating: "  ", count: collection.depth) + collection.title) } }
            }.fixedSize()
            Toggle("Name", isOn: $sortByName).toggleStyle(.button).help("Sort by name")
        }
    }

    private var list: some View {
        List(selection: $selection) { ForEach(items) { item in ExternalLibraryRow(item: item).tag(item.id) } }
            .listStyle(.inset).scrollContentBackground(.hidden).background(palette.well).environment(\.defaultMinListRowHeight, 52)
            .contextMenu(forSelectionType: ReadLaterItem.ID.self) { ids in if let item = ids.first.flatMap(item) { Button("Open") { open(item) }; Button("Open Original in Browser") { NSWorkspace.shared.open(item.sourceURL) }; Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.sourceURL.absoluteString, forType: .string) }; Divider(); MoveToCollectionMenu(item: item, integrations: integrations) } } primaryAction: { ids in ids.compactMap(item).forEach(open) }
            .onKeyPress(.return) { guard let selection, let value = item(selection) else { return .ignored }; open(value); return .handled }
            .accessibilityIdentifier("welcome.external.library")
    }

    private func item(_ id: ReadLaterItem.ID) -> ReadLaterItem? { items.first { $0.id == id } }
    private func open(_ item: ReadLaterItem) { Task { do { switch try await integrations.route(for: item) { case .web(let url): await appStore.openUrl(url.absoluteString); case .file(let url): await appStore.openFile(path: url.path) } } catch {} } }
    private func stateView(_ title: String, _ message: String, _ symbol: String) -> some View { ContentUnavailableView(title, systemImage: symbol, description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct ExternalLibraryRow: View {
    let item: ReadLaterItem
    @Environment(IntegrationsStore.self) private var integrations
    @State private var image: NSImage?
    var body: some View {
        LibraryRowContent(title: item.title, subtitle: [item.author, item.sourceURL.host()].compactMap { $0 }.joined(separator: " · "), badge: item.kind == .pdf ? "PDF" : nil, tooltip: item.sourceURL.absoluteString) {
            Group { if let image { Image(nsImage: image).resizable().scaledToFill() } else { Image(systemName: item.kind == .pdf ? "doc.richtext" : "globe").foregroundStyle(.secondary) } }
                .frame(width: 34, height: 34).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md)).clipShape(RoundedRectangle(cornerRadius: Radius.md)).overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.separator) }
        }
        // Fetch, file read and decode all happen inside the thumbnail actor —
        // the row only assigns the finished image, so scrolling never pays for
        // disk I/O or ImageIO on the main actor.
        .task(id: item.thumbnailURL) { image = await integrations.thumbnailImage(for: item) }
        .accessibilityIdentifier("welcome.external.row.\(item.id)")
    }
}
