import Foundation
import Testing

@testable import Vellum

// `.downloaded` means "there is a local copy and it is STALE". Reading it is
// how a sync-aware app quietly serves a user yesterday's highlights. These
// tests pin that only `.current` is ever treated as ready, everywhere.

@Suite("Coordination seam — only .current is ready")
struct SyncedContainerReadinessTests {
    private let records = URL(fileURLWithPath: "/vellum/records", isDirectory: true)

    private func url(_ name: String) -> URL { records.appendingPathComponent(name) }

    @Test("Only the current status counts as ready")
    func onlyCurrentIsReady() {
        #expect(ItemReadiness.current.isReady)
        #expect(!ItemReadiness.downloaded.isReady)
        #expect(!ItemReadiness.notDownloaded.isReady)
        #expect(ItemReadiness.allCases.filter(\.isReady) == [.current])
    }

    @Test("A downloaded-but-stale item is refused by a require-current read")
    func staleLocalCopyIsRefused() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("stale".utf8), readiness: .downloaded)

        await #expect(throws: SyncedContainerError.notReady(target, .downloaded)) {
            _ = try await container.data(at: target)
        }
        #expect(container.coordinatedReadCount == 0)
    }

    @Test("A not-downloaded item is materialized on demand and then read")
    func materializesOnDemand() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("fresh".utf8), readiness: .notDownloaded)

        let data = try await container.data(at: target, materializing: .downloadIfNeeded(timeout: 5))

        #expect(data == Data("fresh".utf8))
        #expect(container.materializationCount == 1)
        let items = try await container.list(records)
        #expect(items.first?.readiness == .current)
    }

    @Test("Materialization that times out throws rather than returning stale bytes")
    func timeoutBeatsStaleBytes() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("stale".utf8), readiness: .downloaded)
        container.stallMaterialization(at: target)

        await #expect(throws: SyncedContainerError.timedOut(target)) {
            _ = try await container.data(at: target, materializing: .downloadIfNeeded(timeout: 0.1))
        }
        #expect(container.coordinatedReadCount == 0)
    }

    @Test("Listing with readyOnly filters out stale and undownloaded items")
    func readyOnlyFiltersTheRest() async throws {
        let container = FakeSyncedContainer()
        container.seed(url("current.json"), data: Data("a".utf8), readiness: .current)
        container.seed(url("stale.json"), data: Data("b".utf8), readiness: .downloaded)
        container.seed(url("absent.json"), data: Data("c".utf8), readiness: .notDownloaded)

        let ready = try await container.list(records, matching: SyncedItemFilter(readyOnly: true))

        #expect(ready.map(\.name) == ["current.json"])
    }

    @Test("Listing without readyOnly reports each item's readiness verbatim")
    func listingReportsReadinessVerbatim() async throws {
        let container = FakeSyncedContainer()
        container.seed(url("current.json"), data: Data("a".utf8), readiness: .current)
        container.seed(url("stale.json"), data: Data("b".utf8), readiness: .downloaded)
        container.seed(url("absent.json"), data: Data("c".utf8), readiness: .notDownloaded)

        let items = try await container.list(records)

        #expect(
            items.map { [$0.name: $0.readiness] } == [
                ["absent.json": .notDownloaded],
                ["current.json": .current],
                ["stale.json": .downloaded],
            ])
    }
}
