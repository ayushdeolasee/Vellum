import Foundation

/// Optional, top-level fields of a v3 web ink record. Keys are opaque PortableStroke IDs.
/// An absent per-stroke edit time inherits the legacy record's updated_at.
public struct InkMergeHistory: Codable, Equatable, Sendable {
    public static let capability = "ink-tombstones"
    public var deleted: [String: String] = [:]
    public var restored: [String: String] = [:]
    public var updated: [String: String] = [:]
    /// Bridges drawing-only archives and foreign IDs. A self-mapping marks a
    /// deletion first observed without a wire ID.
    public var nativeIDs: [String: String] = [:] // opaque ID -> PencilKit-derived ID

    public init() {}

    public enum CodingKeys: String, CodingKey {
        case deleted = "deleted_ids", restored = "restored_ids", updated = "stroke_updated_at"
        case nativeIDs = "stroke_native_ids"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        deleted = try fields.decodeIfPresent([String: String].self, forKey: .deleted) ?? [:]
        restored = try fields.decodeIfPresent([String: String].self, forKey: .restored) ?? [:]
        updated = try fields.decodeIfPresent([String: String].self, forKey: .updated) ?? [:]
        nativeIDs = try fields.decodeIfPresent([String: String].self, forKey: .nativeIDs) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        if !deleted.isEmpty { try fields.encode(deleted, forKey: .deleted) }
        if !restored.isEmpty { try fields.encode(restored, forKey: .restored) }
        if !updated.isEmpty { try fields.encode(updated, forKey: .updated) }
        if !nativeIDs.isEmpty { try fields.encode(nativeIDs, forKey: .nativeIDs) }
    }

    /// V3 compares RFC3339 instants (offsets included) at the Apple writer's
    /// millisecond precision. Unparseable legacy timestamps compare lexically.
    public static func newer(_ a: String, than b: String) -> Bool {
        if a == b { return false }
        func instant(_ value: String) -> Date? {
            // Corelibs and Darwin ISO parsers can retain different fractional precision.
            guard let dot = value.firstIndex(of: ".") else { return PositionTimestamp.parse(value) }
            let digits = value[value.index(after: dot)...].prefix(while: { $0.isNumber })
            guard digits.count > 3 else { return PositionTimestamp.parse(value) }
            return PositionTimestamp.parse(String(value[...dot] + digits.prefix(3) + value[digits.endIndex...]))
        }
        if let lhs = instant(a), let rhs = instant(b) { return lhs > rhs }
        return a > b
    }

    public mutating func formUnion(_ other: Self) {
        func latest(_ a: String, _ b: String) -> String { Self.newer(b, than: a) ? b : a }
        // A restore belongs to the deletion observed by its writer. Never attach an
        // older generation's undo to a later erase, even if its wall clock was ahead.
        for (id, erase) in other.deleted {
            if let previous = deleted[id] {
                if Self.newer(previous, than: erase) { continue }
                if !Self.newer(erase, than: previous) {
                    deleted[id] = max(previous, erase)
                    if let undo = other.restored[id] {
                        restored[id] = restored[id].map { latest($0, undo) } ?? undo
                    }
                    continue
                }
            }
            deleted[id] = erase
            restored[id] = other.restored[id]
        }
        updated.merge(other.updated, uniquingKeysWith: latest)
        nativeIDs.merge(other.nativeIDs) { current, _ in current }
    }

    /// A candidate must itself carry an explicit restore after the latest deletion.
    /// A newer page timestamp or an unrelated stroke edit cannot undo an erase.
    public func admits(_ id: String, from candidate: Self) -> Bool {
        guard let erase = deleted[id] else { return true }
        guard let seen = candidate.deleted[id], !Self.newer(erase, than: seen),
              let undo = candidate.restored[id] else { return false }
        return Self.newer(undo, than: erase)
    }

    /// Select one complete payload per ID. Callers keep the winner's geometry,
    /// mask and ranges together. Indices refer to the input arrays in drawing order.
    public struct Selection: Sendable {
        public let incoming: Bool
        public let index: Int
    }

    public static func merge(current: Self, ids: [String], timestamp: String,
                             incoming: Self, incomingIDs: [String], incomingTimestamp: String)
        -> (history: Self, strokes: [Selection]) {
        var history = current
        history.formUnion(incoming)
        var slots: [String: Int] = [:]
        var strokes: [Selection] = []
        var times: [String: String] = [:]
        for (fromIncoming, source, keys, fallback) in [(false, current, ids, timestamp),
                                                       (true, incoming, incomingIDs, incomingTimestamp)] {
            for (index, id) in keys.enumerated() where history.admits(id, from: source) {
                let time = source.updated[id] ?? fallback
                let entry = Selection(incoming: fromIncoming, index: index)
                if let slot = slots[id], let prior = times[id] {
                    guard newer(time, than: prior) else { continue }
                    strokes[slot] = entry
                } else {
                    slots[id] = strokes.count
                    strokes.append(entry)
                }
                times[id] = time
            }
        }
        history.updated.merge(times) { _, selected in selected }
        return (history, strokes)
    }

    /// A local edit observed the previous operation. Move at least one writer tick
    /// beyond it even when the clock went backwards or two edits share a millisecond.
    public static func next(_ proposed: String, after observed: String?) -> String {
        guard let observed, !newer(proposed, than: observed),
              let date = PositionTimestamp.parse(observed) else { return proposed }
        return PositionTimestamp.string(from: date.addingTimeInterval(0.001))
    }
}

public extension PortableStroke {
    /// Carry future fields only between corresponding samples of the same stroke.
    mutating func inheritInkFields(from prior: PortableStroke) {
        guard id == prior.id else { return }
        unknownFields.inheritInkFields(from: prior.unknownFields)
        for i in points.indices where prior.points.indices.contains(i) {
            let old = prior.points[i]
            if points[i].x == old.x, points[i].y == old.y, points[i].t == old.t {
                points[i].unknownFields.inheritInkFields(from: old.unknownFields)
            }
        }
        if let old = prior.mask { mask?.unknownFields.inheritInkFields(from: old.unknownFields) }
    }
}

public extension Dictionary where Key == String, Value == JSONValue {
    /// The winning value owns collisions, including null. Preserve independent nested keys.
    mutating func inheritInkFields(from other: Self) {
        merge(other) { winner, prior in
            if case .object(var fields) = winner, case .object(let old) = prior {
                fields.inheritInkFields(from: old)
                return .object(fields)
            }
            return winner
        }
    }
}
