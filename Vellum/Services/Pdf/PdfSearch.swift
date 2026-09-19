#if os(macOS)
import Foundation
import PDFKit

/// Each query owns a private PDF on this actor. Only page numbers and UTF-16
/// ranges cross back to the displayed document; PDFKit objects never do.
actor PdfSearch {
    struct Match: Sendable {
        let page: Int
        let range: NSRange
    }

    private let data: Data
    private var document: PDFDocument?

    init(data: Data) {
        self.data = data
    }

    func matches(query: String) async -> [Match] {
        guard !query.isEmpty, !Task.isCancelled,
              let document = PDFDocument(data: data) else { return [] }
        self.document = document
        defer { self.document = nil }
        var matches: [Match] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return [] }
            let text = await PageTextExtractionGate.shared.extractText(priority: .onDemand, offMain: {
                await self.pageText(index)
            })
            guard !Task.isCancelled, let text else { return [] }
            let source = text as NSString
            var remaining = NSRange(location: 0, length: source.length)
            while remaining.length > 0 {
                guard !Task.isCancelled else { return [] }
                let range = source.range(of: query, options: .caseInsensitive, range: remaining)
                guard range.location != NSNotFound, range.length > 0 else { break }
                matches.append(Match(page: index, range: range))
                let end = NSMaxRange(range)
                remaining = NSRange(location: end, length: source.length - end)
            }
        }
        return matches
    }

    private func pageText(_ index: Int) -> String? {
        guard !Task.isCancelled else { return nil }
        return document?.page(at: index)?.string ?? ""
    }
}
#endif
