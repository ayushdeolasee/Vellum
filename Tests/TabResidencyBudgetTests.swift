import Testing

@testable import Vellum

// The residency ceilings as DATA (#153 D5).
//
// `TabResidencyTests` proves the policy against the iPad's numbers. This suite
// proves the other half: that the numbers are a value the manager is handed
// rather than a constant it is compiled with, and that the iPhone preset behaves
// the way the phone shell needs it to.
//
// That distinction is the whole packet. One binary now serves a device with a
// generous per-app footprint and a device without one, and the failure mode of
// getting it wrong is not a slow app — it is jetsam, which the user experiences
// as Vellum vanishing mid-sentence. So "the phone holds an order of magnitude
// less than the Mac" is asserted here as arithmetic over the shipped constants,
// not left as a sentence in a comment that a later retune can silently falsify.
//
// Same idioms as `TabResidencyTests`: a hand-driven clock so "thirty minutes
// later" costs nothing, `automaticMaintenance: false` so no background sweeper
// or memory-pressure source can race an assertion, and a trivial stand-in for
// `LiveTabRuntime` so nothing here touches PDFKit or WebKit. Numbers are read
// off `TabResidencyBudget` rather than spelled out, EXCEPT in
// `thePhoneBudgetIsTheOneTheSpecAsksFor`, which is the one place a retune has to
// be a deliberate edit.

/// Test clock: time only moves when the test moves it.
@MainActor
private final class ManualClock: ResidencyClock {
    private(set) var now: Duration = .zero

    func advance(by amount: Duration) { now += amount }
}

/// Stand-in for a tab's `LiveTabRuntime`, recording its own release so a test
/// can prove eviction actually reached the resource.
@MainActor
private final class StubResident: TabResidentResource {
    let residencyCostBytes: Int
    private(set) var releaseCount = 0
    private(set) var tier: TabResidencyTier = .warm

    init(costBytes: Int = 1) { residencyCostBytes = costBytes }

    func applyResidencyTier(_ tier: TabResidencyTier) { self.tier = tier }
    func releaseResidency() { releaseCount += 1 }
}

/// Stand-in for a pane. The manager keys its pins by the pane's `AppStore`
/// identity, so a test only needs one distinct object identity.
private final class PaneIdentity: Sendable {}
private let thePane = PaneIdentity()
private let paneOwner = ObjectIdentifier(thePane)

private let megabyte = 1024 * 1024

@MainActor
struct TabResidencyBudgetTests {

    // MARK: - The numbers themselves

    /// The one place the phone's ceilings are spelled out, so changing them has
    /// to be a deliberate edit rather than a side effect. Every other test in
    /// this file derives its expectations from `TabResidencyBudget.phone`.
    @Test func thePhoneBudgetIsTheOneTheSpecAsksFor() {
        let phone = TabResidencyBudget.phone
        // Hot = the document being read plus one recent. The phone shell has
        // exactly one pane (D4), so unlike the iPad there is no second visible
        // document that has to stay rendered.
        #expect(phone.hotLimit == 2)
        #expect(phone.tabLimit == 3)
        #expect(phone.byteBudget == 64 * megabyte)
        #expect(phone.pressureTabLimit == 1)
        #expect(phone.pressureByteBudget == 24 * megabyte)
        // The hot set has to fit inside residency, or a tab could be asked to
        // render after it had been evicted.
        #expect(phone.hotLimit < phone.tabLimit)
        // Under pressure both ceilings only ever tighten.
        #expect(phone.pressureTabLimit <= phone.tabLimit)
        #expect(phone.pressureByteBudget <= phone.byteBudget)
        // The WINDOWS are the repo owner's request on PR #67 and describe how a
        // person uses tabs, not how much RAM a device has — so they are the same
        // on both presets and did not get retuned along with the ceilings.
        #expect(phone.hotWindow == TabResidencyBudget.pad.hotWindow)
        #expect(phone.retention == TabResidencyBudget.pad.retention)
    }

    /// The spec's constraint — "an order of magnitude under the Mac's" — as
    /// code. macOS budgets 768 MB; ten phones' worth of residency has to fit
    /// inside that. This is the assertion that fails first if someone "just
    /// bumps" the phone budget to make a big scanned PDF stay warm.
    @Test func thePhoneBudgetIsAnOrderOfMagnitudeUnderTheMacs() {
        let macByteBudget = 768 * megabyte
        #expect(TabResidencyBudget.phone.byteBudget * 10 <= macByteBudget)
        // And strictly tighter than the iPad's on every ceiling, since the
        // phone is the smaller device of the two this binary serves.
        #expect(TabResidencyBudget.phone.hotLimit < TabResidencyBudget.pad.hotLimit)
        #expect(TabResidencyBudget.phone.tabLimit < TabResidencyBudget.pad.tabLimit)
        #expect(TabResidencyBudget.phone.byteBudget < TabResidencyBudget.pad.byteBudget)
    }

    @Test func eachIdiomCarriesItsOwnResidencyBudget() {
        #expect(ShellIdiom_iOS.phone.residencyBudget == .phone)
        #expect(ShellIdiom_iOS.pad.residencyBudget == .pad)
    }

    /// The iPad's statics still name the iPad's preset. They are aliases now,
    /// not the source of truth, and this is what keeps `TabResidencyTests` — the
    /// suite that reads them — describing the same policy it always did.
    @Test func theManagerStaticsAreStillTheiPadPreset() {
        #expect(TabResidencyManager.hotTabLimit == TabResidencyBudget.pad.hotLimit)
        #expect(TabResidencyManager.residentTabLimit == TabResidencyBudget.pad.tabLimit)
        #expect(TabResidencyManager.residentByteBudget == TabResidencyBudget.pad.byteBudget)
        #expect(TabResidencyManager.pressureTabLimit == TabResidencyBudget.pad.pressureTabLimit)
        #expect(
            TabResidencyManager.pressureByteBudget == TabResidencyBudget.pad.pressureByteBudget)
        #expect(TabResidencyManager.hotWindow == TabResidencyBudget.pad.hotWindow)
        #expect(TabResidencyManager.retentionWindow == TabResidencyBudget.pad.retention)
        // A default-constructed manager is still an iPad one, so nothing that
        // predates the phone changed behaviour.
        #expect(TabResidencyManager(automaticMaintenance: false).budget == .pad)
    }

    // MARK: - The count ceiling

    @Test func thePhoneBudgetEvictsDownToItsResidentLimit() {
        let clock = ManualClock()
        let manager = makeManager(clock: clock, budget: .phone)
        let limit = TabResidencyBudget.phone.tabLimit
        var resources: [String: StubResident] = [:]
        // Two tabs past the ceiling, a minute apart, all well inside the
        // retention window — so only the COUNT ceiling can evict anything.
        let tabIds = (0..<(limit + 2)).map { "tab-\($0)" }
        for tabId in tabIds {
            let resource = StubResident()
            resources[tabId] = resource
            manager.store(resource, tabId: tabId)
            clock.advance(by: .seconds(60))
        }

        // Least-recently-active first, and only as far as the ceiling requires.
        #expect(manager.sweep() == [tabIds[0], tabIds[1]])
        #expect(manager.residentTabCount == limit)
        #expect(manager.residentTabIds == Set(tabIds.suffix(limit)))
        #expect(resources[tabIds[0]]?.releaseCount == 1)
    }

    // MARK: - The hot set

    /// On the phone the hot set is the document on screen plus exactly one
    /// recent — `hotLimit: 2` with a single pinned pane. That is the trade the
    /// budget makes deliberately: switching between three documents pays a warm
    /// re-parent rather than keeping a third live `PDFView` in the display cycle.
    @Test func thePhoneHotSetIsThePinnedTabPlusOneRecent() {
        let clock = ManualClock()
        let manager = makeManager(clock: clock, budget: .phone)
        let oldest = StubResident()
        let recent = StubResident()
        let onScreen = StubResident()
        manager.store(oldest, tabId: "oldest")
        clock.advance(by: .seconds(30))
        manager.store(recent, tabId: "recent")
        clock.advance(by: .seconds(30))
        manager.markActive(tabId: "on-screen", owner: paneOwner)
        manager.store(onScreen, tabId: "on-screen")

        #expect(manager.hotTabIds == ["on-screen", "recent"])
        #expect(manager.hotTabIds.count == TabResidencyBudget.phone.hotLimit)
        #expect(onScreen.tier == .hot)
        #expect(recent.tier == .hot)
        // Demoted, not evicted: still resident, still holding its parsed
        // document, just not being drawn.
        #expect(oldest.tier == .warm)
        #expect(oldest.releaseCount == 0)
        #expect(manager.isResident(tabId: "oldest"))
    }

    // MARK: - The byte ceiling

    /// Costed in the budget's own units rather than in toy integers: three tabs
    /// of 24 MB is 72 MB against the phone's 64 MB ceiling, which is roughly the
    /// real shape of the problem (a couple of scanned PDFs).
    @Test func theByteCeilingEvictsLeastRecentlyActiveFirst() {
        let clock = ManualClock()
        let manager = makeManager(clock: clock, budget: .phone)
        let a = StubResident(costBytes: 24 * megabyte)
        let b = StubResident(costBytes: 24 * megabyte)
        let c = StubResident(costBytes: 24 * megabyte)
        manager.store(a, tabId: "a")
        clock.advance(by: .seconds(60))
        manager.store(b, tabId: "b")
        clock.advance(by: .seconds(60))
        manager.store(c, tabId: "c")
        #expect(manager.residentBytes > TabResidencyBudget.phone.byteBudget)

        #expect(manager.sweep() == ["a"])

        #expect(a.releaseCount == 1)
        #expect(manager.residentTabIds == ["b", "c"])
        #expect(manager.residentBytes <= TabResidencyBudget.phone.byteBudget)
    }

    // MARK: - Memory pressure

    @Test func thePinnedTabIsNeverEvictedAtAnyPressureLevel() {
        let clock = ManualClock()
        let manager = makeManager(clock: clock, budget: .phone)
        // Deliberately over BOTH pressure ceilings at once: the pinned tab alone
        // is bigger than `pressureByteBudget`, so nothing but the pin can save
        // it. This is the tab the user is looking at — evicting it would blank
        // the reader mid-page.
        let onScreen = StubResident(costBytes: TabResidencyBudget.phone.pressureByteBudget + 1)
        let background = StubResident(costBytes: 8 * megabyte)
        manager.markActive(tabId: "on-screen", owner: paneOwner)
        manager.store(onScreen, tabId: "on-screen")
        manager.store(background, tabId: "background")

        manager.handleMemoryPressure(.warning)
        #expect(manager.residentTabIds == ["on-screen"])
        #expect(onScreen.releaseCount == 0)

        manager.handleMemoryPressure(.critical)
        #expect(manager.residentTabIds == ["on-screen"])
        #expect(onScreen.releaseCount == 0)
        #expect(onScreen.tier == .hot)
        #expect(background.releaseCount == 1)
    }

    /// iOS raises one undifferentiated warning, so the manager maps it: the
    /// first applies the tight ceilings, a second inside the escalation window
    /// says the first did not buy enough headroom and drops everything off
    /// screen. Run WITHOUT a pin on purpose — with one, `pressureTabLimit == 1`
    /// makes the pinned tab the only survivor at both levels and the two become
    /// indistinguishable.
    @Test func aSingleMemoryWarningAppliesThePhonePressureCeilings() {
        let clock = ManualClock()
        let manager = makeManager(clock: clock, budget: .phone)
        var resources: [String: StubResident] = [:]
        for tabId in ["a", "b", "c"] {
            let resource = StubResident()
            resources[tabId] = resource
            manager.store(resource, tabId: tabId)
            clock.advance(by: .seconds(30))
        }

        #expect(manager.noteMemoryWarning() == ["a", "b"])

        #expect(manager.residentTabCount == TabResidencyBudget.phone.pressureTabLimit)
        #expect(manager.residentTabIds == ["c"])
        #expect(resources["c"]?.releaseCount == 0)
    }

    @Test func aSecondMemoryWarningInsideTheWindowDropsEverythingUnpinned() {
        let clock = ManualClock()
        let manager = makeManager(clock: clock, budget: .phone)
        let survivor = StubResident()
        manager.store(StubResident(), tabId: "a")
        clock.advance(by: .seconds(30))
        manager.store(survivor, tabId: "b")

        #expect(manager.noteMemoryWarning() == ["a"])
        #expect(manager.residentTabIds == ["b"])

        clock.advance(by: TabResidencyManager.pressureEscalationWindow - .seconds(1))

        #expect(manager.noteMemoryWarning() == ["b"])
        #expect(manager.residentTabIds.isEmpty)
        #expect(survivor.releaseCount == 1)
    }

    /// The structural half of D5: the pressure ceilings are read off the
    /// INSTANCE's budget, not off the iPad statics they used to be. Discriminated
    /// with a budget whose count ceiling cannot fire, so only the byte ceiling
    /// can act — at 24 MB two of the three tabs go, where the iPad's 48 MB would
    /// have dropped just one.
    @Test func pressureCeilingsComeFromTheInjectedBudgetNotTheiPadStatics() {
        let clock = ManualClock()
        let roomyCounts = TabResidencyBudget(
            hotLimit: 2,
            hotWindow: TabResidencyBudget.phone.hotWindow,
            retention: TabResidencyBudget.phone.retention,
            tabLimit: 10,
            byteBudget: Int.max,
            pressureTabLimit: 10,
            pressureByteBudget: 24 * megabyte)
        let manager = makeManager(clock: clock, budget: roomyCounts)
        for tabId in ["a", "b", "c"] {
            manager.store(StubResident(costBytes: 20 * megabyte), tabId: tabId)
            clock.advance(by: .seconds(30))
        }

        #expect(manager.handleMemoryPressure(.warning) == ["a", "b"])
        #expect(manager.residentTabIds == ["c"])
        #expect(manager.residentBytes <= roomyCounts.pressureByteBudget)
    }

    // MARK: - Helper

    private func makeManager(
        clock: ManualClock, budget: TabResidencyBudget
    ) -> TabResidencyManager {
        TabResidencyManager(clock: clock, budget: budget, automaticMaintenance: false)
    }
}
