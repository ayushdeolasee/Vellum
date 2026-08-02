import Foundation
import Observation
import PDFKit

/// Workspace-owned native state for one tab. Pane views are disposable layout
/// projections; this object is not, so switching tabs — or dragging a tab
/// between panes — does not destroy its PDFView/WKWebView or its partially
/// prepared document.
///
/// This is also the unit the residency policy reclaims: one runtime is one
/// resident resource. Everything expensive a tab owns hangs off here and
/// nowhere else, so an eviction that drops the runtime's contents genuinely
/// gives the memory back.
///
/// The runtime object itself survives eviction — it is just a tab id, a
/// page-text dictionary and a couple of controllers. What eviction throws away
/// is the native state hanging off it.
///
/// ## Interface-only, for now (packet 4 §2.0 — the C3 cycle break)
///
/// This file currently ships the cross-packet contract and **nothing else**.
/// Nothing in the app constructs a `LiveTabRuntime` yet: `WorkspaceStore` gains
/// `liveTabRuntime(for:)` in packet 4 §2.5 and `PaneView_iOS` starts mounting
/// one host per tab in §2.8. Until then every member below is inert, which is
/// the point — packet 7 can rebuild the viewers against these names while
/// packet 4 builds the residency policy behind them, and neither has to wait.
///
/// Deliberately **not** here yet, so this commit stays behaviour-free:
/// `pdfLoadState`, `isRendered`, `isEvicted`, `invalidateLoadedPdf()`,
/// `applyResidencyTier(_:)`, `releaseResidency()`, `reactivate()`,
/// `residencyCostBytes`, `flushPdfText()` and the `TabResidentResource`
/// conformance. Those arrive with packet 4 §2.3/§2.4, together with the
/// residency policy that gives them meaning.
@MainActor
@Observable
final class LiveTabRuntime {
    let tabId: String

    /// The tab's PDF controller. It lives here rather than in the viewer's
    /// `@State` so the controller — and the `PDFView` it retains — outlives any
    /// single SwiftUI host: a tab dragged to another pane is remounted, and a
    /// remount must not rebuild PDFKit.
    var pdfController = PdfViewerControlleriOS()

    /// The tab's web controller, on the same terms as `pdfController`: it owns
    /// the `WKWebView` and its content process, both of which must survive a
    /// remount.
    var webController = WebViewerController_iOS()

    /// The pane used to own one `InkController_iOS` (registered in
    /// `InkRegistry_iOS` by pane id). That was correct while exactly one tab per
    /// pane was ever mounted. Live tabs break it: several tabs' `PDFView`s are
    /// mounted at once and each installs `ink.inkProvider` as its
    /// `pageOverlayViewProvider`, so one controller would hand tab B's page-3
    /// canvas to tab A's page 3. Ink is per-DOCUMENT state and now lives on the
    /// runtime with everything else the tab owns.
    var ink = InkController_iOS()

    /// Page text extracted from this tab's document, by 1-based page number.
    /// Kept on the runtime (and deliberately kept across an eviction) so the AI
    /// context stays truthful while an evicted viewer restores, and so the
    /// restore is spared a full extraction walk.
    var pageTexts: [Int: String] = [:]

    /// The parsed, annotation-stripped display document, kept beside the load
    /// state so it survives a *cancelled* load. The viewer's load task is
    /// cancelled whenever the user switches away mid-load; without this the next
    /// visit would re-parse a document we had already finished parsing.
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
    ///
    /// Nothing bumps it yet: `invalidateLoadedPdf()` — the only writer — lands
    /// with packet 4 §2.4. Viewers may already key their load task on it.
    private(set) var documentGeneration = 0

    init(tabId: String) {
        self.tabId = tabId
    }

    /// Adopt a freshly parsed display document. `byteCount` is the size of the
    /// PDF data it was parsed from.
    func adoptPreparedPdf(_ document: PDFDocument, byteCount: Int) {
        preparedDocument = document
        pdfByteCount = byteCount
    }
}
