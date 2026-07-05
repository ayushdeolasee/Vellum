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
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var controller = WebViewerController()

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                WebViewRepresentable(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if controller.isOffline {
                    offlineBadge
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.trailing, 12)
                        .padding(.top, 12)
                }

                if controller.selection != nil, let position = controller.popoverPosition {
                    WebSelectionPopover(
                        position: position,
                        onHighlight: { color in controller.addHighlight(color: color) },
                        onNote: { content in controller.addSelectionNote(content: content) },
                        onClose: { controller.clearSelection() }
                    )
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
            controller.attach(app: appStore, annotationStore: annotationStore, aiStore: aiStore)
        }
        .onDisappear {
            controller.detach()
        }
        .onChange(of: controller.initCount) {
            controller.pushAnnotations(annotationStore.annotations)
            controller.pushMode(appStore.mode)
            controller.scrollToSelected(
                annotations: annotationStore.annotations,
                selectedId: annotationStore.selectedAnnotationId)
        }
        .onChange(of: annotationStore.annotations) {
            controller.pushAnnotations(annotationStore.annotations)
        }
        .onChange(of: appStore.mode) {
            controller.pushMode(appStore.mode)
        }
        .onChange(of: annotationStore.selectedAnnotationId) {
            controller.scrollToSelected(
                annotations: annotationStore.annotations,
                selectedId: annotationStore.selectedAnnotationId)
        }
        .onChange(of: appStore.zoom) { _, zoom in
            controller.applyZoom(zoom)
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumWebHistory)) { note in
            let delta = note.userInfo?["delta"] as? Int ?? 0
            controller.goHistory(delta: delta)
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
        controller.webView
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
    private(set) var noteComposer: WebNoteComposerState?
    private(set) var contextMenu: WebContextMenuState?
    private(set) var noteViewer: WebNoteViewerState?
    private(set) var highlightEditor: WebHighlightEditorState?

    /// Window-space frame of the context menu (for click-outside detection).
    @ObservationIgnored var contextMenuGlobalFrame: CGRect = .zero

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
    @ObservationIgnored private var pendingLocates: [String: (LocatedText?) -> Void] = [:]
    @ObservationIgnored private var pendingCaptures: [String: (CapturedWebPosition?) -> Void] = [:]
    @ObservationIgnored private var eventMonitor: Any?

    @ObservationIgnored private lazy var _webView: WKWebView = makeWebView()
    var webView: WKWebView { _webView }

    private func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            VellumWebSchemeHandler(), forURLScheme: VellumWebSchemeHandler.scheme)
        configuration.userContentController.add(
            WeakScriptMessageHandler(self), name: "vellum")
        let webView = WKWebView(frame: .zero, configuration: configuration)
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
        removeEventMonitor()
        // Only clear the shared handler slots when no replacement viewer has
        // taken over (handlers hold self weakly, so a stale slot is inert).
        if let app, app.activeTabId == mountTabId || app.document == nil {
            app.scrollToPageHandler = nil
            app.scrollToWebPositionHandler = nil
            annotationStore?.captureWebPositionHandler = nil
            aiStore?.locateWebTextHandler = nil
            app.findQueryHandler = nil
            app.findStepHandler = nil
            app.findClearHandler = nil
            app.printHandler = nil
        }
        webView.configuration.userContentController
            .removeScriptMessageHandler(forName: "vellum")
        webView.stopLoading()
    }

    // MARK: Outbound commands

    func post(_ command: String, _ payload: [String: Any] = [:]) {
        var message = payload
        message["vellumCmd"] = command
        guard JSONSerialization.isValidJSONObject(message),
              let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__vellumCmd && window.__vellumCmd(\(json));") { _, _ in }
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
        post("clear-selection")
    }

    func addHighlight(color: String) {
        guard let selection, let annotationStore else { return }
        let input = CreateAnnotationInput(
            type: .highlight,
            pageNumber: selection.pageNumber,
            color: color,
            content: nil,
            positionData: selection.positionData)
        Task { await annotationStore.addHighlight(input) }
    }

    func addSelectionNote(content: String) {
        guard let selection, let annotationStore else { return }
        let input = CreateAnnotationInput(
            type: .note,
            pageNumber: selection.pageNumber,
            color: nil,
            content: content,
            positionData: selection.positionData)
        Task { await annotationStore.addNote(input) }
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
            selection = nil
            popoverPosition = nil
            // A plain click inside the page doubles as "click outside" for
            // the note popovers. The grace period keeps the event fired by
            // the opening click itself from instantly dismissing them.
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

        case "navigate":
            guard let url = data["url"] as? String, let tabId = app.activeTabId else { break }
            // A pending auto-archive for the outgoing page must not fire
            // against the rebound session.
            cancelPendingArchive()
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

        case "viewport-scrolled":
            // Popovers are positioned from event-time rects; scrolling the
            // page underneath invalidates them.
            if selection != nil {
                selection = nil
                popoverPosition = nil
                post("clear-selection")
            }
            hideContextMenu()
            noteViewer = nil
            highlightEditor = nil
            // Keep the composer only if it just opened (the placement click
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

        if let reportedUrl, reportedUrl != currentDoc.pdfPath {
            // The page navigated (back/forward or a redirect changed the
            // effective URL): rebind the session, then ask the page to report
            // again so the fresh context lands after the App-level document
            // reset. Any open note popovers belong to the outgoing document.
            cancelPendingArchive()
            closeNotePopovers()
            Task { [weak self] in
                let rebound = await app.webNavigated(tabId: tabId, url: reportedUrl)
                if rebound != nil {
                    self?.post("request-init")
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
        // double-click selecting a word inside a highlight).
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

extension WebViewerController: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        handleMessage(message.body)
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
