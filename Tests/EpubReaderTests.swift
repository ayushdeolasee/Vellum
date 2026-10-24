import Foundation
import Testing
#if os(macOS)
import AppKit
import WebKit
#endif
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
    @MainActor @Test("Focused EPUB content routes command brackets to chapters")
    func chapterShortcuts() throws {
        let window = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        let webView = EpubChapterWebView(frame: .zero, configuration: WKWebViewConfiguration())
        window.contentView = webView
        #expect(window.makeFirstResponder(webView))
        var steps: [Int] = []
        webView.onChapterStep = { steps.append($0) }
        func event(_ key: String, modifiers: NSEvent.ModifierFlags = .command) throws -> NSEvent {
            try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key,
                charactersIgnoringModifiers: key, isARepeat: false, keyCode: key == "[" ? 33 : 30))
        }
        #expect(webView.performKeyEquivalent(with: try event("[")))
        #expect(webView.performKeyEquivalent(with: try event("]")))
        #expect(steps == [-1, 1])
        _ = webView.performKeyEquivalent(with: try event("]", modifiers: [.command, .shift]))
        _ = webView.performKeyEquivalent(with: try event("[", modifiers: []))
        #expect(steps == [-1, 1])
        window.makeFirstResponder(nil)
        _ = webView.performKeyEquivalent(with: try event("]"))
        #expect(steps == [-1, 1])
        webView.onChapterStep = nil
        window.contentView = nil
    }

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
