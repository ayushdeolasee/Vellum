import Foundation

// The executing half of read-later autopull, and the only place the three
// pre-built pieces are joined: `ReadLaterPrefetchPlanner` decides, an
// `ReadLaterOfflineStoring` moves the bytes, and `RetentionLedger` starts (and
// later ends) the fourteen-day clock on what landed.
//
// Every entry point takes the queue as an argument rather than reaching for a
// store: prefetch, sweep and reconcile must all see the SAME item list the
// caller saw, and an actor that fetched its own would race the sync engine.

struct ReadLaterPrefetchReport: Sendable, Equatable {
    var planned = 0
    var stored = 0
    var failed = 0
    var skipped = 0
    var bytes = 0
    /// The run stopped early because a provider rate-limited it.
    var backedOff = false

    init(
        planned: Int = 0, stored: Int = 0, failed: Int = 0, skipped: Int = 0, bytes: Int = 0,
        backedOff: Bool = false
    ) {
        self.planned = planned
        self.stored = stored
        self.failed = failed
        self.skipped = skipped
        self.bytes = bytes
        self.backedOff = backedOff
    }
}

/// The seam `StorageHousekeeping` evicts read-later bytes through. Narrow on
/// purpose: housekeeping knows "sweep expired offline copies", not what a
/// provider, an item or a fourteen-day window is.
protocol ReadLaterRetentionSweeping: Sendable {
    func sweepExpiredOfflineCopies(
        now: Date, openDocumentPaths: Set<String>
    ) async -> RetentionSweepReport
}

actor ReadLaterPrefetcher {
    private let offline: any ReadLaterOfflineStoring
    private let ledger: RetentionLedger
    private let state: ReadLaterPrefetchState
    private let clock: PositionClock
    /// One run at a time. The triggers overlap by design (a foreground sync
    /// finishing while a background refresh is mid-flight), and two runs would
    /// plan against the same "not downloaded yet" facts and transfer twice.
    private var isRunning = false

    init(
        offline: any ReadLaterOfflineStoring,
        ledger: RetentionLedger = RetentionLedger(),
        state: ReadLaterPrefetchState = ReadLaterPrefetchState(),
        clock: PositionClock = SystemPositionClock()
    ) {
        self.offline = offline
        self.ledger = ledger
        self.state = state
        self.clock = clock
    }

    // MARK: - Events

    /// Opening an item is a read: it restarts the fourteen-day window and, if
    /// retention had already expired this item, lifts the tombstone so the copy
    /// may be downloaded again.
    func markRead(_ item: ReadLaterItem) async {
        await ledger.markRead(item.id, at: clock.now())
        await state.clearEviction(item.id)
    }

    func markAnnotated(_ item: ReadLaterItem) async {
        await ledger.markAnnotated(item.id, at: clock.now())
        await state.clearEviction(item.id)
    }

    // MARK: - Prefetch

    @discardableResult
    func run(
        items: [ReadLaterItem],
        isEnabled: Bool,
        policy: ReadLaterPrefetchPolicy = .foreground
    ) async -> ReadLaterPrefetchReport {
        guard isEnabled else { return ReadLaterPrefetchReport(skipped: items.count) }
        // An empty queue is "the store hasn't loaded yet", not "the user has
        // nothing saved". Doing the bookkeeping below against it would drop
        // every eviction tombstone and hand the whole expired queue back to the
        // next run.
        guard !items.isEmpty else { return ReadLaterPrefetchReport() }
        guard !isRunning else { return ReadLaterPrefetchReport() }
        isRunning = true
        defer { isRunning = false }

        await state.retainOnly(Set(items.map(\.id)))
        await reconcileExemptions(items: items)

        // Gathering facts is I/O per item (a stat for a page, an actor hop and a
        // manifest read for a PDF), so a five-thousand-item Readwise library
        // must not be probed end to end to fill a four-item budget. Look at a
        // generous multiple of what the run could possibly take, newest first;
        // everything past that is skipped without being touched.
        let inspectionLimit = max(policy.maximumItems * 8, policy.maximumItems)
        var candidates: [ReadLaterItem] = []
        for item in items.sorted(by: ReadLaterPrefetchPlanner.candidateOrder)
        where policy.kinds.contains(item.kind) {
            if candidates.count >= inspectionLimit { break }
            candidates.append(item)
        }

        let evicted = await state.evictedIDs()
        var facts: [ReadLaterItem.ID: ReadLaterPrefetchFacts] = [:]
        let tracked = await ledger.snapshot().items
        for item in candidates {
            facts[item.id] = ReadLaterPrefetchFacts(
                hasOfflineCopy: await offline.hasOfflineCopy(for: item),
                wasEvicted: evicted.contains(item.id),
                estimatedBytes: tracked[item.id]?.offlineBytes)
        }

        let plan = ReadLaterPrefetchPlanner.plan(
            items: candidates,
            isEnabled: true,
            policy: policy,
            facts: { facts[$0.id] ?? ReadLaterPrefetchFacts() })

        var report = ReadLaterPrefetchReport(
            planned: plan.fetch.count,
            skipped: (items.count - candidates.count) + (plan.decisions.count - plan.fetch.count))
        var backedOff: Set<IntegrationProvider> = []
        for item in plan.fetch {
            if Task.isCancelled { break }
            // A provider that rate-limited us this run gets no further
            // requests: the sync engine's own traversal shares that quota, and
            // hammering it would cost the item list as well as the bytes.
            guard !backedOff.contains(item.provider) else {
                report.skipped += 1
                continue
            }
            do {
                let bytes = try await offline.storeOfflineCopy(for: item)
                // The clock starts HERE — at local ingestion — not at the
                // provider's `saved_at`, which can be months old.
                await ledger.markAdded(item.id, at: clock.now(), offlineBytes: bytes)
                await state.clearEviction(item.id)
                report.stored += 1
                report.bytes += bytes
            } catch is CancellationError {
                break
            } catch IntegrationError.rateLimited {
                backedOff.insert(item.provider)
                report.backedOff = true
                report.skipped += 1
            } catch {
                // Nothing is recorded for a failure: an item with no offline
                // copy must not be given a retention entry, or the next sweep
                // would "delete" bytes that were never written.
                report.failed += 1
            }
        }
        return report
    }

    // MARK: - Retention

    /// Marks every item the user has annotated (or explicitly kept) as exempt
    /// before any verdict is computed. One-way: `RetentionLedger` can add an
    /// exemption but never clear one, so a page whose sidecar is momentarily
    /// unreadable cannot lose its exemption.
    func reconcileExemptions(items: [ReadLaterItem]) async {
        let tracked = await ledger.snapshot().items
        guard !tracked.isEmpty else { return }
        var exempt: Set<String> = []
        for item in items where tracked[item.id] != nil && tracked[item.id]?.annotatedAt == nil {
            if await offline.isExempt(item) { exempt.insert(item.id) }
        }
        await ledger.reconcileAnnotations(itemIDsWithAnnotations: exempt)
    }

    /// Deletes the offline copies retention has expired, and remembers which
    /// ids those were so the next prefetch run does not immediately re-download
    /// them. Items whose copy could not be deleted stay tracked and untombstoned.
    @discardableResult
    func sweep(
        items: [ReadLaterItem],
        now: Date,
        openDocumentPaths: Set<String> = []
    ) async -> RetentionSweepReport {
        // Same reason `run` refuses an empty queue: without the items, ledger
        // ids can only be mapped back to downloaded PDFs, and a page's archive
        // would be forgotten (not deleted) on the strength of a list that had
        // simply not loaded yet. The caller loads first — see
        // `IntegrationsStore.sweepExpiredOfflineCopies`.
        guard !items.isEmpty else { return RetentionSweepReport() }
        await reconcileExemptions(items: items)
        let byID = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let deleted = DeletedIDs()
        let report = await ledger.sweep(now: now) { itemID in
            let removed: Bool
            if let item = byID[itemID] {
                removed = await offline.removeOfflineCopy(
                    for: item, openDocumentPaths: openDocumentPaths)
            } else {
                removed = await offline.removeOfflineCopy(
                    forItemID: itemID, openDocumentPaths: openDocumentPaths)
            }
            if removed { await deleted.insert(itemID) }
            return removed
        }
        await state.markEvicted(await deleted.ids(), at: now)
        return report
    }

    /// Collects ids across the sweep's `@Sendable` deleter hops.
    private actor DeletedIDs {
        private var stored: [String] = []
        func insert(_ itemID: String) { stored.append(itemID) }
        func ids() -> [String] { stored }
    }
}
