#if os(iOS)
import UIKit

/// Which shell this process is running: the one oracle.
///
/// `TARGETED_DEVICE_FAMILY` is `1,2`, so one binary serves an iPad split-screen
/// reader and an iPhone single-pane reader (#150). Three separate decisions turn
/// on that difference — which shell `RootShell_iOS` renders, how much memory the
/// residency policy is allowed to hold (`TabResidencyBudget`), and whether the
/// workspace may split (`PaneLayoutCapability`) — and they must never disagree.
/// A workspace that thinks it can split while the shell has nowhere to draw the
/// second pane is not a cosmetic bug; it strands tabs and leaks residency pins.
/// So the device is read HERE, once, and the other three sites ask this type.
///
/// The test is the IDIOM, deliberately not the horizontal size class:
///
///   * A phone is a phone in both orientations. Gating on `.compact` width
///     instead would hand the Max/Plus bodies — which report REGULAR width in
///     landscape — the iPad shell, so the same device would be a phone reader
///     held one way and a two-pane iPad reader held the other. Worse, the two
///     branches are different view types, so every rotation would change the
///     subtree's structural identity and SwiftUI would destroy and rebuild the
///     whole shell: pane focus, presented sheets and scroll positions all reset
///     on a turn of the wrist.
///   * An iPad stays on the iPad shell at every width. Slide Over and a narrow
///     Split View are compact-width too, and they have always rendered
///     `ContentView_iOS`; keeping the idiom as the only input is what makes "the
///     iPad path is untouched" true by construction rather than by argument.
///
/// The idiom cannot change for the life of the process, which is what lets
/// `current` be a cached `let` and lets `WorkspaceStore.layout` be immutable.
enum ShellIdiom_iOS: String, Sendable, CaseIterable {
    case phone
    case pad

    /// The idiom this process is running as. Resolved once, on first use.
    @MainActor static let current: ShellIdiom_iOS = resolve(
        environment: ProcessInfo.processInfo.environment,
        deviceIdiom: UIDevice.current.userInterfaceIdiom)

    /// The resolution rule, as a pure function of its two inputs so both
    /// branches are testable without two devices.
    ///
    /// Everything that is not a phone is `pad`: Mac Catalyst and Vision are not
    /// built here, and an unknown future idiom getting the roomier shell is the
    /// safer of the two wrong answers.
    static func resolve(
        environment: [String: String],
        deviceIdiom: UIUserInterfaceIdiom
    ) -> ShellIdiom_iOS {
        #if DEBUG
        // The sanctioned `VELLUM_*` launch-environment pattern (alongside
        // `VELLUM_AUTOOPEN_PDF` and friends): it lets a QA run drive the phone
        // shell on an iPad simulator, and lets the unit suites exercise the
        // branch the host device is not. DEBUG-only, so no shipped build can be
        // talked out of its real idiom.
        if let forced = environment["VELLUM_FORCE_SHELL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let override = ShellIdiom_iOS(rawValue: forced) {
            return override
        }
        #endif
        return deviceIdiom == .phone ? .phone : .pad
    }

    /// Whether the workspace this idiom builds may hold more than one pane.
    var paneLayout: PaneLayoutCapability {
        switch self {
        case .phone: .singlePane
        case .pad: .splitScreen
        }
    }

    /// The device noun for user-facing copy.
    ///
    /// One binary serves both families, so any sentence that names the hardware
    /// has to ask rather than assume. Before #153 several did assume — the
    /// first-run hero promised "AI-powered reading for iPad" and the storage
    /// sheet offered to "Keep on This iPad" — which on an iPhone is the very
    /// first sentence the app says being wrong about the device it is running on.
    ///
    /// Not localized, and deliberately so: these are Apple's product names, which
    /// are not translated in any locale.
    var deviceName: String {
        switch self {
        case .phone: "iPhone"
        case .pad: "iPad"
        }
    }

    /// "this iPhone" / "this iPad" — the form storage copy uses when it is
    /// distinguishing local storage from iCloud.
    var thisDevice: String { "this \(deviceName)" }

    /// How much native tab state this idiom's residency policy may hold.
    var residencyBudget: TabResidencyBudget {
        switch self {
        case .phone: .phone
        case .pad: .pad
        }
    }
}
#endif
