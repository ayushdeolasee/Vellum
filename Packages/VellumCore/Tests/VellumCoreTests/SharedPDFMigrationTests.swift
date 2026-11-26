import Foundation
import XCTest
@testable import VellumCore

final class SharedPDFMigrationTests: XCTestCase {
    private func id(_ bytes: Data) -> String? { ClassicPdfFile.currentInfoText(forKey: "VellumDocId", in: bytes) }

    func testGateUsesOriginalBytesAndTypedIdentity() throws {
        let unsigned = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
        let stamped = SharedPDFIdentity.prepare(unsigned, readID: id)
        XCTAssertGreaterThan(stamped.bytes.count, unsigned.count)
        XCTAssertTrue(stamped.bytes.starts(with: unsigned))
        XCTAssertEqual(id(stamped.bytes), stamped.key)
        XCTAssertEqual(SharedPDFIdentity.prepare(stamped.bytes, readID: id).bytes, stamped.bytes)
        for name in ["encrypted-user-pass", "digitally-signed", "xref-stream-objstm"] {
            let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL(name))
            let result = SharedPDFIdentity.prepare(original, readID: id)
            XCTAssertEqual(result.bytes, original)
            XCTAssertEqual(result.key, DocumentIdentity.byteHash(original))
        }
        let locked = SharedPDFIdentity.prepare(unsigned, writable: false, readID: id)
        XCTAssertEqual(locked.bytes, unsigned)
        XCTAssertEqual(locked.key, DocumentIdentity.byteHash(unsigned))
    }

    func testResumeAndRollbackWithoutDirectoryOwnershipInLegacyJournal() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let source = tmp.appendingPathComponent("Paper.pdf")
        let root = tmp.appendingPathComponent("shared")
        let journals = tmp.appendingPathComponent("journals")
        let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("digitally-signed"))
        try original.write(to: source)
        let migration = try SharedPDFMigration(root: root, localData: tmp.appendingPathComponent("private"), journals: journals)
        do {
            try await migration.migrate([source], readID: id) { if $0 == 1 { throw CancellationError() } }
            XCTFail("Expected interruption")
        } catch is CancellationError {}
        let manifest = journals.appendingPathComponent(DocumentIdentity.sha256Hex(root.path) + "/migration.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifest)) as? [String: Any])
        XCTAssertNotNil(json.removeValue(forKey: "createdDirectories"))
        try JSONSerialization.data(withJSONObject: json).write(to: manifest, options: .atomic)
        try await migration.migrate([], readID: id)
        let pdf = root.appendingPathComponent("PDFs/Paper.pdf")
        XCTAssertEqual(try Data(contentsOf: pdf), original)
        try await migration.rollback()
        XCTAssertFalse(fm.fileExists(atPath: pdf.path))
        XCTAssertTrue(fm.fileExists(atPath: pdf.deletingLastPathComponent().path))
        XCTAssertEqual(try Data(contentsOf: source), original)
    }

    func testMigrationAcrossPrefixesInterruptionRollbackAndPeerChanges() async throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: tmp) }
        let local = tmp.appendingPathComponent("Application Support/Vellum")
        let apple = tmp.appendingPathComponent("Users/alice/Vellum")
        let linux = tmp.appendingPathComponent("home/alice/Vellum")
        let source = tmp.appendingPathComponent("Documents/Paper.pdf")
        let raw = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
        func write(_ data: Data, _ url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        try write(raw, source)
        let old = DocumentIdentity.sha256Hex(source.path)
        let doc = local.appendingPathComponent("documents/" + old)
        let dependent = ["scratchpad.md": Data("![image](attachments/a.png)".utf8),
                         "attachments/a.png": Data([0, 255, 0]), "conversations.json": Data("[]".utf8)]
        for (name, data) in dependent { try write(data, doc.appendingPathComponent(name)) }
        let meta = try JSONSerialization.data(withJSONObject:
            ["kind": "pdf", "version": 1, "last_known_path": source.path, "future": [42], "last_opened": "t"])
        try write(meta, doc.appendingPathComponent("meta.json"))
        let own = DeviceID("fixture")
        let pathKey = DocumentKey.pdfPath(source.path)
        let item = PositionDeviceRecord.DocumentEntry(readingPosition: .init(at: Date(timeIntervalSince1970: 10), value: .init(page: 2)))
        let record = PositionDeviceRecord(deviceID: own, deviceName: "Mac", devicePlatform: "macOS",
                                          writtenAt: Date(timeIntervalSince1970: 12), documents: [pathKey: item])
        let position = "positions/" + PositionLayout.fileName(for: own)
        let sourcePosition = try PositionCoding.encoder.encode(record)
        try write(sourcePosition, local.appendingPathComponent(position))
        let journals = local.appendingPathComponent("journals")
        func migration() throws -> SharedPDFMigration { try .init(root: apple, localData: local, journals: journals) }
        do {
            try await migration().migrate([source], readID: id) { if $0 == 1 { throw CancellationError() } }
            XCTFail("Expected interruption")
        } catch is CancellationError {}
        try await migration().migrate([], readID: id)
        try await migration().migrate([source], readID: id)
        try fm.createDirectory(at: linux.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: apple, to: linux)
        var new = ""
        for prefix in [apple, linux] {
            let location = SharedPDFLocation(root: prefix)
            let pdf = try XCTUnwrap(location.resolve("PDFs/Paper.pdf"))
            let bytes = try Data(contentsOf: pdf)
            new = try XCTUnwrap(id(bytes))
            XCTAssertEqual(location.relativePath(for: pdf), "PDFs/Paper.pdf")
            let shared = prefix.appendingPathComponent(".vellum/documents/" + new)
            let sharedMeta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: shared.appendingPathComponent("meta.json"))) as? [String: Any])
            XCTAssertEqual(sharedMeta["last_known_path"] as? String, "PDFs/Paper.pdf")
            XCTAssertEqual(sharedMeta["future"] as? [Int], [42])
            for (name, data) in dependent { XCTAssertEqual(try Data(contentsOf: shared.appendingPathComponent(name)), data) }
            let saved = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: Data(contentsOf: prefix.appendingPathComponent(".vellum/" + position)))
            XCTAssertEqual(saved.documents[.pdf(stableIdentifier: new)], item)
            XCTAssertNil(saved.documents[pathKey])
            for bad in [source.path, "../Paper.pdf", "PDFs/../Paper.pdf", "PDFs//Paper.pdf", "PDFs/../../Paper.pdf"] {
                XCTAssertNil(location.resolve(bad))
            }
            let link = prefix.appendingPathComponent("PDFs/alias")
            try fm.createSymbolicLink(at: link, withDestinationURL: source.deletingLastPathComponent())
            XCTAssertNil(location.resolve("PDFs/alias/Paper.pdf"))
        }
        let scratch = apple.appendingPathComponent(".vellum/documents/" + new + "/scratchpad.md")
        try Data("peer edit".utf8).write(to: scratch)
        do { try await migration().rollback(); XCTFail("Expected peer conflict") } catch is SharedPDFMigration.Failure {}
        XCTAssertEqual(try String(contentsOf: scratch, encoding: .utf8), "peer edit")
        XCTAssertTrue(fm.fileExists(atPath: apple.appendingPathComponent("PDFs/Paper.pdf").path))
        try dependent["scratchpad.md"]!.write(to: scratch)
        try await migration().rollback()
        try await migration().rollback()
        XCTAssertFalse(fm.fileExists(atPath: scratch.deletingLastPathComponent().path))
        XCTAssertFalse(fm.fileExists(atPath: apple.appendingPathComponent("PDFs/Paper.pdf").path))
        XCTAssertEqual(try Data(contentsOf: source), raw)
        XCTAssertEqual(try Data(contentsOf: doc.appendingPathComponent("meta.json")), meta)
        XCTAssertEqual(try Data(contentsOf: local.appendingPathComponent(position)), sourcePosition)
        for (name, data) in dependent { XCTAssertEqual(try Data(contentsOf: doc.appendingPathComponent(name)), data) }
    }
}
