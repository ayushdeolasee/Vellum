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
final class DocumentPickerCoordinator_iOS: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
    static let shared = DocumentPickerCoordinator_iOS()

    /// Retained so the delegate lives for the duration of the presentation.
    private var onPick: (([URL]) -> Void)?
    private var didPrewarm = false
    private var exportCompletions: [ObjectIdentifier: @MainActor () async -> Void] = [:]
    private var completionTasks: [UUID: Task<Void, Never>] = [:]

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

    /// Present the folder picker (Settings ▸ Storage custom location). `onPick`
    /// receives the chosen security-scoped folder URL; not called on cancel.
    func presentFolderPicker(onPick: @escaping (URL) -> Void) {
        self.onPick = { urls in
            guard let first = urls.first else { return }
            onPick(first)
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        guard let presenter = Self.topViewController() else {
            self.onPick = nil
            return
        }
        presenter.present(picker, animated: true)
    }

    /// Present a single-selection PDF picker (Settings ▸ Storage "Relink…").
    /// Narrower than `present(onPick:)` on purpose: relinking reconnects orphaned
    /// data to exactly one file, and only a PDF can carry the embedded
    /// /VellumDocId the relink verifies against. `onPick` receives the chosen
    /// (security-scoped) URL; it isn't called on cancel.
    func presentPdfPicker(onPick: @escaping (URL) -> Void) {
        self.onPick = { urls in
            guard let first = urls.first else { return }
            onPick(first)
        }
        let picker = UIDocumentPickerViewController(
            forOpeningContentTypes: [.pdf], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = self
        guard let presenter = Self.topViewController() else {
            self.onPick = nil
            return
        }
        presenter.present(picker, animated: true)
    }

    /// The system copies the source before success. The owner may remove its
    /// temporary copy only when this picker completes, cancels, or cannot show.
    func presentExport(urls: [URL], onFinish: (@MainActor () async -> Void)? = nil) {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = self
        if let onFinish { exportCompletions[ObjectIdentifier(picker)] = onFinish }
        guard let presenter = Self.topViewController(), presenter.viewIfLoaded?.window != nil,
              !presenter.isBeingDismissed, !presenter.isBeingPresented else {
            finishExport(picker)
            return
        }
        let identity = ObjectIdentifier(picker)
        presenter.present(picker, animated: true) { [weak self, weak picker] in
            guard let self else { return }
            guard let picker, picker.presentingViewController != nil else {
                self.finishExport(identity: identity)
                return
            }
            picker.presentationController?.delegate = self
        }
        picker.presentationController?.delegate = self
    }

    private func finishExport(_ picker: UIDocumentPickerViewController) {
        finishExport(identity: ObjectIdentifier(picker))
    }

    private func finishExport(identity: ObjectIdentifier) {
        guard let completion = exportCompletions.removeValue(forKey: identity) else { return }
        let id = UUID()
        completionTasks[id] = Task { @MainActor in
            await completion()
            completionTasks[id] = nil
        }
    }

    func awaitPendingExportCompletions() async {
        while !completionTasks.isEmpty {
            for task in Array(completionTasks.values) { await task.value }
            await Task.yield()
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if exportCompletions[ObjectIdentifier(controller)] != nil {
            finishExport(controller)
            return
        }
        let handler = onPick
        onPick = nil
        handler?(urls)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        if exportCompletions[ObjectIdentifier(controller)] != nil {
            finishExport(controller)
            return
        }
        onPick = nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if let picker = presentationController.presentedViewController as? UIDocumentPickerViewController {
            finishExport(picker)
        }
    }

    /// Frontmost presenter for a UIKit modal. Internal rather than private so
    /// the `.vellum` import prompts share one definition with the pickers
    /// (`BundleImportPrompts_iOS`) instead of duplicating the scene walk.
    static func topViewController() -> UIViewController? {
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
