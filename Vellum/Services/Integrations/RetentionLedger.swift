import Foundation

// The persisted half of read-later retention: one sidecar file holding the
// three timestamps the engine needs per item, plus the sweep that turns
// verdicts into deleted bytes.
//
// Deliberately a SEPARATE sidecar rather than new fields on the read-later
// queue model: that model already syncs cross-device in a pinned byte format,
// and retention is a new, phone-local concern. Entangling them is exactly the
// coupling the byte-compatibility constraint exists to prevent.
//
// If this file ever needs to sync, it must convert to the position store's
// shape (`retention/<device_id>.v1.json` + per-field newest-wins) rather than
// becoming a shared read-modify-write file. Noted here so a future implementer
// doesn't take the easy wrong path.

enum RetentionLayout {
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride ?? WebLibrary.appDataDir.appendingPathComponent(
            "read-later", isDirectory: true)
    }

    static var ledgerURL: URL { directory.appendingPathComponent("retention.json") }

    static let schemaVersion = 1
}

/// Per-item retention state. `annotated_at`'s PRESENCE is the exemption flag —
/// one field doing two jobs, so a boolean and a timestamp can never disagree.
struct RetentionItemState: Codable, Sendable, Equatable {
    var addedAt: Date
    var lastReadAt: Date?
    var annotatedAt: Date?
    /// Diagnostics only (a future Storage pane row); never an input to a verdict.
    var offlineBytes: Int?

    init(addedAt: Date, lastReadAt: Date? = nil, annotatedAt: Date? = nil, offlineBytes: Int? = nil)
    {
        self.addedAt = addedAt
        self.lastReadAt = lastReadAt
        self.annotatedAt = annotatedAt
        self.offlineBytes = offlineBytes
    }

    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case lastReadAt = "last_read_at"
        case annotatedAt = "annotated_at"
        case offlineBytes = "offline_bytes"
    }
}

/// Keys are read-later item ids verbatim (`"<provider>:<vendor id>"`) — no
/// re-hashing, because this is a map inside one file, not a set of file names.
struct RetentionLedgerFile: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var writtenAt: Date
    var items: [String: RetentionItemState]

    init(
        schemaVersion: Int = RetentionLayout.schemaVersion,
        writtenAt: Date,
        items: [String: RetentionItemState] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.items = items
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case writtenAt = "written_at"
        case items
    }
}

struct RetentionSweepReport: Sendable, Equatable {
    var evaluated = 0
    var exempt = 0
    var retained = 0
    var expired = 0
    var deleted = 0

    init(evaluated: Int = 0, exempt: Int = 0, retained: Int = 0, expired: Int = 0, deleted: Int = 0)
    {
        self.evaluated = evaluated
        self.exempt = exempt
        self.retained = retained
        self.expired = expired
        self.deleted = deleted
    }
}

enum RetentionCoding {
    /// Deterministic bytes so the wire format is assertable byte for byte.
    /// Timestamps go through `PositionTimestamp`, i.e. the webpage sidecar's
    /// exact writer shape, rather than a third private copy of the formatter.
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

/// Owns `read-later/retention.json` and the sweep.
///
/// Write-through, no debounce: retention events are discrete and rare (add,
/// first read, annotate — a handful per session), so the coalescing machinery
/// the position store needs for continuous scroll would be a seam with one
/// hypothetical adapter.
actor RetentionLedger {
    static let shared = RetentionLedger()

    private let fileURL: URL
    private let clock: PositionClock
    private var file: RetentionLedgerFile

    init(fileURL: URL = RetentionLayout.ledgerURL, clock: PositionClock = SystemPositionClock()) {
        self.fileURL = fileURL
        self.clock = clock
        // Corrupt or absent is the same thing to a caller: start empty and
        // rebuild. Never thrown upward.
        let loaded = (try? Data(contentsOf: fileURL)).flatMap {
            try? RetentionCoding.decoder.decode(RetentionLedgerFile.self, from: $0)
        }
        self.file = loaded ?? RetentionLedgerFile(writtenAt: clock.now())
    }

    // MARK: - Events

    /// The clock starts at LOCAL ingestion — the moment Vellum takes custody of
    /// the offline copy — not at the provider's `saved_at`, which can be months
    /// old and would expire a freshly-prefetched item the instant it lands.
    func markAdded(_ itemID: String, at: Date? = nil, offlineBytes: Int? = nil) {
        let stamp = at ?? clock.now()
        var item = file.items[itemID] ?? RetentionItemState(addedAt: stamp)
        item.addedAt = stamp
        if let offlineBytes { item.offlineBytes = offlineBytes }
        file.items[itemID] = item
        persist()
    }

    func markRead(_ itemID: String, at: Date? = nil) {
        let stamp = at ?? clock.now()
        var item = file.items[itemID] ?? RetentionItemState(addedAt: stamp)
        item.lastReadAt = max(item.lastReadAt ?? stamp, stamp)
        file.items[itemID] = item
        persist()
    }

    func markAnnotated(_ itemID: String, at: Date? = nil) {
        let stamp = at ?? clock.now()
        var item = file.items[itemID] ?? RetentionItemState(addedAt: stamp)
        item.annotatedAt = item.annotatedAt ?? stamp
        file.items[itemID] = item
        persist()
    }

    func forget(_ itemID: String) {
        guard file.items.removeValue(forKey: itemID) != nil else { return }
        persist()
    }

    /// One-way safety pass. It can only ever ADD exemptions, never clear one,
    /// so an annotation written by a path that forgot to call `markAnnotated`
    /// gets picked up, and a reconcile run against a not-yet-downloaded sidecar
    /// can never revoke an exemption. Items the ledger doesn't track are left
    /// alone: there is no offline copy of theirs for a sweep to delete.
    func reconcileAnnotations(itemIDsWithAnnotations: Set<String>) {
        var changed = false
        let stamp = clock.now()
        for itemID in itemIDsWithAnnotations {
            guard var item = file.items[itemID], item.annotatedAt == nil else { continue }
            item.annotatedAt = stamp
            file.items[itemID] = item
            changed = true
        }
        if changed { persist() }
    }

    // MARK: - Sweep

    /// Verdict for every tracked item at `now`, then `deleteOfflineCopy` for
    /// each expired one, then the ledger forgets the items whose copies are
    /// gone. This deletes BYTES, not list rows — the queue entry is untouched,
    /// because the ledger has no way to reach it.
    ///
    /// Takes `now`, never a cutoff: `StorageHousekeeping`'s cutoff is a
    /// user-configurable month count for a different data class, and this
    /// window is a fixed fourteen days that is not user-configurable.
    @discardableResult
    func sweep(
        now: Date,
        policy: RetentionPolicy = .readLater,
        deleteOfflineCopy: @Sendable (String) async -> Bool
    ) async -> RetentionSweepReport {
        var report = RetentionSweepReport()
        var expired: [String] = []
        for (itemID, item) in file.items.sorted(by: { $0.key < $1.key }) {
            report.evaluated += 1
            switch RetentionEngine.verdict(
                addedAt: item.addedAt,
                lastReadAt: item.lastReadAt,
                annotatedAt: item.annotatedAt,
                now: now,
                policy: policy)
            {
            case .exempt:
                report.exempt += 1
            case .retained:
                report.retained += 1
            case .expired:
                report.expired += 1
                expired.append(itemID)
            }
        }

        var deleted = false
        for itemID in expired {
            // A deleter that reports failure leaves the item tracked, so the
            // next sweep tries again rather than losing the bytes silently.
            guard await deleteOfflineCopy(itemID) else { continue }
            report.deleted += 1
            file.items.removeValue(forKey: itemID)
            deleted = true
        }
        if deleted { persist() }
        return report
    }

    /// An item the ledger never tracked has no retention claim, so it reads as
    /// expired. Nothing is deleted on the strength of that: `sweep` only ever
    /// visits tracked items.
    func verdict(
        for itemID: String, now: Date, policy: RetentionPolicy = .readLater
    ) -> RetentionVerdict {
        guard let item = file.items[itemID] else { return .expired(since: now) }
        return RetentionEngine.verdict(
            addedAt: item.addedAt,
            lastReadAt: item.lastReadAt,
            annotatedAt: item.annotatedAt,
            now: now,
            policy: policy)
    }

    func snapshot() -> RetentionLedgerFile { file }

    // MARK: - Persistence

    private func persist() {
        file.writtenAt = clock.now()
        let fileManager = FileManager.default
        let directory = fileURL.deletingLastPathComponent()
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? RetentionCoding.encoder.encode(file) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        if rename(tmp.path, fileURL.path) != 0 {
            try? fileManager.removeItem(at: tmp)
        }
    }
}
