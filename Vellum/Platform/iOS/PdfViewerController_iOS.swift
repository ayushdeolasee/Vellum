#if os(iOS)
import Observation
import PDFKit
import SwiftUI
import UIKit

// iPad counterpart of the macOS PdfViewerController. Same @Observable state the
// SwiftUI overlays read (geometryVersion, selection, selectionPopoverPosition,
// contextMenu, pageViewFrame) and the same store-handler surface (zoom, scroll,
// find, locate, snapshot), but interaction is touch/gesture-driven instead of
// NSEvent monitors, and geometry is UIKit-native (top-left origin, no flip).

/// The two non-`Sendable` values the background text walk has to carry into
/// `PageTextExtractionGate.extractText(priority:offMain:)`.
///
/// That body parameter is `@Sendable` on purpose — that is exactly what keeps
/// the `page.string` read on the detached utility task instead of dragging it
/// back onto the main actor (see `startTextExtraction(data:)`). Neither
/// `PDFDocument` nor the controller is `Sendable`, so the capture needs a box
/// with an explicit safety argument:
///
/// - `copy` is a PRIVATE `PDFDocument(data:)` parsed inside the walk. No view
///   renders from it and nothing else ever holds a reference, so the walk is its
///   only accessor and PDFKit's lack of thread safety cannot bite.
/// - `controller` is only ever dereferenced inside `MainActor.run`, i.e. on the
///   main actor, which is where every one of its members lives. It stays `weak`
///   so a walk outliving its controller drops out instead of keeping the whole
///   viewer alive.
private final class PdfExtractionWalkContext: @unchecked Sendable {
    weak var controller: PdfViewerControlleriOS?
    let copy: PDFDocument

    init(controller: PdfViewerControlleriOS?, copy: PDFDocument) {
        self.controller = controller
        self.copy = copy
    }
}

@MainActor
@Observable
final class PdfViewerControlleriOS: HighlightResizeControlling {
    /// The tab's `PDFView`, held STRONGLY (packet 7, the `RetainedViewOwner`
    /// contract in `LiveTabViewerContract_iOS.swift`): under live tabs the
    /// native view belongs to the tab, not to whichever pane happens to be
    /// hosting it, and rebuilding PDFKit on every remount is exactly what live
    /// tabs exist to avoid. No cycle — the view never holds the controller (the
    /// coordinator holds the controller strongly and the view weakly).
    ///
    /// The reference genuinely outlives its host as of packet 4 §2.8:
    /// `Coordinator.detach()` no longer nils it, so a remount adopts this view
    /// through `adoptRetainedView` instead of building a new one. It is
    /// released by `LiveTabRuntime.releaseResidency()` — which drops the whole
    /// controller — and by nothing else.
    var pdfView: PDFView?
    private(set) var document: PDFDocument?

    @ObservationIgnored weak var app: AppStore?
    @ObservationIgnored weak var annotationStore: AnnotationStore?
    @ObservationIgnored weak var ai: AiStore?

    /// The tab this controller is mounted for. Live tabs mount several viewers
    /// at once, so every generation guard below asks "is MY tab the active one"
    /// rather than reading the pane's active projection at the moment it runs.
    @ObservationIgnored private(set) var tabId: String?
    /// The tab's runtime, weak because the runtime owns this controller.
    /// Extracted page text is mirrored here as well as into the pane's shared
    /// `AiStore`: the AiStore holds only the ACTIVE tab's pages, so a background
    /// tab's already-extracted text would otherwise be lost on every switch.
    @ObservationIgnored weak var runtime: LiveTabRuntime?

    /// Bumped whenever scroll/zoom/layout moves page geometry so the overlays
    /// recompute their positions.
    private(set) var geometryVersion = 0
    let regionCaptureState = RegionCaptureState()

    @ObservationIgnored private var regionCapturePage: PDFPage?
    @ObservationIgnored private var regionCapturePageNumber: Int?
    @ObservationIgnored private var regionCaptureStart: CGPoint?
    @ObservationIgnored private var regionCaptureCurrent: CGPoint?

    private(set) var selection: PdfTextSelection?
    /// Selection popover anchor (bottom-center) in viewer top-left coordinates.
    private(set) var selectionPopoverPosition: CGPoint?
    private(set) var contextMenu: PdfContextMenuState?

    /// Live resize geometry. The overlay reads this instead of persisted rects
    /// during a drag; persistence occurs once, when the gesture ends.
    private(set) var highlightResize: (id: String, positionData: PositionData)?

    @ObservationIgnored private var initialPage = 1
    @ObservationIgnored private var didInitialScroll = false
    @ObservationIgnored private var recomputeScheduled = false
    @ObservationIgnored private var extractionTask: Task<Void, Never>?
    @ObservationIgnored private var persister: PageTextPersister?

    @ObservationIgnored private var findMatches: [PDFSelection] = []
    @ObservationIgnored private var findIndex = -1

    var isNoteMode: Bool { app?.mode == .note }

    /// Native scrolling may dismiss these transient surfaces, but a pan that
    /// STARTED as selection/note work must never also change phone chrome.
    var blocksAutomaticChromeChanges: Bool {
        guard let app, let tabId, app.activeTabId == tabId else { return true }
        return selection != nil || contextMenu != nil || highlightResize != nil
    }

    // MARK: - Lifecycle

    func adopt(
        document: PDFDocument,
        app: AppStore,
        annotationStore: AnnotationStore,
        ai: AiStore,
        initialPage: Int,
        tabId: String,
        runtime: LiveTabRuntime
    ) {
        reset()
        self.document = document
        self.app = app
        self.annotationStore = annotationStore
        self.ai = ai
        self.initialPage = initialPage
        self.tabId = tabId
        self.runtime = runtime
    }

    /// Re-point the pane-scoped stores without touching the loaded document.
    /// A tab dragged to another pane keeps its `PDFView` and its parsed
    /// document but must start talking to the destination pane's stores, and a
    /// warm tab coming back re-registers against whatever pane now hosts it.
    /// Deliberately NOT `adopt`: that resets, which would throw away the very
    /// native state live tabs exist to keep.
    func rebind(
        app: AppStore,
        annotationStore: AnnotationStore,
        ai: AiStore,
        tabId: String,
        runtime: LiveTabRuntime
    ) {
        self.app = app
        self.annotationStore = annotationStore
        self.ai = ai
        self.tabId = tabId
        self.runtime = runtime
    }

    func reset() {
        extractionTask?.cancel()
        extractionTask = nil
        flushAndDropPersister()
        document = nil
        selection = nil
        selectionPopoverPosition = nil
        contextMenu = nil
        highlightResize = nil
        resetRegionSelection()
        didInitialScroll = false
        findMatches = []
        findIndex = -1
        tabId = nil
        runtime = nil
    }

    /// Called by PdfKitView_iOS once the PDFView exists with the document set.
    func documentAttached() {
        guard !didInitialScroll else { return }
        didInitialScroll = true
        DispatchQueue.main.async { [weak self] in
            DispatchQueue.main.async {
                guard let self, self.pdfView != nil else { return }
                let pages = self.document?.pageCount ?? 0
                guard pages >= 1 else { return }
                self.scrollToPage(min(pages, max(1, self.initialPage)))
                self.recomputeVisiblePages()
                self.bumpGeometry()
            }
        }
    }

    // MARK: - Geometry (UIKit: pdfView coords are already top-left origin)

    private func bumpGeometry() { geometryVersion &+= 1 }

    /// Frame of a page in viewer coordinates (top-left origin), current zoom.
    func pageViewFrame(pageNumber: Int) -> CGRect? {
        guard let pdfView, let doc = pdfView.document,
              pageNumber >= 1, pageNumber <= doc.pageCount,
              let page = doc.page(at: pageNumber - 1) else { return nil }
        return pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
    }

    // MARK: - Scroll / zoom tracking (fed by the representable's KVO)

    func scrollChanged(offsetY: CGFloat) {
        currentScrollOffsetY = offsetY
        bumpGeometry()
        refreshRegionSelectionRect()
        // Dismiss the context menu on real scrolling only — engaging the
        // long-press cancels the touch, and that alone can jiggle the content
        // offset by a point or two, which must not wipe the menu it just opened.
        if contextMenu != nil, abs(offsetY - menuAnchorOffsetY) > 8 {
            contextMenu = nil
        }
        scheduleVisiblePagesRecompute()
    }

    @ObservationIgnored private var currentScrollOffsetY: CGFloat = 0
    @ObservationIgnored private var menuAnchorOffsetY: CGFloat = 0

    func scaleChanged() {
        guard let pdfView else { return }
        bumpGeometry()
        refreshRegionSelectionRect()
        if let app, abs(app.zoom - Double(pdfView.scaleFactor)) > 0.0001 {
            app.setZoom(Double(pdfView.scaleFactor))
        }
        scheduleVisiblePagesRecompute()
    }

    func layoutChanged() {
        bumpGeometry()
        refreshRegionSelectionRect()
        scheduleVisiblePagesRecompute()
    }

    // MARK: - Region capture

    func beginRegionSelection(at point: CGPoint) -> Bool {
        guard let pdfView, let document,
              let page = pdfView.page(for: point, nearest: true) else { return false }
        regionCapturePage = page
        regionCapturePageNumber = document.index(for: page) + 1
        let pagePoint = pdfView.convert(point, to: page)
        regionCaptureStart = pagePoint
        regionCaptureCurrent = pagePoint
        refreshRegionSelectionRect()
        return true
    }

    func updateRegionSelection(at point: CGPoint) {
        guard let pdfView, let page = regionCapturePage else { return }
        regionCaptureCurrent = pdfView.convert(point, to: page)
        refreshRegionSelectionRect()
    }

    func finishRegionSelection() -> Bool {
        guard let rect = regionCaptureState.selectionRect,
              rect.width >= RegionCaptureGestureRecognizer.minimumCaptureSize,
              rect.height >= RegionCaptureGestureRecognizer.minimumCaptureSize else {
            resetRegionSelection()
            return false
        }
        regionCaptureState.completeCapture()
        return true
    }

    func resetRegionSelection() {
        regionCapturePage = nil
        regionCapturePageNumber = nil
        regionCaptureStart = nil
        regionCaptureCurrent = nil
        regionCaptureState.clear()
    }

    private func refreshRegionSelectionRect() {
        guard let pdfView, let page = regionCapturePage,
              let start = regionCaptureStart, let current = regionCaptureCurrent else {
            regionCaptureState.update(rect: nil)
            return
        }
        let first = pdfView.convert(start, from: page)
        let second = pdfView.convert(current, from: page)
        regionCaptureState.update(rect: CGRect(
            x: min(first.x, second.x),
            y: min(first.y, second.y),
            width: abs(second.x - first.x),
            height: abs(second.y - first.y)))
    }

    private func scheduleVisiblePagesRecompute() {
        guard !recomputeScheduled else { return }
        recomputeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recomputeScheduled = false
            self.recomputeVisiblePages()
        }
    }

    /// Pages overlapping the viewport become visiblePages; the page with the
    /// largest vertical overlap (ties to the lower page number) becomes
    /// currentPage.
    func recomputeVisiblePages() {
        guard let pdfView, let app else { return }
        guard let doc = pdfView.document, doc.pageCount >= 1, app.numPages >= 1 else {
            app.setVisiblePages([])
            return
        }
        let viewportHeight = pdfView.bounds.height
        var visible: [Int] = []
        var dominantPage = 0
        var dominantOverlap: CGFloat = -1
        for index in 0..<doc.pageCount {
            guard let frame = pageViewFrame(pageNumber: index + 1) else { continue }
            if frame.minY >= viewportHeight {
                if !visible.isEmpty { break }
                continue
            }
            if frame.maxY > 0 {
                let pageNumber = index + 1
                visible.append(pageNumber)
                let overlap = min(frame.maxY, viewportHeight) - max(frame.minY, 0)
                if overlap > dominantOverlap {
                    dominantOverlap = overlap
                    dominantPage = pageNumber
                }
            }
        }
        if !visible.isEmpty {
            app.setVisiblePages(visible)
            app.setCurrentPage(dominantPage)
        }
    }

    // MARK: - Navigation / zoom

    func scrollToPage(_ pageNumber: Int) {
        guard let pdfView, let doc = pdfView.document,
              pageNumber >= 1, pageNumber <= doc.pageCount,
              let page = doc.page(at: pageNumber - 1) else { return }
        // Align the page's top edge with the viewport. iOS PDFView handles the
        // scroll-into-view; PDFDestination's point is in page space (bottom-left
        // origin), so the top-left display corner is (minX, maxY).
        let bounds = page.bounds(for: pdfView.displayBox)
        let destination = PDFDestination(page: page, at: CGPoint(x: bounds.minX, y: bounds.maxY))
        pdfView.go(to: destination)
        scheduleVisiblePagesRecompute()
        bumpGeometry()
    }

    func zoomTo(_ target: Double) {
        let clamped = min(AppStore.maxZoom, max(AppStore.minZoom, target))
        guard let pdfView else {
            app?.setZoom(clamped)
            return
        }
        // Bounded by the view's own range, not just the app-wide one: fit-width
        // reading (issue #152) raises `minScaleFactor` to the fit scale, and the
        // zoom-out button must respect that floor exactly like a pinch does.
        // The two ranges coincide on iPad, so nothing changes there.
        let bounded = min(
            Double(pdfView.maxScaleFactor), max(Double(pdfView.minScaleFactor), clamped))
        guard abs(bounded - Double(pdfView.scaleFactor)) >= 0.0001 else { return }
        pdfView.scaleFactor = CGFloat(bounded)
        app?.setZoom(bounded)
        scheduleVisiblePagesRecompute()
        bumpGeometry()
    }

    // MARK: - Find

    func findQuery(_ query: String) {
        guard let document, let pdfView else { return }
        let matches = document.findString(query, withOptions: [.caseInsensitive])
        for match in matches {
            match.color = UIColor.systemYellow.withAlphaComponent(0.5)
        }
        findMatches = matches
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        findIndex = matches.isEmpty ? -1 : 0
        focusCurrentMatch()
        app?.setFindResults(count: matches.count, current: matches.isEmpty ? 0 : 1)
    }

    func findStep(_ delta: Int) {
        guard !findMatches.isEmpty else {
            app?.setFindResults(count: 0, current: 0)
            return
        }
        let count = findMatches.count
        findIndex = ((findIndex + delta) % count + count) % count
        focusCurrentMatch()
        app?.setFindResults(count: count, current: findIndex + 1)
    }

    func findClear() {
        findMatches = []
        findIndex = -1
        pdfView?.highlightedSelections = nil
        pdfView?.setCurrentSelection(nil, animate: false)
    }

    private func focusCurrentMatch() {
        guard let pdfView, findMatches.indices.contains(findIndex) else { return }
        let match = findMatches[findIndex]
        pdfView.setCurrentSelection(match, animate: false)
        pdfView.scrollSelectionToVisible(nil)
    }

    // MARK: - Print

    func printDocument() {
        guard let document else { return }
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = app?.document?.title ?? "Vellum Document"
        let controller = UIPrintInteractionController.shared
        controller.printInfo = info
        controller.printingItem = document.dataRepresentation()
        controller.present(animated: true, completionHandler: nil)
    }

    // MARK: - Touch interactions

    /// Note-mode tap on the overlay: place a note at the tapped page point.
    func handleNoteTap(atTopLeft point: CGPoint) {
        guard let pdfView, let doc = pdfView.document else { return }
        guard let page = pdfView.page(for: point, nearest: false) else {
            annotationStore?.selectAnnotation(nil)
            return
        }
        let pageNumber = doc.index(for: page) + 1
        guard let frame = pageViewFrame(pageNumber: pageNumber) else { return }
        let zoom = max(pdfView.scaleFactor, 0.0001)
        let clickX = Double((point.x - frame.minX) / zoom)
        let clickY = Double((point.y - frame.minY) / zoom)
        let pageWidth = Double(frame.width / zoom)
        let pageHeight = Double(frame.height / zoom)
        Task {
            await self.placeNote(
                pageNumber: pageNumber, clickX: clickX, clickY: clickY,
                pageWidth: pageWidth, pageHeight: pageHeight)
        }
    }

    /// Whether the point sits on a page but genuinely away from selectable
    /// text. `selectionForWord(at:)` snaps to the NEAREST word at any distance,
    /// so an unbounded check would classify every point on a text page as
    /// "text" — bound it to a small radius around the word's box instead.
    func isEmptyPageArea(atTopLeft point: CGPoint) -> Bool {
        guard let pdfView, let page = pdfView.page(for: point, nearest: false) else { return false }
        let pagePoint = pdfView.convert(point, to: page)
        guard let word = page.selectionForWord(at: pagePoint),
              let text = word.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        let rect = word.bounds(for: page)
        let dx = max(rect.minX - pagePoint.x, pagePoint.x - rect.maxX, 0)
        let dy = max(rect.minY - pagePoint.y, pagePoint.y - rect.maxY, 0)
        return (dx * dx + dy * dy).squareRoot() > 24
    }

    /// Long-press on empty page area (view mode): offer "Add note here".
    /// (Presses on/near text never reach this — the gesture's shouldReceive
    /// gate routes those to the native text selection.)
    func handleLongPress(atTopLeft point: CGPoint) {
        guard isEmptyPageArea(atTopLeft: point),
              let pdfView, let doc = pdfView.document,
              let page = pdfView.page(for: point, nearest: false) else { return }
        // If PDFView's own long-press won the race and snap-selected the
        // nearest word, drop that selection — this press targets empty space.
        pdfView.clearSelection()
        let pageNumber = doc.index(for: page) + 1
        guard let frame = pageViewFrame(pageNumber: pageNumber) else { return }
        let zoom = max(pdfView.scaleFactor, 0.0001)
        menuAnchorOffsetY = currentScrollOffsetY
        contextMenu = PdfContextMenuState(
            location: point,
            pageNumber: pageNumber,
            clickX: Double((point.x - frame.minX) / zoom),
            clickY: Double((point.y - frame.minY) / zoom),
            pageWidth: Double(frame.width / zoom),
            pageHeight: Double(frame.height / zoom)
        )
    }

    func dismissContextMenu() { contextMenu = nil }

    /// A tap on empty page area (view mode) clears selection + context menu.
    func handleBackgroundTap() {
        contextMenu = nil
        annotationStore?.selectAnnotation(nil)
        if selection != nil { clearSelection() }
    }

    // MARK: - Text selection capture

    /// Called when the native selection changes (.PDFViewSelectionChanged).
    func selectionChanged() {
        guard let pdfView, let doc = pdfView.document else { return }
        guard let currentSelection = pdfView.currentSelection,
              let text = currentSelection.string?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else {
            if selection != nil { clearSelection() }
            return
        }
        // Anchor page: the first page the selection touches.
        guard let page = currentSelection.pages.first else { return }
        let pageNumber = doc.index(for: page) + 1
        guard let pageFrame = pageViewFrame(pageNumber: pageNumber) else { return }
        let zoom = max(pdfView.scaleFactor, 0.0001)

        var rects: [AnnotationRect] = []
        var lastLineRect: CGRect?
        for line in currentSelection.selectionsByLine() {
            guard let linePage = line.pages.first else { continue }
            let viewRect = pdfView.convert(line.bounds(for: linePage), from: linePage)
            rects.append(AnnotationRect(
                x: Double((viewRect.minX - pageFrame.minX) / zoom),
                y: Double((viewRect.minY - pageFrame.minY) / zoom),
                width: Double(viewRect.width / zoom),
                height: Double(viewRect.height / zoom)
            ))
            lastLineRect = viewRect
        }
        guard !rects.isEmpty, let lastRect = lastLineRect else { return }

        let positionData = PositionData(
            rects: rects,
            pageWidth: Double(pageFrame.width / zoom),
            pageHeight: Double(pageFrame.height / zoom),
            selectedText: text,
            startOffset: nil, endOffset: nil, prefix: nil, suffix: nil,
            viewportOffset: nil
        )
        selection = PdfTextSelection(text: text, positionData: positionData, pageNumber: pageNumber)
        // Anchor the popover above the FIRST line so it doesn't cover the
        // selection handles a touch user is dragging at the bottom.
        let firstRect = rects.first.map {
            CGRect(x: pageFrame.minX + $0.x * zoom, y: pageFrame.minY + $0.y * zoom,
                   width: $0.width * zoom, height: $0.height * zoom)
        } ?? lastRect
        selectionPopoverPosition = CGPoint(x: firstRect.midX, y: firstRect.minY - 10)
    }

    func clearSelection() {
        selection = nil
        selectionPopoverPosition = nil
        pdfView?.setCurrentSelection(nil, animate: false)
    }

    // MARK: - Highlight edge resize

    func previewHighlightResize(
        annotation: Annotation,
        edge: HighlightEdge,
        toDisplayPoint displayPoint: CGPoint
    ) {
        guard let position = resizedPosition(
            annotation: annotation, edge: edge, toDisplayPoint: displayPoint) else { return }
        highlightResize = (id: annotation.id, positionData: position)
    }

    func commitHighlightResize(
        annotation: Annotation,
        edge: HighlightEdge,
        toDisplayPoint displayPoint: CGPoint
    ) {
        let final = resizedPosition(
            annotation: annotation, edge: edge, toDisplayPoint: displayPoint)
            ?? (highlightResize?.id == annotation.id ? highlightResize?.positionData : nil)
        highlightResize = nil
        guard let final, final != annotation.positionData else { return }
        Task { [weak self] in
            await self?.annotationStore?.updateAnnotation(UpdateAnnotationInput(
                id: annotation.id,
                color: nil,
                content: nil,
                positionData: final))
        }
    }

    func cancelHighlightResize() {
        highlightResize = nil
    }

    private func resizedPosition(
        annotation: Annotation,
        edge: HighlightEdge,
        toDisplayPoint displayPoint: CGPoint
    ) -> PositionData? {
        guard let document,
              annotation.pageNumber >= 1,
              annotation.pageNumber <= document.pageCount,
              let page = document.page(at: annotation.pageNumber - 1),
              let current = annotation.positionData else { return nil }
        return PdfTextLocator.resizedPosition(
            page: page,
            current: current,
            edge: edge,
            toDisplayPoint: displayPoint)
    }

    // MARK: - Note placement

    private func placeNote(
        pageNumber: Int, clickX: Double, clickY: Double,
        pageWidth: Double, pageHeight: Double
    ) async {
        // If the AI panel's "Add as note" armed note mode with a reply payload,
        // this placement consumes it as the note's initial content (nil for a
        // plain, hand-placed note).
        let pendingContent = app?.consumePendingNoteContent()
        // Recorded BEFORE the write below suspends: with live tabs the user can
        // switch panes/tabs while `addNote` is in flight, and only the still-
        // active origin session may leave note mode.
        let originSessionId = app?.activeTabId
        let position = PositionData(
            rects: [AnnotationRect(x: clickX, y: clickY, width: 0, height: 0)],
            pageWidth: pageWidth, pageHeight: pageHeight,
            selectedText: nil, startOffset: nil, endOffset: nil,
            prefix: nil, suffix: nil, viewportOffset: nil
        )
        let input = CreateAnnotationInput(
            type: .note, pageNumber: pageNumber, color: nil, content: pendingContent,
            positionData: position)
        if let annotation = await annotationStore?.addNote(input) {
            annotationStore?.selectAnnotation(annotation.id)
        }
        if let originSessionId {
            app?.finishNotePlacement(forSessionId: originSessionId)
        }
    }

    func addNoteFromContextMenu() {
        guard let menu = contextMenu else { return }
        contextMenu = nil
        let pendingContent = app?.consumePendingNoteContent()
        Task {
            let position = PositionData(
                rects: [AnnotationRect(x: menu.clickX, y: menu.clickY, width: 0, height: 0)],
                pageWidth: menu.pageWidth, pageHeight: menu.pageHeight,
                selectedText: nil, startOffset: nil, endOffset: nil,
                prefix: nil, suffix: nil, viewportOffset: nil
            )
            let input = CreateAnnotationInput(
                type: .note, pageNumber: menu.pageNumber, color: nil, content: pendingContent,
                positionData: position)
            if let annotation = await annotationStore?.addNote(input) {
                annotationStore?.selectAnnotation(annotation.id)
            }
        }
    }

    // MARK: - Persistent page-text cache

    func installPersister(_ persister: PageTextPersister) {
        self.persister = persister
    }

    /// Flush any pending page text to disk (backgrounding/quit path).
    func flushPersister() async {
        await persister?.flush()
    }

    /// Flush-and-drop that survives `reset()`: the flush runs on the captured
    /// persister (which owns its own page data), so nil'ing the property here
    /// can't lose pages. Idempotent — a clean persister flushes to a no-op.
    /// Registered via `flushDetached` so the suspend path can await writes
    /// whose controller is already gone.
    func flushAndDropPersister() {
        guard let persister else { return }
        self.persister = nil
        persister.flushDetached()
    }

    // MARK: - AI page-text feed

    /// Walk every page's text into AiStore.pageTexts (and the persistent
    /// cache). `PDFPage.string` is NOT a cheap accessor — each call runs a
    /// CoreGraphics/TextRecognition layout-analysis pass that takes tens of
    /// milliseconds per page — so the walk runs OFF the main actor over a
    /// PRIVATE `PDFDocument` parsed from `data`. Walking the live (view-bound)
    /// document on the main actor starved the run loop for minutes on textbook
    /// PDFs, freezing every interaction after open/tab-switch; walking it off
    /// the main actor isn't an option either because PDFKit objects aren't
    /// thread-safe while PDFView renders from them. Pages already restored
    /// from the persistent cache are skipped without touching `page.string`
    /// (true resume of a partial walk); a fully cached document never even
    /// pays the copy parse.
    func startTextExtraction(data: Data) {
        extractionTask?.cancel()
        guard let document else { return }
        let pageCount = document.pageCount
        guard pageCount >= 1 else { return }
        // Generation guards: a stale walk must stop writing into the shared
        // pageTexts once the pane shows another tab or another document. The id
        // is THIS MOUNT's tab (live tabs mount several viewers at once), so an
        // inactive tab's walk parks itself instead of racing the visible one.
        let tabId = self.tabId ?? app?.activeTabId
        let docIdentity = ObjectIdentifier(document)
        let cachedPages = Set((ai?.pageTexts ?? [:]).keys)
        let missingPages = (1...pageCount).filter { !cachedPages.contains($0) }
        guard !missingPages.isEmpty else { return }
        extractionTask = Task.detached(priority: .utility) { [weak self] in
            guard let copy = PDFDocument(data: data) else { return }
            // The gate's `offMain:` body must be `@Sendable` (that is what keeps
            // it off the main actor), and neither `PDFDocument` nor the
            // controller is `Sendable`. `PdfExtractionWalkContext` carries both
            // across that boundary with the safety argument spelled out on the
            // type — see its doc comment.
            let walk = PdfExtractionWalkContext(controller: self, copy: copy)
            for pageNumber in missingPages {
                // Idle pacing, kept from the original walk so a background core
                // isn't pinned for the whole document. The gate's own cooldown
                // is measured from the END of the previous page, so this sleep
                // normally absorbs it rather than adding to it.
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }

                // One page at a time, process-wide (main PR #121): `PDFPage
                // .string` on a page with no text layer sends PDFKit to Live
                // Text, and overlapping first-time ANE model compiles crash the
                // process. `offMain:` keeps the read on this detached task —
                // the whole point of walking a private document copy — while
                // the gate's queue bookkeeping stays main-actor isolated.
                let text = await PageTextExtractionGate.shared.extractText(
                    priority: .background
                ) { () async -> String? in
                    // Cache re-check INSIDE the gate: a page the locator (or a
                    // second pane's walk) filled while this request sat in the
                    // queue is skipped, not re-extracted. Returning nil also
                    // tells the gate no read happened, so nothing is paced.
                    let stillNeeded = await MainActor.run { () -> Bool in
                        guard let ai = walk.controller?.ai else { return false }
                        return ai.pageTexts[pageNumber] == nil
                    }
                    guard stillNeeded,
                          pageNumber <= walk.copy.pageCount,
                          let page = walk.copy.page(at: pageNumber - 1) else { return nil }
                    return page.string ?? ""
                }
                // nil means "already cached, or cancelled while queued" — not a
                // reason to stop. Real cancellation is caught by the
                // `Task.isCancelled` check at the top of the next iteration and
                // staleness by the document/tab generation guard below.
                guard let text else { continue }

                let stillCurrent = await MainActor.run { [weak self] () -> Bool in
                    guard let self, let ai = self.ai,
                          self.document.map(ObjectIdentifier.init) == docIdentity,
                          self.app?.activeTabId == tabId else { return false }
                    if ai.pageTexts[pageNumber] == nil,
                       let normalized = ai.setPageText(page: pageNumber, text: text) {
                        // Mirror onto the tab's runtime as well. `AiStore` holds
                        // only the pane's ACTIVE document, so without this every
                        // page this walk extracted would be discarded the moment
                        // the user switched tabs — and the restore on the way
                        // back would have nothing to restore.
                        self.runtime?.pageTexts[pageNumber] = normalized
                        self.persister?.noteExtracted(page: pageNumber, text: normalized)
                    }
                    return true
                }
                if !stillCurrent { return }
            }
            // Whole document walked: flush with complete = true.
            await MainActor.run { [weak self] in self?.persister }?.flush()
        }
    }

    /// Stop the background walk without discarding what it has already
    /// written. The iPad walk is a detached task over a PRIVATE document copy,
    /// so cancelling it is the whole of the pause — there is no main-actor loop
    /// to drain, which is why this needs no `await` (main's macOS twin does).
    func pauseTextExtraction() {
        extractionTask?.cancel()
        extractionTask = nil
    }

    // MARK: - AI highlight locator

    func locateText(pageNumber: Int, query: String) async -> LocatedText? {
        guard let document, pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        // Same Live Text hazard as the extraction walk: on a scanned page this
        // `page.string` runs OCR, so it takes the gate rather than racing a walk
        // that is mid-compile (see PageTextExtractionGate). Main-actor caller,
        // main-actor body — the synchronous overload.
        let extracted = await PageTextExtractionGate.shared.extractText(priority: .onDemand) {
            page.string ?? ""
        }
        guard let pageString = extracted, !pageString.isEmpty else { return nil }
        return PdfTextLocator.locate(
            pageNumber: pageNumber, query: query, in: document, pageString: pageString)
    }

    // MARK: - AI page snapshot

    /// JPEG snapshot of the page, rendered at current zoom × screen scale (capped
    /// at 1.5), downscaled so the max dimension is 1280, encoded at quality 0.72.
    func capturePageImage(pageNumber: Int) -> AiPageImageSnapshot? {
        guard let document, pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        let dims = PdfTextLocator.displayDimensions(of: page)
        guard dims.width >= 1, dims.height >= 1 else { return nil }

        let zoom = pdfView?.scaleFactor ?? 1
        let backing = min(pdfView?.traitCollection.displayScale ?? 1, 1.5)
        var pixelWidth = dims.width * zoom * backing
        var pixelHeight = dims.height * zoom * backing
        guard pixelWidth >= 2, pixelHeight >= 2 else { return nil }
        let maxDimension = max(pixelWidth, pixelHeight)
        if maxDimension > 1280 {
            let scale = 1280 / maxDimension
            pixelWidth = max(1, (pixelWidth * scale).rounded())
            pixelHeight = max(1, (pixelHeight * scale).rounded())
        }
        let size = CGSize(width: pixelWidth, height: pixelHeight)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            let box = pdfView?.displayBox ?? .cropBox
            let pageRect = page.bounds(for: box)
            let cg = ctx.cgContext
            cg.saveGState()
            // Flip into PDF (bottom-left origin) space and scale to fit.
            cg.translateBy(x: 0, y: size.height)
            cg.scaleBy(x: size.width / pageRect.width, y: -size.height / pageRect.height)
            cg.translateBy(x: -pageRect.minX, y: -pageRect.minY)
            page.draw(with: box, to: cg)
            cg.restoreGState()
        }
        guard let jpeg = image.jpegData(compressionQuality: 0.72) else { return nil }
        return AiPageImageSnapshot(
            pageNumber: pageNumber,
            base64Data: jpeg.base64EncodedString(),
            mediaType: "image/jpeg",
            width: Int(pixelWidth),
            height: Int(pixelHeight)
        )
    }

    // MARK: - Scratchpad region snapshot (drag-to-crop)

    /// Render the selected page upright, then crop the stable page selection.
    private func capturePageRegionData(
        viewerRect rect: CGRect,
        pageNumber: Int
    ) -> ScratchpadImageCapture? {
        guard let pdfView, let document,
              pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        guard let pageFrame = pageViewFrame(pageNumber: pageNumber) else { return nil }
        let zoom = max(pdfView.scaleFactor, 0.0001)
        let dims = PdfTextLocator.displayDimensions(of: page)
        guard dims.width >= 1, dims.height >= 1 else { return nil }

        // Region in zoom-1, top-left page points, clamped to the page.
        var rx = Double((rect.minX - pageFrame.minX) / zoom)
        var ry = Double((rect.minY - pageFrame.minY) / zoom)
        rx = max(0, min(rx, Double(dims.width)))
        ry = max(0, min(ry, Double(dims.height)))
        let rw = max(1, min(Double(rect.width / zoom), Double(dims.width) - rx))
        let rh = max(1, min(Double(rect.height / zoom), Double(dims.height) - ry))
        guard rw >= 4, rh >= 4 else { return nil }

        // Render the whole page, then crop. Scale so the region is legible
        // (≤1280 on its long side) without blowing up tiny selections; cap the
        // full-page long side so a tiny crop on a large page can't allocate a
        // huge bitmap.
        var scale = min(3.0, max(1.0, 1280 / max(rw, rh)))
        let maxFullSide = 4096.0
        let fullLong = Double(max(dims.width, dims.height)) * scale
        if fullLong > maxFullSide { scale *= maxFullSide / fullLong }
        let fullW = Int((Double(dims.width) * scale).rounded())
        let fullH = Int((Double(dims.height) * scale).rounded())
        guard fullW > 0, fullH > 0 else { return nil }

        let fullSize = CGSize(width: fullW, height: fullH)
        let thumb = page.thumbnail(of: fullSize, for: pdfView.displayBox)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: fullSize, format: format)
        let composited = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(origin: .zero, size: fullSize))
            thumb.draw(in: CGRect(origin: .zero, size: fullSize))
        }

        // The rendered cgImage is top-down, so the crop rect uses top-left origin.
        guard let full = composited.cgImage else { return nil }
        let cropRect = CGRect(
            x: rx * scale, y: ry * scale, width: rw * scale, height: rh * scale
        ).integral
        guard let cropped = full.cropping(to: cropRect) else { return nil }
        guard let jpeg = UIImage(cgImage: cropped).jpegData(compressionQuality: 0.72) else { return nil }
        return ScratchpadImageCapture(
            data: jpeg,
            fileExtension: "jpg",
            mediaType: "image/jpeg",
            width: cropped.width,
            height: cropped.height,
            pageNumber: pageNumber
        )
    }

    func captureSelectedPageRegionData() -> ScratchpadImageCapture? {
        guard let rect = regionCaptureState.selectionRect,
              let pageNumber = regionCapturePageNumber else { return nil }
        defer { resetRegionSelection() }
        return capturePageRegionData(viewerRect: rect, pageNumber: pageNumber)
    }

}
#endif
