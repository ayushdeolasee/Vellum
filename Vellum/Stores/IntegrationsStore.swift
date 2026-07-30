import Foundation
import Observation

@MainActor @Observable
final class IntegrationsStore {
    private(set) var providers: [IntegrationProvider: IntegrationProviderViewState]
    private(set) var downloads: [ReadLaterItem.ID: IntegrationDownloadState] = [:]
    /// Success/error toasts for move-to-collection actions. Kept separate from
    /// `downloads` so a move toast can never stomp live download progress.
    private(set) var moveNotices: [ReadLaterItem.ID: IntegrationDownloadState] = [:]
    /// Items with a move request currently on the wire; the move menu disables
    /// these and overlapping moves of the same item are rejected at entry.
    private(set) var inFlightMoves: Set<ReadLaterItem.ID> = []
    private(set) var didStart = false
    var autoRefreshEnabled = true

    @ObservationIgnored private let engine: IntegrationsSyncEngine
    @ObservationIgnored private let thumbnails: IntegrationThumbnailCache
    @ObservationIgnored private let scheduler: any IntegrationSleeper
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private let staleInterval: TimeInterval
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var operationTasks: [IntegrationProvider: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Reverse-lookup indexes (download-key → id, normalized address → id),
    /// rebuilt lazily when a provider's items revision changes, so mapping an
    /// open document back to its item is O(1) instead of an O(items) scan.
    @ObservationIgnored private var lookupIndexes: [IntegrationProvider: ItemLookupIndex] = [:]
    /// Bumped on every items mutation; cheap staleness check for the indexes.
    @ObservationIgnored private var itemsRevisions: [IntegrationProvider: Int] = [:]
    /// Moves confirmed (or optimistically applied) locally but possibly not yet
    /// reflected in provider snapshots. Re-applied on top of every `apply` so a
    /// sync that raced the move can't visibly bounce the item back; cleared as
    /// soon as the provider reports the item in its new collection (or newer).
    @ObservationIgnored private var pendingMoves: [ReadLaterItem.ID: (collectionID: String, at: Date)] = [:]
    /// Monotonic counter ordering all notices (downloads and moves).
    @ObservationIgnored private var noticeSequence = 0

    init(engine: IntegrationsSyncEngine, thumbnails: IntegrationThumbnailCache = IntegrationThumbnailCache(), scheduler: any IntegrationSleeper = ContinuousIntegrationSleeper(), now: @escaping @Sendable () -> Date = { .now }, refreshInterval: Duration = .seconds(30 * 60), staleInterval: TimeInterval = 30 * 60) {
        self.engine = engine; self.thumbnails = thumbnails; self.scheduler = scheduler; self.now = now; self.refreshInterval = refreshInterval; self.staleInterval = staleInterval
        providers = Dictionary(uniqueKeysWithValues: IntegrationProvider.allCases.map { ($0, .init(provider: $0, connection: .disconnected, items: [], collections: [], lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0, statusMessage: nil)) })
    }
    convenience init() { self.init(engine: IntegrationsSyncEngine()) }
    var hasConnectedProvider: Bool { providers.values.contains(where: \.isConnected) }
    var connectedProviders: [IntegrationProvider] { IntegrationProvider.allCases.filter { providers[$0]?.isConnected == true } }

    func start() async {
        guard !didStart else { return }; didStart = true
        let loaded = await engine.load(); autoRefreshEnabled = loaded.autoRefreshEnabled
        for provider in IntegrationProvider.allCases {
            if loaded.authenticationRequiredProviders.contains(provider) {
                if let snapshot = loaded.snapshots[provider] { apply(snapshot, connection: .tokenRejected) }
                else { update(provider) { $0.connection = .tokenRejected } }
                update(provider) { $0.statusMessage = "Authentication required — reconnect in Settings" }
            } else if let snapshot = loaded.snapshots[provider] { apply(snapshot, connection: .connected) }
            else if loaded.corruptProviders.contains(provider) { update(provider) { $0.connection = .failed("The local cache is damaged. Sync Now to rebuild it."); $0.statusMessage = "Cache recovery needed" } }
            else if loaded.connectedProviders.contains(provider) { update(provider) { $0.connection = .connected; $0.statusMessage = "Connected — not synced yet" } }
        }
        restartAutoRefresh(); await refreshStaleProviders()
    }

    func setAutoRefresh(_ enabled: Bool) { guard enabled != autoRefreshEnabled else { return }; autoRefreshEnabled = enabled; Task { await engine.setAutoRefreshEnabled(enabled) }; restartAutoRefresh() }
    func connect(provider: IntegrationProvider, token: String) async throws {
        let old = providers[provider]
        let priorOperation = operationTasks[provider]
        update(provider) { $0.connection = .connecting; $0.statusMessage = "Checking token…" }
        do {
            let initial = try await engine.connect(provider: provider, candidate: token)
            priorOperation?.task.cancel()
            if operationTasks[provider]?.id == priorOperation?.id { operationTasks[provider] = nil }
            apply(initial, connection: .connected)
            Task { [weak self] in await self?.sync(provider, forceFull: true) }
        } catch {
            let shouldRestore = priorOperation == nil || operationTasks[provider]?.id == priorOperation?.id
            if shouldRestore, providers[provider]?.connection == .connecting, let old { providers[provider] = old }
            throw error
        }
    }

    func sync(_ provider: IntegrationProvider, forceFull: Bool = false) async {
        if let current = operationTasks[provider] {
            await current.task.value
            if operationTasks[provider]?.id == current.id { operationTasks[provider] = nil }
            if forceFull { await sync(provider, forceFull: true) }
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performSync(provider, forceFull: forceFull, operationID: id)
        }
        operationTasks[provider] = (id: id, task: task)
        await task.value
        if operationTasks[provider]?.id == id { operationTasks[provider] = nil }
    }
    func providerSelected(_ provider: IntegrationProvider) async { guard let date = providers[provider]?.lastSuccessfulSync, now().timeIntervalSince(date) <= 300 else { await sync(provider); return } }

    func disconnect(provider: IntegrationProvider, deleteDownloads: Bool, openDocumentPaths: Set<String> = []) async throws {
        try await engine.disconnect(provider: provider, deleteDownloads: deleteDownloads, openDocumentPaths: openDocumentPaths)
        operationTasks[provider]?.task.cancel(); operationTasks[provider] = nil
        providers[provider] = .init(provider: provider, connection: .disconnected, items: [], collections: [], lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0, statusMessage: nil)
        itemsRevisions[provider, default: 0] += 1
        let prefix = provider.rawValue + ":"
        downloads = downloads.filter { !$0.key.hasPrefix(prefix) }
        moveNotices = moveNotices.filter { !$0.key.hasPrefix(prefix) }
        pendingMoves = pendingMoves.filter { !$0.key.hasPrefix(prefix) }
        inFlightMoves = inFlightMoves.filter { !$0.hasPrefix(prefix) }
    }

    func route(for item: ReadLaterItem) async throws -> ExternalOpenRoute {
        if item.kind != .pdf { return .web(item.sourceURL) }
        if let existing = await engine.existingRoute(for: item) { return existing }
        downloads[item.id] = .init(progress: nil, message: "Downloading \(item.title)…", isActive: true, sequence: nextSequence())
        do { let route = try await engine.download(item) { [weak self] value in await MainActor.run { guard let self else { return }; let old = self.downloads[item.id]; self.downloads[item.id] = .init(progress: value.map { max(old?.progress ?? 0, min(1, $0)) }, message: "Downloading \(item.title)…", isActive: true, sequence: old?.sequence ?? self.nextSequence()) } }; downloads[item.id] = nil; return route }
        catch { downloads[item.id] = .init(progress: nil, message: error.localizedDescription, isActive: false, sequence: nextSequence()); throw error }
    }

    func thumbnailURL(for item: ReadLaterItem) async -> URL? { await thumbnails.imageURL(for: item.thumbnailURL) }
    func dismissDownloadNotice(_ id: ReadLaterItem.ID) { downloads[id] = nil }

    // MARK: - Moving items between collections

    /// Collections an item of this provider can be filed into: Raindrop gets
    /// its synced collections plus the built-in Unsorted inbox; Readwise gets
    /// its fixed Reader locations minus the read-only Feed.
    func moveTargets(for provider: IntegrationProvider) -> [ReadLaterCollection] {
        let collections = providers[provider]?.collections ?? []
        switch provider {
        case .raindrop: return [.raindropUnsorted] + collections
        case .readwise: return collections.filter { ReadwiseClient.moveTargetLocationIDs.contains($0.vendorID) }
        }
    }

    /// Optimistically refiles the item, then asks the provider. Overlapping
    /// moves of the same item are rejected at entry; on failure the optimistic
    /// copy is reverted only if nothing newer has replaced it (compare-and-swap),
    /// and the error surfaces as a floating notice. If a sync was in flight when
    /// the move landed, a follow-up full sync re-fetches the provider's
    /// authoritative state so neither the UI nor the cache stays stale.
    func move(_ item: ReadLaterItem, to collection: ReadLaterCollection) async {
        guard item.provider == collection.provider,
              !inFlightMoves.contains(item.id),
              let original = providers[item.provider]?.items.first(where: { $0.id == item.id }),
              original.collectionIDs != [collection.id] else { return }
        inFlightMoves.insert(item.id)
        let optimistic = original.movingToCollection(collection.id, updatedAt: now())
        pendingMoves[item.id] = (collectionID: collection.id, at: optimistic.updatedAt)
        replace(id: item.id, in: item.provider, with: optimistic)
        var followUpSync = false
        do {
            try await engine.move(original, toCollectionVendorID: collection.vendorID)
            setTransientNotice(for: item.id, message: "Moved to \(collection.title)")
            followUpSync = operationTasks[item.provider] != nil
        } catch {
            pendingMoves[item.id] = nil
            if providers[item.provider]?.items.first(where: { $0.id == item.id }) == optimistic {
                replace(id: item.id, in: item.provider, with: original)
            }
            moveNotices[item.id] = .init(progress: nil, message: "Couldn't move to \(collection.title) — \(error.localizedDescription)", isActive: false, sequence: nextSequence())
        }
        inFlightMoves.remove(item.id)
        if followUpSync { await sync(item.provider, forceFull: true) }
    }

    /// Maps an open document back to the read-later item it came from, so the
    /// toolbar can offer provider actions while the page is open. Web tabs are
    /// matched by normalized URL; downloaded PDFs by their content-addressed
    /// file name. Backed by lazily rebuilt reverse indexes — no per-call scans.
    func readLaterItem(forOpenDocumentPath path: String?) -> ReadLaterItem? {
        guard let path, !path.isEmpty else { return nil }
        let isWeb = path.hasPrefix("http://") || path.hasPrefix("https://")
        if !isWeb, !path.lowercased().hasSuffix(".pdf") { return nil }
        for provider in IntegrationProvider.allCases {
            guard let items = providers[provider]?.items, !items.isEmpty else { continue }
            let index = lookupIndex(for: provider, items: items)
            var id: ReadLaterItem.ID?
            if isWeb {
                let address = Self.comparableWebAddress(path)
                id = index.byAddress[address]
                if id == nil {
                    // The open tab may have gained a query string (redirects,
                    // tracking params) the saved link doesn't have — fall back
                    // to a query-less match when it's unambiguous.
                    let stripped = Self.strippingQuery(address)
                    if let candidate = index.byStrippedAddress[stripped], !candidate.isEmpty { id = candidate }
                }
            } else {
                id = index.byDownloadKey[String((path as NSString).lastPathComponent.dropLast(4))]
            }
            if let id, let item = items.first(where: { $0.id == id }) { return item }
        }
        return nil
    }

    /// The single notice (newest wins) to float over a provider's library list.
    func newestNotice(for provider: IntegrationProvider) -> (id: ReadLaterItem.ID, state: IntegrationDownloadState, isMove: Bool)? {
        let prefix = provider.rawValue + ":"
        var best: (id: ReadLaterItem.ID, state: IntegrationDownloadState, isMove: Bool)?
        for (key, value) in downloads where key.hasPrefix(prefix) && (best == nil || value.sequence > best!.state.sequence) { best = (key, value, false) }
        for (key, value) in moveNotices where key.hasPrefix(prefix) && (best == nil || value.sequence > best!.state.sequence) { best = (key, value, true) }
        return best
    }

    /// The single notice (newest wins) to float over an open document's pane.
    func notice(forItem id: ReadLaterItem.ID) -> (state: IntegrationDownloadState, isMove: Bool)? {
        switch (downloads[id], moveNotices[id]) {
        case (nil, nil): nil
        case (let download?, nil): (download, false)
        case (nil, let move?): (move, true)
        case (let download?, let move?): move.sequence >= download.sequence ? (move, true) : (download, false)
        }
    }

    func dismissMoveNotice(_ id: ReadLaterItem.ID) { moveNotices[id] = nil }

    private func replace(id: ReadLaterItem.ID, in provider: IntegrationProvider, with value: ReadLaterItem) {
        // Deliberately no re-sort: a locally-originated move keeps the row where
        // the user is looking instead of teleporting it to the top of the list.
        update(provider) { state in
            if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index] = value }
        }
    }

    private func setTransientNotice(for id: ReadLaterItem.ID, message: String) {
        let sequence = nextSequence()
        moveNotices[id] = .init(progress: nil, message: message, isActive: false, isSuccess: true, sequence: sequence)
        Task { [weak self, scheduler] in
            try? await scheduler.sleep(for: .seconds(3))
            guard let self, self.moveNotices[id]?.sequence == sequence else { return }
            self.moveNotices[id] = nil
        }
    }

    private func nextSequence() -> Int { noticeSequence += 1; return noticeSequence }

    private struct ItemLookupIndex {
        var revision: Int
        var byDownloadKey: [String: ReadLaterItem.ID]
        var byAddress: [String: ReadLaterItem.ID]
        /// Empty-string value marks an ambiguous key (several items differ only
        /// by query string), which the fallback match must not resolve to.
        var byStrippedAddress: [String: ReadLaterItem.ID]
    }

    private func lookupIndex(for provider: IntegrationProvider, items: [ReadLaterItem]) -> ItemLookupIndex {
        let revision = itemsRevisions[provider, default: 0]
        if let cached = lookupIndexes[provider], cached.revision == revision { return cached }
        var index = ItemLookupIndex(revision: revision, byDownloadKey: [:], byAddress: [:], byStrippedAddress: [:])
        for item in items {
            let key = IntegrationsCache.downloadKey(provider: provider, itemID: item.vendorID)
            if index.byDownloadKey[key] == nil { index.byDownloadKey[key] = item.id }
            let address = Self.comparableWebAddress(item.sourceURL.absoluteString)
            if index.byAddress[address] == nil { index.byAddress[address] = item.id }
            let stripped = Self.strippingQuery(address)
            if let existing = index.byStrippedAddress[stripped] {
                if existing != item.id { index.byStrippedAddress[stripped] = "" }
            } else {
                index.byStrippedAddress[stripped] = item.id
            }
        }
        lookupIndexes[provider] = index
        return index
    }

    /// Loose equality for "is this open page that saved link": drops the scheme
    /// and fragment, lowercases the host (hosts are case-insensitive), ignores a
    /// www. prefix and trailing slashes, and keeps path + query.
    static func comparableWebAddress(_ value: String) -> String {
        guard let components = URLComponents(string: value), let componentsHost = components.host, !componentsHost.isEmpty else {
            var address = value
            for prefix in ["https://", "http://"] where address.hasPrefix(prefix) { address.removeFirst(prefix.count) }
            while address.hasSuffix("/") { address.removeLast() }
            return address
        }
        var host = componentsHost.lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        let query = components.percentEncodedQuery.map { "?" + $0 } ?? ""
        return host + path + query
    }

    static func strippingQuery(_ address: String) -> String {
        address.firstIndex(of: "?").map { String(address[..<$0]) } ?? address
    }

    private func performSync(_ provider: IntegrationProvider, forceFull: Bool, operationID: UUID) async {
        guard operationTasks[provider]?.id == operationID else { return }
        update(provider) { $0.connection = .syncing; $0.statusMessage = "Syncing…" }
        do {
            let snapshot = try await engine.sync(provider: provider, forceFull: forceFull) { [weak self] preview in
                await MainActor.run {
                    guard let self, self.operationTasks[provider]?.id == operationID else { return }
                    self.apply(preview, connection: .syncing, cleanThumbnails: false)
                    self.update(provider) { $0.statusMessage = "Syncing…" }
                }
            }
            guard operationTasks[provider]?.id == operationID else { return }
            apply(snapshot, connection: .connected)
            if snapshot.skippedRecordCount > 0 { update(provider) { $0.statusMessage = "Updated; malformed records were skipped, so deletions were preserved." } }
        } catch is CancellationError {
            guard operationTasks[provider]?.id == operationID else { return }
            update(provider) { $0.connection = .connected; $0.statusMessage = nil }
        } catch {
            guard operationTasks[provider]?.id == operationID else { return }
            let hasCache = !(providers[provider]?.items.isEmpty ?? true)
            update(provider) {
                $0.connection = error as? IntegrationError == .tokenRejected ? .tokenRejected : hasCache ? .offlineCache : .failed(error.localizedDescription)
                $0.statusMessage = error.localizedDescription
            }
        }
    }
    private func refreshStaleProviders() async {
        guard autoRefreshEnabled else { return }
        for provider in IntegrationProvider.allCases where providers[provider]?.canAutoRefresh == true {
            let state = providers[provider]
            let shouldRefresh = state?.lastSuccessfulSync == nil
                || now().timeIntervalSince(state!.lastSuccessfulSync!) >= staleInterval
            guard shouldRefresh else { continue }
            let needsWeeklySweep = state?.lastFullSweep == nil
                || now().timeIntervalSince(state!.lastFullSweep!) >= 7 * 24 * 60 * 60
            await sync(provider, forceFull: needsWeeklySweep)
        }
    }
    private func restartAutoRefresh() { autoRefreshTask?.cancel(); autoRefreshTask = nil; guard autoRefreshEnabled else { return }; autoRefreshTask = Task { [weak self, scheduler, refreshInterval] in while !Task.isCancelled { do { try await scheduler.sleep(for: refreshInterval); try Task.checkCancellation() } catch { return }; await self?.refreshStaleProviders() } } }
    private func apply(_ snapshot: ProviderSnapshot, connection: IntegrationConnectionState, cleanThumbnails: Bool = true) {
        // Re-apply moves the provider hasn't confirmed yet, so a sync that was
        // already paginating when a move landed can't visibly bounce the item
        // back to its old folder. A patch retires as soon as the provider
        // reports the item in its new collection, or newer than the move.
        var items = snapshot.items
        for (id, patch) in pendingMoves {
            guard let index = items.firstIndex(where: { $0.id == id }) else { continue }
            let item = items[index]
            if item.collectionIDs == [patch.collectionID] || item.updatedAt > patch.at {
                pendingMoves[id] = nil
            } else {
                items[index] = item.movingToCollection(patch.collectionID, updatedAt: item.updatedAt)
            }
        }
        providers[snapshot.provider] = .init(provider: snapshot.provider, connection: connection, items: items, collections: snapshot.collections, lastSuccessfulSync: snapshot.lastSuccessfulSync, lastFullSweep: snapshot.lastFullSweep, skippedRecordCount: snapshot.skippedRecordCount, statusMessage: nil)
        itemsRevisions[snapshot.provider, default: 0] += 1
        if cleanThumbnails { Task { await thumbnails.removeUnreferenced(keeping: Set(providers.values.flatMap(\.items).compactMap(\.thumbnailURL))) } }
    }
    private func update(_ provider: IntegrationProvider, _ mutation: (inout IntegrationProviderViewState) -> Void) { guard var value = providers[provider] else { return }; mutation(&value); providers[provider] = value; itemsRevisions[provider, default: 0] += 1 }
}
