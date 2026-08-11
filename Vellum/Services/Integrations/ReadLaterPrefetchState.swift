import Foundation

// The one fact the retention ledger deliberately does not keep: which items
// retention has ALREADY expired. The ledger forgets an item once its offline
// copy is deleted (that is its contract — it tracks bytes it can still delete),
// so without this file the very next prefetch run would re-download exactly
// what the sweep just removed and hand it a fresh fourteen days. The retention
// engine would then be a mechanism for periodically re-downloading the library.
//
// Separate file, not new fields on `retention.json`: that file's bytes are
// pinned by a wire-format test and shared with the sweep; this is one-way
// prefetch bookkeeping that nothing else reads. It reuses the ledger's
// directory and its deterministic coder so the two files stay byte-siblings.

extension RetentionLayout {
    static var prefetchStateURL: URL { directory.appendingPathComponent("prefetch.json") }
}

struct ReadLaterPrefetchStateFile: Codable, Sendable, Equatable {
    var schemaVersion: Int
    var writtenAt: Date
    /// Item id → when retention deleted its offline copy.
    var evicted: [String: Date]

    init(
        schemaVersion: Int = RetentionLayout.schemaVersion,
        writtenAt: Date,
        evicted: [String: Date] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.writtenAt = writtenAt
        self.evicted = evicted
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case writtenAt = "written_at"
        case evicted
    }
}

/// Owns `read-later/prefetch.json`. Same shape as `RetentionLedger`: no I/O in
/// `init`, load on first use, corrupt reads as empty, write-through on change.
actor ReadLaterPrefetchState {
    private let fileURL: URL
    private let clock: PositionClock
    private var storedFile: ReadLaterPrefetchStateFile?

    init(
        fileURL: URL = RetentionLayout.prefetchStateURL,
        clock: PositionClock = SystemPositionClock()
    ) {
        self.fileURL = fileURL
        self.clock = clock
    }

    private var file: ReadLaterPrefetchStateFile {
        get {
            if let storedFile { return storedFile }
            let loaded = (try? Data(contentsOf: fileURL)).flatMap {
                try? RetentionCoding.decoder.decode(ReadLaterPrefetchStateFile.self, from: $0)
            }
            let file = loaded ?? ReadLaterPrefetchStateFile(writtenAt: clock.now())
            storedFile = file
            return file
        }
        set { storedFile = newValue }
    }

    func evictedIDs() -> Set<String> { Set(file.evicted.keys) }

    func wasEvicted(_ itemID: String) -> Bool { file.evicted[itemID] != nil }

    func markEvicted(_ itemIDs: [String], at: Date? = nil) {
        guard !itemIDs.isEmpty else { return }
        let stamp = at ?? clock.now()
        var changed = false
        for itemID in itemIDs where file.evicted[itemID] == nil {
            file.evicted[itemID] = stamp
            changed = true
        }
        if changed { persist() }
    }

    /// Reading an expired item is the user saying they still want it, so the
    /// tombstone lifts and the next run may download it again. This is the ONLY
    /// way back — a re-sync of the same item does not clear it.
    func clearEviction(_ itemID: String) {
        guard file.evicted.removeValue(forKey: itemID) != nil else { return }
        persist()
    }

    /// Drops tombstones for items that are no longer in the queue at all: a
    /// deleted Readwise document should not keep a row here forever.
    func retainOnly(_ liveItemIDs: Set<String>) {
        let dead = file.evicted.keys.filter { !liveItemIDs.contains($0) }
        guard !dead.isEmpty else { return }
        for itemID in dead { file.evicted.removeValue(forKey: itemID) }
        persist()
    }

    func snapshot() -> ReadLaterPrefetchStateFile { file }

    private func persist() {
        file.writtenAt = clock.now()
        let fileManager = FileManager.default
        try? fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? RetentionCoding.encoder.encode(file) else { return }
        let tmp = fileURL.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        if rename(tmp.path, fileURL.path) != 0 {
            try? fileManager.removeItem(at: tmp)
        }
    }
}
