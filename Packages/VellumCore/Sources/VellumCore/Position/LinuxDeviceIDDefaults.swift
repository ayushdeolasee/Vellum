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
        try lockLinuxFile(lock)
        let url = directory.appendingPathComponent("device-id")
        let stored: String
        do {
            stored = try String(contentsOf: url, encoding: .utf8)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            let id = UUID().uuidString.lowercased()
            try writePrivateID(id, to: url)
            return id
        }

        guard let uuid = UUID(uuidString: stored.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let id = uuid.uuidString.lowercased()
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        if stored != id || mode?.intValue != 0o600 {
            try writePrivateID(id, to: url)
        }
        return id
    }

    private func writePrivateID(_ id: String, to url: URL) throws {
        // Set permissions at creation, before publishing any bytes, even with a permissive umask.
        let temporary = directory.appendingPathComponent(".device-id-\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(id.utf8))
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
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
