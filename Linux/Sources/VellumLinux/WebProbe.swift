import Foundation

/// Observes the normal reader across two real sidebar selections of Harbor.
/// Only --web-probe installs the extra negative requests.
@MainActor
final class WebProbe {
    private var current: URL?
    private var stale: URL?
    private var ready: Set<String> = []
    private var staleDenied = false, externalImageDenied = false, navigationDenied = false
    private let external = "https://example.invalid/vellum-offline-probe"

    func nextScript(for document: URL) -> String {
        defer { current = document }
        guard let previous = current else { return "" }
        let asset = previous.deletingLastPathComponent().appendingPathComponent("__VELLUM_ASSET__/sample.png")
        stale = asset
        return """

            addEventListener('securitypolicyviolation', e => {
                if (e.effectiveDirective === 'img-src' && e.blockedURI.startsWith('https://example.invalid')) {
                    window.webkit.messageHandlers.vellum.postMessage({
                        uri: location.href, anchor: '', width: 0, height: 0, event: 'external-image-denied'
                    });
                }
            });
            addEventListener('load', () => {
                new Image().src = '\(asset.absoluteString)';
                new Image().src = '\(external).png';
                const link = document.createElement('a');
                link.href = '\(external)';
                link.click();
            }, {once: true});
            """
    }

    func received(_ message: WebPageHost.PageMessage) {
        if message.event == "external-image-denied" { externalImageDenied = true; return }
        if message.event == nil, message.anchor == "Harbor café 東京", message.width == 17, message.height == 11 {
            ready.insert(message.uri)
            print("Swift received \(message.uri) anchor=\(message.anchor ?? "") image=\(message.width ?? 0)x\(message.height ?? 0)")
        }
    }

    func resourceDenied(_ uri: URL) { if uri == stale { staleDenied = true } }
    func navigationDenied(_ uri: String) { if uri == external { navigationDenied = true } }

    func result() -> Int32 {
        print("Harbor selections=\(ready.count) staleDenied=\(staleDenied) externalImageCSP=\(externalImageDenied) externalNavigationDenied=\(navigationDenied)")
        return ready.count >= 2 && staleDenied && externalImageDenied && navigationDenied ? 0 : 1
    }
}
