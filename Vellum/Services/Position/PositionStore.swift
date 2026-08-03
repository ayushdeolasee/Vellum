import Foundation

struct CoalescePolicy: Sendable, Equatable {
    /// No writes until this long after the last event.
    var quietWindow: TimeInterval = 2.0
    /// ...but never hold a dirty record longer than this.
    var maxDelay: TimeInterval = 15.0
    /// ...and never write twice inside this.
    var minInterval: TimeInterval = 1.0

    init(quietWindow: TimeInterval = 2.0, maxDelay: TimeInterval = 15.0, minInterval: TimeInterval = 1.0) {
        self.quietWindow = quietWindow
        self.maxDelay = maxDelay
        self.minInterval = minInterval
    }

    static let `default` = CoalescePolicy()
    static let immediate = CoalescePolicy(quietWindow: 0, maxDelay: 0, minInterval: 0)
}

/// Per-device coalesced position/recents store. Writes are cheap and in-memory;
/// reads are a newest-wins merge over every device record present locally.
///
/// Callers have no write-now API other than `flush()`, which is the point: the
/// frequent path (scrolling) is free and the disk path is rare, and nobody can
/// opt into "save the scroll position on every frame".
actor PositionStore {
    private let storage: PositionStorage
    private let device: DeviceIdentity
    private let clock: PositionClock
    private let timer: PositionTimer
    private let policy: CoalescePolicy

    private var documents: [DocumentKey: PositionDeviceRecord.DocumentEntry] = [:]
    private var lastStamps: [String: Date] = [:]
    private var hydrated = false
    private var hydration: Task<Void, Never>?
    private var dirty = false
    private var firstDirtyAt: Date?
    private var lastWriteAt: Date?
    private var writeFailures = 0
    private var dirtyGeneration: UInt64 = 0
    private var inFlightWrite: Task<WriteOutcome, Never>?
    private var inFlightGeneration: UInt64?

    private struct WriteOutcome: Sendable {
        var generation: UInt64
        var result: Result<Void, PositionStorageError>

        var succeeded: Bool {
            if case .success = result { return true }
            return false
        }
    }

    init(
        storage: PositionStorage,
        device: DeviceIdentity = .current(),
        clock: PositionClock = SystemPositionClock(),
        timer: PositionTimer = TaskPositionTimer(),
        policy: CoalescePolicy = .default
    ) {
        self.storage = storage
        self.device = device
        self.clock = clock
        self.timer = timer
        self.policy = policy
    }

    var deviceIdentity: DeviceIdentity { device }

    // MARK: - Writes

    func record(_ event: PositionEvent, for key: DocumentKey) {
        var entry = documents[key] ?? PositionDeviceRecord.DocumentEntry()
        switch event {
        case .opened(let title, let tabOrdinal):
            entry.openedAt = stamp(key, "opened_at")
            if let title {
                entry.title = Stamped(at: stamp(key, "title"), value: title)
            }
            entry.openState = Stamped(
                at: stamp(key, "open_state"),
                value: OpenState(isOpen: true, tabOrdinal: tabOrdinal))
        case .titled(let title):
            entry.title = Stamped(at: stamp(key, "title"), value: title)
        case .moved(let position):
            entry.readingPosition = Stamped(at: stamp(key, "reading_position"), value: position)
        case .closed:
            entry.closedAt = stamp(key, "closed_at")
            entry.openState = Stamped(
                at: stamp(key, "open_state"),
                value: OpenState(isOpen: false, tabOrdinal: entry.openState?.value.tabOrdinal))
        }
        documents[key] = entry
        markDirty()
    }

    /// Force the pending write now (backgrounding, tab close, test). Returns
    /// after the bytes are on disk, or after the write failed silently.
    func flush() async {
        timer.cancel()
        while true {
            if let task = inFlightWrite {
                let succeeded = await finishWrite(task)
                guard succeeded else { return }
                continue
            }
            guard dirty else { return }
            guard let task = await beginWriteIfNeeded() else { continue }
            let succeeded = await finishWrite(task)
            guard succeeded else { return }
        }
    }

    // MARK: - Reads

    func resume(for key: DocumentKey) async -> ResumeEntry? {
        guard let merged = await mergedView()[key] else { return nil }
        return localized(PositionMerge.entry(from: merged))
    }

    func recents(limit: Int = 8) async -> [ResumeEntry] {
        PositionMerge.recents(from: await mergedView(), limit: limit)
            .compactMap { localized($0) }
    }

    func webLastOpenedByKey() async -> [String: Date] {
        let merged = await mergedView()
        return merged.reduce(into: [:]) { out, pair in
            guard pair.key.namespace == .web,
                  let openedAt = pair.value.effectiveOpenedAt
            else { return }
            out[pair.key.hash] = openedAt
        }
    }

    /// Documents reported open. `nil` means "on any device"; pass a `DeviceID`
    /// to ask about one.
    func openDocuments(on device: DeviceID? = nil) async -> [DocumentKey] {
        let merged = await mergedView()
        return merged.values
            .filter { position in
                guard let device else { return !position.openOn.isEmpty }
                return position.openOn.contains { $0.id == device }
            }
            .map(\.key)
            .sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: - Coalescing

    private func markDirty() {
        let now = clock.now()
        dirtyGeneration &+= 1
        dirty = true
        if firstDirtyAt == nil { firstDirtyAt = now }
        scheduleWrite(now: now)
    }

    private func scheduleWrite(now: Date) {
        let heldFor = now.timeIntervalSince(firstDirtyAt ?? now)
        let untilMaxDelay = max(0, policy.maxDelay - heldFor)
        var delay = min(policy.quietWindow, untilMaxDelay)
        if let lastWriteAt {
            delay = max(delay, policy.minInterval - now.timeIntervalSince(lastWriteAt))
        }
        let scheduledGeneration = dirtyGeneration
        timer.schedule(after: max(0, delay)) { [weak self] in
            await self?.performScheduledWrite(generation: scheduledGeneration)
        }
    }

    private func performScheduledWrite(generation: UInt64) async {
        if let task = inFlightWrite {
            let succeeded = await finishWrite(task)
            guard succeeded else { return }
        }
        guard dirty, dirtyGeneration <= generation else { return }
        guard let task = await beginWriteIfNeeded() else { return }
        _ = await finishWrite(task)
    }

    private func beginWriteIfNeeded() async -> Task<WriteOutcome, Never>? {
        guard dirty, inFlightWrite == nil else { return inFlightWrite }
        await hydrate()
        guard dirty, inFlightWrite == nil else { return inFlightWrite }

        let generation = dirtyGeneration
        dirty = false
        firstDirtyAt = nil
        let now = clock.now()
        lastWriteAt = now
        var record = currentRecord(writtenAt: now)
        record.trimToMostRecent()
        documents = record.documents
        let storage = self.storage
        let task = Task { () -> WriteOutcome in
            do {
                try await storage.write(record)
                return WriteOutcome(generation: generation, result: .success(()))
            } catch let error as PositionStorageError {
                return WriteOutcome(generation: generation, result: .failure(error))
            } catch {
                return WriteOutcome(
                    generation: generation,
                    result: .failure(.io(error.localizedDescription)))
            }
        }
        inFlightWrite = task
        inFlightGeneration = generation
        return task
    }

    @discardableResult
    private func finishWrite(_ task: Task<WriteOutcome, Never>) async -> Bool {
        let outcome = await task.value
        guard inFlightGeneration == outcome.generation else { return outcome.succeeded }
        inFlightWrite = nil
        inFlightGeneration = nil
        switch outcome.result {
        case .success:
            writeFailures = 0
            return true
        case .failure:
            // A failed write is transient (disk full today, a coordinated
            // adapter's `.cancelled`/`.notReady` later), so the record stays
            // dirty with a timer pending. Clearing the flag and walking away
            // would turn "never hold a dirty record longer than maxDelay" into
            // "drop it until the user happens to scroll again".
            writeFailures += 1
            dirty = true
            if firstDirtyAt == nil { firstDirtyAt = clock.now() }
            scheduleRetry()
            return false
        }
    }

    /// Retries back off on their own schedule rather than through
    /// `scheduleWrite`: `CoalescePolicy.immediate` asks for a zero delay, and a
    /// zero-delay retry against a persistently failing adapter is a spin.
    private func scheduleRetry() {
        let steps = min(max(writeFailures - 1, 0), 6)
        let delay = min(Self.maxRetryDelay, Self.baseRetryDelay * Double(1 << steps))
        let scheduledGeneration = dirtyGeneration
        timer.schedule(after: delay) { [weak self] in
            await self?.performScheduledWrite(generation: scheduledGeneration)
        }
    }

    private static let baseRetryDelay: TimeInterval = 1
    private static let maxRetryDelay: TimeInterval = 60

    private func currentRecord(writtenAt: Date) -> PositionDeviceRecord {
        PositionDeviceRecord(
            schemaVersion: PositionLayout.schemaVersion,
            deviceID: device.id,
            deviceName: device.name,
            devicePlatform: device.platform,
            writtenAt: writtenAt,
            documents: documents)
    }

    /// Stamps are this device's wall clock, but never go backwards for a given
    /// `(document, field)`: an NTP step or a restore from backup would
    /// otherwise let this device lose a merge to its own past, which is the
    /// skew case that produces user-visible nonsense (scroll forward, the app
    /// writes a backdated stamp, the next read resurrects an older position).
    private func stamp(_ key: DocumentKey, _ field: String) -> Date {
        let id = "\(key.rawValue)#\(field)"
        var now = clock.now()
        if let last = lastStamps[id], now <= last {
            now = last.addingTimeInterval(0.001)
        }
        lastStamps[id] = now
        return now
    }

    // MARK: - Merged view

    /// Folds this device's own file in once, so a flush extends its history
    /// rather than replacing it with only what this launch touched.
    ///
    /// The flag is set only after `loadAll()` has returned and been folded in.
    /// Setting it up front would let an actor-reentrant caller — a `recents()`
    /// racing the first flush at launch — sail past the suspension believing
    /// hydration was done, and `mergedView()` would then substitute the
    /// not-yet-folded in-memory documents for this device's whole persisted
    /// history. Concurrent callers await the one in-flight load instead.
    private func hydrate() async {
        if hydrated { return }
        if let hydration {
            await hydration.value
            return
        }
        let task = Task { await self.loadOwnRecord() }
        hydration = task
        await task.value
        hydration = nil
    }

    private func loadOwnRecord() async {
        let stored = await storage.loadAll()
        guard !hydrated else { return }
        hydrated = true
        guard let own = stored.first(where: { $0.deviceID == device.id }),
            PositionMerge.isUsable(own)
        else { return }
        var base = own.documents
        for (key, pending) in documents {
            base[key] = overlay(base: base[key], pending: pending)
        }
        documents = base
    }

    /// In-memory edits are this device's newest by construction — they happened
    /// after the file was written. Where a stamp says otherwise (a backwards
    /// clock), the value still wins and the stamp is nudged past the file's.
    private func overlay(
        base: PositionDeviceRecord.DocumentEntry?, pending: PositionDeviceRecord.DocumentEntry
    ) -> PositionDeviceRecord.DocumentEntry {
        guard let base else { return pending }
        var merged = base
        if let position = pending.readingPosition {
            merged.readingPosition = Stamped(
                at: forward(position.at, past: base.readingPosition?.at), value: position.value)
        }
        if let openedAt = pending.openedAt {
            merged.openedAt = max(openedAt, base.openedAt ?? openedAt)
        }
        if let closedAt = pending.closedAt {
            merged.closedAt = max(closedAt, base.closedAt ?? closedAt)
        }
        if let title = pending.title {
            merged.title = Stamped(at: forward(title.at, past: base.title?.at), value: title.value)
        }
        if let openState = pending.openState {
            merged.openState = Stamped(
                at: forward(openState.at, past: base.openState?.at), value: openState.value)
        }
        merged.unknownFields = base.unknownFields.merging(pending.unknownFields) { _, new in new }
        return merged
    }

    private func forward(_ stamp: Date, past previous: Date?) -> Date {
        guard let previous, stamp <= previous else { return stamp }
        return previous.addingTimeInterval(0.001)
    }

    private func mergedView() async -> [DocumentKey: MergedDocumentPosition] {
        await hydrate()
        var records = await storage.loadAll().filter { $0.deviceID != device.id }
        records.append(currentRecord(writtenAt: clock.now()))
        return PositionMerge.merge(records)
    }

    /// "Open elsewhere" means elsewhere: this device's own open state is what
    /// the caller already knows.
    private func localized(_ entry: ResumeEntry?) -> ResumeEntry? {
        guard let entry else { return nil }
        return ResumeEntry(
            key: entry.key,
            title: entry.title,
            openedAt: entry.openedAt,
            position: entry.position,
            lastOpenedOn: entry.lastOpenedOn,
            openElsewhere: entry.openElsewhere.filter { $0.id != device.id })
    }
}
