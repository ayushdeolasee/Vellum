import Foundation

/// The one durable bit of state owned by the welcome tour.
///
/// Keeping this outside the view makes first-run behavior deterministic and
/// lets UI tests opt into either side of the launch gate without touching a
/// developer's real preferences.
struct OnboardingProgress {
    static let completionKey = "vellum.onboarding.completed.v1"
    static let resetLaunchArgument = "--reset-onboarding"
    static let skipLaunchArgument = "--skip-onboarding"

    /// Xcode puts this in the launched app's environment for XCTest runs. The
    /// onboarding launch arguments are deliberately ignored outside that
    /// isolated test process so a production launch can never rewrite a
    /// person's onboarding preference.
    static let xctestConfigurationEnvironmentKey = "XCTestConfigurationFilePath"

    /// Process-local state used only after the XCTest launch check succeeds.
    /// It keeps reset/skip UI tests out of the user's real defaults domain.
    nonisolated(unsafe) static var completionOverride: Bool?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isComplete: Bool {
        Self.completionOverride ?? defaults.bool(forKey: Self.completionKey)
    }

    func complete() {
        if Self.completionOverride != nil {
            Self.completionOverride = true
            return
        }
        defaults.set(true, forKey: Self.completionKey)
    }

    func reset() {
        if Self.completionOverride != nil {
            Self.completionOverride = false
            return
        }
        defaults.removeObject(forKey: Self.completionKey)
    }

    /// Marks installations that already have a durable workspace as having
    /// completed the tour. The workspace key is only written after Vellum has
    /// restored and saved a real session, so an untouched first launch remains
    /// eligible for onboarding.
    func migrateExistingInstallIfNeeded() {
        guard defaults.object(forKey: Self.completionKey) == nil,
              defaults.object(forKey: WorkspaceService.storageKey) != nil else { return }
        complete()
    }

    /// Returns true only for a Debug app launched by XCTest. The release app
    /// never honors onboarding reset/skip arguments.
    static func isIsolatedUITestLaunch(environment: [String: String]) -> Bool {
        #if DEBUG
        environment[xctestConfigurationEnvironmentKey] != nil
        #else
        false
        #endif
    }

    /// Applies deterministic UI-test launch arguments before the app decides
    /// whether to present the tour. Reset wins when both are supplied.
    func applyLaunchArguments(_ arguments: [String], isIsolatedUITestLaunch: Bool) {
        guard isIsolatedUITestLaunch else {
            Self.completionOverride = nil
            migrateExistingInstallIfNeeded()
            return
        }
        if arguments.contains(Self.resetLaunchArgument) {
            Self.completionOverride = false
        } else if arguments.contains(Self.skipLaunchArgument) {
            Self.completionOverride = true
        } else {
            Self.completionOverride = defaults.bool(forKey: Self.completionKey)
        }
    }
}

/// The two first-launch sheets are mutually exclusive. A storage choice must
/// exist before the onboarding sheet is allowed to appear.
enum FirstLaunchPresentation: Equatable {
    case storageChoice
    case onboarding
    case none

    static func resolve(chosenMode: WebStorageMode?, onboardingComplete: Bool) -> Self {
        guard chosenMode != nil else { return .storageChoice }
        return onboardingComplete ? .none : .onboarding
    }
}
