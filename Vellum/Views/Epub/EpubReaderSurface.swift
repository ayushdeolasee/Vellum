#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import WebKit

#if os(macOS)
typealias EpubViewRepresentable = NSViewRepresentable
#else
typealias EpubViewRepresentable = UIViewRepresentable
#endif

/// A navigation is allowed to finish only for the document load that requested
/// it; a chapter href alone cannot distinguish successive visits to one chapter.
struct EpubReaderLoadGate {
    private(set) var loading: (id: UUID, url: URL)?
    private(set) var loadedURL: URL?

    mutating func begin(path: String) -> (id: UUID, url: URL) {
        let id = UUID()
        var components = URLComponents(url: EpubResourceSchemeHandler.url(for: path), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "vellum-load", value: id.uuidString)]
        let attempt = (id: id, url: components.url!)
        loadedURL = nil
        loading = attempt
        return attempt
    }

    func isLoading(path: String) -> Bool {
        loading.flatMap { EpubResourceSchemeHandler.archivePath(for: $0.url) } == path
    }

    func isLoaded(path: String, viewURL: URL?) -> Bool {
        loadedURL != nil && loadedURL == viewURL && loadedURL.flatMap(EpubResourceSchemeHandler.archivePath(for:)) == path
    }

    func allows(_ url: URL?, mainFrame: Bool, path: String) -> Bool {
        mainFrame && url == loading?.url && url.flatMap(EpubResourceSchemeHandler.archivePath(for:)) == path
    }

    mutating func finish(_ id: UUID, viewURL: URL?) -> Bool {
        guard let loading, loading.id == id, loading.url == viewURL else { return false }
        loadedURL = loading.url
        self.loading = nil
        return true
    }

    mutating func invalidate() { loading = nil; loadedURL = nil }
}

enum EpubReaderLinkRouter {
    static func follow(_ url: URL?, active: Bool, sourceIsMainFrame: Bool,
                       targetIsMainFrame: Bool?, spineIndex: (String) -> Int?,
                       navigate: (Int, String?) -> Void, openExternal: (URL) -> Void) {
        guard active, sourceIsMainFrame, targetIsMainFrame != false, let url else { return }
        if let path = EpubResourceSchemeHandler.archivePath(for: url) {
            if let chapter = spineIndex(path) { navigate(chapter, url.fragment) }
        } else if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
            openExternal(url)
        }
    }
}

struct EpubReaderSurface: EpubViewRepresentable {
    let reader: EpubReaderController
    let session: EpubDocumentSession
    let location: EpubReaderLocation
    let settings: EpubReaderSettings
    let annotations: [Annotation]
    let dark: Bool
    let palette: ThemePalette
    var handwritingNotes: [EpubHandwritingNote] = []
    var pencilHighlighting = false

    func makeCoordinator() -> Coordinator { Coordinator(session: session) }

    #if os(macOS)
    func makeNSView(context: Context) -> EpubChapterWebView { makeView(context: context) }
    func updateNSView(_ view: EpubChapterWebView, context: Context) { updateView(view, context: context) }
    static func dismantleNSView(_ view: EpubChapterWebView, coordinator: Coordinator) { dismantleView(view, coordinator: coordinator) }
    #else
    func makeUIView(context: Context) -> EpubChapterWebView { makeView(context: context) }
    func updateUIView(_ view: EpubChapterWebView, context: Context) { updateView(view, context: context) }
    static func dismantleUIView(_ view: EpubChapterWebView, coordinator: Coordinator) { dismantleView(view, coordinator: coordinator) }
    #endif

    private func makeView(context: Context) -> EpubChapterWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.setURLSchemeHandler(context.coordinator.resources, forURLScheme: EpubResourceSchemeHandler.scheme)
        configuration.userContentController.addUserScript(WKUserScript(source: EpubReaderJavaScript.source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        configuration.userContentController.add(context.coordinator, contentWorld: .defaultClient, name: "epubReader")
        let view = EpubChapterWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        #if os(macOS)
        view.setAccessibilityIdentifier("epub.content")
        #else
        view.accessibilityIdentifier = "epub.content"
        #endif
        reader.webView = view
        let resources = context.coordinator.resources
        reader.drainResources = { await resources.drain() }
        #if os(iOS)
        let pencil = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pencilDragged(_:)))
        pencil.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        pencil.maximumNumberOfTouches = 1
        pencil.isEnabled = false
        view.addGestureRecognizer(pencil)
        context.coordinator.pencil = pencil
        context.coordinator.scrollTouchTypes = view.scrollView.panGestureRecognizer.allowedTouchTypes
        #endif
        return view
    }

    private func updateView(_ view: EpubChapterWebView, context: Context) {
        context.coordinator.parent = self
        view.readerActive = reader.isCurrent
        #if os(iOS)
        let highlighting = pencilHighlighting && reader.isCurrent
        context.coordinator.pencil?.isEnabled = highlighting
        view.scrollView.panGestureRecognizer.allowedTouchTypes = highlighting
            ? [NSNumber(value: UITouch.TouchType.direct.rawValue)] : context.coordinator.scrollTouchTypes
        #endif
        view.onChapterStep = { step in
            guard reader.isCurrent else { return }
            reader.go(chapter: location.chapter + step)
        }
        context.coordinator.show(in: view)
    }

    private static func dismantleView(_ view: EpubChapterWebView, coordinator: Coordinator) {
        view.readerActive = false; view.removeKeyMonitor(); view.onChapterStep = nil
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        coordinator.invalidateLoad()
        view.navigationDelegate = nil; view.stopLoading()
        coordinator.resources.cancelAll()
        coordinator.parent?.reader.deactivate()
        coordinator.parent = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let resources: EpubResourceSchemeHandler
        var parent: EpubReaderSurface?
        private var shown: UUID?
        private var loadGate = EpubReaderLoadGate()
        private var loadingNavigation: WKNavigation?
        private var loadingID: UUID?
        private var pending = false
        private var configurationJSON = ""
        private var annotationJSON = ""
        var openExternalURL: (URL) -> Void = {
            #if os(macOS)
            NSWorkspace.shared.open($0)
            #else
            UIApplication.shared.open($0)
            #endif
        }
        #if os(iOS)
        var pencil: UIPanGestureRecognizer?
        var scrollTouchTypes: [NSNumber] = []

        @objc func pencilDragged(_ gesture: UIPanGestureRecognizer) {
            guard let parent, parent.reader.isCurrent, parent.reader.pencilHighlighting,
                  parent.location.request == parent.reader.location?.request,
                  let view = parent.reader.webView, view === gesture.view,
                  loadGate.isLoaded(path: href, viewURL: view.url) else { return }
            var point = gesture.location(in: view)
            let phase: String
            switch gesture.state {
            case .began:
                let translation = gesture.translation(in: view)
                point.x -= translation.x; point.y -= translation.y
                phase = "begin"
            case .changed: phase = "move"
            case .ended: phase = "end"
            default: phase = "cancel"
            }
            view.evaluateJavaScript("window.__vellumEpub?.pencil('\(phase)',\(point.x),\(point.y));",
                in: nil, in: .defaultClient) { _ in }
        }
        #endif
        init(session: EpubDocumentSession) { resources = EpubResourceSchemeHandler(session: session) }

        func invalidateLoad() {
            loadingNavigation = nil; loadingID = nil; loadGate.invalidate()
        }

        func show(in view: WKWebView) {
            guard let parent else { return }
            let location = parent.location
            let changed = shown != location.request
            if changed {
                shown = location.request; pending = true
                configurationJSON = ""; annotationJSON = ""
            }
            let path = resources.session.publication.spine[location.chapter].path
            if loadGate.isLoaded(path: path, viewURL: view.url) {
                synchronize(view)
            } else if changed && !(loadingNavigation != nil && loadGate.isLoading(path: path)) {
                invalidateLoad()
                view.stopLoading()
                let attempt = loadGate.begin(path: path)
                loadingID = attempt.id
                loadingNavigation = view.load(URLRequest(url: attempt.url))
                if loadingNavigation == nil {
                    loadGate.invalidate(); loadingID = nil
                    parent.reader.notice = "This chapter could not be loaded."
                }
            }
        }

        private struct Configuration: Encodable {
            let token: String; let href: String; let active: Bool
            let settings: EpubReaderSettings; let dark: Bool
            let colors: EpubReaderCSSColors
        }
        private struct Passage: Encodable { let anchor: EpubTextAnchor?; let progression: Double; let fragment: String? }
        private struct Mark: Encodable {
            let id: String; let anchor: EpubTextAnchor; let color: String?; var handwriting = false
        }

        private func synchronize(_ view: WKWebView) {
            guard let parent, shown == parent.location.request,
                  loadGate.isLoaded(path: href, viewURL: view.url) else { return }
            let config = EpubReaderJavaScript.literal(Configuration(token: parent.location.request.uuidString, href: href,
                active: parent.reader.isCurrent, settings: parent.settings, dark: parent.dark,
                colors: EpubReaderCSSColors(palette: parent.palette)))
            var script = ""
            if config != configurationJSON { configurationJSON = config; script += "window.__vellumEpub?.configure(\(config));" }
            var marks = parent.annotations.filter { $0.pageNumber == parent.location.chapter + 1 }
                .prefix(500).compactMap { annotation -> Mark? in
                    guard let anchor = annotation.positionData?.epubAnchor else { return nil }
                    return Mark(id: annotation.id, anchor: anchor, color: annotation.color)
                }
            #if os(iOS)
            marks += parent.handwritingNotes.filter { $0.anchor.chapterHref == href }.prefix(500).map {
                Mark(id: "ink:" + $0.id, anchor: $0.anchor, color: nil, handwriting: true)
            }
            #endif
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let loadingNavigation, navigation === loadingNavigation, let loadingID else { return }
            self.loadingNavigation = nil; self.loadingID = nil
            guard loadGate.finish(loadingID, viewURL: webView.url) else {
                loadGate.invalidate(); return
            }
            synchronize(webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            fail(navigation, error: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            fail(navigation, error: error)
        }

        private func fail(_ navigation: WKNavigation, error: Error) {
            guard let loadingNavigation, navigation === loadingNavigation else { return }
            invalidateLoad()
            parent?.reader.notice = "This chapter could not be loaded: \(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated {
                decisionHandler(.cancel)
                EpubReaderLinkRouter.follow(action.request.url,
                    active: parent?.reader.isCurrent == true &&
                        loadGate.isLoaded(path: href, viewURL: action.sourceFrame.request.url),
                    sourceIsMainFrame: action.sourceFrame.isMainFrame, targetIsMainFrame: action.targetFrame?.isMainFrame,
                    spineIndex: { resources.session.publication.spineIndex(path: $0) },
                    navigate: { [weak self] chapter, fragment in self?.parent?.reader.go(chapter: chapter, fragment: fragment) },
                    openExternal: openExternalURL)
            } else {
                decisionHandler(loadGate.allows(action.request.url,
                    mainFrame: action.targetFrame?.isMainFrame == true, path: href) ? .allow : .cancel)
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let parent, parent.reader.isCurrent, message.frameInfo.isMainFrame,
                  loadGate.isLoaded(path: href, viewURL: message.webView?.url),
                  message.frameInfo.request.url == loadGate.loadedURL,
                  let message = EpubReaderMessage.decode(message.body, token: parent.location.request.uuidString,
                    href: href, docId: resources.session.info.docId ?? "") else { return }
            parent.reader.receive(message)
        }
    }
}

private struct EpubReaderCSSColors: Encodable {
    let well: String
    let surface: String
    let foreground: String
    let primary: String
    let border: String

    init(palette: ThemePalette) {
        well = palette.well.cssRGB
        surface = palette.surface.cssRGB
        foreground = palette.foreground.cssRGB
        primary = palette.primary.cssRGB
        border = palette.border.cssRGB
    }
}

private extension Color {
    var cssRGB: String {
        #if os(macOS)
        let color = NSColor(self).usingColorSpace(.sRGB) ?? .black
        return String(
            format: "rgb(%d, %d, %d)",
            Int((color.redComponent * 255).rounded()),
            Int((color.greenComponent * 255).rounded()),
            Int((color.blueComponent * 255).rounded()))
        #else
        let color = UIColor(self)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: nil)
        return String(
            format: "rgb(%d, %d, %d)",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded()))
        #endif
    }
}
#endif
