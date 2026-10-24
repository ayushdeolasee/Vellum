import Foundation
import Testing
@testable import Vellum

@Suite("EPUB reader locations")
struct EpubReaderTests {
    private let docId = String(repeating: "ab", count: 32)

    private func book(docId: String?) -> DocumentInfo {
        DocumentInfo(kind: .epub, pdfPath: "/tmp/b.epub", title: "B", pageCount: 12, lastPage: nil, docId: docId)
    }

    @Test("EPUB positions key by content docId in their own namespace")
    func positionKey() throws {
        let key = try #require(DocumentPositionService.key(for: book(docId: docId)))
        #expect(key.rawValue == "epub:\(docId)")
        #expect(DocumentKey(rawValue: key.rawValue) == key)
        #expect(DocumentPositionService.key(for: book(docId: nil)) == nil)
        #expect(DocumentPositionService.key(for: book(docId: "not-a-hash")) == nil)
    }

    @MainActor @Test("Tab reading positions carry chapter progression only for EPUB")
    func readingPosition() {
        var tab = PdfTab(
            id: "t", document: book(docId: docId), currentPage: 3, numPages: 12, zoom: 1,
            visiblePages: [], webVisibleRange: nil, webVisibleBookmarks: [], mode: .view)
        tab.epubProgression = 0.4
        #expect(WorkspaceStore.readingPosition(for: tab) == ReadingPosition(page: 3, pageCount: 12, scrollFraction: 0.4))
        tab.document?.kind = .pdf
        #expect(WorkspaceStore.readingPosition(for: tab).scrollFraction == nil)
    }

    #if os(macOS)
    @Test("Resource URLs round-trip archive paths")
    func resourceURLs() {
        for path in ["OEBPS/text/ch 1.xhtml", "OPS/Ünïcode#1.xhtml", "a/b%20c.css"] {
            let url = EpubResourceSchemeHandler.url(for: path)
            #expect(url.scheme == "vellum-epub")
            #expect(EpubResourceSchemeHandler.archivePath(for: url) == path)
        }
        #expect(EpubResourceSchemeHandler.archivePath(for: URL(string: "https://book/OEBPS/a.xhtml")!) == nil)
        #expect(EpubResourceSchemeHandler.archivePath(for: URL(string: "vellum-epub://other/a.xhtml")!) == nil)
    }
    #endif
}
