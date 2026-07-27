import XCTest
@testable import Vellum

final class OnboardingHelpTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "OnboardingHelpTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        WebStorageSettings.needsFirstLaunchChoiceOverride = nil
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFirstRunCompletionAndReset() {
        let progress = OnboardingProgress(defaults: defaults)
        XCTAssertFalse(progress.isComplete)

        progress.complete()
        XCTAssertTrue(progress.isComplete)

        progress.reset()
        XCTAssertFalse(progress.isComplete)
    }

    func testLaunchArgumentsProvideDeterministicUITestState() {
        let progress = OnboardingProgress(defaults: defaults)

        progress.applyLaunchArguments([OnboardingProgress.skipLaunchArgument])
        XCTAssertTrue(progress.isComplete)

        progress.applyLaunchArguments([
            OnboardingProgress.skipLaunchArgument,
            OnboardingProgress.resetLaunchArgument
        ])
        XCTAssertFalse(progress.isComplete, "reset must win when both arguments are present")
    }

    func testExistingWorkspaceMigratesWithoutSkippingTrueFirstLaunch() {
        let firstLaunch = OnboardingProgress(defaults: defaults)
        firstLaunch.applyLaunchArguments([])
        XCTAssertFalse(firstLaunch.isComplete)

        defaults.set("persisted workspace", forKey: WorkspaceService.storageKey)
        let existingInstall = OnboardingProgress(defaults: defaults)
        existingInstall.applyLaunchArguments([])
        XCTAssertTrue(existingInstall.isComplete)
    }

    func testResetLaunchShowsTourWithoutPersistingAStorageChoice() {
        let progress = OnboardingProgress(defaults: defaults)
        progress.complete()
        WebStorageSettings.needsFirstLaunchChoiceOverride = true

        let arguments = [OnboardingProgress.resetLaunchArgument]
        progress.applyLaunchArguments(arguments)
        WebStorageSettings.applyLaunchArguments(arguments)

        XCTAssertFalse(progress.isComplete)
        XCTAssertFalse(WebStorageSettings.needsFirstLaunchChoice)
    }

    func testHelpSearchMatchesFeaturesConceptsAndShortcuts() {
        XCTAssertEqual(HelpTopic.search("AI privacy").map(\.id), ["ai-privacy"])
        XCTAssertEqual(HelpTopic.search("offline snapshot").map(\.id), ["web-storage"])
        XCTAssertEqual(HelpTopic.search("⌘F").map(\.id), ["find"])
        XCTAssertTrue(HelpTopic.search("definitely absent").isEmpty)
    }

    func testTourCoversEveryIssue49TopicWithoutProviderSetupGate() {
        XCTAssertEqual(OnboardingStep.all.map(\.id), [
            "open", "annotate", "ai", "storage", "navigate"
        ])
        let ai = try! XCTUnwrap(OnboardingStep.all.first { $0.id == "ai" })
        XCTAssertTrue(ai.introduction.contains("without an AI provider"))
        XCTAssertTrue(ai.note?.contains("never blocks") == true)
        XCTAssertTrue(ai.points.joined().contains("recent conversation"))
        XCTAssertTrue(ai.points.joined().contains("current-page image"))
        XCTAssertTrue(ai.points.joined().contains("not shown as a chip"))
    }
}
