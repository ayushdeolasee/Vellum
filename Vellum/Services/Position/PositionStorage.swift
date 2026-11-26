import Foundation
import VellumCore

typealias PositionLayout = VellumCore.PositionLayout
typealias PositionStorage = VellumCore.PositionStorage
typealias PositionStorageError = VellumCore.PositionStorageError
typealias FilePositionStorage = VellumCore.FilePositionStorage

extension PositionLayout {
    nonisolated(unsafe) static var rootOverride: URL?

    static var root: URL {
        rootOverride ?? WebLibrary.appDataDir.appendingPathComponent("positions", isDirectory: true)
    }
}

extension FilePositionStorage {
    init() { self.init(root: PositionLayout.root) }
}

/// Routes position records through the app's active storage context. Local and
/// custom-folder modes keep the proven direct adapter above; iCloud discovers
/// peer records through metadata and coordinates every byte read and replace.
struct CoordinatedPositionStorage: PositionStorage {
    let coordinator: StorageCoordinator

    func loadAll() async -> [PositionDeviceRecord] {
        (try? await coordinator.withStorageContext { context in
            switch context {
            case .direct(let layout):
                return await Self.directStorage(for: layout).loadAll()
            case .coordinated(let container, let layout):
                return try await loadAll(
                    from: layout.positionsDir,
                    container: container)
            }
        }) ?? []
    }

    func write(_ record: PositionDeviceRecord) async throws {
        try await coordinator.withStorageContext { context in
            switch context {
            case .direct(let layout):
                try await Self.directStorage(for: layout).write(record)
            case .coordinated(let container, let layout):
                let url = try PositionLayout.fileURL(
                    in: layout.positionsDir, for: record.deviceID, version: record.schemaVersion)
                let bytes = try PositionCoding.encoder.encode(record)
                try await container.replace(url, with: bytes)
            }
        }
    }

    private func loadAll(
        from root: URL,
        container: any SyncedContainer
    ) async throws -> [PositionDeviceRecord] {
        let items = try await container.list(
            root,
            matching: SyncedItemFilter(fileExtension: "json", readyOnly: true))
        var records: [PositionDeviceRecord] = []
        for item in items {
            guard let parsed = PositionLayout.parseFileName(item.name) else { continue }
            do {
                let record = try await container.read(item.url) { try parsed.decode($0) }
                if parsed.version != record.schemaVersion && record.schemaVersion <= PositionLayout.schemaVersion {
                    try await quarantine(item.url, in: root, container: container)
                }
                records.append(record)
            } catch {
                guard parsed.version <= PositionLayout.schemaVersion else { continue }
                try? await quarantine(item.url, in: root, container: container)
            }
        }
        return records
    }

    private func quarantine(
        _ source: URL,
        in root: URL,
        container: any SyncedContainer
    ) async throws {
        let bytes = try await container.data(at: source)
        let destination = root
            .appendingPathComponent("quarantine", isDirectory: true)
            .appendingPathComponent(source.lastPathComponent)
        // Keep the peer's source intact. Its owner may still be able to repair
        // or replace it, and deleting it here would propagate data loss.
        try await container.replace(destination, with: bytes)
    }

    private static func directStorage(for layout: WebStorageLayout) -> FilePositionStorage {
        FilePositionStorage(root: PositionLayout.rootOverride ?? layout.positionsDir)
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
