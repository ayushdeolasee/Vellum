import AppKit
import UniformTypeIdentifiers

/// A URL-only system Share adapter. Successful delivery is not a persistence
/// acknowledgement: the app saves the link before adopting its reader tab.
@MainActor
final class ShareViewController: NSViewController {
    private let statusLabel = NSTextField(wrappingLabelWithString: "Sending link to Vellum…")
    private let urlLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let copyButton = NSButton(title: "Copy Link", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var deliveryTask: Task<Void, Never>?
    private var webpage: URL?
    private var didStartDelivery = false

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 220))
        preferredContentSize = view.frame.size
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        urlLabel.isSelectable = true
        let detail = NSTextField(wrappingLabelWithString:
            "Vellum saves the link to your Library. An offline copy is created after the page loads successfully.")
        retryButton.target = self
        retryButton.action = #selector(retry)
        copyButton.target = self
        copyButton.action = #selector(copyLink)
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        retryButton.isHidden = true
        copyButton.isHidden = true
        let buttons = NSStackView(views: [cancelButton, copyButton, retryButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [statusLabel, urlLabel, detail, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 24),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -24),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        guard !didStartDelivery else { return }
        didStartDelivery = true
        deliver()
    }

    deinit {
        deliveryTask?.cancel()
    }

    @objc private func retry() {
        guard deliveryTask == nil else { return }
        deliver()
    }

    @objc private func copyLink() {
        guard let webpage else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(webpage.absoluteString, forType: .string)
    }

    @objc private func cancel() {
        deliveryTask?.cancel()
        extensionContext?.cancelRequest(withError: CancellationError())
    }

    private func deliver() {
        statusLabel.stringValue = "Sending link to Vellum…"
        retryButton.isHidden = true
        copyButton.isHidden = true
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { deliveryTask = nil }
            do {
                let page: URL
                if let webpage {
                    page = webpage
                } else {
                    page = try await Self.loadWebpage(from: extensionContext?.inputItems ?? [])
                }
                webpage = page
                urlLabel.stringValue = page.absoluteString
                guard let route = VellumExternalWebLink.url(for: page, saveToLibrary: true) else {
                    throw ShareError.unsupportedURL
                }
                try Task.checkCancellation()
                // NSWorkspace is the public macOS URL-delivery API. Do not use
                // NSExtensionContext.open (Today-only) or responder-chain tricks.
                try await Self.send(route)
                try Task.checkCancellation()
                extensionContext?.completeRequest(returningItems: [])
            } catch is CancellationError {
                // The Cancel action already dismisses the request.
            } catch {
                statusLabel.stringValue = webpage == nil
                    ? error.localizedDescription
                    : "Couldn’t send this link to Vellum. Open Vellum and retry, or copy the link and use Add Webpage.\n\(error.localizedDescription)"
                retryButton.isHidden = false
                copyButton.isHidden = webpage == nil
            }
        }
    }

    private static func send(_ route: URL) async throws {
        // Mac extensions are embedded at App.app/Contents/PlugIns/Extension.appex.
        // Target that app explicitly so another URL handler cannot receive the link.
        let containingApp = Bundle.main.bundleURL.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        guard containingApp.pathExtension == "app" else { throw ShareError.deliveryFailed }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([route], withApplicationAt: containingApp,
                                    configuration: NSWorkspace.OpenConfiguration()) { application, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if application != nil {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: ShareError.deliveryFailed)
                }
            }
        }
    }

    private static func loadWebpage(from items: [Any]) async throws -> URL {
        let providers = items.compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }
        for type in [UTType.propertyList.identifier, UTType.url.identifier] {
            for provider in providers where provider.hasItemConformingToTypeIdentifier(type) {
                try Task.checkCancellation()
                guard let item = try? await provider.loadItem(forTypeIdentifier: type) else { continue }
                let candidate: URL?
                if type == UTType.propertyList.identifier {
                    let dictionary: [String: Any]?
                    if let data = item as? Data {
                        dictionary = (try? PropertyListSerialization.propertyList(
                            from: data, options: [], format: nil)) as? [String: Any]
                    } else {
                        dictionary = item as? [String: Any]
                    }
                    let results = dictionary?[NSExtensionJavaScriptPreprocessingResultsKey] as? [String: Any]
                    candidate = (results?["url"] as? String).flatMap(URL.init(string:))
                } else if let url = item as? URL {
                    candidate = url
                } else if let data = item as? Data {
                    candidate = String(data: data, encoding: .utf8).flatMap(URL.init(string:))
                } else {
                    candidate = (item as? String).flatMap(URL.init(string:))
                }
                if let candidate, VellumExternalWebLink.url(for: candidate, saveToLibrary: true) != nil {
                    return candidate
                }
            }
        }
        throw ShareError.unsupportedURL
    }
}

private enum ShareError: LocalizedError {
    case unsupportedURL
    case deliveryFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedURL:
            "Share an HTTP or HTTPS webpage from Safari or another app. Files and internal browser pages aren’t supported."
        case .deliveryFailed:
            "Couldn’t send this link to Vellum. Open Vellum and retry, or copy the link and use Add Webpage in Vellum."
        }
    }
}
