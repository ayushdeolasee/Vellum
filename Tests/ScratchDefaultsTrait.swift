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
/// Only needed by suites that want their OWN domain, e.g. to assert on what a
/// write left behind. Merely keeping a test out of the real user's recents and
/// workspace needs nothing: `AppDefaults` already refuses to hand a hosted test
/// bundle `UserDefaults.standard`.
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
        defer { defaults.removePersistentDomain(forName: name) }
        try await AppDefaults.withDefaults(defaults) { try await function() }
    }
}

extension Trait where Self == ScratchDefaultsTrait {
    static var scratchDefaults: Self { Self() }
}
