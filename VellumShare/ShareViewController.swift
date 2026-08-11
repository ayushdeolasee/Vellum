import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let statusLabel = UILabel()
    private var captureTask: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.text = "Saving to Vellum…"
        statusLabel.textAlignment = .center
        statusLabel.font = .preferredFont(forTextStyle: .headline)
        statusLabel.numberOfLines = 0
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard captureTask == nil else { return }
        captureTask = Task { [weak self] in
            await self?.capture()
        }
    }

    deinit {
        captureTask?.cancel()
    }

    private func capture() async {
        do {
            let input = try await ShareInput.load(from: extensionContext?.inputItems ?? [])
            guard let layout = CaptureInboxLayout.resolve() else {
                throw ShareCaptureError.appGroupUnavailable
            }
            let record = CaptureRecordBuilder.make(
                sourceURL: input.url.absoluteString,
                title: input.title,
                outerHTML: input.outerHTML,
                reportedHTMLByteCount: input.htmlByteCount,
                maxHTMLBytes: CaptureDOMPolicy.maximumByteCount,
                now: .now)
            try CaptureInboxWriter(layout: layout).write(record)
            CaptureWakeup.start(for: input.url)
            extensionContext?.completeRequest(returningItems: [])
        } catch is CancellationError {
            extensionContext?.cancelRequest(withError: CancellationError())
        } catch {
            statusLabel.text = "Couldn’t save this page."
            extensionContext?.cancelRequest(withError: error)
        }
    }
}

@MainActor
private struct ShareInput {
    var url: URL
    var title: String?
    var outerHTML: String?
    var htmlByteCount: Int?

    static func load(from items: [Any]) async throws -> ShareInput {
        let providers = items
            .compactMap { $0 as? NSExtensionItem }
            .flatMap { $0.attachments ?? [] }

        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
            guard let dictionary = try await provider.loadItem(
                forTypeIdentifier: UTType.propertyList.identifier) as? [String: Any],
                let results = dictionary[NSExtensionJavaScriptPreprocessingResultsKey]
                    as? [String: Any],
                let rawURL = results["url"] as? String,
                let url = URL(string: rawURL)
            else { continue }
            return ShareInput(
                url: url,
                title: results["title"] as? String,
                outerHTML: results["outerHTML"] as? String,
                htmlByteCount: results["htmlByteCount"] as? Int)
        }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let item = try await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            if let url = item as? URL {
                return ShareInput(url: url)
            }
            if let rawURL = item as? String, let url = URL(string: rawURL) {
                return ShareInput(url: url)
            }
        }
        throw ShareCaptureError.missingWebPage
    }
}

private enum CaptureWakeup {
    static func start(for url: URL) {
        let session = URLSession(configuration: CaptureBackgroundSession.configuration())
        session.downloadTask(with: url).resume()
        session.finishTasksAndInvalidate()
    }
}

private enum ShareCaptureError: LocalizedError {
    case appGroupUnavailable
    case missingWebPage

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "Vellum's shared capture container is unavailable."
        case .missingWebPage:
            return "The shared item does not contain a webpage URL."
        }
    }
}
