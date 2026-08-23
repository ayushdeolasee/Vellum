import Foundation

@testable import Vellum

/// Shared fixtures for the position-store suites. Device ids are fixed and
/// ordered (`aaaa…` < `bbbb…` < `cccc…`) so the tie-break rule can be asserted
/// against a known winner rather than whatever UUID a run happened to mint.
extension DeviceIdentity {
    static let mac = DeviceIdentity(
        id: DeviceID("aaaaaaaa-0000-4000-8000-000000000001"),
        name: "Ayush's Mac",
        platform: "macos")

    static let phone = DeviceIdentity(
        id: DeviceID("bbbbbbbb-0000-4000-8000-000000000002"),
        name: "Ayush's iPhone",
        platform: "ios")

    static let pad = DeviceIdentity(
        id: DeviceID("cccccccc-0000-4000-8000-000000000003"),
        name: "Ayush's iPad",
        platform: "ipados")
}

enum PositionFixtures {
    static let mac = DeviceIdentity.mac
    static let phone = DeviceIdentity.phone
    static let pad = DeviceIdentity.pad

    static func date(_ rfc3339: String) -> Date {
        guard let date = PositionTimestamp.parse(rfc3339) else {
            fatalError("fixture timestamp is not RFC3339: \(rfc3339)")
        }
        return date
    }

    static func webKey(_ normalizedURL: String) -> DocumentKey {
        .web(normalizedURL: normalizedURL)
    }

    static func pdfKey(_ identifier: String) -> DocumentKey {
        .pdf(stableIdentifier: identifier)
    }

    static func record(
        _ device: DeviceIdentity,
        writtenAt: Date,
        schemaVersion: Int = PositionLayout.schemaVersion,
        fileNameVersion: Int? = nil,
        documents: [DocumentKey: PositionDeviceRecord.DocumentEntry]
    ) -> PositionDeviceRecord {
        PositionDeviceRecord(
            schemaVersion: schemaVersion,
            deviceID: device.id,
            deviceName: device.name,
            devicePlatform: device.platform,
            writtenAt: writtenAt,
            documents: documents,
            fileNameVersion: fileNameVersion)
    }

    static func scratchDirectory(_ suite: String) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-\(suite)-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
