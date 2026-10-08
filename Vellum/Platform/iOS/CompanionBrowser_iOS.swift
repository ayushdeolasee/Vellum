#if os(iOS)
import Observation
import SwiftUI
import UIKit
import WebKit

/// Transient, window-owned browsing. It never opens, renames or saves a document.
@MainActor
@Observable
final class CompanionBrowserController_iOS: NSObject {
    private(set) var webView: CompanionWebView_iOS?
    private(set) var currentURL: URL?
    private(set) var pageTitle = ""
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    private(set) var isLoading = false
    private(set) var estimatedProgress = 0.0
    private(set) var errorMessage: String?
    private(set) var hasParentPage = false
    var addressDraft = ""
    var addressFocusRequest: UUID?
    var addressIsEditing = false

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var parents: [CompanionWebView_iOS] = []
    @ObservationIgnored private var failedURL: URL?
    @ObservationIgnored private var currentNavigation: WKNavigation?
    @ObservationIgnored private var isActive = false
    @ObservationIgnored weak var inspectorHost: UIView?
    @ObservationIgnored private weak var presentedDialog: UIAlertController?
    @ObservationIgnored private var dialogCompletion: ((Bool, String?) -> Void)?

    func prepare() {
        guard webView == nil else { return }
        let configuration = WKWebViewConfiguration()
        // UI checks and ordinary companion browsing cannot modify the reader's
        // WebKit cookies/cache. The session still survives panel/sheet dismissal.
        configuration.websiteDataStore = .nonPersistent()
        let page = CompanionWebView_iOS(frame: .zero, configuration: configuration)
        configure(page)
        webView = page
        observePage()
    }

    private func configure(_ page: CompanionWebView_iOS) {
        page.navigationDelegate = self
        page.uiDelegate = self
        page.allowsBackForwardNavigationGestures = true
        page.onCommand = { [weak self] command in
            guard let self, self.isActive else { return }
            switch command {
            case "l": self.requestAddressFocus()
            case "[": self.goBack()
            case "]": self.goForward()
            case "r": self.reload()
            case UIKeyCommand.inputEscape: self.stop()
            default: break
            }
        }
    }

    private func observePage() {
        observations.removeAll()
        guard let page = webView else { return }
        observations = [
            page.observe(\.url, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            page.observe(\.title, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            page.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            page.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            page.observe(\.isLoading, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() },
            page.observe(\.estimatedProgress, options: [.new]) { [weak self] _, _ in self?.scheduleRefresh() }
        ]
        refreshState()
    }

    nonisolated private func scheduleRefresh() {
        // UI-only synchronization; there is no file I/O or persistence task.
        Task { @MainActor [weak self] in self?.refreshState() }
    }

    private func refreshState() {
        guard let page = webView else { return }
        let previousURL = currentURL
        if errorMessage == nil { currentURL = page.url ?? currentURL }
        pageTitle = page.title ?? ""
        canGoBack = page.canGoBack
        canGoForward = page.canGoForward
        isLoading = page.isLoading
        estimatedProgress = page.estimatedProgress
        if !addressIsEditing, addressDraft.isEmpty || addressDraft == previousURL?.absoluteString {
            addressDraft = currentURL?.absoluteString ?? ""
        }
    }

    func setActive(_ active: Bool) {
        isActive = active
        if !active {
            addressIsEditing = false
            webView?.endEditing(true)
            cancelDialog()
        }
    }

    func isInspectorHosted(in controller: UIViewController) -> Bool {
        guard let inspectorHost, controller.isViewLoaded else { return false }
        return inspectorHost.isDescendant(of: controller.view)
    }

    func requestAddressFocus() { addressFocusRequest = UUID() }

    @discardableResult
    func openAddress() -> Bool {
        guard let url = Self.destination(for: addressDraft) else { return false }
        if Self.externalSchemes.contains(url.scheme?.lowercased() ?? "") {
            offerExternal(url)
            return false
        }
        guard Self.isWebURL(url) else {
            showNotice("Unsupported address", message: "Use a website, search term, mailto, tel or FaceTime link.")
            return false
        }
        prepare()
        beginNavigation()
        currentURL = url
        addressDraft = url.absoluteString
        currentNavigation = webView?.load(URLRequest(url: url))
        return true
    }

    private func beginNavigation() {
        cancelDialog()
        errorMessage = nil
        failedURL = nil
    }

    func goBack() {
        guard let page = webView, page.canGoBack else { return }
        beginNavigation()
        currentNavigation = page.goBack()
    }

    func goForward() {
        guard let page = webView, page.canGoForward else { return }
        beginNavigation()
        currentNavigation = page.goForward()
    }

    func reload() {
        guard let page = webView, let url = failedURL ?? currentURL else { return }
        let retry = failedURL != nil || page.url == nil
        beginNavigation()
        currentNavigation = retry ? page.load(URLRequest(url: url)) : page.reload()
    }

    func stop() {
        webView?.stopLoading()
        currentNavigation = nil
        refreshState()
    }

    func closePopup() {
        guard let parent = parents.popLast() else { return }
        cancelDialog()
        webView?.stopLoading()
        webView?.endEditing(true)
        webView = parent
        hasParentPage = !parents.isEmpty
        currentNavigation = nil
        errorMessage = nil
        failedURL = nil
        currentURL = parent.url
        if !addressIsEditing { addressDraft = currentURL?.absoluteString ?? "" }
        observePage()
    }

    func openInBrowser() {
        guard let url = currentURL, Self.isWebURL(url) else { return }
        handOff(url)
    }

    private func handOff(_ url: URL) {
        UIApplication.shared.open(url, options: [:]) { [weak self] success in
            guard !success else { return }
            Task { @MainActor [weak self] in
                self?.showNotice("Couldn't open link", message: "No available app could open this link.")
            }
        }
    }

    private static let externalSchemes: Set<String> = ["mailto", "tel", "facetime", "facetime-audio"]

    private static func isWebURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && !(url.host ?? "").isEmpty
    }

    static func destination(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if let url = URL(string: value), let scheme = url.scheme {
            // A host:port input is an address, not a custom URL scheme.
            if value.contains("://") || externalSchemes.contains(scheme.lowercased()) ||
                ["javascript", "data", "file", "about"].contains(scheme.lowercased()) {
                return url
            }
        }
        if !value.contains(where: \Character.isWhitespace),
           var components = URLComponents(string: "https://\(value)"),
           let host = components.host, components.user == nil,
           host.contains(".") || host == "localhost" || host.contains(":") {
            if host == "localhost" || host.hasSuffix(".localhost") || host == "127.0.0.1" || host == "[::1]" {
                components.scheme = "http"
            }
            return components.url
        }
        var search = URLComponents(string: "https://duckduckgo.com/")
        search?.queryItems = [URLQueryItem(name: "q", value: value)]
        return search?.url
    }

    // Native dialogs are anchored in the WebView's own presentation host,
    // including the phone inspector sheet. Each WebKit callback completes once,
    // even if the inspector disappears or navigation supersedes the dialog.
    private func presenter(for page: WKWebView) -> UIViewController? {
        guard isActive, page === webView, page.window != nil else { return nil }
        if let presented = SheetPresence_iOS.topPresented,
           !page.isDescendant(of: presented.view) { return nil }
        var responder: UIResponder? = page
        while let current = responder {
            if let controller = current as? UIViewController {
                guard !controller.isBeingDismissed, controller.presentedViewController == nil else { return nil }
                return controller
            }
            responder = current.next
        }
        return nil
    }

    private func cancelDialog() {
        let dialog = presentedDialog
        finishDialog(accepted: false)
        dialog?.dismiss(animated: false)
    }

    private func finishDialog(accepted: Bool, text: String? = nil) {
        let completion = dialogCompletion
        dialogCompletion = nil
        presentedDialog = nil
        completion?(accepted, text)
    }

    private func presentDialog(
        title: String, message: String, defaultText: String? = nil,
        prompt: Bool = false, cancelTitle: String? = "Cancel", acceptTitle: String = "OK",
        completion: @escaping (Bool, String?) -> Void
    ) {
        guard let page = webView, dialogCompletion == nil, let presenter = presenter(for: page) else {
            completion(false, nil)
            return
        }
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        if prompt { alert.addTextField { $0.text = defaultText } }
        if let cancelTitle {
            alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel) { [weak self] _ in
                self?.finishDialog(accepted: false)
            })
        }
        alert.addAction(UIAlertAction(title: acceptTitle, style: .default) { [weak self, weak alert] _ in
            self?.finishDialog(accepted: true, text: alert?.textFields?.first?.text)
        })
        dialogCompletion = completion
        presentedDialog = alert
        presenter.present(alert, animated: true)
    }

    private func showNotice(_ title: String, message: String) {
        presentDialog(title: title, message: message, cancelTitle: nil) { _, _ in }
    }

    private func offerExternal(_ url: URL) {
        presentDialog(title: "Open in another app?", message: url.absoluteString, acceptTitle: "Open") { [weak self] accepted, _ in
            if accepted { self?.handOff(url) }
        }
    }
}

extension CompanionBrowserController_iOS: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        beginNavigation()
        currentNavigation = navigation
        refreshState()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        refreshState()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView, navigation === currentNavigation else { return }
        refreshState()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, page: webView, navigation: navigation)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleFailure(error, page: webView, navigation: navigation)
    }

    private func handleFailure(_ error: Error, page: WKWebView, navigation: WKNavigation?) {
        guard page === webView, navigation === currentNavigation else { return }
        let failure = error as NSError
        guard !(failure.domain == NSURLErrorDomain && failure.code == NSURLErrorCancelled) else { return }
        failedURL = (failure.userInfo[NSURLErrorFailingURLErrorKey] as? URL) ?? currentURL
        currentURL = failedURL
        if !addressIsEditing { addressDraft = currentURL?.absoluteString ?? "" }
        errorMessage = error.localizedDescription
        cancelDialog()
        refreshState()
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        cancelDialog()
        failedURL = currentURL
        errorMessage = "This page stopped responding. Try loading it again."
        isLoading = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .cancel }
        if Self.isWebURL(url) || url.absoluteString == "about:blank" { return .allow }
        // App handoff requires an explicit user link activation in the active
        // panel; custom schemes, scripts and redirects never launch other apps.
        if webView === self.webView, isActive, navigationAction.navigationType == .linkActivated {
            if Self.externalSchemes.contains(url.scheme?.lowercased() ?? "") {
                offerExternal(url)
            } else {
                showNotice("Unsupported link", message: "This browser supports websites and mail, phone and FaceTime links. Use Open in Browser for other website features.")
            }
        }
        return .cancel
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard isActive, webView === self.webView, navigationAction.targetFrame == nil else { return nil }
        guard parents.count < 4 else {
            showNotice("Too many popups", message: "Close a popup before opening another.")
            return nil
        }
        let url = navigationAction.request.url
        guard url == nil || url?.absoluteString == "about:blank" || url.map(Self.isWebURL) == true else {
            if let url, Self.externalSchemes.contains(url.scheme?.lowercased() ?? ""),
               navigationAction.navigationType == .linkActivated { offerExternal(url) }
            return nil
        }
        cancelDialog()
        let child = CompanionWebView_iOS(frame: .zero, configuration: configuration)
        configure(child)
        if let parent = self.webView { parents.append(parent) }
        webView.endEditing(true)
        self.webView = child
        hasParentPage = true
        currentNavigation = nil
        currentURL = url
        if !addressIsEditing { addressDraft = currentURL?.absoluteString ?? "" }
        errorMessage = nil
        failedURL = nil
        observePage()
        return child
    }

    func webViewDidClose(_ webView: WKWebView) {
        if webView === self.webView { closePopup() }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard webView === self.webView else { completionHandler(); return }
        presentDialog(title: frame.request.url?.host ?? "Webpage", message: message, cancelTitle: nil) { _, _ in
            completionHandler()
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard webView === self.webView else { completionHandler(false); return }
        presentDialog(title: frame.request.url?.host ?? "Webpage", message: message) { accepted, _ in
            completionHandler(accepted)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard webView === self.webView else { completionHandler(nil); return }
        presentDialog(title: frame.request.url?.host ?? "Webpage", message: prompt, defaultText: defaultText, prompt: true) { accepted, text in
            completionHandler(accepted ? text : nil)
        }
    }
}

/// Override only browser chords, leaving page text editing and navigation alone.
final class CompanionWebView_iOS: WKWebView {
    var onCommand: ((String) -> Void)?

    override var keyCommands: [UIKeyCommand]? {
        let definitions = [("l", "Focus Browser Address"), ("[", "Back"), ("]", "Forward"), ("r", "Reload")]
        let commands = definitions.map { input, title in
            let command = UIKeyCommand(title: title, action: #selector(runBrowserCommand(_:)), input: input, modifierFlags: .command)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let stop = UIKeyCommand(title: "Stop Loading", action: #selector(runBrowserCommand(_:)), input: UIKeyCommand.inputEscape)
        return commands + [stop] + (super.keyCommands ?? [])
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(runBrowserCommand(_:)), let command = sender as? UIKeyCommand {
            return command.input != UIKeyCommand.inputEscape || isLoading
        }
        return super.canPerformAction(action, withSender: sender)
    }

    @objc private func runBrowserCommand(_ command: UIKeyCommand) {
        if let input = command.input { onCommand?(input) }
    }
}

struct CompanionBrowserPanel_iOS: View {
    @Bindable var controller: CompanionBrowserController_iOS
    let isActive: Bool
    @Environment(\.palette) private var palette
    @FocusState private var addressFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            controls
            ProgressView(value: controller.estimatedProgress)
                .opacity(controller.isLoading ? 1 : 0)
                .frame(height: 2)
                .accessibilityHidden(true)
            ZStack {
                if let page = controller.webView {
                    CompanionPageHost_iOS(page: page)
                        .allowsHitTesting(controller.errorMessage == nil)
                        .accessibilityHidden(controller.errorMessage != nil)
                }
                if let error = controller.errorMessage {
                    ContentUnavailableView {
                        Label("Couldn't load this page", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button { controller.reload() } label: {
                            Text("Try Again").frame(minHeight: 44).contentShape(Rectangle())
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("sidebarBrowser.retry")
                    }
                    .background(palette.background)
                    .accessibilityIdentifier("sidebarBrowser.error")
                } else if controller.currentURL == nil && !controller.isLoading {
                    ContentUnavailableView {
                        Label("Browse the web", systemImage: "globe")
                    } description: {
                        Text("Search or enter a website to browse alongside your document.")
                    } actions: {
                        Button { controller.requestAddressFocus() } label: {
                            Text("Search the Web").frame(minHeight: 44).contentShape(Rectangle())
                        }
                    }
                    .background(palette.background)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.background)
        .onAppear {
            controller.setActive(isActive)
            consumeFocusRequest()
        }
        .onDisappear {
            addressFocused = false
            controller.setActive(false)
        }
        .onChange(of: isActive) { _, active in
            controller.setActive(active)
            if !active { addressFocused = false }
        }
        .onChange(of: addressFocused) { _, focused in
            controller.addressIsEditing = focused
            if !focused { controller.addressFocusRequest = nil }
        }
        .onChange(of: controller.addressFocusRequest) { _, _ in consumeFocusRequest() }
    }

    private var controls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                TextField("Search or enter website", text: $controller.addressDraft)
                    .textFieldStyle(.plain)
                    .keyboardType(.webSearch)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($addressFocused)
                    .onSubmit(openAddress)
                    .frame(minHeight: 44)
                    .accessibilityLabel("Search or enter website")
                    .accessibilityIdentifier("sidebarBrowser.address")
                control("Go", image: "arrow.right", id: "go", disabled: controller.addressDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: openAddress)
            }
            .padding(.leading, 10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 0) {
                if controller.hasParentPage {
                    control("Close popup and return to page", image: "xmark", id: "closePopup", action: controller.closePopup)
                }
                control("Back", image: "chevron.left", id: "back", disabled: !controller.canGoBack, action: controller.goBack)
                control("Forward", image: "chevron.right", id: "forward", disabled: !controller.canGoForward, action: controller.goForward)
                control(controller.isLoading ? "Stop" : "Reload", image: controller.isLoading ? "xmark" : "arrow.clockwise", id: "reload", disabled: controller.currentURL == nil && !controller.isLoading) {
                    controller.isLoading ? controller.stop() : controller.reload()
                }
                Spacer(minLength: 0)
                control("Open in Browser", image: "safari", id: "external", disabled: controller.currentURL?.scheme?.hasPrefix("http") != true, action: controller.openInBrowser)
            }
            Text(controller.pageTitle.isEmpty ? "Browser" : controller.pageTitle)
                .font(.caption)
                .foregroundStyle(palette.mutedForeground)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("sidebarBrowser.title")
        }
        .padding(8)
    }

    private func control(_ title: String, image: String, id: String, disabled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: image)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(title)
        .accessibilityIdentifier("sidebarBrowser.\(id)")
    }

    private func openAddress() {
        if controller.openAddress() {
            addressFocused = false
            controller.addressIsEditing = false
        }
    }

    private func consumeFocusRequest() {
        guard isActive, controller.addressFocusRequest != nil else { return }
        addressFocused = true
        // Clear on blur rather than here, so the phone sheet also observes the
        // request and promotes to its large detent before the keyboard opens.
    }
}

/// A replaceable host is needed for real WebKit popup views. Dismantling only
/// detaches the page; the window-owned controller retains its WebKit history.
private struct CompanionPageHost_iOS: UIViewRepresentable {
    let page: CompanionWebView_iOS

    func makeUIView(context: Context) -> UIView { UIView() }

    func updateUIView(_ host: UIView, context: Context) {
        guard page.superview !== host else { return }
        host.subviews.forEach { $0.removeFromSuperview() }
        page.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(page)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            page.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            page.topAnchor.constraint(equalTo: host.topAnchor),
            page.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
    }

    static func dismantleUIView(_ host: UIView, coordinator: ()) {
        host.subviews.forEach { $0.removeFromSuperview() }
    }
}

/// Marks the inspector's own presentation host for scoped phone keyboard routing.
struct CompanionInspectorHost_iOS: UIViewRepresentable {
    let controller: CompanionBrowserController_iOS

    func makeUIView(context: Context) -> UIView {
        let host = UIView()
        host.isUserInteractionEnabled = false
        host.accessibilityElementsHidden = true
        controller.inspectorHost = host
        return host
    }

    func updateUIView(_ host: UIView, context: Context) { controller.inspectorHost = host }
}
#endif
