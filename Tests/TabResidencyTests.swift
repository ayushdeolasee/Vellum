import Testing
@testable import Vellum

// The open-tab residency policy (issue #52, retuned by the repo owner's request
// on PR #67, then retuned again for iPad by parity #129). A tab is HOT —
// mounted and rendered — while it is among the 3 most recently used and inside
// 10 minutes; WARM — resident but not drawn — after that; and evicted entirely
// at 30 minutes idle, when a ceiling is exceeded, or when the system reports
// memory pressure.
//
// THE NUMBERS ARE NOT MAIN'S. The two WINDOWS (10 / 30 minutes) are the owner's
// request and are unchanged, but both COUNT ceilings are lower here: iPadOS
// enforces a hard per-app footprint and jetsams rather than swapping, so macOS's
// 5 hot / 8 resident / 2-under-pressure would be a crash, not a guardrail.
// `makeManager`'s `tabLimit` default is `TabResidencyManager.residentTabLimit`
// (4), and every test that counts tabs counts against `.hotTabLimit` (3),
// `.residentTabLimit` or `.pressureTabLimit` (1) rather than against a literal,
// so the next retune cannot silently turn a boundary test into a tautology.
// `theCeilingsAreTheiPadNumbersNotTheMacOnes` is the one place that does spell
// them out, which is what makes the retune itself a deliberate edit.
//
// Every test drives a `ManualResidencyClock`, so "thirty minutes later" costs
// nothing, and builds the manager with `automaticMaintenance: false` so no
// background sweeper or memory-pressure source can race the assertions —
// `sweep()` and `handleMemoryPressure(_:)` are called explicitly instead. The
// three tests that specifically care about the background machinery opt back
// in. On iOS a manager with `automaticMaintenance: true` also registers for
// `UIApplication.didReceiveMemoryWarningNotification`; that is inert in a test
// process and nothing here asserts on it — the escalation logic behind it is
// driven directly through `noteMemoryWarning()` instead.

/// Test clock: time only moves when the test moves it.
@MainActor
private final class ManualResidencyClock: ResidencyClock {
    private(set) var now: Duration = .zero

    func advance(by amount: Duration) { now += amount }
}

/// Stand-in for a tab's `LiveTabRuntime`. Records its own release so a test can
/// prove eviction actually reached the resource rather than just dropping the
/// dictionary entry.
@MainActor
private final class FakeResident: TabResidentResource {
    let residencyCostBytes: Int
    private(set) var releaseCount = 0
    /// Mirrors `LiveTabRuntime.isRendered`. Starts warm: a resource is tiered
    /// the moment it is stored, so nothing should ever observe this default.
    private(set) var tier: TabResidencyTier = .warm
    /// How many times the tier actually *changed*. The manager retiers every
    /// resident tab on every sweep, so this proves the no-op guard is honoured
    /// and a hot tab is not being re-signalled once a minute forever.
    private(set) var tierChangeCount = 0

    init(costBytes: Int = 1) { residencyCostBytes = costBytes }

    func applyResidencyTier(_ tier: TabResidencyTier) {
        guard self.tier != tier else { return }
        self.tier = tier
        tierChangeCount += 1
    }

    func releaseResidency() { releaseCount += 1 }
}

@MainActor
private func makeManager(
    clock: ManualResidencyClock,
    hotLimit: Int = TabResidencyManager.hotTabLimit,
    tabLimit: Int = TabResidencyManager.residentTabLimit,
    byteBudget: Int = Int.max
) -> TabResidencyManager {
    TabResidencyManager(
        clock: clock,
        retention: TabResidencyManager.retentionWindow,
        hotLimit: hotLimit,
        hotWindow: TabResidencyManager.hotWindow,
        tabLimit: tabLimit,
        byteBudget: byteBudget,
        automaticMaintenance: false)
}

/// The two windows from the owner's request on PR #67, so a test that exercises
/// a boundary reads as the boundary rather than as arithmetic. Unchanged on
/// iPad. There is deliberately no file-scope `hotTabLimit` twin of main's: the
/// counts are read from `TabResidencyManager` inside the test bodies instead,
/// both because a global `let` cannot initialize itself from a main-actor
/// isolated static and because a second copy of a retuned number is exactly what
/// the retune would forget to update.
private let hotWindow: Duration = .seconds(10 * 60)
private let retentionWindow: Duration = .seconds(30 * 60)

// Stand-ins for the two panes of a split window. The manager keys its
// "which tab is on screen" table by the pane's `AppStore` identity, so a test
// only needs two distinct object identities.
private final class PaneIdentity: Sendable {}
private let paneA = PaneIdentity()
private let paneB = PaneIdentity()
private let pane = ObjectIdentifier(paneA)
private let otherPane = ObjectIdentifier(paneB)

@MainActor
struct TabResidencyTests {

    // MARK: - Basic residency

    @Test func storedResourceIsRetrievable() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()

        manager.store(resource, tabId: "a")

        #expect(manager.resource(tabId: "a") === resource)
        #expect(manager.residentTabIds == ["a"])
    }

    @Test func replacingATabsResourceReleasesTheDisplacedOne() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let first = FakeResident()
        let second = FakeResident()

        manager.store(first, tabId: "a")
        manager.store(second, tabId: "a")

        #expect(first.releaseCount == 1)
        #expect(manager.resource(tabId: "a") === second)
    }

    @Test func storingTheSameResourceTwiceDoesNotReleaseIt() {
        // Re-activating a tab re-stores its existing runtime; that must refresh
        // the idle stamp, not tear the tab down.
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()

        manager.store(resource, tabId: "a")
        clock.advance(by: .seconds(60))
        manager.store(resource, tabId: "a")

        #expect(resource.releaseCount == 0)
        #expect(manager.resource(tabId: "a") === resource)
    }

    // MARK: - The retention window

    @Test func inactiveTabSurvivesUpToTheRetentionWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")
        // "a" was never the active tab of any pane, so nothing pins it.

        clock.advance(by: retentionWindow - .seconds(1))
        #expect(manager.sweep().isEmpty)
        #expect(manager.resource(tabId: "a") === resource)
        #expect(resource.releaseCount == 0)
    }

    @Test func inactiveTabIsEvictedPastTheRetentionWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")

        clock.advance(by: retentionWindow)

        #expect(manager.sweep() == ["a"])
        #expect(manager.resource(tabId: "a") == nil)
        #expect(resource.releaseCount == 1)
    }

    // MARK: - The hot tier (3 tabs / 10 minutes on iPad)

    /// The iPad retune, pinned with literals. These two numbers are the whole
    /// difference between this suite and main's, and both are load-bearing: a
    /// hot tab keeps a live `PDFView`/`WKWebView` in the window's layout and
    /// display cycle, and a resident one keeps a parsed `PDFDocument` and a web
    /// content process alive against a hard per-app footprint. Restoring
    /// macOS's 5 / 8 here is a jetsam, so it has to be a deliberate edit.
    @Test func theCeilingsAreTheiPadNumbersNotTheMacOnes() {
        #expect(TabResidencyManager.hotTabLimit == 3)
        #expect(TabResidencyManager.residentTabLimit == 4)
        // The hot set has to fit inside residency, or a tab could be asked to
        // render after it had been evicted.
        #expect(TabResidencyManager.hotTabLimit < TabResidencyManager.residentTabLimit)
        // Under pressure only the tab on screen is worth keeping.
        #expect(TabResidencyManager.pressureTabLimit == 1)
        // The windows are the owner's request on PR #67 and did NOT change.
        #expect(TabResidencyManager.hotWindow == hotWindow)
        #expect(TabResidencyManager.retentionWindow == retentionWindow)
    }

    @Test func theMostRecentlyUsedTabsUpToTheHotLimitAreRendered() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [String: FakeResident] = [:]
        for index in 0..<TabResidencyManager.hotTabLimit {
            let resource = FakeResident()
            resources["tab-\(index)"] = resource
            manager.markActive(tabId: "tab-\(index)", owner: pane)
            manager.store(resource, tabId: "tab-\(index)")
            clock.advance(by: .seconds(30))
        }

        #expect(manager.hotTabIds.count == TabResidencyManager.hotTabLimit)
        for resource in resources.values { #expect(resource.tier == .hot) }
    }

    /// Main calls this `aSixthTabDemotes…` because its hot set is 5. Named off
    /// the limit rather than off a count so the iPad retune to 3 did not leave
    /// the name lying about what the test does.
    @Test func oneTabPastTheHotLimitDemotesTheLeastRecentlyUsedOutOfTheHotSet() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [String: FakeResident] = [:]
        // One tab more than the hot set holds, half a minute apart, so every one
        // of them is inside the 10-minute window and only the SIZE of the hot
        // set can decide. `hotTabLimit + 1` is also exactly `residentTabLimit`,
        // so nothing here is close to the eviction ceiling either.
        for index in 0...TabResidencyManager.hotTabLimit {
            let resource = FakeResident()
            resources["tab-\(index)"] = resource
            manager.markActive(tabId: "tab-\(index)", owner: pane)
            manager.store(resource, tabId: "tab-\(index)")
            clock.advance(by: .seconds(30))
        }

        // "tab-0" is the oldest and is no longer pinned, so it is the one that
        // stops rendering. Everything is still resident — this is a demotion,
        // not an eviction.
        #expect(resources["tab-0"]?.tier == .warm)
        #expect(resources["tab-0"]?.releaseCount == 0)
        #expect(manager.isResident(tabId: "tab-0"))
        #expect(manager.residentTabCount == TabResidencyManager.hotTabLimit + 1)
        for index in 1...TabResidencyManager.hotTabLimit {
            #expect(resources["tab-\(index)"]?.tier == .hot)
        }
    }

    @Test func aTabStaysRenderedRightUpToTheHotWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")

        clock.advance(by: hotWindow - .seconds(1))
        manager.sweep()

        #expect(resource.tier == .hot)
        #expect(manager.hotTabIds == ["a"])
    }

    @Test func aTabStopsBeingRenderedAtTheHotWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")

        clock.advance(by: hotWindow)
        manager.sweep()

        // Stopped rendering, but everything expensive it owns is still here —
        // that is the whole point of the middle tier.
        #expect(resource.tier == .warm)
        #expect(resource.releaseCount == 0)
        #expect(manager.resource(tabId: "a") === resource)
        #expect(manager.hotTabIds.isEmpty)
    }

    @Test func aWarmTabIsStillResidentJustBeforeTheRetentionWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")

        clock.advance(by: retentionWindow - .seconds(1))

        #expect(manager.sweep().isEmpty)
        #expect(resource.tier == .warm)
        #expect(resource.releaseCount == 0)
    }

    @Test func aWarmTabIsEvictedAtTheRetentionWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")
        clock.advance(by: hotWindow)
        manager.sweep()
        #expect(resource.tier == .warm)

        clock.advance(by: retentionWindow - hotWindow)

        #expect(manager.sweep() == ["a"])
        #expect(resource.releaseCount == 1)
        #expect(manager.resource(tabId: "a") == nil)
    }

    @Test func reactivatingAWarmTabPromotesItBackToHot() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")
        clock.advance(by: hotWindow)
        manager.sweep()
        #expect(resource.tier == .warm)

        manager.markActive(tabId: "a", owner: pane)

        #expect(resource.tier == .hot)
        // Hot on store, warm at the 10-minute sweep, hot again on reactivation —
        // and nothing was released in between, so the promotion is a re-parent
        // of a live native view rather than a reload.
        #expect(resource.tierChangeCount == 3)
        #expect(resource.releaseCount == 0)
    }

    @Test func closingAHotTabPromotesTheNextWarmTabIntoTheFreedSlot() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock, hotLimit: 2)
        var resources: [String: FakeResident] = [:]
        for tabId in ["a", "b", "c"] {
            let resource = FakeResident()
            resources[tabId] = resource
            manager.store(resource, tabId: tabId)
            clock.advance(by: .seconds(30))
        }
        #expect(resources["a"]?.tier == .warm)

        manager.release(tabId: "c")

        #expect(resources["a"]?.tier == .hot)
        #expect(resources["b"]?.tier == .hot)
    }

    @Test func repeatedSweepsDoNotRetierAStableHotTab() {
        // `refreshTiers` runs on every sweep. `isRendered` is `@Observable`, so
        // a missing no-op guard would invalidate every pane once a minute for as
        // long as the app is open.
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a")
        let afterStore = resource.tierChangeCount

        for _ in 0..<5 {
            clock.advance(by: .seconds(60))
            manager.sweep()
        }

        #expect(resource.tier == .hot)
        #expect(resource.tierChangeCount == afterStore)
    }

    // MARK: - Pinning (the tab on screen)

    @Test func thePinnedTabIsExemptFromEveryTierBoundary() {
        let clock = ManualResidencyClock()
        // A hot set of zero and a full day idle: only the pin can save this tab
        // from being demoted out of the rendered tree or evicted outright.
        let manager = makeManager(clock: clock, hotLimit: 0)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a")

        clock.advance(by: .seconds(24 * 60 * 60))
        manager.sweep()

        #expect(resource.tier == .hot)
        #expect(resource.releaseCount == 0)
        #expect(manager.hotTabIds == ["a"])
    }

    @Test func everyPanesVisibleTabIsHotEvenWhenTheHotBudgetIsFull() {
        // A pinned tab spends a hot slot, but can never be displaced by the
        // limit: with room for one and two panes open, BOTH visible documents
        // still render. Otherwise a split window would stop drawing one of the
        // two documents the user is looking at.
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock, hotLimit: 1)
        let left = FakeResident()
        let right = FakeResident()
        manager.markActive(tabId: "left", owner: pane)
        manager.store(left, tabId: "left")
        manager.markActive(tabId: "right", owner: otherPane)
        manager.store(right, tabId: "right")

        #expect(manager.hotTabIds == ["left", "right"])
        #expect(left.tier == .hot)
        #expect(right.tier == .hot)
    }

    @Test func aPinnedTabSpendsOneOfTheHotSlots() {
        // "the previous N tabs" in a single-pane window means the one you are on
        // plus N-1 behind it — not N behind it. `hotLimit: 2` is a local
        // override rather than the shipped 3 so the boundary needs exactly three
        // tabs to reach, whatever the shipped number becomes.
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock, hotLimit: 2)
        let older = FakeResident()
        let recent = FakeResident()
        let visible = FakeResident()
        manager.store(older, tabId: "older")
        clock.advance(by: .seconds(30))
        manager.store(recent, tabId: "recent")
        clock.advance(by: .seconds(30))
        manager.markActive(tabId: "visible", owner: pane)
        manager.store(visible, tabId: "visible")

        #expect(manager.hotTabIds == ["visible", "recent"])
        #expect(older.tier == .warm)
        #expect(older.releaseCount == 0)
    }


    @Test func activeTabIsNeverEvictedHoweverLongItIsRead() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a")

        // Someone reading one long paper all day must not have it evicted out
        // from under them just because they never switched tabs.
        clock.advance(by: .seconds(10 * 60 * 60))

        #expect(manager.sweep().isEmpty)
        #expect(resource.releaseCount == 0)
    }

    @Test func idleClockStartsWhenTheTabIsSwitchedAwayFrom() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let a = FakeResident()
        let b = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(a, tabId: "a")

        // An hour of reading tab "a" — well past the retention window — then
        // switch to "b".
        clock.advance(by: .seconds(60 * 60))
        manager.markActive(tabId: "b", owner: pane)
        manager.store(b, tabId: "b")

        // "a" is not immediately stale despite the clock reading an hour — its
        // 30 minutes start at the switch, not at the activation.
        #expect(manager.sweep().isEmpty)
        clock.advance(by: retentionWindow)
        #expect(manager.sweep() == ["a"])
        #expect(b.releaseCount == 0)
    }

    @Test func eachPanePinsItsOwnTabInASplitWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let left = FakeResident()
        let right = FakeResident()
        manager.markActive(tabId: "left", owner: pane)
        manager.markActive(tabId: "right", owner: otherPane)
        manager.store(left, tabId: "left")
        manager.store(right, tabId: "right")

        clock.advance(by: .seconds(24 * 60 * 60))

        #expect(manager.sweep().isEmpty)
        #expect(manager.residentTabCount == 2)
    }

    @Test func forgettingADiscardedPaneUnpinsItsTab() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a")
        clock.advance(by: .seconds(5 * 60 * 60))

        manager.forgetOwner(pane)
        // Unpinning re-stamps the tab as of now, so it gets a fresh window
        // rather than being evicted the instant its pane collapses.
        #expect(manager.sweep().isEmpty)

        clock.advance(by: retentionWindow)
        #expect(manager.sweep() == ["a"])
    }

    // MARK: - Closing a tab

    @Test func closingATabReleasesImmediately() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a")

        manager.release(tabId: "a")

        #expect(resource.releaseCount == 1)
        #expect(manager.resource(tabId: "a") == nil)
    }

    @Test func releaseAllDropsEverythingIncludingPinnedTabs() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let a = FakeResident()
        let b = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(a, tabId: "a")
        manager.store(b, tabId: "b")

        manager.releaseAll()

        #expect(a.releaseCount == 1)
        #expect(b.releaseCount == 1)
        #expect(manager.residentTabCount == 0)
    }

    // MARK: - Ceilings

    @Test func tabCeilingEvictsLeastRecentlyActiveFirst() {
        let clock = ManualResidencyClock()
        // One under the shipped ceiling, so the test needs `residentTabLimit`
        // tabs to trip it and keeps testing the ceiling rather than a literal.
        let limit = TabResidencyManager.residentTabLimit - 1
        let manager = makeManager(clock: clock, tabLimit: limit)
        var resources: [String: FakeResident] = [:]
        // Visit `limit + 1` tabs a minute apart, ending on the last.
        let tabIds = (0..<(limit + 1)).map { "tab-\($0)" }
        for tabId in tabIds {
            let resource = FakeResident()
            resources[tabId] = resource
            manager.markActive(tabId: tabId, owner: pane)
            manager.store(resource, tabId: tabId)
            clock.advance(by: .seconds(60))
        }

        // The oldest goes first, and only as far as the ceiling requires.
        #expect(manager.sweep() == [tabIds[0]])
        #expect(resources[tabIds[0]]?.releaseCount == 1)
        #expect(manager.residentTabIds == Set(tabIds.dropFirst()))
    }

    @Test func tabCeilingNeverEvictsThePinnedTab() {
        let clock = ManualResidencyClock()
        // A limit of zero: only the pin may save a tab.
        let manager = makeManager(clock: clock, tabLimit: 0)
        let a = FakeResident()
        let b = FakeResident()
        manager.store(a, tabId: "a")
        clock.advance(by: .seconds(60))
        manager.markActive(tabId: "b", owner: pane)
        manager.store(b, tabId: "b")

        manager.sweep()

        #expect(a.releaseCount == 1)
        #expect(b.releaseCount == 0)
        #expect(manager.residentTabIds == ["b"])
    }

    @Test func byteBudgetEvictsUntilItFits() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock, byteBudget: 250)
        let a = FakeResident(costBytes: 100)
        let b = FakeResident(costBytes: 100)
        let c = FakeResident(costBytes: 100)
        manager.store(a, tabId: "a")
        clock.advance(by: .seconds(60))
        manager.store(b, tabId: "b")
        clock.advance(by: .seconds(60))
        manager.store(c, tabId: "c")

        #expect(manager.residentBytes == 300)
        #expect(manager.sweep() == ["a"])
        #expect(manager.residentBytes == 200)
    }

    // MARK: - Ceilings applied at store time

    @Test func enforcingCeilingsTrimsWithoutWaitingForASweep() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock, tabLimit: 1)
        let a = FakeResident()
        let b = FakeResident()
        manager.store(a, tabId: "a")
        clock.advance(by: .seconds(60))
        manager.store(b, tabId: "b")

        #expect(manager.enforceCeilings() == ["a"])
        #expect(a.releaseCount == 1)
        #expect(manager.residentTabIds == ["b"])
    }

    @Test func enforcingCeilingsDoesNotApplyTheRetentionWindow() {
        let clock = ManualResidencyClock()
        // Room to spare (one resident against the shipped ceiling), so only the
        // retention window could evict anything — and the ceiling pass must not
        // be the thing that applies it.
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a")

        clock.advance(by: .seconds(5 * 60 * 60))

        #expect(manager.enforceCeilings().isEmpty)
        #expect(resource.releaseCount == 0)
        // The sweeper still owns the window.
        #expect(manager.sweep() == ["a"])
    }

    @Test func storingOverTheCeilingTrimsOnTheNextTurnNotTheNextSweep() async {
        let clock = ManualResidencyClock()
        // Real machinery: the point of this test is that a burst of opens is
        // bounded long before the sweeper's first 60-second tick.
        let manager = TabResidencyManager(
            clock: clock,
            retention: TabResidencyManager.retentionWindow,
            tabLimit: 1,
            byteBudget: Int.max,
            automaticMaintenance: true)
        let a = FakeResident()
        let b = FakeResident()
        manager.store(a, tabId: "a")
        clock.advance(by: .seconds(60))
        manager.store(b, tabId: "b")
        // Deliberately deferred, not inline: `store` is reachable from a SwiftUI
        // body, where releasing an `@Observable` resource would be a
        // modify-during-update hazard.
        #expect(manager.residentTabCount == 2)

        var spins = 0
        while manager.residentTabCount > 1, spins < 100 {
            await Task.yield()
            spins += 1
        }

        #expect(manager.residentTabIds == ["b"])
        #expect(a.releaseCount == 1)
        manager.releaseAll()
    }

    // MARK: - Memory pressure

    @Test func memoryPressureWarningShrinksToTheTightCeiling() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [FakeResident] = []
        for index in 0..<6 {
            let resource = FakeResident()
            resources.append(resource)
            manager.store(resource, tabId: "tab-\(index)")
            clock.advance(by: .seconds(60))
        }
        manager.markActive(tabId: "tab-5", owner: pane)

        manager.handleMemoryPressure(.warning)

        // The pinned tab plus `pressureTabLimit` warm ones survive; the rest go.
        #expect(manager.residentTabCount <= TabResidencyManager.pressureTabLimit + 1)
        #expect(manager.residentTabIds.contains("tab-5"))
        #expect(resources[0].releaseCount == 1)
    }

    /// `.warning` is raised routinely, and iPadOS raises it more freely than
    /// macOS does. Treating it like `.critical` would make the whole feature
    /// evaporate under normal load, so the most recently used tabs — as many as
    /// `pressureTabLimit` allows — must stay warm rather than going to zero.
    ///
    /// The surviving SET is asserted, not just the count: main keeps two here
    /// because macOS budgets `pressureTabLimit = 2`; the iPad budgets 1, so the
    /// survivor is the single most recent. Deriving it from the constant means
    /// the assertion still describes "the most recent ones survive" if the
    /// budget moves again.
    @Test func memoryPressureWarningKeepsAWarmSetRatherThanDroppingEverything() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let count = TabResidencyManager.pressureTabLimit + 3
        for index in 0..<count {
            manager.store(FakeResident(), tabId: "tab-\(index)")
            clock.advance(by: .seconds(60))
        }

        manager.handleMemoryPressure(.warning)

        let survivors = (count - TabResidencyManager.pressureTabLimit..<count)
            .map { "tab-\($0)" }
        #expect(manager.residentTabCount == TabResidencyManager.pressureTabLimit)
        #expect(manager.residentTabIds == Set(survivors))
        // The distinguishing half: `.critical` would have left nothing at all.
        #expect(!manager.residentTabIds.isEmpty)
    }

    @Test func criticalMemoryPressureEvictsEverythingButTheTabOnScreen() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let visible = FakeResident()
        let background = FakeResident()
        manager.markActive(tabId: "visible", owner: pane)
        manager.store(visible, tabId: "visible")
        manager.store(background, tabId: "background")

        manager.handleMemoryPressure(.critical)

        #expect(manager.residentTabIds == ["visible"])
        #expect(visible.releaseCount == 0)
        #expect(background.releaseCount == 1)
    }

    // MARK: - The iOS memory-warning seam (no macOS counterpart)

    // `handleMemoryPressure(_:)` above takes a severity. iOS does not supply
    // one: `UIApplication.didReceiveMemoryWarningNotification` is a single
    // undifferentiated signal, and the step after it is jetsam rather than swap.
    // `noteMemoryWarning()` is the mapping — first warning is `.warning`, a
    // second one inside `pressureEscalationWindow` is `.critical` — and it is
    // iPad-only code, so these three tests have no equivalent in main's suite.
    //
    // All three run WITHOUT a pinned tab on purpose. With a pane pinning a tab,
    // `pressureTabLimit == 1` means the pinned tab is the only survivor at
    // `.warning` too, so the two levels become indistinguishable; unpinned, the
    // difference is "the most recent tab survives" versus "nothing does", which
    // is exactly the distinction the escalation exists to make.

    @Test func aSingleMemoryWarningAppliesTheTightCeilingsRatherThanDroppingEverything() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [String: FakeResident] = [:]
        for tabId in ["a", "b", "c"] {
            let resource = FakeResident()
            resources[tabId] = resource
            manager.store(resource, tabId: tabId)
            clock.advance(by: .seconds(30))
        }

        let evicted = manager.noteMemoryWarning()

        // Least-recently-active first, and only down to `pressureTabLimit`.
        #expect(evicted == ["a", "b"])
        #expect(manager.residentTabIds == ["c"])
        #expect(resources["c"]?.releaseCount == 0)
    }

    @Test func aSecondMemoryWarningInsideTheEscalationWindowDropsEverythingOffScreen() {
        // The first warning did not buy enough headroom, so the second one stops
        // being polite. This is the branch that keeps a busy iPad off the jetsam
        // list.
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let survivor = FakeResident()
        manager.store(FakeResident(), tabId: "a")
        clock.advance(by: .seconds(30))
        manager.store(survivor, tabId: "b")

        #expect(manager.noteMemoryWarning() == ["a"])
        #expect(manager.residentTabIds == ["b"])

        clock.advance(by: TabResidencyManager.pressureEscalationWindow - .seconds(1))

        #expect(manager.noteMemoryWarning() == ["b"])
        #expect(manager.residentTabIds.isEmpty)
        #expect(survivor.releaseCount == 1)
    }

    @Test func aSecondMemoryWarningAfterTheEscalationWindowIsTreatedAsTheFirstAgain() {
        // A device that raises one warning every few minutes is not in trouble;
        // escalating on it would delete the warm tier outright. The window is
        // inclusive at the far end — exactly `pressureEscalationWindow` later is
        // already "a new episode".
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        manager.store(FakeResident(), tabId: "a")
        clock.advance(by: .seconds(30))
        manager.store(FakeResident(), tabId: "b")

        #expect(manager.noteMemoryWarning() == ["a"])
        #expect(manager.residentTabIds == ["b"])

        clock.advance(by: TabResidencyManager.pressureEscalationWindow)
        let reopened = FakeResident()
        manager.store(reopened, tabId: "c")

        // `.warning` again, not `.critical`: the most recent tab survives.
        #expect(manager.noteMemoryWarning() == ["b"])
        #expect(manager.residentTabIds == ["c"])
        #expect(reopened.releaseCount == 0)
    }

    // MARK: - The shared sweeper

    @Test func sweeperRunsOnlyWhileSomethingIsResident() {
        let clock = ManualResidencyClock()
        // The one test that wants the real background machinery — an idle
        // manager must not schedule a timer at all.
        let manager = TabResidencyManager(
            clock: clock,
            retention: TabResidencyManager.retentionWindow,
            tabLimit: TabResidencyManager.residentTabLimit,
            byteBudget: Int.max,
            automaticMaintenance: true)
        #expect(!manager.isSweeping)

        manager.store(FakeResident(), tabId: "a")
        #expect(manager.isSweeping)

        manager.release(tabId: "a")
        #expect(!manager.isSweeping)
    }

    @Test func sweeperStopsWhenTheLastResidentIsEvictedByTheWindow() {
        let clock = ManualResidencyClock()
        let manager = TabResidencyManager(
            clock: clock,
            retention: TabResidencyManager.retentionWindow,
            tabLimit: TabResidencyManager.residentTabLimit,
            byteBudget: Int.max,
            automaticMaintenance: true)
        manager.store(FakeResident(), tabId: "a")
        #expect(manager.isSweeping)

        clock.advance(by: .seconds(3 * 60 * 60))
        manager.sweep()

        #expect(!manager.isSweeping)
    }

    @Test func noSweeperWhenAutomaticMaintenanceIsOff() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        manager.store(FakeResident(), tabId: "a")
        #expect(!manager.isSweeping)
    }
}
