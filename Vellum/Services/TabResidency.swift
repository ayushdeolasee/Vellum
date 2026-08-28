#if os(iOS)
import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// Open-tab residency policy (issue #52).
//
// Two things used to be thrown away the moment the user switched tabs: the
// SwiftUI view tree (`PaneView_iOS` keyed its viewer on `activeTabId`) and,
// with it, everything expensive the tab owned — the parsed `PDFDocument`, the
// live `PDFView`, the `WKWebView` and its web content process. Coming back
// meant re-reading the file, re-parsing it, re-stripping the embedded
// annotations, re-consulting the page-text cache, re-laying-out PDFKit, and for
// a webpage a full network re-fetch through the proxy scheme handler.
//
// The fix has two halves, and they live in different places:
//
//   * **View residency** — `PaneView_iOS` now keeps a `LiveTabHost` mounted for
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
// A tab moves through three tiers, and the boundaries between them come from
// the repo owner's request on PR #67 (quoted on each constant below):
//
//   HOT   — the `hotLimit` most recently used tabs (3 on iPad, 2 on iPhone —
//           see `TabResidencyBudget`), for 10 minutes since last active.
//           Kept mounted and rendered, so switching to one is instant. This is
//           the tier the whole feature exists for.
//   WARM  — still resident (parsed `PDFDocument` and live `WKWebView` alive)
//           but dropped out of the rendered tree, so it costs no draw, layout
//           or tile work. Switching back re-parents the existing native view:
//           much faster than a cold open, not quite instant.
//   COLD  — evicted at 30 minutes idle. The next visit reloads from scratch.
//
// Two rules cut across all three:
//
//   * A tab that is *active* in some pane is pinned: always hot, never evicted,
//     however long the user sits on it. Pinning is per-pane, so a split window
//     keeps BOTH visible documents rendered.
//   * Ceilings — a resident-tab count limit and an approximate byte budget —
//     evict the least-recently-active unpinned tabs early, and an iOS memory
//     warning tightens both sharply when the OS says it is short on RAM.
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

// MARK: - Tiers

/// Which of the two *resident* tiers a tab is in. (The third tier, cold, is not
/// a state a resource can be in — it has been released and forgotten.)
enum TabResidencyTier: Sendable {
    /// Mounted and rendered. Switching to this tab is instant.
    case hot
    /// Resident but not rendered: the parsed `PDFDocument` and the live
    /// `WKWebView` are still here, but nothing is drawn or laid out for them.
    case warm
}

// MARK: - Resident resources

/// The expensive native state one tab owns and the policy can reclaim: in
/// production always a `LiveTabRuntime` (its `PdfViewerControlleriOS` with
/// the parsed `PDFDocument` and live `PDFView`, and its `WebViewerController_iOS`
/// with the `WKWebView`). Kept as a protocol so the policy can be unit-tested
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

    /// Move the resource between the hot (rendered) and warm (resident but not
    /// rendered) tiers. Called for every resident tab on every retier — which
    /// includes every sweeper tick — so implementations should treat a repeat of
    /// the current tier as a no-op and keep it cheap.
    func applyResidencyTier(_ tier: TabResidencyTier)

    /// Release the native state. Called on the main actor and must be
    /// idempotent — `release(tabId:)` and a sweep can both reach the same
    /// resource, and `LiveTabRuntime` is also evicted directly on tab close.
    func releaseResidency()
}

// MARK: - Budget

/// The ceilings, as data.
///
/// There is one residency *policy* (`TabResidencyManager` below) and two sets of
/// *numbers*, because one binary now serves two devices with very different
/// footprint limits (#150). Making the numbers a value rather than a compile-time
/// constant means the choice is made exactly once, at the shell seam
/// (`ShellIdiom_iOS`), and can be handed to a test as an argument instead of
/// being asserted against whatever the shipping device happens to want.
///
/// The two WINDOWS are the repo owner's request on PR #67 and are the same on
/// both presets — they describe how a person uses tabs, not how much RAM the
/// device has:
///
///   "Maybe we can keep rendering the previous 5 tabs opened by the user for
///    10 minutes let's say. So that it's instant when switching but if the
///    user hasn't gone back to it then we stop rendering and then after 30
///    minutes let say we can clean that out of the memory completely."
///
/// The COUNT and BYTE ceilings are what differ. Do not retune either preset
/// without going back to that comment and to the per-device reasoning on
/// `.pad` / `.phone`.
struct TabResidencyBudget: Sendable, Equatable {
    /// **Hot set size.** The N most recently active tabs stay mounted and
    /// rendered. Pinned tabs (whatever each pane is showing right now) are hot
    /// *in addition* to these, not out of the same budget: a split window must
    /// never leave a visible document unrendered just because the user has been
    /// round three other tabs.
    var hotLimit: Int

    /// **How long a tab stays rendered** — "for 10 minutes … then we stop
    /// rendering". Measured from when the tab was last active. Past it the tab
    /// drops to warm: its resources stay, but nothing is drawn or laid out for
    /// it. Enforced by the shared sweeper, so the real boundary is this plus up
    /// to one `sweepInterval` — irrelevant for a tier whose only effect is
    /// saving draw work.
    var hotWindow: Duration

    /// **The retention window** — "after 30 minutes … we can clean that out of
    /// the memory completely".
    ///
    /// NOTE THE TENSION: issue #52 says "only remove them if inactive for more
    /// than 2 hours". The owner's later comment on PR #67 says 30 minutes. We
    /// implement 30 minutes as the later and more specific instruction, and the
    /// three-tier split is what makes that defensible — under the old two-tier
    /// design, dropping from 2 hours to 30 minutes would have meant a cold
    /// reload after half an hour, whereas now the tab spends minutes 10–30 warm
    /// and only genuinely reloads past 30.
    var retention: Duration

    /// Ceiling on how many tabs stay resident at once, regardless of how
    /// recently they were used.
    var tabLimit: Int

    /// Approximate ceiling on total resident bytes. Read it as a rough
    /// guardrail, not accounting: PDFs are costed at their *file* size and
    /// PDFKit's live footprint is some multiple of that, and there is no cheap
    /// way to do better. The memory-warning hook is the real safety net.
    var byteBudget: Int

    /// Tightened ceilings applied while the system reports memory pressure. At
    /// `.warning` we shrink to these but keep a little warmth; at `.critical`
    /// every inactive tab goes immediately (see `handleMemoryPressure`).
    var pressureTabLimit: Int
    var pressureByteBudget: Int

    /// iPad (parity #129). macOS ships 5 hot / 8 resident / 768 MB / 2 / 128 MB;
    /// iPadOS enforces a hard per-app footprint and jetsams rather than
    /// swapping, so those would be a crash, not a guardrail, here.
    ///
    /// `hotLimit: 3` because every hot tab keeps a live `PDFView`/`WKWebView` in
    /// the window's layout+display cycle, and an iPad has exactly one window and
    /// at most two visible panes: 3 = the two pinned panes plus one recent.
    /// `tabLimit: 4` still covers "a paper plus its references". At 256 MB a
    /// flat-96 MB web tab plus a large scanned PDF still fits; a shelf of them
    /// does not. Under a memory warning only the tab on screen is worth keeping.
    static let pad = TabResidencyBudget(
        hotLimit: 3,
        hotWindow: .seconds(10 * 60),
        retention: .seconds(30 * 60),
        tabLimit: 4,
        byteBudget: 256 * 1024 * 1024,
        pressureTabLimit: 1,
        pressureByteBudget: 48 * 1024 * 1024)

    /// iPhone (#150 / #153). An order of magnitude under the Mac's 768 MB, which
    /// is the spec's constraint expressed as a number; `TabResidencyBudgetTests`
    /// asserts that relation rather than trusting this comment.
    ///
    /// `hotLimit: 2` because the phone shell has exactly ONE pane (D4), so the
    /// hot set is the document being read plus one recent — there is no second
    /// visible document to keep rendered, and a third live `PDFView` buys
    /// nothing but footprint. `tabLimit: 3` keeps that pair plus one warm tab
    /// behind them. 64 MB is roughly one large scanned PDF plus a web tab, which
    /// is as much as a phone can hold without inviting jetsam; under pressure it
    /// drops to the tab on screen and 24 MB.
    static let phone = TabResidencyBudget(
        hotLimit: 2,
        hotWindow: .seconds(10 * 60),
        retention: .seconds(30 * 60),
        tabLimit: 3,
        byteBudget: 64 * 1024 * 1024,
        pressureTabLimit: 1,
        pressureByteBudget: 24 * 1024 * 1024)
}

// MARK: - Manager

@MainActor
final class TabResidencyManager {
    // MARK: The shipped numbers
    //
    // These stay as statics because they are the iPad preset — the numbers this
    // app shipped with and the ones `TabResidencyTests` pins — and because a
    // handful of call sites and tests read them by name. They are ALIASES now,
    // not the source of truth: the source of truth is `TabResidencyBudget.pad`,
    // and what a given manager actually enforces is whatever budget it was
    // handed (`budget`), which on iPhone is `.phone`.

    static let hotTabLimit = TabResidencyBudget.pad.hotLimit
    static let hotWindow = TabResidencyBudget.pad.hotWindow
    static let retentionWindow = TabResidencyBudget.pad.retention
    static let residentTabLimit = TabResidencyBudget.pad.tabLimit
    static let residentByteBudget = TabResidencyBudget.pad.byteBudget
    static let pressureTabLimit = TabResidencyBudget.pad.pressureTabLimit
    static let pressureByteBudget = TabResidencyBudget.pad.pressureByteBudget

    /// How often the shared sweeper wakes. One tick per minute is ample
    /// resolution for a 10-minute demotion and a 30-minute eviction, and the
    /// generous tolerance lets the kernel coalesce it with other timers. The
    /// sweeper only runs while something is resident and is suspended with the
    /// app, so it is not what drains an iPad battery — the per-frame write
    /// coalescing elsewhere in the tree is.
    static let sweepInterval: Duration = .seconds(60)
    static let sweepTolerance: Duration = .seconds(30)

    /// Severity of a memory-pressure event, normalised so the policy does not
    /// have to reason about the platform's signal at every call site. iOS raises
    /// exactly one undifferentiated warning; `noteMemoryWarning()` is what maps
    /// it onto these two levels.
    enum PressureLevel: Sendable {
        case warning
        case critical
    }

    /// A second warning inside this window means the first eviction did not buy
    /// enough headroom, so the next one drops everything off screen.
    static let pressureEscalationWindow: Duration = .seconds(60)

    private struct Entry {
        let resource: any TabResidentResource
        /// Clock reading when this tab was last the active tab (or first stored).
        var lastActive: Duration
    }

    private let clock: ResidencyClock

    /// The ceilings this manager enforces. Injected at construction from
    /// `ShellIdiom_iOS.current.residencyBudget`, so "phone-sized memory" is a
    /// property of the object rather than of the build.
    let budget: TabResidencyBudget

    // Named shorthands for the budget's fields, so the policy below reads the
    // same as it did when these were stored properties.
    private var retention: Duration { budget.retention }
    private var hotLimit: Int { budget.hotLimit }
    private var hot: Duration { budget.hotWindow }
    private var tabLimit: Int { budget.tabLimit }
    private var byteBudget: Int { budget.byteBudget }

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
    /// `nonisolated(unsafe)` for one reason: `deinit` is nonisolated and this is
    /// the handle it must give back. It is written exactly once, from `init` on
    /// the main actor, and read exactly once, from `deinit` — by which point no
    /// other reference to the manager exists — so there is no race to protect
    /// against.
    private nonisolated(unsafe) var memoryWarningObserver: (any NSObjectProtocol)?
    private var lastMemoryWarning: Duration?
    /// Coalesces the deferred ceiling check `store` schedules — see
    /// `scheduleCeilingEnforcement`. One hop per runloop turn, however many
    /// resources are stored in it.
    private var ceilingCheckScheduled = false

    /// The designated init. `.pad` by default so every call site that predates
    /// the phone — including `WorkspaceStore`'s own default — keeps the numbers
    /// it already had.
    init(
        clock: ResidencyClock = ContinuousResidencyClock(),
        budget: TabResidencyBudget = .pad,
        automaticMaintenance: Bool = true
    ) {
        self.clock = clock
        self.budget = budget
        self.automaticMaintenance = automaticMaintenance
        if automaticMaintenance { installMemoryWarningObserver() }
    }

    /// Field-by-field convenience shim, kept because the residency suite builds
    /// managers by overriding one ceiling at a time and that is the clearest way
    /// to write those tests. `clock` and `retention` are deliberately NOT
    /// defaulted: an all-defaults overload would be ambiguous with the budget
    /// init above, and every caller of this form passes both anyway.
    convenience init(
        clock: ResidencyClock,
        retention: Duration,
        hotLimit: Int = TabResidencyBudget.pad.hotLimit,
        hotWindow: Duration = TabResidencyBudget.pad.hotWindow,
        tabLimit: Int = TabResidencyBudget.pad.tabLimit,
        byteBudget: Int = TabResidencyBudget.pad.byteBudget,
        automaticMaintenance: Bool = true
    ) {
        self.init(
            clock: clock,
            budget: TabResidencyBudget(
                hotLimit: hotLimit,
                hotWindow: hotWindow,
                retention: retention,
                tabLimit: tabLimit,
                byteBudget: byteBudget,
                pressureTabLimit: TabResidencyBudget.pad.pressureTabLimit,
                pressureByteBudget: TabResidencyBudget.pad.pressureByteBudget),
            automaticMaintenance: automaticMaintenance)
    }

    deinit {
        // `deinit` is nonisolated, so only the two handles that are safe to
        // touch from anywhere get cleaned up here. Cancelling the Task stops the
        // sweep loop; `removeObserver` is nonisolated-safe and is what makes a
        // discarded manager (one per test) stop hearing memory warnings. The
        // residents themselves are released by
        // ARC as `entries` tears down. That is enough: `releaseResidency()` has
        // nothing to flush that is not already persisted — annotations
        // round-trip on every edit, page text is flushed detached by
        // `PageTextPersister` and awaited by the quit path, and `last_page` is
        // written on tab switch and again at quit.
        sweepTask?.cancel()
        if let memoryWarningObserver {
            NotificationCenter.default.removeObserver(memoryWarningObserver)
        }
    }

    // MARK: - Store / fetch

    /// Make `resource` resident for `tabId`. Replacing an existing resource for
    /// the same tab releases the old one — there is never a moment where two
    /// live `WKWebView`s claim the same tab.
    ///
    /// Call this when the tab actually acquires native state (i.e. when it is
    /// first shown), not when its runtime object is created: `PaneView_iOS` creates
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
        refreshTiers()
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
        // The switch reorders the hot set — the incoming tab is now the most
        // recent, and whatever fell off the end of the 5 must stop rendering.
        refreshTiers()
    }

    /// Drop a pane's pin when the pane itself goes away (collapsed by a split
    /// close, or absorbed by View ▸ Merge Panes). Without this, a discarded
    /// pane's last active tab would stay pinned forever.
    func forgetOwner(_ owner: ObjectIdentifier) {
        guard let tabId = activeTabByOwner.removeValue(forKey: owner) else { return }
        stamp(tabId)
        refreshTiers()
    }

    private func stamp(_ tabId: String) {
        entries[tabId]?.lastActive = clock.now
    }

    // MARK: - Release

    /// Immediate, unconditional release of everything a tab owns. This is the
    /// close-tab path: retention is about tabs that are still *open*, so closing
    /// one gives its memory back straight away rather than a `retentionWindow`
    /// later.
    func release(tabId: String) {
        entries.removeValue(forKey: tabId)?.resource.releaseResidency()
        // A hot slot just came free; whichever warm tab is next in line can be
        // promoted back into it and start rendering again.
        refreshTiers()
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
    /// far past the ceilings it went. The windows themselves are left to the
    /// sweeper — nothing can newly cross `hotWindow` or `retentionWindow` as a
    /// result of a store.
    @discardableResult
    func enforceCeilings() -> [String] {
        evict(tabLimit: tabLimit, byteBudget: byteBudget, expireIdle: false)
    }

    /// Run `enforceCeilings` on the next main-actor turn rather than inline.
    ///
    /// `store` is reachable from a SwiftUI `body` — `PaneView_iOS` resolves a tab's
    /// runtime there — and eviction mutates `@Observable` state on the resources
    /// it releases (`LiveTabRuntime.isEvicted`, `WebViewerController_iOS.initCount`),
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
            // `.warning` (which iPadOS can raise routinely) would effectively delete
            // the feature on a busy machine.
            return evict(
                tabLimit: budget.pressureTabLimit,
                byteBudget: budget.pressureByteBudget,
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

        // Pass 3 — retier whatever is left. This is where the 10-minute
        // demotion actually happens: a tab that outlived `hotWindow`, or that
        // has been pushed out of the 5 most recent, stops being rendered.
        refreshTiers()

        stopSweeperIfIdle()
        return evicted
    }

    // MARK: - Tiering

    /// The tabs that should currently be mounted and rendered: every pinned tab,
    /// plus the `hotLimit` most recently active tabs that are still inside
    /// `hotWindow`.
    var hotTabIds: Set<String> {
        let pinned = Set(activeTabByOwner.values)
        let now = clock.now
        // A pinned tab spends one of the 5 slots — the owner asked for "the
        // previous 5 tabs", and in a single-pane window that reads as the one
        // you are on plus four behind it, not five *behind* the one you are on.
        // But a pinned tab can never be *displaced* by the limit: the union
        // below puts every pane's visible document back regardless. So a
        // three-way split still renders all three visible documents even though
        // that leaves only two slots for recents, and a window with more panes
        // than `hotLimit` renders all of them and no recents.
        let slots = max(0, hotLimit - pinned.intersection(entries.keys).count)
        let recent = entries
            // A tab past the hot window is not a candidate however few tabs are
            // open — "for 10 minutes" is a ceiling, not a quota to fill.
            .filter { !pinned.contains($0.key) && now - $0.value.lastActive < hot }
            .sorted { $0.value.lastActive > $1.value.lastActive }
            .prefix(slots)
            .map(\.key)
        return pinned.union(recent)
    }

    /// Push the current tier down to every resident resource. Cheap and
    /// idempotent — conformers ignore a no-op transition — so it is safe to call
    /// from every mutation rather than trying to work out which tabs moved.
    private func refreshTiers() {
        let hotIds = hotTabIds
        for (tabId, entry) in entries {
            entry.resource.applyResidencyTier(hotIds.contains(tabId) ? .hot : .warm)
        }
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

    /// iOS has one memory signal, `UIApplication.didReceiveMemoryWarningNotification`,
    /// and no severity on it — unlike Dispatch's memory-pressure source, which
    /// macOS raises at `.warning` routinely and `.critical` rarely.
    ///
    /// Treating every warning as `.critical` would delete the warm tier on a
    /// device that raises one warning an hour; treating every warning as
    /// `.warning` ignores that on iPadOS the next step after a warning is
    /// jetsam, not swap. So: the first warning applies the tight ceilings, and a
    /// second one inside `pressureEscalationWindow` escalates to `.critical`.
    /// Driven off the injected clock, so a test can prove both branches without
    /// waiting a minute.
    @discardableResult
    func noteMemoryWarning() -> [String] {
        let now = clock.now
        let escalate = lastMemoryWarning.map { now - $0 < Self.pressureEscalationWindow } ?? false
        lastMemoryWarning = now
        return handleMemoryPressure(escalate ? .critical : .warning)
    }

    private func installMemoryWarningObserver() {
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            // Deliberately a hop rather than `MainActor.assumeIsolated`: the
            // notification is posted on the main thread today, but nothing in
            // the API contract guarantees the observer's queue, and an eviction
            // mutates `@Observable` state on the resources it releases.
            Task { @MainActor [weak self] in self?.noteMemoryWarning() }
        }
    }
}
#endif
