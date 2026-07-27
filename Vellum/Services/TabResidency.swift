import Dispatch
import Foundation

// Open-tab residency policy (issue #52).
//
// Before this, an inactive tab dropped everything expensive it owned the moment
// the user switched away. `PaneView` keys its viewer on `activeTabId`, so the
// whole SwiftUI subtree — and with it the parsed `PDFDocument` and the live
// `WKWebView` — was torn down and rebuilt on the way back. For a large PDF that
// meant re-reading the bytes, re-parsing them, re-stripping the embedded
// annotations and re-consulting the page-text cache; for a webpage it meant a
// full network re-fetch through the proxy scheme handler. (An LRU of three
// prepared PDFs used to blunt the worst of the PDF case; this file generalises
// and replaces it.)
//
// The fix is to make "the tab is open" the primary retention signal, and only
// reclaim after a long idle period. The policy has three layers, in priority
// order:
//
//   1. A tab that is *active* in some pane is never evicted, however long the
//      user has been sitting on it.
//   2. A tab idle for longer than `retentionWindow` (2 hours) is evicted.
//   3. Ceilings — a resident-tab count limit and an approximate byte budget —
//      evict the least-recently-active *inactive* tabs early, and the system
//      memory-pressure source tightens both sharply when the OS says it is
//      short on RAM. Without this layer, "hold every open tab forever" is a
//      straight path to being jetsammed by a user with forty tabs of scanned
//      PDFs.
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

/// An expensive per-tab resource the residency policy can hold and reclaim: a
/// parsed display `PDFDocument`, a live `WKWebView` host, and so on.
///
/// Conformers are responsible for being safe to drop at *any* moment an
/// eviction can fire. In practice that means: nothing user-visible may live
/// only inside the resource. Annotations already round-trip through the session
/// backend on every edit, extracted page text is owned by `PageTextPersister`
/// (which flushes itself), and reading position is mirrored into `PdfTab` /
/// `last_page` metadata — so the concrete conformers here have nothing of their
/// own to save. If that ever stops being true, the flush belongs in
/// `releaseResidency()`, which is the single funnel every eviction path
/// (timeout, ceiling, memory pressure, tab close, app teardown) goes through.
@MainActor
protocol TabResidentResource: AnyObject {
    /// Rough resident footprint in bytes. Only used to rank eviction candidates
    /// and to enforce the byte budget, so an order-of-magnitude estimate is
    /// fine — do not go measuring anything expensive to produce this.
    var residencyCostBytes: Int { get }

    /// Flush anything unsaved and release OS resources. Called on the main
    /// actor, exactly once per stored resource, and must be idempotent.
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

    /// Which expensive resource a resident entry holds. A tab has at most one
    /// of each; in practice a tab is either a PDF or a webpage, never both, but
    /// keying by slot keeps the two call sites from stepping on each other (and
    /// leaves room for a third kind without reworking the store).
    enum Slot: Hashable, Sendable {
        case preparedPdf
        case webView
    }

    /// Severity reported by the system memory-pressure source, normalised so the
    /// policy does not have to import Dispatch's option set at every call site.
    enum PressureLevel: Sendable {
        case warning
        case critical
    }

    /// Shared instance. One policy per process: the ceilings and the memory
    /// pressure response are only meaningful app-wide, and a per-pane manager
    /// would mean one sweeper per pane. Tests build their own.
    static let shared = TabResidencyManager()

    private struct Key: Hashable {
        let tabId: String
        let slot: Slot
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

    private var entries: [Key: Entry] = [:]
    /// Last-active reading per tab, kept separately from `entries` so a tab's
    /// two slots can never disagree about how idle the tab is.
    private var lastActiveByTab: [String: Duration] = [:]
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
        // sweep loop; cancelling the DispatchSource stops its handler firing.
        // The residents themselves are released by ARC as `entries` tears down.
        // That is enough: `releaseResidency()` has nothing to flush that is not
        // already persisted (annotations round-trip on every edit, page text is
        // flushed by `PageTextPersister`, `last_page` is written on tab switch
        // and again by the quit path), so there is no unsaved work riding on
        // this teardown. The shared manager never deinits anyway — in practice
        // this only runs for the per-test managers.
        sweepTask?.cancel()
        pressureSource?.cancel()
    }

    // MARK: - Store / fetch

    /// Make `resource` resident for `tabId`. Replacing an existing resource in
    /// the same slot releases the old one — there is never a moment where two
    /// live `WKWebView`s claim the same tab.
    func store(_ resource: any TabResidentResource, tabId: String, slot: Slot) {
        let key = Key(tabId: tabId, slot: slot)
        if let existing = entries[key], existing.resource !== resource {
            existing.resource.releaseResidency()
        }
        // Storing is itself evidence of use — a resource is only ever built for
        // the tab the user just opened or switched to — so it stamps the idle
        // clock. In practice `markActive` has already stamped it a moment
        // earlier from `applyActiveState`; doing it here too means a caller that
        // forgets to can never hand us something that is stale on arrival.
        let now = clock.now
        lastActiveByTab[tabId] = now
        entries[key] = Entry(resource: resource, lastActive: now)
        // Keep a tab's two slots agreeing about how idle the tab is.
        for other in Array(entries.keys) where other.tabId == tabId && other != key {
            entries[other]?.lastActive = now
        }
        startSweeperIfNeeded()
        scheduleCeilingEnforcement()
    }

    /// The resident resource for a tab, if we still have it. Reading does *not*
    /// count as use — only `markActive` (and `store`) move a tab's idle clock,
    /// because that is the signal the issue is actually about ("inactive tab"),
    /// and a background probe must not be able to keep a tab alive forever.
    func resource(tabId: String, slot: Slot) -> (any TabResidentResource)? {
        entries[Key(tabId: tabId, slot: slot)]?.resource
    }

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
        let now = clock.now
        lastActiveByTab[tabId] = now
        // `Array(...)`: `entries.keys` is a live view, so it must be materialised
        // before the dictionary is written through. Same everywhere below.
        for key in Array(entries.keys) where key.tabId == tabId {
            entries[key]?.lastActive = now
        }
    }

    // MARK: - Release

    /// Immediate, unconditional release of everything a tab owns. This is the
    /// close-tab path: retention is about tabs that are still *open*, so closing
    /// one gives its memory back straight away rather than two hours later.
    func release(tabId: String) {
        for key in Array(entries.keys) where key.tabId == tabId {
            entries.removeValue(forKey: key)?.resource.releaseResidency()
        }
        lastActiveByTab[tabId] = nil
        stopSweeperIfIdle()
    }

    /// Release everything (app teardown / tests).
    func releaseAll() {
        for entry in entries.values { entry.resource.releaseResidency() }
        entries.removeAll()
        lastActiveByTab.removeAll()
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
    /// `sweepInterval` (60s) after the first resource is stored, so until this
    /// existed, everything a user could open in a minute stayed resident no
    /// matter how far past the ceilings it went. The window itself is left to
    /// the sweeper — nothing can newly cross a two-hour threshold as a result of
    /// a store.
    @discardableResult
    func enforceCeilings() -> [String] {
        evict(tabLimit: tabLimit, byteBudget: byteBudget, expireIdle: false)
    }

    /// Run `enforceCeilings` on the next main-actor turn rather than inline.
    ///
    /// `store` is reachable from a SwiftUI `body` — `PaneView` resolves a tab's
    /// web controller there — and eviction mutates `@Observable` state on the
    /// resources it releases (`WebViewerController.initCount`), which is exactly
    /// the "modifying state during view update" hazard. A hop sidesteps that and
    /// is still three orders of magnitude sooner than the next sweep, which is
    /// the whole point.
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
            // machine that is swapping.
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
            for (key, entry) in entries.map({ ($0.key, $0.value) })
            where !pinned.contains(key.tabId) && now - entry.lastActive >= retention {
                entries.removeValue(forKey: key)?.resource.releaseResidency()
                // Per *tab*, not per slot: this loop walks slots, so a tab
                // holding both a PDF and a web view would otherwise be reported
                // twice by a routine whose contract is "the tabs that lost a
                // resource" (pass 2 below already appends once per tab).
                if !evicted.contains(key.tabId) { evicted.append(key.tabId) }
            }
        }

        // Pass 2 — the ceilings. Rank surviving *tabs* (not slots) by idle time
        // so a web tab's view and its future siblings leave together.
        var candidates = residentTabsByIdleDescending(excluding: pinned)
        while !candidates.isEmpty,
              residentTabCount > max(0, tabLimit) || residentBytes > max(0, byteBudget) {
            let victim = candidates.removeFirst()
            for key in Array(entries.keys) where key.tabId == victim {
                entries.removeValue(forKey: key)?.resource.releaseResidency()
            }
            evicted.append(victim)
        }

        // Forget idle stamps for tabs we no longer hold anything for, so the
        // dictionary cannot grow without bound over a long session. A tab that
        // is still open just re-stamps on its next activation.
        let live = Set(entries.keys.map(\.tabId)).union(pinned)
        lastActiveByTab = lastActiveByTab.filter { live.contains($0.key) }

        stopSweeperIfIdle()
        return evicted
    }

    private func residentTabsByIdleDescending(excluding pinned: Set<String>) -> [String] {
        var idleByTab: [String: Duration] = [:]
        for (key, entry) in entries where !pinned.contains(key.tabId) {
            // If a tab somehow holds two slots with different stamps, the older
            // one wins — evict on the most pessimistic reading.
            idleByTab[key.tabId] = min(idleByTab[key.tabId] ?? entry.lastActive, entry.lastActive)
        }
        return idleByTab.sorted { $0.value < $1.value }.map(\.key)
    }

    // MARK: - Introspection (diagnostics + tests)

    var residentTabIds: Set<String> { Set(entries.keys.map(\.tabId)) }
    var residentTabCount: Int { residentTabIds.count }
    var residentBytes: Int { entries.values.reduce(0) { $0 + $1.resource.residencyCostBytes } }
    var isSweeping: Bool { sweepTask != nil }

    // MARK: - Background machinery

    /// One shared sweeper for the whole app, started lazily on the first
    /// resident resource and stopped as soon as nothing is resident — an idle
    /// Vellum schedules no timer at all.
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

    /// `sweep()` calls this, so the loop cancels *itself* once the last resource
    /// is gone; the `Task.isCancelled` check at the top of the loop then exits.
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
        source.setEventHandler { [weak self] in
            let data = source.data
            // The handler runs on DispatchQueue.main, which *is* the main actor's
            // executor, but Dispatch cannot express that in the type system.
            MainActor.assumeIsolated {
                guard let self else { return }
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
