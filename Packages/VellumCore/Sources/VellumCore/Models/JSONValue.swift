import Foundation

/// Just enough JSON to carry keys this build doesn't know about across a
/// decode/encode round trip.
///
/// Number fidelity, precisely: a number is tried as `Int`, then `Decimal`, then
/// `Double`. `Decimal` sits in the middle because it is the only one of the
/// three that can retain more integer digits than `Double` —
/// `12345678901234567890` becomes `1.2345678901234567e+19` through `Double` and
/// comes back out mangled, which for a cross-device file is a v1 build
/// corrupting a v2 build's field while claiming to merely carry it.
///
/// What is NOT preserved is a number's WRITTEN FORM: `2.0` carries back out as
/// `2`. That is a limit of `JSONEncoder`, not a choice here — it emits `2` for
/// `Double(2.0)` and for `Decimal(string: "2.0")` alike, and `JSONDecoder`
/// normalizes both on the way in, so no case of this enum can round-trip the
/// trailing `.0`. Precision is bounded by Decimal and Double.
/// Pinned by "An integral float from a future version carries its value, not
/// its spelling".
public indirect enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case decimal(Decimal)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
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
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
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

    /// Decode only unrecognized keys. Known fields keep their type-specific
    /// decoding, including legacy defaults, dates and explicit nulls.
    public static func unknownFields<Key: CodingKey>(
        in decoder: Decoder, excluding: Key.Type
    ) throws -> [String: JSONValue] {
        let container = try decoder.container(keyedBy: AnyKey.self)
        var extras: [String: JSONValue] = [:]
        for key in container.allKeys where Key(stringValue: key.stringValue) == nil {
            extras[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        return extras
    }

    public static func encode<Key: CodingKey>(
        _ fields: [String: JSONValue], to encoder: Encoder, excluding: Key.Type
    ) throws {
        guard !fields.isEmpty else { return }
        var container = encoder.container(keyedBy: AnyKey.self)
        for (name, value) in fields where Key(stringValue: name) == nil {
            try container.encode(value, forKey: AnyKey(name))
        }
    }
}

public typealias PositionJSON = JSONValue

public extension Dictionary where Key == String, Value == JSONValue {
    /// The existing version owns a colliding key, including explicit null.
    mutating func fillMissing(from other: Self) {
        merge(other) { current, _ in current }
    }
}
