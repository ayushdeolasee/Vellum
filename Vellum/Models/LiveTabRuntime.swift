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

    /// Whether this tab is in the hot tier and should therefore be mounted and
    /// drawn. `PaneView` reads it, so it is observed: a demotion on the
    /// sweeper's tick pulls the viewer out of the rendered tree by itself.
    ///
    /// Starts `false` — a tab the user has never opened has nothing to render
    /// and should not build a viewer just to sit at opacity 0. The residency
    /// policy sets it on the first activation.
    private(set) var isRendered = false

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

    /// Bumped when the tab keeps its identity while the file underneath it
    /// changes — PDF Save As retargets a *live* tab to a new location instead of
    /// closing and reopening it. The mounted viewer keys its load task on this,
    /// because neither `isActive` nor the view's structural identity changes
    /// across a retarget, so nothing else would make it re-read the file.
    private(set) var documentGeneration = 0

    /// Drop the document parsed from the tab's previous location and ask the
    /// mounted viewer to load again. Unlike `releaseResidency` the tab stays
    /// resident: only the parsed document is discarded, and the persister is
    /// flushed first so page text extracted from the old location is written
    /// under the key it was gathered with.
    func invalidateLoadedPdf() {
        pdfController.flushAndDropPersister()
        preparedDocument = nil
        pdfByteCount = 0
        pdfLoadState = .idle
        documentGeneration += 1
    }

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

    /// Hot ⇄ warm. Warm keeps everything expensive — the parsed `PDFDocument`,
    /// the `PDFView`, the `WKWebView` and its content process are all still
    /// here, held by the controllers below — and only stops the tab being drawn:
    /// `PaneView` swaps the viewer for `Color.clear`, which unmounts the
    /// representable and takes the native view out of the window's layout and
    /// display cycle. Coming back re-parents that same native view instead of
    /// rebuilding it, which is the point of having a middle tier at all.
    ///
    /// The equality guard is a cheap early-out, not a correctness requirement:
    /// this runs for every resident tab on every sweeper tick, and skipping the
    /// registrar call entirely is free. Measured, so nobody has to wonder:
    /// Observation does *not* notify on a write of an equal value, so removing
    /// the guard would not actually invalidate anything — which also means no
    /// test can distinguish the two, and there deliberately isn't one.
    func applyResidencyTier(_ tier: TabResidencyTier) {
        let rendered = tier == .hot
        guard isRendered != rendered else { return }
        isRendered = rendered
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
        isRendered = false
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
