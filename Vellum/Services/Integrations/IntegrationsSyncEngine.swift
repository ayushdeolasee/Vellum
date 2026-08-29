import CryptoKit
import Foundation
import PDFKit

struct LoadedIntegrations: Sendable { var snapshots: [IntegrationProvider: ProviderSnapshot]; var connectedProviders: Set<IntegrationProvider>; var authenticationRequiredProviders: Set<IntegrationProvider>; var corruptProviders: Set<IntegrationProvider>; var autoRefreshEnabled: Bool; var offlineReadingEnabled: Bool = true; var defaultRaindropCollectionID: String? = nil }

actor IntegrationsSyncEngine {
    private let credentials: any IntegrationCredentials
    private let cache: IntegrationsCache
    private var preferences: IntegrationPreferences
    private let readwise: any ReadwiseServing
    private let raindrop: any RaindropServing
    private let downloader: any IntegrationDownloading
    private let now: @Sendable () -> Date
    private let maximumPDFBytes: Int
    private var inFlight: [IntegrationProvider: (id: UUID, mode: IntegrationSyncMode, task: Task<ProviderSnapshot, Error>)] = [:]
    private var downloadTasks: [String: (id: UUID, task: Task<ExternalOpenRoute, Error>)] = [:]
    /// Item ids currently being removed by retention. A download cannot register
    /// while its id is in this set, so cancellation + deletion is one barrier
    /// rather than an await across which a replacement transfer can appear.
    private var removingDownloads: Set<String> = []
    /// Short lease bridging “return the existing file URL” to the reader adding
    /// that path to the workspace's open-document set. Retention refuses the
    /// item during this window; after it expires the open-path gate owns it.
    private var openingProtectionUntil: [String: Date] = [:]
    private static let openingProtectionWindow: TimeInterval = 30
    private var transitioningProviders: Set<IntegrationProvider> = []
    /// Identifies the walks this engine instance started. A tentative walk
    /// tagged with anything else was left behind by a previous launch, and
    /// cannot be trusted to line up with the pages this one will fetch.
    private let walkOwnerID = UUID()
    /// Pages between snapshot checkpoints. Every checkpoint re-sorts and
    /// re-encodes everything fetched so far and byte-copies the previous
    /// snapshot to the backup, so doing it per page made a long walk quadratic;
    /// the walk still checkpoints on every exit, so a crash costs at most this
    /// many pages of progress.
    private static let pagesPerCheckpoint = 8
    /// Backstop against a service that paginates forever without repeating
    /// itself. At 50–100 records a page this is far past any real library.
    private static let maximumPagesPerWalk = 5_000
    /// How long a partly-walked page sequence may be resumed before its page
    /// boundaries are assumed to have drifted. See `TentativePagination`.
    private static let maximumResumableWalkAge: TimeInterval = 30 * 60
    /// How many already-running syncs one call will wait on before running its
    /// own. Only a bound: each owner clears its own slot before its awaiters
    /// resume, so the loop normally runs at most twice.
    private static let maximumSyncJoins = 4

    init(credentials: any IntegrationCredentials = KeychainIntegrationCredentials(), cache: IntegrationsCache = IntegrationsCache(), preferences: sending IntegrationPreferences = IntegrationPreferences(), http: ReadLaterHTTPClient = ReadLaterHTTPClient(), readwise: (any ReadwiseServing)? = nil, raindrop: (any RaindropServing)? = nil, downloader: any IntegrationDownloading = IntegrationDownloadClient(), now: @escaping @Sendable () -> Date = { .now }, maximumPDFBytes: Int = 250 * 1024 * 1024) {
        self.credentials = credentials; self.cache = cache; self.preferences = preferences; self.readwise = readwise ?? ReadwiseClient(http: http); self.raindrop = raindrop ?? RaindropClient(http: http); self.downloader = downloader; self.now = now; self.maximumPDFBytes = maximumPDFBytes
    }

    func load() async -> LoadedIntegrations {
        await cache.sweepStaleArtifacts(now: now())
        var snapshots: [IntegrationProvider: ProviderSnapshot] = [:], connected: Set<IntegrationProvider> = [], authenticationRequired: Set<IntegrationProvider> = [], corrupt: Set<IntegrationProvider> = []
        for provider in IntegrationProvider.allCases {
            let metadata = preferences.metadata(for: provider)
            guard metadata.enabled, let fingerprint = metadata.accountFingerprint else { continue }
            switch await cache.load(provider: provider) {
            case .snapshot(let value) where value.accountFingerprint == fingerprint && value.connectionGeneration == metadata.generation: snapshots[provider] = value
            case .corrupt: corrupt.insert(provider)
            default: break
            }
            if let token = await credentials.credential(for: provider), Self.fingerprint(token) == fingerprint { connected.insert(provider) }
            else { authenticationRequired.insert(provider) }
        }
        return .init(snapshots: snapshots, connectedProviders: connected, authenticationRequiredProviders: authenticationRequired, corruptProviders: corrupt, autoRefreshEnabled: preferences.autoRefreshEnabled, offlineReadingEnabled: preferences.offlineReadingEnabled, defaultRaindropCollectionID: preferences.defaultRaindropCollectionID)
    }

    func setAutoRefreshEnabled(_ enabled: Bool) { preferences.autoRefreshEnabled = enabled }
    func setOfflineReadingEnabled(_ enabled: Bool) { preferences.offlineReadingEnabled = enabled }
    func setDefaultRaindropCollectionID(_ collectionID: String?) { preferences.defaultRaindropCollectionID = collectionID }
    func validate(provider: IntegrationProvider, candidate: String) async throws { let token = candidate.trimmingCharacters(in: .whitespacesAndNewlines); guard !token.isEmpty else { throw IntegrationError.invalidCredential }; try await validateToken(token, provider) }

    func connect(provider: IntegrationProvider, candidate: String) async throws -> ProviderSnapshot {
        let token = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { throw IntegrationError.invalidCredential }
        try await validateToken(token, provider)
        try Task.checkCancellation()
        guard transitioningProviders.insert(provider).inserted else { throw IntegrationError.staleGeneration }
        defer { transitioningProviders.remove(provider) }

        let oldMetadata = preferences.metadata(for: provider)
        let oldSnapshot = await cache.load(provider: provider)
        let generation = oldMetadata.generation + 1
        let fingerprint = Self.fingerprint(token)
        var initial = ProviderSnapshot.empty(provider: provider, fingerprint: fingerprint, generation: generation)
        if case .snapshot(let snapshot) = oldSnapshot, snapshot.accountFingerprint == fingerprint {
            initial = snapshot
            initial.connectionGeneration = generation
            initial.tentativePagination = nil
        }

        inFlight[provider]?.task.cancel()
        inFlight[provider] = nil
        cancelDownloads(provider)

        var cacheMutationStarted = false
        do {
            try Task.checkCancellation()
            preferences.persist(.init(enabled: true, generation: generation, accountFingerprint: fingerprint), for: provider)
            cacheMutationStarted = true
            try await cache.save(initial)
            try Task.checkCancellation()
            guard await credentials.setCredential(token, for: provider) else { throw IntegrationError.credentialPersistenceFailed }
            return initial
        } catch {
            if cacheMutationStarted {
                preferences.persist(oldMetadata, for: provider)
                await restoreCache(oldSnapshot, provider: provider)
            }
            throw error
        }
    }

    func disconnect(provider: IntegrationProvider, deleteDownloads: Bool, openDocumentPaths: Set<String> = []) async throws {
        let managed = deleteDownloads ? await cache.managedDownloadURLs(provider: provider) : []
        let normalizedOpenPaths = Set(openDocumentPaths.map(Self.normalizedPath))
        guard managed.allSatisfy({ !normalizedOpenPaths.contains(Self.normalizedPath($0.path)) }) else { throw IntegrationError.downloadsAreOpen }
        guard transitioningProviders.insert(provider).inserted else { throw IntegrationError.staleGeneration }
        defer { transitioningProviders.remove(provider) }

        let oldMetadata = preferences.metadata(for: provider)
        inFlight[provider]?.task.cancel()
        inFlight[provider] = nil
        cancelDownloads(provider)

        let staging = try await cache.stageDisconnect(provider: provider, deleteDownloads: deleteDownloads)
        var metadata = oldMetadata
        metadata.generation += 1
        metadata.enabled = false
        metadata.accountFingerprint = nil
        // Disable first, delete the token second. A crash between the two leaves
        // a disconnected provider whose token outlived it — harmless, and the
        // next connect overwrites it — whereas the other order leaves "enabled
        // with a fingerprint but no token", which the next launch reports as
        // "Authentication required" for a service the user just disconnected.
        preferences.persist(metadata, for: provider)
        do {
            try Task.checkCancellation()
            guard await credentials.deleteCredential(for: provider) else { throw IntegrationError.credentialPersistenceFailed }
        } catch {
            preferences.persist(oldMetadata, for: provider)
            try? await cache.rollbackDisconnect(staging)
            throw error
        }
        try? await cache.commitDisconnect(staging)
        if deleteDownloads { RecentFilesService.remove(paths: Set(managed.map(\.path))) }
    }

    func sync(provider: IntegrationProvider, forceFull: Bool = false, progress: (@Sendable (ProviderSnapshot) async -> Void)? = nil) async throws -> ProviderSnapshot {
        guard transitioningProviders.contains(provider) == false else { throw IntegrationError.staleGeneration }
        let requested: IntegrationSyncMode = forceFull || provider == .raindrop ? .full : .incremental
        // Join a sync that is already running instead of duplicating it. A full
        // request that joined an incremental one still needs its own sweep, so it
        // loops rather than recursing: the running task clears its own slot before
        // its awaiters resume, so the next turn finds the slot empty and starts the
        // full walk. The bound is belt-and-braces against an unbroken stream of new
        // syncs, and falling out of it simply runs this caller's own.
        for _ in 0..<Self.maximumSyncJoins {
            guard let current = inFlight[provider] else { break }
            // Join via `result`, not `value`: a full request that joined a
            // FAILING incremental sync must still escalate to its own sweep —
            // rethrowing here would hand this caller the incremental failure
            // instead of the full sync it asked for.
            let result = await current.task.result
            guard requested == .full, current.mode == .incremental else { return try result.get() }
        }
        let id = UUID()
        let task = Task { try await self.runSync(provider: provider, mode: requested, id: id, progress: progress) }
        inFlight[provider] = (id: id, mode: requested, task: task)
        return try await task.value
    }

    private func runSync(provider: IntegrationProvider, mode: IntegrationSyncMode, id: UUID, progress: (@Sendable (ProviderSnapshot) async -> Void)?) async throws -> ProviderSnapshot {
        defer { if inFlight[provider]?.id == id { inFlight[provider] = nil } }
        return try await performSync(provider: provider, mode: mode, progress: progress)
    }

    /// Files an item under a different collection/location on the provider,
    /// then patches the cached snapshot so the change survives relaunch without
    /// waiting for the next sync. The cache patch is a single actor-isolated
    /// read-modify-write, and the connection is re-validated after the network
    /// call, so a disconnect that lands mid-move can neither be resurrected on
    /// disk nor patched into another account's snapshot. A sync that was already
    /// in flight when the move landed may still re-save pre-move data; the
    /// store compensates by re-applying pending moves and re-syncing.
    func move(_ item: ReadLaterItem, toCollectionVendorID vendorID: String) async throws {
        guard transitioningProviders.contains(item.provider) == false else { throw IntegrationError.staleGeneration }
        let metadata = preferences.metadata(for: item.provider)
        guard metadata.enabled, let fingerprint = metadata.accountFingerprint, let token = await credentials.credential(for: item.provider), Self.fingerprint(token) == fingerprint else { throw IntegrationError.disconnected }
        switch item.provider {
        case .raindrop: try await raindrop.moveItem(token: token, itemID: item.vendorID, collectionVendorID: vendorID)
        case .readwise: try await readwise.moveItem(token: token, itemID: item.vendorID, locationVendorID: vendorID)
        }
        try ensureCurrent(item.provider, metadata.generation, fingerprint)
        try? await cache.patchItemCollection(
            provider: item.provider,
            itemID: item.id,
            collectionID: ReadLaterCollection.id(provider: item.provider, vendorID: vendorID),
            updatedAt: now(),
            expectedGeneration: metadata.generation,
            expectedFingerprint: fingerprint)
    }

    /// The already-downloaded copy, but only while it still matches the item's
    /// current revision: an item the service has updated since must be fetched
    /// again rather than opened from a copy nothing would ever refresh.
    func existingRoute(for item: ReadLaterItem) async -> ExternalOpenRoute? { if let url = try? await cache.currentDownload(provider: item.provider, itemID: item.vendorID, revision: Self.revision(item)) { return .file(url) }; return nil }

    /// Existing route for a user open. Presence probes use `existingRoute`
    /// without a lease; only handing the URL to a reader protects it.
    func acquireExistingRoute(for item: ReadLaterItem) async -> ExternalOpenRoute? {
        while true {
            while removingDownloads.contains(item.id) {
                if Task.isCancelled { return nil }
                try? await Task.sleep(for: .milliseconds(20))
            }
            let route = await existingRoute(for: item)
            // `existingRoute` awaits the cache actor. Removal may have begun in
            // that suspension; retry behind its barrier rather than leasing a
            // URL that is already being deleted.
            if removingDownloads.contains(item.id) { continue }
            guard let route else { return nil }
            openingProtectionUntil[item.id] = now().addingTimeInterval(
                Self.openingProtectionWindow)
            return route
        }
    }

    func download(_ item: ReadLaterItem, progress: @escaping @Sendable (Double?) async -> Void) async throws -> ExternalOpenRoute {
        while true {
            while removingDownloads.contains(item.id) {
                try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(20))
            }
            guard transitioningProviders.contains(item.provider) == false else {
                throw IntegrationError.staleGeneration
            }
            let existing = await existingRoute(for: item)
            if removingDownloads.contains(item.id) { continue }
            if let existing { return existing }
            break
        }
        if let current = downloadTasks[item.id] { return try await current.task.value }
        let metadata = preferences.metadata(for: item.provider); guard metadata.enabled else { throw IntegrationError.disconnected }
        let id = UUID()
        let task = Task { try await self.runDownload(item, id: id, generation: metadata.generation, fingerprint: metadata.accountFingerprint ?? "", progress: progress) }
        downloadTasks[item.id] = (id: id, task: task)
        return try await task.value
    }

    /// Background autopull's entry into the download path (#157). Deliberately
    /// `download` itself rather than a parallel implementation: prefetching and
    /// opening must share the byte cap, the PDF validation, the revision-guarded
    /// reuse of an existing copy, the generation guards AND the per-item dedup —
    /// so a prefetch already in flight is what an open joins instead of racing.
    func prefetch(_ item: ReadLaterItem) async throws -> ExternalOpenRoute {
        try await download(item, progress: { _ in })
    }

    /// Retention's counterpart to `prefetch`: drop a downloaded copy. Refuses
    /// while the file is open in a tab (same rule `disconnect` enforces), and
    /// cancels an in-flight download of the same item first so a transfer can't
    /// re-install the bytes moments after the sweep removed them.
    func removeDownloadedCopy(for item: ReadLaterItem, openDocumentPaths: Set<String>) async -> Bool {
        await removeDownloadedCopy(provider: item.provider, itemID: item.vendorID, openDocumentPaths: openDocumentPaths)
    }

    /// Id-only deletion is valid only when PDF artifacts actually exist. An
    /// article uses a URL-derived web-archive key that cannot be recovered from
    /// its provider id; reporting a missing PDF as success would forget its
    /// retention entry while leaving those bytes behind.
    func downloadedCopyURL(provider: IntegrationProvider, itemID: String) async -> URL? {
        await cache.existingDownloadURL(provider: provider, itemID: itemID)
    }

    func removeDownloadedCopyIfPresent(
        provider: IntegrationProvider, itemID: String, openDocumentPaths: Set<String>
    ) async -> Bool {
        let key = "\(provider.rawValue):\(itemID)"
        if downloadTasks[key] == nil {
            guard await cache.hasDownloadArtifacts(provider: provider, itemID: itemID) else {
                return false
            }
        }
        return await removeDownloadedCopy(
            provider: provider, itemID: itemID, openDocumentPaths: openDocumentPaths)
    }

    func removeDownloadedCopy(provider: IntegrationProvider, itemID: String, openDocumentPaths: Set<String>) async -> Bool {
        let key = "\(provider.rawValue):\(itemID)"
        if let protectedUntil = openingProtectionUntil[key] {
            if protectedUntil > now() { return false }
            openingProtectionUntil[key] = nil
        }
        guard removingDownloads.insert(key).inserted else { return false }
        defer { removingDownloads.remove(key) }

        if let entry = downloadTasks[key] {
            entry.task.cancel()
            downloadTasks[key] = nil
            _ = await entry.task.result
        }
        guard let url = try? await cache.downloadURL(provider: provider, itemID: itemID) else {
            return false
        }
        let normalizedOpenPaths = Set(openDocumentPaths.map(Self.normalizedPath))
        guard !normalizedOpenPaths.contains(Self.normalizedPath(url.path)) else { return false }
        let removed = await cache.deleteDownload(provider: provider, itemID: itemID)
        if removed { RecentFilesService.remove(paths: [url.path]) }
        return removed
    }

    private func runDownload(_ item: ReadLaterItem, id: UUID, generation: Int, fingerprint: String, progress: @escaping @Sendable (Double?) async -> Void) async throws -> ExternalOpenRoute {
        // Identity-guarded like `inFlight`: an unguarded clear would evict a
        // newer task registered after `cancelDownloads`, so a second download of
        // the same item would no longer dedupe against it and would lose the
        // install race with a spurious "a downloaded copy already exists".
        defer { if downloadTasks[item.id]?.id == id { downloadTasks[item.id] = nil } }
        return try await performDownload(item, generation: generation, fingerprint: fingerprint, progress: progress)
    }

    private func performSync(provider: IntegrationProvider, mode: IntegrationSyncMode, progress: (@Sendable (ProviderSnapshot) async -> Void)?) async throws -> ProviderSnapshot {
        let metadata = preferences.metadata(for: provider)
        guard metadata.enabled, let fingerprint = metadata.accountFingerprint, let token = await credentials.credential(for: provider), Self.fingerprint(token) == fingerprint else { throw IntegrationError.disconnected }
        let loaded = await cache.load(provider: provider)
        var committed: ProviderSnapshot
        if case .snapshot(let value) = loaded, value.connectionGeneration == metadata.generation, value.accountFingerprint == fingerprint { committed = value } else { committed = .empty(provider: provider, fingerprint: fingerprint, generation: metadata.generation) }
        let actualMode: IntegrationSyncMode = provider == .raindrop ? .full : mode
        let overlap = actualMode == .incremental ? committed.committedBoundary?.addingTimeInterval(-300) : nil
        let query = IntegrationQueryDescriptor(provider: provider, pageSize: provider == .readwise ? 100 : 50, sort: provider == .raindrop ? "-created" : nil, updatedAfter: overlap)
        let resumed = committed.tentativePagination.flatMap { $0.connectionGeneration == metadata.generation && $0.accountFingerprint == fingerprint && $0.query == query && $0.mode == actualMode && $0.startingBoundary == committed.committedBoundary ? $0 : nil }
        var tentative = resumed ?? TentativePagination(walkOwnerID: walkOwnerID, startedAt: now(), connectionGeneration: metadata.generation, accountFingerprint: fingerprint, query: query, startingBoundary: committed.committedBoundary, mode: actualMode, cursor: nil, fetchedItems: [], seenIDs: [], skippedRecordCount: 0, mergeOnly: false)
        // A walk this engine did not start (so: one a relaunch interrupted), or
        // one that began long enough ago for the list to have shifted under it,
        // cannot claim its pages tile the library — offset pagination over a
        // list that gained or lost entries in the gap skips whatever slid across
        // a boundary it already passed. Downgrading it to merge-only is what
        // stops those absences from being committed as local deletions.
        if resumed != nil, tentative.walkOwnerID != walkOwnerID || now().timeIntervalSince(tentative.startedAt) > Self.maximumResumableWalkAge { tentative.mergeOnly = true }
        var fetched = Dictionary(tentative.fetchedItems.map { ($0.id, $0) }, uniquingKeysWith: Self.newest)
        var collections = committed.collections
        if provider == .raindrop { collections = try await raindrop.collections(token: token) }
        var pageNumber = Int(tentative.cursor ?? "0") ?? 0, pagesWalked = 0, pagesSinceCheckpoint = 0
        do {
            while true {
                try ensureCurrent(provider, metadata.generation, fingerprint)
                let page = provider == .readwise ? try await readwise.page(token: token, cursor: tentative.cursor, updatedAfter: overlap, limit: 100) : try await raindrop.page(token: token, page: pageNumber, perPage: 50)
                try ensureCurrent(provider, metadata.generation, fingerprint)
                pagesWalked += 1
                var newRecordCount = 0
                for item in page.items { if tentative.seenIDs.insert(item.id).inserted { newRecordCount += 1 }; fetched[item.id] = Self.newest(fetched[item.id] ?? item, item) }
                tentative.skippedRecordCount += page.skippedRecordCount
                if !page.hasMore { break }
                // "There is more" has to be backed by actual progress. A repeated
                // cursor, an empty body, or a page of records this walk already
                // holds is a service looping, and taking its word for it is what
                // let one Readwise cursor page forever with the provider stuck in
                // .syncing. The page cap is the backstop for a service that loops
                // without ever repeating itself.
                guard let next = page.nextCursor, next != tentative.cursor, !page.responseWasEmpty, newRecordCount > 0, pagesWalked < Self.maximumPagesPerWalk else { throw IntegrationError.paginationDidNotAdvance }
                tentative.cursor = next
                pagesSinceCheckpoint += 1
                if pagesSinceCheckpoint >= Self.pagesPerCheckpoint { pagesSinceCheckpoint = 0; try await checkpoint(&tentative, &committed, fetched: fetched, provider: provider, generation: metadata.generation, fingerprint: fingerprint) }
                if let progress {
                    await progress(Self.preview(committed: committed, fetched: fetched, collections: collections))
                    try ensureCurrent(provider, metadata.generation, fingerprint)
                }
                if provider == .raindrop { pageNumber = Int(next) ?? (pageNumber + 1) }
            }
        } catch {
            if case IntegrationError.paginationDidNotAdvance = error {
                // A walk that failed because the service stopped making
                // progress must NOT persist its position — a resumed walk
                // refetches the exact page that tripped the guard and fails
                // identically, forever, with no user action that recovers it.
                // Dropping the walk makes the next sync start fresh (its items
                // are refetched; ids merge, so nothing is lost).
                committed.tentativePagination = nil
                if (try? ensureCurrent(provider, metadata.generation, fingerprint)) != nil { try? await cache.save(committed) }
            } else {
                try? await checkpoint(&tentative, &committed, fetched: fetched, provider: provider, generation: metadata.generation, fingerprint: fingerprint)
            }
            throw error
        }
        try ensureCurrent(provider, metadata.generation, fingerprint)
        // Only a walk that saw the whole library, dropped nothing, and never
        // lost its place may treat what it fetched as the truth and delete the
        // rest; anything else merges, which can add and update but never remove.
        let authoritative = actualMode == .full && tentative.skippedRecordCount == 0 && tentative.mergeOnly == false
        var merged = Dictionary(committed.items.map { ($0.id, $0) }, uniquingKeysWith: Self.newest)
        if authoritative { merged = fetched } else { for item in fetched.values { merged[item.id] = Self.newest(merged[item.id] ?? item, item) } }
        committed.items = merged.values.sorted(by: Self.itemOrder); committed.collections = collections; committed.tentativePagination = nil; committed.lastSuccessfulSync = now(); committed.skippedRecordCount = tentative.skippedRecordCount
        if let maximum = fetched.values.map(\.updatedAt).max(), committed.committedBoundary == nil || maximum > committed.committedBoundary! { committed.committedBoundary = maximum }
        if authoritative { committed.lastFullSweep = now() }
        try ensureCurrent(provider, metadata.generation, fingerprint); try await cache.save(committed); return committed
    }

    // Writes everything walked so far. `ensureCurrent` runs first, so a
    // checkpoint on the way out of a cancelled or superseded walk writes
    // nothing — it can neither resurrect a snapshot a disconnect deleted nor
    // stamp one account's items onto another's cache. An actor method with
    // `inout` state rather than a nested func: the compiler infers
    // `@concurrent` for local async functions, which would send the walk's
    // mutable locals out of the actor's region.
    private func checkpoint(_ tentative: inout TentativePagination, _ committed: inout ProviderSnapshot, fetched: [String: ReadLaterItem], provider: IntegrationProvider, generation: Int, fingerprint: String) async throws {
        tentative.fetchedItems = fetched.values.sorted(by: Self.itemOrder); committed.tentativePagination = tentative
        try ensureCurrent(provider, generation, fingerprint); try await cache.save(committed)
    }

    private func performDownload(_ item: ReadLaterItem, generation: Int, fingerprint: String, progress: @escaping @Sendable (Double?) async -> Void) async throws -> ExternalOpenRoute {
        guard let strategy = item.pdfRetrieval else { return .web(item.sourceURL) }
        guard let token = await credentials.credential(for: item.provider) else { throw IntegrationError.disconnected }
        let source: URL
        switch strategy { case .readwiseItem(let id): guard let value = try await readwise.rawSourceURL(token: token, itemID: id) else { throw IntegrationError.notPDF }; source = value; case .raindropURL(let url): source = url }
        try ensureCurrent(item.provider, generation, fingerprint)
        let temporary = try await cache.temporaryDownloadURL(provider: item.provider, itemID: item.vendorID)
        let downloaded = try await downloader.download(URLRequest(url: source), to: temporary, maximumBytes: maximumPDFBytes, progress: progress).temporaryURL
        do {
            try await Task.detached(priority: .userInitiated) { try Self.validatePDF(at: downloaded) }.value
            try ensureCurrent(item.provider, generation, fingerprint)
            let manifest = IntegrationsCache.DownloadManifest(provider: item.provider, itemID: item.vendorID, revision: Self.revision(item))
            return .file(try await cache.installDownload(temporaryURL: downloaded, manifest: manifest))
        } catch { try? FileManager.default.removeItem(at: downloaded); throw error }
    }

    /// Runs off the actor. Mapping a large PDF and letting PDFKit parse its
    /// cross-reference table takes long enough that doing it inline would stall
    /// every other sync, move and progress callback the engine serialises.
    private static func validatePDF(at url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.prefix(5) == Data("%PDF-".utf8), PDFDocument(url: url) != nil else { throw IntegrationError.notPDF }
    }

    /// The item version an installed copy is compared against.
    private static func revision(_ item: ReadLaterItem) -> String { ISO8601DateFormatter.integrationString(from: item.updatedAt) }

    private func validateToken(_ token: String, _ provider: IntegrationProvider) async throws { switch provider { case .readwise: try await readwise.validate(token: token); case .raindrop: try await raindrop.validate(token: token) } }
    private func ensureCurrent(_ provider: IntegrationProvider, _ generation: Int, _ fingerprint: String) throws { let value = preferences.metadata(for: provider); guard value.enabled, value.generation == generation, value.accountFingerprint == fingerprint else { throw IntegrationError.staleGeneration }; try Task.checkCancellation() }
    private func cancelDownloads(_ provider: IntegrationProvider) { for (key, entry) in downloadTasks where key.hasPrefix(provider.rawValue + ":") { entry.task.cancel(); downloadTasks[key] = nil } }
    private func restoreCache(_ previous: IntegrationsCache.LoadResult, provider: IntegrationProvider) async {
        switch previous {
        case .snapshot(let snapshot): try? await cache.save(snapshot)
        case .missing: try? await cache.deleteSnapshot(provider: provider)
        case .corrupt: break
        }
    }
    private static func preview(committed: ProviderSnapshot, fetched: [ReadLaterItem.ID: ReadLaterItem], collections: [ReadLaterCollection]) -> ProviderSnapshot {
        var preview = committed
        var merged = Dictionary(committed.items.map { ($0.id, $0) }, uniquingKeysWith: newest)
        for item in fetched.values { merged[item.id] = newest(merged[item.id] ?? item, item) }
        preview.items = merged.values.sorted(by: itemOrder)
        preview.collections = collections
        return preview
    }
    private static func normalizedPath(_ path: String) -> String { URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path }
    private static func fingerprint(_ token: String) -> String { SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined() }
    private static func newest(_ lhs: ReadLaterItem, _ rhs: ReadLaterItem) -> ReadLaterItem { lhs.updatedAt >= rhs.updatedAt ? lhs : rhs }
    private static func itemOrder(_ lhs: ReadLaterItem, _ rhs: ReadLaterItem) -> Bool { lhs.updatedAt == rhs.updatedAt ? lhs.id < rhs.id : lhs.updatedAt > rhs.updatedAt }
}
