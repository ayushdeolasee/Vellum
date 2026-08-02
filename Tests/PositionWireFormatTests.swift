import Foundation
import Testing

@testable import Vellum

// These files sync between devices running different builds, so the bytes are a
// contract, not an implementation detail. The byte-level test below is the
// `PdfPersistenceTests` idiom applied to a format that doesn't exist on disk
// anywhere yet — pinning it now is what makes the Mac/iPad ports mechanical.

@Suite("Position store — wire format")
struct PositionWireFormatTests {
    private let pdfKey = DocumentKey(
        rawValue: "pdf:1a0f6f4b0a9d6f3c2b1e8d7c6a5b4e3d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b")!
    private let webKey = DocumentKey(
        rawValue: "web:9c1f3a7e5b2d4c8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071")!

    /// The one line the contract documents, byte for byte.
    private let documentedBytes = Data(
        #"""
        {"device_id":"6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f","device_name":"Ayush's iPhone","device_platform":"ios","documents":{"pdf:1a0f6f4b0a9d6f3c2b1e8d7c6a5b4e3d2c1f0a9b8c7d6e5f4a3b2c1d0e9f8a7b":{"opened_at":"2026-08-02T09:12:44.100000+00:00","reading_position":{"at":"2026-08-02T09:31:02.887000+00:00","value":{"page":114,"page_count":388,"scroll_fraction":0.2617}},"title":{"at":"2026-08-02T09:12:44.100000+00:00","value":"Structure and Interpretation"}},"web:9c1f3a7e5b2d4c8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071":{"closed_at":"2026-08-02T18:40:11.002000+00:00","open_state":{"at":"2026-08-02T18:40:11.002000+00:00","value":{"is_open":false,"tab_ordinal":null}},"opened_at":"2026-08-02T18:22:04.512000+00:00","reading_position":{"at":"2026-08-02T18:39:57.331000+00:00","value":{"anchor_prefix":"the coordination layer wraps","anchor_suffix":"every container access","page":1,"scroll_fraction":0.4137,"viewport_offset":220.5}},"title":{"at":"2026-08-02T18:22:04.512000+00:00","value":"Spec #150"}}},"schema_version":1,"written_at":"2026-08-02T18:40:11.014000+00:00"}
        """#.utf8)

    private func documentedRecord() -> PositionDeviceRecord {
        PositionDeviceRecord(
            schemaVersion: 1,
            deviceID: DeviceID("6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f"),
            deviceName: "Ayush's iPhone",
            devicePlatform: "ios",
            writtenAt: PositionFixtures.date("2026-08-02T18:40:11.014000+00:00"),
            documents: [
                pdfKey: .init(
                    readingPosition: Stamped(
                        at: PositionFixtures.date("2026-08-02T09:31:02.887000+00:00"),
                        value: ReadingPosition(page: 114, pageCount: 388, scrollFraction: 0.2617)),
                    openedAt: PositionFixtures.date("2026-08-02T09:12:44.100000+00:00"),
                    title: Stamped(
                        at: PositionFixtures.date("2026-08-02T09:12:44.100000+00:00"),
                        value: "Structure and Interpretation")),
                webKey: .init(
                    readingPosition: Stamped(
                        at: PositionFixtures.date("2026-08-02T18:39:57.331000+00:00"),
                        value: ReadingPosition(
                            page: 1,
                            scrollFraction: 0.4137,
                            anchorPrefix: "the coordination layer wraps",
                            anchorSuffix: "every container access",
                            viewportOffset: 220.5)),
                    openedAt: PositionFixtures.date("2026-08-02T18:22:04.512000+00:00"),
                    closedAt: PositionFixtures.date("2026-08-02T18:40:11.002000+00:00"),
                    title: Stamped(
                        at: PositionFixtures.date("2026-08-02T18:22:04.512000+00:00"),
                        value: "Spec #150"),
                    openState: Stamped(
                        at: PositionFixtures.date("2026-08-02T18:40:11.002000+00:00"),
                        value: OpenState(isOpen: false, tabOrdinal: nil))),
            ])
    }

    @Test("A device record round-trips through encode and decode unchanged")
    func roundTrip() throws {
        let record = documentedRecord()

        let bytes = try PositionCoding.encoder.encode(record)
        let decoded = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: bytes)

        #expect(decoded == record)
        #expect(try PositionCoding.encoder.encode(decoded) == bytes)
    }

    @Test("The encoded bytes match the documented example exactly")
    func bytesMatchTheDocumentedExample() throws {
        let bytes = try PositionCoding.encoder.encode(documentedRecord())

        #expect(String(decoding: bytes, as: UTF8.self) == String(decoding: documentedBytes, as: UTF8.self))
    }

    @Test("Every written file carries schema_version and it matches the file name")
    func schemaVersionIsInTheBodyAndTheName() async throws {
        let root = PositionFixtures.scratchDirectory("position-wire")
        defer { PositionFixtures.remove(root) }
        let storage = FilePositionStorage(root: root)
        let record = documentedRecord()

        try await storage.write(record)

        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(names == ["6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f.v1.json"])
        let parsed = PositionLayout.parseFileName(names[0])
        #expect(parsed?.device == record.deviceID)
        #expect(parsed?.version == record.schemaVersion)
        let object = try JSONSerialization.jsonObject(
            with: Data(contentsOf: root.appendingPathComponent(names[0]))) as? [String: Any]
        #expect(object?["schema_version"] as? Int == PositionLayout.schemaVersion)
    }

    /// A future build adds a field; this build must carry it back out again on
    /// its next write instead of quietly deleting it.
    @Test("Unknown keys added by a future version survive decode")
    func unknownKeysSurviveDecode() throws {
        let bytes = Data(
            #"""
            {"device_id":"6f1b2a44-8c3e-4d10-9f77-1a2b3c4d5e6f","device_name":"Ayush's iPhone","device_platform":"ios","documents":{"web:9c1f3a7e5b2d4c8f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f6071":{"annotation_count":{"at":"2026-08-02T18:22:04.512000+00:00","value":7},"opened_at":"2026-08-02T18:22:04.512000+00:00"}},"reading_streak":12,"schema_version":1,"written_at":"2026-08-02T18:40:11.014000+00:00"}
            """#.utf8)

        let decoded = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: bytes)

        #expect(decoded.unknownFields["reading_streak"] == .int(12))
        #expect(decoded.documents[webKey]?.unknownFields["annotation_count"] != nil)
        #expect(decoded.documents[webKey]?.openedAt == PositionFixtures.date("2026-08-02T18:22:04.512000+00:00"))
        #expect(try PositionCoding.encoder.encode(decoded) == bytes)
    }

    @Test("Timestamps are written in the same RFC3339 shape as the webpage sidecar")
    func timestampsMatchTheSidecarShape() throws {
        let bytes = try PositionCoding.encoder.encode(documentedRecord())
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        let written = try #require(object?["written_at"] as? String)

        #expect(written == "2026-08-02T18:40:11.014000+00:00")
        #expect(WebLibrary.parseRfc3339(written) == documentedRecord().writtenAt)
        // The sidecar's own writer produces the same shape, so the two sort and
        // parse interchangeably.
        #expect(WebLibrary.parseRfc3339(WebLibrary.rfc3339Now()) != nil)
        #expect(PositionTimestamp.parse(WebLibrary.rfc3339Now()) != nil)
    }

    /// `opened_at`/`closed_at` are bare timestamps rather than `{at, value}`,
    /// because for a value that IS a time "newest stamp" and "newest value" are
    /// provably the same comparison.
    @Test("Self-stamped timestamp fields merge identically to stamped ones")
    func selfStampedFieldsMergeLikeStampedOnes() {
        let early = PositionFixtures.date("2026-08-02T09:00:00.000000+00:00")
        let late = PositionFixtures.date("2026-08-02T18:00:00.000000+00:00")
        let macRecord = PositionFixtures.record(
            .mac, writtenAt: early,
            documents: [webKey: .init(openedAt: early, title: Stamped(at: early, value: "old"))])
        let phoneRecord = PositionFixtures.record(
            .phone, writtenAt: late,
            documents: [webKey: .init(openedAt: late, title: Stamped(at: late, value: "new"))])

        let merged = PositionMerge.merge([macRecord, phoneRecord])[webKey]

        #expect(merged?.openedAt?.value == late)
        #expect(merged?.openedAt?.at == merged?.openedAt?.value)
        #expect(merged?.openedAt?.device == merged?.title?.device)
        #expect(merged?.title?.value == "new")
    }

    @Test("A device record is trimmed to its 512 most recent documents, oldest first")
    func recordIsTrimmedToItsMostRecentDocuments() {
        let base = PositionFixtures.date("2026-01-01T00:00:00.000000+00:00")
        var documents: [DocumentKey: PositionDeviceRecord.DocumentEntry] = [:]
        for index in 0..<600 {
            documents[.pdf(stableIdentifier: "doc-\(index)")] = .init(
                openedAt: base.addingTimeInterval(Double(index)))
        }
        var record = PositionFixtures.record(.phone, writtenAt: base, documents: documents)

        record.trimToMostRecent()

        #expect(record.documents.count == PositionDeviceRecord.maxDocuments)
        #expect(record.documents[.pdf(stableIdentifier: "doc-599")] != nil)
        #expect(record.documents[.pdf(stableIdentifier: "doc-88")] != nil)
        #expect(record.documents[.pdf(stableIdentifier: "doc-87")] == nil)
        #expect(record.documents[.pdf(stableIdentifier: "doc-0")] == nil)
    }
}
