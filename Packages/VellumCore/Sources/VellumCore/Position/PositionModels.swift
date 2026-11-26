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
public struct DocumentKey: Hashable, Sendable, Codable, CustomStringConvertible {
    public enum Namespace: String, Sendable, Codable {
        case web
        case pdf
    }

    public let namespace: Namespace
    /// Lowercase sha256 hex, 64 chars.
    public let hash: String

    public var rawValue: String { "\(namespace.rawValue):\(hash)" }
    public var description: String { rawValue }

    private init(namespace: Namespace, hash: String) {
        self.namespace = namespace
        self.hash = hash
    }

    public init?(rawValue: String) {
        guard let separator = rawValue.firstIndex(of: ":"),
            let namespace = Namespace(rawValue: String(rawValue[rawValue.startIndex..<separator]))
        else { return nil }
        let hash = String(rawValue[rawValue.index(after: separator)...])
        guard hash.count == 64, hash.allSatisfy(Self.isLowercaseHexDigit) else { return nil }
        self.init(namespace: namespace, hash: hash)
    }

    /// Byte-identical to `WebLibrary.pageKey(normalizedUrl)`, namespaced.
    /// Caller passes the output of `WebUrl.normalize`.
    public static func web(normalizedURL: String) -> DocumentKey {
        DocumentKey(namespace: .web, hash: DocumentIdentity.sha256Hex(normalizedURL))
    }

    /// Stable, device-independent PDF identity. `identifier` is expected to be
    /// a `/VellumDocumentId` UUID carried inside the PDF itself; until that
    /// exists, callers use `pdfPath(_:)`.
    public static func pdf(stableIdentifier: String) -> DocumentKey {
        DocumentKey(namespace: .pdf, hash: DocumentIdentity.sha256Hex(stableIdentifier))
    }

    /// Device-local fallback: sha256 of the filesystem path, matching
    /// `PageTextCache.pathKey`. Positions written under a path key resume
    /// correctly on the same device and are inert on other devices.
    public static func pdfPath(_ path: String) -> DocumentKey {
        DocumentKey(namespace: .pdf, hash: DocumentIdentity.sha256Hex(path))
    }

    private static func isLowercaseHexDigit(_ character: Character) -> Bool {
        ("0"..."9").contains(character) || ("a"..."f").contains(character)
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let key = DocumentKey(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Not a document key: \(raw)")
        }
        self = key
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Values

/// A resume point. Treated as ONE atomic field: merging `page` from one device
/// with `scrollFraction` from another would produce a position that never
/// existed on any device.
public struct ReadingPosition: Hashable, Sendable, Codable {
    /// 1-indexed, matching `TabDescriptor.currentPage`.
    public var page: Int
    public var pageCount: Int?
    /// 0...1 within the page/document.
    public var scrollFraction: Double?
    /// Web text-quote anchor, mirroring `PositionData.prefix`/`.suffix`.
    public var anchorPrefix: String?
    public var anchorSuffix: String?
    /// CSS px, mirroring `PositionData.viewportOffset`.
    public var viewportOffset: Double?

    public init(
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

public struct DeviceID: Hashable, Sendable, Codable, RawRepresentable, Comparable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public static func < (lhs: DeviceID, rhs: DeviceID) -> Bool { lhs.rawValue < rhs.rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct DeviceIdentity: Hashable, Sendable {
    /// Canonical lowercase UUID string.
    public let id: DeviceID
    /// Display only.
    public let name: String
    /// "ios" | "ipados" | "macos" | "linux".
    public let platform: String

    public init(id: DeviceID, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }

    public var stub: DeviceIdentityStub { DeviceIdentityStub(id: id, name: name, platform: platform) }

    public static let defaultsKey = "vellum.device-id"
}

public struct DeviceIdentityStub: Hashable, Sendable, Codable {
    public let id: DeviceID
    public let name: String
    public let platform: String

    public init(id: DeviceID, name: String, platform: String) {
        self.id = id
        self.name = name
        self.platform = platform
    }
}

public enum PositionEvent: Sendable {
    case opened(title: String?, tabOrdinal: Int?)
    case titled(String)
    case moved(ReadingPosition)
    case closed
}

// MARK: - Wire format

/// A value plus the wall-clock instant the writing device produced it. Used
/// for every mergeable field whose value is not itself a time.
public struct Stamped<Value: Hashable & Sendable & Codable>: Hashable, Sendable, Codable {
    public var at: Date
    public var value: Value

    public init(at: Date, value: Value) {
        self.at = at
        self.value = value
    }

    enum CodingKeys: String, CodingKey {
        case at
        case value
    }
}

/// Per-device open/tab state. Never merged into one answer (see `openElsewhere`).
public struct OpenState: Hashable, Sendable, Codable {
    public var isOpen: Bool
    public var tabOrdinal: Int?

    public init(isOpen: Bool, tabOrdinal: Int? = nil) {
        self.isOpen = isOpen
        self.tabOrdinal = tabOrdinal
    }

    enum CodingKeys: String, CodingKey {
        case isOpen = "is_open"
        case tabOrdinal = "tab_ordinal"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isOpen = try container.decodeIfPresent(Bool.self, forKey: .isOpen) ?? false
        tabOrdinal = try container.decodeIfPresent(Int.self, forKey: .tabOrdinal)
    }

    /// `tab_ordinal` is written even when absent: the pair is one value, and a
    /// missing key would read as "this build doesn't know about tab ordinals"
    /// rather than "there is no ordinal".
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(isOpen, forKey: .isOpen)
        try container.encode(tabOrdinal, forKey: .tabOrdinal)
    }
}

/// One device's whole reading history: `<device_id>.v<N>.json`.
public struct PositionDeviceRecord: Hashable, Sendable, Codable {
    public struct DocumentEntry: Hashable, Sendable, Codable {
        public var readingPosition: Stamped<ReadingPosition>?
        /// Self-stamped: the value IS the timestamp, so "newest `at`" and
        /// "newest value" are the same comparison and the wrapper is dead weight.
        public var openedAt: Date?
        public var closedAt: Date?
        public var title: Stamped<String>?
        public var openState: Stamped<OpenState>?
        /// Keys a future build added, carried through a decode/encode round
        /// trip so this build can never destroy what it doesn't understand.
        public var unknownFields: [String: PositionJSON] = [:]

        public init(
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
        public var lastTouchedAt: Date? {
            [readingPosition?.at, openedAt, closedAt, title?.at, openState?.at]
                .compactMap { $0 }
                .max()
        }

        public init(from decoder: Decoder) throws {
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

        public func encode(to encoder: Encoder) throws {
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
    public static let maxDocuments = 512

    public var schemaVersion: Int
    public var deviceID: DeviceID
    public var deviceName: String
    public var devicePlatform: String
    public var writtenAt: Date
    public var documents: [DocumentKey: DocumentEntry]
    public var unknownFields: [String: PositionJSON] = [:]

    /// The version parsed out of the file name this record was read from.
    /// `nil` for records built in memory. A disagreement with `schemaVersion`
    /// means the bytes are not what the name claims, so the merge drops it.
    public var fileNameVersion: Int?

    public init(
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

    public var deviceStub: DeviceIdentityStub {
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

    public init(from decoder: Decoder) throws {
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

    public func encode(to encoder: Encoder) throws {
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
    public mutating func trimToMostRecent(_ limit: Int = maxDocuments) {
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

public struct MergedField<Value: Hashable & Sendable>: Hashable, Sendable {
    public let at: Date
    public let device: DeviceIdentityStub
    public let value: Value

    public init(at: Date, device: DeviceIdentityStub, value: Value) {
        self.at = at
        self.device = device
        self.value = value
    }
}

/// The cross-device answer for one document. Every mergeable field carries the
/// device that won it; `openOn` is deliberately NOT merged into one answer.
public struct MergedDocumentPosition: Hashable, Sendable {
    public let key: DocumentKey
    public var readingPosition: MergedField<ReadingPosition>?
    public var openedAt: MergedField<Date>?
    public var closedAt: MergedField<Date>?
    public var title: MergedField<String>?
    public var openOn: [DeviceIdentityStub] = []

    public init(key: DocumentKey) {
        self.key = key
    }

    /// The instant a "continue reading" row should sort by: the merged
    /// `opened_at` when there is one, otherwise the newest stamp of any field,
    /// so a document that was only ever scrolled still surfaces.
    public var effectiveOpenedAt: Date? {
        openedAt?.value ?? [readingPosition?.at, closedAt?.at, title?.at].compactMap { $0 }.max()
    }
}

/// One row of the merged, cross-device view. Home's "continue reading" reads
/// this — never a single device's raw record.
public struct ResumeEntry: Hashable, Sendable {
    public let key: DocumentKey
    public let title: String?
    /// Newest across all devices.
    public let openedAt: Date
    /// Newest across all devices.
    public let position: ReadingPosition?
    /// Which device produced `openedAt`.
    public let lastOpenedOn: DeviceIdentityStub?
    /// Devices reporting it currently open.
    public let openElsewhere: [DeviceIdentityStub]

    public init(
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

public enum PositionCoding {
    /// Deterministic bytes: these files sync, so stable ordering and small
    /// output beat the sidecar's pretty printing.
    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PositionTimestamp.string(from: date))
        }
        return encoder
    }()

    public static let decoder: JSONDecoder = {
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
