import CShell
import Foundation
import LinuxReader

/// The GTK stack and reader window outlive this host. All WebKit callbacks
/// execute on that same thread. Requests synchronously take their own byte copy.
@MainActor
final class WebPageHost {
    struct PageMessage: Decodable {
        let uri: String
        let anchor: String
        let width, height: Int
        let event: String?
    }

    private static let script = """
        addEventListener('load', () => {
            const img = document.images[0];
            const text = document.querySelector('p, h1')?.textContent ?? '';
            window.webkit.messageHandlers.vellum.postMessage({
                uri: location.href.split('#')[0], anchor: text.slice(0, 256),
                width: img?.naturalWidth ?? 0, height: img?.naturalHeight ?? 0
            });
        }, {once: true});
        """

    private let resources: ArchiveResourceMap
    private let onReady: () -> Void
    private let probe: WebProbe?
    private var reader: OpaquePointer?

    init(stack: OpaquePointer, resources: ArchiveResourceMap, probe: WebProbe?, onReady: @escaping () -> Void) {
        self.resources = resources
        self.onReady = onReady
        self.probe = probe
        let script = Self.script + (probe?.nextScript(for: resources.documentURL) ?? "")
        reader = web_reader_new(stack, resources.documentURL.absoluteString, resources.hasHandwriting, script, {
            owner, uri, request in
            MainActor.assumeIsolated {
                let host = Unmanaged<WebPageHost>.fromOpaque(owner!).takeUnretainedValue()
                guard let url = URL(string: String(cString: uri!)) else { return false }
                guard let response = try? host.resources.response(for: url) else {
                    host.probe?.resourceDenied(url)
                    return false
                }
                response.bytes.withUnsafeBytes { bytes in
                    web_reader_respond(request, response.mime, bytes.baseAddress, bytes.count)
                }
                return true
            }
        }, { owner, message in
            MainActor.assumeIsolated {
                let host = Unmanaged<WebPageHost>.fromOpaque(owner!).takeUnretainedValue()
                guard let body = try? JSONDecoder().decode(PageMessage.self, from: Data(String(cString: message!).utf8)),
                      body.uri == host.resources.documentURL.absoluteString else { return }
                if body.event == nil { host.onReady() }
                host.probe?.received(body)
            }
        }, { owner, uri in
            MainActor.assumeIsolated {
                Unmanaged<WebPageHost>.fromOpaque(owner!).takeUnretainedValue().probe?.navigationDenied(String(cString: uri!))
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    isolated deinit { if let reader { web_reader_free(reader) } }
}
