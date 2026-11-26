import Foundation
import VellumCore
import WebKit

// Live-page pipeline — port of the fetch/normalize/prepare half of
// src-tauri/src/web_page.rs. The Tauri custom protocol became a
// WKURLSchemeHandler; unlike the original's `?url=<encoded>` route, pages are
// served under TRUTHFUL proxy URLs (`vellum-web://<real-host>/<real-path>`)
// so window.location matches the page's server-rendered route and SPA
// hydration survives (see plans/web-proxy-truthful-urls.html). The redirect
// snapshot-freshening rules and offline fallback chain are unchanged.

// MARK: - URL normalization (Rust `normalize_url`)

enum WebUrl {
    static func normalize(_ raw: String) throws -> String {
        #if os(iOS)
        let httpsOnly = true
        #else
        let httpsOnly = false
        #endif
        do {
            return try WebURLNormalizer.normalize(raw, httpsOnly: httpsOnly)
        } catch WebURLNormalizationError.invalidDocument(let reason) {
            throw SessionServiceError.invalidDocument(reason)
        }
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
    static let session: URLSession = {
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
        // Data.append per byte repeatedly crosses Foundation's storage layer.
        // Keep a small Swift buffer, while still enforcing the decoded size cap
        // during streaming rather than after an unbounded download.
        var chunk = [UInt8]()
        chunk.reserveCapacity(64 * 1024)
        do {
            for try await byte in bytes {
                guard body.count + chunk.count < cap else {
                    throw SessionServiceError.io("Response is too large to load")
                }
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    try Task.checkCancellation()
                    body.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            try Task.checkCancellation()
            body.append(contentsOf: chunk)
        } catch let error as SessionServiceError {
            throw error
        } catch {
            throw SessionServiceError.io("Failed to read response body: \(error.localizedDescription)")
        }
        return body
    }

    /// Decode HTML honoring the charset from the Content-Type header
    /// (falling back to UTF-8). Note: the charset key match is case-sensitive
    /// like the Rust `strip_prefix("charset=")`. The Rust side decodes with
    /// encoding_rs (WHATWG labels, lossy per invalid sequence), so labels are
    /// resolved through the WHATWG alias table first and strict-decode
    /// failures degrade per-sequence instead of re-reading the whole page as
    /// UTF-8 mojibake.
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
        let label = resolveCharsetLabel(charset)
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            // Unknown label: Rust's for_label(...).unwrap_or(UTF_8), lossy.
            return String(decoding: body, as: UTF8.self)
        }
        let encoding = String.Encoding(
            rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        if encoding == .utf8 {
            return String(decoding: body, as: UTF8.self)
        }
        if let decoded = String(data: body, encoding: encoding) {
            return decoded
        }
        return decodeLossy(body, encoding: encoding)
    }

    /// WHATWG Encoding Standard label resolution for the alias families that
    /// CFString maps differently (browsers — and encoding_rs on the Rust
    /// side — decode `iso-8859-1` as windows-1252, `gb2312` as GBK, …).
    /// Anything not listed passes through to the CF IANA lookup unchanged.
    private static func resolveCharsetLabel(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819",
             "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1",
             "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252":
            return "windows-1252"
        case "csisolatin5", "iso-8859-9", "iso-ir-148", "iso8859-9", "iso88599",
             "iso_8859-9", "iso_8859-9:1989", "l5", "latin5", "windows-1254", "x-cp1254":
            return "windows-1254"
        case "dos-874", "iso-8859-11", "iso8859-11", "iso885911", "tis-620", "windows-874":
            return "windows-874"
        case "chinese", "csgb2312", "csiso58gb231280", "gb2312", "gb_2312", "gb_2312-80",
             "gbk", "iso-ir-58", "x-gbk":
            return "gbk"
        case "csshiftjis", "ms932", "ms_kanji", "shift-jis", "shift_jis", "sjis",
             "windows-31j", "x-sjis":
            return "shift_jis"
        default:
            return raw
        }
    }

    /// Lossy decode mirroring encoding_rs: invalid byte sequences become
    /// U+FFFD while everything else decodes with the declared encoding.
    /// Decodes greedily in chunks, backing off around invalid sequences
    /// (multibyte sequences are at most 4 bytes, so a valid chunk boundary is
    /// found within 3 trims; a failing 1-byte chunk is the invalid byte).
    private static func decodeLossy(_ body: Data, encoding: String.Encoding) -> String {
        let bytes = [UInt8](body)
        var out = ""
        var index = 0
        let maxChunk = 64 * 1024
        while index < bytes.count {
            var chunk = min(maxChunk, bytes.count - index)
            var advanced = false
            while chunk > 0 {
                let atEnd = index + chunk == bytes.count
                let minLength = atEnd ? chunk : max(1, chunk - 3)
                var length = chunk
                while length >= minLength {
                    if let decoded = String(bytes: bytes[index..<(index + length)], encoding: encoding) {
                        out += decoded
                        index += length
                        advanced = true
                        break
                    }
                    length -= 1
                }
                if advanced { break }
                if chunk == 1 {
                    out.append("\u{FFFD}")
                    index += 1
                    advanced = true
                    break
                }
                chunk /= 2
            }
            if !advanced {
                // Unreachable (chunk bottoms out at 1), kept as a hard stop.
                out.append("\u{FFFD}")
                index += 1
            }
        }
        return out
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
    private static let cspMetaRegex = regex(
        #"<meta[^>]+http-equiv\s*=\s*["']?content-security-policy["']?[^>]*>"#)
    private static let refreshMetaRegex = regex(
        #"<meta[^>]+http-equiv\s*=\s*["']?refresh["']?[^>]*>"#)
    private static let headOpenRegex = regex(#"<head[^>]*>"#)
    private static let htmlOpenRegex = regex(#"<html[^>]*>"#)

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
    /// - inject the unprivileged page-world bootstrap with the normalized
    ///   page URL and offline flag (only this handler knows them at serve
    ///   time). The content script itself runs as a WKUserScript in an
    ///   isolated content world (see WebViewerController.makeWebView) so
    ///   page scripts can never reach the message bridge.
    static func prepareHtml(_ html: String, pageUrl: String, offline: Bool) -> String {
        var stripped = replaceAll(cspMetaRegex, in: html)
        stripped = replaceAll(refreshMetaRegex, in: stripped)

        let safeUrlAttr = pageUrl.replacingOccurrences(of: "\"", with: "%22")
        let injection = "<base href=\"\(safeUrlAttr)\"><script>"
            + "window.__VELLUM_PAGE_URL__=\(jsonString(pageUrl));"
            + "window.__VELLUM_OFFLINE__=\(offline);\n"
            + WebContentScript.pageWorldSource
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

struct WebProxyResponse: Sendable {
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

@MainActor
final class VellumWebSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "vellum-web"
    /// Second registered scheme for plain-http targets: the proxy authority
    /// mirrors the real host, so the real scheme has to live in the custom
    /// scheme name itself ("i" = insecure).
    nonisolated static let insecureScheme = "vellum-webi"
    /// Reserved authorities — `.invalid` is an RFC 2606 TLD that can never
    /// resolve, so these cannot collide with a real site's own hosts/paths.
    nonisolated static let assetHost = "assets.vellum.invalid"
    nonisolated static let snapshotHost = "snapshot.vellum.invalid"
    private let storage: WebLibraryStorage
    private struct Owner: Equatable, Sendable {
        let key: String
        let token: UUID
        let origin: String
        let generation: UUID
    }
    private var owner: Owner?
    private var suspendedOwner: Owner?

    func bind(to pageURL: String?) {
        guard let pageURL else {
            suspendedOwner = owner
            owner = nil
            cancelRequests()
            return
        }
        let key = WebLibrary.pageKey(pageURL)
        guard owner?.key != key else { return }
        cancelRequests()
        let proxy = Self.proxyUrl(for: pageURL)
        var origin = URLComponents(url: proxy, resolvingAgainstBaseURL: false)!
        origin.path = ""
        origin.query = nil
        origin.fragment = nil
        origin.user = nil
        origin.password = nil
        let token = suspendedOwner?.key == key ? suspendedOwner!.token : UUID()
        owner = Owner(key: key, token: token, origin: origin.string!, generation: UUID())
        suspendedOwner = nil
    }

    private func cancelRequests() {
        for task in activeTasks.values { task.cancel() }
        activeTasks.removeAll()
    }


    init(storage: WebLibraryStorage = WebLibraryStorage()) {
        self.storage = storage
        super.init()
    }

    /// Build the reader URL for a target page. The mapping keeps the real
    /// authority/path/query so in-page routers see the address they were
    /// server-rendered for — `window.location.pathname` must match, or SPA
    /// hydration tears the page down (see plans/web-proxy-truthful-urls.html).
    nonisolated static func proxyUrl(for target: String) -> URL {
        // `target` is always WebUrl.normalize output; swap the scheme by
        // string surgery so the WHATWG-serialized authority/path/query stay
        // byte-identical (URLComponents reassembly would re-encode).
        let mapped: String
        if target.hasPrefix("https://") {
            mapped = "\(scheme)://\(target.dropFirst("https://".count))"
        } else if target.hasPrefix("http://") {
            mapped = "\(insecureScheme)://\(target.dropFirst("http://".count))"
        } else {
            mapped = "\(scheme)://\(target)"
        }
        guard let url = URL(string: mapped) else {
            // Normalize's output should always be URL(string:)-parseable; reaching
            // here means an encoding gap upstream — surface it in debug instead of
            // silently rebinding the tab to an empty snapshot page.
            assertionFailure("proxyUrl: unparseable mapped URL for target \(target)")
            return URL(string: "\(scheme)://\(snapshotHost)/")!
        }
        return url
    }

    /// Reader URL that explicitly requests the offline snapshot for a page
    /// key (navigation-failure fallback).
    func snapshotUrl(forKey key: String) -> URL {
        URL(string: "\(Self.scheme)://\(Self.snapshotHost)/\(key)/\(owner?.token.uuidString ?? "unbound")")!
    }

    /// Map a proxy URL back to the real page URL (inverse of `proxyUrl`).
    /// Percent-encoding is taken verbatim from the request so the round trip
    /// through WKWebView cannot change page identity. Returns nil for the
    /// reserved authorities and foreign schemes.
    nonisolated static func realUrl(from url: URL) -> String? {
        let realScheme: String
        switch url.scheme?.lowercased() {
        case scheme: realScheme = "https"
        case insecureScheme: realScheme = "http"
        default: return nil
        }
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              var host = comps.encodedHost, !host.isEmpty,
              host != assetHost, host != snapshotHost else { return nil }
        if host.contains(":"), !host.hasPrefix("[") {
            host = "[\(host)]" // IPv6 literal: encodedHost strips the brackets
        }
        var authority = ""
        if let user = comps.percentEncodedUser {
            authority += user
            if let password = comps.percentEncodedPassword {
                authority += ":\(password)"
            }
            authority += "@"
        }
        authority += host
        if let port = comps.port { authority += ":\(port)" }
        var path = comps.percentEncodedPath
        if path.isEmpty { path = "/" }
        var out = "\(realScheme)://\(authority)\(path)"
        if let query = comps.percentEncodedQuery { out += "?\(query)" }
        return out
    }

    private var activeTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let request = urlSchemeTask.request
        activeTasks[id] = Task { @MainActor [weak self] in
            guard let self else { return }
            let capturedOwner = self.owner
            let response = await self.handleRequest(request)
            guard self.owner == capturedOwner else { return }
            guard !Task.isCancelled, self.activeTasks.removeValue(forKey: id) != nil else { return }
            let url = request.url ?? URL(string: "\(Self.scheme)://\(Self.snapshotHost)/")!
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
        activeTasks.removeValue(forKey: ObjectIdentifier(urlSchemeTask))?.cancel()
    }

    // MARK: Routing

    func handleRequest(_ request: URLRequest) async -> WebProxyResponse {
        guard let capturedOwner = owner else { return .html(403, "<h1>Reader unavailable</h1>") }
        let response = await handleOwnedRequest(request, owner: capturedOwner)
        guard owner == capturedOwner, !Task.isCancelled else {
            return .html(403, "<h1>Reader changed</h1>")
        }
        return response
    }

    private func handleOwnedRequest(_ request: URLRequest, owner: Owner) async -> WebProxyResponse {
        guard let url = request.url, let host = url.host?.lowercased() else {
            return .html(404, "<h1>Invalid request</h1>")
        }

        // Reserved authorities first: archive assets and the explicit
        // offline-snapshot fallback.
        if host == Self.assetHost || host == Self.snapshotHost {
            let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
            let asset = host == Self.assetHost
            guard parts.count == (asset ? 4 : 3), parts[0].isEmpty,
                  parts[1] == owner.key, parts[2] == owner.token.uuidString,
                  request.value(forHTTPHeaderField: "Origin").map({
                      $0 == owner.origin || $0 == "\(Self.scheme)://\(Self.snapshotHost)"
                  }) ?? true
            else { return .html(403, "<h1>Reader resource unavailable</h1>") }
            if asset {
                let rest = "\(owner.key)/\(parts[3])"
                return await Task.detached {
                    Self.serveArchiveAsset(rest: rest,
                        requestOrigin: request.value(forHTTPHeaderField: "Origin"))
                }.value
            }
            return await serveSnapshotFallback(key: owner.key)
        }

        // Everything else is the page authority: map the truthful proxy URL
        // back to the real page URL.
        guard let rawUrl = Self.realUrl(from: url) else {
            return .html(404, "<h1>Invalid request</h1>")
        }

        // Subresource-shaped requests at the page authority must not turn
        // into page fetches: WebKit fires `Link: rel=preload` headers from
        // cross-origin responses at this handler (resolved against the
        // document origin), which would otherwise let any site's response
        // headers make Vellum issue arbitrary network requests.
        if let mainDocumentURL = request.mainDocumentURL, mainDocumentURL != url {
            return WebProxyResponse(
                status: 204, headers: ["Cache-Control": "no-store"], body: Data())
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

        // Sidecar state drives snapshot refresh and the loading policy.
        let key = WebLibrary.pageKey(pageUrl)
        guard key == owner.key else { return .html(403, "<h1>Reader resource unavailable</h1>") }
        let snapshotFile = WebLibrary.snapshotPath(forKey: key)
        let record = await storage.loadRecord(forKey: key)
        guard !Task.isCancelled, self.owner == owner else {
            return WebProxyResponse(status: 204, headers: [:], body: Data())
        }
        let recordSaved = record?.saved ?? false
        let snapshotOnly = record?.loadingPolicy == "snapshot-only"

        // Pinned-snapshot policy (from an imported archive): don't hit the
        // network at all when the installed snapshot is available.
        if snapshotOnly, let response = await serveInstalledSnapshot(key: key, pageUrl: pageUrl) {
            return response
        }

        do {
            switch try await WebFetch.fetchPage(pageUrl) {
            case .html(let html, let finalUrl):
                try Task.checkCancellation()
                guard self.owner == owner else { return .html(403, "<h1>Reader changed</h1>") }
                // Redirects change the page's effective identity: serve under
                // the final URL so relative subresources resolve correctly and
                // the app shell can rebind the tab to the canonical address.
                let effectiveUrl = (try? WebUrl.normalize(finalUrl)) ?? pageUrl

                // Keep the offline snapshot of saved pages fresh on every
                // successful visit, under the effective identity.
                if effectiveUrl == pageUrl {
                    if recordSaved {
                        await Task.detached { WebFetch.writeSnapshotAtomic(path: snapshotFile, html: html) }.value
                    }
                } else {
                    let effectiveKey = WebLibrary.pageKey(effectiveUrl)
                    let effectiveRecord = await storage.loadRecord(forKey: effectiveKey)
                    try Task.checkCancellation()
                    guard self.owner == owner else { return .html(403, "<h1>Reader changed</h1>") }
                    if effectiveRecord?.saved == true {
                        await Task.detached {
                            WebFetch.writeSnapshotAtomic(path: WebLibrary.snapshotPath(forKey: effectiveKey), html: html)
                        }.value
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
            // A stopped navigation must not read or prepare an offline fallback.
            guard !Task.isCancelled, self.owner == owner else {
                return WebProxyResponse(status: 204, headers: [:], body: Data())
            }
            // Offline / link-rot fallback: prefer the self-contained
            // .vellumweb snapshot, then the plain saved snapshot.
            if let response = await serveInstalledSnapshot(key: key, pageUrl: pageUrl) {
                return response
            }
            let html = await Task.detached { try? String(contentsOf: snapshotFile, encoding: .utf8) }.value
            if let html {
                return .html(200, WebHtml.prepareHtml(html, pageUrl: pageUrl, offline: true))
            }
            return .html(
                502,
                WebHtml.prepareHtml(
                    WebHtml.errorPage(url: pageUrl, message: error.localizedDescription),
                    pageUrl: pageUrl, offline: false))
        }
    }

    /// `vellum-web://assets.vellum.invalid/<key>/<name>` →
    /// `<appData>/web/archives/<key>/assets/<name>`.
    nonisolated private static func serveArchiveAsset(rest: String, requestOrigin: String? = nil) -> WebProxyResponse {
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
        guard let path = archiveResource(key: key, relativePath: "assets/\(name)"),
              let bytes = try? Data(contentsOf: path) else { return notFound }
        var headers = [
            "Content-Type": WebArchive.contentTypeForName(name),
            "Cache-Control": "no-store",
        ]
        // The owned route already checked this against the exact reader origin.
        if let origin = requestOrigin {
            headers["Access-Control-Allow-Origin"] = origin
            headers["Vary"] = "Origin"
        }
        return WebProxyResponse(status: 200, headers: headers, body: bytes)
    }

    /// Serve the installed self-contained snapshot with asset placeholders
    /// resolved to the reserved asset authority.
    private func serveInstalledSnapshot(key: String, pageUrl: String) async -> WebProxyResponse? {
        guard let owner, owner.key == key else { return nil }
        let response = await Task.detached {
            guard let snapshot = Self.archiveResource(key: key, relativePath: "snapshot.html"),
                  let html = try? String(contentsOf: snapshot, encoding: .utf8) else { return nil as WebProxyResponse? }
            let resolved = WebArchive.resolveAssetPlaceholders(
                html, assetBase: "\(Self.scheme)://\(Self.assetHost)/\(key)/\(owner.token.uuidString)")
            return WebProxyResponse.html(200, WebHtml.prepareHtml(resolved, pageUrl: pageUrl, offline: true))
        }.value
        return self.owner == owner ? response : nil
    }

    nonisolated private static func archiveResource(key: String, relativePath: String) -> URL? {
        let root = WebLibrary.archiveDir(forKey: key).deletingLastPathComponent()
            .resolvingSymlinksInPath().appendingPathComponent(key, isDirectory: true)
        let resource = root.appendingPathComponent(relativePath).standardizedFileURL
        guard resource.resolvingSymlinksInPath().path.hasPrefix(root.path + "/") else { return nil }
        return resource
    }

    /// Explicit snapshot request (navigation-failure fallback): installed
    /// archive snapshot first, then the plain saved snapshot, else Vellum's
    /// own error page — the webview must never end up on WebKit's native one.
    private func serveSnapshotFallback(key: String) async -> WebProxyResponse {
        guard let capturedOwner = owner, capturedOwner.key == key else {
            return .html(403, "<h1>Reader unavailable</h1>")
        }
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return .html(404, "<h1>Snapshot not found</h1>")
        }
        let record = await storage.loadRecord(forKey: key)
        guard owner == capturedOwner, !Task.isCancelled else {
            return .html(403, "<h1>Reader changed</h1>")
        }
        let pageUrl = record?.url ?? ""
        if let response = await serveInstalledSnapshot(key: key, pageUrl: pageUrl) {
            return response
        }
        let html = await Task.detached {
            try? String(contentsOf: WebLibrary.snapshotPath(forKey: key), encoding: .utf8)
        }.value
        if let html {
            return .html(200, WebHtml.prepareHtml(html, pageUrl: pageUrl, offline: true))
        }
        return .html(404, WebHtml.prepareHtml(
            WebHtml.errorPage(
                url: pageUrl,
                message: "This page failed to load and no offline snapshot is saved."),
            pageUrl: pageUrl, offline: true))
    }
}
