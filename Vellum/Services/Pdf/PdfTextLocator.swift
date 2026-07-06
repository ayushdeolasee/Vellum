import Foundation
import PDFKit

// Cross-platform PDF text geometry + AI highlight locator — the pure algorithms
// from the macOS PdfViewerController's static helpers, extracted so the iPad
// viewer reuses identical math (page-space→UI mapping, line merging, and the
// whitespace-insensitive first-match locator from highlight-locator.ts).
enum PdfTextLocator {
    /// Whitespace-stripped, lowercased first-match locator returning line-merged
    /// rects at zoom 1 in top-left-origin page points.
    static func locate(pageNumber: Int, query: String, in document: PDFDocument) -> LocatedText? {
        guard pageNumber >= 1, pageNumber <= document.pageCount,
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
            rects.append(uiRect(fromPageSpace: bounds, page: linePage))
        }
        let merged = mergeLineRects(rects)
        guard !merged.isEmpty else { return nil }

        let dims = displayDimensions(of: page)
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

    /// pdf_to_ui with UserUnit = 1: PDF page space (bottom-left, CropBox-relative)
    /// → top-left display space.
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
}
