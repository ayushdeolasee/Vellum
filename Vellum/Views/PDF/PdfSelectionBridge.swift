import AppKit
import Observation
import PDFKit

// Selection → PositionData bridge, page geometry, note placement, AI locator /
// snapshot handlers, and text extraction — the viewer-side logic ported from
// src/hooks/useTextSelection.ts, src/components/pdf/PdfViewer.tsx and
// src/lib/highlight-locator.ts. UI lives in PdfViewerView / PdfOverlays.

/// In-memory text selection (useTextSelection's TextSelection).
struct PdfTextSelection {
    var text: String
    var positionData: PositionData
    var pageNumber: Int
}

/// Right-click "Add note here" menu state (PdfViewer's contextMenu).
struct PdfContextMenuState {
    /// Menu anchor in viewer (top-left origin) coordinates.
    var location: CGPoint
    var pageNumber: Int
    /// Click point normalized to zoom = 1, top-left page origin.
    var clickX: Double
    var clickY: Double
    /// Page display size at zoom = 1.
    var pageWidth: Double
    var pageHeight: Double
}

/// Shared state + behavior between the PDFView (AppKit) and the SwiftUI
/// overlay stack. One instance per PdfViewerView; reset on document change.
@MainActor
@Observable
final class PdfViewerController {
    weak var pdfView: PDFView?
    private(set) var document: PDFDocument?

    @ObservationIgnored weak var app: AppStore?
    @ObservationIgnored weak var annotationStore: AnnotationStore?
    @ObservationIgnored weak var ai: AiStore?

    /// Bumped whenever scroll/zoom/layout moves page geometry so the SwiftUI
    /// overlays recompute their positions.
    private(set) var geometryVersion = 0

    private(set) var selection: PdfTextSelection?
    /// Selection popover anchor (bottom-center) in viewer top-left coordinates.
    private(set) var selectionPopoverPosition: CGPoint?
    private(set) var contextMenu: PdfContextMenuState?

    @ObservationIgnored private var initialPage = 1
    @ObservationIgnored private var didInitialScroll = false
    @ObservationIgnored private var lastScrollOrigin: CGPoint?
    @ObservationIgnored private var lastScrollScale: CGFloat?
    @ObservationIgnored private var recomputeScheduled = false
    @ObservationIgnored private var suppressNextMouseUp = false
    @ObservationIgnored private var extractionTask: Task<Void, Never>?

    // Find state (⌘F): every PDFSelection matching the current query, plus the
    // index of the one currently focused.
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
        // Mirror renderAnnotationLayer={false}: annotations render ONLY from
        // store overlays; embedded ones must not double-draw underneath. The
        // in-memory copy is display-only (mutations rewrite the on-disk file),
        // so stripping them here never touches the document on disk.
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
        lastScrollOrigin = nil
        lastScrollScale = nil
        suppressNextMouseUp = false
        findMatches = []
        findIndex = -1
    }

    /// Called by PdfKitView once the PDFView exists with the document set:
    /// restore the tab's reading position (last_page) and seed visible pages.
    /// Two hops of the run loop stand in for the original's double rAF.
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
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                page.removeAnnotation(annotation)
            }
        }
    }

    // MARK: - Geometry

    private func bumpGeometry() {
        geometryVersion &+= 1
    }

    /// Frame of a page in viewer coordinates (top-left origin), current zoom.
    func pageViewFrame(pageNumber: Int) -> CGRect? {
        guard let pdfView, let doc = pdfView.document,
              pageNumber >= 1, pageNumber <= doc.pageCount,
              let page = doc.page(at: pageNumber - 1) else { return nil }
        let rect = pdfView.convert(page.bounds(for: pdfView.displayBox), from: page)
        return topLeftRect(rect)
    }

    private func topLeftRect(_ rect: CGRect) -> CGRect {
        guard let pdfView, !pdfView.isFlipped else { return rect }
        return CGRect(
            x: rect.minX,
            y: pdfView.bounds.height - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    private func topLeftPoint(_ point: CGPoint) -> CGPoint {
        guard let pdfView, !pdfView.isFlipped else { return point }
        return CGPoint(x: point.x, y: pdfView.bounds.height - point.y)
    }

    // MARK: - Scroll / zoom tracking

    func scrollChanged(origin: CGPoint) {
        bumpGeometry()
        contextMenu = nil
        let scale = pdfView?.scaleFactor ?? 1
        // A zoom change also moves the clip origin; the original only clears
        // the selection for real scroll events (>1px), not zoom settling.
        if let last = lastScrollOrigin, let lastScale = lastScrollScale,
           abs(scale - lastScale) < 0.0001 {
            let dx = abs(origin.x - last.x)
            let dy = abs(origin.y - last.y)
            if (dx > 1 || dy > 1), selection != nil {
                clearSelection()
            }
        }
        lastScrollOrigin = origin
        lastScrollScale = scale
        scheduleVisiblePagesRecompute()
    }

    func scaleChanged() {
        guard let pdfView else { return }
        bumpGeometry()
        if let app, abs(app.zoom - pdfView.scaleFactor) > 0.0001 {
            app.setZoom(pdfView.scaleFactor)
        }
        scheduleVisiblePagesRecompute()
    }

    func layoutChanged() {
        bumpGeometry()
        scheduleVisiblePagesRecompute()
    }

    /// Coalesce per-runloop-tick like the original's rAF throttle.
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
    /// currentPage. If nothing overlaps, neither value changes.
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
                // Pages are laid out top-to-bottom; nothing further can overlap.
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

    // MARK: - Navigation / zoom (window.__scrollToPage / window.__zoomPdfTo)

    func scrollToPage(_ pageNumber: Int) {
        guard let pdfView, let doc = pdfView.document,
              pageNumber >= 1, pageNumber <= doc.pageCount,
              let page = doc.page(at: pageNumber - 1) else { return }
        let bounds = page.bounds(for: pdfView.displayBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        // scrollIntoView(block: "start"): the page's displayed top-left corner
        // in page space, per rotation.
        let point: CGPoint
        switch rotation {
        case 90: point = CGPoint(x: bounds.minX, y: bounds.minY)
        case 180: point = CGPoint(x: bounds.maxX, y: bounds.minY)
        case 270: point = CGPoint(x: bounds.maxX, y: bounds.maxY)
        default: point = CGPoint(x: bounds.minX, y: bounds.maxY)
        }
        // block: "start" aligns only vertically (inline defaults to "nearest"),
        // so keep the clip view's current horizontal origin and set only y —
        // PDFDestination + go(to:) would snap the zoomed-in horizontal pan back
        // to the page's left edge.
        guard let docView = pdfView.documentView,
              let clip = docView.superview as? NSClipView else {
            pdfView.go(to: PDFDestination(page: page, at: point))
            return
        }
        let viewPoint = pdfView.convert(point, from: page)
        let docPoint = docView.convert(viewPoint, from: pdfView)
        let targetY = docView.isFlipped ? docPoint.y : docPoint.y - clip.bounds.height
        let desired = CGPoint(x: clip.bounds.origin.x, y: targetY)
        let constrained = clip.constrainBoundsRect(
            CGRect(origin: desired, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        docView.enclosingScrollView?.reflectScrolledClipView(clip)
    }

    /// Anchored zoom: keep the document point at the viewport center fixed.
    func zoomTo(_ target: Double) {
        let clamped = min(AppStore.maxZoom, max(AppStore.minZoom, target))
        guard let pdfView else {
            app?.setZoom(clamped)
            return
        }
        guard abs(clamped - pdfView.scaleFactor) >= 0.0001 else { return }
        let viewCenter = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let anchorPage = pdfView.page(for: viewCenter, nearest: true)
        let anchorPoint = anchorPage.map { pdfView.convert(viewCenter, to: $0) }

        pdfView.scaleFactor = clamped
        // Keep app.zoom in lockstep synchronously so the next zoomIn/zoomOut
        // reads a fresh value (PDFViewScaleChanged only updates it a runloop
        // turn later, which would make rapid button zooms stall).
        app?.setZoom(clamped)

        guard let anchorPage, let anchorPoint,
              let docView = pdfView.documentView,
              let clip = docView.superview as? NSClipView else { return }
        let restored = pdfView.convert(anchorPoint, from: anchorPage)
        let docPoint = docView.convert(restored, from: pdfView)
        let desired = CGPoint(
            x: docPoint.x - clip.bounds.width / 2,
            y: docPoint.y - clip.bounds.height / 2
        )
        let constrained = clip.constrainBoundsRect(
            CGRect(origin: desired, size: clip.bounds.size))
        clip.scroll(to: constrained.origin)
        docView.enclosingScrollView?.reflectScrolledClipView(clip)
        scheduleVisiblePagesRecompute()
        bumpGeometry()
    }

    // MARK: - Find (⌘F)

    /// Search the whole document; highlight every match and focus the first.
    func findQuery(_ query: String) {
        guard let document, let pdfView else { return }
        let matches = document.findString(query, withOptions: [.caseInsensitive])
        for match in matches {
            match.color = NSColor.systemYellow.withAlphaComponent(0.5)
        }
        findMatches = matches
        pdfView.highlightedSelections = matches.isEmpty ? nil : matches
        findIndex = matches.isEmpty ? -1 : 0
        focusCurrentMatch()
        app?.setFindResults(count: matches.count, current: matches.isEmpty ? 0 : 1)
    }

    /// Move the focused match by `delta`, wrapping at both ends.
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

    /// The current match is drawn as the live selection (system tint) on top of
    /// the yellow highlight layer, then scrolled into view.
    private func focusCurrentMatch() {
        guard let pdfView, findMatches.indices.contains(findIndex) else { return }
        let match = findMatches[findIndex]
        pdfView.setCurrentSelection(match, animate: false)
        pdfView.scrollSelectionToVisible(nil)
    }

    // MARK: - Print (⌘P)

    func printDocument() {
        guard let document, let window = pdfView?.window else { return }
        let printInfo = NSPrintInfo.shared
        guard let operation = document.printOperation(
            for: printInfo, scalingMode: .pageScaleDownToFit, autoRotate: true) else { return }
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    // MARK: - Mouse handling (fed by PdfKitView's event monitors)

    /// Returns true when the event must be swallowed (note placement).
    /// Note-mode overlay click: the point arrives in viewer top-left (SwiftUI
    /// overlay) coordinates; flip to PDFView-native and reuse the standard
    /// mousedown path. topLeftPoint is its own inverse.
    func handleNoteOverlayClick(atTopLeft point: CGPoint) {
        _ = handleMouseDown(atNative: topLeftPoint(point))
        // The tap gesture fires AFTER its own mouseup, so the suppress flag
        // set by note placement has nothing left to suppress — clearing it
        // keeps the next real selection mouseup from being swallowed.
        suppressNextMouseUp = false
    }

    func handleMouseDown(atNative point: CGPoint) -> Bool {
        contextMenu = nil
        guard let pdfView else { return false }

        if isNoteMode {
            if let page = pdfView.page(for: point, nearest: false),
               let doc = pdfView.document {
                let pageNumber = doc.index(for: page) + 1
                if let frame = pageViewFrame(pageNumber: pageNumber) {
                    let zoom = max(pdfView.scaleFactor, 0.0001)
                    let tp = topLeftPoint(point)
                    let clickX = Double((tp.x - frame.minX) / zoom)
                    let clickY = Double((tp.y - frame.minY) / zoom)
                    let pageWidth = Double(frame.width / zoom)
                    let pageHeight = Double(frame.height / zoom)
                    suppressNextMouseUp = true
                    Task {
                        await self.placeNote(
                            pageNumber: pageNumber, clickX: clickX, clickY: clickY,
                            pageWidth: pageWidth, pageHeight: pageHeight)
                    }
                    return true
                }
            }
            // Note mode, gray background: container click just deselects.
            annotationStore?.selectAnnotation(nil)
            return false
        }

        // View mode: clicking a page or the container background deselects.
        annotationStore?.selectAnnotation(nil)

        // Click-outside popover dismissal: after a beat, clear if no new
        // selection formed (useTextSelection's 10 ms mousedown timer).
        if selection != nil {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(10))
                guard let self, self.selection != nil else { return }
                let text = self.pdfView?.currentSelection?.string ?? ""
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.clearSelection()
                }
            }
        }
        return false
    }

    func handleMouseUp(atNative point: CGPoint) {
        if suppressNextMouseUp {
            suppressNextMouseUp = false
            return
        }
        // 10 ms settle delay before reading the finalized selection.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(10))
            self?.captureSelection(atNative: point)
        }
    }

    /// Returns true when a page was hit and the menu opened.
    func handleRightMouseDown(atNative point: CGPoint) -> Bool {
        guard let pdfView,
              let page = pdfView.page(for: point, nearest: false),
              let doc = pdfView.document else { return false }
        let pageNumber = doc.index(for: page) + 1
        guard let frame = pageViewFrame(pageNumber: pageNumber) else { return false }
        let zoom = max(pdfView.scaleFactor, 0.0001)
        let tp = topLeftPoint(point)
        contextMenu = PdfContextMenuState(
            location: tp,
            pageNumber: pageNumber,
            clickX: Double((tp.x - frame.minX) / zoom),
            clickY: Double((tp.y - frame.minY) / zoom),
            pageWidth: Double(frame.width / zoom),
            pageHeight: Double(frame.height / zoom)
        )
        return true
    }

    func dismissContextMenu() {
        contextMenu = nil
    }

    /// Mousedown outside the viewer (toolbar, sidebar, …): the original's
    /// window-level listeners dismiss the context menu, and the browser
    /// collapses the text selection, clearing the popover.
    func handleOutsideMouseDown() {
        contextMenu = nil
        if selection != nil {
            clearSelection()
        }
    }

    // MARK: - Text selection capture (useTextSelection.handleMouseUp)

    private func captureSelection(atNative point: CGPoint) {
        guard let pdfView, let doc = pdfView.document else { return }
        guard let currentSelection = pdfView.currentSelection else { return }
        let text = (currentSelection.string ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // The page under the mouse-up point (the original's closest
        // [data-page-number] ancestor); abort when released over the gap.
        guard let page = pdfView.page(for: point, nearest: false) else { return }
        let pageNumber = doc.index(for: page) + 1
        guard let pageFrame = pageViewFrame(pageNumber: pageNumber) else { return }
        let zoom = max(pdfView.scaleFactor, 0.0001)

        var rects: [AnnotationRect] = []
        var lastLineRect: CGRect?
        for line in currentSelection.selectionsByLine() {
            guard let linePage = line.pages.first else { continue }
            let viewRect = topLeftRect(pdfView.convert(line.bounds(for: linePage), from: linePage))
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
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil
        )
        selection = PdfTextSelection(text: text, positionData: positionData, pageNumber: pageNumber)
        // Above the LAST line rect, offset −10 (translate(-50%,-100%) applied
        // by the overlay's AnchoredAbove).
        selectionPopoverPosition = CGPoint(x: lastRect.midX, y: lastRect.minY - 10)
    }

    func clearSelection() {
        selection = nil
        selectionPopoverPosition = nil
        // The non-animated setter clears the text selection without PDFKit
        // animating it back into view (the plain `currentSelection = nil`
        // setter recenters on the old selection). The document position stays
        // fixed across the relayout that follows because PdfKitView is pinned
        // to the viewport size (see its sizeThatFits + the GeometryReader frame
        // in PdfViewerView), so SwiftUI never resizes the host on a highlight.
        pdfView?.setCurrentSelection(nil, animate: false)
    }

    // MARK: - Note placement

    private func placeNote(
        pageNumber: Int, clickX: Double, clickY: Double,
        pageWidth: Double, pageHeight: Double
    ) async {
        let position = PositionData(
            rects: [AnnotationRect(x: clickX, y: clickY, width: 0, height: 0)],
            pageWidth: pageWidth,
            pageHeight: pageHeight,
            selectedText: nil,
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil
        )
        let input = CreateAnnotationInput(
            type: .note, pageNumber: pageNumber, color: nil, content: nil,
            positionData: position)
        if let annotation = await annotationStore?.addNote(input) {
            annotationStore?.selectAnnotation(annotation.id)
        }
        // Note mode ALWAYS returns to view after a placement attempt.
        app?.setMode(.view)
    }

    func addNoteFromContextMenu() {
        guard let menu = contextMenu else { return }
        contextMenu = nil
        Task {
            let position = PositionData(
                rects: [AnnotationRect(x: menu.clickX, y: menu.clickY, width: 0, height: 0)],
                pageWidth: menu.pageWidth,
                pageHeight: menu.pageHeight,
                selectedText: nil,
                startOffset: nil,
                endOffset: nil,
                prefix: nil,
                suffix: nil,
                viewportOffset: nil
            )
            let input = CreateAnnotationInput(
                type: .note, pageNumber: menu.pageNumber, color: nil, content: nil,
                positionData: position)
            if let annotation = await annotationStore?.addNote(input) {
                annotationStore?.selectAnnotation(annotation.id)
            }
        }
    }

    // MARK: - AI page-text feed (getTextContent pass)

    func startTextExtraction() {
        extractionTask?.cancel()
        guard let document else { return }
        let pageCount = document.pageCount
        guard pageCount >= 1 else { return }
        extractionTask = Task { [weak self] in
            for pageNumber in 1...pageCount {
                // Idle pacing stand-in for requestIdleCallback's 16 ms fallback.
                try? await Task.sleep(for: .milliseconds(16))
                if Task.isCancelled { return }
                guard let self, self.document === document,
                      let page = document.page(at: pageNumber - 1) else { return }
                self.ai?.setPageText(page: pageNumber, text: page.string ?? "")
            }
        }
    }

    // MARK: - AI highlight locator (highlight-locator.ts)

    /// Whitespace-stripped, lowercased first-match locator returning
    /// line-merged rects at zoom 1 in top-left-origin page points.
    func locateText(pageNumber: Int, query: String) async -> LocatedText? {
        guard let document, pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        let needle = query
            .replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased()
        guard !needle.isEmpty, let pageString = page.string else { return nil }

        // Whitespace-free lowercase haystack; every character remembers the
        // UTF-16 range of the source character that produced it.
        var haystack: [Character] = []
        var ownerStarts: [Int] = []
        var ownerLengths: [Int] = []
        var utf16Offset = 0
        for character in pageString {
            let length = String(character).utf16.count
            if !character.isWhitespace {
                for lowered in String(character).lowercased() {
                    haystack.append(lowered)
                    ownerStarts.append(utf16Offset)
                    ownerLengths.append(length)
                }
            }
            utf16Offset += length
        }
        let needleChars = Array(needle)
        guard !needleChars.isEmpty, haystack.count >= needleChars.count else { return nil }

        var matchStart = -1
        for start in 0...(haystack.count - needleChars.count) {
            var matches = true
            for offset in 0..<needleChars.count where haystack[start + offset] != needleChars[offset] {
                matches = false
                break
            }
            if matches {
                matchStart = start
                break
            }
        }
        guard matchStart >= 0 else { return nil }
        let matchLast = matchStart + needleChars.count - 1
        let rangeStart = ownerStarts[matchStart]
        let rangeEnd = ownerStarts[matchLast] + ownerLengths[matchLast]
        guard rangeEnd > rangeStart,
              let selection = page.selection(
                for: NSRange(location: rangeStart, length: rangeEnd - rangeStart))
        else { return nil }

        var rects: [AnnotationRect] = []
        for line in selection.selectionsByLine() {
            guard let linePage = line.pages.first else { continue }
            let bounds = line.bounds(for: linePage)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            rects.append(Self.uiRect(fromPageSpace: bounds, page: linePage))
        }
        let merged = Self.mergeLineRects(rects)
        guard !merged.isEmpty else { return nil }

        let dims = Self.displayDimensions(of: page)
        let positionData = PositionData(
            rects: merged,
            pageWidth: Double(dims.width),
            pageHeight: Double(dims.height),
            selectedText: query,
            startOffset: nil,
            endOffset: nil,
            prefix: nil,
            suffix: nil,
            viewportOffset: nil
        )
        return LocatedText(positionData: positionData, pageNumber: pageNumber)
    }

    /// Merge rects on the same visual line: |Δy| ≤ 0.6 × min heights.
    static func mergeLineRects(_ rects: [AnnotationRect]) -> [AnnotationRect] {
        guard !rects.isEmpty else { return [] }
        let sorted = rects.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        var lines: [AnnotationRect] = []
        for rect in sorted {
            if var last = lines.last {
                let tolerance = min(rect.height, last.height) * 0.6
                if abs(rect.y - last.y) <= tolerance {
                    let left = min(last.x, rect.x)
                    let right = max(last.x + last.width, rect.x + rect.width)
                    let top = min(last.y, rect.y)
                    let bottom = max(last.y + last.height, rect.y + rect.height)
                    last.x = left
                    last.y = top
                    last.width = right - left
                    last.height = bottom - top
                    lines[lines.count - 1] = last
                    continue
                }
            }
            lines.append(rect)
        }
        return lines
    }

    /// pdf_to_ui with UserUnit = 1 (PDFKit does not expose /UserUnit):
    /// PDF page space (bottom-left, CropBox-relative) → top-left display space.
    static func uiRect(fromPageSpace rect: CGRect, page: PDFPage) -> AnnotationRect {
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        func mapped(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            switch rotation {
            case 90: return CGPoint(x: y - crop.minY, y: x - crop.minX)
            case 180: return CGPoint(x: crop.maxX - x, y: y - crop.minY)
            case 270: return CGPoint(x: crop.maxY - y, y: crop.maxX - x)
            default: return CGPoint(x: x - crop.minX, y: crop.maxY - y)
            }
        }
        let corners = [
            mapped(rect.minX, rect.minY),
            mapped(rect.maxX, rect.minY),
            mapped(rect.minX, rect.maxY),
            mapped(rect.maxX, rect.maxY),
        ]
        let xs = corners.map(\.x)
        let ys = corners.map(\.y)
        let minX = xs.min() ?? 0
        let maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0
        let maxY = ys.max() ?? 0
        return AnnotationRect(
            x: Double(minX), y: Double(minY),
            width: Double(maxX - minX), height: Double(maxY - minY))
    }

    /// Rotation-aware page display size at zoom 1.
    static func displayDimensions(of page: PDFPage) -> CGSize {
        let crop = page.bounds(for: .cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return CGSize(width: crop.height, height: crop.width)
        }
        return CGSize(width: crop.width, height: crop.height)
    }

    // MARK: - Scratchpad region snapshot (drag-to-crop)

    /// Crop a JPEG snapshot of the page under `viewerRect` (viewer top-left
    /// coordinates, the SwiftUI overlay space) for the scratchpad. Returns nil
    /// if the rect misses any page or is too small to be useful. Adapted from
    /// the AI branch's `capturePageRegion`, but yields raw bytes so the
    /// attachment store can write them straight to disk.
    func capturePageRegionData(viewerRect rect: CGRect) -> ScratchpadImageCapture? {
        guard let pdfView, let document else { return nil }
        let nativeCenter = topLeftPoint(CGPoint(x: rect.midX, y: rect.midY))
        guard let page = pdfView.page(for: nativeCenter, nearest: true) else { return nil }
        let pageNumber = document.index(for: page) + 1
        guard let pageFrame = pageViewFrame(pageNumber: pageNumber) else { return nil }
        let zoom = max(pdfView.scaleFactor, 0.0001)
        let dims = Self.displayDimensions(of: page)
        guard dims.width >= 1, dims.height >= 1 else { return nil }

        // Region in zoom-1, top-left page points, clamped to the page.
        var rx = Double((rect.minX - pageFrame.minX) / zoom)
        var ry = Double((rect.minY - pageFrame.minY) / zoom)
        rx = max(0, min(rx, Double(dims.width)))
        ry = max(0, min(ry, Double(dims.height)))
        let rw = max(1, min(Double(rect.width / zoom), Double(dims.width) - rx))
        let rh = max(1, min(Double(rect.height / zoom), Double(dims.height) - ry))
        guard rw >= 4, rh >= 4 else { return nil }

        // Render the whole page upright, then crop. Scale so the region is
        // legible (≤1280 on its long side) without blowing up tiny selections.
        var scale = min(3.0, max(1.0, 1280 / max(rw, rh)))
        // The scale drives the *whole* page bitmap, so a tiny selection on a
        // large page (big dims × up to 3×) could allocate a huge image on the
        // main actor. Cap the full-page long side to keep the allocation bounded.
        let maxFullSide = 4096.0
        let fullLong = Double(max(dims.width, dims.height)) * scale
        if fullLong > maxFullSide { scale *= maxFullSide / fullLong }
        let fullW = Int((Double(dims.width) * scale).rounded())
        let fullH = Int((Double(dims.height) * scale).rounded())
        guard fullW > 0, fullH > 0 else { return nil }

        let image = page.thumbnail(
            of: NSSize(width: CGFloat(fullW), height: CGFloat(fullH)),
            for: pdfView.displayBox)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: fullW, pixelsHigh: fullH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let target = NSRect(x: 0, y: 0, width: CGFloat(fullW), height: CGFloat(fullH))
        NSColor.white.setFill()
        target.fill()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        // rep.cgImage is top-down, so the crop rect uses top-left origin.
        guard let full = rep.cgImage else { return nil }
        let cropRect = CGRect(
            x: rx * scale, y: ry * scale, width: rw * scale, height: rh * scale
        ).integral
        guard let cropped = full.cropping(to: cropRect) else { return nil }
        let outRep = NSBitmapImageRep(cgImage: cropped)
        guard let jpeg = outRep.representation(
            using: .jpeg, properties: [.compressionFactor: 0.72]) else { return nil }
        return ScratchpadImageCapture(
            data: jpeg,
            fileExtension: "jpg",
            mediaType: "image/jpeg",
            width: cropped.width,
            height: cropped.height,
            pageNumber: pageNumber
        )
    }

    // MARK: - AI page snapshot (AiPanel.captureCurrentPageImage)

    /// JPEG snapshot of the page's rendered content: rendered at the current
    /// zoom × backing scale (capped at 1.5, matching the canvas DPR cap),
    /// downscaled so the max dimension is 1280, encoded at quality 0.72.
    func capturePageImage(pageNumber: Int) -> AiPageImageSnapshot? {
        guard let document, pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return nil }
        let dims = Self.displayDimensions(of: page)
        guard dims.width >= 1, dims.height >= 1 else { return nil }

        let zoom = pdfView?.scaleFactor ?? 1
        let backing = min(pdfView?.window?.backingScaleFactor ?? 1, 1.5)
        var pixelWidth = dims.width * zoom * backing
        var pixelHeight = dims.height * zoom * backing
        guard pixelWidth >= 2, pixelHeight >= 2 else { return nil }
        let maxDimension = max(pixelWidth, pixelHeight)
        if maxDimension > 1280 {
            let scale = 1280 / maxDimension
            pixelWidth = max(1, (pixelWidth * scale).rounded())
            pixelHeight = max(1, (pixelHeight * scale).rounded())
        }
        let width = Int(pixelWidth)
        let height = Int(pixelHeight)

        let image = page.thumbnail(
            of: NSSize(width: pixelWidth, height: pixelHeight),
            for: pdfView?.displayBox ?? .cropBox)

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        let target = NSRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        NSColor.white.setFill()
        target.fill()
        image.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.72])
        else { return nil }
        return AiPageImageSnapshot(
            pageNumber: pageNumber,
            base64Data: jpeg.base64EncodedString(),
            mediaType: "image/jpeg",
            width: width,
            height: height
        )
    }
}
