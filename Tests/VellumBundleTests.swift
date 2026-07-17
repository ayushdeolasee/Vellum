import XCTest
import CoreGraphics
@testable import Vellum

// Coverage for the `.vellum` bundle codec (VellumBundle) and its sidecar-install
// merge rules: an export→import round-trip that lands notes/attachments/
// conversations under documents/<docId>/ with relative refs intact and the
// conversation merged, hash-tamper detection, zip-slip rejection, the
// conversations-excluded-by-default path, and version-2 rejection. Drives
// VellumBundle + DocumentDataStore directly, never the UI panels.

@MainActor
final class VellumBundleTests: XCTestCase {
    private var base: URL!
    private var root: URL!
    private var scratch: URL!

    override func setUp() async throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-bundle-\(UUID().uuidString)")
        root = base.appendingPathComponent("documents")
        scratch = base.appendingPathComponent("scratch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        DocumentDataStore.rootDirectoryOverride = root
    }

    override func tearDown() async throws {
        DocumentDataStore.rootDirectoryOverride = nil
        if let base { try? FileManager.default.removeItem(at: base) }
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func message(id: String, role: AiRole, content: String, createdAt: String) -> AiMessage {
        AiMessage(id: id, role: role, content: content, createdAt: createdAt)
    }

    // MARK: - Round-trip

    func testExportImportRoundTripInstallsSidecarUnderDocId() throws {
        let attachmentId = "cafebabe-0001"
        let attachmentBytes = Data([0x89, 0x50, 0x4e, 0x47, 1, 2, 3])
        let scratchpad = "Note ![x](attachments/\(attachmentId).png) end"
        let exportedConversation = [
            message(id: "imp-1", role: .user, content: "imported q", createdAt: "2026-02-01T00:00:00Z"),
            message(id: "imp-2", role: .assistant, content: "imported a", createdAt: "2026-02-01T00:00:01Z"),
        ]
        let conversationsData = try JSONEncoder().encode(exportedConversation)
        let documentData = Data("%PDF-1.7 fake pdf bytes".utf8)

        let content = VellumBundle.Content(
            kind: .pdf,
            docId: "11111111-2222-3333-4444-555555555555",
            documentFile: "paper.pdf",
            documentData: documentData,
            title: "The Paper",
            scratchpad: scratchpad,
            attachments: [(name: "\(attachmentId).png", data: attachmentBytes)],
            conversations: conversationsData)

        let bundleURL = scratch.appendingPathComponent("out.vellum")
        try VellumBundle.write(content, to: bundleURL)
        XCTAssertTrue(exists(bundleURL))

        let imported = try VellumBundle.read(at: bundleURL)
        XCTAssertEqual(imported.manifest.format, "vellum")
        XCTAssertEqual(imported.manifest.version, 1)
        XCTAssertEqual(imported.manifest.kind, "pdf")
        XCTAssertEqual(imported.manifest.docId, content.docId)
        XCTAssertEqual(imported.manifest.documentFile, "paper.pdf")
        XCTAssertTrue(imported.manifest.includesConversations)
        XCTAssertEqual(imported.documentData, documentData)
        XCTAssertEqual(imported.scratchpad, scratchpad)
        XCTAssertEqual(imported.attachments.count, 1)
        XCTAssertEqual(imported.attachments.first?.name, "\(attachmentId).png")
        XCTAssertEqual(imported.attachments.first?.data, attachmentBytes)

        // Install under a DIFFERENT local key that already has a conversation,
        // to exercise the merge-by-id union.
        let installKey = "install-doc-key"
        let localConversation = [
            message(id: "local-1", role: .user, content: "local q", createdAt: "2026-01-01T00:00:00Z"),
        ]
        try DocumentDataStore.saveConversationsData(
            forKey: installKey, data: JSONEncoder().encode(localConversation))

        try VellumBundle.installSidecar(imported, forKey: installKey) { _ in .keepLocal }

        // scratchpad.md landed with the relative ref intact.
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: installKey))
        let onDisk = DocumentDataStore.loadScratchpad(forKey: installKey)
        XCTAssertEqual(onDisk, scratchpad)
        XCTAssertTrue(onDisk.contains("attachments/\(attachmentId).png"))

        // Attachment copied into the doc's folder.
        let attachmentFile = DocumentDataStore.attachmentsDir(forKey: installKey)
            .appendingPathComponent("\(attachmentId).png")
        XCTAssertTrue(exists(attachmentFile))
        XCTAssertEqual(try Data(contentsOf: attachmentFile), attachmentBytes)

        // Conversation merged: local + imported, id-unioned, sorted by created_at.
        let mergedData = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: installKey))
        let merged = try JSONDecoder().decode([AiMessage].self, from: mergedData)
        XCTAssertEqual(merged.map(\.id), ["local-1", "imp-1", "imp-2"])
    }

    // MARK: - Unstamped-PDF import stamps the manifest id

    /// An imported PDF that carried no /VellumDocId must be stamped with the
    /// manifest's id before it opens, so its reopen storage key matches the
    /// sidecar just installed under that id (finding 1). Drives the stamp helper
    /// + install directly, skipping the NSSavePanel.
    func testUnstampedPdfImportStampsManifestDocId() throws {
        let real = makeRealPdfData()
        // A byte-hash-style manifest id (what the exporter records for an
        // unstamped source): a bare 64-hex sha256, not a UUID.
        let manifestDocId = DocumentIdentity.byteHash(real)

        let content = VellumBundle.Content(
            kind: .pdf, docId: manifestDocId, documentFile: "unstamped.pdf",
            documentData: real, title: "Unstamped",
            scratchpad: "imported note", attachments: [], conversations: nil)
        let bundleURL = scratch.appendingPathComponent("unstamped.vellum")
        try VellumBundle.write(content, to: bundleURL)
        let imported = try VellumBundle.read(at: bundleURL)

        // Mirror importVellumBundle's post-save steps (no panel): write the doc,
        // stamp when it has no id, resolve the key, install the sidecar.
        let destination = scratch.appendingPathComponent("unstamped-written.pdf")
        try imported.documentData.write(to: destination)
        XCTAssertNil(PdfMetadata.documentId(atPath: destination.path))

        if PdfMetadata.documentId(atPath: destination.path) == nil {
            try PdfMetadata.stampDocumentId(atPath: destination.path, id: imported.manifest.docId)
        }

        // The written file now carries /VellumDocId == manifest.docId, so the
        // reopen key (DocumentIdentity.storageKey) will match the sidecar.
        let stamped = try XCTUnwrap(PdfMetadata.documentId(atPath: destination.path))
        XCTAssertEqual(stamped, manifestDocId)

        let key: String = PdfMetadata.documentId(atPath: destination.path) ?? imported.manifest.docId
        XCTAssertEqual(key, manifestDocId)
        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }

        // The imported note is reachable under the same key the reopen resolves.
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: manifestDocId))
        let reopenKey = DocumentIdentity.storageKey(
            for: DocumentInfo(kind: .pdf, pdfPath: destination.path, title: nil,
                              pageCount: nil, lastPage: nil, docId: stamped))
        XCTAssertEqual(reopenKey, manifestDocId)
    }

    // MARK: - Hash tamper

    func testHashTamperOnDocumentThrows() throws {
        // Manifest claims a hash for one set of bytes; the packed document is
        // different, so integrity verification must fail.
        let realBytes = Data("real document".utf8)
        let tamperedBytes = Data("tampered document".utf8)
        let manifest = VellumBundle.Manifest(
            format: "vellum", version: 1, kind: "pdf",
            docId: Self.canonicalDocId, documentFile: "d.pdf", title: nil,
            exportedAt: WebLibrary.rfc3339Now(), generator: "test",
            includesConversations: false,
            hashes: .init(document: WebArchive.sha256Hex(realBytes), scratchpad: nil, conversations: nil),
            attachments: [])
        let url = try packRawBundle(manifest: manifest, extraEntries: [
            MiniZip.Entry(name: "document/d.pdf", data: tamperedBytes, stored: true),
        ])
        XCTAssertThrowsError(try VellumBundle.read(at: url))
    }

    func testHashTamperOnAttachmentThrows() throws {
        let documentBytes = Data("doc".utf8)
        let realAttachment = Data([1, 2, 3])
        let tampered = Data([9, 9, 9])
        let manifest = VellumBundle.Manifest(
            format: "vellum", version: 1, kind: "pdf",
            docId: Self.canonicalDocId, documentFile: "d.pdf", title: nil,
            exportedAt: WebLibrary.rfc3339Now(), generator: "test",
            includesConversations: false,
            hashes: .init(
                document: WebArchive.sha256Hex(documentBytes), scratchpad: nil, conversations: nil),
            attachments: [
                .init(path: "attachments/a.png", bytes: realAttachment.count,
                      sha256: WebArchive.sha256Hex(realAttachment)),
            ])
        let url = try packRawBundle(manifest: manifest, extraEntries: [
            MiniZip.Entry(name: "document/d.pdf", data: documentBytes, stored: true),
            MiniZip.Entry(name: "attachments/a.png", data: tampered, stored: true),
        ])
        XCTAssertThrowsError(try VellumBundle.read(at: url))
    }

    // MARK: - Zip-slip

    func testZipSlipRawEntryRejected() throws {
        let documentBytes = Data("doc".utf8)
        let manifest = validPdfManifest(documentBytes: documentBytes)
        let url = try packRawBundle(manifest: manifest, extraEntries: [
            MiniZip.Entry(name: "document/d.pdf", data: documentBytes, stored: true),
            MiniZip.Entry(name: "../evil", data: Data("pwned".utf8), stored: true),
        ])
        XCTAssertThrowsError(try VellumBundle.read(at: url)) { error in
            XCTAssertTrue("\(error)".lowercased().contains("unsafe"))
        }
    }

    func testZipSlipAttachmentPathRejected() throws {
        let documentBytes = Data("doc".utf8)
        let evil = Data("pwned".utf8)
        var manifest = validPdfManifest(documentBytes: documentBytes)
        manifest.attachments = [
            .init(path: "attachments/../evil", bytes: evil.count, sha256: WebArchive.sha256Hex(evil)),
        ]
        // Only the document entry is physically present — the malicious path
        // lives in the manifest, so the attachment-path guard must reject it.
        let url = try packRawBundle(manifest: manifest, extraEntries: [
            MiniZip.Entry(name: "document/d.pdf", data: documentBytes, stored: true),
        ])
        XCTAssertThrowsError(try VellumBundle.read(at: url))
    }

    // MARK: - Conversations excluded by default

    func testConversationsExcludedByDefault() throws {
        let content = VellumBundle.Content(
            kind: .pdf, docId: Self.canonicalDocId, documentFile: "d.pdf",
            documentData: Data("doc".utf8), title: "T",
            scratchpad: "a note", attachments: [], conversations: nil)
        let url = scratch.appendingPathComponent("no-convo.vellum")
        try VellumBundle.write(content, to: url)

        let imported = try VellumBundle.read(at: url)
        XCTAssertFalse(imported.manifest.includesConversations)
        XCTAssertNil(imported.manifest.hashes.conversations)
        XCTAssertNil(imported.conversations)

        let key = "no-convo-key"
        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }
        XCTAssertFalse(DocumentDataStore.conversationsExist(forKey: key))
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
    }

    // MARK: - Version rejection

    func testVersionTwoRejected() throws {
        let documentBytes = Data("doc".utf8)
        var manifest = validPdfManifest(documentBytes: documentBytes)
        manifest.version = 2
        let url = try packRawBundle(manifest: manifest, extraEntries: [
            MiniZip.Entry(name: "document/d.pdf", data: documentBytes, stored: true),
        ])
        XCTAssertThrowsError(try VellumBundle.read(at: url)) { error in
            XCTAssertTrue("\(error)".contains("please update Vellum"))
        }
    }

    // MARK: - Scratchpad conflict resolution

    func testScratchpadConflictKeepLocal() throws {
        let key = "conflict-key"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "my local note")
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: "the imported note",
            attachments: [], conversations: nil)
        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "my local note")
    }

    func testScratchpadConflictUseImported() throws {
        let key = "conflict-key-2"
        try DocumentDataStore.saveScratchpad(forKey: key, text: "my local note")
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: "the imported note",
            attachments: [], conversations: nil)
        try VellumBundle.installSidecar(imported, forKey: key) { _ in .useImported }
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "the imported note")
    }

    func testAttachmentNeverOverwritesExistingId() throws {
        let key = "attach-key"
        let dir = DocumentDataStore.attachmentsDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let existing = Data("original".utf8)
        try existing.write(to: dir.appendingPathComponent("id1.png"))

        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: nil,
            attachments: [(name: "id1.png", data: Data("incoming".utf8))],
            conversations: nil)
        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }

        // The local id1 was NOT overwritten.
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("id1.png")), existing)
    }

    // MARK: - doc_id path safety (STAGE F2 #1, all three layers)

    /// VellumBundle layer: a hostile manifest doc_id carrying path traversal is
    /// rejected at read rather than becoming a storage key.
    func testTraversalManifestDocIdRejected() throws {
        let documentBytes = Data("doc".utf8)
        var manifest = validPdfManifest(documentBytes: documentBytes)
        manifest.docId = "../../../../etc/passwd"
        let url = try packRawBundle(manifest: manifest, extraEntries: [
            MiniZip.Entry(name: "document/d.pdf", data: documentBytes, stored: true),
        ])
        XCTAssertThrowsError(try VellumBundle.read(at: url)) { error in
            XCTAssertTrue("\(error)".lowercased().contains("invalid document id"))
        }
    }

    /// DocumentDataStore layer: the central documentDir guard neutralizes a
    /// non-canonical key to its sha256 folder, so it can never escape documents/.
    func testDocumentDirNeutralizesTraversalKey() {
        let evil = "../../../../etc/passwd"
        let dir = DocumentDataStore.documentDir(forKey: evil)
        XCTAssertEqual(
            dir.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL,
            "the folder must stay a direct child of the documents root")
        XCTAssertEqual(dir.lastPathComponent, DocumentIdentity.sha256Hex(evil))
        XCTAssertFalse(dir.path.contains(".."))
        // A canonical key is used verbatim.
        let canonical = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        XCTAssertEqual(
            DocumentDataStore.documentDir(forKey: canonical).lastPathComponent, canonical)
    }

    /// PdfMetadata layer: a crafted PDF whose embedded /VellumDocId is a traversal
    /// string reads back as nil (unstamped), never an attacker-chosen folder name.
    func testEmbeddedTraversalDocIdReadsAsNil() throws {
        let dest = scratch.appendingPathComponent("evil-id.pdf")
        try makeRealPdfData().write(to: dest)
        // Stamp a hostile id straight in, bypassing any write-side validation.
        try PdfMetadata.stampDocumentId(atPath: dest.path, id: "../../evil")
        XCTAssertNil(PdfMetadata.documentId(atPath: dest.path),
                     "a non-canonical embedded id must read as unstamped")
    }

    // MARK: - Panel-free import core (STAGE F2 #2/#3)

    /// The core writes the document, stamps + resolves the key, and installs the
    /// sidecar — the whole import minus the NSSavePanel.
    func testImportCoreWritesDocumentAndInstallsSidecar() throws {
        let real = makeRealPdfData()
        let docId = DocumentIdentity.byteHash(real)
        let content = VellumBundle.Content(
            kind: .pdf, docId: docId, documentFile: "paper.pdf",
            documentData: real, title: "Paper",
            scratchpad: "core note", attachments: [], conversations: nil)
        let bundleURL = scratch.appendingPathComponent("core.vellum")
        try VellumBundle.write(content, to: bundleURL)
        let imported = try VellumBundle.read(at: bundleURL)

        let dest = scratch.appendingPathComponent("core-written.pdf")
        let result = try AppStore.importVellumBundleCore(imported, to: dest) { _ in .keepLocal }

        XCTAssertEqual(result.path, dest.path)
        XCTAssertTrue(result.failedAttachments.isEmpty)
        XCTAssertTrue(exists(dest))
        // The written PDF is stamped with the manifest id, so its reopen key matches.
        let key = try XCTUnwrap(PdfMetadata.documentId(atPath: dest.path))
        XCTAssertEqual(key, docId)
        XCTAssertTrue(DocumentDataStore.scratchpadExists(forKey: key))
        XCTAssertEqual(DocumentDataStore.loadScratchpad(forKey: key), "core note")
    }

    /// Importing over an existing file replaces it atomically (temp + rename, no
    /// pre-delete) and leaves no temp sibling behind.
    func testImportCoreAtomicallyReplacesExistingDestination() throws {
        let dest = scratch.appendingPathComponent("existing.pdf")
        let oldBytes = Data("OLD CONTENT that must be replaced".utf8)
        try oldBytes.write(to: dest)

        let real = makeRealPdfData()
        let content = VellumBundle.Content(
            kind: .pdf, docId: DocumentIdentity.byteHash(real), documentFile: "existing.pdf",
            documentData: real, title: "New", scratchpad: nil, attachments: [], conversations: nil)
        let bundleURL = scratch.appendingPathComponent("replace.vellum")
        try VellumBundle.write(content, to: bundleURL)
        let imported = try VellumBundle.read(at: bundleURL)

        _ = try AppStore.importVellumBundleCore(imported, to: dest) { _ in .keepLocal }

        XCTAssertNotNil(PdfMetadata.documentId(atPath: dest.path), "destination holds the imported PDF")
        XCTAssertNotEqual(try Data(contentsOf: dest), oldBytes)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: scratch.path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".existing.pdf.import-") },
                       "the atomic temp sibling must be renamed away, not left behind")
    }

    // MARK: - Attachment-failure surfacing (STAGE F2 #5)

    func testInstallSidecarSurfacesFailedAttachments() throws {
        let key = "aaaaaaaa-0000-0000-0000-000000000001"
        // Pre-create the attachments dir READ-ONLY so writes into it fail.
        let dir = DocumentDataStore.attachmentsDir(forKey: key)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        }
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8), scratchpad: nil,
            attachments: [(name: "img1.png", data: Data([1, 2, 3]))],
            conversations: nil)
        let failed = try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }
        XCTAssertEqual(failed, ["img1.png"], "a failed attachment write must be reported, not swallowed")
    }

    // MARK: - Pre-parse caps (STAGE F2 #6)

    /// A crafted archive listing more entries than the cap is refused before any
    /// entry payload is touched.
    func testEntryCountCapRejected() throws {
        var entries: [MiniZip.Entry] = [
            MiniZip.Entry(
                name: "manifest.json",
                data: try JSONEncoder().encode(validPdfManifest(documentBytes: Data("d".utf8))),
                stored: false),
            MiniZip.Entry(name: "document/d.pdf", data: Data("d".utf8), stored: true),
        ]
        for i in 0...VellumBundle.maxEntries {
            entries.append(MiniZip.Entry(name: "filler/\(i).bin", data: Data([0]), stored: true))
        }
        let url = scratch.appendingPathComponent("too-many.vellum")
        try MiniZip.write(entries: entries).write(to: url)
        XCTAssertThrowsError(try VellumBundle.read(at: url)) { error in
            XCTAssertTrue("\(error)".lowercased().contains("too many entries"))
        }
    }

    // MARK: - Helpers

    /// A real, PDFKit-parseable single-page PDF with no /VellumDocId — needed
    /// because stampDocumentId round-trips through PDFDocument.
    private func makeRealPdfData() -> Data {
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// A canonical (lowercase-hex/UUID) doc_id — the only form `VellumBundle.read`
    /// now accepts (a non-canonical value is rejected as a hostile path).
    private static let canonicalDocId = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

    private func validPdfManifest(documentBytes: Data) -> VellumBundle.Manifest {
        VellumBundle.Manifest(
            format: "vellum", version: 1, kind: "pdf",
            docId: Self.canonicalDocId, documentFile: "d.pdf", title: "T",
            exportedAt: WebLibrary.rfc3339Now(), generator: "test",
            includesConversations: false,
            hashes: .init(
                document: WebArchive.sha256Hex(documentBytes), scratchpad: nil, conversations: nil),
            attachments: [])
    }

    /// Pack a raw bundle with a caller-supplied manifest + entries — used to
    /// craft tampered / malicious bundles the writer would never produce.
    private func packRawBundle(
        manifest: VellumBundle.Manifest, extraEntries: [MiniZip.Entry]
    ) throws -> URL {
        let manifestData = try JSONEncoder().encode(manifest)
        var entries = [MiniZip.Entry(name: "manifest.json", data: manifestData, stored: false)]
        entries.append(contentsOf: extraEntries)
        let zip = try MiniZip.write(entries: entries)
        let url = scratch.appendingPathComponent("raw-\(UUID().uuidString).vellum")
        try zip.write(to: url)
        return url
    }
}
