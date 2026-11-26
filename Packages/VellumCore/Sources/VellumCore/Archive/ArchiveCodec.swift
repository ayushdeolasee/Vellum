import Foundation

// `.vellumweb` — portable, versioned ZIP archive for annotated webpages.
// Port of src-tauri/src/web_archive.rs. The entry names, JSON field names and
// `"sha256:<hex>"` hash strings are a cross-app compatibility contract; the
// compression choices (Deflate for text, Stored for precompressed media) are
// kept for size parity but readers accept any method.

public struct ManifestHashes: Codable, Sendable {
    /// "sha256:<hex>" of snapshot/index.html bytes.
    public var snapshotHtml: String
    /// "sha256:<hex>" of text/pages.json bytes.
    public var pageText: String
    /// "sha256:<hex>" of annotations.json bytes (verified on import when present).
    public var annotations: String?
    /// "sha256:<hex>" of ink.json bytes (Apple Pencil web ink; verified on
    /// import when present). Optional and additive: an archive written by a
    /// build without web ink omits it, and a reader that predates web ink
    /// decodes the manifest ignoring this unknown key — so the format version
    /// stays 1 (no hard-fail path was triggered).
    public var ink: String?

    public init(snapshotHtml: String, pageText: String, annotations: String? = nil, ink: String? = nil) {
        self.snapshotHtml = snapshotHtml
        self.pageText = pageText
        self.annotations = annotations
        self.ink = ink
    }

    enum CodingKeys: String, CodingKey {
        case snapshotHtml = "snapshot_html"
        case pageText = "page_text"
        case annotations
        case ink
    }
}

public struct ManifestAsset: Codable, Sendable {
    public var path: String
    public var url: String
    public var contentType: String
    public var bytes: Int
    public var sha256: String?

    public init(path: String, url: String, contentType: String, bytes: Int, sha256: String? = nil) {
        self.path = path
        self.url = url
        self.contentType = contentType
        self.bytes = bytes
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case path
        case url
        case contentType = "content_type"
        case bytes
        case sha256
    }
}

public struct ArchiveManifest: Codable, Sendable {
    public var format: String
    public var version: Int
    public var url: String
    public var canonicalUrl: String
    public var title: String?
    /// Nil identifies older archives whose existing names are preserved conservatively.
    public var titleIsUserDefined: Bool?
    public var capturedAt: String
    public var generator: String
    /// "live-first" (default) or "snapshot-only".
    public var loadingPolicy: String
    public var pageCount: Int?
    public var lastPage: Int?
    public var hashes: ManifestHashes
    public var assets: [ManifestAsset]
    public var assetsSkipped: Int

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case url
        case canonicalUrl = "canonical_url"
        case title
        case titleIsUserDefined = "title_is_user_defined"
        case capturedAt = "captured_at"
        case generator
        case loadingPolicy = "loading_policy"
        case pageCount = "page_count"
        case lastPage = "last_page"
        case hashes
        case assets
        case assetsSkipped = "assets_skipped"
    }

    public init(
        format: String, version: Int, url: String, canonicalUrl: String, title: String?,
        titleIsUserDefined: Bool? = nil,
        capturedAt: String, generator: String, loadingPolicy: String, pageCount: Int?,
        lastPage: Int?, hashes: ManifestHashes, assets: [ManifestAsset], assetsSkipped: Int
    ) {
        self.format = format
        self.version = version
        self.url = url
        self.canonicalUrl = canonicalUrl
        self.title = title
        self.titleIsUserDefined = titleIsUserDefined
        self.capturedAt = capturedAt
        self.generator = generator
        self.loadingPolicy = loadingPolicy
        self.pageCount = pageCount
        self.lastPage = lastPage
        self.hashes = hashes
        self.assets = assets
        self.assetsSkipped = assetsSkipped
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        url = try container.decode(String.self, forKey: .url)
        canonicalUrl = try container.decode(String.self, forKey: .canonicalUrl)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        titleIsUserDefined = try container.decodeIfPresent(Bool.self, forKey: .titleIsUserDefined)
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        generator = try container.decode(String.self, forKey: .generator)
        loadingPolicy = try container.decode(String.self, forKey: .loadingPolicy)
        pageCount = try container.decodeIfPresent(Int.self, forKey: .pageCount)
        lastPage = try container.decodeIfPresent(Int.self, forKey: .lastPage)
        hashes = try container.decode(ManifestHashes.self, forKey: .hashes)
        assets = try container.decodeIfPresent([ManifestAsset].self, forKey: .assets) ?? []
        assetsSkipped = try container.decodeIfPresent(Int.self, forKey: .assetsSkipped) ?? 0
    }
}

public struct CapturedAsset: Sendable {
    public var name: String
    public var url: String
    public var contentType: String
    public var bytes: Data

    public init(name: String, url: String, contentType: String, bytes: Data) {
        self.name = name
        self.url = url
        self.contentType = contentType
        self.bytes = bytes
    }
}

public struct DecodedWebArchive: Sendable {
    public let manifest: ArchiveManifest
    public let snapshotHtml: String
    public let assets: [(String, Data)]
    public let annotations: [Annotation]
    public let inkJSON: Data?
}

public enum ArchiveCodecError: LocalizedError {
    case invalidDocument(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDocument(let detail), .io(let detail): return detail
        }
    }
}

public enum ArchiveCodec {
    public static let maxSnapshotBytes = 25 * 1024 * 1024
    public static let formatName = "vellumweb"
    public static let formatVersion = 1

    public static let maxAssets = 80
    public static let maxAssetBytes = 8 * 1024 * 1024
    public static let maxTotalAssetBytes = 64 * 1024 * 1024
    public static let maxManifestBytes = 4 * 1024 * 1024
    public static let maxAnnotationsBytes = 32 * 1024 * 1024
    public static let maxInkBytes = 32 * 1024 * 1024

    // Existing payload budgets, including worst-case JSON escaping of extracted
    // page text (six bytes per source byte), plus ZIP/compression overhead.
    public static let maxTotalUncompressedBytes = maxManifestBytes + maxAnnotationsBytes + maxInkBytes
        + 7 * maxSnapshotBytes + maxTotalAssetBytes
    public static let maxArchiveBytes = maxTotalUncompressedBytes + 8 * 1024 * 1024
    public static let maxEntries = maxAssets + 5

    private static func openArchive(at path: URL) throws -> MiniZip {
        try MiniZip(contentsOf: path, maxBytes: maxArchiveBytes,
                    maxEntries: maxEntries, maxUncompressedBytes: maxTotalUncompressedBytes)
    }

    public static func sha256Hex(_ bytes: Data) -> String {
        "sha256:" + DocumentIdentity.byteHash(bytes)
    }

    /// Media whose container is already compressed: Stored, not recompressed.
    public static func isPrecompressed(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "avif", "woff", "woff2"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    public static func encode(
        manifest: ArchiveManifest,
        snapshotHtml: String,
        assets: [CapturedAsset],
        pagesJson: Data,
        annotations: [Annotation],
        inkJson: Data? = nil
    ) throws -> Data {
        let annotationsJson: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            annotationsJson = try encoder.encode(annotations)
        } catch {
            throw ArchiveCodecError.io(
                "Failed to serialize annotations: \(error.localizedDescription)")
        }
        var manifest = manifest
        manifest.hashes.annotations = sha256Hex(annotationsJson)
        manifest.hashes.ink = inkJson.map(sha256Hex)
        let manifestJson: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            manifestJson = try encoder.encode(manifest)
        } catch {
            throw ArchiveCodecError.io("Failed to serialize manifest: \(error.localizedDescription)")
        }

        var entries: [MiniZip.Entry] = [
            MiniZip.Entry(name: "manifest.json", data: manifestJson, stored: false),
            MiniZip.Entry(name: "snapshot/index.html", data: Data(snapshotHtml.utf8), stored: false),
        ]
        for asset in assets {
            entries.append(MiniZip.Entry(
                name: "snapshot/assets/\(asset.name)",
                data: asset.bytes,
                stored: isPrecompressed(asset.name)))
        }
        entries.append(MiniZip.Entry(name: "text/pages.json", data: pagesJson, stored: false))
        entries.append(MiniZip.Entry(name: "annotations.json", data: annotationsJson, stored: false))
        if let inkJson {
            entries.append(MiniZip.Entry(name: "ink.json", data: inkJson, stored: false))
        }

        let zipData: Data
        do {
            zipData = try MiniZip.write(entries: entries)
        } catch {
            throw ArchiveCodecError.io("Failed to write archive: \(error.localizedDescription)")
        }
        return zipData
    }

    /// Only bare file names are allowed for assets (zip-slip guard).
    public static func safeAssetName(_ name: String) -> String? {
        if name.isEmpty || name.contains("..") || name.contains("/") || name.contains("\\")
            || name.hasPrefix(".") {
            return nil
        }
        return name
    }

    public static func readManifest(at path: URL) throws -> ArchiveManifest {
        let zip = try openArchive(at: path)
        return try readManifest(from: zip)
    }

    public static func readManifest(data: Data) throws -> ArchiveManifest {
        try readManifest(from: MiniZip(
            data: data, maxBytes: maxArchiveBytes, maxEntries: maxEntries,
            maxUncompressedBytes: maxTotalUncompressedBytes))
    }

    private static func readManifest(from zip: MiniZip) throws -> ArchiveManifest {
        let manifestBytes = try zip.readCapped("manifest.json", cap: maxManifestBytes)
        let manifest: ArchiveManifest
        do {
            manifest = try JSONDecoder().decode(ArchiveManifest.self, from: manifestBytes)
        } catch {
            throw ArchiveCodecError.invalidDocument(
                "Invalid archive manifest: \(error.localizedDescription)")
        }
        if manifest.format != formatName {
            throw ArchiveCodecError.invalidDocument(
                "Not a .vellumweb archive (wrong format marker)")
        }
        if manifest.version > formatVersion {
            throw ArchiveCodecError.invalidDocument(
                "This archive uses format version \(manifest.version) — please update Vellum")
        }
        return manifest
    }

    public static func decode(at path: URL) throws -> DecodedWebArchive {
        try decode(from: openArchive(at: path))
    }

    /// Decode bytes obtained through coordinated storage with the same limits
    /// and integrity checks as a file import.
    public static func decode(_ data: Data) throws -> DecodedWebArchive {
        try decode(from: MiniZip(
            data: data, maxBytes: maxArchiveBytes, maxEntries: maxEntries,
            maxUncompressedBytes: maxTotalUncompressedBytes))
    }

    private static func decode(from zip: MiniZip) throws -> DecodedWebArchive {
        let manifest = try readManifest(from: zip)

        let snapshotBytes = try zip.readCapped(
            "snapshot/index.html", cap: maxSnapshotBytes)
        if sha256Hex(snapshotBytes) != manifest.hashes.snapshotHtml {
            throw ArchiveCodecError.invalidDocument(
                "Archive snapshot failed its integrity check (corrupted file?)")
        }
        let snapshotHtml = String(decoding: snapshotBytes, as: UTF8.self)

        var annotations: [Annotation] = []
        if zip.contains("annotations.json") {
            let buf = try zip.readCapped("annotations.json", cap: maxAnnotationsBytes)
            do {
                annotations = try JSONDecoder().decode([Annotation].self, from: buf)
            } catch {
                throw ArchiveCodecError.invalidDocument(
                    "Invalid annotations in archive: \(error.localizedDescription)")
            }
            if let expected = manifest.hashes.annotations, sha256Hex(buf) != expected {
                throw ArchiveCodecError.invalidDocument(
                    "Archive annotations failed their integrity check (corrupted file?)")
            }
        }

        var inkJSON: Data?
        if manifest.hashes.ink != nil && !zip.contains("ink.json") {
            throw ArchiveCodecError.invalidDocument("Archive is missing its ink data")
        }
        if zip.contains("ink.json") {
            let buf = try zip.readCapped("ink.json", cap: maxInkBytes)
            if let expected = manifest.hashes.ink, sha256Hex(buf) != expected {
                throw ArchiveCodecError.invalidDocument(
                    "Archive ink failed its integrity check (corrupted file?)")
            }
            inkJSON = buf
        }

        var assetNames: [String] = []
        for entryName in zip.entryNames where entryName.hasPrefix("snapshot/assets/") {
            let rest = String(entryName.dropFirst("snapshot/assets/".count))
            if let safe = safeAssetName(rest) {
                assetNames.append(safe)
            }
        }
        var assets: [(String, Data)] = []
        var totalAssetBytes = 0
        for name in assetNames {
            let entryPath = "snapshot/assets/\(name)"
            let bytes = try zip.readCapped(entryPath, cap: maxAssetBytes)
            totalAssetBytes += bytes.count
            if totalAssetBytes > maxTotalAssetBytes {
                throw ArchiveCodecError.invalidDocument(
                    "Archive assets exceed the total size limit")
            }
            if let expected = manifest.assets.first(where: { $0.path == entryPath })?.sha256,
               sha256Hex(bytes) != expected {
                throw ArchiveCodecError.invalidDocument(
                    "Archive asset \(name) failed its integrity check")
            }
            assets.append((name, bytes))
        }

        return DecodedWebArchive(
            manifest: manifest,
            snapshotHtml: snapshotHtml,
            assets: assets,
            annotations: annotations,
            inkJSON: inkJSON)
    }
}
