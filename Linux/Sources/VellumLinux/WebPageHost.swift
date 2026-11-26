import CShell
import Foundation
import LinuxReader
import VellumCore

/// The GTK stack and reader window outlive this host. All WebKit callbacks
/// execute on that same thread. Requests synchronously take their own byte copy.
@MainActor
final class WebPageHost {
    struct PageMessage: Decodable {
        let uri: String
        let anchor: String?
        let width, height: Int?
        let event, excerpt: String?
        let position: ReadingPosition?
    }

    private static func script(restoring position: ReadingPosition?) -> String {
        // JSONEncoder quotes all peer-provided strings before they enter this isolated world.
        let saved = position.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        return """
        addEventListener('load', () => {
            const saved = \(saved);
            const extent = () => Math.max(0, document.scrollingElement.scrollHeight - innerHeight);
            function restore() {
                if (!saved) return;
                const prefix = saved.anchor_prefix ?? '', suffix = saved.anchor_suffix ?? '';
                const quote = prefix + suffix;
                if (quote) {
                    const nodes = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
                    for (let i = 0, node; i < 50000 && (node = nodes.nextNode()); i++) {
                        const start = node.data.indexOf(quote);
                        if (start < 0) continue;
                        const range = document.createRange();
                        range.setStart(node, start + prefix.length);
                        range.collapse(true);
                        const rect = range.getBoundingClientRect();
                        if (!rect.height) continue;
                        scrollBy(0, rect.top - (saved.viewport_offset ?? 0));
                        return;
                    }
                }
                scrollTo(0, extent() * (saved.scroll_fraction ?? 0));
            }
            window.vellumLocation = () => {
                if (!innerHeight) return null;
                const range = document.caretRangeFromPoint(innerWidth / 2, Math.min(32, innerHeight / 2));
                const location = {page: 1, page_count: 1,
                    scroll_fraction: Math.min(1, Math.max(0, scrollY / (extent() || 1)))};
                if (range?.startContainer.nodeType === Node.TEXT_NODE) {
                    const node = range.startContainer, index = range.startOffset;
                    location.anchor_prefix = node.data.slice(Math.max(0, index - 48), index);
                    location.anchor_suffix = node.data.slice(index, index + 48);
                    location.viewport_offset = range.getBoundingClientRect().top;
                }
                return location;
            };
            restore();
            addEventListener('scroll', () => {
                window.webkit.messageHandlers.vellum.postMessage({
                    uri: location.href.split('#')[0], event: 'location', position: window.vellumLocation()
                });
            }, {passive:true});
            const img = document.images[0];
            const text = document.querySelector('p, h1')?.textContent ?? '';
            window.webkit.messageHandlers.vellum.postMessage({
                uri: location.href.split('#')[0], anchor: text.slice(0, 256),
                width: img?.naturalWidth ?? 0, height: img?.naturalHeight ?? 0,
                excerpt: (document.body?.innerText ?? '').slice(0, 12000)
            });
        }, {once: true});
        """
    }

    private final class LocationReply {
        let continuation: CheckedContinuation<ReadingPosition?, Never>
        init(_ continuation: CheckedContinuation<ReadingPosition?, Never>) { self.continuation = continuation }
    }

    func location() async -> ReadingPosition? {
        guard let reader else { return nil }
        return await withCheckedContinuation { continuation in
            web_reader_location(reader, { owner, json in
                let reply = Unmanaged<LocationReply>.fromOpaque(owner!).takeRetainedValue()
                let value = json.flatMap { try? JSONDecoder().decode(
                    ReadingPosition.self, from: Data(String(cString: $0).utf8)) }
                reply.continuation.resume(returning: value)
            }, Unmanaged.passRetained(LocationReply(continuation)).toOpaque())
        }
    }

    private let resources: ArchiveResourceMap
    var session: ReaderPositionSession?
    private let onReady: (String) -> Void
    private let probe: WebProbe?
    private var reader: OpaquePointer?

    init(stack: OpaquePointer, resources: ArchiveResourceMap, probe: WebProbe?,
         restoring: ReadingPosition?, session: ReaderPositionSession?, onReady: @escaping (String) -> Void) {
        self.session = session
        self.resources = resources
        self.onReady = onReady
        self.probe = probe
        let script = Self.script(restoring: restoring) + (probe?.nextScript(for: resources.documentURL) ?? "")
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
                if body.event == "location", let position = body.position { host.session?.moved(position); return }
                if body.event == nil { host.onReady(body.excerpt ?? "") }
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
