import Foundation
import VellumCore

/// A capability issued for one open directory. Retiring it rejects late callbacks
/// and joins replacements that were already admitted.
public actor SharedLibraryWriteContext {
    public nonisolated let root: RootDirectory
    let device: DeviceIdentity
    private let inkCapabilityBuild: String?
    private var knownInkParticipants: Set<DeviceID> = []
    private var active = true
    private var pending: [UUID: Task<Bool, Error>] = [:]

    private init(root: RootDirectory, device: DeviceIdentity, inkCapabilityBuild: String?) {
        self.root = root
        self.device = device
        self.inkCapabilityBuild = inkCapabilityBuild
    }

    public static func activate(
        root: RootDirectory, inkCapabilityBuild: String? = nil,
        identity: DeviceIdentityProvider<LinuxDeviceIDDefaults>? = nil
    ) async throws -> SharedLibraryWriteContext {
        let device = try await LibraryIO.run { _ in
            try (identity ?? .linux(name: ProcessInfo.processInfo.hostName)).current()
        }
        return try await prepare(root: root, device: device, inkCapabilityBuild: inkCapabilityBuild)
    }

    static func prepare(
        root: RootDirectory, device: DeviceIdentity, inkCapabilityBuild: String? = nil
    ) async throws -> SharedLibraryWriteContext {
        let context = SharedLibraryWriteContext(root: root, device: device, inkCapabilityBuild: inkCapabilityBuild)
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

    /// Only called for a library that has admitted shared editing. A failed
    /// refresh leaves the next compatibility check to fail closed.
    public func advertiseInkCapability() async {
        guard active, let inkCapabilityBuild, await isSelectedRoot(), active else { return }
        let directory = InkCapabilityStore.directory(in: root.url)
        let devicePrefix = device.id.rawValue + "."
        do {
            let entries = try await root.entryNames(in: directory)
            let archives = try await root.entryNames(in: directory.appendingPathComponent("conflicts"))
            guard !entries.contains(where: { $0.hasPrefix(devicePrefix + "sync-conflict-") }),
                  !archives.contains(where: { $0.hasPrefix(devicePrefix) }) else { return }
            try await InkCapabilityStore.advertise(in: root.url, device: device.id,
                appBuild: inkCapabilityBuild, read: { [root] url, limit in
                    try await root.readRegularFile(url, byteLimit: limit)
                }, replace: { url, bytes, expected in
                    try await self.replace(url, with: bytes, ifCurrent: expected)
                })
        } catch {
            // Position and Scratchpad stay writable when ink compatibility
            // cannot be established.
        }
    }

    /// I10 can consult this on the selected context immediately before an ink
    /// edit. A full read replaces any previous decision on each call.
    public func permitsInkEditing() async -> Bool {
        guard active, let inkCapabilityBuild, !Task.isCancelled else { return false }
        do {
            let evidence = try await inkEvidence()
            let inventory = InkCapabilityStore.Inventory(capabilities: evidence.capabilities,
                positions: evidence.positions, hasRecovery: evidence.hasRecovery)
            knownInkParticipants.formUnion(inventory.devices)
            guard try await inventory.permitsInk(in: root.url,
                requiring: knownInkParticipants, localDevice: device.id, localBuild: inkCapabilityBuild,
                read: { [root] url, limit in
                    try await root.readRegularFile(url, byteLimit: limit)
                }),
                try await inkEvidence() == evidence,
                await isSelectedRoot()
            else { return false }
            return active && !Task.isCancelled && inventory.devices.isSuperset(of: knownInkParticipants)
        } catch {
            return false
        }
    }

    private func isSelectedRoot() async -> Bool {
        (try? await RootDirectory.open(root.url))?.identity == root.identity
    }

    private func inkEvidence() async throws -> (capabilities: [String], positions: [String], hasRecovery: Bool) {
        let capabilities = InkCapabilityStore.directory(in: root.url)
        let positions = root.url.appendingPathComponent(".vellum/positions", isDirectory: true)
        let capabilityNames = try await root.entryNames(in: capabilities)
        let positionNames = try await root.entryNames(in: positions)
        // Kept conflict and quarantine bytes still represent unresolved
        // evidence, even after the storage adapter has archived a sibling.
        let recovery = try await root.entryNames(in: capabilities.appendingPathComponent("conflicts"))
            + root.entryNames(in: positions.appendingPathComponent("conflicts"))
            + root.entryNames(in: positions.appendingPathComponent("quarantine"))
        return (capabilityNames.filter { $0 != "conflicts" },
                positionNames.filter { $0 != "conflicts" && $0 != "quarantine" }, !recovery.isEmpty)
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
            if try await replace(file, with: bytes, ifCurrent: original) {
                await advertiseInkCapability()
                return
            }
        }
        throw LibraryFileError.retryable
    }
}
