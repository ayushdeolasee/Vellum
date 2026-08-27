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

/// What makes the viewer's load task run again: becoming active, or the tab's
/// file being replaced underneath it (`LiveTabRuntime.documentGeneration`).
private struct PdfLoadTrigger_iOS: Equatable {
    let isActive: Bool
    let generation: Int
}

struct PdfViewerView_iOS: View {
    let tabId: String
    let documentInfo: DocumentInfo
    /// Whether this mount is its pane's ACTIVE tab. Inactive mounts sit at
    /// opacity 0 inside `LiveTabHost_iOS` and must not push zoom/scroll/find
    /// state into the pane's shared stores.
    let isActive: Bool
    /// Everything expensive this tab owns: the PDF controller and its retained
    /// `PDFView`, the parsed document, the ink controller, the page-text cache.
    let runtime: LiveTabRuntime

    init(tabId: String, documentInfo: DocumentInfo, isActive: Bool, runtime: LiveTabRuntime) {
        self.tabId = tabId
        self.documentInfo = documentInfo
        self.isActive = isActive
        self.runtime = runtime
    }

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    private var controller: PdfViewerControlleriOS { runtime.pdfController }
    /// Pencil ink is per-DOCUMENT and therefore per-runtime. The pane used to
    /// own one controller for every tab it showed, which aliased page canvases
    /// across documents the moment two tabs were mounted at once.
    private var ink: InkController_iOS { runtime.ink }

    /// Tab the shared handler slots are currently registered for; nil when this
    /// view has no live registration (see `deactivate`'s ownership guard).
    @State private var handlersTabId: String?

    var body: some View {
        content()
            // First activation prepares the document. Subsequent activations
            // reuse the same PDFView/controller and only reclaim the shared
            // command handlers, preserving native scroll, selection and find
            // state. `documentGeneration` covers the one case where this tab's
            // file changes without the tab, the host or `isActive` changing.
            .task(id: PdfLoadTrigger_iOS(isActive: isActive, generation: runtime.documentGeneration)) {
                guard isActive else {
                    deactivate()
                    return
                }
                if case .idle = runtime.pdfLoadState {
                    await load(tabId: tabId)
                } else {
                    activate()
                }
            }
    }

    @ViewBuilder
    private func content() -> some View {
        switch runtime.pdfLoadState {
        case .readFailed(let message):
            statusView(Text("Failed to read PDF: \(message)").foregroundStyle(palette.destructive))
        case .parseFailed:
            statusView(Text("Failed to load PDF").foregroundStyle(palette.destructive))
        case .loaded(let document):
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    PdfKitView_iOS(
                        controller: controller, document: document, ink: ink, isActive: isActive)
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
        defer {
            // `.task(id:)` is intentionally cancelled on a rapid switch. Leave
            // the host retryable rather than stranded in its placeholder.
            if Task.isCancelled, case .loading = runtime.pdfLoadState {
                runtime.pdfLoadState = .idle
            }
        }
        unregisterHandlers()
        handlersTabId = nil
        controller.reset()
        runtime.pdfLoadState = .loading
        if isActive { aiStore.clearDocumentContext() }
        do {
            // The persistent text cache is keyed by the current PDF bytes, so
            // read them even when this tab can reuse an already prepared PDF.
            let data = try await app.sessions.readPdfBytes(sessionId: tabId)
            guard !Task.isCancelled, app.containsTab(id: tabId) else { return }
            let document: PDFDocument
            if let cached = runtime.preparedDocument {
                // Fast path: this tab already parsed its document and a switch
                // away cancelled the load before it finished wiring up. Reuse
                // the prepared document, skipping the parse and strip entirely.
                // Eviction clears it, so this can never resurrect a document the
                // residency policy has already reclaimed.
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
                guard !Task.isCancelled, app.containsTab(id: tabId) else { return }
                guard let parsed = prepared.document else {
                    runtime.pdfLoadState = .parseFailed
                    return
                }
                // The byte count is what the residency policy costs this tab at
                // when ranking eviction candidates against its byte budget.
                runtime.adoptPreparedPdf(parsed, byteCount: data.count)
                document = parsed
            }
            // Restore persisted page text before adopting (PDF only; the host
            // only builds this view for `kind == .pdf`). Hashing + JSON decode
            // run off the main actor inside the cache actor.
            //
            // Storage key resolved from the mounted DocumentInfo — not the
            // pane's active projection, which may already be another tab.
            let storageKey = DocumentIdentity.storageKey(for: documentInfo)
            let path = documentInfo.pdfPath
            let cached: [Int: String]?
            if !path.isEmpty {
                cached = await PageTextCache.shared.lookup(
                    key: storageKey, path: path, data: data, title: documentInfo.title)
            } else {
                cached = nil
            }
            guard !Task.isCancelled, app.containsTab(id: tabId) else { return }
            // Unconditional replace (empty on a miss): anything an outgoing
            // tab's extraction wrote into pageTexts during the awaits above
            // belongs to the OLD document and must not survive into this one.
            runtime.pageTexts = cached ?? [:]
            if isActive { aiStore.restorePageTexts(runtime.pageTexts) }
            let initialPage = app.tab(id: tabId)?.currentPage ?? 1
            controller.adopt(
                document: document,
                app: app,
                annotationStore: annotationStore,
                ai: aiStore,
                initialPage: initialPage,
                tabId: tabId,
                runtime: runtime
            )
            if isActive { app.setNumPages(document.pageCount) }
            if document.pageCount >= 1, !path.isEmpty {
                controller.installPersister(PageTextPersister(
                    key: storageKey,
                    path: path,
                    title: documentInfo.title,
                    pageCount: document.pageCount,
                    seeded: cached ?? [:]))
            }
            ink.pdfController = controller
            ink.app = app
            ink.isActive = false
            ink.inkProvider.resetCache()
            runtime.pdfLoadState = .loaded(document)
            if isActive {
                registerHandlers()
                handlersTabId = tabId
                controller.startTextExtraction(data: data)
            }
        } catch {
            guard !Task.isCancelled, app.containsTab(id: tabId) else { return }
            NSLog("[PdfViewer-iOS] readPdfBytes FAILED: %@", error.localizedDescription)
            runtime.pdfLoadState = .readFailed(error.localizedDescription)
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

    /// The tab is on screen again, with its document already loaded: reclaim
    /// the pane's shared handler slots and re-point the controller at whichever
    /// pane now hosts it (a tab can be dragged between panes while warm).
    private func activate() {
        guard app.activeTabId == tabId else { return }
        controller.rebind(
            app: app, annotationStore: annotationStore, ai: aiStore,
            tabId: tabId, runtime: runtime)
        ink.pdfController = controller
        ink.app = app
        aiStore.restorePageTexts(runtime.pageTexts)
        registerHandlers()
        handlersTabId = tabId
        if case .loaded(let pdf) = runtime.pdfLoadState {
            app.setNumPages(pdf.pageCount)
            Task { await resumeTextExtraction(pageCount: pdf.pageCount) }
        }
    }

    /// Pick the background text walk back up where the last deactivation parked
    /// it. The bytes are re-read rather than kept on the controller: the iPad
    /// walk runs over a PRIVATE `PDFDocument(data:)` copy (that is what keeps it
    /// off the main actor), so retaining the data would mean a second full copy
    /// of every large scanned PDF alive for the life of the tab — precisely the
    /// footprint the residency ceilings exist to bound. Fully-indexed documents
    /// never pay the read at all.
    private func resumeTextExtraction(pageCount: Int) async {
        guard runtime.pageTexts.count < pageCount else { return }
        guard let data = try? await app.sessions.readPdfBytes(sessionId: tabId) else { return }
        guard !Task.isCancelled, app.activeTabId == tabId else { return }
        controller.startTextExtraction(data: data)
    }

    /// The tab went to the background. The document, the `PDFView` and the
    /// extracted text all stay exactly where they are — only the walk stops and
    /// the shared handler slots are given up.
    private func deactivate() {
        controller.pauseTextExtraction()
        guard handlersTabId == tabId else { return }
        // If another document host is taking over it owns these shared slots
        // now (or is about to), and clearing blindly here can race its
        // registration. An empty pane has no replacement viewer, so clear then.
        if app.document == nil {
            unregisterHandlers()
            aiStore.clearDocumentContext()
        }
        handlersTabId = nil
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
                RegionCaptureOverlay_iOS(tool: app.regionCaptureTool) { rect in
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
