import Foundation
import Testing

@testable import Vellum

// Detection is the deliverable; the merge is deferred. What is NOT deferred is
// the promise that nothing gets silently dropped — so a losing version is
// always either handed to a resolver, archived, or still reported as
// unresolved. There is no fourth outcome.

@Suite("Coordination seam — conflict detection")
struct SyncedContainerConflictTests {
    private let records = URL(fileURLWithPath: "/vellum/records", isDirectory: true)

    private func url(_ name: String) -> URL { records.appendingPathComponent(name) }

    private static let current = ConflictVersion(
        id: "v-current", originatingDeviceName: "Ayush's Mac", isCurrent: true)
    private static let loser = ConflictVersion(
        id: "v-loser", originatingDeviceName: "Ayush's iPad", isCurrent: false)

    private struct ResolverFailure: Error {}

    /// Records what the container handed the resolver, across actor hops.
    private final class ScriptedResolver: ConflictResolver, @unchecked Sendable {
        private let lock = NSLock()
        private var events: [ConflictEvent] = []
        private var bytes: [String: Data] = [:]
        private let outcome: @Sendable (ConflictEvent) throws -> ConflictResolution

        init(outcome: @escaping @Sendable (ConflictEvent) throws -> ConflictResolution) {
            self.outcome = outcome
        }

        var seenEvents: [ConflictEvent] { lock.withLock { events } }
        var readVersions: [String: Data] { lock.withLock { bytes } }

        func resolve(
            _ event: ConflictEvent,
            reading: @Sendable (ConflictVersion) async throws -> Data
        ) async throws -> ConflictResolution {
            for version in event.losingVersions {
                let data = try await reading(version)
                lock.withLock { bytes[version.id] = data }
            }
            lock.withLock { events.append(event) }
            return try outcome(event)
        }
    }

    @Test("A conflict on a sidecar surfaces as a typed event carrying every version")
    func conflictSurfacesAsATypedEvent() async {
        let container = FakeSyncedContainer()
        var events = container.conflicts.makeAsyncIterator()
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))

        container.injectConflict(at: target, versions: [Self.current, Self.loser])

        let event = await events.next()
        #expect(event?.url == target)
        #expect(event?.versions.count == 2)
        #expect(event?.currentVersion?.id == "v-current")
        #expect(event?.losingVersions.map(\.id) == ["v-loser"])
        #expect(event?.currentVersion?.originatingDeviceName == "Ayush's Mac")
    }

    @Test("Multiple concurrent conflict versions are all reported, not just the first")
    func everyVersionIsReported() async {
        let container = FakeSyncedContainer()
        var events = container.conflicts.makeAsyncIterator()
        let target = url("a.json")
        let losers = (1...3).map { ConflictVersion(id: "v-\($0)") }
        container.seed(target, data: Data("current".utf8))

        container.injectConflict(at: target, versions: [Self.current] + losers)

        let event = await events.next()
        #expect(event?.losingVersions.map(\.id) == ["v-1", "v-2", "v-3"])
    }

    @Test("A conflict cleared externally stops being reported")
    func clearedConflictsGoQuiet() async {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(at: target, versions: [Self.current, Self.loser])
        #expect(container.deliveredConflictCount == 1)

        container.clearConflict(at: target)
        await container.suspend()
        await container.resume()

        #expect(container.deliveredConflictCount == 1)
        #expect(!container.hasUnresolvedConflict(at: target))
    }

    /// One presenter watches the whole `records/` directory via
    /// `presentedSubitem(at:didGain:)`, so N conflicting sidecars still means
    /// one registration — never one presenter per file.
    @Test("Folder-level detection reports a subitem conflict without one presenter per file")
    func oneDirectoryPresenterCoversEverySubitem() async {
        let container = FakeSyncedContainer()
        var events = container.conflicts.makeAsyncIterator()
        container.seed(url("a.json"), data: Data("a".utf8))
        container.seed(url("b.json"), data: Data("b".utf8))

        container.injectConflict(at: url("a.json"), versions: [Self.current, Self.loser])
        container.injectConflict(at: url("b.json"), versions: [Self.current, Self.loser])

        let first = await events.next()
        let second = await events.next()
        #expect(first?.url == url("a.json"))
        #expect(second?.url == url("b.json"))
        #expect(container.presenterRegistrations == 1)
    }

    @Test("The injected resolver is called with the conflicting versions and a working reader")
    func resolverGetsVersionsAndBytes() async throws {
        let resolver = ScriptedResolver { _ in .keptCurrent(archivedLosers: []) }
        let container = FakeSyncedContainer(resolver: resolver)
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(
            at: target,
            versions: [Self.current, Self.loser],
            payloads: ["v-loser": Data("losing bytes".utf8)])

        let event = ConflictEvent(url: target, detectedAt: .now, versions: [Self.current, Self.loser])
        _ = try await container.resolveConflict(event)

        #expect(resolver.seenEvents.map(\.url) == [target])
        #expect(resolver.readVersions["v-loser"] == Data("losing bytes".utf8))
    }

    @Test("A resolver returning deferred leaves the conflict unresolved and re-reported")
    func deferredKeepsTheConflict() async throws {
        let resolver = ScriptedResolver { _ in .deferred }
        let container = FakeSyncedContainer(resolver: resolver)
        var events = container.conflicts.makeAsyncIterator()
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(
            at: target, versions: [Self.current, Self.loser],
            payloads: ["v-loser": Data("losing".utf8)])
        _ = await events.next()

        let event = ConflictEvent(url: target, detectedAt: .now, versions: [Self.current, Self.loser])
        let resolution = try await container.resolveConflict(event)

        #expect(resolution == .deferred)
        #expect(container.hasUnresolvedConflict(at: target))
        await container.suspend()
        await container.resume()
        #expect(await events.next()?.url == target)
    }

    @Test("A resolver returning merged marks every losing version resolved")
    func mergedClearsTheConflict() async throws {
        let merged = url("a.json")
        let resolver = ScriptedResolver { _ in .merged(merged) }
        let container = FakeSyncedContainer(resolver: resolver)
        container.seed(merged, data: Data("current".utf8))
        container.injectConflict(
            at: merged, versions: [Self.current, Self.loser],
            payloads: ["v-loser": Data("losing".utf8)])

        let event = ConflictEvent(url: merged, detectedAt: .now, versions: [Self.current, Self.loser])
        let resolution = try await container.resolveConflict(event)

        #expect(resolution == .merged(merged))
        #expect(!container.hasUnresolvedConflict(at: merged))
    }

    @Test("The default resolver preserves losing versions instead of dropping them")
    func defaultResolverArchivesLosers() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(
            at: target, versions: [Self.current, Self.loser],
            payloads: ["v-loser": Data("losing".utf8)])

        let event = ConflictEvent(url: target, detectedAt: .now, versions: [Self.current, Self.loser])
        let resolution = try await container.resolveConflict(event)

        let archived = records.appendingPathComponent("conflicts/a.v-loser.json")
        #expect(resolution == .keptCurrent(archivedLosers: [archived]))
        #expect(container.peek(archived) == Data("losing".utf8))
        #expect(!container.hasUnresolvedConflict(at: target))
    }

    /// The deferral is asserted, not assumed: the shipping resolver keeps the
    /// current bytes verbatim and copies the loser aside verbatim. It never
    /// synthesises a third document.
    @Test("The default resolver performs no content merge")
    func defaultResolverDoesNotMerge() async throws {
        let container = FakeSyncedContainer()
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(
            at: target, versions: [Self.current, Self.loser],
            payloads: ["v-loser": Data("losing".utf8)])

        let event = ConflictEvent(url: target, detectedAt: .now, versions: [Self.current, Self.loser])
        let resolution = try await container.resolveConflict(event)

        #expect(container.peek(target) == Data("current".utf8))
        let archived = records.appendingPathComponent("conflicts/a.v-loser.json")
        #expect(container.peek(archived) == Data("losing".utf8))
        if case .merged = resolution { Issue.record("the default resolver must not merge") }
    }

    @Test("Web sidecar conflicts merge user data without importing volatile recency")
    func webSidecarConflictMergesUserData() async throws {
        let container = FakeSyncedContainer()
        let target = url("page.json")
        let pageURL = "https://example.com/article"
        var current = WebPageRecord(url: pageURL)
        current.title = "Current title"
        current.openedAt = "current-open"
        current.annotations = [Annotation(
            id: "shared", type: .note, pageNumber: 1, color: "#fde68a",
            content: "old", positionData: nil,
            createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-01T00:00:00Z")]
        var loser = WebPageRecord(url: pageURL)
        loser.saved = true
        loser.savedAt = "2026-08-02T00:00:00Z"
        loser.openedAt = "loser-open"
        loser.loadingPolicy = "snapshot-only"
        loser.annotations = [
            Annotation(
                id: "shared", type: .note, pageNumber: 1, color: "#fde68a",
                content: "new", positionData: nil,
                createdAt: "2026-08-01T00:00:00Z", updatedAt: "2026-08-03T00:00:00Z"),
            Annotation(
                id: "other", type: .highlight, pageNumber: 2, color: "#fde68a",
                content: "kept", positionData: nil,
                createdAt: "2026-08-02T00:00:00Z", updatedAt: "2026-08-02T00:00:00Z")
        ]
        container.seed(target, data: try WebLibrary.jsonEncoderPretty.encode(current))
        container.injectConflict(
            at: target,
            versions: [Self.current, Self.loser],
            payloads: ["v-loser": try WebLibrary.jsonEncoderPretty.encode(loser)])

        let event = ConflictEvent(
            url: target, detectedAt: .now, versions: [Self.current, Self.loser])
        let resolution = try await container.resolveConflict(event)
        let merged = try JSONDecoder().decode(
            WebPageRecord.self, from: #require(container.peek(target)))

        #expect(resolution == .merged(target))
        #expect(merged.saved)
        #expect(merged.savedAt == loser.savedAt)
        #expect(merged.title == current.title)
        #expect(merged.openedAt == current.openedAt)
        #expect(merged.loadingPolicy == "snapshot-only")
        #expect(merged.annotations.count == 2)
        #expect(merged.annotations.first(where: { $0.id == "shared" })?.content == "new")
    }

    @Test("Two conflicts on different files are reported as two independent events")
    func conflictsAreIndependentPerFile() async {
        let container = FakeSyncedContainer()
        var events = container.conflicts.makeAsyncIterator()
        container.seed(url("a.json"), data: Data("a".utf8))
        container.seed(url("b.json"), data: Data("b".utf8))

        container.injectConflict(at: url("a.json"), versions: [Self.current, Self.loser])
        container.injectConflict(
            at: url("b.json"), versions: [Self.current, ConflictVersion(id: "v-other")])

        let first = await events.next()
        let second = await events.next()
        #expect(first?.losingVersions.map(\.id) == ["v-loser"])
        #expect(second?.losingVersions.map(\.id) == ["v-other"])
        #expect(container.deliveredConflictCount == 2)
    }

    @Test("A resolver that throws leaves the conflict unresolved rather than losing data")
    func aThrowingResolverLosesNothing() async throws {
        let resolver = ScriptedResolver { _ in throw ResolverFailure() }
        let container = FakeSyncedContainer(resolver: resolver)
        let target = url("a.json")
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(
            at: target, versions: [Self.current, Self.loser],
            payloads: ["v-loser": Data("losing".utf8)])

        let event = ConflictEvent(url: target, detectedAt: .now, versions: [Self.current, Self.loser])
        await #expect(throws: ResolverFailure.self) {
            _ = try await container.resolveConflict(event)
        }

        #expect(container.hasUnresolvedConflict(at: target))
        #expect(container.peek(target) == Data("current".utf8))
    }
}
