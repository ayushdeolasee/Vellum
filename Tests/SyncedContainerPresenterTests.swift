import Foundation
import Testing

@testable import Vellum

// A file presenter left registered across a move to the background is how an
// app gets killed for deadlock prevention. The seam exposes exactly two
// lifecycle verbs and no registration API, so the only way to get this wrong is
// to forget to call them — which the app's existing scene-phase handler does at
// the same point it already flushes on backgrounding.

@Suite("Coordination seam — presenter lifecycle")
struct SyncedContainerPresenterTests {
    private let records = URL(fileURLWithPath: "/vellum/records", isDirectory: true)

    private func url(_ name: String) -> URL { records.appendingPathComponent(name) }

    private func versions(current: String = "v-current", loser: String = "v-loser") -> [ConflictVersion] {
        [
            ConflictVersion(id: current, isCurrent: true),
            ConflictVersion(id: loser, isCurrent: false),
        ]
    }

    @Test("suspend removes the presenter and stops the metadata query")
    func suspendTearsDownBoth() async {
        let container = FakeSyncedContainer()
        #expect(container.presenterRegistrations == 1)
        #expect(container.isMetadataQueryRunning)

        await container.suspend()

        #expect(container.presenterRemovals == 1)
        #expect(!container.isMetadataQueryRunning)
    }

    @Test("resume re-registers the presenter and restarts the query")
    func resumeBringsBothBack() async {
        let container = FakeSyncedContainer()
        await container.suspend()
        await container.resume()

        #expect(container.presenterRegistrations == 2)
        #expect(container.presenterRemovals == 1)
        #expect(container.isMetadataQueryRunning)
    }

    @Test("Suspending twice removes the presenter exactly once")
    func suspendIsIdempotent() async {
        let container = FakeSyncedContainer()
        await container.suspend()
        await container.suspend()

        #expect(container.presenterRemovals == 1)
        #expect(container.isSuspended)
    }

    /// No replay buffer: `resume()` re-asks the system what is unresolved,
    /// because a buffer is state that can be wrong and the version store is
    /// authoritative and cheap to re-read.
    @Test("Resuming rescans for conflicts that appeared while suspended")
    func resumeRescans() async throws {
        let container = FakeSyncedContainer()
        var events = container.conflicts.makeAsyncIterator()
        let target = url("a.json")
        container.seed(target, data: Data("a".utf8))

        await container.suspend()
        container.injectConflict(at: target, versions: versions())
        #expect(container.deliveredConflictCount == 0)

        await container.resume()

        let event = await events.next()
        #expect(event?.url == target)
        #expect(container.deliveredConflictCount == 1)
    }

    @Test("No conflict events are delivered while suspended")
    func nothingIsDeliveredWhileSuspended() async {
        let container = FakeSyncedContainer()
        container.seed(url("a.json"), data: Data("a".utf8))
        container.seed(url("b.json"), data: Data("b".utf8))

        await container.suspend()
        container.injectConflict(at: url("a.json"), versions: versions())
        container.injectConflict(at: url("b.json"), versions: versions())

        #expect(container.deliveredConflictCount == 0)
    }

    /// Discovery is the metadata query and nothing else, so a suspended
    /// container has nothing to answer with. The real adapter throws
    /// `.unavailable` here; the fake used to answer from its dictionary
    /// regardless, which certified caller code against an error path it would
    /// meet the first time a background list raced a scene-phase suspend.
    @Test("Listing while suspended is unavailable, exactly as the real container is")
    func listingWhileSuspendedIsUnavailable() async throws {
        let container = FakeSyncedContainer()
        container.seed(url("a.json"), data: Data("a".utf8))

        await container.suspend()
        await #expect(throws: SyncedContainerError.unavailable) {
            _ = try await container.list(records)
        }

        await container.resume()
        #expect(try await container.list(records).count == 1)
    }
}
