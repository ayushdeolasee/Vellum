import Foundation
import Testing

@testable import Vellum

// The user-visible payoff: pick up the phone, get the page the Mac left off on.
// Every read here goes through the merged view, never through this device's own
// file, which is what makes handoff work in the direction that has no local
// history at all.

@Suite("Position store — resume handoff")
struct PositionResumeTests {
    private let spec = PositionFixtures.webKey("https://example.com/spec-150")
    private let book = PositionFixtures.pdfKey("6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f")

    private func makeStore(
        _ storage: InMemoryPositionStorage,
        device: DeviceIdentity = .phone,
        clock: ManualPositionClock
    ) -> PositionStore {
        PositionStore(
            storage: storage,
            device: device,
            clock: clock,
            timer: ManualPositionTimer(),
            policy: .default)
    }

    @Test("A phone with no local activity resumes from the Mac's position")
    func phoneResumesFromTheMac() async throws {
        let t0 = PositionFixtures.date("2026-08-02T09:12:44.100000+00:00")
        let t1 = PositionFixtures.date("2026-08-02T09:31:02.887000+00:00")
        let storage = InMemoryPositionStorage()
        storage.seed(
            PositionFixtures.record(
                .mac, writtenAt: t1,
                documents: [
                    book: .init(
                        readingPosition: Stamped(
                            at: t1, value: ReadingPosition(page: 114, pageCount: 388)),
                        openedAt: t0,
                        title: Stamped(at: t0, value: "Structure and Interpretation"))
                ]))
        let store = makeStore(storage, clock: ManualPositionClock(t1))

        let entry = try #require(await store.resume(for: book))

        #expect(entry.position?.page == 114)
        #expect(entry.title == "Structure and Interpretation")
        #expect(entry.openedAt == t0)
        #expect(entry.lastOpenedOn == PositionFixtures.mac.stub)
        #expect(storage.writeCount == 0)
    }

    @Test("Recents come from the merged view, ordered newest first, capped at the limit")
    func recentsAreMergedOrderedAndCapped() async {
        let base = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let storage = InMemoryPositionStorage()
        var macDocuments: [DocumentKey: PositionDeviceRecord.DocumentEntry] = [:]
        for index in 0..<10 {
            macDocuments[.pdf(stableIdentifier: "doc-\(index)")] = .init(
                openedAt: base.addingTimeInterval(Double(index) * 60))
        }
        storage.seed(PositionFixtures.record(.mac, writtenAt: base, documents: macDocuments))
        // The phone opened doc-0 most recently of all; the merged answer must
        // lead with it even though the Mac's own file ranks it last.
        storage.seed(
            PositionFixtures.record(
                .phone, writtenAt: base,
                documents: [
                    .pdf(stableIdentifier: "doc-0"): .init(
                        openedAt: base.addingTimeInterval(10_000))
                ]))
        let store = makeStore(storage, device: .pad, clock: ManualPositionClock(base))

        let recents = await store.recents(limit: 3)

        #expect(recents.count == 3)
        #expect(
            recents.map(\.key) == [
                .pdf(stableIdentifier: "doc-0"),
                .pdf(stableIdentifier: "doc-9"),
                .pdf(stableIdentifier: "doc-8"),
            ])
        #expect(recents.first?.lastOpenedOn == PositionFixtures.phone.stub)
        #expect(await store.recents().count == 8)
    }

    @Test("A document open on another device is reported as open elsewhere, not open here")
    func openOnAnotherDeviceIsOpenElsewhere() async throws {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let storage = InMemoryPositionStorage()
        storage.seed(
            PositionFixtures.record(
                .mac, writtenAt: t0,
                documents: [
                    spec: .init(
                        openedAt: t0,
                        openState: Stamped(at: t0, value: OpenState(isOpen: true, tabOrdinal: 1)))
                ]))
        let clock = ManualPositionClock(t0.addingTimeInterval(60))
        let store = makeStore(storage, clock: clock)

        await store.record(.opened(title: "Spec #150", tabOrdinal: 0), for: book)
        let specEntry = try #require(await store.resume(for: spec))
        let bookEntry = try #require(await store.resume(for: book))

        #expect(specEntry.openElsewhere == [PositionFixtures.mac.stub])
        #expect(bookEntry.openElsewhere.isEmpty)
        #expect(await store.openDocuments(on: PositionFixtures.phone.id) == [book])
        #expect(await store.openDocuments(on: PositionFixtures.mac.id) == [spec])
        #expect(await store.openDocuments().sorted { $0.rawValue < $1.rawValue } == [book, spec].sorted { $0.rawValue < $1.rawValue })
    }

    @Test("A fresh install with no peer records still records and resumes locally")
    func freshInstallRecordsAndResumesLocally() async throws {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let storage = InMemoryPositionStorage()
        let clock = ManualPositionClock(t0)
        let store = makeStore(storage, clock: clock)

        await store.record(.opened(title: "Spec #150", tabOrdinal: 0), for: spec)
        clock.advance(by: 30)
        await store.record(.moved(ReadingPosition(page: 4, scrollFraction: 0.41)), for: spec)
        await store.flush()

        let entry = try #require(await store.resume(for: spec))
        #expect(entry.position?.page == 4)
        #expect(entry.title == "Spec #150")
        #expect(entry.lastOpenedOn == PositionFixtures.phone.stub)
        #expect(entry.openElsewhere.isEmpty)
        #expect(await store.recents() == [entry])
        #expect(storage.writeCount == 1)
    }

    /// The bug: `hydrate()` set its "done" flag BEFORE awaiting `loadAll()`, so
    /// a read that arrived during that suspension — Home asking for recents
    /// while the first flush of the launch is still loading — sailed past it,
    /// and the merged view then substituted the not-yet-folded in-memory
    /// documents for this device's entire persisted history. "Continue reading"
    /// came back holding only what this launch had touched.
    @Test("A read that arrives mid-hydration still sees this device's stored history")
    func readDuringHydrationSeesStoredHistory() async throws {
        let t0 = PositionFixtures.date("2026-08-02T09:12:44.100000+00:00")
        let storage = GatedPositionStorage()
        storage.seed(
            PositionFixtures.record(
                .phone, writtenAt: t0,
                documents: [
                    book: .init(
                        readingPosition: Stamped(at: t0, value: ReadingPosition(page: 114)),
                        openedAt: t0,
                        title: Stamped(at: t0, value: "Structure and Interpretation"))
                ]))
        let store = PositionStore(
            storage: storage,
            device: .phone,
            clock: ManualPositionClock(t0.addingTimeInterval(60)),
            timer: ManualPositionTimer(),
            policy: .default)

        // An open event schedules a flush; the flush starts hydrating and parks
        // inside `loadAll()`.
        await store.record(.opened(title: "Spec #150", tabOrdinal: 0), for: spec)
        async let flushed: Void = store.flush()
        await storage.firstLoadStarted()

        async let observed = store.recents(limit: 8)
        // Give the reentrant read time to reach the store while the load is
        // still parked. If it arrives later instead, the assertion holds
        // anyway — hydration will simply have finished first.
        try? await Task.sleep(for: .milliseconds(100))
        storage.releaseFirstLoad()

        await flushed
        let keys = await observed.map(\.key)
        #expect(keys.contains(book))
        #expect(keys.contains(spec))
    }
}

/// Parks the FIRST `loadAll()` until the test lets it go, so a read can be made
/// to land inside the hydration suspension deterministically.
private final class GatedPositionStorage: PositionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [DeviceID: PositionDeviceRecord] = [:]
    private var loads = 0
    private var started: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    private var releasedEarly = false
    private var startedEarly = false

    func seed(_ record: PositionDeviceRecord) {
        lock.withLock { records[record.deviceID] = record }
    }

    /// Returns once the first `loadAll()` has begun.
    func firstLoadStarted() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                if startedEarly { return true }
                started = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }

    func releaseFirstLoad() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            let waiting = release
            release = nil
            if waiting == nil { releasedEarly = true }
            return waiting
        }
        waiting?.resume()
    }

    func loadAll() async -> [PositionDeviceRecord] {
        let isFirst: Bool = lock.withLock {
            loads += 1
            return loads == 1
        }
        if isFirst {
            let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
                let waiting = started
                started = nil
                if waiting == nil { startedEarly = true }
                return waiting
            }
            waiting?.resume()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    if releasedEarly { return true }
                    release = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }
        return lock.withLock { records.values.sorted { $0.deviceID < $1.deviceID } }
    }

    func write(_ record: PositionDeviceRecord) async throws {
        lock.withLock { records[record.deviceID] = record }
    }
}
