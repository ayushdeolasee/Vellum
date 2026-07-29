import Foundation
import Testing

@testable import Vellum

/// `.scratchDefaults` — points `AppDefaults` at a throwaway `UserDefaults`
/// suite for the duration of each test, then removes it.
///
/// A trait rather than a stored property with a `deinit` (the shape this
/// replaces) because the redirect is a task-local: it is bound around the test's
/// own body and unwinds with it, so a suite finishing concurrently cannot unhook
/// it mid-test. The process-global it replaces could be, which is why both of
/// its users had to be `.serialized` — and `.serialized` only orders tests
/// within one suite, so two such suites still raced each other (#102).
///
/// Not needed merely to stay out of the real user's recents and workspace —
/// `AppDefaults` already refuses to hand a hosted test bundle
/// `UserDefaults.standard`. Reach for it when a suite wants its own domain: to
/// assert on what a write left behind, or to keep its writes from piling up in
/// the shared scratch domain alongside every unseamed suite's.
///
/// The binding unwinds as soon as the test body returns, so a write still in
/// flight at that point (a debounced `WorkspaceStore` save, say) lands in the
/// base domain and can recreate this suite after teardown. Join such work
/// before returning if a test arms any.
struct ScratchDefaultsTrait: TestTrait, SuiteTrait, TestScoping {
    /// Applies to every test in a suite it is attached to.
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let name = "vellum.scratch.\(UUID().uuidString)"
        let defaults = try #require(
            UserDefaults(suiteName: name), "could not open scratch suite \(name)")
        defer { removeSuite(defaults, named: name) }
        try await AppDefaults.withDefaults(defaults) { try await function() }
    }
}

/// Empty a scratch suite AND unlink its plist.
///
/// `removePersistentDomain` clears the contents but leaves the file behind, so
/// a per-test UUID domain leaves one plist in `~/Library/Preferences` per test
/// per run — the hand-rolled scratch classes this trait replaces had already
/// left over a thousand of them.
func removeSuite(_ defaults: UserDefaults, named name: String) {
    defaults.removePersistentDomain(forName: name)
    UserDefaults.standard.removeSuite(named: name)
    let plist = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences/\(name).plist")
    try? FileManager.default.removeItem(at: plist)
}

extension Trait where Self == ScratchDefaultsTrait {
    static var scratchDefaults: Self { Self() }
}
