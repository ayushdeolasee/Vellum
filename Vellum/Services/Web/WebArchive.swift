import Compression
import CryptoKit
import Foundation

// `.vellumweb` — portable, versioned ZIP archive for annotated webpages.
// Port of src-tauri/src/web_archive.rs. The entry names, JSON field names and
// `"sha256:<hex>"` hash strings are a cross-app compatibility contract; the
// compression choices (Deflate for text, Stored for precompressed media) are
// kept for size parity but readers accept any method.

struct ManifestHashes: Codable, Sendable {
    /// "sha256:<hex>" of snapshot/index.html bytes.
    var snapshotHtml: String
    /// "sha256:<hex>" of text/pages.json bytes.
    var pageText: String
    /// "sha256:<hex>" of annotations.json bytes (verified on import when present).
    var annotations: String?

    enum CodingKeys: String, CodingKey {
        case snapshotHtml = "snapshot_html"
        case pageText = "page_text"
        case annotations
    }
}

struct ManifestAsset: Codable, Sendable {
    var path: String
    var url: String
    var contentType: String
    var bytes: Int
    var sha256: String?

    enum CodingKeys: String, CodingKey {
        case path
        case url
        case contentType = "content_type"
        case bytes
        case sha256
    }
}

struct ArchiveManifest: Codable, Sendable {
    var format: String
    var version: Int
    var url: String
    var canonicalUrl: String
    var title: String?
    var capturedAt: String
    var generator: String
    /// "live-first" (default) or "snapshot-only".
    var loadingPolicy: String
    var pageCount: Int?
    var lastPage: Int?
    var hashes: ManifestHashes
    var assets: [ManifestAsset]
    var assetsSkipped: Int

    enum CodingKeys: String, CodingKey {
        case format
        case version
        case url
        case canonicalUrl = "canonical_url"
        case title
        case capturedAt = "captured_at"
        case generator
        case loadingPolicy = "loading_policy"
        case pageCount = "page_count"
        case lastPage = "last_page"
        case hashes
        case assets
        case assetsSkipped = "assets_skipped"
    }

    init(
        format: String, version: Int, url: String, canonicalUrl: String, title: String?,
        capturedAt: String, generator: String, loadingPolicy: String, pageCount: Int?,
        lastPage: Int?, hashes: ManifestHashes, assets: [ManifestAsset], assetsSkipped: Int
    ) {
        self.format = format
        self.version = version
        self.url = url
        self.canonicalUrl = canonicalUrl
        self.title = title
        self.capturedAt = capturedAt
        self.generator = generator
        self.loadingPolicy = loadingPolicy
        self.pageCount = pageCount
        self.lastPage = lastPage
        self.hashes = hashes
        self.assets = assets
        self.assetsSkipped = assetsSkipped
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        url = try container.decode(String.self, forKey: .url)
        canonicalUrl = try container.decode(String.self, forKey: .canonicalUrl)
        title = try container.decodeIfPresent(String.self, forKey: .title)
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

struct CapturedAsset: Sendable {
    var name: String
    var url: String
    var contentType: String
    var bytes: Data
}

struct CapturedSnapshot: Sendable {
    var html: String
    var assets: [CapturedAsset]
    var skipped: Int
}

struct ImportedArchive: Sendable {
    var manifest: ArchiveManifest
    var snapshotHtml: String
    var assets: [(String, Data)]
    var annotations: [Annotation]
}

/// One page of text inside `text/pages.json` (`{"number":1,"text":"…"}`).
private struct PageTextEntry: Codable {
    var number: Int
    var text: String
}

enum WebArchive {
    static let formatName = "vellumweb"
    static let formatVersion = 1

    static let maxAssets = 80
    static let maxAssetBytes = 8 * 1024 * 1024
    static let maxTotalAssetBytes = 64 * 1024 * 1024
    static let maxManifestBytes = 4 * 1024 * 1024
    static let maxAnnotationsBytes = 32 * 1024 * 1024

    static let assetPlaceholder = "__VELLUM_ASSET__"

    static func sha256Hex(_ bytes: Data) -> String {
        let digest = SHA256.hash(data: bytes)
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Snapshot sanitizing & asset capture

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Compile-time constant patterns; force-try is safe.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    nonisolated(unsafe) private static let scriptRegex = regex(
        #"<script\b[^>]*>.*?</script\s*>|<script\b[^>]*/>"#)
    nonisolated(unsafe) private static let preloadRegex = regex(
        #"<link\b[^>]*rel\s*=\s*["']?(?:preload|prefetch|modulepreload|dns-prefetch|preconnect)["']?[^>]*>"#)
    nonisolated(unsafe) private static let attrStripRegex = regex(
        #"\s(?:srcset|sizes|integrity|crossorigin)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#)
    nonisolated(unsafe) private static let imgSrcRegex = regex(
        #"<img\b[^>]*?\ssrc\s*=\s*["']([^"']+)["']"#)
    nonisolated(unsafe) private static let linkTagRegex = regex(#"<link\b[^>]*>"#)
    nonisolated(unsafe) private static let hrefRegex = regex(#"\bhref\s*=\s*["']([^"']+)["']"#)
    nonisolated(unsafe) private static let stylesheetRelRegex = regex(
        #"\brel\s*=\s*["']?stylesheet["']?"#)
    nonisolated(unsafe) private static let cssUrlRegex = regex(
        #"url\(\s*['"]?([^'")]+)['"]?\s*\)|@import\s+['"]([^'"]+)['"]"#)

    private static func replaceAll(_ regex: NSRegularExpression, in text: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    /// Strip scripts, preload hints, and per-response attributes that either
    /// bloat the archive or break once assets are served locally.
    static func sanitizeSnapshotHtml(_ html: String) -> String {
        var out = replaceAll(scriptRegex, in: html)
        out = replaceAll(preloadRegex, in: out)
        out = replaceAll(attrStripRegex, in: out)
        return out
    }

    /// Collect capturable asset URLs (img src first, then stylesheet href), in
    /// document order, deduplicated by raw value, resolved against the page URL.
    static func collectAssetUrls(html: String, pageUrl: String) -> [(raw: String, abs: String)] {
        guard let base = URL(string: pageUrl) else { return [] }
        var seen: Set<String> = []
        var out: [(String, String)] = []

        func push(_ rawValue: String) {
            let raw = rawValue.trimmingCharacters(in: .whitespaces)
            if raw.isEmpty || raw.hasPrefix("data:") || raw.hasPrefix("#") { return }
            guard let abs = URL(string: raw, relativeTo: base)?.absoluteURL,
                  abs.scheme == "http" || abs.scheme == "https" else { return }
            if seen.insert(raw).inserted {
                out.append((raw, abs.absoluteString))
            }
        }

        let ns = html as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in imgSrcRegex.matches(in: html, range: full) where match.numberOfRanges > 1 {
            push(ns.substring(with: match.range(at: 1)))
        }
        for tagMatch in linkTagRegex.matches(in: html, range: full) {
            let tag = ns.substring(with: tagMatch.range)
            let tagNs = tag as NSString
            let tagRange = NSRange(location: 0, length: tagNs.length)
            guard stylesheetRelRegex.firstMatch(in: tag, range: tagRange) != nil else { continue }
            if let href = hrefRegex.firstMatch(in: tag, range: tagRange), href.numberOfRanges > 1 {
                push(tagNs.substring(with: href.range(at: 1)))
            }
        }
        return out
    }

    /// Rewrite `url(...)` / `@import` refs inside captured CSS to absolute
    /// URLs so they still resolve when the stylesheet is served locally.
    static func absolutizeCss(_ css: String, cssUrl: String) -> String {
        guard let base = URL(string: cssUrl) else { return css }
        let ns = css as NSString
        var out = ""
        var cursor = 0
        for match in cssUrlRegex.matches(in: css, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let whole = ns.substring(with: match.range)
            var reference = ""
            if match.range(at: 1).location != NSNotFound {
                reference = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            } else if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound {
                reference = ns.substring(with: match.range(at: 2)).trimmingCharacters(in: .whitespaces)
            }
            if reference.isEmpty || reference.hasPrefix("data:") || reference.hasPrefix("#") {
                out += whole
            } else if let abs = URL(string: reference, relativeTo: base)?.absoluteURL,
                      abs.scheme == "http" || abs.scheme == "https" {
                if whole.lowercased().hasPrefix("@import") {
                    out += "@import \"\(abs.absoluteString)\""
                } else {
                    out += "url(\"\(abs.absoluteString)\")"
                }
            } else {
                out += whole
            }
            cursor = match.range.location + match.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func extensionFor(contentType: String, url: String) -> String {
        let ct = contentType.split(separator: ";").first.map {
            $0.trimmingCharacters(in: .whitespaces).lowercased()
        } ?? ""
        switch ct {
        case "text/css": return "css"
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/avif": return "avif"
        case "image/svg+xml": return "svg"
        case "image/x-icon", "image/vnd.microsoft.icon": return "ico"
        case "font/woff2": return "woff2"
        case "font/woff", "application/font-woff": return "woff"
        case "font/ttf": return "ttf"
        case "font/otf": return "otf"
        default: break
        }
        let pathExt = URL(string: url)?.pathExtension.lowercased() ?? ""
        switch pathExt {
        case "css", "png", "gif", "webp", "avif", "svg", "ico", "woff2", "woff", "ttf", "otf":
            return pathExt
        case "jpg", "jpeg":
            return "jpg"
        default:
            return "bin"
        }
    }

    static func contentTypeForName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "css": return "text/css"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "html": return "text/html; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    /// Media whose container is already compressed: Stored, not recompressed.
    static func isPrecompressed(_ name: String) -> Bool {
        ["png", "jpg", "jpeg", "gif", "webp", "avif", "woff", "woff2"]
            .contains((name as NSString).pathExtension.lowercased())
    }

    /// Sanitize + capture subresources for a fetched page. Asset references in
    /// the returned HTML point at `__VELLUM_ASSET__/<name>` placeholders.
    static func captureSnapshot(pageUrl: String, rawHtml: String) async -> CapturedSnapshot {
        var html = sanitizeSnapshotHtml(rawHtml)
        let targets = collectAssetUrls(html: html, pageUrl: pageUrl)

        var assets: [CapturedAsset] = []
        var skipped = 0
        var totalBytes = 0

        for (rawRef, absUrl) in targets {
            if assets.count >= maxAssets || totalBytes >= maxTotalAssetBytes {
                skipped += 1
                continue
            }
            guard let fetched = await WebFetch.fetchAsset(absUrl) else {
                skipped += 1
                continue
            }
            var bytes = fetched.body
            let ext = extensionFor(contentType: fetched.contentType, url: absUrl)
            if ext == "css" {
                let css = String(decoding: bytes, as: UTF8.self)
                bytes = Data(absolutizeCss(css, cssUrl: absUrl).utf8)
            }
            let name = "a\(assets.count).\(ext)"
            let placeholder = "\(assetPlaceholder)/\(name)"
            html = html
                .replacingOccurrences(of: "\"\(rawRef)\"", with: "\"\(placeholder)\"")
                .replacingOccurrences(of: "'\(rawRef)'", with: "'\(placeholder)'")
            totalBytes += bytes.count
            assets.append(CapturedAsset(
                name: name, url: absUrl, contentType: fetched.contentType, bytes: bytes))
        }

        return CapturedSnapshot(html: html, assets: assets, skipped: skipped)
    }

    // MARK: - Manifest

    static func buildManifest(
        url: String,
        title: String?,
        pageCount: Int?,
        lastPage: Int?,
        loadingPolicy: String,
        snapshotHtml: String,
        pagesJson: Data,
        assets: [CapturedAsset],
        assetsSkipped: Int
    ) -> ArchiveManifest {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.1.0"
        return ArchiveManifest(
            format: formatName,
            version: formatVersion,
            url: url,
            canonicalUrl: url,
            title: title,
            capturedAt: WebLibrary.rfc3339Now(),
            generator: "Vellum \(version)",
            loadingPolicy: loadingPolicy,
            pageCount: pageCount,
            lastPage: lastPage,
            hashes: ManifestHashes(
                snapshotHtml: sha256Hex(Data(snapshotHtml.utf8)),
                pageText: sha256Hex(pagesJson),
                annotations: nil // filled in by writeArchive
            ),
            assets: assets.map { asset in
                ManifestAsset(
                    path: "snapshot/assets/\(asset.name)",
                    url: asset.url,
                    contentType: asset.contentType,
                    bytes: asset.bytes.count,
                    sha256: sha256Hex(asset.bytes))
            },
            assetsSkipped: assetsSkipped
        )
    }

    static func encodePagesJson(_ pages: [WebPageText]) throws -> Data {
        do {
            return try WebLibrary.jsonEncoderCompact.encode(
                pages.map { PageTextEntry(number: $0.number, text: $0.text) })
        } catch {
            throw SessionServiceError.io("Failed to serialize page text: \(error.localizedDescription)")
        }
    }

    // MARK: - Archive write / read

    /// Write the archive atomically: pack into a temp file next to `dest`,
    /// sync, then rename over the destination. Returns the archive byte size.
    static func writeArchive(
        to dest: URL,
        manifest: ArchiveManifest,
        snapshotHtml: String,
        assets: [CapturedAsset],
        pagesJson: Data,
        annotations: [Annotation]
    ) throws -> Int {
        let parent = dest.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io(
                "Failed to create destination dir: \(error.localizedDescription)")
        }

        let annotationsJson: Data
        do {
            annotationsJson = try WebLibrary.jsonEncoderCompact.encode(annotations)
        } catch {
            throw SessionServiceError.io(
                "Failed to serialize annotations: \(error.localizedDescription)")
        }
        var manifest = manifest
        manifest.hashes.annotations = sha256Hex(annotationsJson)
        let manifestJson: Data
        do {
            manifestJson = try WebLibrary.jsonEncoderPretty.encode(manifest)
        } catch {
            throw SessionServiceError.io("Failed to serialize manifest: \(error.localizedDescription)")
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

        let zipData: Data
        do {
            zipData = try MiniZip.write(entries: entries)
        } catch {
            throw SessionServiceError.io("Failed to write archive: \(error.localizedDescription)")
        }

        // Unique per operation: concurrent writers to the same destination
        // must not share a temp file.
        let fileName = dest.lastPathComponent
        let tmp = parent.appendingPathComponent(
            ".\(fileName).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())")
        do {
            try zipData.write(to: tmp)
            let handle = try FileHandle(forWritingTo: tmp)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to create archive: \(error.localizedDescription)")
        }
        guard rename(tmp.path, dest.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw SessionServiceError.io("Failed to move archive into place: rename failed")
        }
        return zipData.count
    }

    /// Only bare file names are allowed for assets (zip-slip guard).
    static func safeAssetName(_ name: String) -> String? {
        if name.isEmpty || name.contains("..") || name.contains("/") || name.contains("\\")
            || name.hasPrefix(".") {
            return nil
        }
        return name
    }

    static func readArchive(at path: URL) throws -> ImportedArchive {
        let zip = try MiniZip(contentsOf: path)

        let manifestBytes = try zip.readCapped("manifest.json", cap: maxManifestBytes)
        let manifest: ArchiveManifest
        do {
            manifest = try JSONDecoder().decode(ArchiveManifest.self, from: manifestBytes)
        } catch {
            throw SessionServiceError.invalidDocument(
                "Invalid archive manifest: \(error.localizedDescription)")
        }
        if manifest.format != formatName {
            throw SessionServiceError.invalidDocument(
                "Not a .vellumweb archive (wrong format marker)")
        }
        if manifest.version > formatVersion {
            throw SessionServiceError.invalidDocument(
                "This archive uses format version \(manifest.version) — please update Vellum")
        }

        let snapshotBytes = try zip.readCapped(
            "snapshot/index.html", cap: WebFetch.maxResponseBytes)
        if sha256Hex(snapshotBytes) != manifest.hashes.snapshotHtml {
            throw SessionServiceError.invalidDocument(
                "Archive snapshot failed its integrity check (corrupted file?)")
        }
        let snapshotHtml = String(decoding: snapshotBytes, as: UTF8.self)

        var annotations: [Annotation] = []
        if zip.contains("annotations.json") {
            let buf = try zip.readCapped("annotations.json", cap: maxAnnotationsBytes)
            do {
                annotations = try JSONDecoder().decode([Annotation].self, from: buf)
            } catch {
                throw SessionServiceError.invalidDocument(
                    "Invalid annotations in archive: \(error.localizedDescription)")
            }
            if let expected = manifest.hashes.annotations, sha256Hex(buf) != expected {
                throw SessionServiceError.invalidDocument(
                    "Archive annotations failed their integrity check (corrupted file?)")
            }
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
                throw SessionServiceError.invalidDocument(
                    "Archive assets exceed the total size limit")
            }
            if let expected = manifest.assets.first(where: { $0.path == entryPath })?.sha256,
               sha256Hex(bytes) != expected {
                throw SessionServiceError.invalidDocument(
                    "Archive asset \(name) failed its integrity check")
            }
            assets.append((name, bytes))
        }

        return ImportedArchive(
            manifest: manifest,
            snapshotHtml: snapshotHtml,
            assets: assets,
            annotations: annotations)
    }

    // MARK: - Local self-contained snapshot dir (archives/<key>/)

    /// Install snapshot + assets into `archives/<key>/` via a staged dir and
    /// rename-aside swap so a failed install leaves the previous snapshot
    /// intact and concurrent readers never see a missing dir.
    static func installArchiveDir(
        key: String,
        snapshotHtml: String,
        assets: [(String, Data)],
        manifest: ArchiveManifest?
    ) throws {
        let fm = FileManager.default
        let finalDir = WebLibrary.archiveDir(forKey: key)
        let opId = UUID().uuidString.lowercased()
        let parent = finalDir.deletingLastPathComponent()
        let staging = parent.appendingPathComponent("\(key).staging-\(opId)", isDirectory: true)
        let aside = parent.appendingPathComponent("\(key).old-\(opId)", isDirectory: true)

        do {
            try fm.createDirectory(
                at: staging.appendingPathComponent("assets", isDirectory: true),
                withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io("Failed to stage snapshot dir: \(error.localizedDescription)")
        }
        do {
            do {
                try Data(snapshotHtml.utf8)
                    .write(to: staging.appendingPathComponent("snapshot.html"))
            } catch {
                throw SessionServiceError.io("Failed to write snapshot: \(error.localizedDescription)")
            }
            for (name, bytes) in assets {
                guard let safe = safeAssetName(name) else { continue }
                do {
                    try bytes.write(
                        to: staging.appendingPathComponent("assets").appendingPathComponent(safe))
                } catch {
                    throw SessionServiceError.io("Failed to write asset: \(error.localizedDescription)")
                }
            }
            if let manifest {
                let json: Data
                do {
                    json = try WebLibrary.jsonEncoderPretty.encode(manifest)
                } catch {
                    throw SessionServiceError.io(
                        "Failed to serialize manifest: \(error.localizedDescription)")
                }
                do {
                    try json.write(to: staging.appendingPathComponent("manifest.json"))
                } catch {
                    throw SessionServiceError.io("Failed to write manifest: \(error.localizedDescription)")
                }
            }
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }

        // Swap: move the current dir aside (not delete), move staging in,
        // then clean up. On failure, restore the previous dir.
        let hadPrevious = fm.fileExists(atPath: finalDir.path)
            && rename(finalDir.path, aside.path) == 0
        if rename(staging.path, finalDir.path) == 0 {
            if hadPrevious {
                try? fm.removeItem(at: aside)
            }
        } else {
            if hadPrevious {
                _ = rename(aside.path, finalDir.path)
            }
            try? fm.removeItem(at: staging)
            throw SessionServiceError.io("Failed to install snapshot dir: rename failed")
        }
    }

    /// Load a previously installed self-contained snapshot, if present.
    static func loadArchiveDir(key: String) -> (html: String, assets: [(String, Data)])? {
        let dir = WebLibrary.archiveDir(forKey: key)
        guard let html = try? String(
            contentsOf: dir.appendingPathComponent("snapshot.html"), encoding: .utf8) else {
            return nil
        }
        var assets: [(String, Data)] = []
        let assetsDir = dir.appendingPathComponent("assets")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: assetsDir.path) {
            for name in names {
                if let bytes = try? Data(contentsOf: assetsDir.appendingPathComponent(name)) {
                    assets.append((name, bytes))
                }
            }
        }
        return (html, assets)
    }

    /// `__VELLUM_ASSET__/<name>` → `<asset base>/<name>` for serving.
    static func resolveAssetPlaceholders(_ html: String, assetBase: String) -> String {
        var base = assetBase
        while base.hasSuffix("/") { base.removeLast() }
        return html.replacingOccurrences(of: "\(assetPlaceholder)/", with: "\(base)/")
    }

    // MARK: - Annotation merge

    /// Merge imported annotations into the sidecar's list. Same-id conflicts
    /// keep the newer `updated_at`. Returns how many were added or replaced.
    @discardableResult
    static func mergeAnnotations(_ existing: inout [Annotation], incoming: [Annotation]) -> Int {
        var changed = 0
        for annotation in incoming {
            if let index = existing.firstIndex(where: { $0.id == annotation.id }) {
                if newerThan(annotation.updatedAt, existing[index].updatedAt) {
                    existing[index] = annotation
                    changed += 1
                }
            } else {
                existing.append(annotation)
                changed += 1
            }
        }
        return changed
    }

    static func newerThan(_ a: String, _ b: String) -> Bool {
        if let dateA = parseRfc3339(a), let dateB = parseRfc3339(b) {
            return dateA > dateB
        }
        return a > b // lexical fallback (same generator format)
    }

    private static func parseRfc3339(_ value: String) -> Date? {
        if let date = ISO8601DateFormatter.recentTimestamp.date(from: value) {
            return date
        }
        return wholeSecondFormatter.date(from: value)
    }

    nonisolated(unsafe) private static let wholeSecondFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Minimal ZIP container codec

/// Just enough ZIP to write and read `.vellumweb` archives: Stored and
/// Deflate entries, central directory, no zip64 (archives are size-capped far
/// below 4 GiB). Read paths enforce decompressed-size caps *during* inflation
/// so a crafted archive can't inflate a bomb.
struct MiniZip {
    struct Entry {
        var name: String
        var data: Data
        var stored: Bool
    }

    struct SizeLimitExceeded: Error {}

    // MARK: Writing

    static func write(entries: [Entry]) throws -> Data {
        var out = Data()
        var central = Data()
        let (dosTime, dosDate) = dosDateTime(Date())

        for entry in entries {
            let nameBytes = Data(entry.name.utf8)
            let crc = crc32(entry.data)
            let method: UInt16
            let payload: Data
            if entry.stored {
                method = 0
                payload = entry.data
            } else {
                method = 8
                payload = try deflate(entry.data)
            }
            let offset = UInt32(out.count)

            // Local file header
            out.appendUInt32(0x0403_4b50)
            out.appendUInt16(20)        // version needed
            out.appendUInt16(0)         // flags
            out.appendUInt16(method)
            out.appendUInt16(dosTime)
            out.appendUInt16(dosDate)
            out.appendUInt32(crc)
            out.appendUInt32(UInt32(payload.count))
            out.appendUInt32(UInt32(entry.data.count))
            out.appendUInt16(UInt16(nameBytes.count))
            out.appendUInt16(0)         // extra length
            out.append(nameBytes)
            out.append(payload)

            // Central directory record
            central.appendUInt32(0x0201_4b50)
            central.appendUInt16(20)    // version made by
            central.appendUInt16(20)    // version needed
            central.appendUInt16(0)     // flags
            central.appendUInt16(method)
            central.appendUInt16(dosTime)
            central.appendUInt16(dosDate)
            central.appendUInt32(crc)
            central.appendUInt32(UInt32(payload.count))
            central.appendUInt32(UInt32(entry.data.count))
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0)     // extra length
            central.appendUInt16(0)     // comment length
            central.appendUInt16(0)     // disk number start
            central.appendUInt16(0)     // internal attributes
            central.appendUInt32(0)     // external attributes
            central.appendUInt32(offset)
            central.append(nameBytes)
        }

        let centralOffset = UInt32(out.count)
        out.append(central)
        // End of central directory
        out.appendUInt32(0x0605_4b50)
        out.appendUInt16(0)
        out.appendUInt16(0)
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt16(UInt16(entries.count))
        out.appendUInt32(UInt32(central.count))
        out.appendUInt32(centralOffset)
        out.appendUInt16(0)
        return out
    }

    // MARK: Reading

    private struct CentralEntry {
        var method: UInt16
        var compressedSize: Int
        var uncompressedSize: Int
        var localHeaderOffset: Int
    }

    private let data: Data
    private let entries: [String: CentralEntry]
    private let orderedNames: [String]

    var entryNames: [String] { orderedNames }

    /// Number of entries the central directory declares.
    var entryCount: Int { orderedNames.count }

    /// Sum of every entry's DECLARED uncompressed size. Attacker-controlled in a
    /// shared archive, so a caller uses it only as a pre-parse budget gate — never
    /// as ground truth (`readCapped` re-checks each entry while inflating).
    var totalDeclaredUncompressedSize: Int {
        entries.values.reduce(0) { $0 + $1.uncompressedSize }
    }

    func contains(_ name: String) -> Bool { entries[name] != nil }

    init(contentsOf path: URL) throws {
        do {
            data = try Data(contentsOf: path)
        } catch {
            throw SessionServiceError.io("Failed to open archive: \(error.localizedDescription)")
        }
        do {
            (entries, orderedNames) = try Self.parseCentralDirectory(data)
        } catch let error as SessionServiceError {
            throw error
        } catch {
            throw SessionServiceError.invalidDocument(
                "Not a valid .vellumweb archive: \(error.localizedDescription)")
        }
    }

    private static func invalid(_ detail: String) -> SessionServiceError {
        .invalidDocument("Not a valid .vellumweb archive: \(detail)")
    }

    private static func parseCentralDirectory(
        _ data: Data
    ) throws -> ([String: CentralEntry], [String]) {
        let bytes = [UInt8](data)
        guard bytes.count >= 22 else { throw invalid("file too small") }
        // Find the End of Central Directory record (scan back past a comment).
        var eocd = -1
        let scanStart = max(0, bytes.count - 22 - 65535)
        var i = bytes.count - 22
        while i >= scanStart {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4b, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { throw invalid("end of central directory not found") }

        func u16(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        }
        func u32(_ offset: Int) -> Int {
            Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
                | Int(bytes[offset + 2]) << 16 | Int(bytes[offset + 3]) << 24
        }

        let entryCount = u16(eocd + 10)
        var cursor = u32(eocd + 16)
        var entries: [String: CentralEntry] = [:]
        var names: [String] = []
        for _ in 0..<entryCount {
            guard cursor + 46 <= bytes.count, u32(cursor) == 0x0201_4b50 else {
                throw invalid("bad central directory record")
            }
            let method = UInt16(u16(cursor + 10))
            let compressedSize = u32(cursor + 20)
            let uncompressedSize = u32(cursor + 24)
            let nameLen = u16(cursor + 28)
            let extraLen = u16(cursor + 30)
            let commentLen = u16(cursor + 32)
            let localOffset = u32(cursor + 42)
            guard cursor + 46 + nameLen <= bytes.count else {
                throw invalid("bad central directory record")
            }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLen)], as: UTF8.self)
            if entries[name] == nil { names.append(name) }
            entries[name] = CentralEntry(
                method: method,
                compressedSize: compressedSize,
                uncompressedSize: uncompressedSize,
                localHeaderOffset: localOffset)
            cursor += 46 + nameLen + extraLen + commentLen
        }
        return (entries, names)
    }

    /// Read one entry with a hard decompressed-size cap. Size fields are
    /// attacker-controlled in a shared archive, so they gate early but the
    /// cap is enforced again while inflating.
    func readCapped(_ name: String, cap: Int) throws -> Data {
        guard let entry = entries[name] else {
            throw SessionServiceError.invalidDocument("Archive is missing \(name)")
        }
        if entry.uncompressedSize > cap {
            throw SessionServiceError.invalidDocument(
                "Archive entry \(name) exceeds its size limit")
        }
        let bytes = data
        let offset = entry.localHeaderOffset
        guard offset + 30 <= bytes.count else {
            throw SessionServiceError.invalidDocument("Failed to read \(name): bad local header")
        }
        func u16(_ at: Int) -> Int {
            Int(bytes[bytes.startIndex + at]) | Int(bytes[bytes.startIndex + at + 1]) << 8
        }
        func u32(_ at: Int) -> Int {
            u16(at) | u16(at + 2) << 16
        }
        guard u32(offset) == 0x0403_4b50 else {
            throw SessionServiceError.invalidDocument("Failed to read \(name): bad local header")
        }
        let nameLen = u16(offset + 26)
        let extraLen = u16(offset + 28)
        let dataStart = offset + 30 + nameLen + extraLen
        guard dataStart + entry.compressedSize <= bytes.count else {
            throw SessionServiceError.invalidDocument("Failed to read \(name): truncated entry")
        }
        let payload = bytes.subdata(
            in: (bytes.startIndex + dataStart)..<(bytes.startIndex + dataStart + entry.compressedSize))

        switch entry.method {
        case 0:
            if payload.count > cap {
                throw SessionServiceError.invalidDocument(
                    "Archive entry \(name) exceeds its size limit")
            }
            return payload
        case 8:
            do {
                return try MiniZip.inflate(payload, cap: cap)
            } catch is SizeLimitExceeded {
                throw SessionServiceError.invalidDocument(
                    "Archive entry \(name) exceeds its size limit")
            } catch {
                throw SessionServiceError.invalidDocument(
                    "Failed to read \(name): \(error.localizedDescription)")
            }
        default:
            throw SessionServiceError.invalidDocument(
                "Failed to read \(name): unsupported compression method")
        }
    }

    // MARK: Deflate / Inflate (raw DEFLATE, RFC 1951)

    struct CodecError: Error {}

    static func deflate(_ input: Data) throws -> Data {
        if input.isEmpty {
            // Canonical empty raw-deflate stream (single final stored block).
            return Data([0x03, 0x00])
        }
        var capacity = input.count + input.count / 2 + 256
        for _ in 0..<2 {
            var dst = Data(count: capacity)
            let written = dst.withUnsafeMutableBytes { dstPtr -> Int in
                input.withUnsafeBytes { srcPtr -> Int in
                    compression_encode_buffer(
                        dstPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), capacity,
                        srcPtr.baseAddress!.assumingMemoryBound(to: UInt8.self), input.count,
                        nil, COMPRESSION_ZLIB)
                }
            }
            if written > 0 {
                dst.removeSubrange(written..<dst.count)
                return dst
            }
            capacity = capacity * 2 + 1024
        }
        throw CodecError()
    }

    static func inflate(_ input: Data, cap: Int) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0,
            state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
            == COMPRESSION_STATUS_OK else {
            throw CodecError()
        }
        defer { compression_stream_destroy(&stream) }

        let chunkSize = 64 * 1024
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { buffer.deallocate() }

        return try input.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Data in
            let srcBase = srcRaw.baseAddress?.assumingMemoryBound(to: UInt8.self)
            stream.src_ptr = srcBase ?? UnsafePointer<UInt8>(bitPattern: 1)!
            stream.src_size = input.count
            while true {
                stream.dst_ptr = buffer
                stream.dst_size = chunkSize
                let status = compression_stream_process(
                    &stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunkSize - stream.dst_size
                if produced > 0 {
                    out.append(buffer, count: produced)
                    if out.count > cap {
                        throw SizeLimitExceeded()
                    }
                }
                switch status {
                case COMPRESSION_STATUS_END:
                    return out
                case COMPRESSION_STATUS_OK:
                    continue
                default:
                    throw CodecError()
                }
            }
        }
    }

    // MARK: CRC32 / DOS timestamps

    nonisolated(unsafe) private static let crcTable: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) != 0 ? (0xedb8_8320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
        }
        return crc ^ 0xffff_ffff
    }

    private static func dosDateTime(_ date: Date) -> (time: UInt16, date: UInt16) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5)
            | ((parts.second ?? 0) / 2))
        let dosDate = UInt16(((year - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (time, dosDate)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xff))
        append(UInt8(value >> 8))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
}
