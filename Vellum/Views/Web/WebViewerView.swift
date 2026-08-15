#if os(macOS)
import AppKit
import Observation
import SwiftUI
import WebKit

// Web reading mode — port of src/components/web/WebViewer.tsx. The sandboxed
// iframe becomes a WKWebView fed by the vellum-web:// scheme handler; the
// postMessage bridge becomes WKScriptMessageHandler (in) + evaluateJavaScript
// (out) with identical message semantics. One instance per tab mount
// (ContentView keys the view by activeTabId).

extension Notification.Name {
    /// Ask the active web viewer to run history.go(delta) inside the page
    /// (window.__webHistory in the original). userInfo: ["delta": Int].
    static let vellumWebHistory = Notification.Name("vellum.web-history")
}

/// Text-quote anchor for a note placed at a point in the page.
struct WebNoteAnchor {
    var start: Int
    var end: Int
    var text: String
    var prefix: String?
    var suffix: String?
    var pageNumber: Int
}

struct WebSelection {
    var text: String
    var pageNumber: Int
    var positionData: PositionData
}

struct WebNoteComposerState {
    var point: CGPoint
    var anchor: WebNoteAnchor
    var openedAt: Date
    /// Text the composer opens pre-filled with — an AI reply routed here by the
    /// panel's "Add as note". Empty for a plain note-tool placement.
    var initialContent: String = ""
}

struct WebContextMenuState {
    var point: CGPoint
    var anchor: WebNoteAnchor?
    var openedAt: Date
}

struct WebNoteViewerState {
    var id: String
    var point: CGPoint
    var openedAt: Date
}

struct WebHighlightEditorState {
    var id: String
    var point: CGPoint
    var openedAt: Date
}

// MARK: - View

struct WebViewerView: View {
    let tabId: String
    let document: DocumentInfo
    let isActive: Bool
    let runtime: LiveTabRuntime

    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(ScratchpadStore.self) private var scratchpadStore
    @Environment(\.palette) private var palette

    @State private var hasActivated = false
    private var controller: WebViewerController { runtime.webController }

    var body: some View {
        Group {
            if hasActivated || isActive || controller.isAttached {
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                WebViewRepresentable(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Drag-to-crop region snapshot. The scrim intercepts the drag
                // before the web view sees it. The crop goes to whichever panel
                // armed the mode (AppStore.regionCaptureTarget), same as the PDF
                // viewer — WKWebView.takeSnapshot renders page content only, so
                // the marquee itself can never end up inside the crop.
                if appStore.mode == .snapshotRegion {
                    RegionCaptureOverlay { rect in
                        let target = appStore.finishRegionCapture()
                        captureRegion(rect, target: target)
                    } onCancel: {
                        // Plain click or tiny wobble: back out of capture mode
                        // without a warning — the user changed their mind.
                        appStore.setMode(.view)
                    }
                    .zIndex(60)
                }

                if controller.isOffline {
                    offlineBadge
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                        .padding(.top, 12)
                }

                // The pinned note draft keeps the popover mounted while its note
                // field has focus — by then the DOM selection is already gone
                // (see selectionNoteDraft).
                selectionPopover(containerSize: proxy.size)

                if let menu = controller.contextMenu {
                    AnchoredPopover(
                        x: menu.point.x, y: menu.point.y,
                        placement: .menu, containerSize: proxy.size
                    ) {
                        WebContextMenuView(
                            canAddNote: menu.anchor != nil,
                            onAddNote: { controller.contextMenuAddNote() })
                            .onGeometryChange(for: CGRect.self) { geometry in
                                geometry.frame(in: .global)
                            } action: { frame in
                                controller.contextMenuGlobalFrame = frame
                            }
                    }
                    .zIndex(50)
                }

                if let composer = controller.noteComposer {
                    AnchoredPopover(
                        x: composer.point.x, y: composer.point.y,
                        placement: .below, containerSize: proxy.size
                    ) {
                        WebNoteComposerView(
                            initialContent: composer.initialContent,
                            onSubmit: { content in
                                controller.createAnchoredNote(anchor: composer.anchor, content: content)
                                controller.closeNoteComposer()
                            },
                            onClose: { controller.closeNoteComposer() },
                            onDraftChange: { controller.updateNoteComposerDraft($0) })
                    }
                    // The composer seeds its editable text from `initialContent`
                    // once, at init. Keying on the placement timestamp gives each
                    // placement a fresh identity, so placing a second note
                    // without closing the first can't reuse the previous text.
                    .id(composer.openedAt)
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
            } else {
                Color.clear
            }
        }
        .background(palette.well)
        .clipped()
        .onAppear {
            guard isActive else { return }
            hasActivated = true
            controller.attach(
                app: appStore,
                annotationStore: annotationStore,
                aiStore: aiStore,
                tabId: tabId,
                document: document,
                runtime: runtime)
        }
        .onChange(of: controller.initCount) {
            guard isActive else { return }
            controller.pushAnnotations(annotationStore.annotations)
            controller.pushMode(appStore.mode)
            controller.pushSelectedHighlight()
            controller.scrollToSelected(
                annotations: annotationStore.annotations,
                selectedId: annotationStore.selectedAnnotationId)
        }
        .onChange(of: annotationStore.annotations) {
            guard isActive else { return }
            controller.pushAnnotations(annotationStore.annotations)
        }
        .onChange(of: appStore.mode) {
            guard isActive else { return }
            controller.pushMode(appStore.mode)
        }
        // Keyed to the request counter, not selectedAnnotationId: clicking the
        // sidebar row of the already-selected annotation re-selects the same id
        // (no id change, no onChange) but must still scroll back to it.
        .onChange(of: annotationStore.selectionRequestCount) {
            guard isActive else { return }
            controller.scrollToSelected(
                annotations: annotationStore.annotations,
                selectedId: annotationStore.selectedAnnotationId)
        }
        .onChange(of: appStore.zoom) { _, zoom in
            guard isActive else { return }
            controller.applyZoom(zoom)
        }
        .onChange(of: isActive) { _, active in
            guard active else {
                controller.deactivate()
                return
            }
            hasActivated = true
            controller.attach(
                app: appStore,
                annotationStore: annotationStore,
                aiStore: aiStore,
                tabId: tabId,
                document: document,
                runtime: runtime)
            controller.pushAnnotations(annotationStore.annotations)
            controller.pushMode(appStore.mode)
            controller.pushSelectedHighlight()
            controller.applyZoom(appStore.zoom)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumWebHistory)) { note in
            guard isActive else { return }
            let delta = note.userInfo?["delta"] as? Int ?? 0
            controller.goHistory(delta: delta)
        }
    }

    @ViewBuilder
    private func selectionPopover(containerSize: CGSize) -> some View {
        if controller.selection != nil || controller.selectionNoteDraft != nil,
           let position = controller.popoverPosition {
            AnchoredPopover(
                x: position.x, y: position.y,
                placement: .above, containerSize: containerSize
            ) {
                WebSelectionPopover(
                    onHighlight: { color in controller.addHighlight(color: color) },
                    onNote: { content in controller.addSelectionNote(content: content) },
                    onBeginNote: { controller.beginSelectionNote() },
                    onAskAi: { controller.askAiAboutSelection() },
                    onClose: { controller.clearSelection() }
                )
                .id(controller.selectionIdentity)
            }
            .zIndex(50)
        }
    }

    /// Hand the finished crop to whichever panel armed the capture (mirrors
    /// PdfOverlayStack.captureRegion). The AI path stays silent on a miss — a
    /// failed takeSnapshot mid-scroll is not worth a banner; the scratchpad path
    /// warns, since its button is the one the user pressed to get here.
    private func captureRegion(_ rect: CGRect, target: RegionCaptureTarget) {
        switch target {
        case .ai:
            // Pin the tab + document the crop was drawn on before the await; a
            // capture that lands after the user navigated or switched tabs must
            // be discarded, not attached to whatever is showing now. See
            // `AiReferenceTarget`.
            guard let target = aiStore.currentReferenceTarget() else { return }
            Task {
                // A web capture always stamps the virtual page it was taken on,
                // so the snapshot's optional page is always populated here.
                guard let snapshot = await controller.captureRegionImage(viewerRect: rect),
                      let page = snapshot.pageNumber
                else { return }
                aiStore.addCapturedReference(
                    AiReference(kind: .region(image: snapshot, page: page)), target: target)
            }
        case .scratchpad:
            Task {
                if let capture = await controller.captureRegion(viewerRect: rect) {
                    scratchpadStore.addImage(capture, label: "Web region")
                } else {
                    // Crop missed the page or was too small — warn instead of
                    // silently doing nothing.
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

private struct WebViewRepresentable: NSViewRepresentable {
    let controller: WebViewerController

    func makeNSView(context: Context) -> WKWebView {
        // The web view now outlives any single host: it belongs to the tab's
        // `LiveTabRuntime`, and the host is remounted whenever the tab is
        // dragged to another pane or its runtime comes back from eviction. An
        // NSView may only have one superview, and a tab that migrates panes is
        // mounted at its destination before the donor pane's subtree is torn
        // down — a window in which two hosts can briefly claim the same tab.
        // Detaching first means the new host always adopts a parentless view,
        // exactly as it would a freshly created one.
        let webView = controller.webView
        webView.removeFromSuperview()
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// MARK: - Controller (the WebViewer bridge logic)

@MainActor
@Observable
final class WebViewerController: NSObject {
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
    private(set) var noteComposer: WebNoteComposerState? {
        didSet {
            // Every placement reseeds the mirror below from its own initial
            // content, so a composer can never inherit the previous one's text.
            noteComposerDraft = noteComposer?.initialContent ?? ""
        }
    }
    /// The composer's live text, mirrored out of the popover so a dismissal
    /// that isn't an explicit cancel can hand the draft back to the note queue
    /// (issue #92). Observation-ignored: nothing renders from it, and it
    /// changes on every keystroke.
    @ObservationIgnored private var noteComposerDraft = ""
    private(set) var contextMenu: WebContextMenuState?
    private(set) var noteViewer: WebNoteViewerState?
    private(set) var highlightEditor: WebHighlightEditorState? {
        didSet {
            // The selected highlight (the one whose edit popover is open) grows
            // draggable resize handles in the page; keep the content script in
            // sync whenever the selection changes.
            guard highlightEditor?.id != oldValue?.id else { return }
            pushSelectedHighlight()
        }
    }

    /// Window-space frame of the context menu (for click-outside detection).
    @ObservationIgnored var contextMenuGlobalFrame: CGRect = .zero

    @ObservationIgnored private weak var app: AppStore?
    @ObservationIgnored private weak var annotationStore: AnnotationStore?
    @ObservationIgnored private weak var aiStore: AiStore?
    @ObservationIgnored private weak var runtime: LiveTabRuntime?
    @ObservationIgnored private var mountTabId: String?
    @ObservationIgnored private var mountDocument: DocumentInfo?
    @ObservationIgnored private var attached = false
    /// True once this controller has ever built and loaded its `WKWebView`. The
    /// view is created lazily, so a controller belonging to a tab the user has
    /// never opened costs nothing and must not be charged for one.
    @ObservationIgnored private var didCreateWebView = false
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
    @ObservationIgnored private var eventMonitor: Any?

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
        // Runs exactly once, from `_webView`'s lazy initializer. This is the
        // authoritative point at which this tab starts costing a web content
        // process, so it is where the residency policy's byte estimate switches
        // on — not `attach`, which can race the representable's `makeNSView`.
        didCreateWebView = true
        let configuration = WKWebViewConfiguration()
        let schemeHandler = VellumWebSchemeHandler()
        configuration.setURLSchemeHandler(
            schemeHandler, forURLScheme: VellumWebSchemeHandler.scheme)
        configuration.setURLSchemeHandler(
            schemeHandler, forURLScheme: VellumWebSchemeHandler.insecureScheme)
        configuration.userContentController.add(
            WeakScriptMessageHandler(self), contentWorld: Self.bridgeWorld, name: "vellum")
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
        webView.allowsBackForwardNavigationGestures = false
        return webView
    }

    // MARK: Lifecycle

    func attach(
        app: AppStore,
        annotationStore: AnnotationStore,
        aiStore: AiStore,
        tabId: String,
        document: DocumentInfo,
        runtime: LiveTabRuntime
    ) {
        // A tab can migrate to another pane while its native WKWebView stays
        // alive. Always rebind pane-scoped stores and document identity.
        self.app = app
        self.annotationStore = annotationStore
        self.aiStore = aiStore
        self.runtime = runtime
        mountTabId = tabId
        mountDocument = document
        if attached {
            aiStore.restorePageTexts(runtime.pageTexts)
            activateSharedHandlers()
            // An init message may have been queued and intentionally discarded
            // while this tab was inactive; ask the preserved page for a fresh
            // snapshot so extraction and viewport state catch up.
            post("request-init")
            return
        }
        attached = true
        aiStore.restorePageTexts(runtime.pageTexts)
        applyZoom(app.zoom)

        activateSharedHandlers()

        guard document.kind == .web else { return }
        webView.load(URLRequest(url: VellumWebSchemeHandler.proxyUrl(for: document.pdfPath)))
    }

    /// Whether this controller is still bound to a live, loaded page. A warm tab
    /// promoted back into the hot set (because a hot slot came free) is
    /// remounted while still inactive, and `WebViewerView`'s `hasActivated`
    /// state does not survive that remount — without this it would render
    /// `Color.clear` and the retained web view would not be re-parented until
    /// the tab was next selected, which is exactly the cost the hot tier exists
    /// to have already paid.
    var isAttached: Bool { attached }

    /// Rough resident footprint for the residency policy's byte budget. A loaded
    /// `WKWebView` carries its own web content process, so it is never cheap;
    /// WebKit offers no way to ask what a given page actually costs, so this is
    /// a flat, deliberately pessimistic estimate for "a real webpage with its
    /// process attached". Zero until the view actually exists.
    var residencyCostBytes: Int { didCreateWebView ? 96 * 1024 * 1024 : 0 }

    /// Release transient UI owned by an inactive mount while keeping the native
    /// view, history, scroll position, and extracted text intact.
    func deactivate() {
        clearSelection()
        closeNotePopovers()
        removeEventMonitor()
    }

    /// Command hooks are window-shared, so the active preserved WKWebView
    /// reclaims them whenever its tab is selected. The underlying web view and
    /// back-forward list stay untouched.
    private func activateSharedHandlers() {
        guard attached, let app, let annotationStore, let aiStore,
              app.activeTabId == mountTabId else { return }
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

    }

    /// Hard teardown, driven by `TabResidencyManager` through `LiveTabRuntime`:
    /// the tab was closed, sat idle past the retention window, or the system
    /// asked for memory back. This is the point at which the page really is
    /// thrown away.
    func releaseResidency() {
        // A debounced auto-archive is a real write to the user's library — the
        // offline snapshot of the page. Never drop one: keep this controller
        // (and the session it archives through) alive until the task lands. The
        // debounce is 1.5s, so by the time an idle timeout fires there is
        // nothing pending; this matters for a tab closed, or evicted under
        // memory pressure, in the second after a page finished loading.
        let pendingArchive = archiveTask
        archiveTask = nil
        if let pendingArchive {
            Task { await pendingArchive.value; withExtendedLifetime(self) {} }
        }
        detach()
        // Unhook the WebKit delegates. They are a resurrection path: eviction
        // targets tabs that are still OPEN, so `mountDocument` still resolves,
        // and a late `webViewWebContentProcessDidTerminate` would re-load the
        // tab's real URL over the network into a view nobody can see. That
        // callback is not hypothetical — jetsamming background web content
        // processes is precisely what the system does under the memory pressure
        // that triggered the eviction in the first place.
        //
        // Note we do NOT navigate to about:blank to "retire the content process
        // early": `decidePolicyFor` cancels every non-http(s) main-frame
        // navigation that is not one of our own proxy schemes, so that load is
        // simply refused. Dropping the last reference to the controller — which
        // is what `LiveTabRuntime.releaseResidency` does immediately after this
        // returns — is what actually releases the view and its process.
        guard didCreateWebView else { return }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func detach() {
        guard attached else { return }
        attached = false
        for resolve in pendingLocates.values { resolve(nil) }
        pendingLocates.removeAll()
        for resolve in pendingCaptures.values { resolve(nil) }
        pendingCaptures.removeAll()
        removeEventMonitor()
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
        // `webView` is lazy, so only touch it when one was actually built —
        // otherwise tearing down a never-opened tab would create the very web
        // view (and content process) the teardown is meant to avoid.
        if didCreateWebView {
            webView.configuration.userContentController
                .removeScriptMessageHandler(forName: "vellum", contentWorld: Self.bridgeWorld)
            webView.stopLoading()
        }
        mountDocument = nil
        runtime = nil
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

    /// Print the rendered page via WKWebView's print operation.
    func printPage() {
        guard let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
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
    /// dismissal — a click in the page, a scroll, or clearSelection().
    func beginSelectionNote() {
        selectionNoteDraft = selection
    }

    /// The selection a popover action must act on: the live one when the page
    /// still has it, otherwise the copy pinned when the note field opened.
    private var anchoringSelection: WebSelection? { selection ?? selectionNoteDraft }

    /// Identity of the passage the popover is bound to. The view keys its `.id`
    /// on it, so a different passage tears the popover down instead of reusing it
    /// — otherwise its @State (a half-typed note, the expanded field) would carry
    /// over onto the new selection. Blur, which only drops `selection` and leaves
    /// the pinned draft, leaves this unchanged.
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
        // Unconditionally, and before the anchor check: the menu is going away
        // either way, and leaving an anchorless one on screen strands it.
        hideContextMenu()
        guard let anchor = menu.anchor else { return }
        // Same payload hand-off as the note-mode placement click: a queued AI
        // reply pre-fills this composer rather than being left stranded.
        // (`PdfSelectionBridge.addNoteFromContextMenu` consumes the reply too,
        // but has neither of the guards below — with a reply queued it writes
        // the note and leaves note mode armed over an emptied queue, so the
        // next click drops a second, empty note. That is a separate PDF-side
        // bug, not parity to copy.)
        //
        // Gated on the active tab for the same reason the `"note-placed"`
        // branch is: `consumePendingNoteContent` reads the *active* tab's
        // queue, so a menu still mounted on a tab the user has left would
        // otherwise steal the reply armed for the tab now on screen. This is a
        // button action rather than a bridge message, so it does not inherit
        // `handleMessage`'s identical guard.
        // No composer at all on the failing branch, rather than an empty one:
        // `annotationStore` is pane-scoped, so a mount left on a background tab
        // now points at whatever document the pane moved on to, and submitting
        // there would file the note against the wrong document.
        guard let app, let sessionId = mountTabId, app.activeTabId == sessionId else { return }
        let pendingContent = app.consumePendingNoteContent()
        presentNoteComposer(
            WebNoteComposerState(
                point: menu.point, anchor: anchor, openedAt: Date(),
                initialContent: pendingContent ?? ""),
            app: app,
            sessionId: sessionId)
    }

    /// Record the composer's edits as they happen. Only the mirror moves, so a
    /// keystroke costs no view invalidation. A write arriving after the
    /// composer is gone needs no guard: nothing reads the mirror without a
    /// composer, and the next one reseeds it in `didSet`.
    func updateNoteComposerDraft(_ text: String) {
        noteComposerDraft = text
    }

    /// Explicit dismissal — Cancel, Escape, or a completed submit. The draft is
    /// discarded, which is what the user asked for.
    func closeNoteComposer() { noteComposer = nil }

    /// Swap in a new composer, rescuing whatever the outgoing one held.
    ///
    /// A second "Add as note" can be pressed while a composer is still open —
    /// the panel's button is not gated on one — and the placement click that
    /// follows would otherwise overwrite the first reply with the second. This
    /// is the one dismissal path that cannot simply call
    /// `returnNoteComposerDraft` first: the incoming reply has already been
    /// consumed off the queue by the caller, so re-queueing the old draft
    /// before that read would hand the caller back the WRONG text.
    ///
    /// So the order here is load-bearing in both directions: read the stranded
    /// draft before the assignment (whose `didSet` blanks the mirror), and
    /// re-queue it after `finishNotePlacement`, which routes through
    /// `setMode(.view)` and would otherwise drop it again.
    private func presentNoteComposer(
        _ state: WebNoteComposerState, app: AppStore, sessionId: String
    ) {
        let stranded = noteComposer != nil ? noteComposerDraft : nil
        noteComposer = state
        app.finishNotePlacement(forSessionId: sessionId)
        if let stranded { app.restorePendingNote(stranded, forSessionId: sessionId) }
    }

    /// Dismissal the user did not ask for: a stray click on the page, a scroll
    /// that invalidates the anchor, or another popover taking over. The draft
    /// goes back on the note queue and placement re-arms, so one more click
    /// re-offers the same text instead of it being lost (issue #92).
    private func returnNoteComposerDraft() {
        guard noteComposer != nil else { return }
        // Load-bearing order: `noteComposer`'s didSet blanks the mirror, so
        // reading the draft after the nil would hand back an empty string and
        // silently reinstate the bug.
        let draft = noteComposerDraft
        noteComposer = nil
        guard let app, let sessionId = mountTabId else { return }
        app.restorePendingNote(draft, forSessionId: sessionId)
    }

    #if DEBUG
    /// Test seams (same idiom as `WebLibrary.storeDirOverride`), because
    /// `attach` ends in a real `WKWebView` page load.
    ///
    /// Careful: `post` is NOT gated on the content script having reported in —
    /// only the `push*` helpers are — so it materialises the lazy web view.
    /// The dismissal paths reach it solely through `clearSelection()`, which
    /// the message branches below only call when a selection exists, and these
    /// seams never create one. Anything driven from here that could take a
    /// selection path needs re-checking against that.
    func bindForTesting(app: AppStore, tabId: String, annotationStore: AnnotationStore? = nil) {
        self.app = app
        mountTabId = tabId
        self.annotationStore = annotationStore
    }

    /// Opens a composer the way a placement click does. `openedAt` is settable
    /// so a test can age one past the `clickOutside` grace period without
    /// sleeping.
    func openNoteComposerForTesting(content: String, openedAt: Date = Date()) {
        noteComposer = WebNoteComposerState(
            point: .zero, anchor: Self.testAnchor, openedAt: openedAt, initialContent: content)
    }

    /// Arms the page context menu, minus the event monitor `showContextMenu`
    /// installs (there is no window to monitor here).
    func openContextMenuForTesting(anchored: Bool = true) {
        contextMenu = WebContextMenuState(
            point: .zero, anchor: anchored ? Self.testAnchor : nil, openedAt: Date())
    }

    /// Delivers a bridge message exactly as the content script would. The five
    /// incidental dismissals are all message branches, including the literal
    /// stray page click from issue #92, so without this seam none of them can
    /// be regression-tested.
    func handleBridgeMessageForTesting(_ type: String, _ payload: [String: Any] = [:]) {
        var body = payload
        body["vellum"] = true
        body["type"] = type
        handleMessage(body)
    }

    private static let testAnchor = WebNoteAnchor(
        start: 0, end: 0, text: "", prefix: nil, suffix: nil, pageNumber: 1)
    #endif

    func closeNoteViewer() { noteViewer = nil }
    func closeHighlightEditor() { highlightEditor = nil }

    /// Tear down every popover for a reason outside the user's intent: a tab
    /// switch, a link click, an SPA soft-navigation. None of those is a
    /// "discard", so the composer's draft goes back on the note queue —
    /// clicking a link on a dense article is at least as likely a misclick as
    /// clicking whitespace, and it used to lose the reply just as completely.
    func closeNotePopovers() {
        returnNoteComposerDraft()
        hideContextMenu()
        noteViewer = nil
        highlightEditor = nil
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

    /// Tell the content script which highlight is selected so it draws (or
    /// removes) the drag handles. Re-sent after each (re-)init because the
    /// injected script starts with no selection.
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

    /// Snapshot the web view region under `viewerRect` (the SwiftUI overlay's
    /// local coordinates, which sit directly over the web view) into an image
    /// for the scratchpad. Uses `WKWebView.takeSnapshot`; the resulting bytes
    /// run through the shared `scratchpadCapture` normalizer (downscale/encode).
    func captureRegion(viewerRect rect: CGRect) async -> ScratchpadImageCapture? {
        let clamped = rect.intersection(webView.bounds)
        guard clamped.width >= 4, clamped.height >= 4 else { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = clamped
        guard let image = try? await webView.takeSnapshot(configuration: config),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return scratchpadCapture(from: png)
    }

    /// Same crop, but encoded for a vision request instead of the scratchpad.
    /// Deliberately does NOT reuse `scratchpadCapture`: that normalizer keeps
    /// PNG verbatim up to 2000px, which turns a Retina viewport into megabytes
    /// of base64 on every send.
    func captureRegionImage(viewerRect rect: CGRect) async -> AiPageImageSnapshot? {
        await snapshot(rect: rect.intersection(webView.bounds))
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
    private func aiSnapshot(from image: NSImage, page: Int) -> AiPageImageSnapshot? {
        guard let tiff = image.tiffRepresentation,
              let source = NSBitmapImageRep(data: tiff) else { return nil }
        var pixelWidth = Double(source.pixelsWide)
        var pixelHeight = Double(source.pixelsHigh)
        guard pixelWidth >= 2, pixelHeight >= 2 else { return nil }
        let maxDimension = max(pixelWidth, pixelHeight)
        if maxDimension > 1280 {
            let scale = 1280 / maxDimension
            pixelWidth = max(1, (pixelWidth * scale).rounded())
            pixelHeight = max(1, (pixelHeight * scale).rounded())
        }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let target = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        NSColor.white.setFill()
        target.fill()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        else { return nil }
        return AiPageImageSnapshot(
            pageNumber: page,
            base64Data: jpeg.base64EncodedString(),
            mediaType: "image/jpeg",
            width: width,
            height: height
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

    /// Whether the page (rather than a native popover field) holds first
    /// responder — the discriminator between a real selection clear and the one
    /// WebKit performs when the web view is blurred.
    private var webViewHasFocus: Bool {
        guard let responder = webView.window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: webView)
    }

    // MARK: Coordinate mapping

    /// Map page-viewport coordinates to viewer coordinates (the page is
    /// scaled by pageZoom, so CSS px arrive unscaled).
    private func frameToParent(x: Double, y: Double) -> CGPoint {
        let scale = app?.zoom ?? 1
        return CGPoint(x: x * scale, y: y * scale)
    }

    // MARK: Context-menu dismissal (any app-shell click or Escape)

    private func showContextMenu(_ state: WebContextMenuState) {
        contextMenu = state
        contextMenuGlobalFrame = .zero
        installEventMonitor()
    }

    func hideContextMenu() {
        contextMenu = nil
        removeEventMonitor()
    }

    private func installEventMonitor() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .keyDown]
        ) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { // Escape
                    self.hideContextMenu()
                }
                return event
            }
            // Ignore clicks inside the menu itself (the button handles them).
            if let contentView = event.window?.contentView {
                var point = contentView.convert(event.locationInWindow, from: nil)
                if !contentView.isFlipped {
                    point.y = contentView.bounds.height - point.y
                }
                if self.contextMenuGlobalFrame.contains(point) {
                    return event
                }
            }
            self.hideContextMenu()
            return event
        }
    }

    private func removeEventMonitor() {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
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
            // While the popover's note field holds first responder the web view
            // has none, so WebKit has already thrown the DOM selection away:
            // this message is the blur artifact, not a user dismissal, and must
            // not unmount the composer. Once the page is focused again (a click
            // in it takes first responder before mouseup reports the collapse)
            // a clear means what it says, so the pin releases itself.
            if selectionNoteDraft == nil || webViewHasFocus {
                selection = nil
                popoverPosition = nil
                selectionNoteDraft = nil
            }
            // A plain click inside the page doubles as "click outside" for
            // the note popovers. The grace period keeps the event fired by
            // the opening click itself from instantly dismissing them.
            func clickOutside(_ openedAt: Date) -> Bool {
                Date().timeIntervalSince(openedAt) > 0.4
            }
            if let menu = contextMenu, clickOutside(menu.openedAt) { hideContextMenu() }
            if let viewer = noteViewer, clickOutside(viewer.openedAt) { noteViewer = nil }
            if let composer = noteComposer, clickOutside(composer.openedAt) {
                returnNoteComposerDraft()
            }
            if let editor = highlightEditor, clickOutside(editor.openedAt) { highlightEditor = nil }

        case "note-placed":
            // The whole branch is gated on this tab still being the active one,
            // not just the mode reset at the end: `consumePendingNoteContent`
            // below reads the *active* tab's queued AI reply, so a late message
            // from a tab the user has already left would otherwise steal the
            // reply queued for the tab now on screen.
            guard let anchor = parseNoteAnchor(data), let sessionId = mountTabId,
                  app.activeTabId == sessionId else { break }
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0)
            hideContextMenu()
            noteViewer = nil
            // An AI "Add as note" click carries the reply text; a plain note
            // tool click leaves it nil so the composer opens empty for typing.
            // This MUST happen before returning to view mode below, which drops
            // any unconsumed payload. Skipping it was the whole bug behind issue
            // #57's "Add as note just offers a new empty note": the PDF viewer
            // consumed the reply in `PdfSelectionBridge.placeNote`, the web
            // viewer never did, so the text was silently thrown away here.
            let pendingContent = app.consumePendingNoteContent()
            // Mirror the PDF viewer: placing a note returns to view mode — but
            // only when this message belongs to the tab that is still armed, so
            // a late message cannot reset a different session's mode. The
            // helper also rescues whatever the outgoing composer was holding.
            presentNoteComposer(
                WebNoteComposerState(
                    point: point,
                    anchor: anchor,
                    openedAt: Date(),
                    initialContent: pendingContent ?? ""),
                app: app,
                sessionId: sessionId)

        case "context-menu":
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0)
            returnNoteComposerDraft()
            noteViewer = nil
            let found = data["found"] as? Bool ?? false
            showContextMenu(WebContextMenuState(
                point: point,
                anchor: found ? parseNoteAnchor(data) : nil,
                openedAt: Date()))

        case "annotation-click":
            guard let id = data["id"] as? String, let annotationStore else { break }
            annotationStore.selectAnnotation(id)
            let annotation = annotationStore.annotations.first { $0.id == id }
            let point = frameToParent(
                x: doubleValue(data["x"]) ?? 0, y: doubleValue(data["y"]) ?? 0)
            if annotation?.type == .note {
                returnNoteComposerDraft()
                highlightEditor = nil
                hideContextMenu()
                noteViewer = WebNoteViewerState(id: id, point: point, openedAt: Date())
            } else if annotation?.type == .highlight {
                returnNoteComposerDraft()
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
                    id: id, color: nil, content: nil, positionData: positionData,
                    // A resize can drag the anchor across a virtual page break;
                    // keep the sidebar grouping/navigation on the new page.
                    pageNumber: intValue(data["pageNumber"])))
            }

        case "navigate":
            guard let url = data["url"] as? String else { break }
            navigateTo(url)

        case "open-youtube":
            // The YouTube facade (WebContentScript) hands embeds off to the system
            // browser — embeds need an http(s) Referer the proxy origin can't send.
            // Only a validated video id crosses the bridge, never a full URL, so a
            // hostile page script can at worst open a youtube.com/watch page.
            guard let id = data["id"] as? String,
                  id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil,
                  let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { break }
            NSWorkspace.shared.open(url)

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
            // Keep the composer only if it just opened (the placement click
            // can nudge scroll on some pages); otherwise typing continues.
            if let composer = noteComposer,
               Date().timeIntervalSince(composer.openedAt) >= 0.4 {
                returnNoteComposerDraft()
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
        guard let app, let tabId = mountTabId, app.containsTab(id: tabId) else { return }
        // A pending auto-archive for the outgoing page must not fire
        // against the rebound session.
        cancelPendingArchive()
        // Reset the one-shot redirect/crash reload guards for this fresh
        // navigation: they only need to prevent a reload *loop* within a single
        // navigation attempt. Left uncleared, revisiting a URL that was
        // reload-fixed once earlier this mount would skip its corrective reload
        // (redirect) or its crash-recovery reload (process crash) and recur.
        redirectReloadedUrl = nil
        processReloadedUrl = nil
        clearSelection()
        closeNotePopovers()
        let outgoing = mountDocument?.pdfPath
        Task { [weak self] in
            guard let rebound = await app.webNavigated(tabId: tabId, url: url),
                  let self, self.mountTabId == tabId, app.containsTab(id: tabId)
            else { return }
            self.mountDocument = rebound
            self.pendingNavUrl = rebound.pdfPath
            self.outgoingNavUrl = outgoing
            self.initCount = 0
            self.webView.load(
                URLRequest(url: VellumWebSchemeHandler.proxyUrl(for: rebound.pdfPath)))
        }
    }

    private func handleInit(_ data: [String: Any], app: AppStore) {
        guard let tabId = mountTabId, app.activeTabId == tabId,
              let currentDoc = mountDocument else { return }

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
                      let self, self.mountTabId == tabId, app.containsTab(id: tabId)
                else { return }
                self.mountDocument = rebound
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
                if let normalized = aiStore?.setPageText(page: number, text: text) {
                    runtime?.pageTexts[number] = normalized
                }
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
        // double-click selecting a word inside a highlight).
        highlightEditor = nil

        let scale = app.zoom
        popoverPosition = CGPoint(
            x: (last.x + last.width / 2) * scale,
            y: last.y * scale - 10)
        let next = WebSelection(
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
        // Selecting a different passage retires the pinned draft: a drag-select
        // never collapses the old selection, so no "selection-cleared" arrives to
        // release the pin, and a note typed for the old passage would anchor onto
        // this one. Re-reporting the same passage keeps the pin (and the note).
        if let draft = selectionNoteDraft, Self.identityKey(draft) != Self.identityKey(next) {
            selectionNoteDraft = nil
        }
        selection = next
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
        if !(value is NSNull), let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if !(value is NSNull), let number = value as? NSNumber {
            return number.doubleValue
        }
        return nil
    }
}

extension WebViewerController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handleMessage(message.body)
    }
}

extension WebViewerController: WKNavigationDelegate, WKUIDelegate {
    /// Scrolls the current page to `literal` (an already JSON-encoded "#frag")
    /// without waiting for the result.
    ///
    /// Deliberately the completion-handler form, and deliberately called from a
    /// non-async function so the compiler doesn't suggest the `async` one: the
    /// only caller is inside `decidePolicyFor`, and awaiting a round trip to the
    /// web content process while WebKit is still waiting on our navigation
    /// decision is a hang waiting to happen. Fire and forget is the behaviour we
    /// want here — the scroll is best-effort and its result is never read.
    @MainActor
    private static func setLocationHash(_ literal: String, in webView: WKWebView) {
        webView.evaluateJavaScript("location.hash = \(literal);", completionHandler: nil)
    }

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
            // schemes — those loads must always proceed.
            if scheme == VellumWebSchemeHandler.scheme
                || scheme == VellumWebSchemeHandler.insecureScheme {
                return .allow
            }
            guard isMainFrame else { return .allow }
            if let scheme, ["mailto", "tel", "facetime"].contains(scheme) {
                NSWorkspace.shared.open(url)
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
            // the JS string.
            if let data = try? JSONEncoder().encode("#" + fragment),
               let literal = String(data: data, encoding: .utf8) {
                Self.setLocationHash(literal, in: webView)
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
        guard let doc = mountDocument, doc.kind == .web else { return }
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
        guard let doc = mountDocument, doc.kind == .web else { return }
        // The fallback itself failing must not loop.
        guard webView.url?.host != VellumWebSchemeHandler.snapshotHost else { return }
        initCount = 0
        webView.load(URLRequest(
            url: VellumWebSchemeHandler.snapshotUrl(forKey: WebLibrary.pageKey(doc.pdfPath))))
    }
}

/// Breaks the WKUserContentController → handler retain cycle.
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
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
