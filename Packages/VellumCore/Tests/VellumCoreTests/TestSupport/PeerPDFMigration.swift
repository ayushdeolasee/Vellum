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
