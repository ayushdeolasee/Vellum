import Foundation
import Testing

@testable import Vellum

@Suite("Position store — Apple composition", .serialized, .isolatedStorage)
struct PositionWireFormatTests {
    /// `device_name` is display text that every peer shows in an "open
    /// elsewhere" affordance, and it is baked into every record this device
    /// writes. It used to default to `ProcessInfo.processInfo.hostName`, which
    /// answers with a hostname rather than a display name and which Apple
    /// documents as potentially performing a synchronous name resolution — on
    /// the main thread, since this is `PositionStore.init`'s default argument.
    @Test("The default device name is display text, resolved without a name lookup")
    func defaultDeviceNameIsDisplayText() {
        let previousName = DeviceIdentity.nameOverride
        let previousPlatform = DeviceIdentity.platformOverride
        DeviceIdentity.nameOverride = nil
        defer {
            DeviceIdentity.nameOverride = previousName
            DeviceIdentity.platformOverride = previousPlatform
        }

        DeviceIdentity.platformOverride = "ios"
        #expect(DeviceIdentity.current().name == "iPhone")
        DeviceIdentity.platformOverride = "macos"
        #expect(DeviceIdentity.current().name == "Mac")
        DeviceIdentity.platformOverride = "ipados"
        #expect(DeviceIdentity.current().name == "iPad")

        // The app layer's installed name still wins — that is the only path
        // that can reach `UIDevice.current.name`, which is main-actor isolated.
        DeviceIdentity.nameOverride = "Ayush's iPhone"
        #expect(DeviceIdentity.current().name == "Ayush's iPhone")
    }

    @Test("Concurrent callers use one ID within the task's defaults suite")
    func scopedDeviceID() async throws {
        let suite = "vellum.tests.position-id.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        await AppDefaults.withDefaults(defaults) {
            let ids = await withTaskGroup(of: DeviceID.self, returning: Set<DeviceID>.self) { group in
                for _ in 0..<8 { group.addTask { DeviceIdentity.current().id } }
                var ids = Set<DeviceID>()
                for await id in group { ids.insert(id) }
                return ids
            }
            #expect(ids.count == 1)
            #expect(ids.first?.rawValue == defaults.string(forKey: "vellum.device-id"))
            // Preserve IDs written by older builds and re-read the current suite.
            defaults.set("existing-device", forKey: "vellum.device-id")
            #expect(DeviceIdentity.current().id == DeviceID("existing-device"))
        }
    }

    @Test("The sidecar and position store read each other's timestamps")
    func timestampsMatchTheSidecarShape() {
        let written = "2026-08-02T18:40:11.014000+00:00"
        let date = PositionFixtures.date(written)
        #expect(PositionTimestamp.string(from: date) == written)
        #expect(WebLibrary.parseRfc3339(written) == date)
        #expect(WebLibrary.parseRfc3339(WebLibrary.rfc3339Now()) != nil)
        #expect(PositionTimestamp.parse(WebLibrary.rfc3339Now()) != nil)
    }
}
