import Foundation

/// `<appDataDir>/positions/` — a SIBLING of `web/`, never inside it.
public enum PositionLayout {
    public static let schemaVersion = 1

    /// The version lives in the file name as well as the body: a v2 build
    /// writes `<device>.v2.json`, a v1 build simply doesn't recognise it and
    /// leaves it alone, so a downgrade is non-destructive for free.
    public static func fileName(for device: DeviceID, version: Int = schemaVersion) -> String {
        "\(device.rawValue).v\(version).json"
    }

    public static func fileURL(in root: URL, for device: DeviceID, version: Int = schemaVersion) throws -> URL {
        let name = fileName(for: device, version: version)
        guard version >= 1, parseFileName(name) != nil else {
            throw PositionStorageError.io("Invalid reading position filename")
        }
        return root.appendingPathComponent(name)
    }

    public struct FileName: Sendable {
        public let device: DeviceID
        public let version: Int

        /// Decode bytes obtained by the caller's file store. Preserve the filename version
        /// so PositionMerge can reject mismatches without opening or repairing a file.
        public func decode(_ bytes: Data) throws -> PositionDeviceRecord {
            var record = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: bytes)
            record.fileNameVersion = version
            return record
        }
    }

    public static func parseFileName(_ name: String) -> FileName? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(".json".count))
        guard let marker = stem.range(of: ".v", options: .backwards) else { return nil }
        let deviceID = String(stem[stem.startIndex..<marker.lowerBound])
        let versionText = String(stem[marker.upperBound...])
        guard !deviceID.isEmpty, !deviceID.hasPrefix("."),
            !deviceID.utf8.contains(0x2f), !deviceID.utf8.contains(0x5c), !deviceID.utf8.contains(0),
            !versionText.isEmpty,
            versionText.allSatisfy({ ("0"..."9").contains($0) }),
            let version = Int(versionText)
        else { return nil }
        return FileName(device: DeviceID(deviceID), version: version)
    }
}

/// The only thing between the store and bytes. A coordinated adapter can be
/// supplied later without a line changing above this line.
public protocol PositionStorage: Sendable {
    /// Every device record currently visible locally, including this device's.
    /// A record that fails to decode is omitted, never thrown.
    func loadAll() async -> [PositionDeviceRecord]
    /// Replace this device's own record. MUST be atomic (tmp + rename).
    func write(_ record: PositionDeviceRecord) async throws
}

public enum PositionStorageError: Error, Equatable, Sendable {
    case io(String)
}

/// Production storage. Constructed with a root it cannot escape — it appends
/// only `<device_id>.v<N>.json` leaf names, so it is structurally incapable of
/// addressing `web/records/`.
public struct FilePositionStorage: PositionStorage {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var quarantineDir: URL {
        root.appendingPathComponent("quarantine", isDirectory: true)
    }

    public func loadAll() async -> [PositionDeviceRecord] {
        let fileManager = FileManager.default
        guard
            let names = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var records: [PositionDeviceRecord] = []
        for url in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let parsed = PositionLayout.parseFileName(url.lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let record = try? parsed.decode(data) else {
                // The bytes are a device's reading history the user can't
                // recreate; quarantine rather than delete.
                if parsed.version <= PositionLayout.schemaVersion { quarantine(url) }
                continue
            }
            if parsed.version != record.schemaVersion && record.schemaVersion <= PositionLayout.schemaVersion {
                quarantine(url)
            }
            records.append(record)
        }
        return records
    }

    public func write(_ record: PositionDeviceRecord) async throws {
        let path = try PositionLayout.fileURL(in: root, for: record.deviceID, version: record.schemaVersion)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw PositionStorageError.io(
                "Failed to create positions dir: \(error.localizedDescription)")
        }
        let json: Data
        do {
            json = try PositionCoding.encoder.encode(record)
        } catch {
            throw PositionStorageError.io(
                "Failed to serialize position record: \(error.localizedDescription)")
        }
        let tmp = root.appendingPathComponent(
            ".\(path.lastPathComponent).tmp-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.lowercased())")
        do {
            try json.write(to: tmp)
        } catch {
            try? fileManager.removeItem(at: tmp)
            throw PositionStorageError.io(
                "Failed to write position record: \(error.localizedDescription)")
        }
        guard rename(tmp.path, path.path) == 0 else {
            try? fileManager.removeItem(at: tmp)
            throw PositionStorageError.io("Failed to commit position record: rename failed")
        }
    }

    private func quarantine(_ url: URL) {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: quarantineDir, withIntermediateDirectories: true)
        let destination = quarantineDir.appendingPathComponent(url.lastPathComponent)
        try? fileManager.removeItem(at: destination)
        try? fileManager.moveItem(at: url, to: destination)
    }
}
