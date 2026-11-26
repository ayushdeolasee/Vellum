import Foundation
import VellumCore

enum PdfTextReadingOrder {
    private struct Glyph {
        let source: Range<Int>
        let bounds: AnnotationRect
        let baseline: Double
        let isSpace: Bool

        var right: Double { bounds.x + bounds.width }
    }

    private struct Fragment {
        let glyphs: ArraySlice<Glyph>
        let left: Double
        let right: Double
    }

    static func sort(_ raw: PdfiumPageText) throws -> ExtractedPageText {
        try Task.checkCancellation()
        let geometry = raw.geometry
        let units = Array(raw.text.utf16)
        var glyphs: [Glyph] = []
        var index = 0
        while index < raw.chars.count {
            let char = raw.chars[index]
            let start = index
            index += 1
            // Keep a surrogate pair as one glyph while sorting. PDFium may
            // return either a full scalar or two entries with different boxes.
            let unit = units[start]
            if (0xd800...0xdbff).contains(unit), index < units.count,
               (0xdc00...0xdfff).contains(units[index]) {
                index += 1
            }
            guard !char.isGenerated, isVisible(char, on: geometry) else { continue }
            // PDFium reports a discretionary hyphen as U+0002. Keep that
            // glyph in the extracted text rather than treating it as a control.
            if !char.isDiscretionaryHyphen, unit < 32 || (127...159).contains(unit) { continue }
            let bounds = index - start == 2
                ? char.selectionBounds.union(raw.chars[start + 1].selectionBounds) : char.selectionBounds
            let isSpace = Unicode.Scalar(unit).map { CharacterSet.whitespaces.contains($0) } ?? false
            glyphs.append(Glyph(source: start..<index, bounds: bounds, baseline: char.baseline, isSpace: isSpace))
        }

        let heights = glyphs.lazy.filter { !$0.isSpace && $0.bounds.height > 0 }.map(\.bounds.height).sorted()
        let height = heights.isEmpty ? 1 : heights[heights.count / 2]
        // /Rotate changes display coordinates, not the order of horizontal
        // text in the underlying page. Apply it to the boxes after layout.
        glyphs.sort { ($0.baseline, -$0.bounds.x, -$0.source.lowerBound)
                    > ($1.baseline, -$1.bounds.x, -$1.source.lowerBound) }

        var fragmentsInOrder: [Fragment] = []
        var band: [[Fragment]] = []
        var previousBaseline: Double?
        var rowStart = glyphs.startIndex
        while rowStart < glyphs.endIndex {
            try Task.checkCancellation()
            let anchor = glyphs[rowStart]
            var end = rowStart + 1
            while end < glyphs.endIndex, sharesLine(anchor, glyphs[end], height: height) {
                end += 1
            }
            let row = fragments(glyphs[rowStart..<end], height: height)
            rowStart = end
            guard !row.isEmpty else { continue }
            if let previousBaseline, previousBaseline - anchor.baseline > 3 * height {
                fragmentsInOrder.append(contentsOf: readingOrder(in: band, height: height))
                band.removeAll(keepingCapacity: true)
            }
            band.append(row)
            previousBaseline = anchor.baseline
        }
        fragmentsInOrder.append(contentsOf: readingOrder(in: band, height: height))

        var orderedUnits: [UInt16] = []
        var charUiRects: [AnnotationRect?] = []
        var lines: [ExtractedPageText.Line] = []
        var discretionaryHyphens: Set<Int> = []
        for fragment in fragmentsInOrder {
            try Task.checkCancellation()
            if !orderedUnits.isEmpty {
                orderedUnits.append(10)
                charUiRects.append(nil)
            }
            let start = orderedUnits.count
            var previous: Glyph?
            var lineBounds: AnnotationRect?
            for glyph in fragment.glyphs {
                if let previous, !previous.isSpace, !glyph.isSpace,
                   glyph.bounds.x - previous.right > 0.28 * height
                    || hasGeneratedSpace(between: previous, and: glyph, in: raw) {
                    orderedUnits.append(32)
                    charUiRects.append(nil)
                }

                if raw.chars[glyph.source.lowerBound].isDiscretionaryHyphen {
                    if glyph.source == fragment.glyphs.last?.source {
                        discretionaryHyphens.insert(orderedUnits.count)
                    }
                    orderedUnits.append(45)
                } else {
                    orderedUnits.append(contentsOf: units[glyph.source])
                }
                let rect = displayRect(glyph.bounds, geometry: geometry)
                charUiRects.append(contentsOf: repeatElement(rect, count: glyph.source.count))
                if let rect { lineBounds = lineBounds?.union(rect) ?? rect }
                previous = glyph
            }
            if let lineBounds {
                lines.append(.init(utf16Range: start..<orderedUnits.count, bounds: lineBounds))
            }
        }
        return ExtractedPageText(text: String(decoding: orderedUnits, as: UTF16.self),
                                 charUiRects: charUiRects, lines: lines, geometry: geometry,
                                 discretionaryHyphens: discretionaryHyphens)
    }

    private static func isVisible(_ char: PdfiumCharBox, on page: PageGeometry) -> Bool {
        let box = char.selectionBounds
        // Use ink when present. A blank space or a zero-width mapped scalar
        // can only be tested against its advance box or origin.
        let left = char.left < char.right ? char.left : box.x
        let right = char.left < char.right ? char.right : box.x + box.width
        let bottom = char.bottom < char.top ? char.bottom : box.y
        let top = char.bottom < char.top ? char.top : box.y + box.height
        return right > page.left && left < page.right && top > page.bottom && bottom < page.top
    }

    private static func sharesLine(_ a: Glyph, _ b: Glyph, height: Double) -> Bool {
        let baselineGap = a.baseline - b.baseline
        if baselineGap <= 0.15 * height { return true }
        let overlap = min(a.bounds.y + a.bounds.height, b.bounds.y + b.bounds.height) - max(a.bounds.y, b.bounds.y)
        return baselineGap <= 0.4 * height && overlap >= 0.5 * min(a.bounds.height, b.bounds.height)
    }

    private static func fragments(_ row: ArraySlice<Glyph>, height: Double) -> [Fragment] {
        let sorted = row.sorted { ($0.bounds.x, $0.source.lowerBound) < ($1.bounds.x, $1.source.lowerBound) }
        var result: [Fragment] = []
        var start = 0
        var right = sorted[0].right
        for index in sorted.indices.dropFirst() {
            if sorted[index].bounds.x - right >= 3 * height {
                result.append(Fragment(glyphs: sorted[start..<index], left: sorted[start].bounds.x, right: right))
                start = index
            }
            right = max(right, sorted[index].right)
        }
        result.append(Fragment(glyphs: sorted[start...], left: sorted[start].bounds.x, right: right))
        return result
    }

    private static func readingOrder(in rows: [[Fragment]], height: Double) -> [Fragment] {
        // Project disjoint horizontal intervals in this vertical band. Prefer
        // rows with observed gaps so a spanning heading cannot hide the gutter.
        let splitRows = rows.filter { $0.count > 1 }
        let projected = (splitRows.isEmpty ? rows : splitRows).joined().sorted { $0.left < $1.left }
        guard let first = projected.first else { return [] }
        var right = first.right
        var gutters: [Double] = []
        for fragment in projected.dropFirst() {
            if fragment.left - right >= 1.5 * height {
                gutters.append(right + (fragment.left - right) / 2)
            }
            right = max(right, fragment.right)
        }
        guard !gutters.isEmpty else { return Array(rows.joined()) }

        var result: [Fragment] = []
        var columns = [[Fragment]](repeating: [], count: gutters.count + 1)
        func column(for x: Double) -> Int {
            var low = 0
            var high = gutters.count
            while low < high {
                let middle = (low + high) / 2
                if x > gutters[middle] { low = middle + 1 } else { high = middle }
            }
            return low
        }
        for row in rows {
            if row.contains(where: { column(for: $0.left) != column(for: $0.right) }) {
                result.append(contentsOf: columns.joined())
                result.append(contentsOf: row)
                columns = [[Fragment]](repeating: [], count: gutters.count + 1)
            } else {
                for fragment in row {
                    columns[column(for: fragment.left)].append(fragment)
                }
            }
        }
        result.append(contentsOf: columns.joined())
        return result
    }

    private static func hasGeneratedSpace(between a: Glyph, and b: Glyph, in raw: PdfiumPageText) -> Bool {
        guard a.source.upperBound < b.source.lowerBound else { return false }
        // Generated CR/LF reflects PDFium stream grouping. Only a generated
        // space between adjacent glyphs on the same fragment is relevant.
        let gap = raw.chars[a.source.upperBound..<b.source.lowerBound]
        return gap.allSatisfy { $0.isGenerated && $0.codeUnit == 32 }
    }

    private static func displayRect(_ bounds: AnnotationRect, geometry: PageGeometry) -> AnnotationRect? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let a = geometry.pdfToUi(bounds.x, bounds.y)
        let b = geometry.pdfToUi(bounds.x + bounds.width, bounds.y + bounds.height)
        return AnnotationRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}
