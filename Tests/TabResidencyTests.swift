import Testing
@testable import Vellum

// The open-tab residency policy (issue #52, retuned by the repo owner's request
// on PR #67). A tab is HOT — mounted and rendered — while it is among the 5 most
// recently used and inside 10 minutes; WARM — resident but not drawn — after
// that; and evicted entirely at 30 minutes idle, when a ceiling is exceeded, or
// when the system reports memory pressure.
//
// Every test drives a `ManualResidencyClock`, so "thirty minutes later" costs
// nothing, and builds the manager with `automaticMaintenance: false` so no
// background sweeper or memory-pressure source can race the assertions —
// `sweep()` and `handleMemoryPressure(_:)` are called explicitly instead. The
// two tests that specifically care about the background machinery opt back in.

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
    tabLimit: Int = 8,
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

/// The three numbers from the owner's request on PR #67, so a test that
/// exercises a boundary reads as the boundary rather than as arithmetic.
private let hotWindow: Duration = .seconds(10 * 60)
private let retentionWindow: Duration = .seconds(30 * 60)
private let hotTabLimit = 5

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

    // MARK: - The hot tier (5 tabs / 10 minutes)

    @Test func theMostRecentlyUsedTabsUpToTheHotLimitAreRendered() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [String: FakeResident] = [:]
        for index in 0..<hotTabLimit {
            let resource = FakeResident()
            resources["tab-\(index)"] = resource
            manager.markActive(tabId: "tab-\(index)", owner: pane)
            manager.store(resource, tabId: "tab-\(index)")
            clock.advance(by: .seconds(30))
        }

        #expect(manager.hotTabIds.count == hotTabLimit)
        for resource in resources.values { #expect(resource.tier == .hot) }
    }

    @Test func aSixthTabDemotesTheLeastRecentlyUsedOutOfTheHotSet() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [String: FakeResident] = [:]
        // Six tabs, half a minute apart, so all six are inside the 10-minute
        // window and only the size of the hot set can decide.
        for index in 0...hotTabLimit {
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
        #expect(manager.residentTabCount == hotTabLimit + 1)
        for index in 1...hotTabLimit { #expect(resources["tab-\(index)"]?.tier == .hot) }
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
        // "the previous 5 tabs" in a single-pane window means the one you are on
        // plus four behind it — not five behind it.
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
        let manager = makeManager(clock: clock, tabLimit: 2)
        var resources: [String: FakeResident] = [:]
        // Visit three tabs a minute apart, ending on "c".
        for tabId in ["a", "b", "c"] {
            let resource = FakeResident()
            resources[tabId] = resource
            manager.markActive(tabId: tabId, owner: pane)
            manager.store(resource, tabId: tabId)
            clock.advance(by: .seconds(60))
        }

        #expect(manager.sweep() == ["a"])
        #expect(resources["a"]?.releaseCount == 1)
        #expect(manager.residentTabIds == ["b", "c"])
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
        // Room to spare, so only the two-hour window could evict anything —
        // and the ceiling pass must not be the thing that applies it.
        let manager = makeManager(clock: clock, tabLimit: 8)
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

    @Test func memoryPressureWarningKeepsAWarmSetRatherThanDroppingEverything() {
        // `.warning` is raised routinely on a busy Mac. Treating it like
        // `.critical` would make the whole feature evaporate under normal load,
        // so a couple of recently used tabs must stay warm.
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        for index in 0..<4 {
            manager.store(FakeResident(), tabId: "tab-\(index)")
            clock.advance(by: .seconds(60))
        }

        manager.handleMemoryPressure(.warning)

        #expect(manager.residentTabCount == TabResidencyManager.pressureTabLimit)
        #expect(manager.residentTabIds == ["tab-2", "tab-3"])
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

    // MARK: - The shared sweeper

    @Test func sweeperRunsOnlyWhileSomethingIsResident() {
        let clock = ManualResidencyClock()
        // The one test that wants the real background machinery — an idle
        // manager must not schedule a timer at all.
        let manager = TabResidencyManager(
            clock: clock,
            retention: TabResidencyManager.retentionWindow,
            tabLimit: 8,
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
            tabLimit: 8,
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
