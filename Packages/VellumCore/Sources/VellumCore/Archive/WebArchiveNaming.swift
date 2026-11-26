import Foundation

public struct WebArchiveIndexContents: Codable, Sendable, Equatable {
    public var unknownFields: [String: JSONValue] = [:]

    public var version: Int
    public var entries: [String: String]

    public init() {
        version = 1
        entries = [:]
    }
}

extension WebArchiveIndexContents {
    private enum CodingKeys: String, CodingKey {
        case version, entries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        entries = try container.decode([String: String].self, forKey: .entries)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(entries, forKey: .entries)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

public enum WebArchiveNaming {
    /// Filesystem-safe display name: strip path separators and control chars,
    /// collapse whitespace, trim leading dots (hidden files), cap the length.
    /// Falls back to the URL's host+path when the title is empty.
    public static func sanitizedBaseName(title: String?, url: String) -> String {
        var source = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if source.isEmpty {
            // Lenient Foundation URL parsing can yield a path but no host —
            // never emit a dangling "host — " / "— tail" fragment.
            let parsed = URL(string: url)
            let host = parsed?.host ?? ""
            let tail = parsed?.path.split(separator: "/").last.map(String.init) ?? ""
            switch (host.isEmpty, tail.isEmpty) {
            case (false, false): source = "\(host) — \(tail)"
            case (false, true): source = host
            case (true, _): source = tail
            }
        }
        if source.isEmpty { source = "Web Page" }
        var cleaned = ""
        for scalar in source.unicodeScalars {
            if scalar == "/" || scalar == ":" || scalar == "\\" {
                cleaned.append("-")
            } else if scalar.properties.generalCategory == .control {
                continue
            } else {
                cleaned.unicodeScalars.append(scalar)
            }
        }
        cleaned = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 80 {
            cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces)
        }
        return cleaned.isEmpty ? "Web Page" : cleaned
    }
}

extension WebArchiveNaming {
    static let ext = ".vellumweb"

    static func validKey(_ key: String) -> Bool {
        key.utf8.count == 64 && key.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func validLeaf(_ name: String) -> Bool {
        !name.hasPrefix(".") && name.lowercased().hasSuffix(ext) && name.precomposedStringWithCanonicalMapping.utf8.count <= 255
            && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !SyncArtifact.matches(name.lowercased())
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    private static func folded(_ name: String) -> String {
        name.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    // Reserve room for the suffix in either filesystem spelling. A single
    // Hangul syllable, for example, can take nine UTF-8 bytes on Darwin.
    private static func name(_ stem: String, suffix: String = "") -> String {
        let tail = suffix + ext
        let limit = 255 - tail.utf8.count
        var bytes = 0
        let base = stem.precomposedStringWithCanonicalMapping.unicodeScalars.prefix { scalar in
            bytes += max(scalar.utf8.count, String(scalar).decomposedStringWithCanonicalMapping.utf8.count)
            return bytes <= limit
        }
        return String(base) + tail
    }

    static func base(title: String?, url: String) -> String {
        sanitizedBaseName(title: title, url: url).replacingOccurrences(
            of: ".sync-conflict-", with: "-sync-conflict-", options: .caseInsensitive)
    }

    /// Allocate every natural title before any suffix, so another article can
    /// legitimately be called "Paper (abcdef)". Inputs include absent index claims.
    static func names(bases: [String: String], occupied: [String]) -> [String: String] {
        var taken = Set(occupied.map(folded))
        var result: [String: String] = [:]
        let keys = bases.keys.sorted()
        for key in keys {
            let candidate = name(bases[key]!)
            if taken.insert(folded(candidate)).inserted { result[key] = candidate }
        }
        for key in keys where result[key] == nil {
            let base = bases[key]!
            var length = 6
            var counter = 0
            while true {
                let disambiguator = String(key.prefix(length)) + (counter == 0 ? "" : "-\(counter)")
                let candidate = name(base, suffix: " (\(disambiguator))")
                if taken.insert(folded(candidate)).inserted {
                    result[key] = candidate
                    break
                }
                if length < key.count { length += 1 } else { counter += 1 }
            }
        }
        return result
    }
}

extension WebArchiveIndexContents {
    static func checked(_ bytes: Data) throws -> Self {
        let value = try JSONDecoder().decode(Self.self, from: bytes)
        guard value.entries.allSatisfy({ WebArchiveNaming.validKey($0.key) && WebArchiveNaming.validLeaf($0.value) })
        else { throw ArchiveCodecError.invalidDocument("Unsafe archive index entry") }
        return value
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// S5b keeps the original version bytes, including conflicting unknown
    /// scalars. Select their live value consistently, and union unknown objects.
    static func merge(_ versions: [Self]) throws -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        func combine(_ lhs: JSONValue, _ rhs: JSONValue) throws -> JSONValue {
            if case .object(let a) = lhs, case .object(let b) = rhs {
                return .object(try a.merging(b, uniquingKeysWith: combine))
            }
            return try encoder.encode(lhs).lexicographicallyPrecedes(encoder.encode(rhs)) ? lhs : rhs
        }
        var merged = Self()
        for other in versions {
            merged.version = max(merged.version, other.version)
            merged.unknownFields = try merged.unknownFields.merging(other.unknownFields, uniquingKeysWith: combine)
            merged.entries.merge(other.entries) { $0.utf8.lexicographicallyPrecedes($1.utf8) ? $0 : $1 }
        }
        merged.entries = WebArchiveNaming.names(bases: merged.entries.mapValues {
            String($0.dropLast(WebArchiveNaming.ext.count))
        }, occupied: [])
        return merged
    }
}
