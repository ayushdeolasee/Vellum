import Foundation

/// The `UserDefaults` domain app-state services read and write, including the
/// recent-documents list, split-screen layout, and one-time analytics marker.
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
        _ defaults: UserDefaults,
        isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> R
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

    private static let testDomain = "com.vellum.tests.defaults.\(UUID().uuidString)"

    /// Explicit UI-test reset can only reach the isolated test domain.
    static func resetTestDomain() {
        guard TestEnvironment.storageRoot != nil else { return }
        base.removePersistentDomain(forName: testDomain)
    }

    nonisolated(unsafe) private static let base: UserDefaults = {
        guard TestEnvironment.storageRoot != nil else { return .standard }
        guard let scratch = UserDefaults(suiteName: testDomain) else {
            fatalError("Could not open isolated defaults suite")
        }
        scratch.removePersistentDomain(forName: testDomain)
        return scratch
    }()
}
