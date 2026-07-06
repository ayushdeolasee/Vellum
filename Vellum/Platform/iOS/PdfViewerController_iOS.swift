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
@MainActor
@Observable
final class PdfViewerControlleriOS {
    weak var pdfView: PDFView?
    private(set) var document: PDFDocument?

    @ObservationIgnored weak var app: AppStore?
    @ObservationIgnored weak var annotationStore: AnnotationStore?
    @ObservationIgnored weak var ai: AiStore?

    /// Bumped whenever scroll/zoom/layout moves page geometry so the overlays
    /// recompute their positions.
    private(set) var geometryVersion = 0

    private(set) var selection: PdfTextSelection?
    /// Selection popover anchor (bottom-center) in viewer top-left coordinates.
    private(set) var selectionPopoverPosition: CGPoint?
    private(set) var contextMenu: PdfContextMenuState?

    @ObservationIgnored private var initialPage = 1
    @ObservationIgnored private var didInitialScroll = false
    @ObservationIgnored private var recomputeScheduled = false
    @ObservationIgnored private var extractionTask: Task<Void, Never>?

    @ObservationIgnored private var findMatches: [PDFSelection] = []
    @ObservationIgnored private var findIndex = -1

    var isNoteMode: Bool { app?.mode == .note }

    // MARK: - Lifecycle

    func adopt(
        document: PDFDocument,
        app: AppStore,
        annotationStore: AnnotationStore,
        ai: AiStore,
        initialPage: Int
    ) {
        reset()
        self.document = document
        self.app = app
        self.annotationStore = annotationStore
        self.ai = ai
        self.initialPage = initialPage
        // Annotations render only from the SwiftUI overlays; strip the embedded
        // ones from the in-memory display copy so they don't double-draw. The
        // on-disk file is untouched (mutations go through the atomic writer).
        stripEmbeddedAnnotations(from: document)
    }

    func reset() {
        extractionTask?.cancel()
        extractionTask = nil
        document = nil
        selection = nil
        selectionPopoverPosition = nil
        contextMenu = nil
        didInitialScroll = false
        findMatches = []
        findIndex = -1
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

    private func stripEmbeddedAnnotations(from document: PDFDocument) {
        // Highlights/notes/bookmarks render from the SwiftUI overlays, so strip
        // them from the display copy. Pencil ink renders natively via PDFKit, so
        // KEEP Vellum ink annotations — they draw straight from the file.
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where !PdfInk.isVellumInk(annotation) {
                page.removeAnnotation(annotation)
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
        if let app, abs(app.zoom - Double(pdfView.scaleFactor)) > 0.0001 {
            app.setZoom(Double(pdfView.scaleFactor))
        }
        scheduleVisiblePagesRecompute()
    }

    func layoutChanged() {
        bumpGeometry()
        scheduleVisiblePagesRecompute()
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
        guard abs(clamped - Double(pdfView.scaleFactor)) >= 0.0001 else { return }
        pdfView.scaleFactor = CGFloat(clamped)
        app?.setZoom(clamped)
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

    // MARK: - Note placement

    private func placeNote(
        pageNumber: Int, clickX: Double, clickY: Double,
        pageWidth: Double, pageHeight: Double
    ) async {
        let position = PositionData(
            rects: [AnnotationRect(x: clickX, y: clickY, width: 0, height: 0)],
            pageWidth: pageWidth, pageHeight: pageHeight,
            selectedText: nil, startOffset: nil, endOffset: nil,
            prefix: nil, suffix: nil, viewportOffset: nil
        )
        let input = CreateAnnotationInput(
            type: .note, pageNumber: pageNumber, color: nil, content: nil,
            positionData: position)
        if let annotation = await annotationStore?.addNote(input) {
            annotationStore?.selectAnnotation(annotation.id)
        }
        app?.setMode(.view)
    }

    func addNoteFromContextMenu() {
        guard let menu = contextMenu else { return }
        contextMenu = nil
        Task {
            let position = PositionData(
                rects: [AnnotationRect(x: menu.clickX, y: menu.clickY, width: 0, height: 0)],
                pageWidth: menu.pageWidth, pageHeight: menu.pageHeight,
                selectedText: nil, startOffset: nil, endOffset: nil,
                prefix: nil, suffix: nil, viewportOffset: nil
            )
            let input = CreateAnnotationInput(
                type: .note, pageNumber: menu.pageNumber, color: nil, content: nil,
                positionData: position)
            if let annotation = await annotationStore?.addNote(input) {
                annotationStore?.selectAnnotation(annotation.id)
            }
        }
    }

    // MARK: - AI page-text feed

    func startTextExtraction() {
        extractionTask?.cancel()
        guard let document else { return }
        let pageCount = document.pageCount
        guard pageCount >= 1 else { return }
        extractionTask = Task { [weak self] in
            for pageNumber in 1...pageCount {
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                guard let self, self.document === document,
                      let page = document.page(at: pageNumber - 1) else { return }
                self.ai?.setPageText(page: pageNumber, text: page.string ?? "")
            }
        }
    }

    // MARK: - AI highlight locator

    func locateText(pageNumber: Int, query: String) async -> LocatedText? {
        guard let document else { return nil }
        return PdfTextLocator.locate(pageNumber: pageNumber, query: query, in: document)
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
        let backing = min(UIScreen.main.scale, 1.5)
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
}
#endif
