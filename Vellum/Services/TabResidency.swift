import Dispatch
import Foundation

// Open-tab residency policy (issue #52).
//
// Two things used to be thrown away the moment the user switched tabs: the
// SwiftUI/AppKit view tree (`PaneView` keyed its viewer on `activeTabId`) and,
// with it, everything expensive the tab owned — the parsed `PDFDocument`, the
// live `PDFView`, the `WKWebView` and its web content process. Coming back
// meant re-reading the file, re-parsing it, re-stripping the embedded
// annotations, re-consulting the page-text cache, re-laying-out PDFKit, and for
// a webpage a full network re-fetch through the proxy scheme handler.
//
// The fix has two halves, and they live in different places:
//
//   * **View residency** — `PaneView` now keeps a `LiveTabHost` mounted for
//     every open tab and merely hides the inactive ones. Nothing is torn down
//     on a switch, so a switch costs an opacity change. That is what makes it
//     *instant*; keeping the parsed document alive without keeping the view
//     alive still pays a full PDFKit relayout on the way back.
//
//   * **This file** — the policy that decides how long that stays true. "Keep
//     every open tab's `PDFView` and `WKWebView` alive forever" is a straight
//     path to being jetsammed by a user with forty tabs of scanned PDFs, so
//     residency needs a ceiling, an idle window, and a pressure valve.
//
// The policy has three layers, in priority order:
//
//   1. A tab that is *active* in some pane is never evicted, however long the
//      user has been sitting on it. Pinning is per-pane, so a split window
//      keeps BOTH visible documents resident.
//   2. A tab idle for longer than `retentionWindow` (2 hours) is evicted.
//   3. Ceilings — a resident-tab count limit and an approximate byte budget —
//      evict the least-recently-active *inactive* tabs early, and the system
//      memory-pressure source tightens both sharply when the OS says it is
//      short on RAM.
//
// Everything here is main-actor: the stores it serves are `@Observable` and
// main-actor, and eviction reaches into PDFKit/WebKit objects that are only
// safe to touch there.

// MARK: - Clock

/// Monotonic time source for the retention policy.
///
/// Deliberately *not* `Date`: the window is a duration-since-last-use, and
/// wall-clock arithmetic breaks in two ways here. An NTP correction or a manual
/// clock change can move `Date()` backwards, which makes an old tab look
/// arbitrarily fresh (never evicted) or instantly stale (evicted mid-session).
///
/// `ContinuousResidencyClock` wraps `ContinuousClock`, which on Darwin is
/// `mach_continuous_time` and therefore **keeps counting while the Mac is
/// asleep**. That is a deliberate choice, not an accident: the issue asks for
/// "inactive for more than 2 hours" as the user experiences it, and a laptop
/// shut for the night has genuinely left those tabs untouched all night, so
/// reclaiming them on wake is right — and it is what stops a machine that
/// sleeps constantly from accumulating unbounded resident documents.
/// `SuspendingClock` would pause across sleep and hold everything resident
/// indefinitely, which is the surprising behaviour we do not want.
///
/// Tests inject a hand-advanced clock so the 2-hour window can be exercised
/// without waiting 2 hours.
@MainActor
protocol ResidencyClock: AnyObject {
    /// Monotonic elapsed time since an arbitrary, fixed origin. Never decreases.
    var now: Duration { get }
}

@MainActor
final class ContinuousResidencyClock: ResidencyClock {
    private let origin = ContinuousClock.now
    var now: Duration { ContinuousClock.now - origin }
}

// MARK: - Resident resources

/// The expensive native state one tab owns and the policy can reclaim: in
/// production always a `LiveTabRuntime` (its `PdfViewerController` with the
/// parsed `PDFDocument` and live `PDFView`, and its `WebViewerController` with
/// the `WKWebView`). Kept as a protocol so the policy can be unit-tested
/// against a trivial stand-in rather than against PDFKit and WebKit.
///
/// Conformers are responsible for being safe to drop at *any* moment an
/// eviction can fire. In practice that means nothing user-visible may live only
/// inside the resource: annotations round-trip through the session backend on
/// every edit, extracted page text is owned by `PageTextPersister` (which
/// flushes itself, detached, on the way out), and reading position is mirrored
/// into `PdfTab` / `last_page` metadata on every scroll. If that ever stops
/// being true the flush belongs in `releaseResidency()`, which is the single
/// funnel every eviction path (timeout, ceiling, memory pressure, tab close,
/// app teardown) goes through.
@MainActor
protocol TabResidentResource: AnyObject {
    /// Rough resident footprint in bytes. Only used to rank eviction candidates
    /// and to enforce the byte budget, so an order-of-magnitude estimate is
    /// fine — do not go measuring anything expensive to produce this. Read
    /// lazily at sweep time, so it may grow as the tab loads.
    var residencyCostBytes: Int { get }

    /// Release the native state. Called on the main actor and must be
    /// idempotent — `release(tabId:)` and a sweep can both reach the same
    /// resource, and `LiveTabRuntime` is also evicted directly on tab close.
    func releaseResidency()
}

// MARK: - Manager

@MainActor
final class TabResidencyManager {
    /// **The retention window.** An open tab keeps everything expensive it owns
    /// for this long after it was last the active tab; past it, the resources
    /// are reclaimed and the next visit reloads from scratch. Two hours per
    /// issue #52 — long enough that a normal day of hopping between references
    /// never pays a reload, short enough that yesterday's reading does not
    /// still own a gigabyte this morning.
    static let retentionWindow: Duration = .seconds(2 * 60 * 60)

    /// Ceiling on how many tabs stay resident at once, regardless of how recently
    /// they were used. Eight covers "a paper plus its references" comfortably
    /// while bounding the worst case for someone who leaves forty tabs open.
    static let residentTabLimit = 8

    /// Approximate ceiling on total resident bytes. A single 400 MB scanned PDF
    /// plus a couple of heavy web tabs should still fit; a shelf of them should
    /// not. Deliberately generous — the memory-pressure hook below is the real
    /// safety net, this is just a guardrail against obvious runaway.
    ///
    /// Read it as a rough guardrail, not accounting: PDFs are costed at their
    /// *file* size and PDFKit's live footprint is some multiple of that, and
    /// there is no cheap way to do better.
    static let residentByteBudget = 768 * 1024 * 1024

    /// Tightened ceilings applied while the system reports memory pressure. At
    /// `.warning` we shrink hard but keep a little warmth; at `.critical` every
    /// inactive tab goes immediately (see `handleMemoryPressure`).
    static let pressureTabLimit = 2
    static let pressureByteBudget = 128 * 1024 * 1024

    /// How often the shared sweeper wakes. One tick per minute is ample
    /// resolution for a two-hour window, and the generous tolerance lets the
    /// kernel coalesce it with other timers so an idle Vellum is not the reason
    /// a Mac stays awake. The sweeper only runs while something is resident.
    static let sweepInterval: Duration = .seconds(60)
    static let sweepTolerance: Duration = .seconds(30)

    /// Severity reported by the system memory-pressure source, normalised so the
    /// policy does not have to import Dispatch's option set at every call site.
    enum PressureLevel: Sendable {
        case warning
        case critical
    }

    private struct Entry {
        let resource: any TabResidentResource
        /// Clock reading when this tab was last the active tab (or first stored).
        var lastActive: Duration
    }

    private let clock: ResidencyClock
    private let retention: Duration
    private let tabLimit: Int
    private let byteBudget: Int
    /// False in tests: no background sweeper task, no memory-pressure source, so
    /// a test drives `sweep()` and `handleMemoryPressure(_:)` deterministically.
    private let automaticMaintenance: Bool

    /// One entry per resident tab. A tab is a single resource — its
    /// `LiveTabRuntime` — because that object already owns both the PDF and the
    /// web side of the tab. There is deliberately no second cache anywhere else
    /// in the app: if `AppStore` also held parsed `PDFDocument`s, evicting a
    /// runtime would free the view but not the document it was showing.
    private var entries: [String: Entry] = [:]
    /// Active tab of each pane, keyed by that pane's `AppStore` identity. A tab
    /// listed here is pinned: the user is looking at it right now, so no amount
    /// of idle time or memory pressure may pull it out from under them.
    private var activeTabByOwner: [ObjectIdentifier: String] = [:]

    private var sweepTask: Task<Void, Never>?
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    /// Coalesces the deferred ceiling check `store` schedules — see
    /// `scheduleCeilingEnforcement`. One hop per runloop turn, however many
    /// resources are stored in it.
    private var ceilingCheckScheduled = false

    init(
        clock: ResidencyClock = ContinuousResidencyClock(),
        retention: Duration = TabResidencyManager.retentionWindow,
        tabLimit: Int = TabResidencyManager.residentTabLimit,
        byteBudget: Int = TabResidencyManager.residentByteBudget,
        automaticMaintenance: Bool = true
    ) {
        self.clock = clock
        self.retention = retention
        self.tabLimit = tabLimit
        self.byteBudget = byteBudget
        self.automaticMaintenance = automaticMaintenance
        if automaticMaintenance { installMemoryPressureSource() }
    }

    deinit {
        // `deinit` is nonisolated, so only the two handles that are safe to
        // touch from anywhere get cleaned up here. Cancelling the Task stops the
        // sweep loop; cancelling the DispatchSource both stops its handler
        // firing and is what makes a discarded manager (one per test) stop being
        // registered with the kernel. The residents themselves are released by
        // ARC as `entries` tears down. That is enough: `releaseResidency()` has
        // nothing to flush that is not already persisted — annotations
        // round-trip on every edit, page text is flushed detached by
        // `PageTextPersister` and awaited by the quit path, and `last_page` is
        // written on tab switch and again at quit.
        sweepTask?.cancel()
        pressureSource?.cancel()
    }

    // MARK: - Store / fetch

    /// Make `resource` resident for `tabId`. Replacing an existing resource for
    /// the same tab releases the old one — there is never a moment where two
    /// live `WKWebView`s claim the same tab.
    ///
    /// Call this when the tab actually acquires native state (i.e. when it is
    /// first shown), not when its runtime object is created: `PaneView` creates
    /// a runtime for every open tab during layout, and a tab that has never been
    /// looked at holds nothing worth counting against a ceiling.
    func store(_ resource: any TabResidentResource, tabId: String) {
        if let existing = entries[tabId], existing.resource !== resource {
            existing.resource.releaseResidency()
        }
        // Storing is itself evidence of use — a resource is only ever built for
        // the tab the user just opened or switched to — so it stamps the idle
        // clock. In practice `markActive` has already stamped it a moment
        // earlier from `applyActiveState`; doing it here too means a caller that
        // forgets to can never hand us something that is stale on arrival.
        entries[tabId] = Entry(resource: resource, lastActive: clock.now)
        startSweeperIfNeeded()
        scheduleCeilingEnforcement()
    }

    /// The resident resource for a tab, if we still have it. Reading does *not*
    /// count as use — only `markActive` (and `store`) move a tab's idle clock,
    /// because that is the signal the issue is actually about ("inactive tab"),
    /// and a background probe must not be able to keep a tab alive forever.
    func resource(tabId: String) -> (any TabResidentResource)? {
        entries[tabId]?.resource
    }

    func isResident(tabId: String) -> Bool { entries[tabId] != nil }

    // MARK: - Activity tracking

    /// Report which tab a pane is currently showing. Pass `nil` when the pane
    /// goes empty. Pinning is per-pane (`owner`) so a split window keeps *both*
    /// visible documents resident.
    func markActive(tabId: String?, owner: ObjectIdentifier) {
        // The outgoing tab starts its idle countdown from now, not from whenever
        // it was activated — it was in use right up to this moment.
        if let outgoing = activeTabByOwner[owner], outgoing != tabId {
            stamp(outgoing)
        }
        if let tabId {
            activeTabByOwner[owner] = tabId
            stamp(tabId)
        } else {
            activeTabByOwner[owner] = nil
        }
    }

    /// Drop a pane's pin when the pane itself goes away (collapsed by a split
    /// close, or absorbed by View ▸ Merge Panes). Without this, a discarded
    /// pane's last active tab would stay pinned forever.
    func forgetOwner(_ owner: ObjectIdentifier) {
        guard let tabId = activeTabByOwner.removeValue(forKey: owner) else { return }
        stamp(tabId)
    }

    private func stamp(_ tabId: String) {
        entries[tabId]?.lastActive = clock.now
    }

    // MARK: - Release

    /// Immediate, unconditional release of everything a tab owns. This is the
    /// close-tab path: retention is about tabs that are still *open*, so closing
    /// one gives its memory back straight away rather than two hours later.
    func release(tabId: String) {
        entries.removeValue(forKey: tabId)?.resource.releaseResidency()
        stopSweeperIfIdle()
    }

    /// Release everything (app teardown / tests).
    func releaseAll() {
        for entry in entries.values { entry.resource.releaseResidency() }
        entries.removeAll()
        stopSweeperIfIdle()
    }

    // MARK: - Sweeping

    /// Apply the whole policy once. Returns the tab ids that lost a resource,
    /// which is what the tests assert on.
    @discardableResult
    func sweep() -> [String] {
        evict(tabLimit: tabLimit, byteBudget: byteBudget, expireIdle: true)
    }

    /// Apply only the ceilings — the count limit and the byte budget — without
    /// the retention window. This is what `store` triggers, because the sweeper
    /// is the *wrong* place to bound a burst: it first ticks a full
    /// `sweepInterval` (60s) after the first resource is stored, so without this
    /// everything a user could open in a minute stayed resident no matter how
    /// far past the ceilings it went. The window itself is left to the sweeper —
    /// nothing can newly cross a two-hour threshold as a result of a store.
    @discardableResult
    func enforceCeilings() -> [String] {
        evict(tabLimit: tabLimit, byteBudget: byteBudget, expireIdle: false)
    }

    /// Run `enforceCeilings` on the next main-actor turn rather than inline.
    ///
    /// `store` is reachable from a SwiftUI `body` — `PaneView` resolves a tab's
    /// runtime there — and eviction mutates `@Observable` state on the resources
    /// it releases (`LiveTabRuntime.isEvicted`, `WebViewerController.initCount`),
    /// which is exactly the "modifying state during view update" hazard. A hop
    /// sidesteps that and is still three orders of magnitude sooner than the
    /// next sweep, which is the whole point.
    private func scheduleCeilingEnforcement() {
        guard automaticMaintenance, !ceilingCheckScheduled else { return }
        ceilingCheckScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.ceilingCheckScheduled = false
            self.enforceCeilings()
        }
    }

    /// Respond to the system running short on memory. This is the escape hatch
    /// that makes "keep every open tab resident" survivable: the 2-hour window
    /// is a *ceiling* on how long we hold things, never a promise to hold them
    /// that long when the OS is asking for the memory back.
    @discardableResult
    func handleMemoryPressure(_ level: PressureLevel) -> [String] {
        switch level {
        case .warning:
            // Keep the pinned tabs plus a small warm set — switching between the
            // two documents you are comparing should still be instant even on a
            // machine that is swapping. Dropping *everything* on the first
            // `.warning` (which macOS raises routinely) would effectively delete
            // the feature on a busy machine.
            return evict(
                tabLimit: Self.pressureTabLimit,
                byteBudget: Self.pressureByteBudget,
                expireIdle: true)
        case .critical:
            // Everything that is not on screen goes, now.
            return evict(tabLimit: 0, byteBudget: 0, expireIdle: true)
        }
    }

    /// The one eviction routine. Pinned tabs are exempt from every rule;
    /// everything else is ordered least-recently-active first and dropped until
    /// both ceilings are satisfied.
    private func evict(tabLimit: Int, byteBudget: Int, expireIdle: Bool) -> [String] {
        let pinned = Set(activeTabByOwner.values)
        let now = clock.now
        var evicted: [String] = []

        // Pass 1 — the retention window.
        if expireIdle {
            for (tabId, entry) in entries
            where !pinned.contains(tabId) && now - entry.lastActive >= retention {
                entries.removeValue(forKey: tabId)?.resource.releaseResidency()
                evicted.append(tabId)
            }
        }

        // Pass 2 — the ceilings, least-recently-active first.
        var candidates = residentTabsByIdleDescending(excluding: pinned)
        while !candidates.isEmpty,
              residentTabCount > max(0, tabLimit) || residentBytes > max(0, byteBudget) {
            let victim = candidates.removeFirst()
            entries.removeValue(forKey: victim)?.resource.releaseResidency()
            evicted.append(victim)
        }

        stopSweeperIfIdle()
        return evicted
    }

    /// Resident, unpinned tabs ordered most-idle first — i.e. ascending by
    /// `lastActive`, which is the order eviction wants to consume.
    private func residentTabsByIdleDescending(excluding pinned: Set<String>) -> [String] {
        entries
            .filter { !pinned.contains($0.key) }
            .sorted { $0.value.lastActive < $1.value.lastActive }
            .map(\.key)
    }

    // MARK: - Introspection (diagnostics + tests)

    var residentTabIds: Set<String> { Set(entries.keys) }
    var residentTabCount: Int { entries.count }
    var residentBytes: Int { entries.values.reduce(0) { $0 + $1.resource.residencyCostBytes } }
    var isSweeping: Bool { sweepTask != nil }

    // MARK: - Background machinery

    /// One shared sweeper for the whole app, started lazily on the first
    /// resident resource and stopped as soon as nothing is resident — an idle
    /// Vellum schedules no timer at all. One `Task` rather than a timer per tab:
    /// forty open tabs must not mean forty wakeups.
    private func startSweeperIfNeeded() {
        guard automaticMaintenance, sweepTask == nil, !entries.isEmpty else { return }
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.sweepInterval, tolerance: Self.sweepTolerance)
                } catch {
                    return  // cancelled
                }
                guard let self, !Task.isCancelled else { return }
                self.sweep()
            }
        }
    }

    /// `evict()` and `release()` call this, so the loop cancels *itself* once
    /// the last resource is gone; the `Task.isCancelled` check at the top of the
    /// loop then exits.
    private func stopSweeperIfIdle() {
        guard entries.isEmpty, let task = sweepTask else { return }
        sweepTask = nil
        task.cancel()
    }

    /// Subscribe to the kernel's memory-pressure notifications. `DispatchSource`
    /// (rather than `NSApplication`, which has no equivalent signal on macOS) is
    /// the supported way to hear about this; the handler is delivered on the main
    /// queue so it can go straight into the main-actor eviction path.
    private func installMemoryPressureSource() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical], queue: .main)
        // Read the level off `self.pressureSource` rather than capturing `source`
        // in the handler: a handler that captures its own source forms a
        // retain cycle that only `cancel()` can break, and we would rather not
        // depend on `deinit` running to avoid a leak.
        source.setEventHandler { [weak self] in
            // The handler runs on DispatchQueue.main, which *is* the main actor's
            // executor, but Dispatch cannot express that in the type system.
            MainActor.assumeIsolated {
                guard let self, let data = self.pressureSource?.data else { return }
                if data.contains(.critical) {
                    self.handleMemoryPressure(.critical)
                } else if data.contains(.warning) {
                    self.handleMemoryPressure(.warning)
                }
            }
        }
        source.resume()
        pressureSource = source
    }
}
