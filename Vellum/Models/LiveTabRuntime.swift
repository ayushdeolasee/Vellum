import Foundation
import Observation
import PDFKit

/// Workspace-owned native state for one tab. Pane views are disposable layout
/// projections; this object is not, so dragging a tab between panes does not
/// destroy its PDFView/WKWebView or partially prepared document.
@MainActor
@Observable
final class LiveTabRuntime {
    enum PdfLoadState {
        case idle
        case loading
        case readFailed(String)
        case parseFailed
        case loaded(PDFDocument)
    }

    let tabId: String
    var pdfController = PdfViewerController()
    var webController = WebViewerController()
    var pdfLoadState: PdfLoadState = .idle
    var pageTexts: [Int: String] = [:]
    private(set) var isEvicted = false
    @ObservationIgnored var accessOrdinal = 0

    init(tabId: String) {
        self.tabId = tabId
    }

    func reactivate() {
        guard isEvicted else { return }
        pdfLoadState = .idle
        isEvicted = false
    }

    func evict() {
        guard !isEvicted else { return }
        pdfController.flushAndDropPersister()
        pdfController.reset()
        webController.detach()
        // Drop the controller objects themselves: WebViewerController strongly
        // owns its WKWebView, so detach alone would stop it without releasing
        // the memory this eviction is meant to reclaim.
        pdfController = PdfViewerController()
        webController = WebViewerController()
        pdfLoadState = .idle
        // Text is cheap compared with native PDFKit/WebKit state and lets the
        // AI context remain truthful while the evicted viewer restores.
        isEvicted = true
    }

    func flushPdfText() async {
        await pdfController.pauseTextExtraction()
    }
}
