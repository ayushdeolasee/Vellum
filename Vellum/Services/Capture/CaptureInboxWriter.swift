import Foundation

// FOUNDATION ONLY — compiled into the share extension. See CaptureRecord.swift.

/// The extension's entire disk contract: one encode, one write, one rename.
struct CaptureInboxWriter: Sendable {
    let layout: CaptureInboxLayout

    init(container: URL) {
        self.init(layout: CaptureInboxLayout(container: container))
    }

    init(layout: CaptureInboxLayout) {
        self.layout = layout
    }

    /// `tmp/<capture_id>.json` -> `rename(2)` -> `pending/<epoch_ms>-<capture_id>.json`.
    ///
    /// The millisecond prefix is zero-padded to 13 digits so a plain
    /// lexicographic directory listing is already in capture order; the UUID
    /// suffix makes same-millisecond collisions impossible.
    @discardableResult
    func write(_ record: CaptureRecord) throws -> URL {
        do {
            try layout.createDirectories()
        } catch {
            throw CaptureInboxError.io(
                "Failed to create capture inbox: \(error.localizedDescription)")
        }

        let json: Data
        do {
            json = try CaptureCoding.encode(record)
        } catch {
            throw CaptureInboxError.io(
                "Failed to serialize capture record: \(error.localizedDescription)")
        }

        let tmp = layout.tmp.appendingPathComponent("\(record.captureID).json")
        let destination = layout.pending.appendingPathComponent(Self.pendingFileName(for: record))
        do {
            try json.write(to: tmp)
        } catch {
            throw CaptureInboxError.io(
                "Failed to write capture record: \(error.localizedDescription)")
        }
        guard rename(tmp.path, destination.path) == 0 else {
            try? FileManager.default.removeItem(at: tmp)
            throw CaptureInboxError.io("Failed to commit capture record: rename failed")
        }
        return destination
    }

    static func pendingFileName(for record: CaptureRecord) -> String {
        let seconds = CaptureTimestamp.parse(record.capturedAt)?.timeIntervalSince1970 ?? 0
        let milliseconds = max(0, Int64((seconds * 1000).rounded()))
        return String(format: "%013lld-%@.json", milliseconds, record.captureID)
    }
}
