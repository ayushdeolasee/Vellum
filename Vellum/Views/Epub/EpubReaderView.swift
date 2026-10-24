#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Scrolled, chapter-at-a-time EPUB reader. Book XHTML is served from the
/// open archive through `EpubResourceSchemeHandler`; book scripts and network
/// loads are disabled, and the reading location (spine index + progression)
/// is reported to `AppStore.setEpubLocation`.
struct EpubReaderView: View {
    let tabId: String
    let document: DocumentInfo

    @Environment(AppStore.self) private var appStore
    @State private var location: EpubReaderLocation?

    private var session: EpubDocumentSession? {
        appStore.sessions.documentSession(sessionId: tabId) as? EpubDocumentSession
    }

    var body: some View {
        if let session {
            VStack(spacing: 0) {
                if let location {
                    EpubReaderBar(
                        publication: session.publication, chapter: location.chapter,
                        go: { go(to: $0, fragment: $1) })
                    Divider()
                    EpubWebView(
                        session: session, location: location,
                        onProgress: { progression in
                            appStore.setEpubLocation(
                                tabId: tabId, chapter: location.chapter + 1, progression: progression)
                        },
                        onNavigate: { go(to: $0, fragment: $1) })
                } else {
                    Color.clear
                }
            }
            .background(Color.white)
            .task(id: tabId) { await restore(session) }
            .accessibilityIdentifier("epub.reader")
        } else {
            EpubPendingReaderView(document: document)
        }
    }

    private func restore(_ session: EpubDocumentSession) async {
        guard location == nil else { return }
        let tab = appStore.tabs.first { $0.id == tabId }
        let chapter = min(max(0, (tab?.currentPage ?? 1) - 1), session.publication.spine.count - 1)
        let progression = await appStore.epubResumeProgression(tabId: tabId)
        location = EpubReaderLocation(chapter: chapter, progression: progression ?? 0)
    }

    private func go(to chapter: Int, fragment: String?) {
        guard let session, session.publication.spine.indices.contains(chapter) else { return }
        location = EpubReaderLocation(chapter: chapter, progression: 0, fragment: fragment)
        appStore.setEpubLocation(tabId: tabId, chapter: chapter + 1, progression: 0)
    }
}

struct EpubReaderLocation: Equatable {
    var chapter: Int
    var progression: Double
    var fragment: String?
    /// Distinguishes repeated requests for the same place.
    var request = UUID()
}

private struct EpubReaderBar: View {
    let publication: EpubPublication
    let chapter: Int
    let go: (Int, String?) -> Void

    private var chapterTitle: String {
        let path = publication.spine[chapter].path
        return Self.title(for: path, in: publication.toc) ?? "Chapter \(chapter + 1)"
    }

    private static func title(for path: String, in entries: [EpubPublication.TocEntry]) -> String? {
        for entry in entries {
            if entry.path == path { return entry.title }
            if let nested = title(for: path, in: entry.children) { return nested }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if publication.toc.isEmpty {
                    ForEach(publication.spine.indices, id: \.self) { index in
                        Button("Chapter \(index + 1)") { go(index, nil) }
                    }
                } else {
                    tocItems(publication.toc)
                }
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("epub.contents")

            Spacer()
            Text(chapterTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(chapter + 1) of \(publication.spine.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()

            Button { go(chapter - 1, nil) } label: { Image(systemName: "chevron.left") }
                .disabled(chapter == 0)
                .keyboardShortcut("[", modifiers: .command)
                .help("Previous chapter")
                .accessibilityIdentifier("epub.previousChapter")
            Button { go(chapter + 1, nil) } label: { Image(systemName: "chevron.right") }
                .disabled(chapter >= publication.spine.count - 1)
                .keyboardShortcut("]", modifiers: .command)
                .help("Next chapter")
                .accessibilityIdentifier("epub.nextChapter")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func tocItems(_ entries: [EpubPublication.TocEntry]) -> AnyView {
        AnyView(ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            let target = entry.path.flatMap { publication.spineIndex(path: $0) }
            if entry.children.isEmpty {
                Button(entry.title) { if let target { go(target, entry.fragment) } }
                    .disabled(target == nil)
            } else {
                Menu(entry.title) {
                    if let target {
                        Button(entry.title) { go(target, entry.fragment) }
                        Divider()
                    }
                    tocItems(entry.children)
                }
            }
        })
    }
}

private struct EpubWebView: NSViewRepresentable {
    let session: EpubDocumentSession
    let location: EpubReaderLocation
    let onProgress: (Double) -> Void
    let onNavigate: (Int, String?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> EpubChapterWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: EpubResourceSchemeHandler.scheme)
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let controller = configuration.userContentController
        controller.addUserScript(WKUserScript(
            source: Self.readerScript, injectionTime: .atDocumentEnd,
            forMainFrameOnly: true, in: .defaultClient))
        controller.add(context.coordinator, contentWorld: .defaultClient, name: "epubReader")
        let webView = EpubChapterWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setAccessibilityIdentifier("epub.content")
        return webView
    }

    func updateNSView(_ webView: EpubChapterWebView, context: Context) {
        context.coordinator.parent = self
        webView.onChapterStep = { step in
            let chapter = location.chapter + step
            guard session.publication.spine.indices.contains(chapter) else { return }
            onNavigate(chapter, nil)
        }
        context.coordinator.show(location, in: webView)
    }

    static func dismantleNSView(_ webView: EpubChapterWebView, coordinator: Coordinator) {
        webView.removeKeyMonitor()
        webView.onChapterStep = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.stopLoading()
        coordinator.resources.cancelAll()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let resources: EpubResourceSchemeHandler
        var parent: EpubWebView?
        private var shown: UUID?
        private var pending: EpubReaderLocation?

        init(session: EpubDocumentSession) {
            resources = EpubResourceSchemeHandler(session: session)
        }

        private var publication: EpubPublication { resources.session.publication }

        func show(_ location: EpubReaderLocation, in webView: WKWebView) {
            guard shown != location.request else { return }
            shown = location.request
            pending = location
            let url = EpubResourceSchemeHandler.url(for: publication.spine[location.chapter].path)
            if webView.url?.path == url.path, webView.isLoading == false {
                applyPending(in: webView)
            } else {
                webView.load(URLRequest(url: url))
            }
        }

        private func applyPending(in webView: WKWebView) {
            guard let pending else { return }
            self.pending = nil
            let script: String
            if let fragment = pending.fragment,
               let data = try? JSONEncoder().encode(fragment), let literal = String(data: data, encoding: .utf8) {
                script = "window.__vellumEpubReveal(\(literal))"
            } else {
                script = "window.__vellumEpubRestore(\(min(1, max(0, pending.progression))))"
            }
            webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            applyPending(in: webView)
        }

        func webView(
            _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == EpubResourceSchemeHandler.scheme {
                guard action.navigationType == .linkActivated, action.targetFrame?.isMainFrame != false else {
                    return decisionHandler(.allow)
                }
                decisionHandler(.cancel)
                let path = EpubResourceSchemeHandler.archivePath(for: url)
                if let chapter = path.flatMap({ publication.spineIndex(path: $0) }) {
                    parent?.onNavigate(chapter, url.fragment)
                }
                return
            }
            decisionHandler(.cancel)
            if action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                NSWorkspace.shared.open(url)
            }
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], body["type"] as? String == "progress",
                  let value = body["value"] as? Double, value.isFinite else { return }
            parent?.onProgress(min(1, max(0, value)))
        }
    }

    private static let readerScript = """
    (() => {
      const style = document.createElement('style');
      style.textContent = `
        :root { color-scheme: light; }
        html { -webkit-text-size-adjust: 100%; background: #fff; }
        body { max-width: 40em; margin: 0 auto !important; padding: 2.5em 2em 5em !important;
               font-size: 18px; line-height: 1.6; color: #1d1d1f; }
        img, svg, video { max-width: 100%; height: auto; }
        pre { white-space: pre-wrap; }`;
      (document.head || document.documentElement).appendChild(style);
      const scrollable = () => Math.max(0, document.documentElement.scrollHeight - window.innerHeight);
      let timer = null;
      const report = () => {
        const height = scrollable();
        window.webkit.messageHandlers.epubReader.postMessage({
          type: 'progress', value: height > 0 ? Math.min(1, window.scrollY / height) : 0 });
      };
      window.addEventListener('scroll', () => { clearTimeout(timer); timer = setTimeout(report, 300); },
                              { passive: true });
      window.__vellumEpubRestore = (fraction) => { window.scrollTo(0, scrollable() * fraction); };
      window.__vellumEpubReveal = (id) => {
        const target = document.getElementById(id) || document.getElementsByName(id)[0];
        if (target) { target.scrollIntoView(); } else { window.scrollTo(0, 0); }
        report();
      };
    })();
    """
}

final class EpubChapterWebView: WKWebView {
    var onChapterStep: ((Int) -> Void)?
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        guard window != nil else { return }
        // Intercept before WebKit's content responder handles history navigation.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleChapterShortcut(event) == true ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func handleChapterShortcut(_ event: NSEvent) -> Bool {
        if let window, event.window === window, window.attachedSheet == nil,
           let responder = window.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let onChapterStep {
            switch event.charactersIgnoringModifiers {
            case "[": onChapterStep(-1); return true
            case "]": onChapterStep(1); return true
            default: break
            }
        }
        return false
    }
}

/// Serves archive resources of one open book under
/// `vellum-epub://book/<archive path>`, with a CSP that keeps book content
/// off the network and script-free.
@MainActor
final class EpubResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "vellum-epub"
    nonisolated static let host = "book"
    nonisolated static let contentSecurityPolicy =
        "default-src 'none'; img-src vellum-epub: data:; media-src vellum-epub:; "
        + "font-src vellum-epub: data:; style-src vellum-epub: 'unsafe-inline'; script-src 'none'"

    let session: EpubDocumentSession
    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(session: EpubDocumentSession) {
        self.session = session
    }

    nonisolated static func url(for path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path
        return components.url ?? URL(string: "\(scheme)://\(host)/")!
    }

    nonisolated static func archivePath(for url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let path = String(url.path.drop { $0 == "/" })
        return path.isEmpty ? nil : path
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url, let path = Self.archivePath(for: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let mediaType = session.publication.manifestItem(path: path)?.mediaType
            ?? UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        active[id] = Task { [weak self, session] in
            let result: Result<Data, Error>
            do {
                result = .success(try await session.resourceData(at: path))
            } catch {
                result = .failure(error)
            }
            guard let self, self.active.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
            switch result {
            case .success(let data):
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mediaType,
                        "Content-Length": "\(data.count)",
                        "Content-Security-Policy": Self.contentSecurityPolicy,
                    ])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            case .failure:
                task.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        active.removeValue(forKey: ObjectIdentifier(task))?.cancel()
    }

    func cancelAll() {
        active.values.forEach { $0.cancel() }
        active.removeAll()
    }
}
#endif
