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
    private var drainTask: Task<CaptureDrainReport, Never>?
    private var drainGeneration = 0
    private var ownedExports: Set<URL> = []

    struct RecoveryEntry: Identifiable, Sendable {
        enum State: Sendable, Equatable { case pending, failed }
        let id: URL
        let state: State
        let title: String
        let sourceURL: String?
        let status: String
        let canRetry: Bool
        let byteCount: Int64
    }

    init(
        layout: CaptureInboxLayout,
        normalize: @escaping @Sendable (String) throws -> String = WebUrl.normalize,
        pageKey: @escaping @Sendable (String) -> String = WebLibrary.pageKey,
        clock: PositionClock = SystemPositionClock()
    ) {
        self.layout = layout
        self.normalize = normalize
        self.pageKey = pageKey
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
        ingest: @escaping @Sendable (CaptureRecord, DocumentKey) async throws -> CaptureIngestOutcome
    ) async -> CaptureDrainReport {
        // Cancellation can arrive before this actor creates its owned task.
        guard !Task.isCancelled else { return CaptureDrainReport(retained: pendingFiles().count) }
        if let drainTask { return await drainTask.value }
        drainGeneration += 1
        let generation = drainGeneration
        let task = Task { await self.drainImpl(ingest: ingest) }
        drainTask = task
        let report = await task.value
        if generation == drainGeneration { drainTask = nil }
        return report
    }

    private func drainImpl(
        ingest: @Sendable (CaptureRecord, DocumentKey) async throws -> CaptureIngestOutcome
    ) async -> CaptureDrainReport {
        var report = CaptureDrainReport()

        var order: [DocumentKey] = []
        // Index only small locators/timestamps. Holding every DOM until ingest
        // would make a legacy inbox above today's budget an unbounded allocation.
        var groups: [DocumentKey: [(url: URL, capturedAt: Date)]] = [:]
        let files = pendingFiles()
        for (index, url) in files.enumerated() {
            guard !Task.isCancelled else {
                report.retained += files.count - index
                break
            }
            let data: Data
            do { data = try CaptureInboxFiles.readRecord(url) }
            catch CaptureInboxError.recordTooLarge {
                if quarantine(url) { report.quarantined += 1 } else { report.retained += 1 }
                continue
            } catch {
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
                if quarantine(url) { report.quarantined += 1 } else { report.retained += 1 }
                continue
            }
            guard let capturedAt = CaptureTimestamp.parse(record.capturedAt) else {
                if quarantine(url) { report.quarantined += 1 } else { report.retained += 1 }
                continue
            }
            // A valid save request does not expire while its device is offline.
            // `page_key_hint` is never read here. The app recomputes the key
            // with the library's own functions, so extension and library
            // derivation are structurally incapable of diverging.
            guard let normalized = try? normalize(record.sourceURL),
                let key = DocumentKey(rawValue: "web:\(pageKey(normalized))")
            else {
                if quarantine(url) { report.quarantined += 1 } else { report.retained += 1 }
                continue
            }
            if groups[key] == nil {
                groups[key] = []
                order.append(key)
            }
            groups[key]?.append((url, capturedAt))
        }

        for key in order {
            guard let group = groups[key], let winner = Self.newest(of: group) else { continue }
            do {
                try Task.checkCancellation()
                let bytes = try CaptureInboxFiles.readRecord(winner.url)
                guard case .ok(let record) = CaptureCoding.decode(bytes) else {
                    throw CaptureInboxError.io("This capture changed before saving.")
                }
                let outcome = try await ingest(record, key)
                switch outcome {
                case .ingested:
                    report.ingested += 1
                    report.deduped += group.count - 1
                case .alreadyPresent:
                    report.deduped += group.count
                }
                for entry in group {
                    do {
                        try CaptureInboxFiles.withLock(layout: layout) {
                            try FileManager.default.removeItem(at: entry.url)
                        }
                    } catch { report.retained += 1 }
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
        (try? CaptureInboxFiles.withLock(layout: layout) {
            try CaptureInboxFiles.files(in: layout.pending)
        }) ?? []
    }

    /// Joining before a destructive mutation prevents delete/retry from racing
    /// the ingest that already read this record. Finished tasks are cleared by
    /// generation so a later drain cannot be cleared by an older completion.
    private func joinDrain() async {
        while let task = drainTask {
            let generation = drainGeneration
            _ = await task.value
            if generation == drainGeneration { drainTask = nil }
        }
    }

    func cancelAndJoinDrain() async {
        drainTask?.cancel()
        await joinDrain()
    }

    func recoveryEntries() throws -> [RecoveryEntry] {
        let (pending, failed) = try CaptureInboxFiles.withLock(layout: layout) {
            (try CaptureInboxFiles.files(in: layout.pending), try CaptureInboxFiles.files(in: layout.failed))
        }
        return (pending.map { ($0, RecoveryEntry.State.pending) }
            + failed.map { ($0, RecoveryEntry.State.failed) }).map { url, state in
            let size = (try? CaptureInboxFiles.regularFileSize(url)) ?? 0
            var title = "Capture needing recovery"
            var sourceURL: String?
            var canRetry = false
            var status = "This capture could not be read. Export it for recovery or delete it."
            do {
                let data = try CaptureInboxFiles.readRecord(url)
                switch CaptureCoding.decode(data) {
                case .ok(let record):
                    sourceURL = String(record.sourceURL.prefix(2_048))
                    title = String((record.title ?? record.sourceURL).prefix(256))
                    canRetry = CaptureTimestamp.parse(record.capturedAt) != nil
                        && (try? normalize(record.sourceURL)) != nil
                    status = canRetry
                        ? (state == .pending ? "Waiting to save. Kept until saved or explicitly deleted."
                           : "Preserved capture. Retry saving it to your library.")
                        : "This capture's URL or date is invalid. Export it for recovery or delete it."
                case .unsupportedSchema:
                    status = "This capture needs a newer Vellum version. Its original bytes are kept."
                case .undecodable:
                    status = "This capture is incomplete or damaged. Its original bytes are kept."
                }
            } catch CaptureInboxError.recordTooLarge {
                status = "This capture is too large to read safely. Export it for recovery or delete it."
            } catch { }
            return RecoveryEntry(id: url, state: state, title: title, sourceURL: sourceURL,
                status: status, canRetry: canRetry, byteCount: size)
        }
    }

    func retry(_ entry: RecoveryEntry) async throws {
        await joinDrain()
        try validate(entry)
        let data = try CaptureInboxFiles.readRecord(entry.id)
        guard case .ok(let record) = CaptureCoding.decode(data),
              CaptureTimestamp.parse(record.capturedAt) != nil,
              (try? normalize(record.sourceURL)) != nil else {
            throw CaptureInboxError.io("This capture cannot be retried. Export its original copy for recovery.")
        }
        if entry.state == .failed {
            try CaptureInboxFiles.withLock(layout: layout) {
                let destination = CaptureInboxFiles.availableDestination(in: layout.pending,
                    name: entry.id.lastPathComponent)
                try CaptureInboxFiles.publish(entry.id, to: destination)
            }
        }
    }

    func delete(_ entry: RecoveryEntry) async throws {
        await joinDrain()
        try validate(entry)
        try CaptureInboxFiles.withLock(layout: layout) {
            do { try FileManager.default.removeItem(at: entry.id) }
            catch let error as CocoaError where error.code == .fileNoSuchFile { }
        }
    }

    func export(_ entry: RecoveryEntry) throws -> URL {
        try validate(entry)
        _ = try CaptureInboxFiles.regularFileSize(entry.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "Vellum Capture \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(entry.id.lastPathComponent)
        do {
            // Copy streams the file without decoding it, including oversized or
            // future-format captures that this version cannot retry.
            try FileManager.default.copyItem(at: entry.id, to: destination)
            ownedExports.insert(destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    /// Only URLs minted by this inbox can authorize deletion of an export
    /// directory; capture originals and arbitrary caller paths are never removed.
    func discardExport(_ url: URL) throws {
        guard ownedExports.contains(url) else { return }
        do { try FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        ownedExports.remove(url)
    }

    private func validate(_ entry: RecoveryEntry) throws {
        let parent = entry.id.deletingLastPathComponent().standardizedFileURL
        guard parent == layout.pending.standardizedFileURL || parent == layout.failed.standardizedFileURL,
              entry.id.pathExtension == "json" else { throw CaptureInboxError.noLongerAvailable }
    }

    /// The newest capture of a page wins. File name breaks a `captured_at` tie,
    /// and the name is millisecond-prefixed, so the order is total.
    private static func newest(
        of group: [(url: URL, capturedAt: Date)]
    ) -> (url: URL, capturedAt: Date)? {
        group.max { lhs, rhs in
            let left = lhs.capturedAt
            let right = rhs.capturedAt
            if left == right { return lhs.url.lastPathComponent < rhs.url.lastPathComponent }
            return left < right
        }
    }

    private func quarantine(_ url: URL) -> Bool {
        do {
            try CaptureInboxFiles.withLock(layout: layout) {
                let destination = CaptureInboxFiles.availableDestination(in: layout.failed,
                    name: url.lastPathComponent)
                try CaptureInboxFiles.publish(url, to: destination)
            }
            return true
        } catch { return false }
    }
}
