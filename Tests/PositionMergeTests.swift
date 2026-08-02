import Foundation
import Testing

@testable import Vellum

// The merge is the whole cross-device story: every device writes only its own
// file and the "one true answer" is computed at read time. These tests pin the
// two properties that make that safe — newest-wins per field, and complete
// independence from the order the files were read in.

@Suite("Position store — merge")
struct PositionMergeTests {
    private let key = PositionFixtures.webKey("https://example.com/spec-150")
    private let other = PositionFixtures.pdfKey("6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f")

    private func position(_ page: Int, scroll: Double? = nil) -> ReadingPosition {
        ReadingPosition(page: page, scrollFraction: scroll)
    }

    @Test("The newest write wins when two devices update the same field")
    func newestWriteWins() {
        let early = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let late = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        let macRecord = PositionFixtures.record(
            .mac, writtenAt: early,
            documents: [key: .init(readingPosition: Stamped(at: early, value: position(12)))])
        let phoneRecord = PositionFixtures.record(
            .phone, writtenAt: late,
            documents: [key: .init(readingPosition: Stamped(at: late, value: position(114)))])

        let merged = PositionMerge.merge([macRecord, phoneRecord])

        #expect(merged[key]?.readingPosition?.value == position(114))
        #expect(merged[key]?.readingPosition?.device == PositionFixtures.phone.stub)
    }

    @Test("Two devices updating different fields concurrently both survive the merge")
    func differentFieldsBothSurvive() {
        let early = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let late = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        // Whole-record last-writer-wins would drop the Mac's title here purely
        // because the phone's file is newer.
        let macRecord = PositionFixtures.record(
            .mac, writtenAt: early,
            documents: [key: .init(title: Stamped(at: early, value: "Spec #150"))])
        let phoneRecord = PositionFixtures.record(
            .phone, writtenAt: late,
            documents: [key: .init(readingPosition: Stamped(at: late, value: position(114)))])

        let merged = PositionMerge.merge([macRecord, phoneRecord])

        #expect(merged[key]?.title?.value == "Spec #150")
        #expect(merged[key]?.readingPosition?.value == position(114))
    }

    @Test("Equal timestamps break the tie by device id, and every device agrees")
    func equalTimestampsTieBreakByDeviceID() {
        let instant = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        let macRecord = PositionFixtures.record(
            .mac, writtenAt: instant,
            documents: [key: .init(readingPosition: Stamped(at: instant, value: position(12)))])
        let phoneRecord = PositionFixtures.record(
            .phone, writtenAt: instant,
            documents: [key: .init(readingPosition: Stamped(at: instant, value: position(114)))])

        let forwards = PositionMerge.merge([macRecord, phoneRecord])
        let backwards = PositionMerge.merge([phoneRecord, macRecord])

        #expect(PositionFixtures.phone.id > PositionFixtures.mac.id)
        #expect(forwards[key]?.readingPosition?.value == position(114))
        #expect(forwards == backwards)
    }

    @Test("Merging the same device records in any order gives the same result")
    func mergeIsOrderIndependent() {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let t1 = PositionFixtures.date("2026-08-02T12:00:00.000000+00:00")
        let t2 = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        let records = [
            PositionFixtures.record(
                .mac, writtenAt: t0,
                documents: [
                    key: .init(openedAt: t0, title: Stamped(at: t0, value: "Spec")),
                    other: .init(readingPosition: Stamped(at: t2, value: position(388))),
                ]),
            PositionFixtures.record(
                .phone, writtenAt: t1,
                documents: [key: .init(readingPosition: Stamped(at: t1, value: position(114)))]),
            PositionFixtures.record(
                .pad, writtenAt: t2,
                documents: [key: .init(openedAt: t2, title: Stamped(at: t2, value: "Spec #150"))]),
        ]

        let baseline = PositionMerge.merge(records)
        for permutation in permutations(records) {
            #expect(PositionMerge.merge(permutation) == baseline)
        }
    }

    @Test("Merging an already-merged view changes nothing")
    func mergeIsIdempotent() {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let t1 = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        let records = [
            PositionFixtures.record(
                .mac, writtenAt: t0, documents: [key: .init(openedAt: t0)]),
            PositionFixtures.record(
                .phone, writtenAt: t1,
                documents: [key: .init(readingPosition: Stamped(at: t1, value: position(114)))]),
        ]

        let once = PositionMerge.merge(records)
        let twice = PositionMerge.merge(records + records)

        #expect(once == twice)
    }

    @Test("A device record that fails to decode is skipped, not fatal")
    func corruptRecordIsSkipped() async throws {
        let root = PositionFixtures.scratchDirectory("position-merge")
        defer { PositionFixtures.remove(root) }
        let storage = FilePositionStorage(root: root)
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        try await storage.write(
            PositionFixtures.record(.mac, writtenAt: t0, documents: [key: .init(openedAt: t0)]))
        try Data("{ not json at all".utf8).write(
            to: root.appendingPathComponent(PositionLayout.fileName(for: PositionFixtures.phone.id)))

        let records = await storage.loadAll()
        let merged = PositionMerge.merge(records)

        #expect(records.count == 1)
        #expect(merged[key]?.openedAt?.device == PositionFixtures.mac.stub)
    }

    /// Downgrade safety: a build that only understands v1 must leave a v2 file
    /// exactly where and as it found it, or the first launch of an older build
    /// destroys everything the newer one wrote.
    @Test("A record whose schema_version is newer than we understand is ignored and never rewritten")
    func unknownNewerSchemaIsIgnoredAndUntouched() async throws {
        let root = PositionFixtures.scratchDirectory("position-merge")
        defer { PositionFixtures.remove(root) }
        let storage = FilePositionStorage(root: root)
        let future = root.appendingPathComponent(
            PositionLayout.fileName(for: PositionFixtures.pad.id, version: 2))
        let futureBytes = Data(
            """
            {"device_id":"\(PositionFixtures.pad.id.rawValue)","device_name":"Ayush's iPad",\
            "device_platform":"ipados","documents":{},"schema_version":2,\
            "written_at":"2026-08-02T18:40:11.014000+00:00"}
            """.utf8)
        try futureBytes.write(to: future)

        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        try await storage.write(
            PositionFixtures.record(.mac, writtenAt: t0, documents: [key: .init(openedAt: t0)]))
        let merged = PositionMerge.merge(await storage.loadAll())

        #expect(merged[key]?.openedAt?.device == PositionFixtures.mac.stub)
        #expect(try Data(contentsOf: future) == futureBytes)
    }

    @Test("A record whose file name version disagrees with its body is quarantined")
    func fileNameVersionMismatchIsQuarantined() async throws {
        let root = PositionFixtures.scratchDirectory("position-merge")
        defer { PositionFixtures.remove(root) }
        let storage = FilePositionStorage(root: root)
        let name = PositionLayout.fileName(for: PositionFixtures.pad.id, version: 2)
        try Data(
            """
            {"device_id":"\(PositionFixtures.pad.id.rawValue)","device_name":"Ayush's iPad",\
            "device_platform":"ipados","documents":{"\(key.rawValue)":\
            {"opened_at":"2026-08-02T09:00:00.000000+00:00"}},"schema_version":1,\
            "written_at":"2026-08-02T18:40:11.014000+00:00"}
            """.utf8
        ).write(to: root.appendingPathComponent(name))

        let merged = PositionMerge.merge(await storage.loadAll())

        #expect(merged.isEmpty)
        #expect(
            FileManager.default.fileExists(
                atPath: storage.quarantineDir.appendingPathComponent(name).path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path))
    }

    @Test("Recents order comes from the merged newest opened_at, never one device's file")
    func recentsOrderComesFromTheMergedView() {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let t1 = PositionFixtures.date("2026-08-02T12:00:00.000000+00:00")
        let t2 = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        // The Mac's own file says `other` is the most recent thing it opened;
        // the phone opened `key` later, so the merged answer must lead with it.
        let macRecord = PositionFixtures.record(
            .mac, writtenAt: t1,
            documents: [key: .init(openedAt: t0), other: .init(openedAt: t1)])
        let phoneRecord = PositionFixtures.record(
            .phone, writtenAt: t2, documents: [key: .init(openedAt: t2)])

        let recents = PositionMerge.recents(
            from: PositionMerge.merge([macRecord, phoneRecord]), limit: 8)

        #expect(recents.map(\.key) == [key, other])
        #expect(recents.first?.openedAt == t2)
        #expect(recents.first?.lastOpenedOn == PositionFixtures.phone.stub)
    }

    @Test("Open state is reported per device and never folded into the merged position")
    func openStateStaysPerDevice() {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let t1 = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        let macRecord = PositionFixtures.record(
            .mac, writtenAt: t0,
            documents: [
                key: .init(
                    openedAt: t0,
                    openState: Stamped(at: t0, value: OpenState(isOpen: true, tabOrdinal: 2)))
            ])
        let phoneRecord = PositionFixtures.record(
            .phone, writtenAt: t1,
            documents: [
                key: .init(
                    openedAt: t1,
                    openState: Stamped(at: t1, value: OpenState(isOpen: false, tabOrdinal: nil)))
            ])

        let merged = PositionMerge.merge([macRecord, phoneRecord])

        #expect(merged[key]?.openOn == [PositionFixtures.mac.stub])
        #expect(PositionMerge.entry(from: merged[key]!)?.openElsewhere == [PositionFixtures.mac.stub])
    }

    @Test("A single device with no peers merges to itself")
    func singleDeviceMergesToItself() {
        let t0 = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let record = PositionFixtures.record(
            .phone, writtenAt: t0,
            documents: [
                key: .init(
                    readingPosition: Stamped(at: t0, value: position(114, scroll: 0.25)),
                    openedAt: t0,
                    title: Stamped(at: t0, value: "Spec #150"))
            ])

        let merged = PositionMerge.merge([record])

        #expect(merged.count == 1)
        #expect(merged[key]?.readingPosition?.value == position(114, scroll: 0.25))
        #expect(merged[key]?.title?.value == "Spec #150")
        #expect(merged[key]?.openedAt?.value == t0)
        #expect(PositionMerge.merge([]).isEmpty)
    }

    private func permutations<T>(_ values: [T]) -> [[T]] {
        guard values.count > 1 else { return [values] }
        var result: [[T]] = []
        for index in values.indices {
            var rest = values
            let picked = rest.remove(at: index)
            for tail in permutations(rest) {
                result.append([picked] + tail)
            }
        }
        return result
    }
}
