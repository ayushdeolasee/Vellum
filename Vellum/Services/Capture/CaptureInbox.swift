import Foundation

// APP TARGET ONLY. This is the half of the capture module that knows about the
// library: `WebUrl.normalize` lives behind `import WebKit` and the whole
// live-page pipeline, so linking it into the extension would contradict the
// point of the inbox. Keeping the drain in its own file is what makes
// "the extension does no heavy lifting" a linker fact.

enum CaptureIngestOutcome: Sendable, Equatable {
    /// A new library entry was committed.
    case ingested(DocumentKey)
    /// Dedup hit — the commit is a no-op, but the record is still consumed.
    case alreadyPresent(DocumentKey)
}

/// `ingested` counts groups that produced a new library entry. `deduped` counts
/// pending records consumed WITHOUT producing one: both the losers collapsed
/// inside a group and groups whose ingest reported `.alreadyPresent`.
/// `retained` counts records left pending for the next drain; `quarantined`
/// counts records moved to `failed/`.
struct CaptureDrainReport: Sendable, Equatable {
    var ingested = 0
    var deduped = 0
    var retained = 0
    var quarantined = 0

    init(ingested: Int = 0, deduped: Int = 0, retained: Int = 0, quarantined: Int = 0) {
        self.ingested = ingested
        self.deduped = deduped
        self.retained = retained
        self.quarantined = quarantined
    }
}

actor CaptureInbox {
    private let layout: CaptureInboxLayout
    private let normalize: @Sendable (String) throws -> String
    private let pageKey: @Sendable (String) -> String
    private let clock: PositionClock
    private let abandonAfter: TimeInterval

    init(
        layout: CaptureInboxLayout,
        normalize: @escaping @Sendable (String) throws -> String = WebUrl.normalize,
        pageKey: @escaping @Sendable (String) -> String = WebLibrary.pageKey,
        clock: PositionClock = SystemPositionClock(),
        abandonAfter: TimeInterval = 30 * 86_400
    ) {
        self.layout = layout
        self.normalize = normalize
        self.pageKey = pageKey
        self.clock = clock
        self.abandonAfter = abandonAfter
    }

    /// Reads pending records, normalizes and de-duplicates them, hands each
    /// surviving one to `ingest`, and deletes the file ONLY after `ingest`
    /// returns. An `ingest` that throws leaves the record pending for the next
    /// drain — a crash between read and commit therefore re-drains the record,
    /// and the second drain hits the dedup path and consumes it. A capture is
    /// lost only if the App Group container itself is lost.
    ///
    /// Never throws. A record that can't be decoded or whose URL can't be
    /// normalized will never succeed, so it is quarantined rather than retried
    /// forever — and quarantined rather than deleted, because it still contains
    /// a URL the user chose to save.
    @discardableResult
    func drain(
        ingest: @Sendable (CaptureRecord, DocumentKey) async throws -> CaptureIngestOutcome
    ) async -> CaptureDrainReport {
        var report = CaptureDrainReport()
        let now = clock.now()

        var order: [DocumentKey] = []
        var groups: [DocumentKey: [(record: CaptureRecord, url: URL)]] = [:]

        for url in pendingFiles() {
            guard let data = try? Data(contentsOf: url) else {
                // Unreadable right now is not the same as unparseable; leave it
                // for the next drain rather than quarantining live bytes.
                report.retained += 1
                continue
            }
            let record: CaptureRecord
            switch CaptureCoding.decode(data) {
            case .ok(let decoded):
                record = decoded
            case .undecodable, .unsupportedSchema:
                quarantine(url)
                report.quarantined += 1
                continue
            }
            // `captured_at` is already in the record, so the abandon window
            // needs no attempt counter and no extra bookkeeping file.
            guard let capturedAt = CaptureTimestamp.parse(record.capturedAt) else {
                quarantine(url)
                report.quarantined += 1
                continue
            }
            guard now.timeIntervalSince(capturedAt) < abandonAfter else {
                quarantine(url)
                report.quarantined += 1
                continue
            }
            // `page_key_hint` is never read here. The app recomputes the key
            // with the library's own functions, so extension and library
            // derivation are structurally incapable of diverging.
            guard let normalized = try? normalize(record.sourceURL),
                let key = DocumentKey(rawValue: "web:\(pageKey(normalized))")
            else {
                quarantine(url)
                report.quarantined += 1
                continue
            }
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append((record, url))
        }

        for key in order {
            guard let group = groups[key], let winner = Self.newest(of: group) else { continue }
            do {
                let outcome = try await ingest(winner.record, key)
                switch outcome {
                case .ingested:
                    report.ingested += 1
                    report.deduped += group.count - 1
                case .alreadyPresent:
                    report.deduped += group.count
                }
                for entry in group {
                    try? FileManager.default.removeItem(at: entry.url)
                }
            } catch {
                // Transient — offline, disk full. Delete nothing.
                report.retained += group.count
            }
        }

        return report
    }

    func pendingCount() async -> Int {
        pendingFiles().count
    }

    // MARK: - Internals

    private func pendingFiles() -> [URL] {
        guard
            let names = try? FileManager.default.contentsOfDirectory(
                at: layout.pending, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        return
            names
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The newest capture of a page wins. File name breaks a `captured_at` tie,
    /// and the name is millisecond-prefixed, so the order is total.
    private static func newest(
        of group: [(record: CaptureRecord, url: URL)]
    ) -> (record: CaptureRecord, url: URL)? {
        group.max { lhs, rhs in
            let left = CaptureTimestamp.parse(lhs.record.capturedAt) ?? .distantPast
            let right = CaptureTimestamp.parse(rhs.record.capturedAt) ?? .distantPast
            if left == right { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
            return left < right
        }
    }

    private func quarantine(_ url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: layout.failed, withIntermediateDirectories: true)
        let destination = layout.failed.appendingPathComponent(url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try? fileManager.moveItem(at: url, to: destination)
    }
}
