import Foundation

/// The `UserDefaults` domain the app-state services read and write — currently
/// `RecentFilesService` (the recent-documents list) and `WorkspaceService` (the
/// split-screen layout).
///
/// It exists to make two guarantees that a bare `UserDefaults.standard` and a
/// process-global override variable could not (#102):
///
/// 1. **A test cannot reach the real user's state, even by accident.** The unit
///    test bundle is *hosted* — it runs inside the app and therefore shares the
///    app's defaults domain. Any test that happens to open a document (which
///    records a recent) or drive a `WorkspaceStore` through a restore (which
///    saves a layout) would otherwise rewrite the developer's own recents list
///    and window layout. Under test the base domain is a private scratch suite,
///    never `.standard`, so the protection does not depend on each test
///    remembering to install a seam — the same fail-safe as `KeychainStore`'s
///    in-memory store (#97). Before this, `WorkspaceService.save` had no seam at
///    all and was kept out of real defaults only by the incidental
///    `guard didRestore` in `WorkspaceStore.scheduleSave`.
///
/// 2. **Suites cannot clobber each other's redirect.** `override` is a
///    task-local, so it unwinds with the test's own task and an unrelated suite
///    finishing at the same moment cannot unhook it. The
///    `RecentFilesService.defaultsOverride` global it replaces forced
///    `.serialized` onto both of its users, and `.serialized` only orders tests
///    *within* one suite — two such suites running concurrently still raced
///    each other's install and teardown, silently sending one suite's recents
///    writes into the other's domain or the real one.
enum AppDefaults {
    /// The domain to read and write. Never `.standard` under test.
    static var current: UserDefaults { override?.defaults ?? base }

    /// Run `operation` with app state redirected at `defaults`. Scoped, so
    /// there is no teardown to forget and nothing another suite can reset out
    /// from under this one. The binding follows the task tree, so work the
    /// operation starts with `Task { }` inherits it too.
    static func withDefaults<R>(
        _ defaults: UserDefaults, operation: () async throws -> R
    ) async rethrows -> R {
        try await $override.withValue(Box(defaults: defaults), operation: operation)
    }

    /// Per-test redirect, scoped to the task that binds it. Always nil in
    /// production; reached only through `withDefaults`.
    @TaskLocal private static var override: Box?

    /// `UserDefaults` is thread-safe, but its `Sendable` conformance is
    /// explicitly unavailable, so carrying one across isolation needs a box
    /// that vouches for it — the same reasoning as the `nonisolated(unsafe)`
    /// markers on the directory seams elsewhere in the app.
    private struct Box: @unchecked Sendable {
        let defaults: UserDefaults
    }

    /// `.standard` in production; a private scratch suite under test.
    nonisolated(unsafe) private static let base: UserDefaults = {
        guard isHostedInTestBundle else { return .standard }
        let name = "com.vellum.tests.defaults"
        guard let scratch = UserDefaults(suiteName: name) else {
            // Fail closed: silently falling back to `.standard` would hand the
            // whole test suite the real user's recents and workspace, which is
            // exactly what this type exists to prevent.
            fatalError("could not open the scratch defaults suite '\(name)'")
        }
        // Start every test process from empty. A domain that accumulated state
        // across runs would be its own source of order-dependent flakes.
        scratch.removePersistentDomain(forName: name)
        return scratch
    }()

    /// True inside a hosted XCTest bundle — the case that matters here, because
    /// such a bundle runs within the app process and shares its defaults.
    ///
    /// Deliberately NARROWER than `KeychainStore`'s equivalent, which also
    /// counts `--ui-testing` app launches. A UI-test launch runs under the
    /// `UITesting` build configuration, so it already has its own bundle
    /// identifier and therefore its own defaults domain, and its harness seeds
    /// that domain on purpose (`UITestLaunchConfiguration.prepare` writes
    /// `vellum.workspace` for the corrupt-restoration test). Redirecting it
    /// here would hide those seeds from the app under test. The keychain has no
    /// such per-configuration partition, which is why its guard is broader.
    private static let isHostedInTestBundle: Bool = {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
            || env["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }()
}
