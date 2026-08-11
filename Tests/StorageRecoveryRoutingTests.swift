#if os(iOS)
import SwiftUI
import Testing

@testable import Vellum

@Suite("Storage recovery routing and copy")
struct StorageRecoveryRoutingTests {
    @Test("Phone and compact iPad route recovery rows into sheets")
    func compactRoutingPredicate() {
        #expect(StorageCompactRouting.usesRecoverySheets(
            idiom: .phone, horizontalSizeClass: .regular))
        #expect(StorageCompactRouting.usesRecoverySheets(
            idiom: .pad, horizontalSizeClass: .compact))
        #expect(StorageCompactRouting.usesRecoverySheets(
            idiom: .pad, horizontalSizeClass: .regular) == false)
    }

    @Test("iCloud copy promises only data that currently syncs")
    func truthfulICloudCopy() {
        let healthy = StorageLocationCopy.choiceDescription(
            for: .icloud,
            iCloudAvailable: true,
            deviceName: "iPhone")
        let degraded = StorageLocationCopy.settingsFooter(
            for: .icloud,
            isDegraded: true,
            deviceName: "iPhone")
        let custom = StorageLocationCopy.choiceDescription(
            for: .custom,
            iCloudAvailable: true,
            deviceName: "iPhone")

        #expect(healthy.contains("highlights"))
        #expect(healthy.contains("AI conversations"))
        #expect(healthy.contains("reading positions"))
        #expect(healthy.contains("Scratchpad notes and images"))
        #expect(healthy.contains("notes — lives in iCloud") == false)
        #expect(degraded.contains("private local storage"))
        #expect(degraded.contains("nothing is syncing"))
        #expect(degraded.contains("iPad") == false)
        #expect(custom.contains("Offline copies live in the folder"))
        #expect(custom.contains("Highlights, AI conversations, reading positions"))
        #expect(custom.contains("private storage on this iPhone"))
        #expect(custom.contains("sync across") == false)
    }
}
#endif
