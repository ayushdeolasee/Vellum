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

    /// An imported bundle is not a file we wrote: `read` accepts up to
    /// `maxConversationsBytes` (32 MB) of conversations.json from it, and the
    /// merge writes the result straight to documents/<key>/conversations.json.
    /// So the import path has to apply the same per-reference caps
    /// `AiPersistence.limit` does — otherwise a reference that still carries its
    /// base64 pixels, or a whole-page excerpt, lands on disk verbatim and is
    /// re-encoded and rewritten in full on every subsequent AI turn.
    func testImportedConversationReferencesAreCappedLikeAPersistedOne() throws {
        let key = "convo-ref-cap-key"
        let hugeExcerpt = String(repeating: "x", count: AiPersistence.maxReferenceCharacters + 500)
        var incoming = message(
            id: "imp-ref-1", role: .user, content: "what is this",
            createdAt: "2026-02-01T00:00:00Z")
        incoming.references = [
            AiReference(kind: .selection(text: hugeExcerpt, page: 3)),
            AiReference(kind: .pageSnapshot(
                image: AiPageImageSnapshot(
                    pageNumber: 4, base64Data: String(repeating: "A", count: 4_096),
                    mediaType: "image/jpeg", width: 640, height: 480),
                page: 4)),
        ]
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: nil,
            attachments: [],
            conversations: try JSONEncoder().encode([incoming]))

        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }

        let data = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: key))
        let stored = try JSONDecoder().decode([AiMessage].self, from: data)
        let references = try XCTUnwrap(stored.first).references
        XCTAssertEqual(references.count, 2)
        // The cap plus the one-character ellipsis marker, as on the save path.
        XCTAssertEqual(references.first?.text?.count, AiPersistence.maxReferenceCharacters + 1)
        // Pixels dropped, descriptor kept — the reference still renders as a chip.
        XCTAssertEqual(references.last?.image?.base64Data, "")
        XCTAssertEqual(references.last?.image?.width, 640)
        XCTAssertEqual(references.last?.page, 4)
    }

    // MARK: - Import must not destroy a local conversation it can't read (#90)

    /// The merge rewrites conversations.json in one shot, with no write-behind
    /// cache to fall back on. It used to decode the LOCAL file all-or-nothing, so
    /// one bad record collapsed it to `[]` and the import destroyed every good
    /// local message on the spot. Only the unreadable record may be lost.
    func testImportKeepsLocalMessagesAroundAnUndecodableOne() throws {
        let key = "convo-lossy-merge-key"
        let good = message(id: "local-1", role: .user, content: "local question",
                           createdAt: "2026-01-01T00:00:00Z")
        var array = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode([good])) as? [Any])
        array.append(["id": "local-bad", "role": "system"])
        try DocumentDataStore.saveConversationsData(
            forKey: key, data: try JSONSerialization.data(withJSONObject: array))

        let incoming = message(id: "imp-1", role: .assistant, content: "imported answer",
                               createdAt: "2026-01-02T00:00:00Z")
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: nil,
            attachments: [],
            conversations: try JSONEncoder().encode([incoming]))
        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }

        let data = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: key))
        let stored = try JSONDecoder().decode([AiMessage].self, from: data)
        XCTAssertEqual(stored.map(\.id), ["local-1", "imp-1"],
                       "the readable local message must survive the merge")
    }

    /// When NOTHING in the local file decodes, the merge would write the
    /// imported messages over bytes we merely failed to read — the same loss
    /// `AiPersistence`'s write guard refuses. The import must not be a way
    /// around it: the file is left byte-for-byte intact and the failure is
    /// surfaced rather than swallowed.
    func testImportRefusesToOverwriteAnUndecodableLocalConversation() throws {
        let key = "convo-undecodable-merge-key"
        let corrupt = Data(#"[{"id":"local-bad","role":"system"}]"#.utf8)
        try DocumentDataStore.saveConversationsData(forKey: key, data: corrupt)

        let incoming = message(id: "imp-1", role: .assistant, content: "imported answer",
                               createdAt: "2026-01-02T00:00:00Z")
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: nil,
            attachments: [],
            conversations: try JSONEncoder().encode([incoming]))

        XCTAssertThrowsError(
            try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal })
        XCTAssertEqual(DocumentDataStore.loadConversationsData(forKey: key), corrupt,
                       "the unreadable local conversation must be left untouched")
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

    func testImportedConversationCapsNestedToolSummaries() throws {
        let huge = String(repeating: "oversized ", count: 2_000)
        var hostile = message(
            id: "hostile",
            role: .assistant,
            content: "answer",
            createdAt: "2026-01-01T00:00:00Z"
        )
        hostile.toolSummaries = (0..<(AiPersistence.maxToolSummariesPerMessage + 4)).map { index in
            AiToolSummary(
                id: huge,
                title: "\(index)-\(huge)",
                detail: huge,
                sources: (0..<(AiPersistence.maxToolSourcesPerSummary + 4)).map {
                    .init(id: huge, page: $0 == 0 ? Int.max : $0 + 1, excerpt: huge)
                },
                destinationPage: Int.max
            )
        }
        let imported = VellumBundle.Imported(
            manifest: validPdfManifest(documentBytes: Data("d".utf8)),
            documentData: Data("d".utf8),
            scratchpad: nil,
            attachments: [],
            conversations: try JSONEncoder().encode([hostile])
        )
        let key = "hostile-conversation"

        try VellumBundle.installSidecar(imported, forKey: key) { _ in .keepLocal }

        let data = try XCTUnwrap(DocumentDataStore.loadConversationsData(forKey: key))
        let stored = try XCTUnwrap(JSONDecoder().decode([AiMessage].self, from: data).first)
        let summaries = try XCTUnwrap(stored.toolSummaries)
        let first = try XCTUnwrap(summaries.first)
        XCTAssertEqual(summaries.count, AiPersistence.maxToolSummariesPerMessage)
        XCTAssertLessThanOrEqual(first.title.count, AiPersistence.maxToolSummaryTitleCharacters)
        XCTAssertEqual(first.sources.count, AiPersistence.maxToolSourcesPerSummary)
        XCTAssertLessThanOrEqual(
            first.sources.first?.excerpt.count ?? 0,
            AiPersistence.maxToolSourceExcerptCharacters
        )
        XCTAssertNil(first.destinationPage)
        XCTAssertNil(first.sources.first?.page)
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
