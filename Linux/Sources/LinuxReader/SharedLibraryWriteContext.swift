import Foundation
import VellumCore

/// A capability issued for one open directory. Retiring it rejects late callbacks
/// and joins replacements that were already admitted.
public actor SharedLibraryWriteContext {
    public nonisolated let root: RootDirectory
    let device: DeviceIdentity
    private var active = true
    private var pending: [UUID: Task<Bool, Error>] = [:]

    private init(root: RootDirectory, device: DeviceIdentity) {
        self.root = root
        self.device = device
    }

    public static func activate(root: RootDirectory) async throws -> SharedLibraryWriteContext {
        let device = try await LibraryIO.run { _ in
            try DeviceIdentityProvider.linux(name: ProcessInfo.processInfo.hostName).current()
        }
        return try await prepare(root: root, device: device)
    }

    static func prepare(root: RootDirectory, device: DeviceIdentity) async throws -> SharedLibraryWriteContext {
        let context = SharedLibraryWriteContext(root: root, device: device)
        let ignore = root.url.appendingPathComponent(".stignore", isDirectory: false)
        let original = try await root.readRegularFile(ignore, byteLimit: 1024 * 1024)
        let updated = try StignoreManager.render(original ?? Data())
        if updated != original {
            guard try await context.replace(ignore, with: updated, ifCurrent: original) else {
                throw StignoreManager.UpdateError.changedDuringUpdate
            }
        }
        return context
    }

    public func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool {
        guard active else { throw ReaderFileError.readOnly }
        let limit: Int
        switch url.pathExtension.lowercased() {
        case "pdf": limit = PdfiumDocument.maxInputBytes
        case "vellumweb": limit = ArchiveCodec.maxArchiveBytes
        default: limit = url.lastPathComponent == ".stignore" ? 1024 * 1024 : 32 * 1024 * 1024
        }
        let id = UUID()
        let task = Task { [root] in try await root.replace(url, with: data, ifCurrent: expected, limit: limit) }
        pending[id] = task
        defer { pending[id] = nil }
        return try await task.value
    }

    public func retire() async {
        active = false
        for task in pending.values { _ = await task.result }
    }

    @concurrent
    public func savePosition(_ position: ReadingPosition, for key: DocumentKey, at timestamp: Date = .now) async throws {
        let device = self.device
        let dir = root.url.appendingPathComponent(".vellum/positions", isDirectory: true)
        let file = try PositionLayout.fileURL(in: dir, for: device.id)
        for _ in 0..<3 {
            let original = try await root.readRegularFile(file, byteLimit: 32 * 1024 * 1024)
            var record: PositionDeviceRecord
            if let original {
                record = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: original)
                guard record.deviceID == device.id, record.schemaVersion == PositionLayout.schemaVersion
                else { throw PositionStorageError.io("Device record has an incompatible identity or version.") }
            } else {
                record = PositionDeviceRecord(deviceID: device.id, deviceName: device.name,
                                              devicePlatform: device.platform, writtenAt: .now)
            }
            var entry = record.documents[key] ?? .init()
            if let latest = entry.readingPosition?.at, latest >= timestamp { return }
            var value = position
            value.unknownFields = entry.readingPosition?.value.unknownFields ?? [:]
            var field = Stamped(at: timestamp, value: value)
            field.unknownFields = entry.readingPosition?.unknownFields ?? [:]
            entry.readingPosition = field
            record.documents[key] = entry
            record.writtenAt = max(record.writtenAt, timestamp)
            record.trimToMostRecent()
            let bytes = try PositionCoding.encoder.encode(record)
            if try await replace(file, with: bytes, ifCurrent: original) { return }
        }
        throw LibraryFileError.retryable
    }
}
