import Foundation

/// Reading-order text and line geometry at zoom 1. A synthetic separator has
/// no rectangle. A glyph encoded as a surrogate pair can own both UTF-16 units.
public struct ExtractedPageText: Sendable {
    public struct Line: Sendable {
        public let utf16Range: Range<Int>
        public let bounds: AnnotationRect

        public init(utf16Range: Range<Int>, bounds: AnnotationRect) {
            self.utf16Range = utf16Range
            self.bounds = bounds
        }
    }

    public let text: String
    public let charUiRects: [AnnotationRect?]
    public let lines: [Line]
    public let geometry: PageGeometry
    let discretionaryHyphens: Set<Int>

    public init(text: String, charUiRects: [AnnotationRect?], lines: [Line], geometry: PageGeometry,
                discretionaryHyphens: Set<Int> = []) {
        self.text = text
        self.charUiRects = charUiRects
        self.lines = lines
        self.geometry = geometry
        self.discretionaryHyphens = discretionaryHyphens
    }
}

public enum PdfTextLocatorPortable {
    public enum Edge: String, Codable, Sendable { case start, end }

    public struct Selection: Sendable {
        public let utf16Range: Range<Int>
        public let positionData: PositionData
    }

    public static func locate(query: String, in page: ExtractedPageText) -> Selection? {
        let exact = PdfTextSelectionMath.firstMatch(of: query, in: page.text)
        let match = exact ?? (page.discretionaryHyphens.isEmpty ? nil
            : PdfTextSelectionMath.firstMatch(of: query, in: page.text, ignoring: page.discretionaryHyphens))
        guard let range = match,
              let position = position(for: range, in: page, selectedText: query) else { return nil }
        return Selection(utf16Range: range, positionData: position)
    }

    /// Begin on text, then snap the moving endpoint to the nearest grapheme caret.
    /// Both points use the selected page's top-left display coordinates at zoom 1.
    public static func selection(in page: ExtractedPageText, fromX x: Double, y: Double,
                                 toX endX: Double, y endY: Double) -> Selection? {
        guard [x, y, endX, endY].allSatisfy(\.isFinite),
              page.charUiRects.contains(where: { box in
                  guard let box else { return false }
                  return x >= box.x - 2 && x <= box.x + box.width + 2 &&
                         y >= box.y - 2 && y <= box.y + box.height + 2
              }),
              let a = caretOffset(x: x, y: y, in: page),
              let b = caretOffset(x: endX, y: endY, in: page) else { return nil }
        let range = min(a, b)..<max(a, b)
        guard let data = position(for: range, in: page) else { return nil }
        return Selection(utf16Range: range, positionData: data)
    }

    /// Resize an in-flight selection. The original range pins the opposite
    /// glyph exactly, including when display rotation changes rectangle order.
    /// All points and output rectangles are in zoom-1, top-left display space.
    public static func resizedPosition(
        page: ExtractedPageText, current: Selection, edge: Edge, toDisplayX x: Double, y: Double
    ) -> Selection? {
        guard x.isFinite, y.isFinite, let hit = caretOffset(
            x: min(max(x, 0), page.geometry.displayWidth),
            y: min(max(y, 0), page.geometry.displayHeight),
            in: page
        ) else { return nil }

        let old = current.utf16Range
        let range: Range<Int>
        switch edge {
        case .start:
            guard hit < old.upperBound else { return nil }
            range = hit..<old.upperBound
        case .end:
            guard hit > old.lowerBound else { return nil }
            range = old.lowerBound..<hit
        }
        guard let position = position(for: range, in: page) else { return nil }
        return Selection(utf16Range: range, positionData: position)
    }

    private static func position(
        for range: Range<Int>, in page: ExtractedPageText, selectedText: String? = nil
    ) -> PositionData? {
        guard !range.isEmpty, range.lowerBound >= 0, range.upperBound <= page.charUiRects.count else { return nil }
        let rects = page.lines.compactMap { line -> AnnotationRect? in
            let overlap = line.utf16Range.clamped(to: range)
            guard !overlap.isEmpty else { return nil }
            var bounds: AnnotationRect?
            for index in overlap {
                if let rect = page.charUiRects[index] { bounds = bounds?.union(rect) ?? rect }
            }
            return bounds
        }
        guard !rects.isEmpty else { return nil }
        let text = selectedText ?? (page.text as NSString).substring(
            with: NSRange(location: range.lowerBound, length: range.count))
        return PositionData(rects: PdfTextSelectionMath.mergeLineRects(rects),
                            pageWidth: page.geometry.displayWidth, pageHeight: page.geometry.displayHeight,
                            selectedText: text)
    }

    private static func caretOffset(x: Double, y: Double, in page: ExtractedPageText) -> Int? {
        let geometry = page.geometry
        // Compare along and across the underlying line even when the displayed
        // line is vertical or right-to-left because of the page's /Rotate.
        func logical(_ x: Double, _ y: Double) -> (along: Double, across: Double) {
            let point = geometry.uiToPdf(x, y, pageWidth: geometry.displayWidth, pageHeight: geometry.displayHeight)
            return (point.x, point.y)
        }
        let target = logical(x, y)
        func distance(to rect: AnnotationRect) -> (along: Double, across: Double) {
            let start = logical(rect.x, rect.y)
            let end = logical(rect.x + rect.width, rect.y + rect.height)
            return (max(min(start.along, end.along) - target.along, 0, target.along - max(start.along, end.along)),
                    max(min(start.across, end.across) - target.across, 0, target.across - max(start.across, end.across)))
        }
        let line = page.lines.min {
            let a = distance(to: $0.bounds)
            let b = distance(to: $1.bounds)
            return (a.across, a.along) < (b.across, b.along)
        }
        guard let line else { return nil }
        let utf16 = page.text.utf16
        guard let start = utf16.index(utf16.startIndex, offsetBy: line.utf16Range.lowerBound, limitedBy: utf16.endIndex),
              let end = utf16.index(start, offsetBy: line.utf16Range.count, limitedBy: utf16.endIndex)
        else { return nil }

        // Hit-test entire graphemes so a drag cannot split a surrogate pair
        // or a combining sequence, even when several units share a box.
        let lineText = String(decoding: utf16[start..<end], as: UTF16.self)
        var offset = line.utf16Range.lowerBound
        var nearest: (offset: Int, distance: Double)?
        func consider(_ offset: Int, at x: Double) {
            let distance = abs(target.along - x)
            if let nearest, distance >= nearest.distance { return }
            nearest = (offset, distance)
        }
        for character in lineText {
            let end = offset + String(character).utf16.count
            var bounds: AnnotationRect?
            for index in offset..<end {
                if let rect = page.charUiRects[index] { bounds = bounds?.union(rect) ?? rect }
            }
            if let bounds {
                let a = logical(bounds.x, bounds.y).along
                let b = logical(bounds.x + bounds.width, bounds.y + bounds.height).along
                consider(offset, at: min(a, b))
                consider(end, at: max(a, b))
            }
            offset = end
        }
        return nearest?.offset
    }
}
