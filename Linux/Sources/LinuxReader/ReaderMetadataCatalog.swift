import Foundation
import VellumCore

public struct ReaderDocumentMetadata: Sendable {
    public let storageKey: String?
    public let displayTitle: String
    /// One-based. Legacy last_page supplies only a page and an optional page count.
    public let position: ReadingPosition?
    public var lastPage: Int? { position?.page }
    /// A regular sidecar name existed at catalog load time. Its payload is not decoded.
    public let hasInkSidecar: Bool
}

/// A library-scoped snapshot of peer positions and ink filenames. Archive listing and
/// selection supply the manifest already decoded from their own root-confined bytes.
public struct ReaderMetadataCatalog: Sendable {
    private let store: ReadOnlyLibraryFileStore
    private let peers: [DocumentKey: MergedDocumentPosition]
    private let inkKeys: Set<DocumentKey>

    @concurrent
    public static func load(in store: ReadOnlyLibraryFileStore) async throws -> Self {
        let positions = store.root.url.appendingPathComponent(".vellum/positions", isDirectory: true)
        var records: [PositionDeviceRecord] = []
        // Apple trims its device record to 512 documents. Limit decoded input retained
        // for a single merge too, so many small files cannot bypass the store's file cap.
        var remainingBytes = 32 * 1024 * 1024
        for entry in try await store.list(positions, suffix: ".json") {
            try Task.checkCancellation()
            guard !entry.url.hasDirectoryPath, let name = PositionLayout.parseFileName(entry.name),
                  name.version == PositionLayout.schemaVersion,
                  PositionLayout.fileName(for: name.device) == entry.name,
                  let bytes = try? await store.read(entry.url),
                  var record = try? name.decode(bytes),
                  name.device == record.deviceID, PositionMerge.isUsable(record) else { continue }
            guard bytes.count <= remainingBytes else { throw ReaderFileError.fileTooLarge }
            remainingBytes -= bytes.count
            // A bad page must not win over an older usable position. The other
            // independent fields in the same device record still participate.
            for (key, entry) in record.documents {
                if let position = entry.readingPosition, !usable(position.value) {
                    record.documents[key]?.readingPosition = nil
                }
            }
            records.append(record)
        }

        let directory = store.root.url.appendingPathComponent(".vellum/records", isDirectory: true)
        let suffix = ".ink.json"
        var inkKeys = Set<DocumentKey>()
        for entry in try await store.list(directory, suffix: suffix) {
            try Task.checkCancellation()
            if !entry.url.hasDirectoryPath, let key = DocumentKey(rawValue: "web:" + entry.name.dropLast(suffix.count)) {
                inkKeys.insert(key)
            }
        }
        try Task.checkCancellation()
        return Self(store: store, peers: PositionMerge.merge(records), inkKeys: inkKeys)
    }

    /// Apple opens an archive by normalizing manifest.url. Neither canonical_url, the
    /// archive filename nor text from a sidecar is used as a path or a second identity.
    @concurrent
    public func web(manifest: ArchiveManifest, fallbackTitle: String) async throws -> ReaderDocumentMetadata {
        try Task.checkCancellation()
        let key = Self.webKey(manifest.url)
        var record: WebPageRecord?
        if let key {
            let url = store.root.url.appendingPathComponent(".vellum/records/\(key.hash).json", isDirectory: false)
            if let bytes = try? await store.read(url),
               let decoded = try? JSONDecoder().decode(WebPageRecord.self, from: bytes),
               Self.webKey(decoded.url) == key {
                record = decoded
            }
        }
        try Task.checkCancellation()
        let peer = key.flatMap { peers[$0] }
        let recordTitle = Self.title(record?.title)
        let archiveTitle = Self.title(manifest.title)
        let manualRecord = record?.titleIsUserDefined == true ? recordTitle : nil
        // A missing flag on an old archive protects its existing title, as on Apple.
        let manualArchive = manifest.titleIsUserDefined != false ? archiveTitle : nil
        let displayTitle = manualRecord ?? manualArchive ?? recordTitle ?? archiveTitle
            ?? Self.title(peer?.title?.value) ?? fallbackTitle
        let position = peer?.readingPosition?.value
            ?? Self.legacyPosition(page: record?.lastPage, count: record?.pageCount)
            ?? Self.legacyPosition(page: manifest.lastPage, count: manifest.pageCount)
        return ReaderDocumentMetadata(storageKey: key?.hash, displayTitle: displayTitle, position: position,
                                      hasInkSidecar: key.map { inkKeys.contains($0) } ?? false)
    }

    /// Pass the existing stamp from this PDF, if known. A relocated path, basename,
    /// byte hash or metadata last_known_path cannot establish that identity.
    public func pdf(stableIdentifier: String?, fallbackTitle: String) -> ReaderDocumentMetadata {
        let key = stableIdentifier.flatMap { DocumentIdentity.isCanonicalKey($0) ? $0 : nil }
        let peer = key.flatMap { peers[.pdf(stableIdentifier: $0)] }
        return ReaderDocumentMetadata(storageKey: key,
                                      displayTitle: Self.title(peer?.title?.value) ?? fallbackTitle,
                                      position: peer?.readingPosition?.value, hasInkSidecar: false)
    }

    /// A hash fallback is usable only for the exact selected bytes with a
    /// matching S8 sidecar. Legacy resume still requires its typed stamp.
    @concurrent
    public func sharedPDF(bytes: Data, file: URL, stamp: String?,
                          fallbackTitle: String) async throws -> ReaderDocumentMetadata {
        let verified = SharedPDFIdentity.stamp(in: bytes, readerID: stamp)
        let directory = store.root.url.appendingPathComponent(".vellum/documents")
        struct Meta: Decodable {
            let kind: String
            let title: String?
            let last_known_path: String
        }
        let relative = try store.root.relativePath(to: file)
        if relative.hasPrefix("PDFs/") {
            // Older imports of these exact bytes could only use their hash.
            // Their matched sidecars and reading positions keep that identity.
            let hash = DocumentIdentity.byteHash(bytes)
            for key in [hash, verified].compactMap({ $0 }) {
                let url = directory.appendingPathComponent(key).appendingPathComponent("meta.json")
                guard let data = try await store.read(url),
                      let meta = try? JSONDecoder().decode(Meta.self, from: data),
                      meta.kind == "pdf",
                      try await matchesLocator(meta.last_known_path, selected: relative,
                                               hashBytes: key == hash ? bytes : nil) else { continue }
                let result = pdf(stableIdentifier: key, fallbackTitle: fallbackTitle)
                return ReaderDocumentMetadata(storageKey: result.storageKey, displayTitle: Self.title(meta.title) ?? result.displayTitle,
                                              position: result.position, hasInkSidecar: false)
            }
        }
        return pdf(stableIdentifier: verified, fallbackTitle: fallbackTitle)
    }

    private func matchesLocator(_ recorded: String, selected: String, hashBytes: Data?) async throws -> Bool {
        // The selected relative path has already passed shared PDF path validation.
        guard recorded == selected else { return false }
        if recorded.utf8.elementsEqual(selected.utf8) { return true }
        guard let hashBytes else { return false }

        // Linux can store both spellings. Walk directory entries by canonical
        // equivalence, retaining their actual spelling until the whole path matches.
        let parts = selected.split(separator: "/")
        var candidates = [store.root.url]
        for (index, part) in parts.enumerated() {
            var next: [URL] = []
            for directory in candidates {
                for entry in try await store.list(directory, suffix: nil)
                    where entry.name == part && entry.url.hasDirectoryPath == (index < parts.count - 1) {
                    next.append(entry.url)
                }
            }
            candidates = next
        }
        guard candidates.count == 1, let candidate = candidates.first,
              candidate.path.utf8.elementsEqual(store.root.url.appendingPathComponent(selected).path.utf8)
        else { return false }
        return try await store.read(candidate) == hashBytes
    }

    private static func webKey(_ url: String) -> DocumentKey? {
        // A stored page URL is absolute. Bound work on untrusted URL text before
        // normalization. Only the resulting fixed-length hash reaches the store.
        guard url.utf8.count <= 8192 else { return nil }
        let prefix = url.prefix(8).lowercased()
        guard prefix.hasPrefix("https://") || prefix.hasPrefix("http://"),
              let normalized = try? WebURLNormalizer.normalize(url, httpsOnly: false) else { return nil }
        return .web(normalizedURL: normalized)
    }

    static func title(_ text: String?) -> String? {
        guard let text, !text.utf8.contains(0),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static func usable(_ position: ReadingPosition) -> Bool {
        guard (1...Int(Int32.max)).contains(position.page) else { return false }
        if let count = position.pageCount, !(position.page...Int(Int32.max)).contains(count) { return false }
        if let fraction = position.scrollFraction, !(0...1).contains(fraction) { return false }
        return position.viewportOffset?.isFinite != false
    }

    private static func legacyPosition(page: Int?, count: Int?) -> ReadingPosition? {
        guard let page else { return nil }
        let position = ReadingPosition(page: page, pageCount: count)
        return usable(position) ? position : nil
    }
}
