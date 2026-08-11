import Foundation

/// Total-order newest-wins per document per field over N device records.
/// Pure, commutative, associative, idempotent. No clock, no filesystem.
///
/// The comparison key is the pair `(stamp, device_id)` under lexicographic
/// order. Device ids are unique per device, so no two distinct candidates ever
/// compare equal — that makes the order strict and total, which is exactly what
/// makes `max` (and therefore this whole merge) independent of the order the
/// files happened to be read in.
enum PositionMerge {
    static func merge(_ records: [PositionDeviceRecord]) -> [DocumentKey: MergedDocumentPosition] {
        var out: [DocumentKey: MergedDocumentPosition] = [:]
        for record in records where isUsable(record) {
            let device = record.deviceStub
            for (key, entry) in record.documents {
                var merged = out[key] ?? MergedDocumentPosition(key: key)
                if let position = entry.readingPosition {
                    merged.readingPosition = better(
                        merged.readingPosition,
                        MergedField(at: position.at, device: device, value: position.value))
                }
                if let openedAt = entry.openedAt {
                    merged.openedAt = better(
                        merged.openedAt,
                        MergedField(at: openedAt, device: device, value: openedAt))
                }
                if let closedAt = entry.closedAt {
                    merged.closedAt = better(
                        merged.closedAt,
                        MergedField(at: closedAt, device: device, value: closedAt))
                }
                if let title = entry.title {
                    merged.title = better(
                        merged.title,
                        MergedField(at: title.at, device: device, value: title.value))
                }
                // Open state is never folded into one answer: merging it would
                // mean opening a tab on the Mac pops a tab on the phone. It is
                // appended per device instead.
                if entry.openState?.value.isOpen == true, !merged.openOn.contains(device) {
                    merged.openOn.append(device)
                    merged.openOn.sort { $0.id < $1.id }
                }
                out[key] = merged
            }
        }
        return out
    }

    static func recents(
        from merged: [DocumentKey: MergedDocumentPosition], limit: Int
    ) -> [ResumeEntry] {
        guard limit > 0 else { return [] }
        let entries = merged.values.compactMap(entry(from:))
        let ordered = entries.sorted { lhs, rhs in
            if lhs.openedAt == rhs.openedAt { return lhs.key.rawValue > rhs.key.rawValue }
            return lhs.openedAt > rhs.openedAt
        }
        return Array(ordered.prefix(limit))
    }

    static func entry(from merged: MergedDocumentPosition) -> ResumeEntry? {
        guard let openedAt = merged.effectiveOpenedAt else { return nil }
        return ResumeEntry(
            key: merged.key,
            title: merged.title?.value,
            openedAt: openedAt,
            position: merged.readingPosition?.value,
            lastOpenedOn: merged.openedAt?.device,
            openElsewhere: merged.openOn)
    }

    /// A record whose body version is newer than this build understands, or
    /// whose body disagrees with the version in its file name, is ignored — and
    /// never rewritten, so a newer build's data survives a downgrade.
    static func isUsable(_ record: PositionDeviceRecord) -> Bool {
        guard record.schemaVersion >= 1, record.schemaVersion <= PositionLayout.schemaVersion else {
            return false
        }
        if let fileNameVersion = record.fileNameVersion, fileNameVersion != record.schemaVersion {
            return false
        }
        return true
    }

    private static func better<Value>(
        _ incumbent: MergedField<Value>?, _ candidate: MergedField<Value>
    ) -> MergedField<Value> {
        guard let incumbent else { return candidate }
        if candidate.at == incumbent.at {
            // Equal stamps mean the user did two things at once and neither
            // answer is "right"; all that matters is that every device picks
            // the same one.
            return candidate.device.id > incumbent.device.id ? candidate : incumbent
        }
        return candidate.at > incumbent.at ? candidate : incumbent
    }
}
