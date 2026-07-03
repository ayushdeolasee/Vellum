import Foundation
import WebKit

// Live-page pipeline — port of the fetch/normalize/prepare half of
// src-tauri/src/web_page.rs plus the `vellum-web://` protocol routing from
// src-tauri/src/lib.rs (handle_vellum_web_request, lines 75–210). The Tauri
// custom protocol becomes a WKURLSchemeHandler with identical routes and
// fallback chain, including the redirect snapshot-freshening rules.

// MARK: - URL normalization (Rust `normalize_url`)

enum WebUrl {
    /// Normalize a user-supplied URL: default to https, strip fragments and
    /// tracking params so the same article always maps to one record. The
    /// output must match the Rust `url` crate's serialization (the sha256 of
    /// this string is the on-disk storage key).
    static func normalize(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw SessionServiceError.invalidDocument("Empty URL")
        }
        var candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        // The WHATWG parser strips ASCII tab/newline anywhere in the input.
        candidate = candidate.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }

        // Scheme
        guard let colon = candidate.firstIndex(of: ":") else {
            throw SessionServiceError.invalidDocument("Invalid URL: relative URL without a base")
        }
        let schemeRaw = String(candidate[candidate.startIndex..<colon])
        guard isValidScheme(schemeRaw) else {
            throw SessionServiceError.invalidDocument("Invalid URL: relative URL without a base")
        }
        let scheme = schemeRaw.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw SessionServiceError.invalidDocument("Unsupported URL scheme: \(scheme)")
        }

        var rest = String(candidate[candidate.index(after: colon)...])
        guard rest.hasPrefix("//") else {
            throw SessionServiceError.invalidDocument("URL has no host")
        }
        rest.removeFirst(2)
        // Extra leading slashes are tolerated by the WHATWG parser.
        while rest.hasPrefix("/") || rest.hasPrefix("\\") { rest.removeFirst() }

        // Split authority / path / query / fragment. '\' acts as '/' in
        // special-scheme URLs.
        var authority = ""
        var pathPart = ""
        var queryPart: String? = nil
        var index = rest.startIndex
        while index < rest.endIndex {
            let c = rest[index]
            if c == "/" || c == "\\" || c == "?" || c == "#" { break }
            authority.append(c)
            index = rest.index(after: index)
        }
        var seenQuery = false
        var stop = false
        while index < rest.endIndex, !stop {
            let c = rest[index]
            switch c {
            case "#":
                stop = true // fragment stripped
            case "?" where !seenQuery:
                seenQuery = true
                queryPart = ""
            default:
                if seenQuery {
                    queryPart?.append(c)
                } else {
                    pathPart.append(c)
                }
            }
            index = rest.index(after: index)
        }

        // Authority: userinfo, host, port
        var userinfo: String? = nil
        var hostPort = authority
        if let at = authority.lastIndex(of: "@") {
            userinfo = String(authority[authority.startIndex..<at])
            hostPort = String(authority[authority.index(after: at)...])
        }
        var host = ""
        var portString: String? = nil
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else {
                throw SessionServiceError.invalidDocument("Invalid URL: invalid IPv6 address")
            }
            host = String(hostPort[hostPort.startIndex...close])
            let after = String(hostPort[hostPort.index(after: close)...])
            if after.hasPrefix(":") {
                portString = String(after.dropFirst())
            } else if !after.isEmpty {
                throw SessionServiceError.invalidDocument("Invalid URL: invalid port number")
            }
        } else if let colonIdx = hostPort.lastIndex(of: ":") {
            host = String(hostPort[hostPort.startIndex..<colonIdx])
            portString = String(hostPort[hostPort.index(after: colonIdx)...])
        } else {
            host = hostPort
        }
        host = host.lowercased()
        if host.isEmpty {
            throw SessionServiceError.invalidDocument("Invalid URL: empty host")
        }
        var port: Int? = nil
        if let portString, !portString.isEmpty {
            guard portString.allSatisfy(\.isNumber), let parsed = Int(portString), parsed <= 65535 else {
                throw SessionServiceError.invalidDocument("Invalid URL: invalid port number")
            }
            port = parsed
        }
        if (scheme == "http" && port == 80) || (scheme == "https" && port == 443) {
            port = nil
        }

        let path = normalizePath(pathPart)

        // Query: parsed as form-urlencoded pairs, tracking params dropped,
        // re-serialized (the Rust code always rebuilds the query via
        // `query_pairs_mut` when any pair survives).
        var query: String? = nil
        if let queryPart, !queryPart.isEmpty {
            let kept = parseFormPairs(queryPart).filter { !isTrackingParam($0.0) }
            if !kept.isEmpty {
                query = kept
                    .map { "\(formEncode($0.0))=\(formEncode($0.1))" }
                    .joined(separator: "&")
            }
        }

        var out = "\(scheme)://"
        if let userinfo, !userinfo.isEmpty { out += "\(userinfo)@" }
        out += host
        if let port { out += ":\(port)" }
        out += path
        if let query { out += "?\(query)" }
        return out
    }

    static func isTrackingParam(_ key: String) -> Bool {
        key.hasPrefix("utm_")
            || ["fbclid", "gclid", "igshid", "mc_cid", "mc_eid", "ref_src", "twclid"].contains(key)
    }

    private static func isValidScheme(_ scheme: String) -> Bool {
        guard let first = scheme.first, first.isASCII, first.isLetter else { return false }
        return scheme.dropFirst().allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".")
        }
    }

    /// WHATWG-style path canonicalization for special schemes: '\' → '/',
    /// dot-segment resolution, percent-encoding of the path encode set
    /// (existing percent-escapes pass through untouched).
    private static func normalizePath(_ raw: String) -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        var segments: [String] = []
        var endsWithSlash = true
        for piece in path.split(separator: "/", omittingEmptySubsequences: false).dropFirst(0) {
            let segment = String(piece)
            let lowered = segment.lowercased()
                .replacingOccurrences(of: "%2e", with: ".")
            if lowered == "." {
                endsWithSlash = true
                continue
            }
            if lowered == ".." {
                if !segments.isEmpty { segments.removeLast() }
                endsWithSlash = true
                continue
            }
            if segment.isEmpty {
                endsWithSlash = true
                continue
            }
            segments.append(segment)
            endsWithSlash = false
        }
        if segments.isEmpty { return "/" }
        var out = "/" + segments.map(encodePathSegment).joined(separator: "/")
        if endsWithSlash || path.hasSuffix("/") { out += "/" }
        return out
    }

    private static func encodePathSegment(_ segment: String) -> String {
        var out = ""
        for byte in segment.utf8 {
            let c = Character(UnicodeScalar(byte))
            let needsEncoding = byte < 0x20 || byte > 0x7e
                || c == " " || c == "\"" || c == "<" || c == ">" || c == "`"
                || c == "#" || c == "?" || c == "{" || c == "}"
            if needsEncoding {
                out += String(format: "%%%02X", byte)
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// application/x-www-form-urlencoded parse ('+' means space).
    static func parseFormPairs(_ query: String) -> [(String, String)] {
        var out: [(String, String)] = []
        for piece in query.split(separator: "&", omittingEmptySubsequences: true) {
            let part = String(piece)
            if let eq = part.firstIndex(of: "=") {
                out.append((
                    formDecode(String(part[part.startIndex..<eq])),
                    formDecode(String(part[part.index(after: eq)...]))
                ))
            } else {
                out.append((formDecode(part), ""))
            }
        }
        return out
    }

    static func formDecode(_ value: String) -> String {
        var bytes: [UInt8] = []
        let utf8 = Array(value.utf8)
        var i = 0
        while i < utf8.count {
            let b = utf8[i]
            if b == UInt8(ascii: "+") {
                bytes.append(UInt8(ascii: " "))
                i += 1
            } else if b == UInt8(ascii: "%"), i + 2 < utf8.count,
                      let hi = hexValue(utf8[i + 1]), let lo = hexValue(utf8[i + 2]) {
                bytes.append(hi << 4 | lo)
                i += 3
            } else {
                bytes.append(b)
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
        default: return nil
        }
    }

    /// form-urlencoded serialization: unreserved = ALPHA / DIGIT / * - . _,
    /// space → '+', everything else %XX.
    static func formEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "*"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"):
                out.append(Character(UnicodeScalar(byte)))
            case UInt8(ascii: " "):
                out.append("+")
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }
}

// MARK: - Page fetching (Rust `fetch_page` / `read_body_capped`)

enum WebFetchedPage {
    case html(html: String, finalUrl: String)
    case other(contentType: String, body: Data)
}

enum WebFetch {
    static let maxResponseBytes = 25 * 1024 * 1024
    static let maxAssetBytes = 8 * 1024 * 1024
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
        + "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 Vellum/0.1"

    /// Shared client: exact UA, 30 s timeout, redirects followed, no cookies,
    /// no cache (reqwest always hits the network; a cached hit here would
    /// defeat the offline-snapshot fallback chain).
    nonisolated(unsafe) static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 30
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    static func fetchPage(_ url: String) async throws -> WebFetchedPage {
        guard let requestUrl = URL(string: url) else {
            throw SessionServiceError.io("Failed to fetch page: invalid URL")
        }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: URLRequest(url: requestUrl))
        } catch {
            throw SessionServiceError.io("Failed to fetch page: \(error.localizedDescription)")
        }
        guard let http = response as? HTTPURLResponse else {
            throw SessionServiceError.io("Failed to fetch page: not an HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SessionServiceError.io("The server responded with HTTP \(http.statusCode)")
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "text/html"
        let body = try await readBodyCapped(bytes, expected: http.expectedContentLength, cap: maxResponseBytes)

        if contentType.contains("text/html") || contentType.contains("application/xhtml") {
            let finalUrl = (http.url ?? requestUrl).absoluteString
            return .html(html: decodeHtml(body, contentType: contentType), finalUrl: finalUrl)
        }
        return .other(contentType: contentType, body: body)
    }

    /// Asset fetch used by snapshot capture: failures return nil (skipped).
    static func fetchAsset(_ url: String) async -> (contentType: String, body: Data)? {
        guard let requestUrl = URL(string: url) else { return nil }
        do {
            let (bytes, response) = try await session.bytes(for: URLRequest(url: requestUrl))
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return nil }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
                ?? "application/octet-stream"
            let body = try await readBodyCapped(
                bytes, expected: http.expectedContentLength, cap: maxAssetBytes)
            return (contentType, body)
        } catch {
            return nil
        }
    }

    /// Cap enforced *while* streaming so a missing/false Content-Length or a
    /// decompression bomb can't exhaust memory before a post-hoc check.
    private static func readBodyCapped(
        _ bytes: URLSession.AsyncBytes, expected: Int64, cap: Int
    ) async throws -> Data {
        if expected > 0, expected > Int64(cap) {
            throw SessionServiceError.io("Response is too large to load")
        }
        var body = Data()
        do {
            for try await byte in bytes {
                body.append(byte)
                if body.count > cap {
                    throw SessionServiceError.io("Response is too large to load")
                }
            }
        } catch let error as SessionServiceError {
            throw error
        } catch {
            throw SessionServiceError.io("Failed to read response body: \(error.localizedDescription)")
        }
        return body
    }

    /// Decode HTML honoring the charset from the Content-Type header
    /// (falling back to UTF-8). Note: the charset key match is case-sensitive
    /// like the Rust `strip_prefix("charset=")`.
    static func decodeHtml(_ body: Data, contentType: String) -> String {
        var charset = "utf-8"
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("charset=") {
                charset = String(trimmed.dropFirst("charset=".count))
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
                break
            }
        }
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        if cfEncoding != kCFStringEncodingInvalidId {
            let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            if let decoded = String(data: body, encoding: String.Encoding(rawValue: nsEncoding)) {
                return decoded
            }
        }
        return String(decoding: body, as: UTF8.self)
    }

    /// Write a snapshot file atomically (temp + rename) so concurrent readers
    /// never observe a torn file.
    static func writeSnapshotAtomic(path: URL, html: String) {
        let tmp = path.deletingPathExtension()
            .appendingPathExtension("tmp-\(UUID().uuidString.lowercased())")
        guard (try? Data(html.utf8).write(to: tmp)) != nil else { return }
        if rename(tmp.path, path.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
        }
    }
}

// MARK: - HTML preparation (Rust `prepare_html` / `error_page`)

enum WebHtml {
    nonisolated(unsafe) private static let cspMetaRegex = regex(
        #"<meta[^>]+http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>"#)
    nonisolated(unsafe) private static let refreshMetaRegex = regex(
        #"<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*>"#)
    nonisolated(unsafe) private static let headOpenRegex = regex(#"<head[^>]*>"#)
    nonisolated(unsafe) private static let htmlOpenRegex = regex(#"<html[^>]*>"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // Patterns are compile-time constants; force-try is safe.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return json
    }

    /// Rewrite fetched HTML for serving inside the reader webview:
    /// - strip `<meta http-equiv="Content-Security-Policy">` tags,
    /// - strip `<meta http-equiv="refresh">` tags,
    /// - inject `<base href>` so relative subresources resolve against the
    ///   real origin,
    /// - inject the Vellum content script with the normalized page URL.
    static func prepareHtml(_ html: String, pageUrl: String, offline: Bool) -> String {
        var stripped = replaceAll(cspMetaRegex, in: html)
        stripped = replaceAll(refreshMetaRegex, in: stripped)

        let safeUrlAttr = pageUrl.replacingOccurrences(of: "\"", with: "%22")
        let injection = "<base href=\"\(safeUrlAttr)\"><script>"
            + "window.__VELLUM_PAGE_URL__=\(jsonString(pageUrl));"
            + "window.__VELLUM_OFFLINE__=\(offline);\n"
            + WebContentScript.source
            + "</script>"

        let ns = stripped as NSString
        let full = NSRange(location: 0, length: ns.length)
        if let match = headOpenRegex.firstMatch(in: stripped, range: full) {
            let end = match.range.location + match.range.length
            return ns.substring(to: end) + injection + ns.substring(from: end)
        }
        if let match = htmlOpenRegex.firstMatch(in: stripped, range: full) {
            let end = match.range.location + match.range.length
            return ns.substring(to: end) + "<head>" + injection + "</head>" + ns.substring(from: end)
        }
        return injection + stripped
    }

    private static func replaceAll(_ regex: NSRegularExpression, in text: String) -> String {
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
    }

    static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// Simple error page, also run through `prepareHtml` so the content
    /// script still reports init to the app shell.
    static func errorPage(url: String, message: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8"><title>Couldn't load page</title></head>
        <body style="font-family: -apple-system, system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem; color: #333;">
        <h1 style="font-size: 1.25rem;">Couldn't load this page</h1>
        <p style="color:#666; word-break: break-all;">\(escape(url))</p>
        <p>\(escape(message))</p>
        <p style="color:#666;">Check the URL and your network connection, then reload the tab.</p>
        </body></html>
        """
    }
}

// MARK: - vellum-web:// scheme handler (lib.rs handle_vellum_web_request)

private struct WebProxyResponse {
    var status: Int
    var headers: [String: String]
    var body: Data

    static func html(_ status: Int, _ body: String) -> WebProxyResponse {
        WebProxyResponse(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8",
                "Cache-Control": "no-store",
            ],
            body: Data(body.utf8)
        )
    }
}

final class VellumWebSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "vellum-web"

    /// Build the reader URL for a target page, mirroring the frontend's
    /// `webProxyUrl` (encodeURIComponent on the target).
    static func proxyUrl(for target: String) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) ?? target
        return URL(string: "vellum-web://localhost/?url=\(encoded)")
            ?? URL(string: "vellum-web://localhost/")!
    }

    private var activeTasks: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(id)
        let requestUrl = urlSchemeTask.request.url
        Task { @MainActor [weak self] in
            let response = await Self.handleRequest(requestUrl)
            guard let self, self.activeTasks.contains(id) else { return }
            self.activeTasks.remove(id)
            let url = requestUrl ?? URL(string: "vellum-web://localhost/")!
            guard let http = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: response.headers
            ) else { return }
            urlSchemeTask.didReceive(http)
            urlSchemeTask.didReceive(response.body)
            urlSchemeTask.didFinish()
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: Routing

    private static func handleRequest(_ url: URL?) async -> WebProxyResponse {
        guard let url else {
            return .html(404, "<h1>Missing url parameter</h1>")
        }

        let path = url.path
        if path.hasPrefix("/asset/") {
            return serveArchiveAsset(rest: String(path.dropFirst("/asset/".count)))
        }

        // ?url=<encoded>, parsed form-urlencoded like the Rust side.
        let rawQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .percentEncodedQuery ?? ""
        let rawUrl = WebUrl.parseFormPairs(rawQuery).first(where: { $0.0 == "url" })?.1
        guard let rawUrl else {
            return .html(404, "<h1>Missing url parameter</h1>")
        }

        let pageUrl: String
        do {
            pageUrl = try WebUrl.normalize(rawUrl)
        } catch {
            let message = error.localizedDescription
            return .html(
                400,
                WebHtml.prepareHtml(
                    WebHtml.errorPage(url: rawUrl, message: message),
                    pageUrl: rawUrl, offline: false))
        }

        // Base for absolute asset URLs inside served snapshots.
        let assetBase: String
        if let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            assetBase = "\(scheme)://\(host)\(port)"
        } else {
            assetBase = "vellum-web://localhost"
        }

        // Sidecar state drives snapshot refresh and the loading policy.
        let key = WebLibrary.pageKey(pageUrl)
        let snapshotFile = WebLibrary.snapshotPath(forKey: key)
        let record = WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key))
        let recordSaved = record?.saved ?? false
        let snapshotOnly = record?.loadingPolicy == "snapshot-only"

        // Pinned-snapshot policy (from an imported archive): don't hit the
        // network at all when the installed snapshot is available.
        if snapshotOnly, let response = serveInstalledSnapshot(
            key: key, pageUrl: pageUrl, assetBase: assetBase) {
            return response
        }

        do {
            switch try await WebFetch.fetchPage(pageUrl) {
            case .html(let html, let finalUrl):
                // Redirects change the page's effective identity: serve under
                // the final URL so relative subresources resolve correctly and
                // the app shell can rebind the tab to the canonical address.
                let effectiveUrl = (try? WebUrl.normalize(finalUrl)) ?? pageUrl

                // Keep the offline snapshot of saved pages fresh on every
                // successful visit, under the effective identity.
                if effectiveUrl == pageUrl {
                    if recordSaved {
                        WebFetch.writeSnapshotAtomic(path: snapshotFile, html: html)
                    }
                } else {
                    let effectiveKey = WebLibrary.pageKey(effectiveUrl)
                    let effectiveRecord = WebLibrary.loadRecord(
                        at: WebLibrary.recordPath(forKey: effectiveKey))
                    if effectiveRecord?.saved == true {
                        WebFetch.writeSnapshotAtomic(
                            path: WebLibrary.snapshotPath(forKey: effectiveKey), html: html)
                    }
                }

                return .html(200, WebHtml.prepareHtml(html, pageUrl: effectiveUrl, offline: false))

            case .other(let contentType, let body):
                return WebProxyResponse(
                    status: 200,
                    headers: ["Content-Type": contentType, "Cache-Control": "no-store"],
                    body: body)
            }
        } catch {
            // Offline / link-rot fallback: prefer the self-contained
            // .vellumweb snapshot, then the plain saved snapshot.
            if let response = serveInstalledSnapshot(
                key: key, pageUrl: pageUrl, assetBase: assetBase) {
                return response
            }
            if let html = try? String(contentsOf: snapshotFile, encoding: .utf8) {
                return .html(200, WebHtml.prepareHtml(html, pageUrl: pageUrl, offline: true))
            }
            return .html(
                502,
                WebHtml.prepareHtml(
                    WebHtml.errorPage(url: pageUrl, message: error.localizedDescription),
                    pageUrl: pageUrl, offline: false))
        }
    }

    /// `/asset/<key>/<name>` → `<appData>/web/archives/<key>/assets/<name>`.
    private static func serveArchiveAsset(rest: String) -> WebProxyResponse {
        let notFound = WebProxyResponse.html(404, "<h1>Asset not found</h1>")
        guard let slash = rest.firstIndex(of: "/") else { return notFound }
        let key = String(rest[rest.startIndex..<slash])
        let name = String(rest[rest.index(after: slash)...])
        // Keys are sha256 hex; names are flat generated file names. Anything
        // else is rejected (path traversal guard).
        guard !key.isEmpty,
              key.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              !name.isEmpty,
              !name.contains(".."),
              !name.contains("/"),
              !name.contains("\\"),
              !name.hasPrefix(".") else {
            return notFound
        }
        let path = WebLibrary.archiveDir(forKey: key)
            .appendingPathComponent("assets")
            .appendingPathComponent(name)
        guard let bytes = try? Data(contentsOf: path) else { return notFound }
        return WebProxyResponse(
            status: 200,
            headers: [
                "Content-Type": WebArchive.contentTypeForName(name),
                "Cache-Control": "public, max-age=604800",
            ],
            body: bytes)
    }

    /// Serve the installed self-contained snapshot with asset placeholders
    /// resolved to proxy asset URLs.
    private static func serveInstalledSnapshot(
        key: String, pageUrl: String, assetBase: String
    ) -> WebProxyResponse? {
        let snapshot = WebLibrary.archiveDir(forKey: key).appendingPathComponent("snapshot.html")
        guard let html = try? String(contentsOf: snapshot, encoding: .utf8) else { return nil }
        let resolved = WebArchive.resolveAssetPlaceholders(
            html, assetBase: "\(assetBase)/asset/\(key)")
        return .html(200, WebHtml.prepareHtml(resolved, pageUrl: pageUrl, offline: true))
    }
}
