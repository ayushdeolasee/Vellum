import PDFKit
import SwiftUI

// SwiftUI shell of the PDF viewer — port of src/components/pdf/PdfViewer.tsx.
// Loads the document as DATA via readPdfBytes (mutations rewrite the file on
// disk; the in-view document is the in-memory copy and annotations render only
// from store overlays), hosts PdfKitView plus the overlay stack, and registers
// the zoom/scroll/locator/snapshot handlers on the stores.

/// Carries a prepared (parsed + stripped) PDFDocument out of a detached task.
/// PDFDocument isn't Sendable, but this instance is freshly created there and
/// never touched off-main again, so the crossing is safe.
private struct PreparedPdf: @unchecked Sendable {
    let document: PDFDocument?
}

struct PdfViewerView: View {
    let tabId: String
    let documentInfo: DocumentInfo
    let isActive: Bool
    let runtime: LiveTabRuntime

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    private var controller: PdfViewerController { runtime.pdfController }
    /// Tab the shared handler slots are currently registered for; nil when
    /// this view has no live registration (see teardown's ownership guard).
    @State private var handlersTabId: String?

    var body: some View {
        content(tabId: tabId)
            // First activation prepares the document. Subsequent activations
            // reuse the same PDFView/controller and only reclaim shared command
            // handlers, preserving native scroll, selection, and find state.
            .task(id: isActive) {
                guard isActive else {
                    await deactivate()
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
    private func content(tabId: String) -> some View {
        switch runtime.pdfLoadState {
        case .readFailed(let message):
            statusView(Text("Failed to read PDF: \(message)").foregroundStyle(palette.destructive))
        case .parseFailed:
            statusView(Text("Failed to load PDF").foregroundStyle(palette.destructive))
        case .loaded(let document):
            // Explicit concrete frame from the container size. PDFView's own
            // fitting size is the full document (much larger than the viewport
            // when zoomed in); pinning the host to the geometry size stops
            // SwiftUI from ever adopting that intrinsic size during a relayout
            // (highlight add/remove) or a zoom, which would oversize the view
            // and break scrolling to the page edges.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    PdfKitView(
                        controller: controller,
                        document: document,
                        isActive: isActive)
                        .frame(width: geo.size.width, height: geo.size.height)
                    PdfOverlayStack(controller: controller)
                }
            }
        default:
            statusView(Text("Loading PDF...").foregroundStyle(palette.mutedForeground))
        }
    }

    private func statusView(_ label: Text) -> some View {
        ZStack {
            palette.muted
            label.font(.system(size: 14))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(tabId: String) async {
        defer {
            // `.task(id: isActive)` is intentionally cancelled on a rapid
            // switch. Leave the host retryable rather than stranded forever in
            // its loading placeholder.
            if Task.isCancelled, case .loading = runtime.pdfLoadState {
                runtime.pdfLoadState = .idle
            }
        }
        // The OUTGOING document's pending page text is flushed by ITS OWN
        // view's teardown/reset (flushAndDropPersister — this view's fresh
        // controller has no persister to flush); the quit path additionally
        // awaits those detached flushes via awaitInFlightFlushes.
        unregisterHandlers()
        handlersTabId = nil
        controller.reset()
        runtime.pdfLoadState = .loading
        // Document/tab changed: reset the AI document context (PdfViewer.tsx
        // clears it alongside the local state reset).
        if isActive { aiStore.clearDocumentContext() }
        do {
            // The persistent text cache is keyed by the current PDF bytes, so
            // read them even when this tab can reuse an already prepared PDF.
            let data = try await app.sessions.readPdfBytes(sessionId: tabId)
            guard !Task.isCancelled, app.containsTab(id: tabId) else { return }
            let document: PDFDocument
            if let cached = app.cachedPreparedPdf(tabId: tabId) {
                // Fast path: this tab was opened recently — reuse the prepared
                // document, skipping the disk read, parse, and strip entirely.
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
                app.storePreparedPdf(parsed, tabId: tabId)
                document = parsed
            }
            // Restore persisted page text before adopting (PDF only; this view
            // is guarded to document.kind == .pdf). Hashing + JSON decode run
            // off the main actor inside the cache actor.
            // Storage key resolved from the just-opened DocumentInfo: its docId
            // when the file carries one, else the path hash. The IO actor keyed
            // itself the same way at open, so lookup, persister, and every
            // in-app refreshHash agree for the whole session.
            let storageKey = DocumentIdentity.storageKey(for: documentInfo)
            let cached: [Int: String]?
            let path = documentInfo.pdfPath
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
            if document.pageCount >= 1 {
                controller.installPersister(PageTextPersister(
                    key: storageKey,
                    path: path,
                    title: documentInfo.title,
                    pageCount: document.pageCount,
                    seeded: cached ?? [:]))
            }
            runtime.pdfLoadState = .loaded(document)
            if isActive { activate() }
        } catch {
            guard !Task.isCancelled, app.containsTab(id: tabId) else { return }
            NSLog("[PdfViewer] readPdfBytes FAILED: %@", error.localizedDescription)
            runtime.pdfLoadState = .readFailed(error.localizedDescription)
        }
    }

    private func registerHandlers() {
        app.zoomToHandler = { [weak controller] target in
            MainActor.assumeIsolated {
                controller?.zoomTo(target)
            }
        }
        app.scrollToPageHandler = { [weak controller] page in
            MainActor.assumeIsolated {
                controller?.scrollToPage(page)
            }
        }
        aiStore.locatePdfTextHandler = { [weak controller] page, query in
            await controller?.locateText(pageNumber: page, query: query)
        }
        aiStore.capturePageImageHandler = { [weak controller] page in
            await controller?.capturePageImage(pageNumber: page)
        }
        aiStore.ensureExtractedHandler = { [weak controller] pages in
            await controller?.ensureExtracted(pages: pages) ?? 0
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

    private func activate() {
        guard app.activeTabId == tabId else { return }
        controller.rebind(
            app: app, annotationStore: annotationStore, ai: aiStore, tabId: tabId,
            runtime: runtime)
        aiStore.restorePageTexts(runtime.pageTexts)
        registerHandlers()
        handlersTabId = tabId
        controller.startTextExtraction()
        if case .loaded(let pdf) = runtime.pdfLoadState {
            app.setNumPages(pdf.pageCount)
        }
    }

    private func deactivate() async {
        await controller.pauseTextExtraction()
        guard handlersTabId == tabId else { return }
        // If another document host is taking over, it owns these shared slots
        // now (or is about to). Clearing blindly here can race after its
        // registration. Home has no replacement viewer, so clear in that case.
        if app.document == nil {
            unregisterHandlers()
        }
        handlersTabId = nil
    }

    private func unregisterHandlers() {
        app.zoomToHandler = nil
        app.scrollToPageHandler = nil
        aiStore.locatePdfTextHandler = nil
        aiStore.capturePageImageHandler = nil
        aiStore.ensureExtractedHandler = nil
        app.findQueryHandler = nil
        app.findStepHandler = nil
        app.findClearHandler = nil
        app.printHandler = nil
        app.flushPageTextCacheHandler = nil
    }

}
