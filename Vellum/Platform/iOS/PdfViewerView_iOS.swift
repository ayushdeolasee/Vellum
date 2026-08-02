#if os(iOS)
import PDFKit
import SwiftUI

// SwiftUI shell of the iPad PDF viewer. Loads the document as DATA via
// readPdfBytes (mutations rewrite the file on disk; the in-view document is the
// in-memory copy and annotations render only from store overlays), hosts
// PdfKitView_iOS plus the touch overlay stack, and registers the zoom/scroll/
// locator/snapshot handlers on the stores — the same contract as the macOS
// PdfViewerView.

/// Carries a prepared (parsed + stripped) PDFDocument out of a detached task.
/// PDFDocument isn't Sendable, but this instance is freshly created there and
/// never touched off-main again, so the crossing is safe.
private struct PreparedPdf: @unchecked Sendable {
    let document: PDFDocument?
}

struct PdfViewerView_iOS: View {
    var ink: InkController_iOS

    // MARK: - Live-tab mount contract (packet 4 §2.0) — accepted, not honoured
    //
    // `(tabId:documentInfo:isActive:runtime:)` is the shape packet 7's rebuilt
    // viewer takes, so that `LiveTabHost_iOS` can mount one of these per open
    // tab instead of one per pane. Interface only for now: nothing constructs a
    // `LiveTabRuntime`, nothing calls that initializer, and the four values
    // below are stored and never read. The body still resolves the document
    // through `app.document` / `app.activeTabId` and still owns its controller
    // in `@State`, exactly as before.
    //
    // Packet 7 deletes `init(ink:)`, drops the optionality, and switches the
    // body over to these — gating every `onChange`-driven push on
    // `isActiveMount` and taking the controller from `mountedRuntime`.

    /// Tab this host is mounted for; `nil` on the pre-live-tabs path.
    private let mountedTabId: String?
    /// Document this host is mounted for; `nil` on the pre-live-tabs path.
    private let mountedDocument: DocumentInfo?
    /// Whether this mount is its pane's ACTIVE tab. Inactive mounts sit at
    /// opacity 0 and must not push zoom/scroll/find state into the shared
    /// stores. Defaults to `true` on the pre-live-tabs path, where the single
    /// mounted viewer is by definition the active one — so every push that runs
    /// today still runs.
    private let isActiveMount: Bool
    /// The tab's workspace-owned runtime: the controller, the retained
    /// `PDFView`, the ink controller and the prepared document all come from
    /// here once packet 7 lands. `nil` on the pre-live-tabs path.
    private let mountedRuntime: LiveTabRuntime?

    init(ink: InkController_iOS) {
        self.ink = ink
        self.mountedTabId = nil
        self.mountedDocument = nil
        self.isActiveMount = true
        self.mountedRuntime = nil
    }

    /// The live-tab entry point. Declared so packet 7 has a compiler-checked
    /// target and packet 4 §2.8 has something to call; the arguments are
    /// accepted and ignored until packet 7 honours them.
    init(tabId: String, documentInfo: DocumentInfo, isActive: Bool, runtime: LiveTabRuntime) {
        self.ink = runtime.ink
        self.mountedTabId = tabId
        self.mountedDocument = documentInfo
        self.isActiveMount = isActive
        self.mountedRuntime = runtime
    }

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var controller = PdfViewerControlleriOS()
    @State private var loadState: LoadState = .idle
    @State private var handlersTabId: String?

    private enum LoadState {
        case idle
        case loading
        case readFailed(String)
        case parseFailed
        case loaded(PDFDocument, tabId: String)
    }

    var body: some View {
        if let document = app.document, document.kind == .pdf, let tabId = app.activeTabId {
            content(tabId: tabId)
                .task(id: tabId) { await load(tabId: tabId) }
                .onDisappear { teardown() }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(tabId: String) -> some View {
        switch loadState {
        case .readFailed(let message):
            statusView(Text("Failed to read PDF: \(message)").foregroundStyle(palette.destructive))
        case .parseFailed:
            statusView(Text("Failed to load PDF").foregroundStyle(palette.destructive))
        case .loaded(let document, let loadedTabId) where loadedTabId == tabId:
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    PdfKitView_iOS(controller: controller, document: document, ink: ink)
                        .frame(width: geo.size.width, height: geo.size.height)
                    PdfOverlayStack_iOS(controller: controller)
                }
                .overlay(alignment: .bottom) {
                    if ink.isActive {
                        InkToolPalette_iOS(ink: ink) { ink.isActive = false }
                            .padding(.bottom, 24)
                    }
                }
            }
        default:
            statusView(Text("Loading PDF...").foregroundStyle(palette.mutedForeground))
        }
    }

    private func statusView(_ label: Text) -> some View {
        ZStack {
            palette.well
            label.font(.system(size: 15))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(tabId: String) async {
        unregisterHandlers()
        handlersTabId = nil
        controller.reset()
        loadState = .loading
        aiStore.clearDocumentContext()
        do {
            // The persistent text cache is keyed by the current PDF bytes, so
            // read them even when this tab can reuse an already prepared PDF.
            let data = try await app.sessions.readPdfBytes(sessionId: tabId)
            guard !Task.isCancelled, app.activeTabId == tabId else { return }
            let document: PDFDocument
            if let cached = app.cachedPreparedPdf(tabId: tabId) {
                // Fast path: this tab was opened recently — reuse the prepared
                // document, skipping the parse and strip entirely.
                document = cached
            } else {
                // Parse the PDF and strip its embedded annotations OFF the main
                // thread — both are heavy CGPDF work that would otherwise freeze
                // the UI (beachball) on every tab switch for a large document.
                // The document isn't attached to any view yet, so this is safe.
                let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedPdf in
                    guard let document = PDFDocument(data: data) else { return PreparedPdf(document: nil) }
                    for index in 0..<document.pageCount {
                        guard let page = document.page(at: index) else { continue }
                        for annotation in page.annotations {
                            page.removeAnnotation(annotation)
                        }
                    }
                    return PreparedPdf(document: document)
                }.value
                guard !Task.isCancelled, app.activeTabId == tabId else { return }
                guard let parsed = prepared.document else {
                    loadState = .parseFailed
                    return
                }
                app.storePreparedPdf(parsed, tabId: tabId)
                document = parsed
            }
            // Restore persisted page text before adopting (PDF only; this view
            // is guarded to document.kind == .pdf). Hashing + JSON decode run
            // off the main actor inside the cache actor.
            // Storage key resolved from the just-opened DocumentInfo: its docId
            // when the file carries one, else the path hash. The write path
            // keyed itself the same way at open (PdfSessionCacheKeys), so
            // lookup, persister, and every in-app refreshHash agree for the
            // whole session.
            let storageKey = app.document.map { DocumentIdentity.storageKey(for: $0) }
            let cached: [Int: String]?
            if let path = app.document?.pdfPath, let storageKey {
                cached = await PageTextCache.shared.lookup(
                    key: storageKey, path: path, data: data, title: app.document?.title)
            } else {
                cached = nil
            }
            guard !Task.isCancelled, app.activeTabId == tabId else { return }
            // Unconditional replace (empty on a miss): anything an outgoing
            // tab's extraction wrote into pageTexts during the awaits above
            // belongs to the OLD document and must not survive into this one.
            aiStore.restorePageTexts(cached ?? [:])
            controller.adopt(
                document: document,
                app: app,
                annotationStore: annotationStore,
                ai: aiStore,
                initialPage: app.currentPage
            )
            app.setNumPages(document.pageCount)
            if document.pageCount >= 1, let path = app.document?.pdfPath, let storageKey {
                controller.installPersister(PageTextPersister(
                    key: storageKey,
                    path: path,
                    title: app.document?.title,
                    pageCount: document.pageCount,
                    seeded: cached ?? [:]))
            }
            ink.pdfController = controller
            ink.app = app
            ink.isActive = false
            ink.inkProvider.resetCache()
            registerHandlers()
            handlersTabId = tabId
            loadState = .loaded(document, tabId: tabId)
            controller.startTextExtraction(data: data)
        } catch {
            guard !Task.isCancelled, app.activeTabId == tabId else { return }
            NSLog("[PdfViewer-iOS] readPdfBytes FAILED: %@", error.localizedDescription)
            loadState = .readFailed(error.localizedDescription)
        }
    }

    private func registerHandlers() {
        app.zoomToHandler = { [weak controller] target in
            MainActor.assumeIsolated { controller?.zoomTo(target) }
        }
        app.scrollToPageHandler = { [weak controller] page in
            MainActor.assumeIsolated { controller?.scrollToPage(page) }
        }
        aiStore.locatePdfTextHandler = { [weak controller] page, query in
            await controller?.locateText(pageNumber: page, query: query)
        }
        aiStore.capturePageImageHandler = { [weak controller] page in
            await controller?.capturePageImage(pageNumber: page)
        }
        app.findQueryHandler = { [weak controller] query in
            MainActor.assumeIsolated { controller?.findQuery(query) }
        }
        app.findStepHandler = { [weak controller] delta in
            MainActor.assumeIsolated { controller?.findStep(delta) }
        }
        app.findClearHandler = { [weak controller] in
            MainActor.assumeIsolated { controller?.findClear() }
        }
        app.printHandler = { [weak controller] in
            MainActor.assumeIsolated { controller?.printDocument() }
        }
        app.flushPageTextCacheHandler = { [weak controller] in
            await controller?.flushPersister()
        }
    }

    private func unregisterHandlers() {
        app.zoomToHandler = nil
        app.scrollToPageHandler = nil
        aiStore.locatePdfTextHandler = nil
        aiStore.capturePageImageHandler = nil
        app.findQueryHandler = nil
        app.findStepHandler = nil
        app.findClearHandler = nil
        app.printHandler = nil
        app.flushPageTextCacheHandler = nil
    }

    private func teardown() {
        if app.activeTabId == handlersTabId || app.document == nil {
            unregisterHandlers()
            aiStore.clearDocumentContext()
        }
        handlersTabId = nil
        controller.reset()
        loadState = .idle
    }
}

/// Touch overlay stack: per-page highlight/note layers, the selection popover,
/// and the note-mode placement layer. Positions everything in viewer top-left
/// coordinates, recomputed on every controller.geometryVersion bump.
struct PdfOverlayStack_iOS: View {
    let controller: PdfViewerControlleriOS

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(ScratchpadStore.self) private var scratchpadStore
    @Environment(\.palette) private var palette

    private struct PageOverlay: Equatable {
        var pageNumber: Int
        var frame: CGRect
        var annotations: [Annotation]
    }

    var body: some View {
        let _ = controller.geometryVersion
        let scale = controller.pdfView.map { Double($0.scaleFactor) } ?? app.zoom
        ZStack(alignment: .topLeading) {
            // Note-mode: a clear layer that captures the placement tap so it
            // never reaches the PDFView's own selection handling.
            if app.mode == .note {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { location in
                        controller.handleNoteTap(atTopLeft: location)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Drag-to-crop region snapshot. Sits above the page layers so its
            // marquee owns the touch; the scrim swallows the drag before the
            // PDFView sees it. The crop goes to whichever panel armed the mode
            // (AppStore.regionCaptureTarget).
            if app.mode == .snapshotRegion {
                RegionCaptureOverlay_iOS { rect in
                    // `finishRegionCapture` hands back the destination the tab
                    // armed and returns to view mode in one step; reading
                    // `regionCaptureTarget` after the reset would always say
                    // `.ai`.
                    let target = app.finishRegionCapture()
                    captureRegion(rect, target: target)
                } onCancel: {
                    // Plain tap or tiny wobble: back out without a warning — the
                    // user changed their mind.
                    app.setMode(.view)
                }
                .zIndex(60)
            }

            ForEach(pageOverlays, id: \.pageNumber) { overlay in
                HighlightLayer(
                    annotations: overlay.annotations,
                    zoom: scale,
                    controller: controller)
                    .frame(width: overlay.frame.width, height: overlay.frame.height,
                           alignment: .topLeading)
                    .offset(x: overlay.frame.minX, y: overlay.frame.minY)
            }

            if let selection = controller.selection,
               let position = controller.selectionPopoverPosition {
                AnchoredAbove(point: position) {
                    SelectionPopover(selection: selection) {
                        controller.clearSelection()
                    }
                }
                .zIndex(50)
            }

            if let menu = controller.contextMenu {
                PdfNoteContextMenu_iOS {
                    controller.addNoteFromContextMenu()
                }
                .offset(x: menu.location.x, y: menu.location.y)
                .zIndex(50)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }

    /// Hand the finished crop to whichever panel armed the capture. The AI path
    /// stays silent on a miss (it just re-arms nothing); the scratchpad path
    /// warns, since its button is the one the user pressed to get here.
    private func captureRegion(_ rect: CGRect, target: RegionCaptureTarget) {
        switch target {
        case .ai:
            // A region crop always lands on a page (capturePageRegion bails
            // otherwise), so the snapshot's optional page is always populated.
            if let snapshot = controller.capturePageRegion(viewerRect: rect),
               let page = snapshot.pageNumber {
                aiStore.addReference(AiReference(kind: .region(image: snapshot, page: page)))
            }
        case .scratchpad:
            if let capture = controller.capturePageRegionData(viewerRect: rect) {
                let label = capture.pageNumber.map { "Region · p.\($0)" } ?? "Region"
                scratchpadStore.addImage(capture, label: label)
            } else {
                // Drag missed a page or was too small to crop — tell the user
                // rather than silently reverting to view mode.
                scratchpadStore.warnRegionCaptureFailed()
            }
        }
    }

    private var pageOverlays: [PageOverlay] {
        overlayPages.compactMap { pageNumber in
            let annotations = annotationStore.annotationsForPage(pageNumber)
            guard !annotations.isEmpty,
                  let frame = controller.pageViewFrame(pageNumber: pageNumber)
            else { return nil }
            return PageOverlay(pageNumber: pageNumber, frame: frame, annotations: annotations)
        }
    }

    private var overlayPages: [Int] {
        let numPages = app.numPages
        guard numPages >= 1 else { return [] }
        let center = app.visiblePages.isEmpty ? [app.currentPage] : app.visiblePages
        let low = max(1, (center.first ?? 1) - 2)
        let high = min(numPages, (center.last ?? 1) + 2)
        guard low <= high else { return [] }
        return Array(low...high)
    }
}

/// "Add note here" pill (touch context menu).
struct PdfNoteContextMenu_iOS: View {
    var onAddNote: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: onAddNote) {
            HStack(spacing: 8) {
                Image(systemName: "note.text")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(hex: "#f59e0b"))
                Text("Add note here")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.foreground)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.lg))
        .fixedSize()
    }
}
#endif
