import Foundation

/// `<appDataDir>/positions/` — a SIBLING of `web/`, never inside it.
enum PositionLayout {
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? WebLibrary.appDataDir.appendingPathComponent("positions", isDirectory: true)
    }

    static let schemaVersion = 1

    /// The version lives in the file name as well as the body: a v2 build
    /// writes `<device>.v2.json`, a v1 build simply doesn't recognise it and
    /// leaves it alone, so a downgrade is non-destructive for free.
    static func fileName(for device: DeviceID, version: Int = schemaVersion) -> String {
        "\(device.rawValue).v\(version).json"
    }

    static func parseFileName(_ name: String) -> (device: DeviceID, version: Int)? {
        guard name.hasSuffix(".json") else { return nil }
        let stem = String(name.dropLast(".json".count))
        guard let marker = stem.range(of: ".v", options: .backwards) else { return nil }
        let deviceID = String(stem[stem.startIndex..<marker.lowerBound])
        let versionText = String(stem[marker.upperBound...])
        guard !deviceID.isEmpty,
            !versionText.isEmpty,
            versionText.allSatisfy({ ("0"..."9").contains($0) }),
            let version = Int(versionText)
        else { return nil }
        return (DeviceID(deviceID), version)
    }
}

/// The only thing between the store and bytes. A coordinated adapter can be
/// supplied later without a line changing above this line.
protocol PositionStorage: Sendable {
    /// Every device record currently visible locally, including this device's.
    /// A record that fails to decode is omitted, never thrown.
    func loadAll() async -> [PositionDeviceRecord]
    /// Replace this device's own record. MUST be atomic (tmp + rename).
    func write(_ record: PositionDeviceRecord) async throws
}

enum PositionStorageError: Error, Equatable, Sendable {
    case io(String)
}

/// Production storage. Constructed with a root it cannot escape — it appends
/// only `<device_id>.v<N>.json` leaf names, so it is structurally incapable of
/// addressing `web/records/`.
struct FilePositionStorage: PositionStorage {
    let root: URL

    init(root: URL = PositionLayout.root) {
        self.root = root
    }

    /// The single leaf name this adapter can ever write. Exposed so a test can
    /// assert the resolved URL rather than trust the claim.
    func fileURL(for device: DeviceID, version: Int = PositionLayout.schemaVersion) -> URL {
        root.appendingPathComponent(PositionLayout.fileName(for: device, version: version))
    }

    var quarantineDir: URL {
        root.appendingPathComponent("quarantine", isDirectory: true)
    }

    func loadAll() async -> [PositionDeviceRecord] {
        let fileManager = FileManager.default
        guard
            let names = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var records: [PositionDeviceRecord] = []
        for url in names.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let parsed = PositionLayout.parseFileName(url.lastPathComponent) else { continue }
            guard let data = try? Data(contentsOf: url) else { continue }
            guard var record = try? PositionCoding.decoder.decode(PositionDeviceRecord.self, from: data)
            else {
                // The bytes are a device's reading history the user can't
                // recreate; quarantine rather than delete.
                quarantine(url)
                continue
            }
            record.fileNameVersion = parsed.version
            if parsed.version != record.schemaVersion { quarantine(url) }
            records.append(record)
        }
        return records
    }

    func write(_ record: PositionDeviceRecord) async throws {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw PositionStorageError.io(
                "Failed to create positions dir: \(error.localizedDescription)")
        }
        let path = fileURL(for: record.deviceID, version: record.schemaVersion)
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

/// Tests / previews.
final class InMemoryPositionStorage: PositionStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [DeviceID: PositionDeviceRecord] = [:]
    private var writes = 0
    private var lastBytes: Data?
    private var pendingError: Error?

    init() {}

    var writeCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    var lastWrittenBytes: Data? {
        lock.lock()
        defer { lock.unlock() }
        return lastBytes
    }

    func seed(_ record: PositionDeviceRecord) {
        lock.lock()
        defer { lock.unlock() }
        records[record.deviceID] = record
    }

    func failNextWrite(with error: Error) {
        lock.lock()
        defer { lock.unlock() }
        pendingError = error
    }

    func loadAll() async -> [PositionDeviceRecord] {
        lock.withLock { records.values.sorted { $0.deviceID < $1.deviceID } }
    }

    func write(_ record: PositionDeviceRecord) async throws {
        let bytes = try PositionCoding.encoder.encode(record)
        try lock.withLock {
            if let pendingError {
                self.pendingError = nil
                throw pendingError
            }
            writes += 1
            lastBytes = bytes
            records[record.deviceID] = record
        }
    }
}
