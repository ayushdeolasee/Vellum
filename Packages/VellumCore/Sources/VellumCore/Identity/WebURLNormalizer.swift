import Foundation

public enum WebURLNormalizationError: Error {
    case invalidDocument(String)
}

public enum WebURLNormalizer {
    /// Normalize a user-supplied URL: default to https, strip fragments and
    /// tracking params so the same article always maps to one record. The
    /// output must match the Rust `url` crate's serialization (the sha256 of
    /// this string is the on-disk storage key).
    public static func normalize(_ raw: String, httpsOnly: Bool) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw WebURLNormalizationError.invalidDocument("Empty URL")
        }
        var candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        // The WHATWG parser strips ASCII tab/newline anywhere in the input.
        candidate = candidate.filter { $0 != "\t" && $0 != "\n" && $0 != "\r" }

        // Scheme
        guard let colon = candidate.firstIndex(of: ":") else {
            throw WebURLNormalizationError.invalidDocument("Invalid URL: relative URL without a base")
        }
        let schemeRaw = String(candidate[candidate.startIndex..<colon])
        guard isValidScheme(schemeRaw) else {
            throw WebURLNormalizationError.invalidDocument("Invalid URL: relative URL without a base")
        }
        let scheme = schemeRaw.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw WebURLNormalizationError.invalidDocument("Unsupported URL scheme: \(scheme)")
        }
        guard !httpsOnly || scheme == "https" else {
            throw WebURLNormalizationError.invalidDocument(
                "Plain HTTP webpages aren't supported. Use an HTTPS address.")
        }

        var rest = String(candidate[candidate.index(after: colon)...])
        guard rest.hasPrefix("//") else {
            throw WebURLNormalizationError.invalidDocument("URL has no host")
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
                throw WebURLNormalizationError.invalidDocument("Invalid URL: invalid IPv6 address")
            }
            host = String(hostPort[hostPort.startIndex...close])
            let after = String(hostPort[hostPort.index(after: close)...])
            if after.hasPrefix(":") {
                portString = String(after.dropFirst())
            } else if !after.isEmpty {
                throw WebURLNormalizationError.invalidDocument("Invalid URL: invalid port number")
            }
        } else if let colonIdx = hostPort.lastIndex(of: ":") {
            host = String(hostPort[hostPort.startIndex..<colonIdx])
            portString = String(hostPort[hostPort.index(after: colonIdx)...])
        } else {
            host = hostPort
        }
        host = host.lowercased()
        if host.isEmpty {
            throw WebURLNormalizationError.invalidDocument("Invalid URL: empty host")
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
                throw WebURLNormalizationError.invalidDocument("Invalid URL: invalid port number")
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
        if let userinfo, !userinfo.isEmpty { out += "\(encodeUserinfo(userinfo))@" }
        out += host
        if let port { out += ":\(port)" }
        out += path
        if let query { out += "?\(query)" }
        return out
    }

    private static func isTrackingParam(_ key: String) -> Bool {
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
                    throw WebURLNormalizationError.invalidDocument(
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
        let bytes = Array(segment.utf8)
        var out = ""
        var i = 0
        func isHex(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
        while i < bytes.count {
            let byte = bytes[i]
            let c = Character(UnicodeScalar(byte))
            if c == "%" {
                // Keep valid %XX escapes verbatim (they're already-encoded input);
                // a stray % would otherwise produce an invalid URL that
                // URL(string:) rejects or re-encodes, breaking round-trip identity.
                if i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                    out.append("%")
                } else {
                    out += "%25"
                }
                i += 1
                continue
            }
            let needsEncoding = byte < 0x20 || byte > 0x7e
                || c == " " || c == "\"" || c == "<" || c == ">" || c == "`"
                || c == "#" || c == "?" || c == "{" || c == "}"
            if needsEncoding {
                out += String(format: "%%%02X", byte)
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// RFC 3986 userinfo: unreserved / pct-encoded / sub-delims / ":".
    /// Everything else — including a raw "@" from a multi-@ authority — gets
    /// percent-encoded so normalize's WHATWG-style split (last "@") and
    /// Foundation's URLComponents re-parse in realUrl agree on the same host.
    private static func encodeUserinfo(_ userinfo: String) -> String {
        let bytes = Array(userinfo.utf8)
        var out = ""
        var i = 0
        func isHex(_ b: UInt8) -> Bool {
            (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
        }
        // unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~"
        // sub-delims: "!" / "$" / "&" / "'" / "(" / ")" / "*" / "+" / "," / ";" / "="
        // plus ":" — all allowed verbatim in userinfo.
        let allowedExtras: Set<Character> = ["-", ".", "_", "~", "!", "$", "&", "'", "(", ")", "*", "+", ",", ";", "=", ":"]
        while i < bytes.count {
            let byte = bytes[i]
            let c = Character(UnicodeScalar(byte))
            if c == "%" {
                if i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                    out.append("%")
                } else {
                    out += "%25"
                }
                i += 1
                continue
            }
            let isUnreserved = (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
            if isUnreserved || allowedExtras.contains(c) {
                out.append(c)
            } else {
                out += String(format: "%%%02X", byte)
            }
            i += 1
        }
        return out
    }

    /// application/x-www-form-urlencoded parse ('+' means space).
    private static func parseFormPairs(_ query: String) -> [(String, String)] {
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

    private static func formDecode(_ value: String) -> String {
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
    private static func formEncode(_ value: String) -> String {
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
