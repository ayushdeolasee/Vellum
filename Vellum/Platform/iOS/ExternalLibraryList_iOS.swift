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

    @Environment(AppStore.self) private var appStore
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette
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
        // A 5-minute freshness check whenever this account is selected.
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
            TextField("Search \(provider.name)", text: $search)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.search)
                .autocorrectionDisabled()
                .accessibilityIdentifier("welcome.external.search")
            Menu(collectionID == nil ? "All locations" : state?.collections.first(where: { $0.id == collectionID })?.title ?? "Location") {
                Button("All locations") { collectionID = nil }
                ForEach(state?.collections ?? []) { collection in Button { collectionID = collection.id } label: { Text(String(repeating: "  ", count: collection.depth) + collection.title) } }
            }
            // The Mac used a `.toggleStyle(.button)` Toggle with a `.help`
            // tooltip; on touch that is an unlabelled mystery box, so it becomes
            // an explicit icon button with a real accessibility label.
            Button { sortByName.toggle() } label: {
                Image(systemName: sortByName ? "textformat.abc" : "clock")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Sort by name")
        }
    }

    private var list: some View {
        List {
            ForEach(items) { item in
                Button { open(item) } label: { ExternalLibraryRow_iOS(item: item) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open") { open(item) }
                        Button("Open Original in Browser") { UIApplication.shared.open(item.sourceURL) }
                        Button("Copy Link") { UIPasteboard.general.string = item.sourceURL.absoluteString }
                        Divider()
                        MoveToCollectionMenu(item: item, integrations: integrations)
                    }
                    // Long-press is the only other route to the browser; a
                    // swipe makes it discoverable without one.
                    .swipeActions(edge: .trailing) {
                        Button("Open in Browser") { UIApplication.shared.open(item.sourceURL) }
                    }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(palette.well)
        .environment(\.defaultMinListRowHeight, 60)
        .accessibilityIdentifier("welcome.external.library")
    }

    /// Routing through `integrations.route(for:)` is what makes a synced item
    /// open as an ordinary Vellum tab: an article becomes a normal web tab, a
    /// PDF is downloaded into the integrations cache and opened as a normal PDF
    /// tab through `AppStore.openFile` (and so inherits `PdfFileGate`). There is
    /// deliberately no bespoke reader path here.
    private func open(_ item: ReadLaterItem) { Task { do { switch try await integrations.route(for: item) { case .web(let url): await appStore.openUrl(url.absoluteString); case .file(let url): await appStore.openFile(path: url.path) } } catch {} } }
    private func stateView(_ title: String, _ message: String, _ symbol: String) -> some View { ContentUnavailableView(title, systemImage: symbol, description: Text(message)).frame(maxWidth: .infinity, maxHeight: .infinity) }
}

private struct ExternalLibraryRow_iOS: View {
    let item: ReadLaterItem
    @Environment(IntegrationsStore.self) private var integrations
    @State private var image: UIImage?
    var body: some View {
        LibraryRowContent_iOS(title: item.title, subtitle: [item.author, item.sourceURL.host()].compactMap { $0 }.joined(separator: " · "), badge: item.kind == .pdf ? "PDF" : nil) {
            Group { if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: item.kind == .pdf ? "doc.richtext" : "globe").foregroundStyle(.secondary) } }
                .frame(width: 34, height: 34).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.md)).clipShape(RoundedRectangle(cornerRadius: Radius.md)).overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.separator) }
        }
        // Fetch, file read and decode all happen inside the thumbnail actor —
        // the row only assigns the finished image, so scrolling never pays for
        // disk I/O or ImageIO on the main actor. That argument matters more on
        // iPad than on a Mac, not less: this is battery as well as smoothness.
        .task(id: item.thumbnailURL) { image = await integrations.thumbnailImage(for: item) }
        .accessibilityIdentifier("welcome.external.row.\(item.id)")
    }
}

#endif
