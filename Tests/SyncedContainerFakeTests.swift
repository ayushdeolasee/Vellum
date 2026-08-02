import Foundation
import Testing

@testable import Vellum

// The fake is what every other suite in this module stands on, so it has to be
// held to the same discipline the real adapter is: coordinate everything,
// replace and never update in place, discover only through the query, and fail
// loudly rather than deadlock. The counters are the evidence.

@Suite("Coordination seam — the fake is a faithful stand-in")
struct SyncedContainerFakeTests {
    private let records = URL(fileURLWithPath: "/vellum/records", isDirectory: true)

    private func url(_ name: String) -> URL { records.appendingPathComponent(name) }

    @Test("Every read goes through a coordinated accessor")
    func readsAreCoordinated() async throws {
        let container = FakeSyncedContainer()
        container.seed(url("a.json"), data: Data(#"{"a":1}"#.utf8))

        let sawAccessor = try await container.read(url("a.json"), materializing: .requireCurrent) { _ in
            SyncedContainerAccessor.isInside
        }

        #expect(sawAccessor)
        #expect(container.coordinatedReadCount == 1)
        #expect(container.maxAccessorDepth == 1)
    }

    @Test("Every write is a forReplacing coordinated replace")
    func writesAreAlwaysForReplacing() async throws {
        let container = FakeSyncedContainer()
        try await container.replace(url("a.json"), with: Data("one".utf8))
        try await container.replace(url("a.json"), with: Data("two".utf8))
        container.cancelNextWrite()
        await #expect(throws: SyncedContainerError.cancelled) {
            try await container.replace(url("a.json"), with: Data("three".utf8))
        }

        // There is exactly one write path and it is always `.forReplacing`, so
        // these two can never drift — including when a write fails.
        #expect(container.coordinatedWriteCount == 3)
        #expect(container.forReplacingWriteCount == container.coordinatedWriteCount)
        #expect(container.maxAccessorDepth == 1)
    }

    @Test("Listing a directory never enumerates it or checks existence directly")
    func listingUsesTheMetadataQueryOnly() async throws {
        let container = FakeSyncedContainer()
        container.seed(url("b.json"), data: Data("b".utf8))
        container.seed(url("a.json"), data: Data("a".utf8))

        let items = try await container.list(records)

        #expect(items.map(\.name) == ["a.json", "b.json"])
        #expect(container.metadataQueryCount == 1)
        #expect(container.directoryEnumerationCount == 0)
        #expect(container.existenceCheckCount == 0)
    }

    /// `fileExists(atPath:)` is unreachable through this API: the seam ships no
    /// existence check, so "is it there?" is answered by the item appearing in
    /// a listing and by nothing else.
    @Test("Existence is answered by the listing, never by a stat")
    func existenceComesFromTheListing() async throws {
        let container = FakeSyncedContainer()
        container.seed(url("a.json"), data: Data("a".utf8))

        let present = try await container.list(records, matching: SyncedItemFilter(namePrefix: "a"))
        let absent = try await container.list(records, matching: SyncedItemFilter(namePrefix: "z"))

        #expect(present.count == 1)
        #expect(absent.isEmpty)
        #expect(container.existenceCheckCount == 0)
    }

    /// Opening a coordinated access inside another one is the documented way to
    /// deadlock an app on iCloud. The guard turns it into a thrown error, which
    /// a crash report can name and a test can assert.
    @Test("A nested coordinated access throws instead of deadlocking")
    func nestedCoordinationThrows() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("a".utf8))

        await SyncedContainerAccessor.$isInside.withValue(true) {
            await #expect(throws: SyncedContainerError.nestedCoordination(target)) {
                _ = try await container.data(at: target)
            }
            await #expect(throws: SyncedContainerError.nestedCoordination(target)) {
                try await container.replace(target, with: Data("b".utf8))
            }
        }

        #expect(container.coordinatedReadCount == 0)
        #expect(container.maxAccessorDepth == 0)
    }

    @Test("A cancelled write surfaces as cancelled, not as a hard failure")
    func cancellationIsItsOwnOutcome() async throws {
        let container = FakeSyncedContainer()
        container.cancelNextWrite()

        await #expect(throws: SyncedContainerError.cancelled) {
            try await container.replace(url("a.json"), with: Data("a".utf8))
        }

        // Retryable: the next write goes through untouched.
        try await container.replace(url("a.json"), with: Data("a".utf8))
        #expect(container.peek(url("a.json")) == Data("a".utf8))
    }

    @Test("A cancelled write leaves the destination bytes untouched")
    func cancellationDoesNotHalfWrite() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("original".utf8))
        container.cancelNextWrite()

        await #expect(throws: SyncedContainerError.cancelled) {
            try await container.replace(target, with: Data("replacement".utf8))
        }

        #expect(container.peek(target) == Data("original".utf8))
    }

    @Test("remove goes through coordination like every other mutation")
    func removalIsCoordinated() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("a".utf8))

        try await container.remove(target)

        #expect(container.coordinatedRemoveCount == 1)
        #expect(container.maxAccessorDepth == 1)
        #expect(try await container.list(records).isEmpty)
    }
}
