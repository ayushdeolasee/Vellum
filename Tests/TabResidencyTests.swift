import Testing
@testable import Vellum

// The open-tab retention policy (issue #52): a tab's expensive resources stay
// resident for as long as the tab is open, and are only reclaimed after two
// hours of inactivity, when a ceiling is exceeded, or when the system reports
// memory pressure.
//
// Every test drives a `ManualResidencyClock`, so "two hours later" costs
// nothing, and builds the manager with `automaticMaintenance: false` so no
// background sweeper or memory-pressure source can race the assertions —
// `sweep()` and `handleMemoryPressure(_:)` are called explicitly instead.

/// Test clock: time only moves when the test moves it.
@MainActor
private final class ManualResidencyClock: ResidencyClock {
    private(set) var now: Duration = .zero

    func advance(by amount: Duration) { now += amount }
}

/// Stand-in for a parsed PDF / live web view. Records its own release so a test
/// can prove eviction actually reached the resource rather than just dropping
/// the dictionary entry.
@MainActor
private final class FakeResident: TabResidentResource {
    let residencyCostBytes: Int
    private(set) var releaseCount = 0

    init(costBytes: Int = 1) { residencyCostBytes = costBytes }

    func releaseResidency() { releaseCount += 1 }
}

@MainActor
private func makeManager(
    clock: ManualResidencyClock,
    tabLimit: Int = 8,
    byteBudget: Int = Int.max
) -> TabResidencyManager {
    TabResidencyManager(
        clock: clock,
        retention: TabResidencyManager.retentionWindow,
        tabLimit: tabLimit,
        byteBudget: byteBudget,
        automaticMaintenance: false)
}

private let pane = ObjectIdentifier(TabResidencyTests.self)
private let otherPane = ObjectIdentifier(FakeResident.self)

@MainActor
struct TabResidencyTests {

    // MARK: - Basic residency

    @Test func storedResourceIsRetrievable() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()

        manager.store(resource, tabId: "a", slot: .preparedPdf)

        #expect(manager.resource(tabId: "a", slot: .preparedPdf) === resource)
        #expect(manager.residentTabIds == ["a"])
    }

    @Test func slotsAreIndependent() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let pdf = FakeResident()
        let web = FakeResident()

        manager.store(pdf, tabId: "a", slot: .preparedPdf)
        manager.store(web, tabId: "a", slot: .webView)

        #expect(manager.resource(tabId: "a", slot: .preparedPdf) === pdf)
        #expect(manager.resource(tabId: "a", slot: .webView) === web)
        // Two slots, but still one resident *tab* as far as the ceiling cares.
        #expect(manager.residentTabCount == 1)
    }

    @Test func replacingASlotReleasesTheDisplacedResource() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let first = FakeResident()
        let second = FakeResident()

        manager.store(first, tabId: "a", slot: .webView)
        manager.store(second, tabId: "a", slot: .webView)

        #expect(first.releaseCount == 1)
        #expect(manager.resource(tabId: "a", slot: .webView) === second)
    }

    // MARK: - The retention window

    @Test func inactiveTabSurvivesUpToTheRetentionWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a", slot: .preparedPdf)
        // "a" was never the active tab of any pane, so nothing pins it.

        clock.advance(by: .seconds(2 * 60 * 60 - 1))
        #expect(manager.sweep().isEmpty)
        #expect(manager.resource(tabId: "a", slot: .preparedPdf) === resource)
        #expect(resource.releaseCount == 0)
    }

    @Test func inactiveTabIsEvictedPastTheRetentionWindow() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.store(resource, tabId: "a", slot: .preparedPdf)

        clock.advance(by: .seconds(2 * 60 * 60))

        #expect(manager.sweep() == ["a"])
        #expect(manager.resource(tabId: "a", slot: .preparedPdf) == nil)
        #expect(resource.releaseCount == 1)
    }

    @Test func evictionReleasesEverySlotTheTabOwns() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let pdf = FakeResident()
        let web = FakeResident()
        manager.store(pdf, tabId: "a", slot: .preparedPdf)
        manager.store(web, tabId: "a", slot: .webView)

        clock.advance(by: .seconds(3 * 60 * 60))
        manager.sweep()

        #expect(pdf.releaseCount == 1)
        #expect(web.releaseCount == 1)
        #expect(manager.residentTabCount == 0)
    }

    // MARK: - Pinning (the tab on screen)

    @Test func activeTabIsNeverEvictedHoweverLongItIsRead() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a", slot: .preparedPdf)

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
        manager.store(a, tabId: "a", slot: .preparedPdf)

        // Three hours of reading tab "a", then switch to "b".
        clock.advance(by: .seconds(3 * 60 * 60))
        manager.markActive(tabId: "b", owner: pane)
        manager.store(b, tabId: "b", slot: .preparedPdf)

        // "a" is not immediately stale despite the clock reading 3h — its two
        // hours start at the switch, not at the activation.
        #expect(manager.sweep().isEmpty)
        clock.advance(by: .seconds(2 * 60 * 60))
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
        manager.store(left, tabId: "left", slot: .preparedPdf)
        manager.store(right, tabId: "right", slot: .webView)

        clock.advance(by: .seconds(24 * 60 * 60))

        #expect(manager.sweep().isEmpty)
        #expect(manager.residentTabCount == 2)
    }

    @Test func forgettingADiscardedPaneUnpinsItsTab() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a", slot: .preparedPdf)
        clock.advance(by: .seconds(5 * 60 * 60))

        manager.forgetOwner(pane)
        // Unpinning re-stamps the tab as of now, so it gets a fresh window
        // rather than being evicted the instant its pane collapses.
        #expect(manager.sweep().isEmpty)

        clock.advance(by: .seconds(2 * 60 * 60))
        #expect(manager.sweep() == ["a"])
    }

    // MARK: - Closing a tab

    @Test func closingATabReleasesImmediately() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let resource = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(resource, tabId: "a", slot: .preparedPdf)

        manager.release(tabId: "a")

        #expect(resource.releaseCount == 1)
        #expect(manager.resource(tabId: "a", slot: .preparedPdf) == nil)
    }

    @Test func releaseAllDropsEverythingIncludingPinnedTabs() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let a = FakeResident()
        let b = FakeResident()
        manager.markActive(tabId: "a", owner: pane)
        manager.store(a, tabId: "a", slot: .preparedPdf)
        manager.store(b, tabId: "b", slot: .webView)

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
            manager.store(resource, tabId: tabId, slot: .preparedPdf)
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
        manager.store(a, tabId: "a", slot: .preparedPdf)
        clock.advance(by: .seconds(60))
        manager.markActive(tabId: "b", owner: pane)
        manager.store(b, tabId: "b", slot: .preparedPdf)

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
        manager.store(a, tabId: "a", slot: .preparedPdf)
        clock.advance(by: .seconds(60))
        manager.store(b, tabId: "b", slot: .preparedPdf)
        clock.advance(by: .seconds(60))
        manager.store(c, tabId: "c", slot: .preparedPdf)

        #expect(manager.residentBytes == 300)
        #expect(manager.sweep() == ["a"])
        #expect(manager.residentBytes == 200)
    }

    // MARK: - Memory pressure

    @Test func memoryPressureWarningShrinksToTheTightCeiling() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        var resources: [FakeResident] = []
        for index in 0..<6 {
            let resource = FakeResident()
            resources.append(resource)
            manager.store(resource, tabId: "tab-\(index)", slot: .preparedPdf)
            clock.advance(by: .seconds(60))
        }
        manager.markActive(tabId: "tab-5", owner: pane)

        manager.handleMemoryPressure(.warning)

        // The pinned tab plus `pressureTabLimit` warm ones survive; the rest go.
        #expect(manager.residentTabCount <= TabResidencyManager.pressureTabLimit + 1)
        #expect(manager.residentTabIds.contains("tab-5"))
        #expect(resources[0].releaseCount == 1)
    }

    @Test func criticalMemoryPressureEvictsEverythingButTheTabOnScreen() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        let visible = FakeResident()
        let background = FakeResident()
        manager.markActive(tabId: "visible", owner: pane)
        manager.store(visible, tabId: "visible", slot: .preparedPdf)
        manager.store(background, tabId: "background", slot: .webView)

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

        manager.store(FakeResident(), tabId: "a", slot: .preparedPdf)
        #expect(manager.isSweeping)

        manager.release(tabId: "a")
        #expect(!manager.isSweeping)
    }

    @Test func noSweeperWhenAutomaticMaintenanceIsOff() {
        let clock = ManualResidencyClock()
        let manager = makeManager(clock: clock)
        manager.store(FakeResident(), tabId: "a", slot: .preparedPdf)
        #expect(!manager.isSweeping)
    }
}
