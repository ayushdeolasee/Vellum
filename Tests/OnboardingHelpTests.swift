import XCTest
@testable import Vellum

final class OnboardingHelpTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        OnboardingProgress.completionOverride = nil
        suiteName = "OnboardingHelpTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        OnboardingProgress.completionOverride = nil
        WebStorageSettings.modeOverride = nil
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

        progress.applyLaunchArguments(
            [OnboardingProgress.skipLaunchArgument],
            isIsolatedUITestLaunch: true)
        XCTAssertTrue(progress.isComplete)

        progress.applyLaunchArguments(
            [OnboardingProgress.skipLaunchArgument, OnboardingProgress.resetLaunchArgument],
            isIsolatedUITestLaunch: true)
        XCTAssertFalse(progress.isComplete, "reset must win when both arguments are present")
    }

    func testExistingWorkspaceMigratesWithoutSkippingTrueFirstLaunch() {
        let firstLaunch = OnboardingProgress(defaults: defaults)
        firstLaunch.applyLaunchArguments([], isIsolatedUITestLaunch: false)
        XCTAssertFalse(firstLaunch.isComplete)

        defaults.set("persisted workspace", forKey: WorkspaceService.storageKey)
        let existingInstall = OnboardingProgress(defaults: defaults)
        existingInstall.applyLaunchArguments([], isIsolatedUITestLaunch: false)
        XCTAssertTrue(existingInstall.isComplete)
    }

    func testResetLaunchIsLimitedToAnIsolatedUITestAndUsesAnInMemoryStorageChoice() {
        let progress = OnboardingProgress(defaults: defaults)
        progress.complete()

        let arguments = [OnboardingProgress.resetLaunchArgument]
        progress.applyLaunchArguments(arguments, isIsolatedUITestLaunch: false)
        WebStorageSettings.applyLaunchArguments(arguments, isIsolatedUITestLaunch: false)

        XCTAssertTrue(progress.isComplete, "production launch arguments must not reset onboarding")
        XCTAssertNil(WebStorageSettings.modeOverride)

        progress.applyLaunchArguments(arguments, isIsolatedUITestLaunch: true)
        WebStorageSettings.applyLaunchArguments(arguments, isIsolatedUITestLaunch: true)

        XCTAssertFalse(progress.isComplete)
        XCTAssertTrue(defaults.bool(forKey: OnboardingProgress.completionKey))
        XCTAssertEqual(WebStorageSettings.modeOverride, .local)
        XCTAssertEqual(WebStorageSettings.chosenMode, .local)
    }

    func testFirstLaunchPresentationRequiresAChosenStorageMode() {
        XCTAssertEqual(
            FirstLaunchPresentation.resolve(chosenMode: nil, onboardingComplete: false),
            .storageChoice)
        XCTAssertEqual(
            FirstLaunchPresentation.resolve(chosenMode: .local, onboardingComplete: false),
            .onboarding)
        XCTAssertEqual(
            FirstLaunchPresentation.resolve(chosenMode: .local, onboardingComplete: true),
            .none)
    }

    func testXCTestEnvironmentIsRequiredForTheUITestLaunchSeam() {
        XCTAssertFalse(OnboardingProgress.isIsolatedUITestLaunch(
            environment: [:]))
        XCTAssertTrue(OnboardingProgress.isIsolatedUITestLaunch(
            environment: [OnboardingProgress.xctestConfigurationEnvironmentKey: "/tmp/config.xctest"]))
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
        XCTAssertTrue(ai.points.joined().contains("By default"))
        XCTAssertTrue(ai.points.joined().contains("Tool-assisted requests"))
        XCTAssertTrue(ai.points.joined().contains("whole-document search"))
        XCTAssertTrue(ai.points.joined().contains("other pages"))
        XCTAssertTrue(ai.points.joined().contains("current-page image"))
        XCTAssertTrue(ai.points.joined().contains("not shown as a chip"))
    }
}
