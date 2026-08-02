#if os(iOS)
import UIKit

/// Modal prompts for the `.vellum` import flow. macOS runs these as
/// `NSAlert.runModal()` *inside* the synchronous merge-resolver
/// `VellumBundle.installSidecar` takes; iOS can't block a thread waiting on an
/// alert, so each prompt is an async `UIAlertController` bridged through a
/// checked continuation and presented over the frontmost view controller.
///
/// Presented from UIKit rather than as a SwiftUI `.alert` on purpose: an import
/// can arrive via `.onOpenURL` during a cold launch, before any view that owns
/// sheet state has appeared.
@MainActor
enum BundleImportPrompts_iOS {
    /// The local note for this document differs from the imported one. Returns
    /// the user's choice; `.keepLocal` is the safe default and the swipe-away
    /// outcome (it is the `.cancel` action), matching the Mac's default button.
    static func scratchpadConflict(title: String) async -> VellumBundle.ScratchpadDecision {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Notes already exist for \(title)",
                message: "This document already has notes on this iPad. Keep the notes you have, "
                    + "or replace them with the imported notes? Your highlights and reading "
                    + "position are not affected either way.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep My Notes", style: .cancel) { _ in
                continuation.resume(returning: .keepLocal)
            })
            alert.addAction(UIAlertAction(title: "Use Imported Notes", style: .destructive) { _ in
                continuation.resume(returning: .useImported)
            })
            alert.view.accessibilityIdentifier = "import.scratchpadConflict"
            guard let presenter = DocumentPickerCoordinator_iOS.topViewController() else {
                // Fail safe: losing the user's own notes because no presenter
                // was available would be unrecoverable.
                return continuation.resume(returning: .keepLocal)
            }
            presenter.present(alert, animated: true)
        }
    }

    /// Some of the bundle's images could not be installed. Never a silent
    /// success with broken image refs — name them.
    static func failedAttachments(_ names: [String]) async {
        guard !names.isEmpty else { return }
        await acknowledge(
            title: "Some images couldn't be imported",
            message: "These images from the bundle could not be saved, so the notes that "
                + "reference them will show a broken image:\n\n" + names.joined(separator: "\n"),
            identifier: "import.failedAttachments")
    }

    /// The bundle was rejected (integrity check, unsafe entry path, version too
    /// new…). Silent rejection reads as a broken app, which is the whole point
    /// of surfacing the codec's error text.
    static func importFailed(_ message: String) async {
        await acknowledge(
            title: "Couldn't open this Vellum bundle",
            message: message,
            identifier: "import.failed")
    }

    /// Single-OK alert, awaited until dismissed.
    private static func acknowledge(
        title: String, message: String, identifier: String
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(
                title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                continuation.resume()
            })
            alert.view.accessibilityIdentifier = identifier
            guard let presenter = DocumentPickerCoordinator_iOS.topViewController() else {
                return continuation.resume()
            }
            presenter.present(alert, animated: true)
        }
    }
}
#endif
