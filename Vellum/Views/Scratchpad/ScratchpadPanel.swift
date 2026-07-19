import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Sidebar tab for free-form Markdown + LaTeX notes tied to the active
/// document. A single Obsidian-style live-preview editor renders every line
/// except the one under the cursor, which shows raw Markdown source. The text
/// persists per-document via `ScratchpadStore`.
///
/// Images enter the note two ways: a drag-to-crop region snapshot of the PDF
/// (the camera button arms `.snapshotRegion` mode over the page) and external
/// images dropped onto the panel. Both write bytes to `ScratchpadAttachmentStore`
/// and append a lightweight `![](vellum-scratchpad://id)` reference the editor
/// resolves through its WebView scheme handler.
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

    var body: some View {
        @Bindable var store = scratchpadStore
        return VStack(spacing: 0) {
            header
            ScratchpadLiveEditor(
                text: $store.text,
                store: scratchpadStore,
                fontSize: workspace.sidebarFontSize,
                palette: palette,
                dropsEnabled: workspace.sidebarTab == .scratchpad
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The drop outline and the whole-area drag destination live on the sidebar
        // container (`SidebarDropCatcher` in `SidebarPanelStack`), which routes
        // drops here via `scratchpadStore.handleDrop`; the editor WebView's own
        // drop overrides remain as belt-and-braces but are unreachable while the
        // frontmost catcher is present. Only the transient "unsupported drop"
        // banner is panel-local.
        .overlay(alignment: .bottom) {
            if let warning = scratchpadStore.dropWarning {
                dropWarningBanner(warning)
                    .padding(12)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: scratchpadStore.dropWarning)
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

}

/// Normalize dropped image bytes into a `ScratchpadImageCapture`: keep small
/// PNG/JPEG/GIF originals verbatim, and re-encode everything else (or anything
/// larger than 2000px on its long side) — PNG when it has alpha, JPEG when
/// opaque — so attachments stay a sane size and format.
func scratchpadCapture(from data: Data) -> ScratchpadImageCapture? {
    guard let rep = NSBitmapImageRep(data: data) else { return nil }
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard w > 0, h > 0 else { return nil }
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

    let scale = maxSide > cap ? Double(cap) / Double(maxSide) : 1
    let tw = max(1, Int((Double(w) * scale).rounded()))
    let th = max(1, Int((Double(h) * scale).rounded()))
    let hasAlpha = rep.hasAlpha
    guard let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: tw, pixelsHigh: th,
        bitsPerSample: 8, samplesPerPixel: hasAlpha ? 4 : 3, hasAlpha: hasAlpha,
        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ), let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    let target = NSRect(x: 0, y: 0, width: tw, height: th)
    if !hasAlpha {
        NSColor.white.setFill()
        target.fill()
    }
    _ = rep.draw(in: target)
    NSGraphicsContext.restoreGraphicsState()

    if hasAlpha, let png = out.representation(using: .png, properties: [:]) {
        return ScratchpadImageCapture(
            data: png, fileExtension: "png", mediaType: "image/png",
            width: tw, height: th, pageNumber: nil)
    }
    guard let jpeg = out.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    else { return nil }
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

/// Marker subclass so the app-level key monitor (`ContentView.handleKeyDown`)
/// can recognize when keyboard focus is inside the scratchpad editor by walking
/// the first responder's view ancestry. Editing happens in a private WebKit
/// content view, so there is no `NSTextView`/`NSTextField` to detect directly;
/// spotting this enclosing WebView is how the monitor knows to let bare-key
/// shortcuts (e.g. `N` for note mode) fall through to the editor.
final class ScratchpadWebView: WKWebView {
    /// Consume an image dropped onto the editor body. The WebView (not the
    /// SwiftUI `.onDrop`) is the drag destination over its own area — AppKit
    /// routes a drop to the topmost registered view under the cursor, which is
    /// this WebView. The scratchpad only accepts images, so we take over every
    /// drop here (no `super` fall-through to WebKit's own drag handling) and
    /// route anything that isn't a usable image to `onUnsupportedDrop`.
    var onImageDrop: ((ScratchpadImageCapture) -> Void)?
    /// Called when a non-image (or undecodable image) is dropped, so the panel
    /// can tell the user only image files are accepted.
    var onUnsupportedDrop: (() -> Void)?

    /// False while another sidebar tab is in front. The panels stay mounted in
    /// a ZStack with the scratchpad frontmost, and SwiftUI's `opacity(0)` /
    /// `allowsHitTesting(false)` on the hidden panel do NOT remove this
    /// WKWebView from AppKit's drag-destination search — WebKit registers its
    /// own dragged types, so the invisible editor still outranks the visible
    /// AI panel beneath it and silently swallows every drop aimed there.
    /// Unregistering while hidden lets the drag fall through to the panel the
    /// user can actually see.
    ///
    /// Defaults to `false` so the view starts drag-transparent: `WKWebView.init`
    /// and the first navigation both register WebKit's own dragged types, and
    /// that happens before SwiftUI's first `updateNSView` sets the real value.
    /// Starting `false` means the `registerForDraggedTypes` override below
    /// refuses those early registrations at the source, so there is never a
    /// window — however brief — where the freshly-created hidden editor is a
    /// live drop target. `ScratchpadLiveEditor.updateNSView` flips this to
    /// `true` only when the scratchpad is the visible tab.
    var acceptsDrops = false {
        didSet {
            guard acceptsDrops != oldValue else { return }
            if acceptsDrops {
                registerForDraggedTypes(Self.scratchpadDraggedTypes)
            } else {
                unregisterDraggedTypes()
            }
        }
    }

    /// The single choke point for becoming an AppKit drag destination: every
    /// `registerForDraggedTypes(_:)` — ours in `acceptsDrops.didSet` AND the
    /// ones WebKit fires on its own — funnels through here.
    ///
    /// WebKit re-registers its own dragged types out of our sight: after the
    /// content process connects, after each navigation, and when the view
    /// enters a real (key, on-screen) window — none of which a headless probe
    /// reproduces, which is why the offscreen test saw an empty registration
    /// and the live app did not. A one-shot `unregisterDraggedTypes()` when the
    /// tab hides can't hold: WebKit simply re-registers afterward, the invisible
    /// editor (frontmost in ContentView's ZStack, above the AI panel) becomes a
    /// drag destination again, and AppKit — which routes a drop to the topmost
    /// *registered* view by geometry, ignoring SwiftUI's `opacity(0)` /
    /// `allowsHitTesting(false)` — hands it every drop meant for the AI panel
    /// underneath, where `draggingEntered` returns `[]` and the drop dies.
    ///
    /// Refusing the registration at the source is the durable fix: while hidden
    /// this view can never re-arm itself as a destination, so drops fall through
    /// to the visible AI panel. When visible, registration is allowed and the
    /// editor's own image-drop path (all destination methods overridden, no
    /// `super`) works as before.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        guard acceptsDrops else { return }
        super.registerForDraggedTypes(newTypes)
    }

    /// What the editor's own drop handling consumes (all destination methods
    /// are overridden with no `super` fall-through, so WebKit's internal drag
    /// types don't matter): image files from Finder, raw bytes from Preview or
    /// a browser.
    static let scratchpadDraggedTypes: [NSPasteboard.PasteboardType] = [.fileURL, .png, .tiff, .URL]

    // Accept every drag so the drop is delivered to `performDragOperation`,
    // where we decide whether it's a usable image. (Returning `[]` for
    // non-images would suppress the drop event and we couldn't warn.) The
    // `acceptsDrops` guard is belt-and-braces for the hidden-panel case, in
    // case WebKit re-registers its own types behind our back.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrops ? .copy : []
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        acceptsDrops ? .copy : []
    }
    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { acceptsDrops }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard acceptsDrops else { return false }
        // Read the pasteboard on the main thread (it's tied to the drag event),
        // but push the heavy decode/resize/encode off it so a large drop can't
        // stall the UI — mirroring the SwiftUI item-provider path — then report
        // back on the main queue.
        guard let data = droppedImageData(sender) else {
            onUnsupportedDrop?()
            return true
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let capture = scratchpadCapture(from: data)
            DispatchQueue.main.async {
                guard let self else { return }
                if let capture {
                    self.onImageDrop?(capture)
                } else {
                    self.onUnsupportedDrop?()
                }
            }
        }
        return true
    }

    /// Image bytes on the drag pasteboard: a dropped image file (Finder), or
    /// raw image data (dragged from Preview / a browser). Nil for anything else.
    private func droppedImageData(_ sender: NSDraggingInfo) -> Data? {
        let pasteboard = sender.draggingPasteboard
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier],
        ]
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
           let url = urls.first, let data = try? Data(contentsOf: url) {
            return data
        }
        if let image = NSImage(pasteboard: pasteboard) {
            return image.tiffRepresentation
        }
        return nil
    }
}

/// CodeMirror 6 editor hosted in an offline `WKWebView`. The bundled
/// `Resources/katex` folder holds the editor bundle, KaTeX, and marked — no
/// network. Swift pushes content + theme in; the editor posts back `ready` and
/// `change` messages. Two-way sync guards against echo loops so typing never
/// resets the caret.
private struct ScratchpadLiveEditor: NSViewRepresentable {
    @Binding var text: String
    let store: ScratchpadStore
    let fontSize: Double
    let palette: ThemePalette
    /// Whether the scratchpad is the visible sidebar tab — see
    /// `ScratchpadWebView.acceptsDrops`.
    let dropsEnabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WKWebView {
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
        webView.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = webView

        // Route snapshot/drop insertions from the store into the editor.
        installInsertHandler(on: store, coordinator: context.coordinator)
        // Images dropped onto the editor body are consumed by the WebView (it
        // is the drag destination over its own area, ahead of SwiftUI's onDrop).
        webView.onImageDrop = { [weak store] capture in
            store?.addImage(capture, label: "Image")
        }
        webView.onUnsupportedDrop = { [weak store] in
            store?.warnUnsupportedDrop()
        }

        if let url = Self.templateURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // Re-assert this coordinator as the store's insert owner. Covers two
        // cases: (1) the focused-pane store swaps underneath a stable editor
        // (split-screen focus change is an update, not a remake, so makeNSView
        // never re-runs for the new store), and (2) the live editor reclaiming
        // ownership after any transient remake churn — so the store's handler
        // always points at the editor the user is actually looking at.
        installInsertHandler(on: store, coordinator: context.coordinator)
        (webView as? ScratchpadWebView)?.acceptsDrops = dropsEnabled
        context.coordinator.apply(text: text, fontSize: fontSize, palette: palette)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        // Only relinquish the store's handler if THIS coordinator still owns it.
        // SwiftUI builds a replacement editor (whose makeNSView installs a fresh
        // handler) before dismantling the old one; clearing unconditionally here
        // would wipe that fresh handler, and a dropped image would save to disk
        // yet never appear in the note (with no warning). The identity guard keeps
        // the live editor's handler intact.
        let store = coordinator.parent.store
        if store.insertMarkdownOwner === coordinator {
            store.insertMarkdownHandler = nil
            store.insertMarkdownOwner = nil
        }
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "scratchpad")
    }

    /// Point `store.insertMarkdownHandler` at `coordinator` and record it as the
    /// owner. Called from both `makeNSView` and `updateNSView` so the store's
    /// handler tracks the current editor even when SwiftUI reuses the view across
    /// a store swap; `dismantleNSView` uses the recorded owner to avoid wiping a
    /// newer editor's handler.
    private func installInsertHandler(on store: ScratchpadStore, coordinator: Coordinator) {
        store.insertMarkdownHandler = { [weak coordinator] markdown in
            coordinator?.enqueueInsert(markdown)
        }
        store.insertMarkdownOwner = coordinator
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
            let ns = NSColor(color).usingColorSpace(.sRGB) ?? .black
            let r = Int((ns.redComponent * 255).rounded())
            let g = Int((ns.greenComponent * 255).rounded())
            let b = Int((ns.blueComponent * 255).rounded())
            return String(format: "#%02x%02x%02x", r, g, b)
        }
    }
}
