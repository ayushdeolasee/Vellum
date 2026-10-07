#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WebKit

extension Notification.Name {
    static let vellumFocusBrowserAddress = Notification.Name("vellum.focus-browser-address")
    static let vellumReloadBrowser = Notification.Name("vellum.reload-browser")
}

/// Companion browsing stays separate from the document library and annotations.
struct SidebarBrowserView: View {
    let isActive: Bool
    @Environment(\.palette) private var palette

    @State private var controller = SidebarBrowserController()
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            GeometryReader { geometry in
                Rectangle()
                    .fill(controller.isLoading ? palette.primary : palette.border)
                    .frame(width: geometry.size.width * (controller.isLoading ? controller.estimatedProgress : 1))
            }
            .frame(height: 2)
            .accessibilityHidden(true)

            ZStack {
                SidebarBrowserWebView(webView: controller.webView, isVisible: controller.errorMessage == nil)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(controller.errorMessage == nil)
                    .accessibilityHidden(controller.errorMessage != nil)

                if let error = controller.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load this page", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") { controller.reload() }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("sidebarBrowser.retry")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                    .accessibilityIdentifier("sidebarBrowser.error")
                } else if controller.currentURL == nil && !controller.isLoading {
                    ContentUnavailableView {
                        Label("Browse the web", systemImage: "globe")
                    } description: {
                        Text("Search or enter a website to browse alongside your document.")
                    } actions: {
                        Button("Search the Web") { addressFocused = true }
                            .buttonStyle(.bordered)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(palette.background)
                }
            }
        }
        .background(palette.background)
        .onChange(of: controller.currentURL) { _, url in
            guard !addressFocused else { return }
            address = url?.absoluteString ?? ""
        }
        .onChange(of: isActive) { _, active in
            controller.setActive(active)
            if !active { addressFocused = false }
        }
        .onAppear { controller.setActive(isActive) }
        .onReceive(NotificationCenter.default.publisher(for: .vellumFocusBrowserAddress)) { _ in
            guard isActive else { return }
            addressFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumReloadBrowser)) { _ in
            guard isActive else { return }
            controller.reload()
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(palette.mutedForeground)
                    .accessibilityHidden(true)
                TextField("Search or enter website", text: $address)
                    .textFieldStyle(.plain)
                    .focused($addressFocused)
                    .onSubmit(openAddress)
                    .onExitCommand {
                        address = controller.currentURL?.absoluteString ?? ""
                        addressFocused = false
                    }
                    .accessibilityLabel("Search or enter website")
                    .accessibilityIdentifier("sidebarBrowser.address")
                IconButton(help: "Go", disabled: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                    openAddress()
                } icon: {
                    Image(systemName: "arrow.right")
                }
                .accessibilityIdentifier("sidebarBrowser.go")
            }
            .padding(.leading, 10)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(addressFocused ? palette.primary : palette.borderStrong)
            }

            HStack(spacing: 4) {
                if controller.hasParentPage {
                    IconButton(help: "Close pop-up and return to page") {
                        controller.closePopup()
                    } icon: {
                        Image(systemName: "xmark")
                    }
                    .accessibilityIdentifier("sidebarBrowser.closePopup")
                }
                IconButton(help: "Back", disabled: !controller.canGoBack) {
                    controller.goBack()
                } icon: {
                    Image(systemName: "chevron.left")
                }
                .accessibilityIdentifier("sidebarBrowser.back")
                IconButton(help: "Forward", disabled: !controller.canGoForward) {
                    controller.goForward()
                } icon: {
                    Image(systemName: "chevron.right")
                }
                .accessibilityIdentifier("sidebarBrowser.forward")
                IconButton(help: controller.isLoading ? "Stop" : "Reload", disabled: controller.currentURL == nil && !controller.isLoading) {
                    controller.isLoading ? controller.stop() : controller.reload()
                } icon: {
                    Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                }
                .accessibilityIdentifier("sidebarBrowser.reload")

                Text(controller.errorMessage != nil ? "Page unavailable" : (controller.pageTitle.isEmpty ? "Browser" : controller.pageTitle))
                    .font(.caption)
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(controller.pageTitle)
                    .accessibilityIdentifier("sidebarBrowser.title")

                Menu {
                    Button("Zoom In") { controller.changeZoom(by: 0.1) }
                        .disabled(controller.zoom >= 2)
                    Button("Zoom Out") { controller.changeZoom(by: -0.1) }
                        .disabled(controller.zoom <= 0.5)
                    Button("Actual Size") { controller.resetZoom() }
                } label: {
                    Text("\(Int((controller.zoom * 100).rounded()))%")
                        .font(.caption.monospacedDigit())
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Page zoom")
                .accessibilityLabel("Page zoom")
                .accessibilityIdentifier("sidebarBrowser.zoom")
            }
        }
        .padding(12)
    }

    private func openAddress() {
        guard controller.open(address) else { return }
        address = controller.currentURL?.absoluteString ?? address
        addressFocused = false
    }
}

@MainActor
@Observable
private final class SidebarBrowserController: NSObject {
    private(set) var webView: WKWebView
    private(set) var currentURL: URL?
    private(set) var pageTitle = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var errorMessage: String?
    private(set) var zoom = 1.0
    private(set) var hasParentPage = false
    private var isActive = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var parentPages: [WKWebView] = []
    @ObservationIgnored private var failedURL: URL?

    override init() {
        let configuration = WKWebViewConfiguration()
        if UITestLaunchConfiguration.isEnabled {
            configuration.websiteDataStore = .nonPersistent()
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        configure(webView)
        observeCurrentPage()
    }

    private func configure(_ page: WKWebView) {
        page.navigationDelegate = self
        page.uiDelegate = self
        page.allowsBackForwardNavigationGestures = true
    }

    private func observeCurrentPage() {
        observations = [
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() }
        ]
        refreshState()
    }

    nonisolated private func scheduleRefresh() {
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active { resignPageFocus() }
    }

    private func resignPageFocus() {
        guard let window = webView.window,
              let responder = window.firstResponder as? NSView,
              responder === webView || responder.isDescendant(of: webView)
        else { return }
        window.makeFirstResponder(nil)
    }

    @discardableResult
    func open(_ input: String) -> Bool {
        guard let url = Self.destination(for: input) else { return false }
        errorMessage = nil
        failedURL = nil
        currentURL = url
        webView.load(URLRequest(url: url))
        return true
    }

    func goBack() { if webView.canGoBack { webView.goBack() } }
    func goForward() { if webView.canGoForward { webView.goForward() } }

    func reload() {
        guard let url = failedURL ?? currentURL else { return }
        errorMessage = nil
        if failedURL != nil || webView.url == nil {
            failedURL = nil
            webView.load(URLRequest(url: url))
        } else {
            webView.reload()
        }
    }

    func stop() {
        webView.stopLoading()
        refreshState()
    }

    func changeZoom(by delta: Double) {
        zoom = min(2, max(0.5, (zoom + delta) * 10).rounded() / 10)
        webView.pageZoom = zoom
    }

    func resetZoom() {
        zoom = 1
        webView.pageZoom = zoom
    }

    func closePopup() {
        guard let parent = parentPages.popLast() else { return }
        webView.stopLoading()
        webView = parent
        hasParentPage = !parentPages.isEmpty
        errorMessage = nil
        failedURL = nil
        currentURL = parent.url
        observeCurrentPage()
    }

    private func refreshState() {
        if errorMessage == nil { currentURL = webView.url ?? currentURL }
        pageTitle = webView.title ?? ""
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        estimatedProgress = webView.estimatedProgress
        zoom = webView.pageZoom
    }

    private static func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           let host = url.host, !host.isEmpty {
            return url
        }

        if !value.contains(where: \Character.isWhitespace),
           var components = URLComponents(string: "https://\(value)"),
           let host = components.host,
           components.user == nil,
           host.contains(".") || host == "localhost" || host.contains(":") {
            // Local development servers commonly serve HTTP, including port URLs.
            if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "[::1]" {
                components.scheme = "http"
            }
            return components.url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url
    }
}

extension SidebarBrowserController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        errorMessage = nil
        failedURL = nil
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        refreshState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, in: webView)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        failedURL = currentURL
        errorMessage = "This page stopped responding. Try loading it again."
        resignPageFocus()
        refreshState()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased()
        if scheme == "http" || scheme == "https" || url.absoluteString == "about:blank" {
            return .allow
        }
        if navigationAction.navigationType == .linkActivated,
           let scheme, ["mailto", "tel", "facetime"].contains(scheme) {
            NSWorkspace.shared.open(url)
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard isActive, webView === self.webView, navigationAction.targetFrame == nil else { return nil }
        // Return a real child using WebKit's configuration so window.opener and
        // JavaScript-created blank windows continue to work. Keep the parent alive.
        let popup = WKWebView(frame: .zero, configuration: configuration)
        configure(popup)
        parentPages.append(webView)
        self.webView = popup
        hasParentPage = true
        currentURL = navigationAction.request.url
        errorMessage = nil
        failedURL = nil
        observeCurrentPage()
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView { closePopup() }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        guard let window = dialogWindow(for: webView) else { return }
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        await alert.beginSheetModal(for: window)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        guard let window = dialogWindow(for: webView) else { return false }
        let alert = pageAlert(message, frame: frame)
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo) async -> String? {
        guard let window = dialogWindow(for: webView) else { return nil }
        let alert = pageAlert(prompt, frame: frame)
        let field = NSTextField(string: defaultText ?? "")
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
        return field.stringValue
    }

    private func dialogWindow(for page: WKWebView) -> NSWindow? {
        guard isActive, page === webView else { return nil }
        return page.window
    }

    private func pageAlert(_ message: String, frame: WKFrameInfo) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Webpage"
        alert.informativeText = message
        return alert
    }

    private func handleFailure(_ error: Error, in page: WKWebView) {
        guard page === webView else { return }
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else { return }
        failedURL = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? currentURL
        currentURL = failedURL
        errorMessage = error.localizedDescription
        resignPageFocus()
        refreshState()
    }
}

private struct SidebarBrowserWebView: NSViewRepresentable {
    let webView: WKWebView
    let isVisible: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ host: NSView, context: Context) {
        webView.isHidden = !isVisible
        webView.setAccessibilityHidden(!isVisible)
        guard webView.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        webView.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            webView.topAnchor.constraint(equalTo: host.topAnchor),
            webView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }
}
#endif
