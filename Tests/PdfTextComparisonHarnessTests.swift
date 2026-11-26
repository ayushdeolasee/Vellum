import CryptoKit
import Foundation
import PDFKit
import VellumCore
import XCTest
@testable import Vellum

final class PdfTextComparisonHarnessTests: XCTestCase {
    func testPdfKitReferences() async throws {
        let bundle = Bundle(for: Self.self)
        let bundledPdf = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("Pdf", isDirectory: true)
        let bundledGolden = try XCTUnwrap(bundle.resourceURL).appendingPathComponent("PdfTextGolden", isDirectory: true)
        let output = ProcessInfo.processInfo.environment["VELLUM_PDF_TEXT_GOLDEN_OUTPUT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }

        let mismatches = try await Task.detached {
            try await Self.generateOrCompare(pdfs: bundledPdf, goldens: bundledGolden, output: output)
        }.value
        XCTAssertEqual(mismatches, [], "Sources or PDFKit references changed")
    }

    private static func generateOrCompare(pdfs: URL, goldens: URL, output: URL?) async throws -> [String] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let names = [
            "classic-two-column", "digitally-signed", "encrypted-user-pass", "foreign-annotations",
            "ipad-vellum-ink", "pdf-ink-erased-full", "pdf-ink-erased-partial", "pdf-ink-marker",
            "pdf-ink-rotated", "rotated-all-angles", "text-selection-edge-cases", "xref-stream-objstm"
        ]
        var mismatches: [String] = []
        for name in names {
            let input = pdfs.appendingPathComponent(name + ".pdf")
            let data: Data
            if name == "text-selection-edge-cases" {
                data = edgeCasePdf()
                if let output {
                    try data.write(to: output.appendingPathComponent(input.lastPathComponent), options: .atomic)
                } else if try Data(contentsOf: input) != data {
                    mismatches.append(input.lastPathComponent)
                }
            } else {
                data = try Data(contentsOf: input)
            }
            let reference = try ReferenceDocument(data: data, password: name == "encrypted-user-pass" ? "vellum" : nil)
            var pages: [Golden.Page] = []
            for number in 1...reference.pageCount {
                _ = await PageTextExtractionGate.shared.extractText(priority: .onDemand, offMain: {
                    await reference.capture(page: number, probes: probes(for: name, page: number))
                })
                pages.append(try await reference.takeSnapshot())
            }
            let sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let golden = Golden(fixture: input.lastPathComponent, pdfSHA256: sha256, pages: pages)
            var json = try encoder.encode(golden)
            json.append(10)
            let file = name + ".json"
            if let output {
                try json.write(to: output.appendingPathComponent(file), options: .atomic)
            } else if try Data(contentsOf: goldens.appendingPathComponent(file)) != json {
                mismatches.append(file)
            }
        }
        return mismatches
    }

    private struct Golden: Encodable, Sendable {
        let version = 1
        let fixture: String
        let pdfSHA256: String
        let pages: [Page]

        struct Page: Encodable, Sendable {
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

        struct Quote: Encodable, Sendable {
            let query: String
            let utf16Range: Range<Int>?
            let pdfkitSelectionText: String?
            let pdfkitSelectionRanges: [Range<Int>]?
            let pdfkitUiRects: [AnnotationRect]?
        }

        struct Drag: Encodable, Sendable {
            let name: String
            let initialQuery: String
            let edge: PdfTextLocatorPortable.Edge
            let x: Double
            let y: Double
            let targetGlyph: Int?
            let targetFraction: Double?
            let result: PositionData?
        }
    }

    private struct Probes: Sendable {
        struct Drag: Sendable {
            enum Target: Sendable { case character(String, offset: Int, fraction: Double = 0.5), beforeLine, afterLine }
            let name: String
            let initialQuery: String
            let edge: PdfTextLocatorPortable.Edge
            let target: Target
        }
        let quotes: [String]
        var drags: [Drag] = []
        var pinRotatedEndpoints = false
    }

    private actor ReferenceDocument {
        private let document: PDFDocument
        nonisolated let pageCount: Int
        private var snapshot: Golden.Page?

        init(data: Data, password: String?) throws {
            guard let document = PDFDocument(data: data) else { throw CocoaError(.fileReadCorruptFile) }
            if let password, !document.unlock(withPassword: password) {
                throw CocoaError(.fileReadNoPermission)
            }
            guard document.pageCount > 0 else { throw CocoaError(.fileReadCorruptFile) }
            self.document = document
            pageCount = document.pageCount
        }

        func capture(page number: Int, probes: Probes) -> String? {
            guard let page = document.page(at: number - 1) else { return nil }
            dispatchPrecondition(condition: .notOnQueue(.main))
            let text = page.string ?? ""
            let crop = page.bounds(for: .cropBox)
            let dimensions = PdfTextLocator.displayDimensions(of: page)
            if text.isEmpty {
                let current = PositionData(rects: [AnnotationRect(x: 10, y: 10, width: 50, height: 12)],
                                           pageWidth: dimensions.width, pageHeight: dimensions.height)
                guard PdfTextLocator.resizedPosition(
                    page: page, current: current, edge: .end, toDisplayPoint: CGPoint(x: 100, y: 16)
                ) == nil else { return nil }
            }
            func locate(_ query: String) -> LocatedText? {
                PdfTextLocator.locate(pageNumber: number, query: query, in: document, pageString: text)
            }
            let quotes = probes.quotes.map { query in
                let range = PdfTextSelectionMath.firstMatch(of: query, in: text)
                let selection = range.flatMap { page.selection(for: NSRange(location: $0.lowerBound, length: $0.count)) }
                let selectedRanges = selection.map { selection in
                    (0..<selection.numberOfTextRanges(on: page)).compactMap { index -> Range<Int>? in
                        let range = selection.range(at: index, on: page)
                        guard range.location != NSNotFound else { return nil }
                        return range.location..<NSMaxRange(range)
                    }
                }
                return Golden.Quote(query: query, utf16Range: range, pdfkitSelectionText: selection?.string,
                                    pdfkitSelectionRanges: selectedRanges, pdfkitUiRects: locate(query)?.positionData.rects)
            }
            let drags = probes.drags.compactMap { probe -> Golden.Drag? in
                guard let initial = locate(probe.initialQuery)?.positionData, let rect = initial.rects.first else {
                    return nil
                }
                let target: CGPoint
                let targetGlyph: Int?
                let targetFraction: Double?
                switch probe.target {
                case let .character(word, offset, fraction):
                    guard let range = PdfTextSelectionMath.firstMatch(of: word, in: text),
                          range.contains(range.lowerBound + offset),
                          let char = page.selection(for: NSRange(location: range.lowerBound + offset, length: 1))
                    else { return nil }
                    let bounds = char.bounds(for: page)
                    let nativePoint = CGRect(x: bounds.minX + fraction * bounds.width,
                                             y: bounds.midY, width: 0, height: 0)
                    let geometry = PdfTextLocator.uiRect(fromPageSpace: nativePoint, page: page)
                    target = CGPoint(x: geometry.x, y: geometry.y)
                    targetGlyph = range.lowerBound + offset
                    targetFraction = fraction
                case .beforeLine, .afterLine:
                    let x: Double
                    if case .beforeLine = probe.target { x = 0 } else { x = dimensions.width + 1_000 }
                    target = CGPoint(x: x, y: rect.y + rect.height / 2)
                    targetGlyph = nil
                    targetFraction = nil
                }
                let result = PdfTextLocator.resizedPosition(page: page, current: initial,
                    edge: probe.edge == .start ? .start : .end, toDisplayPoint: target)
                if probes.pinRotatedEndpoints {
                    guard let selectedText = result?.selectedText,
                          let outputRect = result?.rects.first
                    else { return nil }
                    let start = probe.edge == .end
                    guard start ? selectedText.hasPrefix(probe.initialQuery) : selectedText.hasSuffix(probe.initialQuery)
                    else { return nil }
                    // Compare in native page space, so the asserted endpoint
                    // is independent of display axis and sign.
                    func endpoint(_ rect: AnnotationRect) -> Double {
                        let a = PdfTextLocator.pageSpacePoint(fromDisplay: CGPoint(x: rect.x, y: rect.y), page: page)
                        let b = PdfTextLocator.pageSpacePoint(
                            fromDisplay: CGPoint(x: rect.x + rect.width, y: rect.y + rect.height), page: page)
                        return start ? min(a.x, b.x) : max(a.x, b.x)
                    }
                    guard abs(endpoint(rect) - endpoint(outputRect)) < 0.001 else { return nil }
                }
                return Golden.Drag(name: probe.name, initialQuery: probe.initialQuery, edge: probe.edge,
                                   x: target.x, y: target.y, targetGlyph: targetGlyph,
                                   targetFraction: targetFraction, result: result)
            }
            guard drags.count == probes.drags.count else { return nil }
            snapshot = Golden.Page(page: number, pdfkitText: text, pdfkitCharacterCount: page.numberOfCharacters,
                                   cropBox: AnnotationRect(x: crop.minX, y: crop.minY,
                                                           width: crop.width, height: crop.height),
                                   rotation: page.rotation, displayWidth: dimensions.width,
                                   displayHeight: dimensions.height, probes: quotes, drags: drags)
            return text
        }

        func takeSnapshot() throws -> Golden.Page {
            guard let snapshot else { throw CocoaError(.coderInvalidValue) }
            self.snapshot = nil
            return snapshot
        }
    }

    private static func probes(for name: String, page: Int) -> Probes {
        switch name {
        case "classic-two-column", "encrypted-user-pass", "digitally-signed":
            return Probes(quotes: ["  COLUMN:\tCAFÉ ", "Café First line", "Right column: naïve",
                                   "evidence.", "evidence. Right column", "Second line", "missing quote"])
        case "foreign-annotations":
            return Probes(quotes: ["Highlighted text", "Margin note"])
        case "rotated-all-angles":
            return Probes(quotes: ["Rotation \((page - 1) * 90)", "degrees"], drags: [
                .init(name: "extend end on rotated page", initialQuery: "Rotation", edge: .end,
                      target: .character("degrees", offset: 4)),
                .init(name: "extend start on rotated page", initialQuery: "degrees", edge: .start,
                      target: .character("Rotation", offset: 2)),
                .init(name: "extend end before rotated midpoint", initialQuery: "Rotation", edge: .end,
                      target: .character("degrees", offset: 4, fraction: 0.25)),
                .init(name: "extend end after rotated midpoint", initialQuery: "Rotation", edge: .end,
                      target: .character("degrees", offset: 4, fraction: 0.75)),
                .init(name: "extend start before rotated midpoint", initialQuery: "degrees", edge: .start,
                      target: .character("Rotation", offset: 2, fraction: 0.25)),
                .init(name: "extend start after rotated midpoint", initialQuery: "degrees", edge: .start,
                      target: .character("Rotation", offset: 2, fraction: 0.75))
            ], pinRotatedEndpoints: true)
        case "xref-stream-objstm":
            return Probes(quotes: ["Compressed page dictionary"])
        case "text-selection-edge-cases" where page == 1:
            return Probes(quotes: ["quick brown", "first line", "wrapping selection", "hyphen- ated"], drags: [
                .init(name: "extend end", initialQuery: "quick brown", edge: .end,
                      target: .character("jumps", offset: 2)),
                .init(name: "extend start", initialQuery: "fox", edge: .start,
                      target: .character("The", offset: 1)),
                .init(name: "clamp end past page", initialQuery: "quick brown", edge: .end, target: .afterLine),
                .init(name: "reject drag into left margin", initialQuery: "quick brown", edge: .end,
                      target: .beforeLine),
                .init(name: "cross pinned start", initialQuery: "quick brown", edge: .end,
                      target: .character("The", offset: 1)),
                .init(name: "cross pinned end", initialQuery: "fox", edge: .start,
                      target: .character("jumps", offset: 2)),
                .init(name: "extend across lines", initialQuery: "first line", edge: .end,
                      target: .character("selection", offset: 3)),
                .init(name: "extend across lines before midpoint", initialQuery: "first line", edge: .end,
                      target: .character("selection", offset: 3, fraction: 0.25)),
                .init(name: "extend across lines after midpoint", initialQuery: "first line", edge: .end,
                      target: .character("selection", offset: 3, fraction: 0.75))
            ])
        case "text-selection-edge-cases" where page == 2:
            return Probes(quotes: ["🙂", "é", "ﬁ", "fi", "after", "End"])
        case "text-selection-edge-cases":
            return Probes(quotes: ["spanning title", "left second", "right first", "Outside crop", "Footer"])
        default:
            return Probes(quotes: ["missing quote"])
        }
    }

    private static func edgeCasePdf() -> Data {
        func stream(_ contents: String) -> String {
            "<< /Length \(contents.utf8.count) >>\nstream\n\(contents)\nendstream"
        }
        func page(_ contents: Int) -> String {
            "<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 3 0 R /Unicode 4 0 R >> >> /Contents \(contents) 0 R >>"
        }
        return PdfFixtureBuilder.classicObjects([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [6 0 R 8 0 R 10 0 R] /Count 3 /MediaBox [0 0 612 500] /CropBox [20.25 40.5 580.75 475.125] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding /ToUnicode 5 0 R >>",
            stream("""
            /CIDInit /ProcSet findresource begin
            12 dict begin begincmap
            /CIDSystemInfo << /Registry (Test) /Ordering (Unicode) /Supplement 0 >> def
            /CMapName /P2-Test def /CMapType 2 def
            1 begincodespacerange <00> <FF> endcodespacerange
            3 beginbfchar
            <42> <D83DDE42>
            <43> <00650301>
            <44> <FB01>
            endbfchar
            endcmap CMapName currentdict /CMap defineresource pop end end
            """),
            page(7),
            stream("""
            BT /F1 18 Tf 40 325 Td (ated word) Tj ET
            BT /F1 18 Tf 40 430 Td (The quick brown fox jumps over the lazy dog) Tj ET
            BT /F1 14 Tf 40 360 Td (Wrapping selection and a hyphen-) Tj ET
            BT /F1 14 Tf 40 384 Td (A first line of text.) Tj ET
            """),
            page(9),
            stream("""
            BT /Unicode 14 Tf 40 430 Td (A B C D after) Tj ET
            BT /F1 14 Tf 40 406 Td (End) Tj ET
            """),
            page(11),
            stream("""
            BT /F1 14 Tf 40 487 Td (Outside crop) Tj ET
            BT /F1 14 Tf 350 416 Td (Right first with space) Tj ET
            BT /F1 14 Tf 40 394 Td (Left second) Tj ET
            BT /F1 18 Tf 40 446 Td (Long spanning title stretching over the gutter and both columns) Tj ET
            BT /F1 14 Tf 350 394 Td (Right second) Tj ET
            BT /F1 14 Tf 40 416 Td (Left first) Tj ET
            BT /F1 14 Tf 40 280 Td (Footer) Tj ET
            """)
        ])
    }
}
