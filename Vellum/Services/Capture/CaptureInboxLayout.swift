import Foundation
import Darwin

// FOUNDATION ONLY — compiled into the share extension. See CaptureRecord.swift.

/// Where the capture inbox lives inside the App Group container.
///
/// This type contains NO reference to `url(forUbiquityContainerIdentifier:)`.
/// Captures are a device-local handoff between two processes on one device;
/// routing them through iCloud would put an unsynced-yet, half-uploaded file in
/// the path of a share sheet that has 200ms to finish.
struct CaptureInboxLayout: Sendable, Equatable {
    static var appGroupIdentifier: String { RuntimeProfile.current.appGroupIdentifier }

    nonisolated(unsafe) static var containerOverride: URL?

    let container: URL

    init(container: URL) {
        self.container = container
    }

    /// `nil` when the App Group is unavailable (no entitlement, not provisioned).
    /// Callers degrade to "no capture" — never to some other container.
    static func resolve() -> CaptureInboxLayout? {
        if let containerOverride { return CaptureInboxLayout(container: containerOverride) }
        guard
            let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        return CaptureInboxLayout(container: url)
    }

    var root: URL { container.appendingPathComponent("capture", isDirectory: true) }
    /// Temps live in their own directory, not beside the records they become,
    /// so a drain enumerating `pending/` cannot see a half-written file even in
    /// principle. That is stronger than an extension filter and costs one mkdir.
    var tmp: URL { root.appendingPathComponent("tmp", isDirectory: true) }
    var pending: URL { root.appendingPathComponent("pending", isDirectory: true) }
    var failed: URL { root.appendingPathComponent("failed", isDirectory: true) }

    func createDirectories() throws {
        let fileManager = FileManager.default
        for directory in [tmp, pending, failed] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}

enum CaptureInboxError: LocalizedError, Equatable {
    case io(String)
    case capacityExceeded
    case recordTooLarge
    case noLongerAvailable

    var errorDescription: String? {
        switch self {
        case .io(let message): message
        case .capacityExceeded: "Your unsaved captures have reached 256 MB or 1,000 pages. Open Vellum Settings → Storage to retry, export or delete captures, then share this page again. Your existing captures are kept."
        case .recordTooLarge: "This capture is too large to read safely. Export it or delete it in Settings → Storage."
        case .noLongerAvailable: "This capture has already been saved or removed."
        }
    }
}

/// One budget for pending and quarantined intent. Existing captures are never
/// evicted to make room; only a new share can be refused.
struct CaptureInboxCapacity: Sendable {
    var maximumBytes: Int64 = 256 * 1024 * 1024
    var maximumEntries: Int = 1_000
}

/// Foundation-only disk discipline shared by the app and extension. The short
/// file lock protects admission and publication across processes; network work
/// never holds it. Every caller runs file I/O outside the main actor.
enum CaptureInboxFiles {
    // JSON can escape each DOM byte as six bytes; leave room for its metadata.
    static let maximumRecordBytes = CaptureDOMPolicy.maximumByteCount * 6 + 65_536

    static func withLock<T>(layout: CaptureInboxLayout, _ operation: () throws -> T) throws -> T {
        try layout.createDirectories()
        let lockURL = layout.root.appendingPathComponent(".inbox.lock")
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CaptureInboxError.io("Capture storage is unavailable.") }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { throw CaptureInboxError.io("Capture storage is busy.") }
        defer { flock(descriptor, LOCK_UN) }
        try recoverOrphanedTemps(layout: layout)
        return try operation()
    }

    /// Writers create and publish temps while holding this same lock. Once we
    /// acquire it, every leftover temp belongs to an interrupted write. Preserve
    /// even incomplete/future bytes in failed, where recovery and quota see them.
    private static func recoverOrphanedTemps(layout: CaptureInboxLayout) throws {
        let temporary = try files(in: layout.tmp)
        guard !temporary.isEmpty else { return }
        var published = try files(in: layout.pending) + files(in: layout.failed)
        for source in temporary {
            _ = try regularFileSize(source)
            var sourceStat = stat()
            guard lstat(source.path, &sourceStat) == 0 else { continue }
            // A crash after link publication but before unlink leaves two names
            // for the same bytes. Keep the published copy and remove only its
            // redundant temp name, rather than counting another save request.
            let alreadyPublished = published.contains { destination in
                var destinationStat = stat()
                return lstat(destination.path, &destinationStat) == 0
                    && sourceStat.st_dev == destinationStat.st_dev
                    && sourceStat.st_ino == destinationStat.st_ino
            }
            if alreadyPublished {
                try FileManager.default.removeItem(at: source)
            } else {
                let destination = availableDestination(in: layout.failed, name: source.lastPathComponent)
                try publish(source, to: destination)
                published.append(destination)
            }
        }
    }

    static func files(in directory: URL) throws -> [URL] {
        do {
            return try FileManager.default.contentsOfDirectory(at: directory,
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile { return [] }
    }

    static func regularFileSize(_ url: URL) throws -> Int64 {
        var attributes = stat()
        guard lstat(url.path, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CaptureInboxError.io("This capture is not a readable file.")
        }
        return max(0, Int64(attributes.st_size))
    }

    static func readRecord(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CaptureInboxError.io("This capture could not be read.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var attributes = stat()
        guard fstat(descriptor, &attributes) == 0,
              attributes.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw CaptureInboxError.io("This capture is not a readable file.")
        }
        guard attributes.st_size <= maximumRecordBytes else { throw CaptureInboxError.recordTooLarge }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65_536, maximumRecordBytes - data.count + 1)),
              !chunk.isEmpty {
            guard data.count + chunk.count <= maximumRecordBytes else { throw CaptureInboxError.recordTooLarge }
            data.append(chunk)
        }
        return data
    }

    /// link(2) publishes complete bytes atomically and refuses an existing
    /// destination. Unlike rename(2), it cannot overwrite another capture.
    static func publish(_ source: URL, to destination: URL) throws {
        guard link(source.path, destination.path) == 0 else {
            throw CaptureInboxError.io("A capture already exists here, or storage is unavailable.")
        }
        try FileManager.default.removeItem(at: source)
    }

    static func availableDestination(in directory: URL, name: String) -> URL {
        let proposed = directory.appendingPathComponent(name)
        var attributes = stat()
        if lstat(proposed.path, &attributes) != 0 { return proposed }
        return directory.appendingPathComponent(name).deletingPathExtension()
            .appendingPathExtension(UUID().uuidString.lowercased()).appendingPathExtension("json")
    }
}
