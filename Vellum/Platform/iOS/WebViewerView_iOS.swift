#if os(iOS)
import Observation
import SwiftUI
import UIKit
import WebKit

// Touch web reading mode — iPad port of Vellum/Views/Web/WebViewerView.swift.
// Same bridge contract (VellumWebSchemeHandler + WebContentScript +
// WKScriptMessageHandler named "vellum"), rehosted on UIKit: WKWebView inside
// a UIViewRepresentable, store handlers registered/unregistered the same way
// PdfViewerView_iOS does it. Annotation UI (selection popover, note
// composer/viewer, highlight editor, context menu) mirrors the macOS
// controller; the only structural difference is there's no NSEvent monitor —
// touch has no hover/click-outside concept, so context-menu / popover
// dismissal relies entirely on the "selection-cleared" grace-period logic and
// "viewport-scrolled", exactly as the macOS handlers already do.

struct WebViewerView_iOS: View {
    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(ScratchpadStore.self) private var scratchpadStore
    @Environment(\.palette) private var palette

    @State private var controller = WebViewerController_iOS()

    var body: some View {
        if app.document?.kind == .web {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    WebViewRepresentable_iOS(controller: controller)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Drag-to-crop region snapshot. The scrim intercepts the
                    // drag before the web view sees it; WKWebView.takeSnapshot
                    // renders page content only, so the marquee itself can never
                    // land inside the crop. Routes per AppStore.regionCaptureTarget.
                    if app.mode == .snapshotRegion {
                        RegionCaptureOverlay_iOS { rect in
                            captureRegion(rect)
                            app.setMode(.view)
                        } onCancel: {
                            app.setMode(.view)
                        }
                        .zIndex(60)
                    }

                    if controller.isOffline {
                        offlineBadge
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.trailing, 12)
                            .padding(.top, 12)
                    }

                    // The pinned note draft keeps the popover mounted while its
                    // note field has focus — by then the DOM selection is gone
                    // (WebKit drops it when the WKWebView resigns first
                    // responder; see selectionNoteDraft).
                    if controller.selection != nil || controller.selectionNoteDraft != nil,
                       let position = controller.popoverPosition {
                        WebSelectionPopover(
                            position: position,
                            onHighlight: { color in controller.addHighlight(color: color) },
                            onNote: { content in controller.addSelectionNote(content: content) },
                            onBeginNote: { controller.beginSelectionNote() },
                            onAskAi: { controller.askAiAboutSelection() },
                            onClose: { controller.clearSelection() }
                        )
                        // Rekey on the bound passage so a new selection tears the
                        // popover down (dropping a half-typed note) instead of
                        // inheriting the previous one's field text.
                        .id(controller.selectionIdentity)
                        .zIndex(50)
                    }

                    if let menu = controller.contextMenu {
                        AnchoredPopover(
                            x: menu.point.x, y: menu.point.y,
                            placement: .menu, containerSize: proxy.size
                        ) {
                            WebContextMenuView(
                                canAddNote: menu.anchor != nil,
                                onAddNote: { controller.contextMenuAddNote() })
                        }
                        .zIndex(50)
                    }

                    if let composer = controller.noteComposer {
                        AnchoredPopover(
                            x: composer.point.x, y: composer.point.y,
                            placement: .below, containerSize: proxy.size
                        ) {
                            WebNoteComposerView(
                                onSubmit: { content in
                                    controller.createAnchoredNote(anchor: composer.anchor, content: content)
                                    controller.closeNoteComposer()
                                },
                                onClose: { controller.closeNoteComposer() })
                        }
                        .zIndex(50)
                    }

                    if let editor = controller.highlightEditor,
                       let annotation = annotationStore.annotations.first(where: {
                           $0.id == editor.id && $0.type == .highlight
                       }) {
                        AnchoredPopover(
                            x: editor.point.x, y: editor.point.y,
                            placement: .above, containerSize: proxy.size
                        ) {
                            HighlightEditPopover(
                                annotation: annotation,
                                onDelete: { controller.closeHighlightEditor() })
                                // The overlay proposes the full container width;
                                // hug the swatch row instead.
                                .fixedSize()
                        }
                        .zIndex(50)
                    }

                    if let viewer = controller.noteViewer {
                        AnchoredPopover(
                            x: viewer.point.x, y: viewer.point.y,
                            placement: .above, containerSize: proxy.size
                        ) {
                            // Keyed by annotation so switching markers never
                            // carries one note's edit draft into another.
                            WebNoteViewerView(
                                annotationId: viewer.id,
                                onClose: { controller.closeNoteViewer() })
                                .id(viewer.id)
                        }
                        .zIndex(50)
                    }
                }
            }
            .background(palette.well)
            .clipped()
            .onAppear {
                controller.attach(app: app, annotationStore: annotationStore, aiStore: aiStore)
            }
            .onDisappear {
                controller.detach()
            }
            .onChange(of: controller.initCount) {
                controller.pushAnnotations(annotationStore.annotations)
                controller.pushMode(app.mode)
                controller.pushSelectedHighlight()
                controller.scrollToSelected(
                    annotations: annotationStore.annotations,
                    selectedId: annotationStore.selectedAnnotationId)
            }
            .onChange(of: annotationStore.annotations) {
                controller.pushAnnotations(annotationStore.annotations)
            }
            .onChange(of: app.mode) {
                controller.pushMode(app.mode)
            }
            // Observe the request counter too: re-tapping the already-selected
            // sidebar highlight leaves `selectedAnnotationId` unchanged, so the
            // counter is what forces the scroll-into-view to re-run.
            .onChange(of: annotationStore.selectedAnnotationId) {
                controller.scrollToSelected(
                    annotations: annotationStore.annotations,
                    selectedId: annotationStore.selectedAnnotationId)
            }
            .onChange(of: annotationStore.selectionRequestCount) {
                controller.scrollToSelected(
                    annotations: annotationStore.annotations,
                    selectedId: annotationStore.selectedAnnotationId)
            }
            .onChange(of: app.zoom) { _, zoom in
                controller.applyZoom(zoom)
            }
            .onReceive(NotificationCenter.default.publisher(for: .vellumWebHistory)) { note in
                let delta = note.userInfo?["delta"] as? Int ?? 0
                controller.goHistory(delta: delta)
            }
        } else {
            Color.clear
        }
    }

    /// Hand the finished crop to whichever panel armed the capture (mirrors
    /// PdfOverlayStack_iOS.captureRegion). The AI path stays silent on a miss —
    /// a failed takeSnapshot mid-scroll is not worth a banner; the scratchpad
    /// path warns, since its button is the one the user pressed to get here.
    private func captureRegion(_ rect: CGRect) {
        let sessionId = app.activeTabId
        switch app.regionCaptureTarget {
        case .ai:
            Task {
                // A web capture always stamps the virtual page it was taken on,
                // so the snapshot's optional page is always populated here.
                guard let snapshot = await controller.captureRegionImage(viewerRect: rect),
                      let page = snapshot.pageNumber,
                      app.activeTabId == sessionId else { return }
                aiStore.addReference(AiReference(kind: .region(image: snapshot, page: page)))
            }
        case .scratchpad:
            Task {
                if let capture = await controller.captureRegion(viewerRect: rect),
                   app.activeTabId == sessionId {
                    scratchpadStore.addImage(capture, label: "Web region")
                } else if app.activeTabId == sessionId {
                    scratchpadStore.warnRegionCaptureFailed()
                }
            }
        }
    }

    private var offlineBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 12))
            Text("Offline snapshot")
                .font(.system(size: 12))
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .zIndex(40)
    }
}

/// Hosts the controller's WKWebView. UIKit counterpart of the macOS
/// NSViewRepresentable — no AppKit involved.
private struct WebViewRepresentable_iOS: UIViewRepresentable {
    let controller: WebViewerController_iOS

    func makeUIView(context: Context) -> WKWebView {
        controller.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

// MARK: - Controller (the WebViewer bridge logic, iOS)

@MainActor
@Observable
final class WebViewerController_iOS: NSObject {
    // Counts inits from the document currently bound to this tab; 0 = nothing
    // loaded yet. A counter (not a boolean) so highlight application re-fires
    // after in-tab navigation replaces the document.
    private(set) var initCount = 0
    private(set) var isOffline = false
    private(set) var selection: WebSelection?
    private(set) var popoverPosition: CGPoint?
    /// The selection pinned while the selection popover's note field is open.
    /// Focusing that field moves first responder off the WKWebView, and WebKit
    /// drops the DOM selection whenever it resigns first responder — so by the
    /// time the note is submitted, `selection` is gone. Without the pin the
    /// resulting "selection-cleared" would also unmount the popover (and the
    /// half-typed note) mid-compose.
    private(set) var selectionNoteDraft: WebSelection?
    private(set) var noteComposer: WebNoteComposerState?
    private(set) var contextMenu: WebContextMenuState?
    private(set) var noteViewer: WebNoteViewerState?
    private(set) var highlightEditor: WebHighlightEditorState? {
        didSet {
            guard highlightEditor?.id != oldValue?.id else { return }
            pushSelectedHighlight()
        }
    }

    @ObservationIgnored private weak var app: AppStore?
    @ObservationIgnored private weak var annotationStore: AnnotationStore?
    @ObservationIgnored private weak var aiStore: AiStore?
    @ObservationIgnored private var mountTabId: String?
    @ObservationIgnored private var attached = false
    // Whether the injected content script supports point anchors (declared in
    // its init handshake).
    @ObservationIgnored private var supportsPositions = false
    // Auto-archive bookkeeping: the URL already archived this mount, and a
    // debounce task so the fullest text extraction wins.
    @ObservationIgnored private var archivedUrl: String?
    @ObservationIgnored private var archiveTask: Task<Void, Never>?
    // Target of an in-flight link navigation: late messages from the outgoing
    // document are ignored until the new document reports in.
    @ObservationIgnored private var pendingNavUrl: String?
    /// URL of the page being navigated away from — its late re-inits must be
    /// ignored during the transition, everything else is the new document.
    @ObservationIgnored private var outgoingNavUrl: String?
    // URL whose reading position has already been restored this mount.
    @ObservationIgnored private var restoredUrl: String?
    // One-shot guards: the URL already reloaded to chase a server redirect
    // (a redirect loop must not ping-pong the webview), and the URL already
    // reloaded after a web-content-process crash (second crash → snapshot).
    @ObservationIgnored private var redirectReloadedUrl: String?
    @ObservationIgnored private var processReloadedUrl: String?
    @ObservationIgnored private var pendingLocates: [String: (LocatedText?) -> Void] = [:]
    @ObservationIgnored private var pendingCaptures: [String: (CapturedWebPosition?) -> Void] = [:]

    @ObservationIgnored private lazy var _webView: WKWebView = makeWebView()
    var webView: WKWebView { _webView }

    /// Isolated content world for the bridge: the content script and the
    /// "vellum" message handler live here, out of reach of page scripts (a
    /// hostile page could otherwise post open-youtube/navigate messages or
    /// call __vellumCmd directly). Isolated worlds share the DOM, so all the
    /// script's overlays, selection handling, and the YouTube facade work
    /// unchanged.
    private static let bridgeWorld = WKContentWorld.world(name: "VellumBridge")

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let schemeHandler = VellumWebSchemeHandler()
        configuration.setURLSchemeHandler(
            schemeHandler, forURLScheme: VellumWebSchemeHandler.scheme)
        configuration.setURLSchemeHandler(
            schemeHandler, forURLScheme: VellumWebSchemeHandler.insecureScheme)
        configuration.userContentController.add(
            WeakScriptMessageHandler_iOS(self), contentWorld: Self.bridgeWorld, name: "vellum")
        // The content script is world-scoped, not inlined into the page HTML
        // (WebHtml.prepareHtml injects only the unprivileged page-world
        // bootstrap). Registered once: it runs on every main-frame load this
        // webview performs — live pages, snapshot fallbacks, and error pages
        // alike. .atDocumentEnd so the bootstrap's data- attributes are set;
        // the script's own start() waits for the load event regardless.
        configuration.userContentController.addUserScript(WKUserScript(
            source: WebContentScript.source,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.bridgeWorld))
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Native edge-swipe back/forward bypasses the session-rebind path
        // (navigateTo / handleInit), so drive history only through the toolbar
        // and the content-script bridge, matching the macOS viewer.
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    // MARK: Lifecycle

    func attach(app: AppStore, annotationStore: AnnotationStore, aiStore: AiStore) {
        guard !attached else { return }
        attached = true
        self.app = app
        self.annotationStore = annotationStore
        self.aiStore = aiStore
        mountTabId = app.activeTabId
        applyZoom(app.zoom)

        // Global hooks used by the toolbar, sidebar, and AI tool execution
        // (window.__scrollToPage / __scrollToWebPosition / __captureWebPosition
        // / __locateWebText in the original).
        app.scrollToPageHandler = { [weak self] page in
            self?.post("scroll-to-page", ["page": page])
        }
        app.scrollToWebPositionHandler = { [weak self] positionData, page in
            self?.scrollToWebPosition(positionData, page: page) ?? false
        }
        annotationStore.captureWebPositionHandler = { [weak self] in
            await self?.captureWebPosition()
        }
        aiStore.locateWebTextHandler = { [weak self] page, text in
            await self?.locateWebText(page: page, text: text)
        }
        // The requested page is ignored: a web "page" is a scroll range inside
        // one continuous document, not an independently renderable surface, so
        // the only thing we can snapshot is the visible viewport. Callers ask
        // for the current page anyway, and the snapshot stamps the page it
        // actually captured.
        aiStore.capturePageImageHandler = { [weak self] _ in
            await self?.capturePageImage()
        }
        app.findQueryHandler = { [weak self] query in
            self?.post("find", ["query": query])
        }
        app.findStepHandler = { [weak self] delta in
            self?.post("find-step", ["delta": delta])
        }
        app.findClearHandler = { [weak self] in
            self?.post("find-clear")
        }
        app.printHandler = { [weak self] in
            self?.printPage()
        }

        if let doc = app.document, doc.kind == .web {
            webView.load(URLRequest(url: VellumWebSchemeHandler.proxyUrl(for: doc.pdfPath)))
        }
    }

    func detach() {
        guard attached else { return }
        attached = false
        cancelPendingArchive()
        for resolve in pendingLocates.values { resolve(nil) }
        pendingLocates.removeAll()
        for resolve in pendingCaptures.values { resolve(nil) }
        pendingCaptures.removeAll()
        // Only clear the shared handler slots when no replacement viewer has
        // taken over (handlers hold self weakly, so a stale slot is inert).
        if let app, app.activeTabId == mountTabId || app.document == nil {
            app.scrollToPageHandler = nil
            app.scrollToWebPositionHandler = nil
            annotationStore?.captureWebPositionHandler = nil
            aiStore?.locateWebTextHandler = nil
            aiStore?.capturePageImageHandler = nil
            app.findQueryHandler = nil
            app.findStepHandler = nil
            app.findClearHandler = nil
            app.printHandler = nil
        }
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "vellum", contentWorld: Self.bridgeWorld)
        webView.stopLoading()
    }

    // MARK: Outbound commands

    func post(_ command: String, _ payload: [String: Any] = [:]) {
        var message = payload
        message["vellumCmd"] = command
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        // Evaluated in the bridge world — __vellumCmd only exists there.
        webView.evaluateJavaScript(
            "window.__vellumCmd && window.__vellumCmd(\(json));",
            in: nil, in: Self.bridgeWorld)
    }

    func applyZoom(_ zoom: Double) {
        webView.pageZoom = CGFloat(zoom)
    }

    func goHistory(delta: Int) {
        post("history", ["delta": delta])
    }

    // MARK: Navigation controls (toolbar back/forward/reload)

    func goBack() {
        guard webView.canGoBack else { return }
        webView.goBack()
    }

    func goForward() {
        guard webView.canGoForward else { return }
        webView.goForward()
    }

    func reload() {
        webView.reload()
    }

    /// Print the rendered page via WKWebView's print formatter. WKWebView has
    /// no printOperation equivalent on iOS, so UIPrintInteractionController
    /// is driven with the web view's own UIPrintFormatter, presented
    /// non-blocking from the shared UIPrintInteractionController.
    func printPage() {
        let printController = UIPrintInteractionController.shared
        let printInfo = UIPrintInfo(dictionary: nil)
        printInfo.outputType = .general
        printInfo.jobName = app?.document?.title ?? "Document"
        printController.printInfo = printInfo
        printController.printFormatter = webView.viewPrintFormatter()
        printController.present(animated: true, completionHandler: nil)
    }

    // MARK: Selection & note actions

    func clearSelection() {
        selection = nil
        popoverPosition = nil
        selectionNoteDraft = nil
        post("clear-selection")
    }

    /// The selection popover's note field is opening. Pinning happens here, in
    /// the button action, because the field takes first responder as soon as it
    /// appears — and that is what destroys the DOM selection. Collapsing the
    /// field again does not unpin: the selection is gone by then, so the draft
    /// is all that keeps the popover (and its swatches) usable until a real
    /// dismissal — a tap in the page, a scroll, or clearSelection().
    func beginSelectionNote() {
        selectionNoteDraft = selection
    }

    /// The selection a popover action must act on: the live one when the page
    /// still has it, otherwise the copy pinned when the note field opened.
    private var anchoringSelection: WebSelection? { selection ?? selectionNoteDraft }

    /// Identity of the passage the popover is bound to. The view keys its `.id`
    /// on it, so a different passage tears the popover down instead of reusing
    /// it — otherwise its @State (a half-typed note, the expanded field) would
    /// carry over onto the new selection. Blur, which only drops `selection` and
    /// leaves the pinned draft, leaves this unchanged.
    var selectionIdentity: String? { anchoringSelection.map(Self.identityKey) }

    private static func identityKey(_ selection: WebSelection) -> String {
        let position = selection.positionData
        return "\(selection.pageNumber)|\(position.startOffset ?? -1)|\(position.endOffset ?? -1)|\(selection.text)"
    }

    func addHighlight(color: String) {
        guard let selection = anchoringSelection, let annotationStore else { return }
        let input = CreateAnnotationInput(
            type: .highlight,
            pageNumber: selection.pageNumber,
            color: color,
            content: nil,
            positionData: selection.positionData)
        Task { await annotationStore.addHighlight(input) }
    }

    func addSelectionNote(content: String) {
        guard let selection = anchoringSelection, let annotationStore else { return }
        let input = CreateAnnotationInput(
            type: .note,
            pageNumber: selection.pageNumber,
            color: nil,
            content: content,
            positionData: selection.positionData)
        Task { await annotationStore.addNote(input) }
    }

    /// Attach the selected text to the AI composer. The page number is the
    /// content script's virtual page — the same locator the AI's scroll/read
    /// tools take on web documents — so the chip and the prompt line stay true.
    func askAiAboutSelection() {
        guard let selection = anchoringSelection, let aiStore else { return }
        let text = selection.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        aiStore.addReference(AiReference(
            kind: .selection(text: text, page: selection.pageNumber)))
    }

    func createAnchoredNote(anchor: WebNoteAnchor, content: String) {
        guard let annotationStore else { return }
        let input = CreateAnnotationInput(
            type: .note,
            pageNumber: anchor.pageNumber,
            color: nil,
            content: content,
            positionData: PositionData(
                rects: [],
                pageWidth: 1,
                pageHeight: 1,
                selectedText: anchor.text,
                startOffset: anchor.start,
                endOffset: anchor.end,
                prefix: anchor.prefix,
                suffix: anchor.suffix,
                viewportOffset: nil))
        Task {
            if let annotation = await annotationStore.addNote(input) {
                annotationStore.selectAnnotation(annotation.id)
            }
        }
    }

    func contextMenuAddNote() {
        guard let menu = contextMenu else { return }
        hideContextMenu()
        if let anchor = menu.anchor {
            noteComposer = WebNoteComposerState(
                point: menu.point, anchor: anchor, openedAt: Date())
        }
    }

    func closeNoteComposer() { noteComposer = nil }
    func closeNoteViewer() { noteViewer = nil }
    func closeHighlightEditor() { highlightEditor = nil }

    func closeNotePopovers() {
        noteComposer = nil
        hideContextMenu()
        noteViewer = nil
        highlightEditor = nil
    }

    func hideContextMenu() {
        contextMenu = nil
    }

    // MARK: Effects (annotations / mode / selection scroll)

    /// JSON value for an optional (nil → null), for bridge payloads.
    private func orNull(_ value: (some Any)?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }

    func pushAnnotations(_ annotations: [Annotation]) {
        guard initCount > 0 else { return }

        func anchor(_ annotation: Annotation) -> [String: Any] {
            [
                "id": annotation.id,
                "color": annotation.color ?? "#fef08a",
                "start": orNull(annotation.positionData?.startOffset),
                "end": orNull(annotation.positionData?.endOffset),
                "text": annotation.positionData?.selectedText ?? "",
                "prefix": orNull(annotation.positionData?.prefix),
                "suffix": orNull(annotation.positionData?.suffix),
            ]
        }
        func hasQuote(_ annotation: Annotation) -> Bool {
            guard let text = annotation.positionData?.selectedText else { return false }
            return !text.isEmpty
        }

        let highlights = annotations
            .filter { $0.type == .highlight && hasQuote($0) }
            .map(anchor)
        let notes = annotations
            .filter { $0.type == .note && hasQuote($0) && $0.positionData?.startOffset != nil }
            .map { annotation -> [String: Any] in
                var payload = anchor(annotation)
                payload["content"] = annotation.content ?? ""
                return payload
            }
        // Point bookmarks go along too so the content script can re-anchor
        // them and report which are on screen (drives the toolbar state).
        let bookmarks = annotations
            .filter { $0.type == .bookmark && hasQuote($0) && $0.positionData?.startOffset != nil }
            .map(anchor)
        post("apply-annotations", [
            "highlights": highlights,
            "notes": notes,
            "bookmarks": bookmarks,
        ])
    }

    func pushMode(_ mode: InteractionMode) {
        guard initCount > 0 else { return }
        post("set-mode", ["mode": mode.rawValue])
    }

    func pushSelectedHighlight() {
        guard initCount > 0 else { return }
        post("set-selected-highlight", ["id": orNull(highlightEditor?.id)])
    }

    func scrollToSelected(annotations: [Annotation], selectedId: String?) {
        guard initCount > 0, let selectedId else { return }
        guard let annotation = annotations.first(where: { $0.id == selectedId }) else { return }
        let hasQuote = (annotation.positionData?.selectedText).map { !$0.isEmpty } ?? false
        if (annotation.type == .highlight || annotation.type == .note), hasQuote {
            post("scroll-to-annotation", ["id": selectedId])
        } else if annotation.type == .bookmark,
                  let positionData = annotation.positionData,
                  positionData.startOffset != nil {
            post("scroll-to-position", [
                "start": orNull(positionData.startOffset),
                "end": orNull(positionData.endOffset),
                "text": orNull(positionData.selectedText),
                "prefix": orNull(positionData.prefix),
                "suffix": orNull(positionData.suffix),
                "offset": orNull(positionData.viewportOffset),
                "page": annotation.pageNumber,
            ])
        }
    }

    // MARK: Locate / capture / scroll-to-position hooks

    func locateWebText(page: Int, text: String) async -> LocatedText? {
        await withCheckedContinuation { continuation in
            let requestId = UUID().uuidString.lowercased()
            pendingLocates[requestId] = { continuation.resume(returning: $0) }
            post("locate-text", ["requestId": requestId, "page": page, "text": text])
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(4))
                self?.finishLocate(requestId, with: nil)
            }
        }
    }

    private func finishLocate(_ requestId: String, with value: LocatedText?) {
        guard let resolve = pendingLocates.removeValue(forKey: requestId) else { return }
        resolve(value)
    }

    func captureWebPosition() async -> CapturedWebPosition? {
        guard supportsPositions else { return nil }
        return await withCheckedContinuation { continuation in
            let requestId = UUID().uuidString.lowercased()
            pendingCaptures[requestId] = { continuation.resume(returning: $0) }
            post("capture-position", ["requestId": requestId])
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(1500))
                self?.finishCapture(requestId, with: nil)
            }
        }
    }

    private func finishCapture(_ requestId: String, with value: CapturedWebPosition?) {
        guard let resolve = pendingCaptures.removeValue(forKey: requestId) else { return }
        resolve(value)
    }

    /// Snapshot the web-view region under `viewerRect` (SwiftUI overlay-local
    /// coordinates, which sit directly over the web view), encoded for a vision
    /// request. The touch overlay that supplies `viewerRect` lands in Phase 6;
    /// this entry point is ready for it.
    func captureRegionImage(viewerRect rect: CGRect) async -> AiPageImageSnapshot? {
        await snapshot(rect: rect.intersection(webView.bounds))
    }

    /// Crop the web-view region under `viewerRect` for the scratchpad. Runs the
    /// snapshot bytes through the shared `scratchpadCapture` normalizer
    /// (downscale/encode) so a web crop is stored just like a dropped image.
    /// The drag-to-crop touch overlay that supplies `viewerRect` lands in
    /// Phase 6; this entry point is ready for it.
    func captureRegion(viewerRect rect: CGRect) async -> ScratchpadImageCapture? {
        let clamped = rect.intersection(webView.bounds)
        guard clamped.width >= 4, clamped.height >= 4 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = clamped
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let png = image.pngData() else { return nil }
        return scratchpadCapture(from: png)
    }

    /// Snapshot of what the reader can currently see. There is no way to render
    /// an offscreen virtual page on its own — the archived document is one
    /// continuous DOM — so "current page" means the viewport.
    func capturePageImage() async -> AiPageImageSnapshot? {
        await snapshot(rect: webView.bounds)
    }

    private func snapshot(rect: CGRect) async -> AiPageImageSnapshot? {
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = rect
        guard let image = try? await webView.takeSnapshot(configuration: config) else { return nil }
        // Stamp the page that was actually on screen when the bytes were taken,
        // never the one a caller asked for.
        return aiSnapshot(from: image, page: max(1, app?.currentPage ?? 1))
    }

    /// Encode to the same budget the PDF vision path uses (max side 1280, JPEG
    /// quality 0.72) so web and PDF references cost the model the same.
    private func aiSnapshot(from image: UIImage, page: Int) -> AiPageImageSnapshot? {
        var pixelWidth = image.size.width * image.scale
        var pixelHeight = image.size.height * image.scale
        guard pixelWidth >= 2, pixelHeight >= 2 else { return nil }
        let maxDimension = max(pixelWidth, pixelHeight)
        if maxDimension > 1280 {
            let scale = 1280 / maxDimension
            pixelWidth = max(1, (pixelWidth * scale).rounded())
            pixelHeight = max(1, (pixelHeight * scale).rounded())
        }
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let rendered = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let jpeg = rendered.jpegData(compressionQuality: 0.72) else { return nil }
        return AiPageImageSnapshot(
            pageNumber: page,
            base64Data: jpeg.base64EncodedString(),
            mediaType: "image/jpeg",
            width: Int(pixelWidth),
            height: Int(pixelHeight)
        )
    }

    func scrollToWebPosition(_ positionData: PositionData, page: Int?) -> Bool {
        guard supportsPositions else { return false }
        post("scroll-to-position", [
            "start": orNull(positionData.startOffset),
            "end": orNull(positionData.endOffset),
            "text": orNull(positionData.selectedText),
            "prefix": orNull(positionData.prefix),
            "suffix": orNull(positionData.suffix),
            "offset": orNull(positionData.viewportOffset),
            "page": orNull(page),
        ])
        return true
    }

    // MARK: Auto-archive

    private func cancelPendingArchive() {
        archiveTask?.cancel()
        archiveTask = nil
    }

    private func startArchiveTimer(tabId: String, url: String, pages: [WebPageText]) {
        cancelPendingArchive()
        archiveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard !Task.isCancelled, let self, let app = self.app else { return }
            self.archiveTask = nil
            self.archivedUrl = url
            do {
                _ = try await app.sessions.archiveWebpageDefault(
                    sessionId: tabId, pages: pages, expectedUrl: url)
            } catch {
                // Non-fatal: reading works without the archive. Allow a retry
                // on the next init for this URL.
                if self.archivedUrl == url {
                    self.archivedUrl = nil
                }
            }
        }
    }

    // MARK: Coordinate mapping

    /// Map page-viewport coordinates to viewer coordinates (the page is
    /// scaled by pageZoom, so CSS px arrive unscaled).
    private func frameToParent(x: Double, y: Double) -> CGPoint {
        let scale = app?.zoom ?? 1
        return CGPoint(x: x * scale, y: y * scale)
    }

    // MARK: Inbound messages

    fileprivate func handleMessage(_ body: Any) {
        guard let data = body as? [String: Any],
              data["vellum"] as? Bool == true,
              let type = data["type"] as? String,
              let app else { return }
        // Drop messages queued from before a tab switch: this viewer belongs
        // to one tab, and acting on another tab's state would corrupt it.
        guard app.activeTabId == mountTabId else { return }

        switch type {
        case "init":
            handleInit(data, app: app)

        case "scroll":
            if let currentPage = intValue(data["currentPage"]) {
                app.setCurrentPage(currentPage)
            }
            if let visible = data["visiblePages"] as? [Any] {
                app.setVisiblePages(visible.compactMap(intValue))
            }
            if let start = intValue(data["visibleStart"]),
               let end = intValue(data["visibleEnd"]) {
                app.setWebVisibleRange(WebVisibleRange(start: start, end: end))
            }
            if let bookmarks = data["visibleBookmarks"] as? [Any] {
                app.setWebVisibleBookmarks(bookmarks.compactMap { $0 as? String })
            }

        case "selection":
            handleSelection(data, app: app)

        case "selection-cleared":
            selection = nil
            popoverPosition = nil
            // A plain tap inside the page doubles as "click outside" for
            // the note popovers. The grace period keeps the event fired by
            // the opening tap itself from instantly dismissing them.
            func clickOutside(_ openedAt: Date) -> Bool {
                Date().timeIntervalSince(openedAt) > 0.4
            }
            if let menu = contextMenu, clickOutside(menu.openedAt) { hideContextMenu() }
            if let viewer = noteViewer, clickOutside(viewer.openedAt) { noteViewer = nil }
            if let composer = noteComposer, clickOutside(composer.openedAt) { noteComposer = nil }
            if let editor = highlightEditor, clickOutside(editor.openedAt) { highlightEditor = nil }

        case "note-placed":
            guard let anchor = parseNoteAnchor(data) else { break }
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0)
            hideContextMenu()
            noteViewer = nil
            noteComposer = WebNoteComposerState(point: point, anchor: anchor, openedAt: Date())
            // Mirror the PDF viewer: placing a note returns to view mode.
            app.setMode(.view)

        case "context-menu":
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0)
            noteComposer = nil
            noteViewer = nil
            let found = data["found"] as? Bool ?? false
            contextMenu = WebContextMenuState(
                point: point,
                anchor: found ? parseNoteAnchor(data) : nil,
                openedAt: Date())

        case "annotation-click":
            guard let id = data["id"] as? String, let annotationStore else { break }
            annotationStore.selectAnnotation(id)
            let annotation = annotationStore.annotations.first { $0.id == id }
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0)
            if annotation?.type == .note {
                noteComposer = nil
                highlightEditor = nil
                hideContextMenu()
                noteViewer = WebNoteViewerState(id: id, point: point, openedAt: Date())
            } else if annotation?.type == .highlight {
                noteComposer = nil
                noteViewer = nil
                hideContextMenu()
                highlightEditor = WebHighlightEditorState(id: id, point: point, openedAt: Date())
            }

        case "highlight-resized":
            guard let id = data["id"] as? String,
                  let start = intValue(data["start"]),
                  let end = intValue(data["end"]),
                  let text = data["text"] as? String,
                  let annotationStore else { break }
            let positionData = PositionData(
                rects: [],
                pageWidth: 1,
                pageHeight: 1,
                selectedText: text,
                startOffset: start,
                endOffset: end,
                prefix: data["prefix"] as? String,
                suffix: data["suffix"] as? String,
                viewportOffset: nil)
            Task {
                await annotationStore.updateAnnotation(UpdateAnnotationInput(
                    id: id,
                    color: nil,
                    content: nil,
                    positionData: positionData,
                    pageNumber: intValue(data["pageNumber"])))
            }

        case "navigate":
            guard let url = data["url"] as? String else { break }
            navigateTo(url)

        case "open-youtube":
            // The YouTube facade (WebContentScript) hands embeds off to the
            // system browser — embeds need an http(s) Referer the proxy origin
            // can't send. Only a validated video id crosses the bridge, never a
            // full URL, so a hostile page script can at worst open a
            // youtube.com/watch page. The watch URL is built natively from the
            // id, never taken from the page.
            guard let id = data["id"] as? String,
                  id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { break }
            UIApplication.shared.open(url)

        case "viewport-scrolled":
            // Popovers are positioned from event-time rects; scrolling the
            // page underneath invalidates them — including a pinned note draft,
            // whose popover would otherwise hang at a stale anchor.
            if selection != nil || selectionNoteDraft != nil {
                selection = nil
                popoverPosition = nil
                selectionNoteDraft = nil
                post("clear-selection")
            }
            hideContextMenu()
            noteViewer = nil
            highlightEditor = nil
            // Keep the composer only if it just opened (the placement tap
            // can nudge scroll on some pages); otherwise typing continues.
            if let composer = noteComposer,
               Date().timeIntervalSince(composer.openedAt) >= 0.4 {
                noteComposer = nil
            }

        case "locate-result":
            guard let requestId = data["requestId"] as? String else { break }
            if data["found"] as? Bool == true,
               let start = intValue(data["start"]),
               let end = intValue(data["end"]) {
                finishLocate(requestId, with: LocatedText(
                    positionData: PositionData(
                        rects: [],
                        pageWidth: 1,
                        pageHeight: 1,
                        selectedText: nil,
                        startOffset: start,
                        endOffset: end,
                        prefix: data["prefix"] as? String,
                        suffix: data["suffix"] as? String,
                        viewportOffset: nil),
                    pageNumber: intValue(data["pageNumber"]) ?? 0))
            } else {
                finishLocate(requestId, with: nil)
            }

        case "find-result":
            app.setFindResults(
                count: intValue(data["count"]) ?? 0,
                current: intValue(data["current"]) ?? 0)

        case "position-result":
            guard let requestId = data["requestId"] as? String else { break }
            if data["found"] as? Bool == true,
               let start = intValue(data["start"]),
               let end = intValue(data["end"]),
               let text = data["text"] as? String {
                finishCapture(requestId, with: CapturedWebPosition(
                    pageNumber: intValue(data["pageNumber"]) ?? 1,
                    positionData: PositionData(
                        rects: [],
                        pageWidth: 1,
                        pageHeight: 1,
                        selectedText: text,
                        startOffset: start,
                        endOffset: end,
                        prefix: data["prefix"] as? String,
                        suffix: data["suffix"] as? String,
                        viewportOffset: doubleValue(data["offset"]))))
            } else {
                finishCapture(requestId, with: nil)
            }

        default:
            break
        }
    }

    /// Rebind the tab to a new page and reload the reader — used by the
    /// content script's link interception, the navigation delegate's escape
    /// hatch for router-driven top-level loads, and window.open routing.
    func navigateTo(_ url: String) {
        guard let app, let tabId = app.activeTabId else { return }
        // A pending auto-archive for the outgoing page must not fire against
        // the rebound session.
        cancelPendingArchive()
        // Reset the one-shot redirect/crash reload guards for this fresh
        // navigation: they only need to prevent a reload *loop* within a single
        // navigation attempt. Left uncleared, revisiting a URL that was
        // reload-fixed once earlier this mount would skip its corrective reload.
        redirectReloadedUrl = nil
        processReloadedUrl = nil
        clearSelection()
        closeNotePopovers()
        let outgoing = app.document?.pdfPath
        Task { [weak self] in
            guard let rebound = await app.webNavigated(tabId: tabId, url: url),
                  let self else { return }
            self.pendingNavUrl = rebound.pdfPath
            self.outgoingNavUrl = outgoing
            self.initCount = 0
            self.webView.load(
                URLRequest(url: VellumWebSchemeHandler.proxyUrl(for: rebound.pdfPath)))
        }
    }

    private func handleInit(_ data: [String: Any], app: AppStore) {
        guard let tabId = app.activeTabId, let currentDoc = app.document else { return }

        let reportedUrl = data["url"] as? String

        // Mid-navigation: ignore late reports from the outgoing document (its
        // delayed re-extraction) so they can't rebind us backwards. Anything
        // else is the incoming document — requiring equality with the
        // requested URL here swallowed the init (and every one after it)
        // whenever a server redirect landed the load on a different final
        // URL, leaving the address pill stale from then on.
        if pendingNavUrl != nil {
            if reportedUrl != pendingNavUrl, reportedUrl == outgoingNavUrl { return }
            pendingNavUrl = nil
            outgoingNavUrl = nil
        }

        isOffline = data["offline"] as? Bool ?? false
        supportsPositions = data["positionAnchors"] as? Bool ?? false

        // Compare normalized identities: the content script's history shim
        // reports un-normalized URLs after soft navigations (tracking params
        // and all), and a raw != comparison would rebind forever.
        let reportedNormalized = reportedUrl.map { (try? WebUrl.normalize($0)) ?? $0 }
        if let reportedUrl, let reportedNormalized, reportedNormalized != currentDoc.pdfPath {
            // The page navigated (back/forward, a server redirect changed the
            // effective URL, or an SPA soft-navigated): rebind the session,
            // then ask the page to report again so the fresh context lands
            // after the App-level document reset. Any open note popovers
            // belong to the outgoing document.
            cancelPendingArchive()
            closeNotePopovers()
            Task { [weak self] in
                guard let rebound = await app.webNavigated(tabId: tabId, url: reportedUrl),
                      let self else { return }
                // Server redirect: the destination's HTML was served under
                // the pre-redirect request URL, so window.location still
                // shows the old path and strict client routers would hydrate
                // against it — reload under the truthful address. One-shot
                // per URL so a redirect loop can't ping-pong the webview.
                // Soft navigations (pushState) already updated location and
                // skip the reload; snapshot serving (nil realUrl) does too.
                let serving = self.webView.url
                    .flatMap(VellumWebSchemeHandler.realUrl(from:))
                    .flatMap { try? WebUrl.normalize($0) }
                if let serving, serving != rebound.pdfPath,
                   self.redirectReloadedUrl != rebound.pdfPath {
                    self.redirectReloadedUrl = rebound.pdfPath
                    self.pendingNavUrl = rebound.pdfPath
                    self.outgoingNavUrl = nil
                    self.initCount = 0
                    self.webView.load(
                        URLRequest(url: VellumWebSchemeHandler.proxyUrl(for: rebound.pdfPath)))
                } else {
                    self.post("request-init")
                }
            }
            return
        }

        initCount += 1

        if let pageCount = intValue(data["pageCount"]), pageCount > 0 {
            app.setNumPages(pageCount)
        }

        var pages: [WebPageText] = []
        if let rawPages = data["pages"] as? [Any] {
            for rawPage in rawPages {
                guard let page = rawPage as? [String: Any],
                      let number = intValue(page["number"]),
                      let text = page["text"] as? String else { continue }
                pages.append(WebPageText(number: number, text: text))
                aiStore?.setPageText(page: number, text: text)
            }
        }

        if let title = data["title"] as? String, !title.isEmpty {
            app.updateDocumentTitle(tabId: tabId, title: title)
            Task {
                try? await app.sessions.setDocumentMetadata(
                    sessionId: tabId, key: "title", value: title)
            }
        }

        // Default behaviour: archive every opened page as a .vellumweb in the
        // managed library. Skip when we're already showing a snapshot
        // (offline). Debounced so a late re-extraction with fuller text wins,
        // and run once per URL per mount; the backend re-checks the URL so a
        // navigation that slips between the timer and the command can't
        // archive mismatched content.
        if !isOffline, archivedUrl != currentDoc.pdfPath {
            startArchiveTimer(tabId: tabId, url: currentDoc.pdfPath, pages: pages)
        }

        // Restore the reading position once per document; later inits from
        // re-extraction must not yank the reader away from where they are.
        if restoredUrl != currentDoc.pdfPath {
            restoredUrl = currentDoc.pdfPath
            let target = app.currentPage
            if target > 1 {
                post("scroll-to-page", ["page": target])
            }
        }
    }

    private func handleSelection(_ data: [String: Any], app: AppStore) {
        guard let text = data["text"] as? String, !text.isEmpty,
              let rawRects = data["rects"] as? [Any], !rawRects.isEmpty else { return }
        let rects: [(x: Double, y: Double, width: Double, height: Double)] = rawRects
            .compactMap { raw in
                guard let rect = raw as? [String: Any],
                      let x = doubleValue(rect["x"]), let y = doubleValue(rect["y"]),
                      let width = doubleValue(rect["width"]),
                      let height = doubleValue(rect["height"]) else { return nil }
                return (x, y, width, height)
            }
        guard let last = rects.last else { return }

        // A live text selection wins over the highlight edit popover (e.g.
        // double-tap selecting a word inside a highlight).
        highlightEditor = nil

        let scale = app.zoom
        popoverPosition = CGPoint(
            x: (last.x + last.width / 2) * scale,
            y: last.y * scale - 10)
        selection = WebSelection(
            text: text,
            pageNumber: intValue(data["pageNumber"]) ?? 1,
            positionData: PositionData(
                rects: [],
                pageWidth: 1,
                pageHeight: 1,
                selectedText: text,
                startOffset: intValue(data["start"]),
                endOffset: intValue(data["end"]),
                prefix: data["prefix"] as? String,
                suffix: data["suffix"] as? String,
                viewportOffset: nil))
    }

    private func parseNoteAnchor(_ data: [String: Any]) -> WebNoteAnchor? {
        guard let start = intValue(data["start"]),
              let end = intValue(data["end"]),
              let text = data["text"] as? String,
              !text.isEmpty else { return nil }
        let pageNumber = intValue(data["pageNumber"]) ?? 0
        return WebNoteAnchor(
            start: start,
            end: end,
            text: text,
            prefix: data["prefix"] as? String,
            suffix: data["suffix"] as? String,
            pageNumber: pageNumber >= 1 ? pageNumber : 1)
    }

    private func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !(number is NSNull) {
            return number.intValue
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber, !(number is NSNull) {
            return number.doubleValue
        }
        return nil
    }
}

extension WebViewerController_iOS: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handleMessage(message.body)
    }
}

extension WebViewerController_iOS: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // The injected <base href> makes any link the content script misses —
        // and router location.assign calls — resolve to the real https
        // origin; without this the webview would leave the reader entirely.
        // Main frame only: subframes (article embeds, video iframes) load
        // their real content directly.
        guard let url = navigationAction.request.url else { return .allow }
        let scheme = url.scheme?.lowercased()
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true

        // Non-http(s) main-frame navigations (mailto:/tel:/… link clicks):
        // letting WebKit try to load these fails the provisional load, which
        // handleLoadFailure turns into the offline-snapshot fallback for what
        // was just an external-scheme click. Hand common external schemes to
        // the system and cancel; cancel (never allow) any other unsupported
        // scheme so the snapshot fallback isn't triggered. Subframes keep their
        // real content, so only the main frame is intercepted here.
        if scheme != "http" && scheme != "https" {
            // The reader's own content is served over the vellum-web(i) proxy
            // schemes — those loads must always proceed (memory invariant).
            if scheme == VellumWebSchemeHandler.scheme
                || scheme == VellumWebSchemeHandler.insecureScheme {
                return .allow
            }
            guard isMainFrame else { return .allow }
            if let scheme, ["mailto", "tel", "facetime", "sms"].contains(scheme) {
                UIApplication.shared.open(url, options: [:], completionHandler: nil)
            }
            return .cancel
        }
        guard isMainFrame else { return .allow }
        // A same-page anchor click resolves against the injected <base href> to
        // the real https origin, so WebKit sees a cross-origin navigation instead
        // of a scroll. When only the fragment differs from the current page,
        // scroll in place via location.hash (a same-document navigation) rather
        // than rebinding and reloading the whole reader. normalize strips
        // fragments, so equal normalized URLs == same page.
        if let fragment = url.fragment,
           let currentProxy = webView.url,
           let currentReal = VellumWebSchemeHandler.realUrl(from: currentProxy),
           let incoming = try? WebUrl.normalize(url.absoluteString),
           let current = try? WebUrl.normalize(currentReal),
           incoming == current {
            // JSON-encode the fragment so quotes/backslashes can't break out of
            // the JS string. The hash change runs in the page world (location),
            // not the bridge world, so target the page world (nil = page).
            if let data = try? JSONEncoder().encode("#" + fragment),
               let literal = String(data: data, encoding: .utf8) {
                webView.evaluateJavaScript("location.hash = \(literal);", completionHandler: nil)
            }
            return .cancel
        }
        navigateTo(url.absoluteString)
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // window.open / target=_blank: no popup windows in the reader —
        // route http(s) targets through the normal rebind flow instead of
        // silently dropping them.
        if let url = navigationAction.request.url,
           let scheme = url.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            navigateTo(url.absoluteString)
        }
        return nil
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        handleLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleLoadFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let doc = app?.document, doc.kind == .web else { return }
        if processReloadedUrl == doc.pdfPath {
            loadSnapshotFallback()
        } else {
            processReloadedUrl = doc.pdfPath
            initCount = 0
            webView.load(URLRequest(url: VellumWebSchemeHandler.proxyUrl(for: doc.pdfPath)))
        }
    }

    private func handleLoadFailure(_ error: Error) {
        // Our own decidePolicyFor cancels and superseded loads arrive here
        // too — only real failures fall through to the snapshot fallback.
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        // WebKitErrorFrameLoadInterruptedByPolicyChange
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return }
        loadSnapshotFallback()
    }

    /// Serve the offline snapshot (or Vellum's own error page) instead of
    /// ever leaving the user on WebKit's native error screen.
    private func loadSnapshotFallback() {
        guard let app, let doc = app.document, doc.kind == .web else { return }
        // The fallback itself failing must not loop.
        guard webView.url?.host != VellumWebSchemeHandler.snapshotHost else { return }
        initCount = 0
        webView.load(URLRequest(
            url: VellumWebSchemeHandler.snapshotUrl(forKey: WebLibrary.pageKey(doc.pdfPath))))
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptMessageHandler_iOS: NSObject, WKScriptMessageHandler {
    weak var delegate: WKScriptMessageHandler?

    init(_ delegate: WKScriptMessageHandler) {
        self.delegate = delegate
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}
#endif
