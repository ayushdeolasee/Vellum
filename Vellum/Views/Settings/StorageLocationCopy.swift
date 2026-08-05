#if os(iOS)
import SwiftUI

/// User-facing storage promises in one place. Per-document Scratchpad notes and
/// images follow the same coordinated class-B location as conversations.
enum StorageLocationCopy {
    static func introduction(on deviceName: String) -> String {
        "Vellum stores offline web pages, highlights, Scratchpad notes, AI conversations, and reading positions. iCloud Drive can sync those across your devices."
    }

    static func choiceDescription(
        for mode: WebStorageMode,
        iCloudAvailable: Bool,
        deviceName: String
    ) -> String {
        let thisDevice = "this \(deviceName)"
        switch mode {
        case .icloud where iCloudAvailable:
            return "Offline copies, highlights, Scratchpad notes and images, AI conversations, and reading positions live in iCloud Drive ▸ Vellum and sync across your devices."
        case .icloud:
            return "iCloud sync isn't available in this build or for this iCloud account. Choose local storage for now; Vellum will keep everything private on \(thisDevice) and won't write to iCloud."
        case .custom:
            return "Offline copies live in the folder you choose. Highlights, AI conversations, reading positions, and live scratchpad notes stay in Vellum's private storage on \(thisDevice) and don't sync."
        case .local:
            return "Everything stays in Vellum's private app folder on \(thisDevice). Nothing syncs."
        }
    }

    static func settingsFooter(
        for mode: WebStorageMode,
        isDegraded: Bool,
        deviceName: String
    ) -> String {
        let thisDevice = "this \(deviceName)"
        if isDegraded {
            switch mode {
            case .icloud:
                return "iCloud sync isn't available in this build or for this iCloud account. Vellum is using private local storage on \(thisDevice); nothing is syncing or being written to iCloud."
            case .custom:
                return "The chosen folder can't be found. Vellum is using private local storage on \(thisDevice) until you choose a folder again."
            case .local:
                return "Everything stays in Vellum's private app folder on \(thisDevice). Nothing syncs."
            }
        }
        return choiceDescription(
            for: mode,
            iCloudAvailable: true,
            deviceName: deviceName)
    }

    static func relocationConfirmation(on deviceName: String) -> String {
        "Vellum will move offline pages, highlights, Scratchpad notes and images, reading positions, and AI conversations in the background. Keep Vellum open until the move finishes. If the destination becomes unavailable, Vellum keeps using its safe local copy and resumes when that location returns."
    }
}

/// Compact-width storage management uses sheets so long recovery lists do not
/// dominate the Settings form. The rule is pure for deterministic phone/iPad
/// coverage without launching either shell.
enum StorageCompactRouting {
    static func usesRecoverySheets(
        idiom: ShellIdiom_iOS,
        horizontalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        idiom == .phone || horizontalSizeClass == .compact
    }
}
#endif
