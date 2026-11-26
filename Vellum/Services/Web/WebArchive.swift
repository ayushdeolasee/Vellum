import Foundation
import VellumCore

typealias ArchiveManifest = VellumCore.ArchiveManifest
typealias ManifestHashes = VellumCore.ManifestHashes
typealias ManifestAsset = VellumCore.ManifestAsset
typealias CapturedAsset = VellumCore.CapturedAsset
typealias MiniZip = VellumCore.MiniZip

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
    /// Apple Pencil web ink, if the archive carried an `ink.json` entry. nil
    /// for archives written before web ink or with no ink on the page.
    var inkRecord: WebInkRecord?
}

/// One page of text inside `text/pages.json` (`{"number":1,"text":"…"}`).
private struct PageTextEntry: Codable {
    var number: Int
    var text: String
}

enum WebArchive {
    static let formatName = ArchiveCodec.formatName
    static let formatVersion = ArchiveCodec.formatVersion
    static let maxAssets = ArchiveCodec.maxAssets
    static let maxTotalAssetBytes = ArchiveCodec.maxTotalAssetBytes
    static let maxArchiveBytes = ArchiveCodec.maxArchiveBytes
    static let maxEntries = ArchiveCodec.maxEntries
    static let maxTotalUncompressedBytes = ArchiveCodec.maxTotalUncompressedBytes

    static let assetPlaceholder = "__VELLUM_ASSET__"

    static func sha256Hex(_ bytes: Data) -> String {
        ArchiveCodec.sha256Hex(bytes)
    }

    // MARK: - Snapshot sanitizing & asset capture

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Compile-time constant patterns; force-try is safe.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static let scriptRegex = regex(
        #"<script\b[^>]*>.*?</script\s*>|<script\b[^>]*/>"#)
    private static let preloadRegex = regex(
        #"<link\b[^>]*rel\s*=\s*["']?(?:preload|prefetch|modulepreload|dns-prefetch|preconnect)["']?[^>]*>"#)
    private static let attrStripRegex = regex(
        #"\s(?:srcset|sizes|integrity|crossorigin)\s*=\s*(?:"[^"]*"|'[^']*'|[^\s>]+)"#)
    private static let imgSrcRegex = regex(
        #"<img\b[^>]*?\ssrc\s*=\s*["']([^"']+)["']"#)
    private static let linkTagRegex = regex(#"<link\b[^>]*>"#)
    private static let hrefRegex = regex(#"\bhref\s*=\s*["']([^"']+)["']"#)
    private static let stylesheetRelRegex = regex(
        #"\brel\s*=\s*["']?stylesheet["']?"#)
    private static let cssUrlRegex = regex(
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
        titleIsUserDefined: Bool? = false,
        pageCount: Int?,
        lastPage: Int?,
        loadingPolicy: String,
        snapshotHtml: String,
        pagesJson: Data,
        assets: [CapturedAsset],
        assetsSkipped: Int,
        previous: ArchiveManifest? = nil
    ) -> ArchiveManifest {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0.1.0"
        var manifest = ArchiveManifest(
            format: formatName,
            version: formatVersion,
            url: url,
            canonicalUrl: url,
            title: title,
            titleIsUserDefined: titleIsUserDefined,
            capturedAt: WebLibrary.rfc3339Now(),
            generator: "Vellum \(version)",
            loadingPolicy: loadingPolicy,
            pageCount: pageCount,
            lastPage: lastPage,
            hashes: ManifestHashes(
                snapshotHtml: sha256Hex(Data(snapshotHtml.utf8)),
                pageText: sha256Hex(pagesJson),
                annotations: nil, // filled in by writeArchive
                ink: nil // filled in by writeArchive when the page carries ink
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
        if let previous { manifest.inheritUnknownFields(from: previous) }
        return manifest
    }

    static func installedManifest(forKey key: String) throws -> ArchiveManifest? {
        let path = WebLibrary.archiveDir(forKey: key).appendingPathComponent("manifest.json")
        let file: FileHandle
        do { file = try FileHandle(forReadingFrom: path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        defer { try? file.close() }
        let data = try file.read(upToCount: ArchiveCodec.maxManifestBytes + 1) ?? Data()
        guard data.count <= ArchiveCodec.maxManifestBytes else {
            throw SessionServiceError.invalidDocument("Installed web manifest exceeds its size limit")
        }
        return try JSONDecoder().decode(ArchiveManifest.self, from: data)
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
        annotations: [Annotation],
        inkJson: Data? = nil
    ) throws -> Int {
        let zipData = try encodeArchive(
            manifest: manifest,
            snapshotHtml: snapshotHtml,
            assets: assets,
            pagesJson: pagesJson,
            annotations: annotations, inkJson: inkJson)
        try writeArchiveBytes(zipData, to: dest)
        return zipData.count
    }

    static func encodeArchive(
        manifest: ArchiveManifest,
        snapshotHtml: String,
        assets: [CapturedAsset],
        pagesJson: Data,
        annotations: [Annotation],
        inkJson: Data? = nil
    ) throws -> Data {
        try translatingArchiveErrors {
            try ArchiveCodec.encode(manifest: manifest, snapshotHtml: snapshotHtml, assets: assets,
                                    pagesJson: pagesJson, annotations: annotations, inkJson: inkJson)
        }
    }

    static func translatingArchiveErrors<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch ArchiveCodecError.invalidDocument(let detail) {
            throw SessionServiceError.invalidDocument(detail)
        } catch ArchiveCodecError.io(let detail) {
            throw SessionServiceError.io(detail)
        } catch let error as SessionServiceError {
            throw error
        } catch {
            throw SessionServiceError.io(error.localizedDescription)
        }
    }

    static func writeArchiveBytes(_ zipData: Data, to dest: URL) throws {
        let parent = dest.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw SessionServiceError.io(
                "Failed to create destination dir: \(error.localizedDescription)")
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
    }

    static func readManifest(at path: URL) throws -> ArchiveManifest {
        try translatingArchiveErrors { try ArchiveCodec.readManifest(at: path) }
    }

    static func readManifest(data: Data) throws -> ArchiveManifest {
        try translatingArchiveErrors { try ArchiveCodec.readManifest(data: data) }
    }

    static func readArchive(at path: URL) throws -> ImportedArchive {
        try imported(translatingArchiveErrors { try ArchiveCodec.decode(at: path) })
    }

    static func readArchive(data: Data) throws -> ImportedArchive {
        try imported(translatingArchiveErrors { try ArchiveCodec.decode(data) })
    }

    private static func imported(_ archive: DecodedWebArchive) throws -> ImportedArchive {
        let inkRecord: WebInkRecord?
        do {
            inkRecord = try archive.inkJSON.map { try JSONDecoder().decode(WebInkRecord.self, from: $0) }
            _ = try inkRecord?.validatedMergedDrawing()
        } catch {
            throw SessionServiceError.invalidDocument(
                "Archive ink data could not be read: \(error.localizedDescription)")
        }
        return ImportedArchive(manifest: archive.manifest, snapshotHtml: archive.snapshotHtml,
                               assets: archive.assets, annotations: archive.annotations, inkRecord: inkRecord)
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
                guard let safe = ArchiveCodec.safeAssetName(name) else { continue }
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
                let current = existing[index]
                let newer = newerThan(annotation.updatedAt, current.updatedAt)
                var merged = newer ? annotation : current
                merged.unknownFields = current.unknownFields
                merged.unknownFields.fillMissing(from: annotation.unknownFields)
                if var position = merged.positionData {
                    // Preserve current extras on collisions even when newer
                    // known geometry came from the incoming annotation.
                    if let old = current.positionData, let other = annotation.positionData {
                        position.unknownFields = old.unknownFields
                        for index in position.rects.indices.prefix(old.rects.count) {
                            position.rects[index].unknownFields = old.rects[index].unknownFields
                        }
                        position.inheritUnknownFields(from: other)
                    }
                    merged.positionData = position
                }
                if merged != current {
                    existing[index] = merged
                    changed += 1
                }
            } else {
                existing.append(annotation)
                changed += 1
            }
        }
        return changed
    }

    /// Import by stable stroke ID, retaining erasures even on an empty canvas.
    /// Return the number of net additions (legacy unreadable clusters count replacements).
    @discardableResult
    static func mergeInk(_ existing: inout WebInkRecord?, incoming: WebInkRecord) throws -> Int {
        guard var current = existing else {
            var incoming = incoming
            try WebInkStore.discardDeleted(from: &incoming)
            _ = try incoming.validatedMergedDrawing()
            existing = incoming
            return incoming.clusters.count
        }
        // Real records merge by stable Pencil stroke identity. Keep the legacy
        // cluster-id path below as a compatibility fallback for malformed or
        // synthetic records whose drawing payloads cannot be decoded.
        do {
            let before = try current.validatedMergedDrawing().strokes.count
            let merged = try WebInkStore.additivelyMerged(current: current, incoming: incoming)
            let after = try merged.validatedMergedDrawing().strokes.count
            existing = merged
            return max(0, after - before)
        } catch {
            // The historic id-only fallback is for drawing-only records.
            guard current.history == InkMergeHistory(), incoming.history == InkMergeHistory(),
                  (current.clusters + incoming.clusters).allSatisfy({ $0.drawing != nil && !$0.hasPortablePayload })
            else { throw error }
            if (try? current.validatedMergedDrawing()) != nil, (try? incoming.validatedMergedDrawing()) != nil {
                throw error
            }
        }
        let incomingNewer = newerThan(incoming.updatedAt, current.updatedAt)
        var changed = 0
        for cluster in incoming.clusters {
            if let index = current.clusters.firstIndex(where: { $0.id == cluster.id }) {
                if incomingNewer {
                    current.clusters[index] = cluster
                    changed += 1
                }
            } else {
                current.clusters.append(cluster)
                changed += 1
            }
        }
        if incomingNewer {
            current.updatedAt = incoming.updatedAt
            current.layout = incoming.layout
        }
        if changed > 0 {
            // `version` describes the capture/clustering guarantees of every
            // cluster in the record. If a merge mixes in legacy clusters, keep
            // the lowest version so the next load recaptures all anchors before
            // snapshotting a fully-current record.
            current.version = min(current.version, incoming.version)
        }
        if let original = existing {
            WebInkStore.carryUnknownFields(into: &current, from: [original, incoming])
        }
        existing = current
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

extension ArchiveManifest {
    mutating func inheritUnknownFields(from previous: ArchiveManifest) {
        unknownFields.fillMissing(from: previous.unknownFields)
        hashes.unknownFields.fillMissing(from: previous.hashes.unknownFields)
        for index in assets.indices {
            let asset = assets[index]
            // A live capture can rename an asset. Offline captures retain
            // its installed path, but do not have a source URL.
            let prior = previous.assets.first { old in
                if asset.url.isEmpty { return old.path == asset.path }
                if !old.url.isEmpty { return old.url == asset.url }
                // An offline export has no source URL. A live capture can
                // identify that same asset by its installed path and digest.
                return old.path == asset.path && old.sha256 != nil && old.sha256 == asset.sha256
            }
            if let prior {
                assets[index].unknownFields.fillMissing(from: prior.unknownFields)
            }
        }
    }
}
