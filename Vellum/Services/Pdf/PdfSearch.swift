import Foundation
import PDFKit

/// Each query owns a private PDF on this actor. Only page numbers and UTF-16
/// ranges cross back to the displayed document; PDFKit objects never do.
actor PdfSearch {
    struct Match: Sendable, Equatable {
        let page: Int
        let range: NSRange
    }

    struct Result: Sendable {
        var matches: [Match] = []
        var truncated = false
    }

    static let maximumMatches = 1_000
    private let data: Data
    private var document: PDFDocument?

    init(data: Data) {
        self.data = data
    }

    func matches(query: String) async -> Result {
        guard !query.isEmpty, !Task.isCancelled,
              let document = PDFDocument(data: data) else { return Result() }
        self.document = document
        defer { self.document = nil }
        var matches: [Match] = []
        for index in 0..<document.pageCount {
            guard !Task.isCancelled else { return Result() }
            let text = await PageTextExtractionGate.shared.extractText(priority: .onDemand, offMain: {
                await self.pageText(index)
            })
            guard !Task.isCancelled, let text else { return Result() }
            let source = text as NSString
            var remaining = NSRange(location: 0, length: source.length)
            while remaining.length > 0 {
                guard !Task.isCancelled else { return Result() }
                let range = source.range(of: query, options: .caseInsensitive, range: remaining)
                guard range.location != NSNotFound, range.length > 0 else { break }
                guard matches.count < Self.maximumMatches else {
                    return Result(matches: matches, truncated: true)
                }
                matches.append(Match(page: index, range: range))
                let end = NSMaxRange(range)
                remaining = NSRange(location: end, length: source.length - end)
            }
        }
        return Result(matches: matches)
    }

    private func pageText(_ index: Int) -> String? {
        guard !Task.isCancelled else { return nil }
        return document?.page(at: index)?.string ?? ""
    }
}

/// A request-local copy for AI reads and highlight geometry. PDFKit objects stay
/// on this actor; the viewer receives only text or Sendable coordinates.
actor PdfTextReader {
    private let data: Data
    private var document: PDFDocument?

    init(data: Data) { self.data = data }

    func text(pageNumber: Int) async -> String? {
        guard !Task.isCancelled else { return nil }
        if document == nil { document = PDFDocument(data: data) }
        return await PageTextExtractionGate.shared.extractText(priority: .onDemand, offMain: {
            await self.extract(pageNumber: pageNumber)
        })
    }

    private func extract(pageNumber: Int) -> String? {
        guard !Task.isCancelled, let document,
              pageNumber >= 1, pageNumber <= document.pageCount else { return nil }
        return document.page(at: pageNumber - 1)?.string ?? ""
    }

    func locate(pageNumber: Int, query: String) async -> LocatedText? {
        guard let text = await text(pageNumber: pageNumber), !Task.isCancelled,
              let document else { return nil }
        return PdfTextLocator.locate(pageNumber: pageNumber, query: query,
                                     in: document, pageString: text)
    }
}
