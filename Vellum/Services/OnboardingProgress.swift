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

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isComplete: Bool {
        defaults.bool(forKey: Self.completionKey)
    }

    func complete() {
        defaults.set(true, forKey: Self.completionKey)
    }

    func reset() {
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

    /// Applies deterministic launch arguments before the app decides whether
    /// to present the tour. Reset wins when both are supplied and deliberately
    /// bypasses legacy migration so an isolated UI-test launch can show it.
    func applyLaunchArguments(_ arguments: [String]) {
        if arguments.contains(Self.resetLaunchArgument) {
            reset()
        } else if arguments.contains(Self.skipLaunchArgument) {
            complete()
        } else {
            migrateExistingInstallIfNeeded()
        }
    }
}
