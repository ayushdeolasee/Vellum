import Foundation

extension Notification.Name {
    /// Asks the main window to present the guided walkthrough. Posted by
    /// Help ▸ Vellum Walkthrough and by the welcome screen's help button, both
    /// of which live outside the scene that owns the sheet's presentation
    /// state. (vellum:show-walkthrough)
    static let vellumShowWalkthrough = Notification.Name("vellum.show-walkthrough")
}

/// First-run state for the guided walkthrough (issue #49).
///
/// Modeled on `StorageHousekeeping` and `WebStorageSettings` rather than an
/// `@AppStorage` property: the flag is read from three places that are not all
/// Views — the launch gate in `VellumApp`, the sheet that marks it, and the
/// tests — so a static namespace over UserDefaults keeps one definition of
/// "has the user seen this" instead of a key string repeated per call site.
enum WalkthroughSettings {
    static let seenKey = "walkthrough.seen"

    /// False until the walkthrough has been presented once. Absent-means-false
    /// is exactly what `bool(forKey:)` returns, so a fresh install needs no
    /// registered default.
    static var hasSeenWalkthrough: Bool {
        UserDefaults.standard.bool(forKey: seenKey)
    }

    /// True on a fresh install, and only until the sheet actually appears.
    static var needsFirstRun: Bool { !hasSeenWalkthrough }

    /// Record that the walkthrough has been presented.
    ///
    /// Called from the sheet's `onAppear` rather than from its Done button on
    /// purpose: once the user has seen the sheet, re-nagging them at the next
    /// launch because they closed it early is worse than letting them reopen it
    /// from the Help menu. That also makes the transition genuinely one-way.
    ///
    /// Returns `true` only for the call that actually flipped the flag, so the
    /// once-only contract is observable (and testable) instead of implied.
    @discardableResult
    static func markSeen() -> Bool {
        guard !hasSeenWalkthrough else { return false }
        UserDefaults.standard.set(true, forKey: seenKey)
        return true
    }
}
