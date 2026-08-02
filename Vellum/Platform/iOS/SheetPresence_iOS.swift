#if os(iOS)
import UIKit

/// Whether the app is currently showing a modal on top of the document UI —
/// asked of UIKit, not inferred from SwiftUI's presentation flags.
///
/// The macOS twin of this file (`App/SheetPresenceMonitor.swift`) is
/// deliberately NOT ported — it gates `.focusedSceneValue` so a disabled menu
/// item declines its key equivalent (issue #98: ⌘W pressed to dismiss a sheet
/// closed the tab underneath). iPadOS has no menu validation to lean on:
/// `VellumCommands_iOS` is rebuilt only when SwiftUI re-evaluates `Commands`,
/// which is exactly why `VellumShortcutRouter` re-checks every precondition at
/// invocation time. So this is a live query, consulted there.
///
/// WHY UIKIT RATHER THAN A SET OF `isPresented` FLAGS — same two reasons as
/// macOS. A flag records what the app ASKED for, not what is on screen, and
/// Vellum does not present all of its own modals: `UIDocumentPickerViewController`
/// (`DocumentPickerCoordinator_iOS`), the share sheet and
/// `UIPrintInteractionController` are all presented by frameworks.
/// `presentedViewController` covers every one of them and cannot describe a
/// modal that is not there.
@MainActor
enum SheetPresence_iOS {
    /// True while any view controller is presented modally over the app's
    /// foreground-active scene.
    static var isPresenting: Bool { topPresented != nil }

    /// The frontmost presented controller, or nil. Also the dismissal target
    /// for Escape — see `VellumShortcutRouter`'s gate.
    static var topPresented: UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              let root = scene.keyWindow?.rootViewController
        else { return nil }
        var presented = root.presentedViewController
        while let next = presented?.presentedViewController { presented = next }
        return presented
    }
}
#endif
