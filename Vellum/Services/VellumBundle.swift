import Foundation

// `.vellum` — the "share with notes" container (plans/storage-design.html §5,
// tier 2). One ZIP holding the document plus its class-B sidecar so a share
// carries everything: notes, attachments, and — only when the user opts in —
// the AI conversation. A bare PDF/.vellumweb share still carries annotations for
// free (they live in the document); this bundle is the superset.
//
// The container reuses the .vellumweb machinery wholesale (WebArchive.sha256Hex,
// the MiniZip codec, WebArchive's tmp+fsync+rename atomic write, and a
// bare-filename zip-slip guard) rather than reinventing a second archive format.
// Zip entries:
//   manifest.json               — snake_case, versioned, sha256 hashes
//   document/<document_file>     — the PDF bytes as-is, or a .vellumweb for web
//   scratchpad.md                — PERSISTED relative-ref form (attachments/<id>)
//   attachments/<id>.<ext>       — region snapshots + dropped images
//   conversations.json           — ONLY when includes_conversations is true
enum VellumBundle {
    static let formatName = "vellum"
    static let formatVersion = 1

    // Read caps. The document is generous (PDFs run to hundreds of MB); the
    // sidecar caps mirror .vellumweb's tighter limits so a crafted bundle can't
    // inflate a bomb through a small entry.
    static let maxManifestBytes = 4 * 1024 * 1024
    static let maxDocumentBytes = 2 * 1024 * 1024 * 1024        // 2 GiB
    static let maxScratchpadBytes = 8 * 1024 * 1024
    static let maxConversationsBytes = 32 * 1024 * 1024
    static let maxAttachmentBytes = 16 * 1024 * 1024
    static let maxTotalAttachmentBytes = 256 * 1024 * 1024
    static let maxAttachments = 1000

    // Pre-parse memory guards (design §5 / STAGE F2 #6). MiniZip loads the whole
    // file into memory and copies it to a `[UInt8]` before any per-entry cap
    // applies, so a crafted archive is bounded THREE ways before a single entry
    // payload is touched: the on-disk file size, the central-directory entry
    // count, and the SUM of every entry's declared uncompressed size.
    /// Largest `.vellum` file we will even open (a 2 GiB document + its sidecar).
    static let maxArchiveBytes = 2_684_354_560          // 2.5 GiB
    /// Ceiling on central-directory entry count (a real bundle has a handful).
    static let maxEntries = 4096
    /// Ceiling on the sum of declared uncompressed sizes — the per-kind caps'
    /// combined budget, so no legitimate bundle is ever refused.
    static var maxTotalUncompressedBytes: Int {
        maxManifestBytes + maxDocumentBytes + maxScratchpadBytes
            + maxConversationsBytes + maxTotalAttachmentBytes
    }

    static var marketingVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.1.0"
    }

    // MARK: - Manifest

    struct Manifest: Codable, Sendable {
        var format: String
        var version: Int
        /// "pdf" | "web".
        var kind: String
        /// The document's durable identity: the /VellumDocId (or byte-hash
        /// fallback) for PDFs, the sha256 URL hash for web docs.
        var docId: String
        /// Bare filename of the entry under `document/` (also the NSSavePanel
        /// default name on import).
        var documentFile: String
        var title: String?
        var exportedAt: String
        var generator: String
        var includesConversations: Bool
        var hashes: Hashes
        var attachments: [Attachment]

        struct Hashes: Codable, Sendable {
            var document: String
            var scratchpad: String?
            var conversations: String?
        }

        struct Attachment: Codable, Sendable {
            /// Zip entry path, e.g. "attachments/<id>.jpg".
            var path: String
            var bytes: Int
            var sha256: String
        }

        enum CodingKeys: String, CodingKey {
            case format
            case version
            case kind
            case docId = "doc_id"
            case documentFile = "document_file"
            case title
            case exportedAt = "exported_at"
            case generator
            case includesConversations = "includes_conversations"
            case hashes
            case attachments
        }
    }

    // MARK: - Export / import value types

    /// Everything a bundle carries, assembled by the caller (the exporter pulls
    /// document bytes through the session and the sidecar through
    /// DocumentDataStore). Kept free of session/UI dependencies so it round-trips
    /// in tests without the panels.
    struct Content: Sendable {
        var kind: DocumentKind
        var docId: String
        var documentFile: String
        var documentData: Data
        var title: String?
        /// Persisted relative-ref markdown, or nil to omit.
        var scratchpad: String?
        /// (bare filename, bytes) per attachment.
        var attachments: [(name: String, data: Data)]
        /// Raw conversations.json bytes, present only when the user opted in.
        var conversations: Data?
    }

    struct Imported: Sendable {
        var manifest: Manifest
        var documentData: Data
        var scratchpad: String?
        var attachments: [(name: String, data: Data)]
        var conversations: Data?
    }

    /// How to resolve a scratchpad that already exists locally and differs from
    /// the imported one. `.keepLocal` is the safe default (never lose the user's
    /// own notes without an explicit choice).
    enum ScratchpadDecision: Sendable { case keepLocal, useImported }

    // MARK: - Zip-slip guard

    /// Only bare file names are allowed inside a subdir (mirrors
    /// WebArchive.safeAssetName): no traversal, no separators, no leading dot.
    static func safeName(_ name: String) -> String? {
        if name.isEmpty || name.contains("..") || name.contains("/")
            || name.contains("\\") || name.hasPrefix(".") {
            return nil
        }
        return name
    }

    /// A physical zip entry name that could escape the extraction root. Rejected
    /// outright on read so a crafted bundle can't smuggle a "../evil" entry past
    /// the manifest-driven read paths below.
    private static func hasTraversal(_ name: String) -> Bool {
        name.contains("..") || name.hasPrefix("/") || name.contains("\\")
    }

    // MARK: - Write

    /// Pack `content` into a `.vellum` bundle at `dest` atomically (temp file
    /// next to the destination, fsync, rename — WebArchive.writeArchive's idiom).
    static func write(_ content: Content, to dest: URL) throws {
        let documentHash = WebArchive.sha256Hex(content.documentData)

        var attachmentManifest: [Manifest.Attachment] = []
        var attachmentEntries: [MiniZip.Entry] = []
        for attachment in content.attachments {
            guard let safe = safeName(attachment.name) else { continue }
            let path = "attachments/\(safe)"
            attachmentManifest.append(Manifest.Attachment(
                path: path, bytes: attachment.data.count,
                sha256: WebArchive.sha256Hex(attachment.data)))
            attachmentEntries.append(MiniZip.Entry(
                name: path, data: attachment.data, stored: WebArchive.isPrecompressed(safe)))
        }

        let scratchData: Data? = content.scratchpad.flatMap { $0.isEmpty ? nil : Data($0.utf8) }
        let conversationsData: Data? = content.conversations

        let manifest = Manifest(
            format: formatName,
            version: formatVersion,
            kind: content.kind.rawValue,
            docId: content.docId,
            documentFile: content.documentFile,
            title: content.title,
            exportedAt: WebLibrary.rfc3339Now(),
            generator: "Vellum \(marketingVersion)",
            includesConversations: conversationsData != nil,
            hashes: Manifest.Hashes(
                document: documentHash,
                scratchpad: scratchData.map(WebArchive.sha256Hex),
                conversations: conversationsData.map(WebArchive.sha256Hex)),
            attachments: attachmentManifest)

        let manifestJson: Data
        do {
            manifestJson = try WebLibrary.jsonEncoderPretty.encode(manifest)
        } catch {
            throw SessionServiceError.io("Failed to serialize bundle manifest: \(error.localizedDescription)")
        }

        var entries: [MiniZip.Entry] = [
            MiniZip.Entry(name: "manifest.json", data: manifestJson, stored: false),
            // Store the document (a PDF is largely precompressed streams; a
            // .vellumweb is already a zip) — deflating hundreds of MB would burn
            // CPU and memory for no gain.
            MiniZip.Entry(
                name: "document/\(content.documentFile)", data: content.documentData, stored: true),
        ]
        if let scratchData {
            entries.append(MiniZip.Entry(name: "scratchpad.md", data: scratchData, stored: false))
        }
        entries.append(contentsOf: attachmentEntries)
        if let conversationsData {
            entries.append(MiniZip.Entry(
                name: "conversations.json", data: conversationsData, stored: false))
        }

        let zipData: Data
        do {
            zipData = try MiniZip.write(entries: entries)
        } catch {
            throw SessionServiceError.io("Failed to write bundle: \(error.localizedDescription)")
        }

        let parent = dest.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to create destination dir: \(error.localizedDescription)")
        }
        // Unique per operation so concurrent writers to the same destination
        // don't share a temp file.
        let tmp = parent.appendingPathComponent(
            ".\(dest.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())")
        do {
            try zipData.write(to: tmp)
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to create bundle: \(error.localizedDescription)")
        }
        guard rename(tmp.path, dest.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to move bundle into place: rename failed")
        }
    }

    // MARK: - Read

    /// Read and fully verify a `.vellum` bundle. Every entry is hash-checked;
    /// a version above what this build understands is rejected with the same
    /// "please update Vellum" phrasing .vellumweb uses.
    static func read(at path: URL) throws -> Imported {
        // Pre-parse guard #1 (file size): refuse before MiniZip reads the whole
        // file into memory + copies it to `[UInt8]`. A stat, not a read.
        if let size = (try? FileManager.default.attributesOfItem(atPath: path.path))?[.size] as? Int,
           size > maxArchiveBytes {
            throw SessionServiceError.invalidDocument("Bundle is too large to open")
        }

        let zip = try MiniZip(contentsOf: path)

        // Pre-parse guard #2/#3 (central-directory shape): a crafted directory
        // can list millions of entries or declare petabytes of payload. Bound
        // both from the parsed metadata BEFORE any entry's bytes are touched.
        if zip.entryCount > maxEntries {
            throw SessionServiceError.invalidDocument("Bundle contains too many entries")
        }
        if zip.totalDeclaredUncompressedSize > maxTotalUncompressedBytes {
            throw SessionServiceError.invalidDocument("Bundle declares more data than Vellum will open")
        }

        // Reject any physical entry whose name could escape the extraction root,
        // regardless of whether the manifest references it.
        for name in zip.entryNames where hasTraversal(name) {
            throw SessionServiceError.invalidDocument("Bundle contains an unsafe entry path")
        }

        let manifestBytes = try zip.readCapped("manifest.json", cap: maxManifestBytes)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestBytes)
        } catch {
            throw SessionServiceError.invalidDocument(
                "Invalid bundle manifest: \(error.localizedDescription)")
        }
        if manifest.format != formatName {
            throw SessionServiceError.invalidDocument("Not a .vellum bundle (wrong format marker)")
        }
        if manifest.version > formatVersion {
            throw SessionServiceError.invalidDocument(
                "This bundle uses format version \(manifest.version) — please update Vellum")
        }
        // The manifest doc_id becomes the sidecar's storage key (and is stamped
        // into an imported PDF). A hostile bundle could carry a traversal string
        // here; reject anything non-canonical so it can never steer a path (the
        // documentDir guard is the backstop, this is the explicit gate).
        guard DocumentIdentity.isCanonicalKey(manifest.docId) else {
            throw SessionServiceError.invalidDocument("Bundle has an invalid document id")
        }

        // Document.
        guard let documentFile = safeName(manifest.documentFile) else {
            throw SessionServiceError.invalidDocument("Bundle has an unsafe document file name")
        }
        let documentData = try zip.readCapped("document/\(documentFile)", cap: maxDocumentBytes)
        if WebArchive.sha256Hex(documentData) != manifest.hashes.document {
            throw SessionServiceError.invalidDocument(
                "Bundle document failed its integrity check (corrupted file?)")
        }

        // Scratchpad (present only when the manifest carries its hash).
        var scratchpad: String? = nil
        if let expected = manifest.hashes.scratchpad {
            let data = try zip.readCapped("scratchpad.md", cap: maxScratchpadBytes)
            if WebArchive.sha256Hex(data) != expected {
                throw SessionServiceError.invalidDocument(
                    "Bundle notes failed their integrity check (corrupted file?)")
            }
            scratchpad = String(decoding: data, as: UTF8.self)
        }

        // Attachments.
        if manifest.attachments.count > maxAttachments {
            throw SessionServiceError.invalidDocument("Bundle lists too many attachments")
        }
        var attachments: [(name: String, data: Data)] = []
        var totalAttachmentBytes = 0
        for attachment in manifest.attachments {
            guard attachment.path.hasPrefix("attachments/") else {
                throw SessionServiceError.invalidDocument("Bundle attachment path is not under attachments/")
            }
            let rest = String(attachment.path.dropFirst("attachments/".count))
            guard let safe = safeName(rest) else {
                throw SessionServiceError.invalidDocument("Bundle has an unsafe attachment path")
            }
            let data = try zip.readCapped(attachment.path, cap: maxAttachmentBytes)
            totalAttachmentBytes += data.count
            if totalAttachmentBytes > maxTotalAttachmentBytes {
                throw SessionServiceError.invalidDocument("Bundle attachments exceed the total size limit")
            }
            if WebArchive.sha256Hex(data) != attachment.sha256 {
                throw SessionServiceError.invalidDocument(
                    "Bundle attachment \(safe) failed its integrity check")
            }
            attachments.append((safe, data))
        }

        // Conversations (only when opted in AND hashed).
        var conversations: Data? = nil
        if manifest.includesConversations, let expected = manifest.hashes.conversations {
            let data = try zip.readCapped("conversations.json", cap: maxConversationsBytes)
            if WebArchive.sha256Hex(data) != expected {
                throw SessionServiceError.invalidDocument(
                    "Bundle conversation failed its integrity check (corrupted file?)")
            }
            conversations = data
        }

        return Imported(
            manifest: manifest,
            documentData: documentData,
            scratchpad: scratchpad,
            attachments: attachments,
            conversations: conversations)
    }

    // MARK: - Sidecar install (merge rules, §5)

    /// Install an imported bundle's sidecar into `documents/<key>/`, applying the
    /// design's merge rules:
    ///   • scratchpad — written when no local note exists or the local one is
    ///     byte-identical; a differing local note consults `resolveConflict`.
    ///   • attachments — copied, never overwriting an existing id.
    ///   • conversations — merged by message-id union, sorted by created_at,
    ///     then the existing per-document caps applied.
    /// The document file itself is written by the caller (it chooses where it
    /// lands); this only touches the sidecar folder.
    /// Returns the bare names of any attachments that could NOT be written (a
    /// read-only folder, a disk error). An empty array is a clean install; a
    /// non-empty one lets the caller warn the user which images are missing
    /// rather than reporting a silent success with broken refs (STAGE F2 #5).
    @discardableResult
    static func installSidecar(
        _ imported: Imported,
        forKey key: String,
        resolveScratchpadConflict resolveConflict: (_ title: String) -> ScratchpadDecision
    ) throws -> [String] {
        if let incoming = imported.scratchpad, !incoming.isEmpty {
            if !DocumentDataStore.scratchpadExists(forKey: key) {
                try DocumentDataStore.saveScratchpad(forKey: key, text: incoming)
            } else if DocumentDataStore.loadScratchpad(forKey: key) != incoming {
                let title = imported.manifest.title ?? "this document"
                if resolveConflict(title) == .useImported {
                    try DocumentDataStore.saveScratchpad(forKey: key, text: incoming)
                }
            }
            // Identical local note: nothing to do.
        }

        var failedAttachments: [String] = []
        if !imported.attachments.isEmpty {
            let dir = DocumentDataStore.attachmentsDir(forKey: key)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // Existing ids (by stem) are never overwritten — the local copy of a
            // given attachment id is authoritative.
            let existingStems = Set(
                ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                    .map { ($0 as NSString).deletingPathExtension.lowercased() })
            for (name, data) in imported.attachments {
                let stem = (name as NSString).deletingPathExtension.lowercased()
                if existingStems.contains(stem) { continue }
                do {
                    try data.write(to: dir.appendingPathComponent(name))
                } catch {
                    failedAttachments.append(name)
                }
            }
        }

        if let incoming = imported.conversations {
            try mergeConversations(incoming, forKey: key)
        }
        return failedAttachments
    }

    /// Union the imported conversation with any local one by message id, sort by
    /// created_at, then apply the per-document caps (AiPersistence contract).
    private static func mergeConversations(_ incomingData: Data, forKey key: String) throws {
        let decoder = JSONDecoder()
        let incoming = (try? decoder.decode([AiMessage].self, from: incomingData)) ?? []
        let local = DocumentDataStore.loadConversationsData(forKey: key)
            .flatMap { try? decoder.decode([AiMessage].self, from: $0) } ?? []
        guard !incoming.isEmpty || !local.isEmpty else { return }

        // Local kept on an id collision (first occurrence wins).
        var seen = Set<String>()
        var merged: [AiMessage] = []
        for message in local + incoming where seen.insert(message.id).inserted {
            merged.append(message)
        }
        merged.sort { $0.createdAt < $1.createdAt }
        let capped = capConversation(merged)
        guard !capped.isEmpty else { return }
        let data = try JSONEncoder().encode(capped)
        try DocumentDataStore.saveConversationsData(forKey: key, data: data)
    }

    /// The per-document conversation caps (mirrors AiPersistence.limit, using its
    /// public constants so the two never drift): keep the newest N, truncate
    /// over-long content.
    private static func capConversation(_ messages: [AiMessage]) -> [AiMessage] {
        messages.suffix(AiPersistence.maxMessagesPerDocument).map { message in
            var message = message
            if message.content.count > AiPersistence.maxMessageCharacters {
                let end = message.content.index(
                    message.content.startIndex, offsetBy: AiPersistence.maxMessageCharacters)
                message.content = String(message.content[..<end]) + "\n[truncated]"
            }
            return message
        }
    }
}
