import Foundation
import Observation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor @Observable
final class IntegrationsStore {
    private(set) var providers: [IntegrationProvider: IntegrationProviderViewState]
    private(set) var downloads: [ReadLaterItem.ID: IntegrationDownloadState] = [:]
    /// A retained older PDF revision that the user can reopen after the
    /// provider supplied a replacement. The file remains on disk after this
    /// one-time warning is dismissed.
    private(set) var previousRevisionURLs: [ReadLaterItem.ID: URL] = [:]
    /// Success/error toasts for move-to-collection actions. Kept separate from
    /// `downloads` so a move toast can never stomp live download progress.
    private(set) var moveNotices: [ReadLaterItem.ID: IntegrationDownloadState] = [:]
    /// Items with a move request currently on the wire; the move menu disables
    /// these and overlapping moves of the same item are rejected at entry.
    private(set) var inFlightMoves: Set<ReadLaterItem.ID> = []
    private(set) var didStart = false
    /// Join point for concurrent launch callers. The app's startup sync and
    /// launch housekeeping are separate `.task`s; without one shared task, the
    /// housekeeping path can observe `didStart` while cached provider snapshots
    /// are still loading and mistake an empty queue for an authoritative one.
    @ObservationIgnored private var startupTask: Task<Void, Never>?
    var autoRefreshEnabled = true
    /// "Download for offline reading" (#157). Mirrors the persisted preference;
    /// the toggle writes through the engine like `autoRefreshEnabled` does.
    var offlineReadingEnabled = true

    @ObservationIgnored private let engine: IntegrationsSyncEngine
    /// Background autopull + the fourteen-day retention clock. Built here (not
    /// injected) because it is this store's items the prefetcher works on, and
    /// every trigger — start, staleness, manual sync, foreground, background
    /// refresh — already routes through this object.
    @ObservationIgnored let prefetcher: ReadLaterPrefetcher
    @ObservationIgnored private let thumbnails: IntegrationThumbnailCache
    @ObservationIgnored private let scheduler: any IntegrationSleeper
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let refreshInterval: Duration
    @ObservationIgnored private let staleInterval: TimeInterval
    @ObservationIgnored private var autoRefreshTask: Task<Void, Never>?
    /// The prefetch run in flight, if any — cancellable by the quit drain.
    @ObservationIgnored private var prefetchTask: Task<Void, Never>?
    @ObservationIgnored private var operationTasks: [IntegrationProvider: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Store-owned background work — preference writes, the post-connect sync,
    /// moves, disconnects, thumbnail cleanup. Every fire-and-forget task that
    /// persists or deletes lives here so `awaitQuiescence()` can drain it on
    /// quit instead of the work vanishing with the process.
    @ObservationIgnored private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    /// Reverse-lookup indexes (id → item, download-key → id, normalized address
    /// → id), rebuilt lazily when a provider's items revision changes, so
    /// mapping an open document back to its item is O(1) instead of an O(items)
    /// scan.
    @ObservationIgnored private var lookupIndexes: [IntegrationProvider: ItemLookupIndex] = [:]
    /// Bumped when a provider's `items` actually change — never for a cosmetic
    /// status/connection change, which would throw away the index for nothing.
    @ObservationIgnored private var itemsRevisions: [IntegrationProvider: Int] = [:]
    /// Moves confirmed (or optimistically applied) locally but possibly not yet
    /// reflected in provider snapshots. Re-applied on top of every `apply` so a
    /// sync that raced the move can't visibly bounce the item back; cleared as
    /// soon as the provider reports the item in its new collection (or newer).
    @ObservationIgnored private var pendingMoves: [ReadLaterItem.ID: (collectionID: String, at: Date)] = [:]
    /// How long an unconfirmed move patch may keep rewriting snapshots. An item
    /// deleted (or re-filed) server-side can never satisfy its patch, so the
    /// patch has to expire rather than mask provider state for the session.
    private static let pendingMoveTTL: TimeInterval = 15 * 60
    /// True while `awaitQuiescence` drains for quit. Gates new syncs (including
    /// a move's follow-up sweep) so the drain converges on in-flight work
    /// instead of chasing work it can no longer cancel.
    @ObservationIgnored private var isQuiescing = false
    /// Monotonic counter ordering all notices (downloads and moves).
    @ObservationIgnored private var noticeSequence = 0
    /// Fade-out timers for success toasts, keyed by item and stamped with the
    /// notice they belong to so a newer toast can cancel the older one's timer.
    @ObservationIgnored private var noticeExpiries: [ReadLaterItem.ID: (sequence: Int, task: Task<Void, Never>)] = [:]
    /// Prevents an immediate reopen from re-showing a warning while its
    /// acknowledgement is queued behind actor work. A later provider revision
    /// points at a different previous URL and is therefore still shown.
    @ObservationIgnored private var acknowledgedRevisionURLs: [ReadLaterItem.ID: URL] = [:]

    init(engine: IntegrationsSyncEngine, thumbnails: IntegrationThumbnailCache = IntegrationThumbnailCache(), scheduler: any IntegrationSleeper = ContinuousIntegrationSleeper(), now: @escaping @Sendable () -> Date = { .now }, refreshInterval: Duration = .seconds(30 * 60), staleInterval: TimeInterval = 30 * 60, prefetcher: ReadLaterPrefetcher? = nil, webLibraryStorage: WebLibraryStorage = WebLibraryStorage()) {
        self.engine = engine; self.thumbnails = thumbnails; self.scheduler = scheduler; self.now = now; self.refreshInterval = refreshInterval; self.staleInterval = staleInterval
        self.prefetcher = prefetcher ?? ReadLaterPrefetcher(
            offline: IntegrationsOfflineStore(engine: engine, storage: webLibraryStorage))
        providers = Dictionary(uniqueKeysWithValues: IntegrationProvider.allCases.map { ($0, .init(provider: $0, connection: .disconnected, items: [], collections: [], lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0, statusMessage: nil)) })
    }
    convenience init() { self.init(engine: IntegrationsSyncEngine()) }
    var hasConnectedProvider: Bool { providers.values.contains(where: \.isConnected) }
    var connectedProviders: [IntegrationProvider] { IntegrationProvider.allCases.filter { providers[$0]?.isConnected == true } }
    /// Every cached item across connected providers, in stable provider order —
    /// the corpus home search indexes.
    var searchableItems: [ReadLaterItem] { connectedProviders.flatMap { providers[$0]?.items ?? [] } }
    /// Changes exactly when `searchableItems` can have changed (any provider's
    /// items revision, which item mutations always bump alongside an observable
    /// `providers` write) — the `.task(id:)` key for re-indexing search.
    var searchRevision: Int { itemsRevisions.values.reduce(0, +) }

    func start() async {
        if didStart { return }
        if let startupTask {
            await startupTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performStart()
        }
        startupTask = task
        await task.value
        startupTask = nil
    }

    private func performStart() async {
        let loaded = await engine.load(); autoRefreshEnabled = loaded.autoRefreshEnabled; offlineReadingEnabled = loaded.offlineReadingEnabled
        for provider in IntegrationProvider.allCases {
            if loaded.authenticationRequiredProviders.contains(provider) {
                if let snapshot = loaded.snapshots[provider] { apply(snapshot, connection: .tokenRejected) }
                else { update(provider) { $0.connection = .tokenRejected } }
                update(provider) { $0.statusMessage = "Authentication required — reconnect in Settings" }
            } else if let snapshot = loaded.snapshots[provider] { apply(snapshot, connection: .connected) }
            else if loaded.corruptProviders.contains(provider) { update(provider) { $0.connection = .failed("The local cache is damaged. Sync Now to rebuild it."); $0.statusMessage = "Cache recovery needed" } }
            else if loaded.connectedProviders.contains(provider) { update(provider) { $0.connection = .connected; $0.statusMessage = "Connected — not synced yet" } }
        }
        guard !Task.isCancelled, !isQuiescing else {
            didStart = true
            return
        }
        restartAutoRefresh(); await refreshStaleProviders()
        didStart = true
    }

    /// The toggle applies to the UI immediately and the preference write runs
    /// behind it — as a store-owned task, so quitting right after flipping the
    /// switch can't silently revert it.
    func setAutoRefresh(_ enabled: Bool) {
        guard enabled != autoRefreshEnabled else { return }
        autoRefreshEnabled = enabled
        run { [engine] in await engine.setAutoRefreshEnabled(enabled) }
        restartAutoRefresh()
    }

    /// Settings ▸ Integrations ▸ "Download for offline reading". Same shape as
    /// `setAutoRefresh`: the UI flips immediately, the preference write runs as
    /// a store-owned task so quitting right afterwards can't revert it. Turning
    /// it ON starts a run immediately — the user just asked for their queue —
    /// while turning it OFF only stops future runs: bytes already downloaded
    /// stay under the fourteen-day clock rather than vanishing on a toggle.
    func setOfflineReading(_ enabled: Bool) {
        guard enabled != offlineReadingEnabled else { return }
        offlineReadingEnabled = enabled
        run { [engine] in await engine.setOfflineReadingEnabled(enabled) }
        guard enabled else { return }
        run { [weak self] in await self?.prefetchOfflineCopies() }
    }

    /// One prefetch pass over the current queue. Safe to call from every
    /// trigger: the prefetcher runs one pass at a time and skips whatever is
    /// already on disk.
    func prefetchOfflineCopies(policy: ReadLaterPrefetchPolicy = .foreground) async {
        guard offlineReadingEnabled, !isQuiescing else { return }
        if let prefetchTask {
            await prefetchTask.value
            return
        }
        let items = searchableItems
        let enabled = offlineReadingEnabled
        // Held in its own slot rather than only as a `run` handle: prefetching
        // is minutes of network work, and the quit/background drain must be
        // able to CANCEL it (like a sync) instead of waiting it out inside a
        // `beginBackgroundTask` window.
        let task = Task { [prefetcher] in
            _ = await prefetcher.run(items: items, isEnabled: enabled, policy: policy)
        }
        prefetchTask = task
        await task.value
        if prefetchTask == task { prefetchTask = nil }
    }

    /// The BGAppRefreshTask body (#157): refresh what is stale, top up the
    /// offline copies within the background budget, then let retention expire
    /// what the user never came back to. Sweeping LAST means an item downloaded
    /// moments ago is never a candidate of the same run.
    func backgroundRefresh(openDocumentPaths: Set<String> = []) async {
        await start()
        await refreshStaleProviders()
        await prefetchOfflineCopies(policy: .background)
        _ = await sweepExpiredOfflineCopies(
            now: now(), openDocumentPaths: openDocumentPaths)
    }

    func connect(provider: IntegrationProvider, token: String) async throws {
        let old = providers[provider]
        let priorOperation = operationTasks[provider]
        update(provider) { $0.connection = .connecting; $0.statusMessage = "Checking token…" }
        do {
            let initial = try await engine.connect(provider: provider, candidate: token)
            // Every sync in flight when the connection landed belongs to the old
            // generation — the one captured before the await AND any auto-refresh
            // that started during it. Cancel whatever holds the slot and clear
            // it, so a stale `staleGeneration` failure can never overwrite this
            // fresh connection (its `performSync` guards compare against the slot).
            priorOperation?.task.cancel()
            if let current = operationTasks[provider] { current.task.cancel(); operationTasks[provider] = nil }
            apply(initial, connection: .connected)
            run { [weak self] in await self?.sync(provider, forceFull: true) }
        } catch {
            // Restore only while nothing newer owns the provider: same operation
            // in the slot as before the await (or still none at all).
            let shouldRestore = operationTasks[provider]?.id == priorOperation?.id
            if shouldRestore, providers[provider]?.connection == .connecting, let old {
                providers[provider] = old
                itemsRevisions[provider, default: 0] += 1
            }
            throw error
        }
    }

    func sync(_ provider: IntegrationProvider, forceFull: Bool = false) async {
        guard !isQuiescing else { return }
        if let current = operationTasks[provider] {
            await current.task.value
            if forceFull { await sync(provider, forceFull: true) }
            return
        }
        let id = UUID()
        let task = Task { [weak self] in
            await Task.yield()
            guard let self else { return }
            await self.performSync(provider, forceFull: forceFull, operationID: id)
            // The task clears its own slot (identity-guarded). An awaiter doing
            // it instead leaves a window where `awaitQuiescence` re-observes a
            // completed task in a loop that never suspends — awaiting an
            // already-finished task returns synchronously, so the awaiter's
            // continuation never gets scheduled and ⌘Q spins the main actor.
            if self.operationTasks[provider]?.id == id { self.operationTasks[provider] = nil }
        }
        operationTasks[provider] = (id: id, task: task)
        await task.value
    }
    func providerSelected(_ provider: IntegrationProvider) async { guard let date = providers[provider]?.lastSuccessfulSync, now().timeIntervalSince(date) <= 300 else { await sync(provider); return } }

    // MARK: - Joinable background work

    /// Runs `operation` as a store-owned task and keeps the handle, so nothing
    /// this store starts in the background is unjoinable (root CLAUDE.md: never
    /// drop the handle of a task that persists). The handle comes back for
    /// callers that must also cancel it — a settings sheet that closes while its
    /// request is still on the wire.
    @discardableResult
    func run(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        // The closure inherits this store's main-actor isolation, and cannot
        // start before this function returns, so the bookkeeping can't race.
        let task = Task { [weak self] in
            await operation()
            self?.backgroundTasks[id] = nil
        }
        backgroundTasks[id] = task
        return task
    }

    /// Quit barrier, awaited by `applicationShouldTerminate` next to the
    /// page-text and AI drains. Syncs are network work, so quitting cancels them
    /// and waits only for the unwind (their cache writes commit page by page);
    /// the store-owned tasks — preference writes, moves, disconnects, thumbnail
    /// cleanup — are drained to completion. Rounds repeat because a drained task
    /// may start one more (a move's follow-up sync), and each round strictly
    /// follows the previous one's completion, so this terminates.
    func awaitQuiescence() async {
        isQuiescing = true
        defer { isQuiescing = false }
        autoRefreshTask?.cancel(); autoRefreshTask = nil
        // Cancelled, not awaited: an unfinished prefetch costs a retry next
        // launch, and the ledger records nothing for a transfer that did not
        // land, so there is no half-state to drain.
        prefetchTask?.cancel(); prefetchTask = nil
        startupTask?.cancel()
        while true {
            for entry in operationTasks.values { entry.task.cancel() }
            let pending = Array(backgroundTasks.values)
                + operationTasks.values.map(\.task)
                + [startupTask].compactMap { $0 }
            guard !pending.isEmpty else { return }
            for task in pending { await task.value }
            // Let continuations those completions resumed run before
            // re-sampling, so bookkeeping done by awaiters has landed and the
            // next round observes the real remainder instead of ghosts.
            await Task.yield()
        }
    }

    func disconnect(provider: IntegrationProvider, deleteDownloads: Bool, openDocumentPaths: Set<String> = []) async throws {
        try await engine.disconnect(provider: provider, deleteDownloads: deleteDownloads, openDocumentPaths: openDocumentPaths)
        operationTasks[provider]?.task.cancel(); operationTasks[provider] = nil
        providers[provider] = .init(provider: provider, connection: .disconnected, items: [], collections: [], lastSuccessfulSync: nil, lastFullSweep: nil, skippedRecordCount: 0, statusMessage: nil)
        itemsRevisions[provider, default: 0] += 1
        let prefix = provider.rawValue + ":"
        downloads = downloads.filter { !$0.key.hasPrefix(prefix) }
        previousRevisionURLs = previousRevisionURLs.filter { !$0.key.hasPrefix(prefix) }
        acknowledgedRevisionURLs = acknowledgedRevisionURLs.filter { !$0.key.hasPrefix(prefix) }
        moveNotices = moveNotices.filter { !$0.key.hasPrefix(prefix) }
        pendingMoves = pendingMoves.filter { !$0.key.hasPrefix(prefix) }
        inFlightMoves = inFlightMoves.filter { !$0.hasPrefix(prefix) }
    }

    func route(for item: ReadLaterItem) async throws -> ExternalOpenRoute {
        // Opening IS the read that resets the fourteen-day clock (#157), and it
        // is recorded here — the single chokepoint every surface routes through
        // (Home, the external library list, the welcome screen) — rather than in
        // each of them. Fire-and-forget through `run`, so a ledger write never
        // delays putting the document on screen.
        run { [prefetcher] in await prefetcher.markRead(item) }
        if item.kind != .pdf { return .web(item.sourceURL) }
        if let existing = await engine.acquireExistingRoute(for: item) {
            await surfaceRevisionWarning(for: item)
            return existing
        }
        downloads[item.id] = .init(progress: nil, message: "Downloading \(item.title)…", isActive: true, sequence: nextSequence())
        do { let route = try await engine.download(item) { [weak self] value in await MainActor.run { guard let self else { return }; let old = self.downloads[item.id]; self.downloads[item.id] = .init(progress: value.map { max(old?.progress ?? 0, min(1, $0)) }, message: "Downloading \(item.title)…", isActive: true, sequence: old?.sequence ?? self.nextSequence()) } }; await surfaceRevisionWarning(for: item); return route }
        catch { downloads[item.id] = .init(progress: nil, message: error.localizedDescription, isActive: false, sequence: nextSequence()); throw error }
    }

    /// A ready-to-draw thumbnail. The fetch, the file read AND the decode all
    /// happen inside the cache actor, so a library row never blocks the main
    /// actor on disk I/O or ImageIO.
    func thumbnailImage(for item: ReadLaterItem) async -> IntegrationThumbnailImage? { await thumbnails.image(for: item.thumbnailURL) }

    func previousRevisionURL(for id: ReadLaterItem.ID) -> URL? { previousRevisionURLs[id] }

    func takePreviousRevision(for id: ReadLaterItem.ID) -> URL? {
        let url = previousRevisionURLs[id]
        dismissDownloadNotice(id)
        return url
    }

    func dismissDownloadNotice(_ id: ReadLaterItem.ID) {
        downloads[id] = nil
        let previousURL = previousRevisionURLs[id]
        previousRevisionURLs[id] = nil
        guard let previousURL,
              let item = searchableItems.first(where: { $0.id == id }) else { return }
        acknowledgedRevisionURLs[id] = previousURL
        run { [engine] in
            await engine.acknowledgeRevisionWarning(
                for: item, previousRevisionURL: previousURL)
        }
    }

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

    /// Entry point for menus and other UI that can't await: the move runs as a
    /// store-owned task instead of a dropped `Task` handle, so the quit path can
    /// drain a refile the user asked for a moment ago.
    func beginMove(_ item: ReadLaterItem, to collection: ReadLaterCollection) {
        run { [weak self] in await self?.move(item, to: collection) }
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
        // Not during quit: the drain waits for this move (deliberate — it's a
        // write the user asked for), but a follow-up FULL sweep is minutes of
        // cancellable-in-name-only network work the next launch's stale-check
        // performs anyway.
        if followUpSync, !isQuiescing { await sync(item.provider, forceFull: true) }
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
                let fileStem = String((path as NSString).lastPathComponent.dropLast(4))
                id = index.byDownloadKey[String(fileStem.prefix(64))]
            }
            if let id, let item = index.byID[id] { return item }
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

    private func surfaceRevisionWarning(for item: ReadLaterItem) async {
        guard let previousURL = await engine.pendingPreviousRevisionURL(for: item) else {
            previousRevisionURLs[item.id] = nil
            downloads[item.id] = nil
            return
        }
        guard acknowledgedRevisionURLs[item.id] != previousURL else { return }
        previousRevisionURLs[item.id] = previousURL
        downloads[item.id] = .init(
            progress: nil,
            message: "A newer revision was downloaded. Your previous copy was preserved.",
            isActive: false,
            sequence: nextSequence())
    }

    private func replace(id: ReadLaterItem.ID, in provider: IntegrationProvider, with value: ReadLaterItem) {
        // Deliberately no re-sort: a locally-originated move keeps the row where
        // the user is looking instead of teleporting it to the top of the list.
        update(provider) { state in
            if let index = state.items.firstIndex(where: { $0.id == id }) { state.items[index] = value }
        }
        itemsRevisions[provider, default: 0] += 1
    }

    private func setTransientNotice(for id: ReadLaterItem.ID, message: String) {
        let sequence = nextSequence()
        moveNotices[id] = .init(progress: nil, message: message, isActive: false, isSuccess: true, sequence: sequence)
        noticeExpiries[id]?.task.cancel()
        noticeExpiries[id] = (sequence: sequence, task: Task { [weak self, scheduler] in
            try? await scheduler.sleep(for: .seconds(3))
            guard let self, self.noticeExpiries[id]?.sequence == sequence else { return }
            if self.moveNotices[id]?.sequence == sequence { self.moveNotices[id] = nil }
            self.noticeExpiries[id] = nil
        })
    }

    /// Awaits the pending fade-out timer for a move notice. The timers are
    /// joinable like everything else this store starts, but they are
    /// deliberately NOT part of `awaitQuiescence` — a toast fading is not work
    /// worth delaying ⌘Q for. Tests await this instead of polling the notice.
    func awaitNoticeExpiry(for id: ReadLaterItem.ID) async { await noticeExpiries[id]?.task.value }

    private func nextSequence() -> Int { noticeSequence += 1; return noticeSequence }

    private struct ItemLookupIndex {
        var revision: Int
        /// Resolves a matched id straight to its item — the whole point of the
        /// index is that no lookup path falls back to a linear scan.
        var byID: [ReadLaterItem.ID: ReadLaterItem]
        var byDownloadKey: [String: ReadLaterItem.ID]
        var byAddress: [String: ReadLaterItem.ID]
        /// Empty-string value marks an ambiguous key (several items differ only
        /// by query string), which the fallback match must not resolve to.
        var byStrippedAddress: [String: ReadLaterItem.ID]
    }

    private func lookupIndex(for provider: IntegrationProvider, items: [ReadLaterItem]) -> ItemLookupIndex {
        let revision = itemsRevisions[provider, default: 0]
        if let cached = lookupIndexes[provider], cached.revision == revision { return cached }
        var index = ItemLookupIndex(revision: revision, byID: [:], byDownloadKey: [:], byAddress: [:], byStrippedAddress: [:])
        index.byID.reserveCapacity(items.count)
        for item in items {
            if index.byID[item.id] == nil { index.byID[item.id] = item }
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
            // Staleness/manual/post-connect triggers all land here: a sync that
            // committed new items is exactly when autopull has something to do.
            run { [weak self] in await self?.prefetchOfflineCopies() }
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
    /// iOS has no "app is running continuously" guarantee: the auto-refresh
    /// timer's sleep is suspended with the process, so returning to the
    /// foreground is the moment to re-check staleness. macOS gets this for free
    /// from the always-running timer.
    func foregroundRefresh() async { await refreshStaleProviders() }

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
            // A patch older than the TTL is unsatisfiable — the item was deleted
            // (or re-filed) server-side and will never come back in the shape the
            // patch waits for — so it retires instead of rewriting snapshots for
            // the rest of the session.
            let isExpired = now().timeIntervalSince(patch.at) >= Self.pendingMoveTTL
            guard let index = items.firstIndex(where: { $0.id == id }) else {
                if isExpired { pendingMoves[id] = nil }
                continue
            }
            let item = items[index]
            if item.collectionIDs == [patch.collectionID] || item.updatedAt > patch.at || isExpired {
                pendingMoves[id] = nil
            } else {
                items[index] = item.movingToCollection(patch.collectionID, updatedAt: item.updatedAt)
            }
        }
        providers[snapshot.provider] = .init(provider: snapshot.provider, connection: connection, items: items, collections: snapshot.collections, lastSuccessfulSync: snapshot.lastSuccessfulSync, lastFullSweep: snapshot.lastFullSweep, skippedRecordCount: snapshot.skippedRecordCount, statusMessage: nil)
        itemsRevisions[snapshot.provider, default: 0] += 1
        if cleanThumbnails {
            // The keep-set is computed HERE, not inside the task: a disconnect
            // landing in between would otherwise hand the sweep a post-disconnect
            // set and delete thumbnails the surviving providers still reference.
            let keep = Set(providers.values.flatMap(\.items).compactMap(\.thumbnailURL))
            run { [thumbnails] in await thumbnails.removeUnreferenced(keeping: keep) }
        }
    }
    /// Non-items mutations (connection state, status message). Deliberately does
    /// NOT bump `itemsRevisions`: invalidating the lookup index on a cosmetic
    /// "Syncing…" message would throw away the cache this class exists to keep.
    /// Everything that mutates `items` bumps the revision itself — `apply`,
    /// `replace`, `disconnect`, and the connect rollback.
    private func update(_ provider: IntegrationProvider, _ mutation: (inout IntegrationProviderViewState) -> Void) { guard var value = providers[provider] else { return }; mutation(&value); providers[provider] = value }
}

/// `StorageHousekeeping` evicts read-later bytes through this store, not
/// through the prefetcher directly: the sweep needs the CURRENT queue to map
/// ledger ids back to items, and this is the object that has it.
extension IntegrationsStore: ReadLaterRetentionSweeping {
    @discardableResult
    func sweepExpiredOfflineCopies(
        now: Date, openDocumentPaths: Set<String>
    ) async -> RetentionSweepReport {
        // The launch-time housekeeping pass can race the startup load. `start()`
        // joins the one in-flight startup task, so snapshots and any required
        // refresh are settled before an empty queue can be called authoritative.
        await start()
        if let prefetchTask { await prefetchTask.value }
        return await prefetcher.sweep(
            items: searchableItems, now: now, openDocumentPaths: openDocumentPaths)
    }
}
