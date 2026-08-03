import Foundation
import Testing

@testable import Vellum

// Scrolling produces events continuously; disks and iCloud do not want them.
// The policy makes the frequent path free and the disk path rare, and callers
// have no write-now API other than `flush()`, so nobody can opt out of it.

@Suite("Position store — coalescing")
struct PositionCoalescingTests {
    private let key = PositionFixtures.webKey("https://example.com/spec-150")

    private func makeStore(
        clock: ManualPositionClock,
        timer: ManualPositionTimer,
        storage: any PositionStorage,
        policy: CoalescePolicy = .default
    ) -> PositionStore {
        PositionStore(
            storage: storage,
            device: .phone,
            clock: clock,
            timer: timer,
            policy: policy)
    }

    @Test("Rapid position updates inside the quiet window collapse to a single write")
    func rapidUpdatesCollapseToOneWrite() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        for page in 1...20 {
            await store.record(.moved(ReadingPosition(page: page)), for: key)
            clock.advance(by: 0.05)
        }
        #expect(storage.writeCount == 0)
        await timer.fire()

        #expect(storage.writeCount == 1)
        let bytes = try #require(storage.lastWrittenBytes)
        let written = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: bytes)
        #expect(written.documents[key]?.readingPosition?.value.page == 20)
    }

    @Test("A continuous stream of updates still writes once the max delay elapses")
    func continuousUpdatesWriteAtTheMaxDelay() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        await store.record(.moved(ReadingPosition(page: 1)), for: key)
        for second in 1...14 {
            clock.advance(by: 1)
            await store.record(.moved(ReadingPosition(page: second + 1)), for: key)
            #expect((timer.pendingDelay ?? 0) > 0)
        }
        clock.advance(by: 1)
        await store.record(.moved(ReadingPosition(page: 16)), for: key)

        #expect(timer.pendingDelay == 0)
        await timer.fire()
        #expect(storage.writeCount == 1)
    }

    @Test("flush() writes immediately and cancels the pending timer")
    func flushWritesNowAndCancelsTheTimer() async {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        await store.record(.opened(title: "Spec #150", tabOrdinal: 0), for: key)
        #expect(timer.pendingDelay == 2.0)

        await store.flush()

        #expect(storage.writeCount == 1)
        #expect(timer.pendingDelay == nil)
        await timer.fire()
        #expect(storage.writeCount == 1)
    }

    @Test("Nothing dirty means no write at all")
    func nothingDirtyMeansNoWrite() async {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        await store.flush()
        #expect(storage.writeCount == 0)

        await store.record(.moved(ReadingPosition(page: 3)), for: key)
        await store.flush()
        await store.flush()
        await store.flush()

        #expect(storage.writeCount == 1)
    }

    /// An NTP step or a restore from backup can move the wall clock backwards.
    /// If a stamp went backwards with it, this device would lose a merge to its
    /// own past and the next read would resurrect an older position.
    @Test("A backwards clock jump still produces strictly increasing stamps")
    func backwardsClockStillProducesIncreasingStamps() async throws {
        let start = PositionFixtures.date("2026-08-02T12:00:00.000000+00:00")
        let clock = ManualPositionClock(start)
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        await store.record(.moved(ReadingPosition(page: 10)), for: key)
        await store.flush()
        let first = try stampedPosition(in: storage)

        clock.set(start.addingTimeInterval(-3600))
        await store.record(.moved(ReadingPosition(page: 11)), for: key)
        await store.flush()
        let second = try stampedPosition(in: storage)

        #expect(first.at == start)
        #expect(second.at > first.at)
        #expect(second.value.page == 11)
    }

    @Test("Two writes never land closer together than the minimum interval")
    func writesRespectTheMinimumInterval() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        // A quiet window shorter than the minimum interval, so the floor is
        // what has to raise the delay rather than the window doing it anyway.
        let policy = CoalescePolicy(quietWindow: 0.1, maxDelay: 15, minInterval: 1)
        let store = makeStore(clock: clock, timer: timer, storage: storage, policy: policy)

        await store.record(.moved(ReadingPosition(page: 1)), for: key)
        #expect(timer.pendingDelay == 0.1)
        await timer.fire()
        #expect(storage.writeCount == 1)

        clock.advance(by: 0.2)
        await store.record(.moved(ReadingPosition(page: 2)), for: key)

        let delay = try #require(timer.pendingDelay)
        #expect(abs(delay - 0.8) < 0.000_001)
        #expect(storage.writeCount == 1)
    }

    /// The bug: `performWrite` cleared `dirty`, `firstDirtyAt` and scheduled
    /// nothing BEFORE the write, so a write that threw left the store looking
    /// clean with no timer pending. The coalesced position was then never
    /// retried — the maxDelay guarantee quietly became "drop it until the user
    /// happens to scroll again", and a jetsam in between lost the page.
    @Test("A write that fails leaves the record dirty and retries it")
    func failedWriteIsRetried() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)
        storage.failNextWrite(with: PositionStorageError.io("disk full"))

        await store.record(.moved(ReadingPosition(page: 200)), for: key)
        await timer.fire()

        #expect(storage.writeCount == 0)
        // Still pending rather than silently abandoned.
        #expect(timer.pendingDelay != nil)

        await timer.fire()

        #expect(storage.writeCount == 1)
        #expect(try stampedPosition(in: storage).value.page == 200)
    }

    @Test("A flush after a failed write still gets the position onto disk")
    func flushAfterAFailedWriteStillWrites() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = InMemoryPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)
        storage.failNextWrite(with: PositionStorageError.io("disk full"))

        await store.record(.moved(ReadingPosition(page: 200)), for: key)
        await store.flush()
        #expect(storage.writeCount == 0)

        await store.flush()

        #expect(storage.writeCount == 1)
        #expect(try stampedPosition(in: storage).value.page == 200)
    }

    @Test("A flush joins an already-firing timer write instead of overlapping it")
    func flushJoinsInFlightTimerWrite() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = BlockedPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        await store.record(.moved(ReadingPosition(page: 1)), for: key)
        let timerTask = Task { await timer.fire() }
        await storage.waitForWriteStart(1)

        let flushTask = Task { await store.flush() }
        for _ in 0..<10 { await Task.yield() }

        #expect(await storage.writeStartCount == 1)
        #expect(await storage.maxConcurrentWrites == 1)

        await storage.releaseWrite(1)
        await timerTask.value
        await flushTask.value

        #expect(await storage.writeStartCount == 1)
        #expect(await storage.writtenPages == [1])
    }

    @Test("A flush writes a newer generation after joining an older timer write")
    func flushWritesNewerGenerationAfterOlderTimerWrite() async throws {
        let clock = ManualPositionClock(PositionFixtures.date("2026-08-02T09:00:00.000000+00:00"))
        let timer = ManualPositionTimer()
        let storage = BlockedPositionStorage()
        let store = makeStore(clock: clock, timer: timer, storage: storage)

        await store.record(.moved(ReadingPosition(page: 1)), for: key)
        let timerTask = Task { await timer.fire() }
        await storage.waitForWriteStart(1)

        clock.advance(by: 1)
        await store.record(.moved(ReadingPosition(page: 2)), for: key)
        let flushTask = Task { await store.flush() }
        for _ in 0..<10 { await Task.yield() }

        #expect(await storage.writeStartCount == 1)
        #expect(await storage.maxConcurrentWrites == 1)

        await storage.releaseWrite(1)
        await timerTask.value
        await flushTask.value

        #expect(await storage.writtenPages == [1, 2])
        #expect(await storage.maxConcurrentWrites == 1)
        #expect(await storage.stampedPosition(for: key)?.value.page == 2)
    }

    private func stampedPosition(in storage: InMemoryPositionStorage) throws -> Stamped<ReadingPosition> {
        let bytes = try #require(storage.lastWrittenBytes)
        let record = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: bytes)
        return try #require(record.documents[key]?.readingPosition)
    }
}

private actor BlockedPositionStorage: PositionStorage {
    private var records: [DeviceID: PositionDeviceRecord] = [:]
    private var writesStarted = 0
    private var activeWrites = 0
    private var maxActiveWrites = 0
    private var startedContinuations: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseContinuations: [Int: CheckedContinuation<Void, Never>] = [:]
    private var releasedWrites: Set<Int> = []
    private var pages: [Int] = []

    var writeStartCount: Int { writesStarted }
    var maxConcurrentWrites: Int { maxActiveWrites }
    var writtenPages: [Int] { pages }

    func waitForWriteStart(_ ordinal: Int) async {
        if writesStarted >= ordinal { return }
        await withCheckedContinuation { continuation in
            startedContinuations[ordinal, default: []].append(continuation)
        }
    }

    func releaseWrite(_ ordinal: Int) {
        releasedWrites.insert(ordinal)
        releaseContinuations.removeValue(forKey: ordinal)?.resume()
    }

    func loadAll() async -> [PositionDeviceRecord] {
        records.values.sorted { $0.deviceID < $1.deviceID }
    }

    func write(_ record: PositionDeviceRecord) async throws {
        writesStarted += 1
        let ordinal = writesStarted
        activeWrites += 1
        maxActiveWrites = max(maxActiveWrites, activeWrites)
        let started = startedContinuations.removeValue(forKey: ordinal) ?? []
        for continuation in started { continuation.resume() }
        if ordinal == 1, !releasedWrites.contains(ordinal) {
            await withCheckedContinuation { continuation in
                releaseContinuations[ordinal] = continuation
            }
        }
        if let page = record.documents.values.compactMap({ $0.readingPosition?.value.page }).max() {
            pages.append(page)
        }
        records[record.deviceID] = record
        activeWrites -= 1
    }

    func stampedPosition(for key: DocumentKey) -> Stamped<ReadingPosition>? {
        records.values.first?.documents[key]?.readingPosition
    }
}
