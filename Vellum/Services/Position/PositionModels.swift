import Foundation
import VellumCore

typealias DocumentKey = VellumCore.DocumentKey
typealias ReadingPosition = VellumCore.ReadingPosition
typealias DeviceID = VellumCore.DeviceID
typealias DeviceIdentity = VellumCore.DeviceIdentity
typealias DeviceIdentityStub = VellumCore.DeviceIdentityStub
typealias PositionEvent = VellumCore.PositionEvent
typealias OpenState = VellumCore.OpenState
typealias PositionDeviceRecord = VellumCore.PositionDeviceRecord
typealias PositionJSON = VellumCore.PositionJSON
typealias MergedDocumentPosition = VellumCore.MergedDocumentPosition
typealias ResumeEntry = VellumCore.ResumeEntry
typealias PositionTimestamp = VellumCore.PositionTimestamp
typealias PositionCoding = VellumCore.PositionCoding
typealias PositionMerge = VellumCore.PositionMerge
typealias Stamped = VellumCore.Stamped
typealias MergedField = VellumCore.MergedField

extension DeviceIdentity {
    /// `UIDevice.current.name`/`.userInterfaceIdiom` are main-actor isolated and
    /// this is callable from any isolation, so the app layer installs what it
    /// sees rather than this reaching for UIKit.
    nonisolated(unsafe) static var nameOverride: String?
    nonisolated(unsafe) static var platformOverride: String?

    /// Mints and persists a per-install id in AppDefaults. Non-blocking: this
    /// is evaluated as `PositionStore.init`'s default argument, which is a main
    /// thread in practice.
    static func current() -> DeviceIdentity {
        let defaults = AppleDeviceIDDefaults(defaults: AppDefaults.current)
        let platform = platformOverride ?? defaultPlatform
        return DeviceIdentityProvider(
            defaults: defaults, name: nameOverride ?? defaultName(for: platform), platform: platform
        ).current()
    }

    private static var defaultPlatform: String {
        #if os(macOS)
        return "macos"
        #else
        // The iOS target is universal now (TARGETED_DEVICE_FAMILY 1,2) but the
        // runtime idiom check is main-actor isolated and this is callable from
        // any isolation, so the compile-time answer stays "ipados" and the app
        // layer narrows it to "ios" on a phone through `platformOverride` when
        // phone sync identity lands. Nothing reads this as a capability flag —
        // it is a label on synced position records — so an iPhone reporting
        // "ipados" until then is cosmetic, not a correctness bug.
        return "ipados"
        #endif
    }

    /// A constant, deliberately: `ProcessInfo.processInfo.hostName` is
    /// documented as potentially performing a synchronous name resolution, so
    /// on a network with slow or absent reverse DNS it blocks whichever thread
    /// asks — here, the main thread at startup. It also answers with a hostname
    /// rather than the display name this field is contracted to carry
    /// ("Ayush's iPhone"), and that hostname would be baked into every synced
    /// record for peers to show. The app layer installs the real name into
    /// `nameOverride` from `UIDevice.current.name`, which is main-actor
    /// isolated and therefore cannot be read from here.
    private static func defaultName(for platform: String) -> String {
        switch platform {
        case "macos": return "Mac"
        case "ios": return "iPhone"
        default: return "iPad"
        }
    }
}

private struct AppleDeviceIDDefaults: DeviceIDDefaults, @unchecked Sendable {
    let defaults: UserDefaults
    private static let lock = NSLock()

    func loadOrCreateID(forKey key: String) -> String {
        Self.lock.withLock {
            if let id = defaults.string(forKey: key), !id.isEmpty { return id }
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: key)
            return id
        }
    }
}
