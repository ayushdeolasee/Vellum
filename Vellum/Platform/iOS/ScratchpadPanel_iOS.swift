#if os(iOS)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import WebKit
import ImageIO

/// Sidebar tab for free-form Markdown + LaTeX notes tied to the active
/// document. A single Obsidian-style live-preview editor renders every line
/// except the one under the cursor, which shows raw Markdown source. The text
/// persists per-document via `ScratchpadStore`.
///
/// Images enter the note two ways: a drag-to-crop region snapshot of the PDF
/// (the camera button arms `.snapshotRegion` mode over the page; the touch
/// overlay lands in Phase 6) and external images dropped onto the panel. Both
/// write bytes to `ScratchpadAttachmentStore` and append a lightweight
/// `![](vellum-scratchpad://id)` reference the editor resolves through its
/// WebView scheme handler. The iPad analogue of the macOS `ScratchpadPanel` —
/// AppKit drag/`NSViewRepresentable`/`NSColor` become UIDropInteraction/
/// `UIViewRepresentable`/`UIColor`, but the `vellum-scratchpad://` scheme
/// handler and the message-handler bridge are structured exactly as on macOS.
struct ScratchpadPanel: View {
    @Environment(ScratchpadStore.self) private var scratchpadStore
    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    /// True only while a capture *this* panel armed is in flight — the AI panel
    /// arms the same `.snapshotRegion` mode, and its crop must not light up the
    /// scratchpad's crop button.
    private var isCapturingRegion: Bool {
        appStore.mode == .snapshotRegion && appStore.regionCaptureTarget == .scratchpad
    }

    @State private var dropTargeted = false

    var body: some View {
        @Bindable var store = scratchpadStore
        return VStack(spacing: 0) {
            header
            ScratchpadLiveEditor(
                text: $store.text,
                store: scratchpadStore,
                fontSize: workspace.sidebarFontSize,
                palette: palette
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(palette.primary, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    .padding(4)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if let warning = scratchpadStore.dropWarning {
                dropWarningBanner(warning)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: scratchpadStore.dropWarning)
        // Accept any drag so a non-image drop reaches `handleDrop` and can be
        // explained, rather than silently rejected. (The WebView covers the
        // editor body; this catches drops on the header/margins.)
        .onDrop(of: [.item], isTargeted: $dropTargeted, perform: handleDrop)
    }

    private func dropWarningBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(palette.destructive)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(palette.foreground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(palette.destructive.opacity(0.35))
        }
        .accessibilityIdentifier("scratchpad.dropWarning")
    }

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.primary)
                Text("Scratchpad")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
                    .fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            if appStore.document != nil {
                IconButton(
                    variant: isCapturingRegion ? .active : .ghost,
                    help: "Snapshot a region of the page into the note",
                    action: toggleSnapshotRegion
                ) {
                    Image(systemName: "crop").font(.system(size: 15))
                }
                .accessibilityIdentifier("scratchpad.snapshotRegion")
                .accessibilityAddTraits(isCapturingRegion ? .isSelected : [])
            }
            IconButton(help: "Clear scratchpad", action: clear) {
                Image(systemName: "trash").font(.system(size: 15))
            }
            .accessibilityIdentifier("scratchpad.clear")
        }
        .foregroundStyle(palette.foreground)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func toggleSnapshotRegion() {
        if isCapturingRegion {
            appStore.setMode(.view)
        } else {
            appStore.beginRegionCapture(target: .scratchpad)
        }
    }

    private func clear() {
        scratchpadStore.text = ""
    }

    /// Load each dropped image, normalize it (see `scratchpadCapture(from:)`),
    /// and append it to the note. Returns true when at least one provider is an
    /// image we can take.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let imageProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        guard !imageProviders.isEmpty else {
            // A non-image was dropped on the header/margin — explain why nothing
            // happened (the WebView takes image drops on the editor body itself).
            scratchpadStore.warnUnsupportedDrop()
            return true
        }
        let store = scratchpadStore
        for provider in imageProviders {
            loadScratchpadCapture(from: provider) { capture in
                guard let capture else { return }
                Task { @MainActor in store.addImage(capture, label: "Image") }
            }
        }
        return true
    }
}

/// Load the best image representation from `provider` and normalize it. Prefers
/// a concrete registered image type over the abstract `public.image` so a
/// provider that only advertises a subtype (PNG/HEIC/…) still resolves.
func loadScratchpadCapture(
    from provider: NSItemProvider,
    completion: @escaping (ScratchpadImageCapture?) -> Void
) {
    let identifier = provider.registeredTypeIdentifiers.first {
        UTType($0)?.conforms(to: .image) == true
    } ?? UTType.image.identifier
    // The data completion runs off-main; normalize there so a large image can't
    // stall the caller, then hand the capture back on the same off-main hop —
    // callers re-hop to the main actor themselves before touching UI/stores.
    let box = UncheckedSendableBox(completion)
    provider.loadDataRepresentation(forTypeIdentifier: identifier) { data, _ in
        box.value(data.flatMap { scratchpadCapture(from: $0) })
    }
}

/// Ferries a non-`Sendable` completion across the `@Sendable`
/// `loadDataRepresentation` boundary. Safe here: the closure is invoked exactly
/// once and its captured state (a store / a weak view) is only touched after the
/// callers re-hop to the main actor.
private struct UncheckedSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Normalize dropped image bytes into a `ScratchpadImageCapture`: keep small
/// PNG/JPEG/GIF originals verbatim, and re-encode everything else (or anything
/// larger than 2000px on its long side) — PNG when it has alpha, JPEG when
/// opaque — so attachments stay a sane size and format. iOS twin of the macOS
/// `NSBitmapImageRep` path: dimensions come from ImageIO, resize/encode from
/// `UIGraphicsImageRenderer`.
func scratchpadCapture(from data: Data) -> ScratchpadImageCapture? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
          let w = props[kCGImagePropertyPixelWidth] as? Int,
          let h = props[kCGImagePropertyPixelHeight] as? Int,
          w > 0, h > 0 else { return nil }
    let cap = 2000
    let maxSide = max(w, h)

    let isPNG = data.starts(with: [0x89, 0x50, 0x4E, 0x47])
    let isJPEG = data.starts(with: [0xFF, 0xD8, 0xFF])
    let isGIF = data.starts(with: [0x47, 0x49, 0x46])
    if maxSide <= cap {
        if isGIF {
            return ScratchpadImageCapture(
                data: data, fileExtension: "gif", mediaType: "image/gif",
                width: w, height: h, pageNumber: nil)
        }
        if isPNG {
            return ScratchpadImageCapture(
                data: data, fileExtension: "png", mediaType: "image/png",
                width: w, height: h, pageNumber: nil)
        }
        if isJPEG {
            return ScratchpadImageCapture(
                data: data, fileExtension: "jpg", mediaType: "image/jpeg",
                width: w, height: h, pageNumber: nil)
        }
    }

    guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
    let alpha = cgImage.alphaInfo
    let hasAlpha = !(alpha == .none || alpha == .noneSkipLast || alpha == .noneSkipFirst)
    let scale = maxSide > cap ? Double(cap) / Double(maxSide) : 1
    let tw = max(1, Int((Double(w) * scale).rounded()))
    let th = max(1, Int((Double(h) * scale).rounded()))

    let size = CGSize(width: tw, height: th)
    let format = UIGraphicsImageRendererFormat.default()
    format.scale = 1
    format.opaque = !hasAlpha
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    let rendered = renderer.image { ctx in
        if !hasAlpha {
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
        UIImage(cgImage: cgImage).draw(in: CGRect(origin: .zero, size: size))
    }

    if hasAlpha, let png = rendered.pngData() {
        return ScratchpadImageCapture(
            data: png, fileExtension: "png", mediaType: "image/png",
            width: tw, height: th, pageNumber: nil)
    }
    guard let jpeg = rendered.jpegData(compressionQuality: 0.85) else { return nil }
    return ScratchpadImageCapture(
        data: jpeg, fileExtension: "jpg", mediaType: "image/jpeg",
        width: tw, height: th, pageNumber: nil)
}

/// Resolves `vellum-scratchpad://<id>` image requests from the editor WebView
/// by streaming the attachment file's bytes back. Stateless — the id maps to a
/// flat file in `ScratchpadAttachmentStore`, so it needs no document context.
final class ScratchpadAttachmentSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let id = url.host ?? url.lastPathComponent
        guard let fileURL = ScratchpadAttachmentStore.fileURL(for: id),
              let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = ScratchpadAttachmentStore.mediaType(forExtension: fileURL.pathExtension)
        let response = URLResponse(
            url: url, mimeType: mime,
            expectedContentLength: data.count, textEncodingName: nil)
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

// MARK: - Live-preview editor

/// Marker subclass so the hardware-keyboard command guard (`VellumCommands_iOS`)
/// can recognize when keyboard focus is inside the scratchpad editor by walking
/// the first responder's view ancestry. Editing happens in a private WebKit
/// content view, so there is no `UITextView`/`UITextField` to detect directly;
/// spotting this enclosing WebView is how the guard knows to let bare-key
/// shortcuts (e.g. `N` for note mode) fall through to the editor instead of
/// firing the app command.
///
/// It also owns the image-drop interaction over the editor body: WKWebView
/// registers its own drop handling, so a SwiftUI `.onDrop` never sees drops
/// that land on the web content. We install an explicit `UIDropInteraction`
/// (do-not-reintroduce #11 — embedded UIKit views swallow drops) that claims
/// only image drops and appends them to the note; non-image drops fall through
/// to WebKit untouched.
final class ScratchpadWebView: WKWebView, UIDropInteractionDelegate {
    var onImageDrop: ((ScratchpadImageCapture) -> Void)?

    func installImageDrop() {
        addInteraction(UIDropInteraction(delegate: self))
    }

    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool {
        session.hasItemsConforming(toTypeIdentifiers: [UTType.image.identifier])
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        for item in session.items {
            let provider = item.itemProvider
            guard provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) else { continue }
            // Decode/resize/encode off the main thread (loadDataRepresentation's
            // completion already runs off-main) so a large drop can't stall the
            // UI, then report back on the main queue — mirroring the SwiftUI
            // item-provider path.
            loadScratchpadCapture(from: provider) { [weak self] capture in
                guard let capture else { return }
                DispatchQueue.main.async { self?.onImageDrop?(capture) }
            }
        }
    }
}

/// CodeMirror 6 editor hosted in an offline `WKWebView`. The bundled
/// `Resources/katex` folder holds the editor bundle, KaTeX, and marked — no
/// network. Swift pushes content + theme in; the editor posts back `ready` and
/// `change` messages. Two-way sync guards against echo loops so typing never
/// resets the caret.
private struct ScratchpadLiveEditor: UIViewRepresentable {
    @Binding var text: String
    let store: ScratchpadStore
    let fontSize: Double
    let palette: ThemePalette

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(context.coordinator, name: "scratchpad")
        config.userContentController = controller
        // Serve `vellum-scratchpad://<id>` image references from disk. The
        // configuration retains the handler, so a fresh instance is fine.
        config.setURLSchemeHandler(
            ScratchpadAttachmentSchemeHandler(),
            forURLScheme: ScratchpadAttachmentStore.scheme)

        let webView = ScratchpadWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent background so the editor blends into the sidebar surface
        // (the iOS analogue of AppKit's `drawsBackground = false`).
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.installImageDrop()
        context.coordinator.webView = webView

        // Route snapshot/drop insertions from the store into the editor.
        store.insertMarkdownHandler = { [weak coordinator = context.coordinator] markdown in
            coordinator?.enqueueInsert(markdown)
        }
        // Images dropped onto the editor body are consumed by the WebView (it
        // owns its own drop interaction, ahead of SwiftUI's onDrop).
        webView.onImageDrop = { [weak store] capture in
            store?.addImage(capture, label: "Image")
        }

        if let url = Self.templateURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(text: text, fontSize: fontSize, palette: palette)
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.parent.store.insertMarkdownHandler = nil
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "scratchpad")
    }

    private static var templateURL: URL? {
        Bundle.main.url(forResource: "editor", withExtension: "html", subdirectory: "katex")
            ?? Bundle.main.url(forResource: "editor", withExtension: "html")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: ScratchpadLiveEditor
        weak var webView: WKWebView?

        private var isReady = false
        /// The text the editor currently holds (last pushed or last reported).
        /// Guards the sync loop: a SwiftUI re-render triggered by a `change`
        /// message must not push the same text back and reset the caret.
        private var editorText: String?
        private var pendingText: String?
        private var pendingStyle: (fontSize: Double, palette: ThemePalette)?
        /// The style last handed to the editor. `apply` runs on every keystroke,
        /// so we diff against this and only re-queue a `setTheme` when the font
        /// size or a themed color actually changed — mirroring the `pendingText`
        /// guard rather than pushing JS on every character.
        private var appliedStyleKey: String?
        /// Markdown snippets to append once the editor is ready. Buffered so a
        /// snapshot/drop that lands before `ready` isn't dropped on the floor.
        private var pendingInserts: [String] = []

        init(parent: ScratchpadLiveEditor) { self.parent = parent }

        func apply(text: String, fontSize: Double, palette: ThemePalette) {
            let styleKey = "\(Int(fontSize))|\(hex(palette.foreground))|" +
                "\(hex(palette.mutedForeground))|\(hex(palette.primary))|\(hex(palette.destructive))"
            if styleKey != appliedStyleKey {
                appliedStyleKey = styleKey
                pendingStyle = (fontSize, palette)
            }
            if text != editorText { pendingText = text }
            flush()
        }

        /// Queue a markdown block for insertion at the end of the note. The
        /// resulting edit comes back as a `change` message, so `text` and
        /// persistence update through the normal path.
        func enqueueInsert(_ markdown: String) {
            pendingInserts.append(markdown)
            flush()
        }

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                if pendingText == nil { pendingText = parent.text }
                flush()
            case "change":
                guard let text = body["text"] as? String else { return }
                editorText = text
                if parent.text != text { parent.text = text }
            default:
                break
            }
        }

        private func flush() {
            guard isReady, let webView else { return }
            if let style = pendingStyle {
                pendingStyle = nil
                let p = style.palette
                let js = "window.ScratchpadEditor.setTheme({" +
                    "fg:\(jsString(hex(p.foreground)))," +
                    "muted:\(jsString(hex(p.mutedForeground)))," +
                    "accent:\(jsString(hex(p.primary)))," +
                    "err:\(jsString(hex(p.destructive)))," +
                    "fontSize:\(Int(style.fontSize))});"
                webView.evaluateJavaScript(js)
            }
            if let text = pendingText {
                pendingText = nil
                editorText = text
                webView.evaluateJavaScript("window.ScratchpadEditor.setContent(\(jsString(text)));")
            }
            if !pendingInserts.isEmpty {
                let inserts = pendingInserts
                pendingInserts = []
                for markdown in inserts {
                    webView.evaluateJavaScript(
                        "window.ScratchpadEditor.insertSnippet(\(jsString(markdown)));")
                }
            }
        }

        /// JSON-encode a string into a safely escaped JS string literal.
        private func jsString(_ value: String) -> String {
            guard let data = try? JSONEncoder().encode(value),
                  let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
            return literal
        }

        private func hex(_ color: Color) -> String {
            let ui = UIColor(color)
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ui.getRed(&r, green: &g, blue: &b, alpha: &a)
            let ri = min(255, max(0, Int((r * 255).rounded())))
            let gi = min(255, max(0, Int((g * 255).rounded())))
            let bi = min(255, max(0, Int((b * 255).rounded())))
            return String(format: "#%02x%02x%02x", ri, gi, bi)
        }
    }
}
#endif
