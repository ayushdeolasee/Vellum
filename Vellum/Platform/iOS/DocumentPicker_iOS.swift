#if os(iOS)
import UIKit
import UniformTypeIdentifiers

/// Presents the system document picker directly from UIKit instead of through
/// SwiftUI's `.fileImporter`.
///
/// `.fileImporter` lazily spins up the entire document-picker subsystem (the XPC
/// connection to the document-manager service and file-provider discovery across
/// iCloud/Files/third-party providers) synchronously, at the moment it's
/// presented — which is why the first "Open a PDF" tap stalls for seconds. This
/// coordinator (a) presents a plain `UIDocumentPickerViewController` imperatively
/// and (b) exposes `prewarm()` so that expensive first-time setup can run shortly
/// after launch, off the user's tap.
@MainActor
final class DocumentPickerCoordinator_iOS: NSObject, UIDocumentPickerDelegate {
    static let shared = DocumentPickerCoordinator_iOS()

    /// Retained so the delegate lives for the duration of the presentation.
    private var onPick: (([URL]) -> Void)?
    private var didPrewarm = false

    /// Warm up the document-picker machinery ahead of the user's first tap.
    /// Instantiating a picker establishes the service connection and kicks off
    /// file-provider discovery, so the real present is snappy. Idempotent.
    func prewarm() {
        guard !didPrewarm else { return }
        didPrewarm = true
        _ = UIDocumentPickerViewController(
            forOpeningContentTypes: DocumentImport.openableTypes, asCopy: false)
    }

    /// Present the picker over the frontmost view controller. `onPick` receives
    /// the chosen (security-scoped) URLs; it isn't called on cancel.
    func present(onPick: @escaping ([URL]) -> Void) {
        self.onPick = onPick
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: DocumentImport.openableTypes, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        guard let presenter = Self.topViewController() else {
            self.onPick = nil
            return
        }
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        let handler = onPick
        onPick = nil
        handler?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        onPick = nil
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
            ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#endif
