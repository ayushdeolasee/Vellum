import Foundation
import Testing
import VellumCore
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(LinuxReader)
import LinuxReader
#endif

extension PeerLibrary {
    static func documentID(_ bytes: Data) -> String? {
        #if canImport(CoreGraphics)
        guard let provider = CGDataProvider(data: bytes as CFData),
              let document = CGPDFDocument(provider), let info = document.info else { return nil }
        var value: CGPDFStringRef?
        guard CGPDFDictionaryGetString(info, "VellumDocId", &value), let value else { return nil }
        return CGPDFStringCopyTextString(value) as String?
        #else
        return ClassicPdfFile.currentInfoText(forKey: "VellumDocId", in: bytes)
        #endif
    }

    /// Migrate legacy path-keyed sidecars and a position on the synthetic source
    /// machine. Only the resulting shared folder crosses to the other machine.
    func migratePDFs() async throws {
        let privateRoot = root.deletingLastPathComponent().appendingPathComponent("before-migration", isDirectory: true)
            .standardizedFileURL.resolvingSymlinksInPath()
        let local = privateRoot.appendingPathComponent("local", isDirectory: true)
        let original = privateRoot.appendingPathComponent("Paper.pdf")
        let signed = privateRoot.appendingPathComponent("Signed.pdf")
        let source = LocalFolderFileStore(root: privateRoot)
        try await source.replace(original, with: Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column")))
        try await source.replace(signed, with: Data(contentsOf: PdfFixtureBuilder.fixtureURL("digitally-signed")))
        let old = local.appendingPathComponent("documents/" + DocumentIdentity.sha256Hex(original.path))
        let meta: [String: Any] = ["version": 1, "kind": "pdf", "title": "Migrated paper",
                                   "last_opened": "2026-01-01T00:00:00Z", "last_known_path": original.path,
                                   "future_pdf": ["edition": 17]]
        try await source.replace(old.appendingPathComponent("meta.json"), with: JSONSerialization.data(withJSONObject: meta))
        try await source.replace(old.appendingPathComponent("conversations.json"), with: Self.messageBytes(["pdf-message"]))
        try await source.replace(old.appendingPathComponent("scratchpad.md"), with: Data(Self.imageLink.utf8))
        try await source.replace(old.appendingPathComponent("attachments/" + Self.imageName), with: Self.png)
        var legacy = Self.position("mac")
        legacy.documents = [.pdfPath(original.path): legacy.documents[Self.key]!]
        try await FilePositionStorage(root: local.appendingPathComponent("positions")).write(legacy)
        try await positions.write(Self.position("mac"))
        let migration = try SharedPDFMigration(root: root, localData: local, journals: privateRoot.appendingPathComponent("journals"))
        try await migration.migrate([original, signed], readID: Self.documentID)
        let mapped = try await migration.migratedURL(for: original, readID: Self.documentID)
        #expect(mapped?.lastPathComponent == "Paper.pdf")
        let published = try read(Self.pdf)
        #expect(published.starts(with: try Data(contentsOf: original)))
        let id = try #require(Self.documentID(published))
        #expect(try !store.contents(of: url(".vellum/documents/" + id)).isEmpty)
        // Outside both peer roots: compare the returned bytes against the original Mac export.
        try await source.replace(privateRoot.appendingPathComponent("published.sha256"),
                                 with: Data(DocumentIdentity.byteHash(published).utf8))
    }

    func verifyPDFs() async throws -> String {
        let location = SharedPDFLocation(root: root)
        let pdf = try #require(location.resolve(Self.pdf))
        let bytes = try Data(contentsOf: pdf)
        let id = try #require(Self.documentID(bytes))
        #expect(SharedPDFIdentity.storageKey(in: bytes, readerID: id) == id)
        let base = ".vellum/documents/" + id + "/"
        let meta = try JSONDecoder().decode([String: JSONValue].self, from: read(base + "meta.json"))
        #expect(meta["last_known_path"] == .string(Self.pdf))
        #expect(meta["future_pdf"] == .object(["edition": .int(17)]))
        #expect(try read(base + "scratchpad.md") == Data(Self.imageLink.utf8))
        #expect(try read(base + "attachments/" + Self.imageName) == Self.png)
        #expect(try read(base + "conversations.json") == Self.messageBytes(["pdf-message"]))
        let signed = try read("PDFs/Signed.pdf")
        #expect(signed == (try Data(contentsOf: PdfFixtureBuilder.fixtureURL("digitally-signed"))))
        let hash = SharedPDFIdentity.storageKey(in: signed, readerID: Self.documentID(signed))
        #expect(hash == DocumentIdentity.byteHash(signed))
        let signedMeta = try JSONDecoder().decode([String: JSONValue].self, from: read(".vellum/documents/" + hash + "/meta.json"))
        #expect(signedMeta["last_known_path"] == .string("PDFs/Signed.pdf"))
        #if canImport(LinuxReader)
        let fileStore = ReadOnlyLibraryFileStore(root: try await RootDirectory.open(root))
        let catalog = try await ReaderMetadataCatalog.load(in: fileStore)
        let opened = try await PdfiumDocument.openingInfo(in: bytes)
        #expect(opened.stableIdentifier == id)
        let entry = try await catalog.sharedPDF(bytes: bytes, file: pdf, stamp: opened.stableIdentifier, fallbackTitle: "fallback")
        #expect(entry.displayTitle == "Migrated paper")
        #expect(entry.lastPage == 1)
        #endif
        return id
    }
}

extension CrossPlatformRoundTripTests {
    @Test func historicalPDFPathMigration() async throws {
        let fm = FileManager.default
        let name = "vellum-path-migration-" + UUID().uuidString
        let base = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        defer { try? fm.removeItem(at: base) }
        for physicalHistory in [true, false] {
            let folder = base.appendingPathComponent(physicalHistory ? "physical" : "logical")
            let physicalDir: URL
            let logicalDir: URL
            #if os(macOS)
            physicalDir = URL(fileURLWithPath: "/private" + folder.path)
            logicalDir = folder
            #else
            physicalDir = folder.appendingPathComponent("originals")
            logicalDir = folder.appendingPathComponent("alias")
            #endif
            try fm.createDirectory(at: physicalDir, withIntermediateDirectories: true)
            #if !os(macOS)
            try fm.createSymbolicLink(at: logicalDir, withDestinationURL: physicalDir)
            #endif
            let physical = physicalDir.appendingPathComponent("Paper.pdf")
            let logical = logicalDir.appendingPathComponent("Paper.pdf")
            let original = try Data(contentsOf: PdfFixtureBuilder.fixtureURL("classic-two-column"))
            try original.write(to: physical)
            let historical = physicalHistory ? physical : logical
            #if os(macOS)
            let selected = physicalHistory ? logical : physical
            #else
            // An arbitrary symlink is discoverable only when supplied by the caller.
            let selected = logical
            #endif
            let local = PeerLibrary(root: folder.appendingPathComponent("local"))
            let shared = PeerLibrary(root: folder.appendingPathComponent("shared"))
            let journals = folder.appendingPathComponent("journals")
            let migration = try SharedPDFMigration(root: shared.root, localData: local.root, journals: journals)
            func privateDir(_ url: URL) -> String { "documents/" + DocumentIdentity.sha256Hex(url.path) + "/" }
            let legacy = privateDir(historical)
            let alternate = privateDir(physicalHistory ? logical : physical)
            try #require(legacy != alternate)
            let meta = try JSONEncoder().encode(["version": JSONValue.int(1), "kind": .string("pdf"),
                "last_known_path": .string(historical.path), "last_opened": .string("t"), "future_pdf": PeerLibrary.future])
            let sidecars = ["scratchpad.md": Data(PeerLibrary.imageLink.utf8),
                            "attachments/" + PeerLibrary.imageName: PeerLibrary.png,
                            "conversations.json": try PeerLibrary.messageBytes(["old"])]
            for (name, bytes) in sidecars { try await local.write(legacy + name, bytes) }
            try await local.write(legacy + "meta.json", meta)
            var position = PeerLibrary.position("mac")
            let entry = try #require(position.documents[PeerLibrary.key])
            position.documents = [.pdfPath(historical.path): entry,
                                  .pdf(stableIdentifier: DocumentIdentity.sha256Hex(historical.path)): entry]
            let name = "positions/" + PositionLayout.fileName(for: position.deviceID)
            let positionBytes = try PositionCoding.encoder.encode(position)
            try await local.write(name, positionBytes)

            let other = physicalDir.appendingPathComponent("Other.pdf")
            try original.write(to: other) // Equal bytes alone cannot authorize a different path's notes.
            try await local.write(privateDir(other) + "foreign.md", Data([99]))
            let collision = local.url(alternate + "scratchpad.md")
            try await local.write(alternate + "scratchpad.md", Data([12]))
            await #expect(throws: SharedPDFMigration.Failure.self) {
                try await migration.migrate([selected], readID: PeerLibrary.documentID)
            }
            #expect(!fm.fileExists(atPath: shared.root.path))
            #expect(try Data(contentsOf: collision) == Data([12]))
            try fm.removeItem(at: collision)
            await #expect(throws: CancellationError.self) {
                try await migration.migrate([selected], readID: PeerLibrary.documentID) { if $0 == 0 { throw CancellationError() } }
            }
            let fresh = try SharedPDFMigration(root: shared.root, localData: local.root, journals: journals)
            try fm.removeItem(at: physical)
            try fm.createSymbolicLink(at: physical, withDestinationURL: other)
            await #expect(throws: SharedPDFMigration.Failure.self) {
                try await fresh.migrate([], readID: PeerLibrary.documentID)
            }
            #expect(!fm.fileExists(atPath: shared.url(PeerLibrary.pdf).path))
            try fm.removeItem(at: physical)
            try original.write(to: physical)
            try await fresh.migrate([physical], readID: PeerLibrary.documentID)
            try await fresh.migrate([logical], readID: PeerLibrary.documentID)
            let pdf = try #require(try await fresh.migratedURL(for: historical, readID: PeerLibrary.documentID))
            let id = try #require(PeerLibrary.documentID(Data(contentsOf: pdf)))
            let published = ".vellum/documents/" + id + "/"
            #expect(try fm.contentsOfDirectory(atPath: shared.url("PDFs").path) == ["Paper.pdf"])
            #expect(try shared.store.occupiedNames(in: shared.url(".vellum/documents")) == [id])
            #expect(!fm.fileExists(atPath: shared.url(published + "foreign.md").path))
            let object = try JSONDecoder().decode([String: JSONValue].self, from: shared.read(published + "meta.json"))
            #expect(object["future_pdf"] == PeerLibrary.future)
            #expect(object["last_known_path"] == .string("PDFs/Paper.pdf"))
            for (name, bytes) in sidecars { #expect(try shared.read(published + name) == bytes) }
            let saved = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: shared.read(".vellum/" + name))
            #expect(saved.documents == [.pdf(stableIdentifier: id): entry])

            try await fresh.rollback()
            try await fresh.rollback()
            #expect(!fm.fileExists(atPath: pdf.path))
            #expect(!fm.fileExists(atPath: shared.url(published).path))
            #expect(!fm.fileExists(atPath: shared.url(".vellum/" + name).path))
            #expect(try Data(contentsOf: physical) == original)
            #expect(try local.read(legacy + "meta.json") == meta)
            #expect(try local.read(name) == positionBytes)
            for (name, bytes) in sidecars { #expect(try local.read(legacy + name) == bytes) }
            #expect(try local.read(privateDir(other) + "foreign.md") == Data([99]))
        }
    }
}
