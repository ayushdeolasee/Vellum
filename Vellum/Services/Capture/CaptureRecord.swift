import Foundation

// The share-extension capture inbox. A share extension gets a few hundred
// milliseconds and a hard memory ceiling, so it does exactly one thing: write a
// self-describing record into the App Group container and exit. The app drains
// that container later and does every expensive part (normalization, key
// derivation, fetch, archive) on its own time.
//
// FOUNDATION ONLY. This file, `CaptureRecordBuilder`, `CaptureInboxLayout` and
// `CaptureInboxWriter` are the four files the extension target compiles. They
// reference no WebKit, no CryptoKit, and nothing under `Services/Web`, so
// "the extension never runs the asset pipeline" is true because those symbols
// are not linked into it, not because a reviewer remembered.
//
// The App Group container is device-local and never syncs, so these bytes are
// NOT a cross-device contract. `schema_version` exists for app-update skew
// only: a record written by build N and drained by build N+1. The cross-device
// contract begins at ingest, where the result is an ordinary webpage sidecar.

struct CaptureRecord: Codable, Sendable, Equatable {
    enum Payload: String, Codable, Sendable {
        case full
        case urlOnly = "url_only"
    }

    enum DroppedReason: String, Codable, Sendable {
        case oversize
        case unavailable
    }

    /// The version this build writes.
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    /// Lowercase UUID.
    var captureID: String
    /// RFC3339, the webpage sidecar's exact writer shape.
    var capturedAt: String
    /// RAW as shared. Never normalized here — the app owns normalization so the
    /// extension and the library can't derive different keys.
    var sourceURL: String
    var title: String?
    var payload: Payload
    /// Present iff `payload == .full`.
    var outerHTML: String?
    var htmlByteCount: Int?
    /// Present iff `payload == .urlOnly`.
    var droppedReason: DroppedReason?
    var droppedHTMLByteCount: Int?
    /// ADVISORY ONLY. The drain always recomputes the page key and never trusts
    /// this, so extension/library key derivation cannot diverge.
    var pageKeyHint: String?
    /// e.g. `"0.1.0 (1)"`.
    var extensionBuild: String?
    /// Keys a future extension build added, carried across a decode/encode
    /// round trip so an older drain can never destroy what it doesn't parse.
    var unknownFields: [String: CaptureJSON] = [:]

    init(
        schemaVersion: Int = CaptureRecord.currentSchemaVersion,
        captureID: String,
        capturedAt: String,
        sourceURL: String,
        title: String? = nil,
        payload: Payload,
        outerHTML: String? = nil,
        htmlByteCount: Int? = nil,
        droppedReason: DroppedReason? = nil,
        droppedHTMLByteCount: Int? = nil,
        pageKeyHint: String? = nil,
        extensionBuild: String? = nil,
        unknownFields: [String: CaptureJSON] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.captureID = captureID
        self.capturedAt = capturedAt
        self.sourceURL = sourceURL
        self.title = title
        self.payload = payload
        self.outerHTML = outerHTML
        self.htmlByteCount = htmlByteCount
        self.droppedReason = droppedReason
        self.droppedHTMLByteCount = droppedHTMLByteCount
        self.pageKeyHint = pageKeyHint
        self.extensionBuild = extensionBuild
        self.unknownFields = unknownFields
    }

    /// A build only understands versions it wrote or predates. A newer record is
    /// reported, never thrown and never rewritten.
    var isSupportedSchema: Bool { schemaVersion <= Self.currentSchemaVersion }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case captureID = "capture_id"
        case capturedAt = "captured_at"
        case sourceURL = "source_url"
        case title
        case payload
        case outerHTML = "outer_html"
        case htmlByteCount = "html_byte_count"
        case droppedReason = "dropped_reason"
        case droppedHTMLByteCount = "dropped_html_byte_count"
        case pageKeyHint = "page_key_hint"
        case extensionBuild = "extension_build"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        captureID = try container.decode(String.self, forKey: .captureID)
        capturedAt = try container.decode(String.self, forKey: .capturedAt)
        sourceURL = try container.decode(String.self, forKey: .sourceURL)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        payload = try container.decode(Payload.self, forKey: .payload)
        outerHTML = try container.decodeIfPresent(String.self, forKey: .outerHTML)
        htmlByteCount = try container.decodeIfPresent(Int.self, forKey: .htmlByteCount)
        droppedReason = try container.decodeIfPresent(DroppedReason.self, forKey: .droppedReason)
        droppedHTMLByteCount = try container.decodeIfPresent(
            Int.self, forKey: .droppedHTMLByteCount)
        pageKeyHint = try container.decodeIfPresent(String.self, forKey: .pageKeyHint)
        extensionBuild = try container.decodeIfPresent(String.self, forKey: .extensionBuild)
        unknownFields = try CaptureJSON.unknownFields(
            in: decoder, known: CodingKeys.allCases.map(\.rawValue))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(captureID, forKey: .captureID)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(sourceURL, forKey: .sourceURL)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encode(payload, forKey: .payload)
        try container.encodeIfPresent(outerHTML, forKey: .outerHTML)
        try container.encodeIfPresent(htmlByteCount, forKey: .htmlByteCount)
        try container.encodeIfPresent(droppedReason, forKey: .droppedReason)
        try container.encodeIfPresent(droppedHTMLByteCount, forKey: .droppedHTMLByteCount)
        try container.encodeIfPresent(pageKeyHint, forKey: .pageKeyHint)
        try container.encodeIfPresent(extensionBuild, forKey: .extensionBuild)
        try CaptureJSON.encode(unknownFields, to: encoder)
    }
}

// MARK: - Decode outcome

/// Decoding a pending record has three answers and none of them are a thrown
/// error the caller has to interpret: the drain routes each one differently.
enum CaptureDecodeOutcome: Sendable, Equatable {
    case ok(CaptureRecord)
    /// Written by a newer build. Quarantined, never rewritten, never dropped.
    case unsupportedSchema(Int)
    case undecodable
}

// MARK: - Coding

enum CaptureCoding {
    /// Deterministic bytes so the wire format is assertable byte for byte.
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    static let decoder = JSONDecoder()

    static func encode(_ record: CaptureRecord) throws -> Data {
        try encoder.encode(record)
    }

    static func decode(_ data: Data) -> CaptureDecodeOutcome {
        guard let record = try? decoder.decode(CaptureRecord.self, from: data) else {
            return .undecodable
        }
        guard record.isSupportedSchema else { return .unsupportedSchema(record.schemaVersion) }
        return .ok(record)
    }
}

/// RFC3339 in the webpage sidecar's exact writer shape. Duplicated rather than
/// shared with `WebLibrary`/`PositionTimestamp` on purpose: those types live in
/// files the extension target must not compile.
enum CaptureTimestamp {
    static func string(from date: Date) -> String { writer.string(from: date) }

    /// Lenient: our own 6-digit-fraction shape first, then ISO8601 with and
    /// without fractional seconds, matching `WebLibrary.parseRfc3339`'s chain.
    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = writer.date(from: value) { return date }
        if let date = iso8601Fractional.date(from: value) { return date }
        return iso8601Plain.date(from: value)
    }

    private static let writer: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let iso8601Plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

// MARK: - Forward compatibility

/// Just enough JSON to carry keys this build doesn't know about across a
/// decode/encode round trip. Same number-fidelity rules as `PositionJSON`:
/// `Int`, then `Decimal` (so a value outside `Int`'s range keeps its digits
/// instead of going through `Double` and coming back mangled), then `Double`.
/// A number's written form is normalized — `2.0` carries out as `2` — because
/// `JSONEncoder` has no way to emit the other spelling.
indirect enum CaptureJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case decimal(Decimal)
    case double(Double)
    case string(String)
    case array([CaptureJSON])
    case object([String: CaptureJSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Decimal.self) {
            self = .decimal(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([CaptureJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: CaptureJSON].self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .decimal(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func unknownFields(in decoder: Decoder, known: [String]) throws -> [String: CaptureJSON] {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let knownKeys = Set(known)
        var extras: [String: CaptureJSON] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(CaptureJSON.self, forKey: key)
        }
        return extras
    }

    static func encode(_ fields: [String: CaptureJSON], to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyKey.self)
        for (name, value) in fields {
            try container.encode(value, forKey: AnyKey(name))
        }
    }
}
