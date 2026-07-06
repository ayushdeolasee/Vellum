#if os(macOS)
import PDFKit
import SwiftUI

// SwiftUI shell of the PDF viewer — port of src/components/pdf/PdfViewer.tsx.
// Loads the document as DATA via readPdfBytes (mutations rewrite the file on
// disk; the in-view document is the in-memory copy and annotations render only
// from store overlays), hosts PdfKitView plus the overlay stack, and registers
// the zoom/scroll/locator/snapshot handlers on the stores.

struct PdfViewerView: View {
    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var controller = PdfViewerController()
    @State private var loadState: LoadState = .idle
    /// Tab the shared handler slots are currently registered for; nil when
    /// this view has no live registration (see teardown's ownership guard).
    @State private var handlersTabId: String?

    private enum LoadState {
        case idle
        case loading
        /// readPdfBytes failed.
        case readFailed(String)
        /// Bytes arrived but PDFKit could not parse them (pdf.js error state).
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
            // Explicit concrete frame from the container size. PDFView's own
            // fitting size is the full document (much larger than the viewport
            // when zoomed in); pinning the host to the geometry size stops
            // SwiftUI from ever adopting that intrinsic size during a relayout
            // (highlight add/remove) or a zoom, which would oversize the view
            // and break scrolling to the page edges.
            GeometryReader { geo in
                ZStack(alignment: .topLeading) {
                    PdfKitView(controller: controller, document: document)
                        .id(loadedTabId)
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
        unregisterHandlers()
        handlersTabId = nil
        controller.reset()
        loadState = .loading
        // Document/tab changed: reset the AI document context (PdfViewer.tsx
        // clears it alongside the local state reset).
        aiStore.clearDocumentContext()
        do {
            let data = try await app.sessions.readPdfBytes(sessionId: tabId)
            guard !Task.isCancelled, app.activeTabId == tabId else { return }
            guard let document = PDFDocument(data: data) else {
                loadState = .parseFailed
                return
            }
            controller.adopt(
                document: document,
                app: app,
                annotationStore: annotationStore,
                ai: aiStore,
                initialPage: app.currentPage
            )
            app.setNumPages(document.pageCount)
            registerHandlers()
            handlersTabId = tabId
            loadState = .loaded(document, tabId: tabId)
            controller.startTextExtraction()
        } catch {
            guard !Task.isCancelled, app.activeTabId == tabId else { return }
            NSLog("[PdfViewer] readPdfBytes FAILED: %@", error.localizedDescription)
            loadState = .readFailed(error.localizedDescription)
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
    }

    private func teardown() {
        // SwiftUI mounts the replacement viewer (onAppear/task) BEFORE this
        // onDisappear fires, so only clear the shared handler slots and the AI
        // document context when no replacement viewer has taken over — same
        // ownership guard as WebViewerController.detach. A replacement's own
        // load() unconditionally unregisters before re-registering, so stale
        // handlers never leak.
        if app.activeTabId == handlersTabId || app.document == nil {
            unregisterHandlers()
            aiStore.clearDocumentContext()
        }
        handlersTabId = nil
        controller.reset()
        loadState = .idle
    }
}

#endif  // os(macOS) — iPad reference; see Platform/iOS
