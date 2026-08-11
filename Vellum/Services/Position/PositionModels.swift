import CryptoKit
import Foundation

// Reading position, "continue reading", and open-tab state used to ride along
// in the webpage sidecar (`web/records/<key>.json`), which also holds
// annotations. That made every scroll a read-modify-write of a file another
// device may be writing at the same instant — the hazard `WebLibrary` names at
// its per-record lock, which only serializes one device. This module is the
// separate, per-device, append-only-ish store that removes reading state from
// that write path entirely: each device owns exactly one file, nobody ever
// rewrites anybody else's, and the cross-device answer is computed by merging
// at read time instead of by sharing a mutable file.

// MARK: - Identity

/// Namespaced, content-derived document identity. The namespace prefix is part
/// of the wire format: `"web:<sha256hex>"`, `"pdf:<sha256hex>"`.
struct DocumentKey: Hashable, Sendable, Codable, CustomStringConvertible {
    enum Namespace: String, Sendable, Codable {
        case web
        case pdf
    }

    let namespace: Namespace
    /// Lowercase sha256 hex, 64 chars.
    let hash: String

    var rawValue: String { "\(namespace.rawValue):\(hash)" }
    var description: String { rawValue }

    private init(namespace: Namespace, hash: String) {
        self.namespace = namespace
        self.hash = hash
    }

    init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":"),
            let namespace = Namespace(rawValue: String(rawValue[rawValue.startIndex..<separator]))
        else { return nil }
        let hash = String(rawValue[rawValue.index(after: separator)...])
        guard hash.count == 64, hash.allSatisfy(Self.isLowercaseHexDigit) else { return nil }
        self.init(namespace: namespace, hash: hash)
    }

    /// Byte-identical to `WebLibrary.pageKey(normalizedUrl)`, namespaced.
    /// Caller passes the output of `WebUrl.normalize`.
    static func web(normalizedURL: String) -> DocumentKey {
        DocumentKey(namespace: .web, hash: WebLibrary.pageKey(normalizedURL))
    }

    /// Stable, device-independent PDF identity. `identifier` is expected to be
    /// a `/VellumDocumentId` UUID carried inside the PDF itself; until that
    /// exists, callers use `pdfPath(_:)`.
    static func pdf(stableIdentifier: String) -> DocumentKey {
        DocumentKey(namespace: .pdf, hash: sha256Hex(stableIdentifier))
    }

    /// Device-local fallback: sha256 of the filesystem path, matching
    /// `PageTextCache.pathKey`. Positions written under a path key resume
    /// correctly on the same device and are inert on other devices.
    static func pdfPath(_ path: String) -> DocumentKey {
        DocumentKey(namespace: .pdf, hash: PageTextCache.pathKey(path))
    }

    private static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func isLowercaseHexDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = DocumentKey(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not a document key: \(raw)")
        }
        self = key
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Values

/// A resume point. Treated as ONE atomic field: merging `page` from one device
/// with `scrollFraction` from another would produce a position that never
/// existed on any device.
struct ReadingPosition: Hashable, Sendable, Codable {
    /// 1-indexed, matching `TabDescriptor.currentPage`.
    var page: Int
    var pageCount: Int?
    /// 0...1 within the page/document.
    var scrollFraction: Double?
    /// Web text-quote anchor, mirroring `PositionData.prefix`/`.suffix`.
    var anchorPrefix: String?
    var anchorSuffix: String?
    /// CSS px, mirroring `PositionData.viewportOffset`.
    var viewportOffset: Double?

    init(
        page: Int,
        pageCount: Int? = nil,
        scrollFraction: Double? = nil,
        anchorPrefix: String? = nil,
        anchorSuffix: String? = nil,
        viewportOffset: Double? = nil
    ) {
        self.page = page
        self.pageCount = pageCount
        self.scrollFraction = scrollFraction
        self.anchorPrefix = anchorPrefix
        self.anchorSuffix = anchorSuffix
        self.viewportOffset = viewportOffset
    }

    enum CodingKeys: String, CodingKey {
        case page
        case pageCount = "page_count"
        case scrollFraction = "scroll_fraction"
        case anchorPrefix = "anchor_prefix"
        case anchorSuffix = "anchor_suffix"
        case viewportOffset = "viewport_offset"
    }
}

struct DeviceID: Hashable, Sendable, Codable, RawRepresentable, Comparable {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue
    }

    init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    static func < (lhs: DeviceID, rhs: DeviceID) -> Bool { lhs.rawValue < rhs.rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

struct DeviceIdentity: Hashable, Sendable {
    /// Canonical lowercase UUID string.
    let id: DeviceID
    /// Display only.
    let name: String
    /// "ios" | "ipados" | "macos".
    let platform: String

    init(id: DeviceID, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }

    var stub: DeviceIdentityStub { DeviceIdentityStub(id: id, name: name, platform: platform) }

    static let defaultsKey = "vellum.device-id"

    /// `UIDevice.current.name`/`.userInterfaceIdiom` are main-actor isolated and
    /// this is callable from any isolation, so the app layer installs what it
    /// sees rather than this reaching for UIKit.
    nonisolated(unsafe) static var nameOverride: String?
    nonisolated(unsafe) static var platformOverride: String?

    /// Mints and persists a per-install id in AppDefaults. Non-blocking: this
    /// is evaluated as `PositionStore.init`'s default argument, which is a main
    /// thread in practice.
    static func current() -> DeviceIdentity {
        let defaults = AppDefaults.current
        let id: String
        if let stored = defaults.string(forKey: defaultsKey), !stored.isEmpty {
            id = stored
        } else {
            id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: defaultsKey)
        }
        let platform = platformOverride ?? defaultPlatform
        return DeviceIdentity(
            id: DeviceID(id),
            name: nameOverride ?? defaultName(for: platform),
            platform: platform)
    }

    private static var defaultPlatform: String {
        #if os(macOS)
        return "macos"
        #else
        // The iOS target is universal now (TARGETED_DEVICE_FAMILY 1,2) but the
        // runtime idiom check is main-actor isolated and this is callable from
        // any isolation, so the compile-time answer stays "ipados" and the app
        // layer narrows it to "ios" on a phone through `platformOverride` when
        // phone sync identity lands. Nothing reads this as a capability flag —
        // it is a label on synced position records — so an iPhone reporting
        // "ipados" until then is cosmetic, not a correctness bug.
        return "ipados"
        #endif
    }

    /// A constant, deliberately: `ProcessInfo.processInfo.hostName` is
    /// documented as potentially performing a synchronous name resolution, so
    /// on a network with slow or absent reverse DNS it blocks whichever thread
    /// asks — here, the main thread at startup. It also answers with a hostname
    /// rather than the display name this field is contracted to carry
    /// ("Ayush's iPhone"), and that hostname would be baked into every synced
    /// record for peers to show. The app layer installs the real name into
    /// `nameOverride` from `UIDevice.current.name`, which is main-actor
    /// isolated and therefore cannot be read from here.
    private static func defaultName(for platform: String) -> String {
        switch platform {
        case "macos": return "Mac"
        case "ios": return "iPhone"
        default: return "iPad"
        }
    }
}

struct DeviceIdentityStub: Hashable, Sendable, Codable {
    let id: DeviceID
    let name: String
    let platform: String

    init(id: DeviceID, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}

enum PositionEvent: Sendable {
    case opened(title: String?, tabOrdinal: Int?)
    case titled(String)
    case moved(ReadingPosition)
    case closed
}

// MARK: - Wire format

/// A value plus the wall-clock instant the writing device produced it. Used
/// for every mergeable field whose value is not itself a time.
struct Stamped<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    var at: Date
    var value: Value

    init(at: Date, value: Value) {
        self.at = at
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case at
        case value
    }
}

/// Per-device open/tab state. Never merged into one answer (see `openElsewhere`).
struct OpenState: Hashable, Sendable, Codable {
    var isOpen: Bool
    var tabOrdinal: Int?

    init(isOpen: Bool, tabOrdinal: Int? = nil) {
        self.isOpen = isOpen
        self.tabOrdinal = tabOrdinal
    }

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case tabOrdinal = "tab_ordinal"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        tabOrdinal = try container.decodeIfPresent(Int.self, forKey: .tabOrdinal)
    }

    /// `tab_ordinal` is written even when absent: the pair is one value, and a
    /// missing key would read as "this build doesn't know about tab ordinals"
    /// rather than "there is no ordinal".
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOpen, forKey: .isOpen)
        try container.encode(tabOrdinal, forKey: .tabOrdinal)
    }
}

/// One device's whole reading history: `<device_id>.v<N>.json`.
struct PositionDeviceRecord: Hashable, Sendable, Codable {
    struct DocumentEntry: Hashable, Sendable, Codable {
        var readingPosition: Stamped<ReadingPosition>?
        /// Self-stamped: the value IS the timestamp, so "newest `at`" and
        /// "newest value" are the same comparison and the wrapper is dead weight.
        var openedAt: Date?
        var closedAt: Date?
        var title: Stamped<String>?
        var openState: Stamped<OpenState>?
        /// Keys a future build added, carried through a decode/encode round
        /// trip so this build can never destroy what it doesn't understand.
        var unknownFields: [String: PositionJSON] = [:]

        init(
            readingPosition: Stamped<ReadingPosition>? = nil,
            openedAt: Date? = nil,
            closedAt: Date? = nil,
            title: Stamped<String>? = nil,
            openState: Stamped<OpenState>? = nil,
            unknownFields: [String: PositionJSON] = [:]
        ) {
            self.readingPosition = readingPosition
            self.openedAt = openedAt
            self.closedAt = closedAt
            self.title = title
            self.openState = openState
            self.unknownFields = unknownFields
        }

        enum CodingKeys: String, CodingKey, CaseIterable {
            case readingPosition = "reading_position"
            case openedAt = "opened_at"
            case closedAt = "closed_at"
            case title
            case openState = "open_state"
        }

        /// The newest instant any field of this entry was stamped — the sort
        /// key the 512-document trim uses.
        var lastTouchedAt: Date? {
            [readingPosition?.at, openedAt, closedAt, title?.at, openState?.at]
                .compactMap { $0 }
                .max()
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            readingPosition = try container.decodeIfPresent(
                Stamped<ReadingPosition>.self, forKey: .readingPosition)
            openedAt = try container.decodeIfPresent(Date.self, forKey: .openedAt)
            closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
            title = try container.decodeIfPresent(Stamped<String>.self, forKey: .title)
            openState = try container.decodeIfPresent(Stamped<OpenState>.self, forKey: .openState)
            unknownFields = try PositionJSON.unknownFields(
                in: decoder, known: CodingKeys.allCases.map(\.rawValue))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(readingPosition, forKey: .readingPosition)
            try container.encodeIfPresent(openedAt, forKey: .openedAt)
            try container.encodeIfPresent(closedAt, forKey: .closedAt)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(openState, forKey: .openState)
            try PositionJSON.encode(unknownFields, to: encoder)
        }
    }

    /// A device record is trimmed to its most recently touched documents:
    /// 512 x ~350 bytes stays inside a sane single-file atomic replace.
    static let maxDocuments = 512

    var schemaVersion: Int
    var deviceID: DeviceID
    var deviceName: String
    var devicePlatform: String
    var writtenAt: Date
    var documents: [DocumentKey: DocumentEntry]
    var unknownFields: [String: PositionJSON] = [:]

    /// The version parsed out of the file name this record was read from.
    /// `nil` for records built in memory. A disagreement with `schemaVersion`
    /// means the bytes are not what the name claims, so the merge drops it.
    var fileNameVersion: Int?

    init(
        schemaVersion: Int = PositionLayout.schemaVersion,
        deviceID: DeviceID,
        deviceName: String,
        devicePlatform: String,
        writtenAt: Date,
        documents: [DocumentKey: DocumentEntry] = [:],
        unknownFields: [String: PositionJSON] = [:],
        fileNameVersion: Int? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.devicePlatform = devicePlatform
        self.writtenAt = writtenAt
        self.documents = documents
        self.unknownFields = unknownFields
        self.fileNameVersion = fileNameVersion
    }

    var deviceStub: DeviceIdentityStub {
        DeviceIdentityStub(id: deviceID, name: deviceName, platform: devicePlatform)
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion = "schema_version"
        case deviceID = "device_id"
        case deviceName = "device_name"
        case devicePlatform = "device_platform"
        case writtenAt = "written_at"
        case documents
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        deviceID = try container.decode(DeviceID.self, forKey: .deviceID)
        deviceName = try container.decodeIfPresent(String.self, forKey: .deviceName) ?? ""
        devicePlatform = try container.decodeIfPresent(String.self, forKey: .devicePlatform) ?? ""
        writtenAt = try container.decode(Date.self, forKey: .writtenAt)
        let raw = try container.decodeIfPresent([String: DocumentEntry].self, forKey: .documents) ?? [:]
        // A key from a future namespace is skipped, not fatal: the rest of the
        // file is still this device's authoritative history.
        documents = raw.reduce(into: [:]) { result, pair in
            guard let key = DocumentKey(rawValue: pair.key) else { return }
            result[key] = pair.value
        }
        unknownFields = try PositionJSON.unknownFields(
            in: decoder, known: CodingKeys.allCases.map(\.rawValue))
        fileNameVersion = nil
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(deviceID, forKey: .deviceID)
        try container.encode(deviceName, forKey: .deviceName)
        try container.encode(devicePlatform, forKey: .devicePlatform)
        try container.encode(writtenAt, forKey: .writtenAt)
        var byRawKey: [String: DocumentEntry] = [:]
        for (key, entry) in documents { byRawKey[key.rawValue] = entry }
        try container.encode(byRawKey, forKey: .documents)
        try PositionJSON.encode(unknownFields, to: encoder)
    }

    /// Drops the least-recently-touched documents. Only ever applied to the
    /// writing device's own file, so it can never destroy another device's
    /// history.
    mutating func trimToMostRecent(_ limit: Int = maxDocuments) {
        guard documents.count > limit else { return }
        let ordered = documents.sorted { lhs, rhs in
            let left = lhs.value.lastTouchedAt ?? .distantPast
            let right = rhs.value.lastTouchedAt ?? .distantPast
            if left == right { return lhs.key.rawValue > rhs.key.rawValue }
            return left > right
        }
        documents = Dictionary(uniqueKeysWithValues: ordered.prefix(limit).map { ($0.key, $0.value) })
    }
}

// MARK: - Merged view

struct MergedField<Value: Hashable & Sendable>: Hashable, Sendable {
    let at: Date
    let device: DeviceIdentityStub
    let value: Value
}

/// The cross-device answer for one document. Every mergeable field carries the
/// device that won it; `openOn` is deliberately NOT merged into one answer.
struct MergedDocumentPosition: Hashable, Sendable {
    let key: DocumentKey
    var readingPosition: MergedField<ReadingPosition>?
    var openedAt: MergedField<Date>?
    var closedAt: MergedField<Date>?
    var title: MergedField<String>?
    var openOn: [DeviceIdentityStub] = []

    init(key: DocumentKey) {
        self.key = key
    }

    /// The instant a "continue reading" row should sort by: the merged
    /// `opened_at` when there is one, otherwise the newest stamp of any field,
    /// so a document that was only ever scrolled still surfaces.
    var effectiveOpenedAt: Date? {
        openedAt?.value ?? [readingPosition?.at, closedAt?.at, title?.at].compactMap { $0 }.max()
    }
}

/// One row of the merged, cross-device view. Home's "continue reading" reads
/// this — never a single device's raw record.
struct ResumeEntry: Hashable, Sendable {
    let key: DocumentKey
    let title: String?
    /// Newest across all devices.
    let openedAt: Date
    /// Newest across all devices.
    let position: ReadingPosition?
    /// Which device produced `openedAt`.
    let lastOpenedOn: DeviceIdentityStub?
    /// Devices reporting it currently open.
    let openElsewhere: [DeviceIdentityStub]

    init(
        key: DocumentKey,
        title: String?,
        openedAt: Date,
        position: ReadingPosition?,
        lastOpenedOn: DeviceIdentityStub?,
        openElsewhere: [DeviceIdentityStub]
    ) {
        self.key = key
        self.title = title
        self.openedAt = openedAt
        self.position = position
        self.lastOpenedOn = lastOpenedOn
        self.openElsewhere = openElsewhere
    }
}

// MARK: - Forward compatibility

/// Just enough JSON to carry keys this build doesn't know about across a
/// decode/encode round trip.
///
/// Number fidelity, precisely: a number is tried as `Int`, then `Decimal`, then
/// `Double`. `Decimal` sits in the middle because it is the only one of the
/// three that survives a value outside `Int`'s range without losing digits —
/// `12345678901234567890` becomes `1.2345678901234567e+19` through `Double` and
/// comes back out mangled, which for a cross-device file is a v1 build
/// corrupting a v2 build's field while claiming to merely carry it.
///
/// What is NOT preserved is a number's WRITTEN FORM: `2.0` carries back out as
/// `2`. That is a limit of `JSONEncoder`, not a choice here — it emits `2` for
/// `Double(2.0)` and for `Decimal(string: "2.0")` alike, and `JSONDecoder`
/// normalizes both on the way in, so no case of this enum can round-trip the
/// trailing `.0`. Values are preserved; JSON number *spelling* is normalized.
/// Pinned by "An integral float from a future version carries its value, not
/// its spelling".
indirect enum PositionJSON: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case decimal(Decimal)
    case double(Double)
    case string(String)
    case array([PositionJSON])
    case object([String: PositionJSON])

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
        } else if let value = try? container.decode([PositionJSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: PositionJSON].self))
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

    static func unknownFields(in decoder: Decoder, known: [String]) throws -> [String: PositionJSON] {
        let container = try decoder.container(keyedBy: AnyKey.self)
        let knownKeys = Set(known)
        var extras: [String: PositionJSON] = [:]
        for key in container.allKeys where !knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try container.decode(PositionJSON.self, forKey: key)
        }
        return extras
    }

    static func encode(_ fields: [String: PositionJSON], to encoder: Encoder) throws {
        guard !fields.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyKey.self)
        for (name, value) in fields {
            try container.encode(value, forKey: AnyKey(name))
        }
    }
}

// MARK: - Coding

/// RFC3339 in `WebLibrary`'s exact writer shape, so a position timestamp and a
/// sidecar timestamp sort and parse interchangeably.
enum PositionTimestamp {
    static func string(from date: Date) -> String { formatter.string(from: date) }

    static func parse(_ value: String) -> Date? { WebLibrary.parseRfc3339(value) }

    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSS'+00:00'"
        return formatter
    }()
}

enum PositionCoding {
    /// Deterministic bytes: these files sync, so stable ordering and small
    /// output beat the sidecar's pretty printing.
    nonisolated(unsafe) static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PositionTimestamp.string(from: date))
        }
        return encoder
    }()

    nonisolated(unsafe) static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let date = PositionTimestamp.parse(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: try decoder.singleValueContainer(),
                    debugDescription: "Not an RFC3339 timestamp: \(raw)")
            }
            return date
        }
        return decoder
    }()
}
