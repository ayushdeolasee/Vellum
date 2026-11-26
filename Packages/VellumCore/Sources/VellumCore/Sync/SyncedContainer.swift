import Foundation

// The file-coordination seam. Eight members, each one traceable to a rule the
// coordination APIs impose and that a call site would otherwise have to
// remember: coordinate every access, always replace atomically, never stat a
// ubiquitous file, never treat a stale local copy as ready, never leave a
// presenter registered into the background, never drop a conflicting version.
//
// The omissions are as load-bearing as the members:
//   * no `exists(_:)` — `fileExists(atPath:)` materializes a ubiquitous file,
//     so existence is `list(...)` returning the item and nothing else.
//   * no writing-options parameter — `.forReplacing` is the only correct option
//     for Vellum's tmp+rename pattern, so there is no way to pick wrong.
//   * no `isReady(_:)` — readiness is a property of `SyncedItem` and a
//     precondition of `read`, so "downloaded but stale" can't be read as ready.
//   * no presenter-registration API — registration happens on construction and
//     `suspend()`/`resume()` are the only lifecycle verbs.
public protocol SyncedContainer: Sendable {
    /// Coordinated read, off the caller's actor. `body` runs inside the
    /// accessor scope, so a nested coordinated access from within it throws
    /// `.nestedCoordination` instead of deadlocking.
    func read<T: Sendable>(
        _ url: URL,
        materializing: Materialization,
        _ body: @Sendable (Data) throws -> T
    ) async throws -> T

    /// The ONLY sanctioned write: always a `.forReplacing` coordinated atomic
    /// replace.
    func replace(_ url: URL, with data: Data) async throws

    /// Compare and replace inside one coordinated writing accessor. Nil means
    /// the destination must still be absent. False means no bytes were changed.
    func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool

    func remove(_ url: URL) async throws

    /// The ONLY discovery API. Backed by a metadata query, never by directory
    /// enumeration or an existence check. A returned array is a complete
    /// discovery snapshot; adapters throw while discovery is still incomplete.
    func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem]

    /// Typed detection surface. Carries no merge policy of its own.
    var conflicts: AsyncStream<ConflictEvent> { get }

    func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution

    /// Remove the presenter and stop the query. Driven by the app layer's
    /// scene-phase handling; the module observes no UIKit notification itself.
    func suspend() async
    /// Re-register, restart, and rescan for conflicts that appeared meanwhile.
    func resume() async
}

public extension SyncedContainer {
    /// Adapters without an atomic comparison cannot safely restore a copy.
    func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool {
        false
    }

    func read<T: Sendable>(_ url: URL, _ body: @Sendable (Data) throws -> T) async throws -> T {
        try await read(url, materializing: .requireCurrent, body)
    }

    func data(at url: URL, materializing: Materialization = .requireCurrent) async throws -> Data {
        try await read(url, materializing: materializing) { $0 }
    }

    func list(_ directory: URL) async throws -> [SyncedItem] {
        try await list(directory, matching: .all)
    }
}

/// The nesting guard, shared by every adapter so the fake and the real
/// container fail the same way. Apple's coordination APIs deadlock when a
/// coordinated access is opened inside another one; this turns that into a
/// thrown error that a test can assert on.
public enum SyncedContainerAccessor {
    @TaskLocal public static var isInside = false

    public static func guarded<T>(
        _ url: URL,
        isolation: isolated (any Actor)? = #isolation,
        _ body: nonisolated(nonsending) () async throws -> T
    ) async throws -> T {
        guard !isInside else { throw SyncedContainerError.nestedCoordination(url) }
        return try await $isInside.withValue(true, operation: body)
    }
}
