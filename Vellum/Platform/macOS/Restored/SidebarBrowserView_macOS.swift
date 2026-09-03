#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WebKit

/// A lightweight companion browser for looking something up without leaving
/// the document. It deliberately stays separate from Vellum's webpage reader:
/// navigation here does not create tabs, archives, annotations, or library
/// records.
struct SidebarBrowserView: View {
    @Environment(\.palette) private var palette

    @State private var controller = SidebarBrowserController()
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()

            ZStack {
                SidebarBrowserWebView(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if controller.currentURL == nil && !controller.isLoading {
                    ContentUnavailableView {
                        Label("Browse the web", systemImage: "globe")
                    } description: {
                        Text("Search or enter a website above.")
                    }
                }
            }

            if let error = controller.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(palette.destructive)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(palette.destructive.opacity(0.1))
                    .accessibilityIdentifier("sidebarBrowser.error")
            }
        }
        .background(palette.background)
        .onChange(of: controller.currentURL) { _, url in
            if let url { address = url.absoluteString }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
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

                IconButton(help: controller.isLoading ? "Stop" : "Reload") {
                    controller.isLoading ? controller.stop() : controller.reload()
                } icon: {
                    Image(systemName: controller.isLoading ? "xmark" : "arrow.clockwise")
                }
                .accessibilityIdentifier("sidebarBrowser.reload")

                TextField("Search or enter website", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .focused($addressFocused)
                    .onSubmit(openAddress)
                    .accessibilityIdentifier("sidebarBrowser.address")

                IconButton(
                    variant: .primary,
                    help: "Go",
                    disabled: address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ) {
                    openAddress()
                } icon: {
                    Image(systemName: "arrow.right")
                }
                .accessibilityIdentifier("sidebarBrowser.go")
            }

            if controller.isLoading {
                ProgressView()
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Loading webpage")
            }
        }
        .padding(10)
    }

    private func openAddress() {
        guard controller.open(address) else { return }
        addressFocused = false
    }
}

@MainActor
@Observable
private final class SidebarBrowserController: NSObject {
    private(set) var currentURL: URL?
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?

    @ObservationIgnored private lazy var _webView: WKWebView = makeWebView()
    var webView: WKWebView { _webView }

    private func makeWebView() -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    @discardableResult
    func open(_ input: String) -> Bool {
        guard let url = Self.destination(for: input) else { return false }
        errorMessage = nil
        currentURL = url
        webView.load(URLRequest(url: url))
        return true
    }

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reload() {
        guard currentURL != nil else { return }
        webView.reload()
    }

    func stop() {
        webView.stopLoading()
        refreshState()
    }

    private func refreshState() {
        currentURL = webView.url ?? currentURL
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
    }

    private static func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if let url = URL(string: value),
           let scheme = url.scheme?.lowercased(),
           ["http", "https"].contains(scheme),
           url.host != nil {
            return url
        }

        if !value.contains(where: \Character.isWhitespace),
           (value.contains(".") || value == "localhost"),
           let url = URL(string: "https://\(value)"),
           url.host != nil {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: value)]
        return components?.url
    }
}

extension SidebarBrowserController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        errorMessage = nil
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshState()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        handleFailure(error)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" else {
            if let scheme, ["mailto", "tel", "facetime"].contains(scheme) {
                NSWorkspace.shared.open(url)
            }
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           let url = navigationAction.request.url {
            webView.load(URLRequest(url: url))
        }
        return nil
    }

    private func handleFailure(_ error: Error) {
        let nsError = error as NSError
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
        else { return }
        errorMessage = error.localizedDescription
        refreshState()
    }
}

private struct SidebarBrowserWebView: NSViewRepresentable {
    let controller: SidebarBrowserController

    func makeNSView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#endif
