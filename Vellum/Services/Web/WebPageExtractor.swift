import Foundation
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
        // rust-url runs domains through IDNA (UTS-46 → punycode). Full UTS-46
        // mapping is out of scope here, but lowercasing + NFC + RFC 3492
        // punycode reproduces the crate's output for real-world hosts, so
        // "münchen.de" keys the same record as the Tauri app's
        // "xn--mnchen-3ya.de".
        if !host.hasPrefix("["), !host.allSatisfy(\.isASCII) {
            host = try idnaToAscii(host)
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

    /// IDNA ToASCII for an already-lowercased host: NFC-normalize each label
    /// and punycode-encode the non-ASCII ones (error message matches
    /// rust-url's Display for ParseError::IdnaError).
    private static func idnaToAscii(_ host: String) throws -> String {
        let labels = try host
            .split(separator: ".", omittingEmptySubsequences: false)
            .map { piece -> String in
                let label = String(piece)
                if label.allSatisfy(\.isASCII) { return label }
                let normalized = label.precomposedStringWithCanonicalMapping
                if normalized.allSatisfy(\.isASCII) { return normalized }
                guard let encoded = punycodeEncode(normalized) else {
                    throw SessionServiceError.invalidDocument(
                        "Invalid URL: invalid international domain name")
                }
                return "xn--" + encoded
            }
        return labels.joined(separator: ".")
    }

    /// RFC 3492 punycode encoding (base 36, tmin 1, tmax 26, skew 38,
    /// damp 700, initial bias 72, initial n 128). Returns nil on overflow.
    private static func punycodeEncode(_ label: String) -> String? {
        let input = Array(label.unicodeScalars)
        var output = ""
        for scalar in input where scalar.isASCII {
            output.unicodeScalars.append(scalar)
        }
        let basicCount = output.unicodeScalars.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }

        func digit(_ value: UInt32) -> Character {
            value < 26
                ? Character(UnicodeScalar(UInt8(ascii: "a") + UInt8(value)))
                : Character(UnicodeScalar(UInt8(ascii: "0") + UInt8(value - 26)))
        }
        func adapt(_ delta: UInt32, _ numPoints: UInt32, _ firstTime: Bool) -> UInt32 {
            var delta = firstTime ? delta / 700 : delta / 2
            delta += delta / numPoints
            var k: UInt32 = 0
            while delta > (35 * 26) / 2 {
                delta /= 36
                k += 36
            }
            return k + 36 * delta / (delta + 38)
        }

        var n: UInt32 = 128
        var delta: UInt32 = 0
        var bias: UInt32 = 72
        while handled < input.count {
            guard let m = input.lazy.map(\.value).filter({ $0 >= n }).min() else { return nil }
            let (step, stepOverflow) = (m - n).multipliedReportingOverflow(by: UInt32(handled + 1))
            if stepOverflow { return nil }
            let (next, nextOverflow) = delta.addingReportingOverflow(step)
            if nextOverflow { return nil }
            delta = next
            n = m
            for scalar in input {
                if scalar.value < n {
                    let (bumped, overflow) = delta.addingReportingOverflow(1)
                    if overflow { return nil }
                    delta = bumped
                }
                if scalar.value == n {
                    var q = delta
                    var k: UInt32 = 36
                    while true {
                        let t = k <= bias ? 1 : (k >= bias + 26 ? 26 : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (36 - t)))
                        q = (q - t) / (36 - t)
                        k += 36
                    }
                    output.append(digit(q))
                    bias = adapt(delta, UInt32(handled + 1), handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }

    /// WHATWG-style path canonicalization for special schemes: '\' → '/',
    /// dot-segment resolution, percent-encoding of the path encode set
    /// (existing percent-escapes pass through untouched). Only "." and ".."
    /// dot-segments are resolved — empty segments are PRESERVED ("/a//b"
    /// stays "/a//b"), matching the rust `url` crate whose serialization
    /// feeds the sha256 storage key.
    private static func normalizePath(_ raw: String) -> String {
        let path = raw.replacingOccurrences(of: "\\", with: "/")
        if path.isEmpty { return "/" }
        // `path` starts with "/" (the authority scan stops at the first
        // slash), so the piece before it is the empty string — skip it and
        // treat the rest as WHATWG path-state segments.
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        var segments: [String] = []
        for (offset, piece) in pieces.enumerated().dropFirst() {
            let segment = String(piece)
            let isLast = offset == pieces.count - 1
            let lowered = segment.lowercased()
                .replacingOccurrences(of: "%2e", with: ".")
            if lowered == "." {
                // A trailing "." keeps the trailing slash ("/a/." → "/a/").
                if isLast { segments.append("") }
                continue
            }
            if lowered == ".." {
                if !segments.isEmpty { segments.removeLast() }
                if isLast { segments.append("") }
                continue
            }
            segments.append(segment)
        }
        return "/" + segments.map(encodePathSegment).joined(separator: "/")
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
    /// Second registered scheme for plain-http targets: the proxy authority
    /// mirrors the real host, so the real scheme has to live in the custom
    /// scheme name itself ("i" = insecure).
    static let insecureScheme = "vellum-webi"
    /// Reserved authorities — `.invalid` is an RFC 2606 TLD that can never
    /// resolve, so these cannot collide with a real site's own hosts/paths.
    static let assetHost = "assets.vellum.invalid"
    static let snapshotHost = "snapshot.vellum.invalid"

    /// Build the reader URL for a target page. The mapping keeps the real
    /// authority/path/query so in-page routers see the address they were
    /// server-rendered for — `window.location.pathname` must match, or SPA
    /// hydration tears the page down (see plans/web-proxy-truthful-urls.html).
    static func proxyUrl(for target: String) -> URL {
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
        return URL(string: mapped) ?? URL(string: "\(scheme)://\(snapshotHost)/")!
    }

    /// Reader URL that explicitly requests the offline snapshot for a page
    /// key (navigation-failure fallback).
    static func snapshotUrl(forKey key: String) -> URL {
        URL(string: "\(scheme)://\(snapshotHost)/\(key)")!
    }

    /// Map a proxy URL back to the real page URL (inverse of `proxyUrl`).
    /// Percent-encoding is taken verbatim from the request so the round trip
    /// through WKWebView cannot change page identity. Returns nil for the
    /// reserved authorities and foreign schemes.
    static func realUrl(from url: URL) -> String? {
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

    private var activeTasks: Set<ObjectIdentifier> = []

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        activeTasks.insert(id)
        let request = urlSchemeTask.request
        Task { @MainActor [weak self] in
            let response = await Self.handleRequest(request)
            guard let self, self.activeTasks.contains(id) else { return }
            self.activeTasks.remove(id)
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
        activeTasks.remove(ObjectIdentifier(urlSchemeTask))
    }

    // MARK: Routing

    private static func handleRequest(_ request: URLRequest) async -> WebProxyResponse {
        guard let url = request.url, let host = url.host?.lowercased() else {
            return .html(404, "<h1>Invalid request</h1>")
        }

        // Reserved authorities first: archive assets and the explicit
        // offline-snapshot fallback.
        if host == assetHost {
            return serveArchiveAsset(rest: String(url.path.dropFirst()))
        }
        if host == snapshotHost {
            return serveSnapshotFallback(key: String(url.path.dropFirst()))
        }

        // Everything else is the page authority: map the truthful proxy URL
        // back to the real page URL.
        guard let rawUrl = realUrl(from: url) else {
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
        let snapshotFile = WebLibrary.snapshotPath(forKey: key)
        let record = WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key))
        let recordSaved = record?.saved ?? false
        let snapshotOnly = record?.loadingPolicy == "snapshot-only"

        // Pinned-snapshot policy (from an imported archive): don't hit the
        // network at all when the installed snapshot is available.
        if snapshotOnly, let response = serveInstalledSnapshot(key: key, pageUrl: pageUrl) {
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
            if let response = serveInstalledSnapshot(key: key, pageUrl: pageUrl) {
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

    /// `vellum-web://assets.vellum.invalid/<key>/<name>` →
    /// `<appData>/web/archives/<key>/assets/<name>`.
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
                // Pages and assets live on different origins now; CORS-mode
                // loads (SVG <use>, crossorigin attrs) need this to succeed.
                "Access-Control-Allow-Origin": "*",
            ],
            body: bytes)
    }

    /// Serve the installed self-contained snapshot with asset placeholders
    /// resolved to the reserved asset authority.
    private static func serveInstalledSnapshot(key: String, pageUrl: String) -> WebProxyResponse? {
        let snapshot = WebLibrary.archiveDir(forKey: key).appendingPathComponent("snapshot.html")
        guard let html = try? String(contentsOf: snapshot, encoding: .utf8) else { return nil }
        let resolved = WebArchive.resolveAssetPlaceholders(
            html, assetBase: "\(scheme)://\(assetHost)/\(key)")
        return .html(200, WebHtml.prepareHtml(resolved, pageUrl: pageUrl, offline: true))
    }

    /// Explicit snapshot request (navigation-failure fallback): installed
    /// archive snapshot first, then the plain saved snapshot, else Vellum's
    /// own error page — the webview must never end up on WebKit's native one.
    private static func serveSnapshotFallback(key: String) -> WebProxyResponse {
        guard !key.isEmpty, key.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            return .html(404, "<h1>Snapshot not found</h1>")
        }
        let record = WebLibrary.loadRecord(at: WebLibrary.recordPath(forKey: key))
        let pageUrl = record?.url ?? ""
        if let response = serveInstalledSnapshot(key: key, pageUrl: pageUrl) {
            return response
        }
        if let html = try? String(
            contentsOf: WebLibrary.snapshotPath(forKey: key), encoding: .utf8) {
            return .html(200, WebHtml.prepareHtml(html, pageUrl: pageUrl, offline: true))
        }
        return .html(404, WebHtml.prepareHtml(
            WebHtml.errorPage(
                url: pageUrl,
                message: "This page failed to load and no offline snapshot is saved."),
            pageUrl: pageUrl, offline: true))
    }
}
