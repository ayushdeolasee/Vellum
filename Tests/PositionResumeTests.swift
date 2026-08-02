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
}
