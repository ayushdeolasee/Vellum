#if os(macOS)
import AppKit
import SwiftUI
import WebKit

struct EpubReaderSurface: NSViewRepresentable {
    let reader: EpubReaderController
    let session: EpubDocumentSession
    let location: EpubReaderLocation
    let annotations: [Annotation]
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    func makeNSView(context: Context) -> EpubChapterWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: EpubResourceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(WKUserScript(source: EpubReaderJavaScript.source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "epubReader")
        let view = EpubChapterWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setAccessibilityIdentifier("epub.content")
        reader.webView = view
        let resources = context.coordinator.resources
        reader.drainResources = { await resources.drain() }
        return view
    }

    func updateNSView(_ view: EpubChapterWebView, context: Context) {
        context.coordinator.parent = self
        view.readerActive = reader.isCurrent
        view.onChapterStep = { step in
            guard reader.isCurrent else { return }
            reader.go(chapter: location.chapter + step)
        }
        context.coordinator.show(in: view)
    }

    static func dismantleNSView(_ view: EpubChapterWebView, coordinator: Coordinator) {
        view.readerActive = false; view.removeKeyMonitor(); view.onChapterStep = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.navigationDelegate = nil; view.stopLoading()
        coordinator.resources.cancelAll()
        coordinator.parent?.reader.deactivate()
        coordinator.parent = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let resources: EpubResourceSchemeHandler
        var parent: EpubReaderSurface?
        private var shown: UUID?
        private var pending = false
        private var configurationJSON = ""
        private var annotationJSON = ""
        init(session: EpubDocumentSession) { resources = EpubResourceSchemeHandler(session: session) }

        func show(in view: WKWebView) {
            guard let parent else { return }
            let location = parent.location
            if shown != location.request {
                shown = location.request; pending = true
                configurationJSON = ""; annotationJSON = ""
                let url = EpubResourceSchemeHandler.url(for: resources.session.publication.spine[location.chapter].path)
                if view.url?.path != url.path || view.isLoading {
                    view.stopLoading(); view.load(URLRequest(url: url)); return
                }
            }
            if !view.isLoading { synchronize(view) }
        }

        private struct Configuration: Encodable {
            let token: String; let href: String; let active: Bool
            let settings: EpubReaderSettings; let dark: Bool
        }
        private struct Passage: Encodable { let anchor: EpubTextAnchor?; let progression: Double; let fragment: String? }
        private struct Mark: Encodable { let id: String; let anchor: EpubTextAnchor; let color: String? }

        private func synchronize(_ view: WKWebView) {
            guard let parent, shown == parent.location.request,
                  EpubResourceSchemeHandler.archivePath(for: view.url ?? URL(fileURLWithPath: "/")) == href else { return }
            let config = EpubReaderJavaScript.literal(Configuration(token: parent.location.request.uuidString, href: href,
                active: parent.reader.isCurrent, settings: parent.reader.settings, dark: parent.dark))
            var script = ""
            if config != configurationJSON { configurationJSON = config; script += "window.__vellumEpub?.configure(\(config));" }
            let marks = parent.annotations.filter { $0.pageNumber == parent.location.chapter + 1 }
                .prefix(500).compactMap { annotation -> Mark? in
                    guard let anchor = annotation.positionData?.epubAnchor else { return nil }
                    return Mark(id: annotation.id, anchor: anchor, color: annotation.color)
                }
            let encodedMarks = EpubReaderJavaScript.literal(marks)
            if encodedMarks != annotationJSON { annotationJSON = encodedMarks; script += "window.__vellumEpub?.annotations(\(encodedMarks));" }
            if pending {
                pending = false
                let passage = Passage(anchor: parent.location.anchor, progression: parent.location.progression, fragment: parent.location.fragment)
                script += "window.__vellumEpub?.restore(\(EpubReaderJavaScript.literal(passage)));"
            }
            if !script.isEmpty { view.evaluateJavaScript(script, in: nil, in: .defaultClient) { _ in } }
        }

        private var href: String {
            guard let parent else { return "" }
            return resources.session.publication.spine[parent.location.chapter].path
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { synchronize(webView) }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url, let path = EpubResourceSchemeHandler.archivePath(for: url) else {
                // No publication navigation can escape this book's origin.
                decisionHandler(.cancel); return
            }
            if action.navigationType == .linkActivated {
                decisionHandler(.cancel)
                guard parent?.reader.isCurrent == true, action.targetFrame?.isMainFrame != false,
                      let chapter = resources.session.publication.spineIndex(path: path) else { return }
                parent?.reader.go(chapter: chapter, fragment: url.fragment)
            } else {
                decisionHandler(action.targetFrame?.isMainFrame == true && path == href ? .allow : .cancel)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let parent, parent.reader.isCurrent, message.frameInfo.isMainFrame,
                  let message = EpubReaderMessage.decode(message.body, token: parent.location.request.uuidString,
                    href: href, docId: resources.session.info.docId ?? "") else { return }
            parent.reader.receive(message)
        }
    }
}
#endif
