import Foundation
import Observation
import PDFKit

/// Workspace-owned native state for one tab. Pane views are disposable layout
/// projections; this object is not, so switching tabs — or dragging a tab
/// between panes — does not destroy its PDFView/WKWebView or its partially
/// prepared document.
///
/// This is also the unit the residency policy reclaims: one runtime is one
/// `TabResidentResource` (see Services/TabResidency.swift). Everything
/// expensive a tab owns hangs off here and nowhere else, so an eviction that
/// drops the runtime's contents genuinely gives the memory back.
///
/// The runtime object itself survives eviction — it is just a tab id, a page-text
/// dictionary and a couple of nil-able controllers. What eviction throws away is
/// the native state hanging off it.
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

    /// The parsed, annotation-stripped display document, kept beside
    /// `pdfLoadState` so it survives a *cancelled* load. `.task(id: isActive)`
    /// is cancelled whenever the user switches away mid-load, which resets the
    /// state to `.idle`; without this the next visit would re-parse a document
    /// we had already finished parsing.
    ///
    /// This deliberately lives here rather than in an LRU on `AppStore`. A
    /// second cache elsewhere would mean an eviction that drops the runtime
    /// still leaves the `PDFDocument` alive in the LRU — i.e. the memory the
    /// eviction existed to reclaim would not actually come back.
    @ObservationIgnored private(set) var preparedDocument: PDFDocument?

    /// Size of the PDF bytes `preparedDocument` was parsed from, used to rank
    /// eviction candidates and enforce the byte budget. PDFKit's own footprint
    /// is larger (and unknowable), but the file size tracks it closely enough
    /// for ranking.
    @ObservationIgnored private var pdfByteCount = 0

    init(tabId: String) {
        self.tabId = tabId
    }

    /// Adopt a freshly parsed display document. `byteCount` is the size of the
    /// PDF data it was parsed from.
    func adoptPreparedPdf(_ document: PDFDocument, byteCount: Int) {
        preparedDocument = document
        pdfByteCount = byteCount
    }

    // MARK: - TabResidentResource

    /// Rough resident footprint. A PDF tab is costed at its file size; a web tab
    /// at a flat, deliberately pessimistic estimate for "a real webpage with its
    /// own web content process attached", because WebKit offers no way to ask
    /// what a given page actually costs. A tab that has never been shown holds
    /// neither and costs nothing.
    var residencyCostBytes: Int {
        pdfByteCount + webController.residencyCostBytes
    }

    /// Reclaim the native state. Reached from the residency policy (idle
    /// timeout, tab/byte ceiling, memory pressure) and directly on tab close.
    /// Idempotent.
    ///
    /// Nothing unsaved is lost here, and that is a property of the surrounding
    /// code rather than of this method: annotations are written through the
    /// session backend on every edit, the scroll position was mirrored into the
    /// `PdfTab` while the tab was still on screen, and the extraction walk's
    /// pages are handed to `PageTextPersister.flushDetached()` below — a real
    /// write that the quit path awaits via `awaitInFlightFlushes()`. The web
    /// side additionally holds its teardown open until a pending auto-archive
    /// lands (see `WebViewerController.releaseResidency`).
    func releaseResidency() {
        guard !isEvicted else { return }
        pdfController.flushAndDropPersister()
        pdfController.reset()
        webController.releaseResidency()
        // Drop the controller objects themselves: they strongly own the PDFView
        // and the WKWebView, so resetting alone would stop them without
        // releasing the memory this eviction is meant to reclaim.
        pdfController = PdfViewerController()
        webController = WebViewerController()
        pdfLoadState = .idle
        preparedDocument = nil
        pdfByteCount = 0
        // `pageTexts` is deliberately kept: it is a few hundred KB of strings at
        // most, it is what lets the AI context stay truthful while an evicted
        // viewer restores, and it saves the restore a full extraction walk.
        isEvicted = true
    }

    func reactivate() {
        guard isEvicted else { return }
        pdfLoadState = .idle
        isEvicted = false
    }

    func flushPdfText() async {
        await pdfController.pauseTextExtraction()
    }
}

extension LiveTabRuntime: TabResidentResource {}
