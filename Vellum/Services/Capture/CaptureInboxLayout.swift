import Foundation

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

enum CaptureInboxError: Error, Equatable {
    case io(String)
}
