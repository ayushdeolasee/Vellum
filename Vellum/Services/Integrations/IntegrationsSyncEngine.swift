import CryptoKit
import Foundation
import PDFKit

struct LoadedIntegrations: Sendable { var snapshots: [IntegrationProvider: ProviderSnapshot]; var connectedProviders: Set<IntegrationProvider>; var authenticationRequiredProviders: Set<IntegrationProvider>; var corruptProviders: Set<IntegrationProvider>; var autoRefreshEnabled: Bool }

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
    private var downloadTasks: [String: Task<ExternalOpenRoute, Error>] = [:]
    private var transitioningProviders: Set<IntegrationProvider> = []

    init(credentials: any IntegrationCredentials = KeychainIntegrationCredentials(), cache: IntegrationsCache = IntegrationsCache(), preferences: sending IntegrationPreferences = IntegrationPreferences(), http: ReadLaterHTTPClient = ReadLaterHTTPClient(), readwise: (any ReadwiseServing)? = nil, raindrop: (any RaindropServing)? = nil, downloader: any IntegrationDownloading = IntegrationDownloadClient(), now: @escaping @Sendable () -> Date = { .now }, maximumPDFBytes: Int = 250 * 1024 * 1024) {
        self.credentials = credentials; self.cache = cache; self.preferences = preferences; self.readwise = readwise ?? ReadwiseClient(http: http); self.raindrop = raindrop ?? RaindropClient(http: http); self.downloader = downloader; self.now = now; self.maximumPDFBytes = maximumPDFBytes
    }

    func load() async -> LoadedIntegrations {
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
        return .init(snapshots: snapshots, connectedProviders: connected, authenticationRequiredProviders: authenticationRequired, corruptProviders: corrupt, autoRefreshEnabled: preferences.autoRefreshEnabled)
    }

    func setAutoRefreshEnabled(_ enabled: Bool) { preferences.autoRefreshEnabled = enabled }
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
        do {
            try Task.checkCancellation()
            guard await credentials.deleteCredential(for: provider) else { throw IntegrationError.credentialPersistenceFailed }
        } catch {
            try? await cache.rollbackDisconnect(staging)
            throw error
        }

        var metadata = oldMetadata
        metadata.generation += 1
        metadata.enabled = false
        metadata.accountFingerprint = nil
        preferences.persist(metadata, for: provider)
        try? await cache.commitDisconnect(staging)
        if deleteDownloads { RecentFilesService.remove(paths: Set(managed.map(\.path))) }
    }

    func sync(provider: IntegrationProvider, forceFull: Bool = false, progress: (@Sendable (ProviderSnapshot) async -> Void)? = nil) async throws -> ProviderSnapshot {
        guard transitioningProviders.contains(provider) == false else { throw IntegrationError.staleGeneration }
        let requested: IntegrationSyncMode = forceFull || provider == .raindrop ? .full : .incremental
        if let current = inFlight[provider] {
            let result = try await current.task.value
            if requested == .full && current.mode == .incremental { return try await sync(provider: provider, forceFull: true, progress: progress) }
            return result
        }
        let id = UUID()
        let task = Task { try await self.performSync(provider: provider, mode: requested, progress: progress) }
        inFlight[provider] = (id: id, mode: requested, task: task)
        defer { if inFlight[provider]?.id == id { inFlight[provider] = nil } }
        return try await task.value
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

    func existingRoute(for item: ReadLaterItem) async -> ExternalOpenRoute? { if let url = try? await cache.existingDownload(provider: item.provider, itemID: item.vendorID) { return .file(url) }; return nil }

    func download(_ item: ReadLaterItem, progress: @escaping @Sendable (Double?) async -> Void) async throws -> ExternalOpenRoute {
        guard transitioningProviders.contains(item.provider) == false else { throw IntegrationError.staleGeneration }
        if let existing = await existingRoute(for: item) { return existing }
        if let task = downloadTasks[item.id] { return try await task.value }
        let metadata = preferences.metadata(for: item.provider); guard metadata.enabled else { throw IntegrationError.disconnected }
        let task = Task { try await self.performDownload(item, generation: metadata.generation, fingerprint: metadata.accountFingerprint ?? "", progress: progress) }
        downloadTasks[item.id] = task; defer { downloadTasks[item.id] = nil }; return try await task.value
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
        let saved = committed.tentativePagination
        var tentative = saved.flatMap { $0.connectionGeneration == metadata.generation && $0.accountFingerprint == fingerprint && $0.query == query && $0.mode == actualMode && $0.startingBoundary == committed.committedBoundary ? $0 : nil } ?? TentativePagination(generationID: UUID(), connectionGeneration: metadata.generation, accountFingerprint: fingerprint, query: query, startingBoundary: committed.committedBoundary, mode: actualMode, cursor: nil, fetchedItems: [], seenIDs: [], skippedRecordCount: 0)
        var fetched = Dictionary(tentative.fetchedItems.map { ($0.id, $0) }, uniquingKeysWith: Self.newest)
        var collections = committed.collections
        if provider == .raindrop { collections = try await raindrop.collections(token: token) }
        var pageNumber = Int(tentative.cursor ?? "0") ?? 0
        while true {
            try ensureCurrent(provider, metadata.generation, fingerprint)
            let page = provider == .readwise ? try await readwise.page(token: token, cursor: tentative.cursor, updatedAfter: overlap, limit: 100) : try await raindrop.page(token: token, page: pageNumber, perPage: 50)
            try ensureCurrent(provider, metadata.generation, fingerprint)
            for item in page.items { tentative.seenIDs.insert(item.id); fetched[item.id] = Self.newest(fetched[item.id] ?? item, item) }
            tentative.skippedRecordCount += page.skippedRecordCount
            if !page.hasMore { break }
            guard let next = page.nextCursor else { throw IntegrationError.invalidResponse }
            tentative.cursor = next; tentative.fetchedItems = fetched.values.sorted(by: Self.itemOrder); committed.tentativePagination = tentative
            try ensureCurrent(provider, metadata.generation, fingerprint); try await cache.save(committed)
            if let progress {
                await progress(Self.preview(committed: committed, fetched: fetched, collections: collections))
                try ensureCurrent(provider, metadata.generation, fingerprint)
            }
            if provider == .raindrop { pageNumber = Int(next) ?? (pageNumber + 1) }
        }
        try ensureCurrent(provider, metadata.generation, fingerprint)
        var merged = Dictionary(committed.items.map { ($0.id, $0) }, uniquingKeysWith: Self.newest)
        if actualMode == .full && tentative.skippedRecordCount == 0 { merged = fetched } else { for item in fetched.values { merged[item.id] = Self.newest(merged[item.id] ?? item, item) } }
        committed.items = merged.values.sorted(by: Self.itemOrder); committed.collections = collections; committed.tentativePagination = nil; committed.lastSuccessfulSync = now(); committed.skippedRecordCount = tentative.skippedRecordCount
        if let maximum = fetched.values.map(\.updatedAt).max(), committed.committedBoundary == nil || maximum > committed.committedBoundary! { committed.committedBoundary = maximum }
        if actualMode == .full && tentative.skippedRecordCount == 0 { committed.lastFullSweep = now() }
        try ensureCurrent(provider, metadata.generation, fingerprint); try await cache.save(committed); return committed
    }

    private func performDownload(_ item: ReadLaterItem, generation: Int, fingerprint: String, progress: @escaping @Sendable (Double?) async -> Void) async throws -> ExternalOpenRoute {
        guard let strategy = item.pdfRetrieval else { return .web(item.sourceURL) }
        guard let token = await credentials.credential(for: item.provider) else { throw IntegrationError.disconnected }
        let source: URL
        switch strategy { case .readwiseItem(let id): guard let value = try await readwise.rawSourceURL(token: token, itemID: id) else { throw IntegrationError.notPDF }; source = value; case .raindropURL(let url): source = url }
        try ensureCurrent(item.provider, generation, fingerprint)
        let temporary = try await cache.temporaryDownloadURL(provider: item.provider, itemID: item.vendorID)
        let result = try await downloader.download(URLRequest(url: source), to: temporary, maximumBytes: maximumPDFBytes, progress: progress)
        do {
            let data = try Data(contentsOf: result.temporaryURL, options: .mappedIfSafe)
            guard data.prefix(5) == Data("%PDF-".utf8), PDFDocument(url: result.temporaryURL) != nil else { throw IntegrationError.notPDF }
            try ensureCurrent(item.provider, generation, fingerprint)
            let manifest = IntegrationsCache.DownloadManifest(provider: item.provider, itemID: item.vendorID, revision: ISO8601DateFormatter.integrationString(from: item.updatedAt), etag: result.response.value(forHTTPHeaderField: "ETag"), installedAt: now())
            return .file(try await cache.installDownload(temporaryURL: result.temporaryURL, manifest: manifest))
        } catch { try? FileManager.default.removeItem(at: result.temporaryURL); throw error }
    }

    private func validateToken(_ token: String, _ provider: IntegrationProvider) async throws { switch provider { case .readwise: try await readwise.validate(token: token); case .raindrop: try await raindrop.validate(token: token) } }
    private func ensureCurrent(_ provider: IntegrationProvider, _ generation: Int, _ fingerprint: String) throws { let value = preferences.metadata(for: provider); guard value.enabled, value.generation == generation, value.accountFingerprint == fingerprint else { throw IntegrationError.staleGeneration }; try Task.checkCancellation() }
    private func cancelDownloads(_ provider: IntegrationProvider) { for (key, task) in downloadTasks where key.hasPrefix(provider.rawValue + ":") { task.cancel(); downloadTasks[key] = nil } }
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
