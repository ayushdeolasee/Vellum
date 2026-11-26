import Foundation

/// Search and selection geometry shared by PDFKit and the portable reader.
public enum PdfTextSelectionMath {
    /// First whitespace-insensitive, case-insensitive match in the original UTF-16 string.
    public static func firstMatch(of query: String, in text: String) -> Range<Int>? {
        firstMatch(of: query, in: text, ignoring: [])
    }

    static func firstMatch(of query: String, in text: String, ignoring offsets: Set<Int>) -> Range<Int>? {
        let needle = Array(query.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
            .lowercased())
        guard !needle.isEmpty, !text.isEmpty else { return nil }

        // Keep the full source range for every character emitted by lowercasing.
        // A grapheme can span multiple UTF-16 units or lowercase into multiple characters.
        var haystack: [Character] = []
        var owners: [Range<Int>] = []
        var offset = 0
        for character in text {
            let source = String(character)
            let end = offset + source.utf16.count
            if !character.isWhitespace, !offsets.contains(offset) {
                for lowered in source.lowercased() {
                    haystack.append(lowered)
                    owners.append(offset..<end)
                }
            }
            offset = end
        }

        guard haystack.count >= needle.count else { return nil }
        for start in 0...(haystack.count - needle.count) {
            let end = start + needle.count
            if haystack[start..<end].elementsEqual(needle) {
                return owners[start].lowerBound..<owners[end - 1].upperBound
            }
        }
        return nil
    }

    /// Apple highlight positions are stored in visual order with same-line bounds merged.
    public static func mergeLineRects(_ rects: [AnnotationRect]) -> [AnnotationRect] {
        let sorted = rects.sorted { $0.y != $1.y ? $0.y < $1.y : $0.x < $1.x }
        var lines: [AnnotationRect] = []
        for rect in sorted {
            if let last = lines.last, abs(rect.y - last.y) <= 0.6 * min(rect.height, last.height) {
                lines[lines.count - 1] = last.union(rect)
            } else {
                lines.append(rect)
            }
        }
        return lines
    }
}

extension AnnotationRect {
    /// Smallest axis-aligned rectangle containing both bounds.
    public func union(_ other: AnnotationRect) -> AnnotationRect {
        let left = min(x, other.x)
        let top = min(y, other.y)
        return AnnotationRect(x: left, y: top, width: max(x + width, other.x + other.width) - left,
                              height: max(y + height, other.y + other.height) - top)
    }
}
