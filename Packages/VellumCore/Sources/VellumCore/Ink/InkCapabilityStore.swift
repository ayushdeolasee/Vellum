import Foundation

public enum InkCapabilityStore {
    public static let feature = "ink-tombstones"
    public static let byteLimit = 64 * 1024
    public static let positionByteLimit = 32 * 1024 * 1024

    // An expired advertisement still counts as a participant. Expiration
    // limits how long an offline advertisement can vouch for the old build.
    private static let lifetime: TimeInterval = 24 * 60 * 60
    private static let clockSkew: TimeInterval = 5 * 60

    public static func directory(in root: URL) -> URL {
        root.appendingPathComponent(".vellum/capabilities", isDirectory: true)
    }

    public typealias Read = @Sendable (URL, Int) async throws -> Data?
    public typealias Replace = @Sendable (URL, Data, Data?) async throws -> Bool

    /// Refresh only this install's record. Read the current position before
    /// publishing so an update from an older build invalidates the claim, even
    /// if that build preserves unknown keys or has a different clock.
    public static func advertise(
        in root: URL, device: DeviceID, appBuild: String, now: Date = .now,
        read: Read, replace: Replace
    ) async throws {
        guard validBuild(appBuild), validDevice(device) else { throw LibraryFileError.unavailable }
        let positions = root.appendingPathComponent(".vellum/positions", isDirectory: true)
        let position = try PositionLayout.fileURL(in: positions, for: device)
        let url = directory(in: root).appendingPathComponent(device.rawValue + ".json")

        for _ in 0..<3 {
            let original = try await read(url, byteLimit)
            let digest = try await positionDigest(at: position, device: device, read: read)
            var record = Advertisement(deviceID: device, appBuild: appBuild,
                                       advertisedAt: now, positionSHA256: digest)
            if let original {
                let old = try decode(original, for: device)
                guard old.advertisedAt <= now else { throw LibraryFileError.retryable }
                if old.appBuild == appBuild, old.features.contains(feature),
                   old.positionSHA256 == digest, now.timeIntervalSince(old.advertisedAt) < lifetime / 2 {
                    return
                }
                record.unknownFields = old.unknownFields
            }
            let data = try PositionCoding.encoder.encode(record)
            guard data.count <= byteLimit else { throw LibraryFileError.unavailable }
            if try await replace(url, data, original) { return }
        }
        throw LibraryFileError.retryable
    }

    /// Files observed in the two per-device namespaces. Include conflicts,
    /// placeholders and unexpected entries so the caller can fail closed.
    public struct Inventory: Sendable {
        public let devices: Set<DeviceID>
        public let isComplete: Bool
        private let positionDevices: Set<DeviceID>
        private let advertisingDevices: Set<DeviceID>

        public init(capabilities: [String], positions: [String], hasRecovery: Bool) {
            let advertisements = Self.parse(capabilities) { name in
                guard name.hasSuffix(".json") else { return nil }
                let device = DeviceID(String(name.dropLast(".json".count)))
                return validDevice(device) ? device : nil
            }
            let positionFiles = Self.parse(positions) { name in
                guard let parsed = PositionLayout.parseFileName(name), validDevice(parsed.device) else { return nil }
                return parsed.device
            }
            advertisingDevices = advertisements.devices
            positionDevices = positionFiles.devices
            devices = advertisingDevices.union(positionDevices)
            let unsupportedVersion = positions.contains {
                guard let file = PositionLayout.parseFileName($0) else { return false }
                return $0 != PositionLayout.fileName(for: file.device)
            }
            isComplete = advertisements.complete && positionFiles.complete && !unsupportedVersion && !hasRecovery
        }

        private static func parse(
            _ names: [String], deviceFor: (String) -> DeviceID?
        ) -> (devices: Set<DeviceID>, complete: Bool) {
            var devices: Set<DeviceID> = []
            var complete = true
            for name in names {
                // Our own atomic-write staging and sync-daemon temporary data
                // are not participants. A conflict or offline placeholder is.
                if name.contains(".sync-conflict-") || name.hasSuffix(".icloud") {
                    complete = false
                } else if SyncArtifact.matches(name) {
                    continue
                } else if let device = deviceFor(name), devices.insert(device).inserted {
                    continue
                } else {
                    complete = false
                }
            }
            return (devices, complete)
        }

        /// Check again immediately before each future ink mutation. A grant is
        /// about this observed snapshot and cannot be carried to another folder
        /// or retained when discovery and reads disagree.
        public func permitsInk(
            in root: URL, requiring known: Set<DeviceID>, localDevice: DeviceID,
            now: Date = .now, read: Read
        ) async throws -> Bool {
            guard isComplete, devices.contains(localDevice),
                  devices.count > 1, devices.isSuperset(of: known), devices == advertisingDevices
            else { return false }
            let capabilities = directory(in: root)
            let positions = root.appendingPathComponent(".vellum/positions", isDirectory: true)
            for device in devices {
                let url = capabilities.appendingPathComponent(device.rawValue + ".json")
                guard let bytes = try await read(url, byteLimit) else { return false }
                let record = try decode(bytes, for: device)
                let age = now.timeIntervalSince(record.advertisedAt)
                guard age >= -clockSkew, age < lifetime, record.features.contains(feature) else { return false }
                let position = try PositionLayout.fileURL(in: positions, for: device)
                let digest = try await positionDigest(at: position, device: device, read: read)
                guard (digest != nil) == positionDevices.contains(device),
                      digest == record.positionSHA256 else { return false }
            }
            return true
        }
    }

    private static func positionDigest(at url: URL, device: DeviceID, read: Read) async throws -> String? {
        guard let bytes = try await read(url, positionByteLimit) else { return nil }
        let record = try PositionCoding.decoder.decode(PositionDeviceRecord.self, from: bytes)
        guard record.deviceID == device, record.schemaVersion == PositionLayout.schemaVersion
        else { throw LibraryFileError.unavailable }
        return DocumentIdentity.byteHash(bytes)
    }

    private static func validDevice(_ device: DeviceID) -> Bool {
        let value = device.rawValue
        // Match the portable device identities used by position records. Do
        // not accept aliases, dots, or path separators in an advertisement.
        return !value.isEmpty && value.utf8.count <= 128 && value.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
        }
    }

    private static func validBuild(_ build: String) -> Bool {
        !build.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && build.utf8.count <= 256
    }

    private static func decode(_ data: Data, for device: DeviceID) throws -> Advertisement {
        let record = try PositionCoding.decoder.decode(Advertisement.self, from: data)
        guard record.schemaVersion == 1, record.deviceID == device, validBuild(record.appBuild),
              Set(record.features).count == record.features.count else { throw LibraryFileError.unavailable }
        return record
    }

    private struct Advertisement: Codable {
        let schemaVersion: Int
        let deviceID: DeviceID
        let appBuild: String
        let features: [String]
        let advertisedAt: Date
        let positionSHA256: String?
        var unknownFields: [String: JSONValue] = [:]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case deviceID = "device_id"
            case appBuild = "app_build"
            case features
            case advertisedAt = "advertised_at"
            case positionSHA256 = "position_sha256"
        }

        init(deviceID: DeviceID, appBuild: String, advertisedAt: Date, positionSHA256: String?) {
            schemaVersion = 1
            self.deviceID = deviceID
            self.appBuild = appBuild
            features = [InkCapabilityStore.feature]
            self.advertisedAt = advertisedAt
            self.positionSHA256 = positionSHA256
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try fields.decode(Int.self, forKey: .schemaVersion)
            deviceID = try fields.decode(DeviceID.self, forKey: .deviceID)
            appBuild = try fields.decode(String.self, forKey: .appBuild)
            features = try fields.decode([String].self, forKey: .features)
            advertisedAt = try fields.decode(Date.self, forKey: .advertisedAt)
            positionSHA256 = try fields.decode(String?.self, forKey: .positionSHA256)
            unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
        }

        func encode(to encoder: Encoder) throws {
            var fields = encoder.container(keyedBy: CodingKeys.self)
            try fields.encode(schemaVersion, forKey: .schemaVersion)
            try fields.encode(deviceID, forKey: .deviceID)
            try fields.encode(appBuild, forKey: .appBuild)
            try fields.encode(features, forKey: .features)
            try fields.encode(advertisedAt, forKey: .advertisedAt)
            try fields.encode(positionSHA256, forKey: .positionSHA256)
            try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
        }
    }
}
