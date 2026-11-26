import Crypto
import Foundation
import Testing
import VellumCore
@testable import LinuxReader

// Keep PDFium tests on the same serialized suite. The existing worker tests
// rely on counting their own queued jobs.
extension PdfiumTests {
    @Test func comparesPdfKitGoldens() async throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/VellumCore/Tests/VellumCoreTests/Fixtures")
        let directory = fixtures.appendingPathComponent("PdfTextGolden")
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(files.count == 12)
        let blankDragSource = try await PdfiumDocument.readText(
            in: Data(contentsOf: fixtures.appendingPathComponent("Pdf/foreign-annotations.pdf")), at: 0)
        let blankDrag = try #require(PdfTextLocatorPortable.locate(query: "Highlighted", in: blankDragSource))
        var observed: Set<String> = []
        for file in files {
            let golden = try JSONDecoder().decode(PdfTextGolden.self, from: Data(contentsOf: file))
            try #require(golden.version == 1)
            let bytes = try Data(contentsOf: fixtures.appendingPathComponent("Pdf").appendingPathComponent(golden.fixture))
            let sha256 = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            try #require(sha256 == golden.pdfSHA256, "Reference was generated from different PDF bytes")
            let password = golden.fixture == "encrypted-user-pass.pdf" ? "vellum" : nil
            let info = try await PdfiumDocument.pageInfo(in: bytes, at: 0, password: password)
            #expect(info.pageCount == golden.pages.count)
            for reference in golden.pages {
                let page = try await PdfiumDocument.readText(in: bytes, at: reference.page - 1, password: password)
                let label = "\(golden.fixture):\(reference.page)"
                func difference(_ check: String, _ details: String) {
                    observed.insert("\(label) \(check)")
                    print("DIFFERENCE \(label) \(check) \(details)")
                }
                let geometry = page.geometry
                let crop = AnnotationRect(x: geometry.left, y: geometry.bottom, width: geometry.width, height: geometry.height)
                #expect(crop == reference.cropBox, "\(label)")
                #expect(geometry.rotation == reference.rotation, "\(label)")
                #expect(geometry.displayWidth == reference.displayWidth, "\(label)")
                #expect(geometry.displayHeight == reference.displayHeight, "\(label)")
                #expect(page.charUiRects.count == page.text.utf16.count, "\(label)")
                #expect(page.text.utf16.count == reference.pdfkitText.utf16.count, "\(label)")
                for line in page.lines {
                    #expect(!line.utf16Range.isEmpty && line.utf16Range.upperBound <= page.charUiRects.count, "\(label)")
                }

                let similarity = textOrderSimilarity(reference.pdfkitText, page.text)
                let exact = sameUnits(reference.pdfkitText, page.text)
                print("TEXT \(label) exact=\(exact) order=\(similarity) utf16=\(reference.pdfkitText.utf16.count)/\(page.text.utf16.count) pdfkitCharacterCount=\(reference.pdfkitCharacterCount)")
                if !exact {
                    difference("raw text", "\(String(reflecting: reference.pdfkitText)) → \(String(reflecting: page.text))")
                    #expect(sameUnits(page.text, twoColumnText), "\(label)")
                }
                if similarity < 0.98 {
                    difference("reading order", "\(similarity) < 0.98")
                }

                for quote in reference.probes {
                    let actual = PdfTextLocatorPortable.locate(query: quote.query, in: page)
                    let range = actual?.utf16Range
                    if let pdfkitRanges = quote.pdfkitSelectionRanges, let range,
                       pdfkitRanges != [range] {
                        difference("PDFKit selection range \(quote.query)", "\(pdfkitRanges) → \(range)")
                        // PDFKit can report the trailing line break even when
                        // its selection string and rectangles omit it.
                        #expect(pdfkitRanges == [range.lowerBound..<(range.upperBound + 1)], "\(label)")
                    }
                    if range != quote.utf16Range {
                        difference("quote range \(quote.query)", "\(String(describing: quote.utf16Range)) → \(String(describing: range))")
                    }
                    let selected = range.map { (page.text as NSString).substring(with: NSRange(location: $0.lowerBound, length: $0.count)) }
                    if !sameUnits(quote.pdfkitSelectionText, selected) {
                        difference("quote text \(quote.query)", "\(String(describing: quote.pdfkitSelectionText)) → \(String(describing: selected))")
                        #expect(sameUnits(selected, knownQuoteText[quote.query]), "\(label)")
                    }
                    let bounds = compareRects(quote.pdfkitUiRects, actual?.positionData.rects)
                    if !bounds.passes {
                        difference("quote bounds \(quote.query)", bounds.details)
                    } else if let iou = bounds.iou {
                        print("QUOTE \(label) \(quote.query.debugDescription) range=\(String(describing: range)) IoU=\(iou) edge=\(bounds.edge)")
                    }
                }

                for drag in reference.drags {
                    let initial = try #require(PdfTextLocatorPortable.locate(query: drag.initialQuery, in: page))
                    let actual = PdfTextLocatorPortable.resizedPosition(
                        page: page, current: initial, edge: drag.edge, toDisplayX: drag.x, y: drag.y
                    )
                    if let actual {
                        switch drag.edge {
                        case .start: #expect(actual.utf16Range.upperBound == initial.utf16Range.upperBound)
                        case .end: #expect(actual.utf16Range.lowerBound == initial.utf16Range.lowerBound)
                        }
                        #expect(actual.positionData.startOffset == nil && actual.positionData.endOffset == nil)
                    }
                    let textMatches = sameUnits(drag.result?.selectedText, actual?.positionData.selectedText)
                    if !textMatches {
                        difference("drag text \(drag.name)", "\(String(describing: drag.result?.selectedText)) → \(String(describing: actual?.positionData.selectedText))")
                        #expect(sameUnits(actual?.positionData.selectedText, knownDragText[label]?[drag.name]), "\(label)")
                    }
                    let bounds = compareRects(drag.result?.rects, actual?.positionData.rects)
                    if !bounds.passes {
                        difference("drag bounds \(drag.name)", bounds.details)
                    } else if let iou = bounds.iou {
                        print("DRAG \(label) \(drag.name.debugDescription) textExact=\(textMatches) IoU=\(iou) edge=\(bounds.edge)")
                    } else {
                        print("DRAG \(label) \(drag.name.debugDescription) both refused")
                    }
                }

                if reference.pdfkitText.isEmpty {
                    #expect(PdfTextLocatorPortable.resizedPosition(
                        page: page, current: blankDrag, edge: .end, toDisplayX: 10, y: 10) == nil)
                }
                if label == "text-selection-edge-cases.pdf:1" {
                    let wrapped = PdfTextLocatorPortable.locate(query: "hyphen- ated", in: page)
                    let joined = PdfTextLocatorPortable.locate(query: "hyphenated", in: page)
                    #expect(joined != nil && joined?.utf16Range == wrapped?.utf16Range)
                    #expect(joined?.positionData.rects == wrapped?.positionData.rects)
                }
            }
        }
        #expect(observed == knownDifferences, "Observed PDFKit/PDFium differences: \(observed.sorted())")
    }
}

private struct PdfTextGolden: Decodable {
    let version: Int
    let fixture: String
    let pdfSHA256: String
    let pages: [Page]

    struct Page: Decodable {
        let page: Int
        let pdfkitText: String
        let pdfkitCharacterCount: Int
        let cropBox: AnnotationRect
        let rotation: Int
        let displayWidth: Double
        let displayHeight: Double
        let probes: [Quote]
        let drags: [Drag]
    }

    struct Quote: Decodable {
        let query: String
        let utf16Range: Range<Int>?
        let pdfkitSelectionText: String?
        let pdfkitSelectionRanges: [Range<Int>]?
        let pdfkitUiRects: [AnnotationRect]?
    }

    struct Drag: Decodable {
        let name: String
        let initialQuery: String
        let edge: PdfTextLocatorPortable.Edge
        let x: Double
        let y: Double
        let result: PositionData?
    }
}

// Keep the exact divergent results visible and test for added or removed drift.
private let twoColumnText = """
    Left column: Café
    First line of evidence.
    Right column: naïve
    Second line of evidence.
    """
private let knownQuoteText = [
    "Café First line": "Café\nFirst line",
    "evidence. Right column": "evidence.\nRight column"
]
private let extendEnd = "extend end on rotated page"
private let extendStart = "extend start on rotated page"
private let knownDragText = [
    "rotated-all-angles.pdf:1": [extendEnd: "Rotation 0 degre"],
    "rotated-all-angles.pdf:2": [extendEnd: "Rotation 90 degre", extendStart: "ation 90 degrees"],
    "rotated-all-angles.pdf:3": [extendEnd: "Rotation 180 degre", extendStart: "ation 180 degrees"],
    "rotated-all-angles.pdf:4": [extendEnd: "Rotation 270 degre", extendStart: "ation 270 degrees"],
    "text-selection-edge-cases.pdf:1": ["extend across lines": "first line of text.\nWrapping sel"]
]

private var knownDifferences: Set<String> {
    let twoColumnFiles = ["classic-two-column", "digitally-signed", "encrypted-user-pass"]
    var result = Set(twoColumnFiles.flatMap { name in
        ["\(name).pdf:1 raw text", "\(name).pdf:1 PDFKit selection range Right column: naïve"]
            + knownQuoteText.keys.map { "\(name).pdf:1 quote text \($0)" }
    })
    result.insert("text-selection-edge-cases.pdf:2 PDFKit selection range after")
    result.insert("text-selection-edge-cases.pdf:3 PDFKit selection range left second")
    for (label, drags) in knownDragText {
        for name in drags.keys {
            result.insert("\(label) drag text \(name)")
            result.insert("\(label) drag bounds \(name)")
        }
    }
    return result
}

private func sameUnits(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case let (a?, b?): return a.utf16.elementsEqual(b.utf16)
    case (nil, nil): return true
    default: return false
    }
}

/// Levenshtein similarity of non-whitespace UTF-16 units. Raw text, selection
/// text, and offsets are checked separately without any normalization.
private func textOrderSimilarity(_ a: String, _ b: String) -> Double {
    let left = Array(a.filter { !$0.isWhitespace }.utf16)
    let right = Array(b.filter { !$0.isWhitespace }.utf16)
    guard left != right else { return 1 }
    var previous = Array(0...right.count)
    var row = previous
    for (i, unit) in left.enumerated() {
        row[0] = i + 1
        for (j, other) in right.enumerated() {
            row[j + 1] = min(previous[j + 1] + 1, row[j] + 1, previous[j] + (unit == other ? 0 : 1))
        }
        swap(&row, &previous)
    }
    return 1 - Double(previous[right.count]) / Double(max(left.count, right.count))
}

private func compareRects(_ expected: [AnnotationRect]?, _ actual: [AnnotationRect]?)
    -> (passes: Bool, iou: Double?, edge: Double, details: String) {
    guard let expected, let actual, expected.count == actual.count, !expected.isEmpty else {
        return (expected == nil && actual == nil, nil, 0,
                "rect count \(expected?.count ?? 0) → \(actual?.count ?? 0)")
    }
    var iou = 1.0
    var edge = 0.0
    for (a, b) in zip(expected, actual) {
        let rightA = a.x + a.width, bottomA = a.y + a.height
        let rightB = b.x + b.width, bottomB = b.y + b.height
        let width = max(0, min(rightA, rightB) - max(a.x, b.x))
        let height = max(0, min(bottomA, bottomB) - max(a.y, b.y))
        let intersection = width * height
        let union = a.width * a.height + b.width * b.height - intersection
        iou = min(iou, union > 0 ? intersection / union : 0)
        edge = max(edge, abs(a.x - b.x), abs(a.y - b.y), abs(rightA - rightB), abs(bottomA - bottomB))
    }
    return (iou >= 0.85 && edge <= 3, iou, edge, "IoU=\(iou) edge=\(edge)")
}
