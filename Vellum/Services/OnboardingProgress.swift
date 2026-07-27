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

    /// Applies deterministic launch arguments before the app decides whether
    /// to present the tour. Reset wins when both are supplied.
    func applyLaunchArguments(_ arguments: [String]) {
        if arguments.contains(Self.resetLaunchArgument) {
            reset()
        } else if arguments.contains(Self.skipLaunchArgument) {
            complete()
        }
    }
}
