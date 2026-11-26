#if os(Linux)
import Foundation
import Glibc

/// Device settings live outside the synced library. Constructing the provider performs no I/O.
public struct LinuxDeviceIDDefaults: DeviceIDDefaults {
    let directory: URL

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let stateHome: URL
        if let path = environment["XDG_STATE_HOME"], path.hasPrefix("/") {
            stateHome = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            let home: URL
            if let path = environment["HOME"], path.hasPrefix("/") {
                home = URL(fileURLWithPath: path, isDirectory: true)
            } else {
                home = FileManager.default.homeDirectoryForCurrentUser
            }
            stateHome = home.appendingPathComponent(".local/state", isDirectory: true)
        }
        directory = stateHome.appendingPathComponent("vellum", isDirectory: true)
    }

    public func loadOrCreateID(forKey key: String) throws -> String {
        guard key == DeviceIdentity.defaultsKey else { throw CocoaError(.fileWriteInvalidFileName) }
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        // Lock a stable inode: the atomic write below replaces the device-id inode.
        let lock = open(directory.appendingPathComponent("device-id.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(lock) }
        while flock(lock, LOCK_EX) != 0 {
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        let url = directory.appendingPathComponent("device-id")
        do {
            let id = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard UUID(uuidString: id) != nil else { throw CocoaError(.fileReadCorruptFile) }
            return id
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let id = UUID().uuidString.lowercased()
            try Data(id.utf8).write(to: url, options: .atomic)
            return id
        }
    }
}

extension DeviceIdentityProvider where Defaults == LinuxDeviceIDDefaults {
    public static func linux(
        name: String = "Linux", environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Self {
        Self(defaults: LinuxDeviceIDDefaults(environment: environment), name: name, platform: "linux")
    }
}
#endif
