import Foundation

// FOUNDATION ONLY — compiled into the share extension. See CaptureRecord.swift.

/// Bounded admission followed by atomic publication of one complete record.
struct CaptureInboxWriter: Sendable {
    let layout: CaptureInboxLayout
    let capacity: CaptureInboxCapacity

    init(container: URL) {
        self.init(layout: CaptureInboxLayout(container: container))
    }

    init(layout: CaptureInboxLayout, capacity: CaptureInboxCapacity = CaptureInboxCapacity()) {
        self.layout = layout
        self.capacity = capacity
    }

    /// Publish a private temp file as `pending/<epoch_ms>-<capture_id>.json`.
    ///
    /// The millisecond prefix is zero-padded to 13 digits so a plain
    /// lexicographic directory listing is already in capture order; the UUID
    /// suffix makes same-millisecond collisions impossible.
    @discardableResult
    func write(_ record: CaptureRecord) throws -> URL {
        guard UUID(uuidString: record.captureID) != nil else {
            throw CaptureInboxError.io("The capture identifier is invalid.")
        }
        let json = try CaptureCoding.encode(record)
        guard json.count <= CaptureInboxFiles.maximumRecordBytes else { throw CaptureInboxError.recordTooLarge }
        return try CaptureInboxFiles.withLock(layout: layout) {
            let files = try CaptureInboxFiles.files(in: layout.pending) + CaptureInboxFiles.files(in: layout.failed)
            var bytes: Int64 = 0
            for url in files {
                let size = try CaptureInboxFiles.regularFileSize(url)
                guard size <= Int64.max - bytes else { throw CaptureInboxError.capacityExceeded }
                bytes += size
            }
            guard files.count < capacity.maximumEntries,
                  bytes <= capacity.maximumBytes,
                  Int64(json.count) <= capacity.maximumBytes - bytes else {
                throw CaptureInboxError.capacityExceeded
            }
            let tmp = layout.tmp.appendingPathComponent("\(UUID().uuidString.lowercased()).json")
            let destination = layout.pending.appendingPathComponent(Self.pendingFileName(for: record))
            defer { try? FileManager.default.removeItem(at: tmp) }
            try json.write(to: tmp)
            try CaptureInboxFiles.publish(tmp, to: destination)
            return destination
        }
    }

    static func pendingFileName(for record: CaptureRecord) -> String {
        let seconds = CaptureTimestamp.parse(record.capturedAt)?.timeIntervalSince1970 ?? 0
        let milliseconds = max(0, Int64((seconds * 1000).rounded()))
        return String(format: "%013lld-%@.json", milliseconds, record.captureID)
    }
}
