import Foundation

// The decision half of read-later autopull: given the queue and what is already
// on disk, WHICH items should this run download, and why was everything else
// left alone. Pure — no I/O, no `Date()`, no globals — so the rules can be
// tested exhaustively without a network or a filesystem, exactly like
// `RetentionEngine` is for the clock.
//
// The executing half (`ReadLaterPrefetcher`) supplies the facts and performs
// the transfers. Keeping the two apart is what stops "should we?" from being
// re-derived inside a `catch` block three layers down.

/// The budget for one run. Two presets, because the two triggers have wildly
/// different budgets: a foreground run rides a sync the user can see, while a
/// `BGAppRefreshTask` gets tens of seconds of wall clock and a battery the
/// system is accounting for.
struct ReadLaterPrefetchPolicy: Sendable, Equatable {
    /// Hard cap on transfers started per run.
    var maximumItems: Int
    /// Soft cap: the run stops planning once the ESTIMATED bytes of what it has
    /// already planned reach this. It is a planning bound, not a transfer bound
    /// — the real per-file ceiling is the download plumbing's own byte cap
    /// (`IntegrationsSyncEngine.maximumPDFBytes` for PDFs,
    /// `WebFetch.maxResponseBytes` for pages), which this can never widen.
    var maximumBytes: Int
    /// Kinds Vellum can actually produce an offline copy of. A video or an
    /// EPUB has no reader here, so downloading one would spend bytes on
    /// something the app cannot open.
    var kinds: Set<ReadLaterKind>

    init(
        maximumItems: Int = 12,
        maximumBytes: Int = 64 * 1024 * 1024,
        kinds: Set<ReadLaterKind> = [.article, .pdf]
    ) {
        self.maximumItems = max(0, maximumItems)
        self.maximumBytes = max(0, maximumBytes)
        self.kinds = kinds
    }

    /// Rides the sync engine's startup / staleness / manual triggers.
    static let foreground = ReadLaterPrefetchPolicy()
    /// The BGAppRefreshTask budget.
    static let background = ReadLaterPrefetchPolicy(
        maximumItems: 4, maximumBytes: 16 * 1024 * 1024)
}

/// Why an item was passed over. A closed set, because these are the only
/// reasons that exist and a UI (or a test) should be able to switch over them.
enum ReadLaterPrefetchSkip: String, Sendable, Equatable, CaseIterable {
    /// "Download for offline reading" is off.
    case disabled
    /// No offline representation exists for this kind.
    case unsupportedKind
    /// The bytes are already here and current.
    case alreadyOffline
    /// Retention already expired this item's copy once. Re-downloading it would
    /// restart the fourteen-day clock on its own, which turns the retention
    /// engine into an expensive no-op; only a READ clears the tombstone.
    case expiredOnce
    case itemBudget
    case byteBudget
    /// The provider rate-limited this run; every later item of that provider is
    /// left for the next one.
    case providerBackedOff
}

enum ReadLaterPrefetchDecision: Sendable, Equatable {
    case fetch(estimatedBytes: Int)
    case skip(ReadLaterPrefetchSkip)

    var isFetch: Bool { if case .fetch = self { return true } else { return false } }
    var skip: ReadLaterPrefetchSkip? { if case .skip(let value) = self { return value } else { return nil } }
}

/// Everything the planner is allowed to know about one item's local state.
/// Gathering these is the caller's job (they are all I/O); deciding on them is
/// this file's.
struct ReadLaterPrefetchFacts: Sendable, Equatable {
    var hasOfflineCopy: Bool
    var wasEvicted: Bool
    /// Best guess at the transfer size, used only against `maximumBytes`. A
    /// previous copy's recorded size when one is known, else a per-kind guess.
    var estimatedBytes: Int

    init(hasOfflineCopy: Bool = false, wasEvicted: Bool = false, estimatedBytes: Int? = nil) {
        self.hasOfflineCopy = hasOfflineCopy
        self.wasEvicted = wasEvicted
        self.estimatedBytes = estimatedBytes ?? 0
    }

    /// Deliberately coarse. Being wrong here costs at most one extra item in a
    /// run; being precise would mean a HEAD request per item.
    static func estimate(for kind: ReadLaterKind) -> Int {
        switch kind {
        case .pdf: 6 * 1024 * 1024
        case .article: 1_500_000
        case .epub, .video, .other: 0
        }
    }
}

struct ReadLaterPrefetchPlan: Sendable, Equatable {
    /// In the order the run should transfer them.
    var fetch: [ReadLaterItem] = []
    var decisions: [ReadLaterItem.ID: ReadLaterPrefetchDecision] = [:]
    var estimatedBytes: Int = 0

    func decision(for id: ReadLaterItem.ID) -> ReadLaterPrefetchDecision? { decisions[id] }
    func skipCount(_ reason: ReadLaterPrefetchSkip) -> Int {
        decisions.values.count { $0.skip == reason }
    }
}

enum ReadLaterPrefetchPlanner {
    /// Newest first. The queue's own order is `updatedAt` (which a provider-side
    /// re-tag bumps), so ordering by when the user SAVED it is what makes "the
    /// thing I added this morning" the first thing on the phone.
    static func candidateOrder(_ lhs: ReadLaterItem, _ rhs: ReadLaterItem) -> Bool {
        lhs.savedAt == rhs.savedAt ? lhs.id < rhs.id : lhs.savedAt > rhs.savedAt
    }

    /// One item's verdict, with the budgets already reduced by everything
    /// planned before it. Split out from `plan` so each rule can be tested on
    /// its own, and so the precedence between rules is written down once.
    static func decide(
        _ item: ReadLaterItem,
        isEnabled: Bool,
        facts: ReadLaterPrefetchFacts,
        policy: ReadLaterPrefetchPolicy,
        remainingItems: Int,
        remainingBytes: Int,
        backedOffProviders: Set<IntegrationProvider>
    ) -> ReadLaterPrefetchDecision {
        // Order matters: the reasons that are properties of the WORLD come
        // before the ones that are properties of this particular run, so a
        // report never says "budget" about something that was never eligible.
        guard isEnabled else { return .skip(.disabled) }
        guard policy.kinds.contains(item.kind) else { return .skip(.unsupportedKind) }
        guard !facts.hasOfflineCopy else { return .skip(.alreadyOffline) }
        guard !facts.wasEvicted else { return .skip(.expiredOnce) }
        guard !backedOffProviders.contains(item.provider) else { return .skip(.providerBackedOff) }
        guard remainingItems > 0 else { return .skip(.itemBudget) }
        let bytes = facts.estimatedBytes > 0
            ? facts.estimatedBytes
            : ReadLaterPrefetchFacts.estimate(for: item.kind)
        // A single item larger than the whole budget still runs when nothing
        // else has: the alternative is an item that can never be prefetched.
        guard bytes <= remainingBytes || remainingItems == policy.maximumItems else {
            return .skip(.byteBudget)
        }
        return .fetch(estimatedBytes: bytes)
    }

    static func plan(
        items: [ReadLaterItem],
        isEnabled: Bool,
        policy: ReadLaterPrefetchPolicy = .foreground,
        backedOffProviders: Set<IntegrationProvider> = [],
        facts: (ReadLaterItem) -> ReadLaterPrefetchFacts
    ) -> ReadLaterPrefetchPlan {
        var plan = ReadLaterPrefetchPlan()
        var remainingItems = policy.maximumItems
        var remainingBytes = policy.maximumBytes
        for item in items.sorted(by: candidateOrder) {
            // Duplicated ids can't happen inside one provider's snapshot, but
            // `searchableItems` concatenates providers — decide once per id.
            guard plan.decisions[item.id] == nil else { continue }
            let decision = decide(
                item,
                isEnabled: isEnabled,
                facts: facts(item),
                policy: policy,
                remainingItems: remainingItems,
                remainingBytes: remainingBytes,
                backedOffProviders: backedOffProviders)
            plan.decisions[item.id] = decision
            if case .fetch(let bytes) = decision {
                plan.fetch.append(item)
                plan.estimatedBytes += bytes
                remainingItems -= 1
                remainingBytes = max(0, remainingBytes - bytes)
            }
        }
        return plan
    }
}
