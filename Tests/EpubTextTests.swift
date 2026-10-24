import Foundation
import Testing

@testable import Vellum

@Suite("EPUB normalized text and durable anchors")
struct EpubTextTests {
    private let href = "OPS/text/chapter 1.xhtml"

    private func extract(_ body: String, limits: EpubTextExtractor.Limits = .standard) throws -> EpubChapterText {
        try EpubTextExtractor.extract(
            xhtml: Data("<html xmlns='http://www.w3.org/1999/xhtml'><body>\(body)</body></html>".utf8),
            chapterHref: href, limits: limits)
    }

    @Test("Document-order inline text, block separators, CDATA and entities")
    func xhtmlText() throws {
        let chapter = try EpubTextExtractor.extract(
            xhtml: Data(
                """
                <!DOCTYPE html SYSTEM "https://example.invalid/no.dtd">
                <html xmlns="http://www.w3.org/1999/xhtml"><head><title>Ignore</title><style>bad</style></head>
                <body><h1>A&nbsp;Book</h1><p>Hel<em>lo</em> &amp; &#x1F600; &mdash; &unknown;</p>
                <p><![CDATA[<plain>]]><br/>Next</p><table><tr><td>one</td><td>two</td></tr></table></body></html>
                """.utf8), chapterHref: href)
        #expect(chapter.chapterHref == href)
        #expect(chapter.text == "A Book Hello & 😀 — &unknown; <plain> Next one two")
    }

    @Test("Excluded subtrees do not leak script/style/head or explicitly hidden text")
    func excludedText() throws {
        let chapter = try extract(
            """
            <p>one<script>bad</script><style>bad</style><template>bad</template><noscript>bad</noscript>two</p>
            <div hidden='hidden'><p>bad</p></div><span aria-hidden='TRUE'>bad</span><p>three</p>
            """)
        #expect(chapter.text == "onetwo three")
    }

    @Test("The full whitespace set including NBSP collapses without Unicode folding")
    func whitespace() throws {
        let spaces =
            "\u{9}\u{A}\u{B}\u{C}\u{D}\u{20}\u{85}\u{A0}\u{1680}"
            + "\u{2000}\u{2001}\u{2002}\u{2003}\u{2004}\u{2005}\u{2006}\u{2007}\u{2008}\u{2009}\u{200A}"
            + "\u{2028}\u{2029}\u{202F}\u{205F}\u{3000}\u{FEFF}"
        #expect(EpubTextExtractor.normalizeWhitespace(spaces + "a" + spaces + "b" + spaces) == "a b")
        #expect(try extract("<p>A&#160;  B</p><p>C</p>").text == "A B C")
        #expect(EpubTextExtractor.normalizeWhitespace("e\u{301}").utf16.count == 2)
    }

    @Test("UTF-16 offsets include surrogate pairs and permit combining-mark boundaries")
    func utf16Ranges() throws {
        let chapter = try extract("<p>A😀e&#x301; Z</p>")
        #expect(chapter.utf16Count == 7)
        let emoji = try #require(chapter.anchor(in: NSRange(location: 1, length: 2)))
        #expect(emoji.quote == "😀")
        #expect(emoji.startUTF16 == 1 && emoji.endUTF16 == 3)
        #expect(chapter.resolve(emoji) == NSRange(location: 1, length: 2))
        #expect(chapter.quote(in: NSRange(location: 3, length: 1)) == "e")
        #expect(chapter.quote(in: NSRange(location: 4, length: 1)) == "\u{301}")
        #expect(chapter.anchor(in: NSRange(location: 2, length: 1)) == nil)
        #expect(chapter.quote(in: NSRange(location: 1, length: 1)) == nil)
        #expect(chapter.quote(in: NSRange(location: Int.max, length: Int.max)) == nil)
        #expect(chapter.quote(in: NSRange(location: -1, length: 1)) == nil)
        #expect(chapter.anchor(in: NSRange(location: 0, length: 0)) == nil)
        let bounded = try #require(chapter.anchor(in: NSRange(location: 3, length: 1), contextUTF16: 1))
        #expect(bounded.prefix == "")  // Do not split the preceding surrogate pair.
    }

    @Test("Offsets plus exact quote take precedence even among duplicate passages")
    func offsetValidation() throws {
        let chapter = try extract("<p>same then same</p>")
        var anchor = try #require(chapter.anchor(in: NSRange(location: 10, length: 4)))
        anchor.prefix = "stale context"
        #expect(chapter.resolve(anchor) == NSRange(location: 10, length: 4))
        anchor.quote = "gone"
        #expect(chapter.resolve(anchor) == nil)
    }

    @Test("Unique quote plus immediate context survives changed offsets")
    func contextResolution() throws {
        let chapter = try extract("<p>red same blue and green same gold</p>")
        var anchor = EpubTextAnchor(
            chapterHref: href, quote: "same", prefix: "green ", suffix: " gold",
            startUTF16: 0, endUTF16: 4)
        #expect(chapter.resolve(anchor) == NSRange(location: 24, length: 4))
        anchor.startUTF16 = nil
        anchor.endUTF16 = nil
        #expect(chapter.resolve(anchor) == NSRange(location: 24, length: 4))
        anchor.prefix = "missing "
        #expect(chapter.resolve(anchor) == nil)
    }

    @Test("Missing, ambiguous, overlapping or wrong-chapter quotes never pick a passage")
    func unresolved() throws {
        let chapter = try extract("<p>same same banana</p>")
        func resolve(_ quote: String, chapterHref: String? = nil) -> NSRange? {
            chapter.resolve(EpubTextAnchor(chapterHref: chapterHref ?? href, quote: quote, prefix: "", suffix: ""))
        }
        #expect(resolve("same") == nil)
        #expect(resolve("absent") == nil)
        #expect(resolve("") == nil)
        #expect(resolve("ana") == nil)
        #expect(resolve("banana", chapterHref: "other.xhtml") == nil)
        #expect(resolve("banana") == NSRange(location: 10, length: 6))
        let duplicateContext = try extract("<p>x same y x same y</p>")
        #expect(
            duplicateContext.resolve(EpubTextAnchor(chapterHref: href, quote: "same", prefix: "x ", suffix: " y"))
                == nil)
    }

    @Test("Resolution is Unicode literal, not canonical-equivalence or case matching")
    func literalQuotes() throws {
        let chapter = try extract("<p>e&#x301; WORD</p>")
        #expect(chapter.resolve(EpubTextAnchor(chapterHref: href, quote: "é", prefix: "", suffix: "")) == nil)
        #expect(chapter.resolve(EpubTextAnchor(chapterHref: href, quote: "word", prefix: "", suffix: "")) == nil)
    }

    @Test("Reflow and source whitespace do not change normalized text anchors")
    func reflow() throws {
        let first = try extract("<p>One\n two <em>three</em>.</p><p>Four</p>")
        let second = try extract("<div> One&nbsp;two <span>three</span>. </div>\n<div>Four</div>")
        #expect(first.text == second.text)
        let anchor = try #require(first.anchor(in: NSRange(location: 4, length: 10)))
        #expect(second.resolve(anchor) == NSRange(location: 4, length: 10))
    }

    @Test("Search normalizes query whitespace and bounds result count")
    func search() throws {
        let chapter = try extract("<p>one two one two one two</p>")
        let matches = try chapter.search(" one\u{A0}\n two ", limit: 2)
        #expect(matches.count == 2)
        #expect(matches.map(\.startUTF16) == [0, 8])
        #expect(matches.allSatisfy { chapter.resolve($0) != nil })
        #expect(try chapter.search("  ").isEmpty)
        #expect(try chapter.search("one", limit: -1).isEmpty)
        #expect(
            try extract("<p>" + String(repeating: "a ", count: 300) + "</p>").search("a", limit: Int.max).count == 200)
    }

    @Test("Internal and external entity declarations are rejected before parsing")
    func maliciousXML() throws {
        for xml in [
            "<!DOCTYPE html [<!ENTITY x SYSTEM 'file:///does-not-exist'>]><html><body>&x;</body></html>",
            "<!DOCTYPE html [<!ENTITY x 'boom'><!ENTITY y '&x;&x;'>]><html><body>&y;</body></html>",
            "<!DOCTYPE html [<!ENTITY % x SYSTEM 'https://example.invalid/evil'>%x;]><html><body/></html>",
        ] {
            for encoding in [String.Encoding.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian, .utf32] {
                let data = try #require(xml.data(using: encoding))
                #expect(throws: EpubTextError.entityDeclaration) {
                    try EpubTextExtractor.extract(xhtml: data, chapterHref: href)
                }
            }
        }
        #expect(throws: (any Error).self) { try extract("<p>unclosed") }
        #expect(throws: EpubTextError.malformedXML) {
            try EpubTextExtractor.extract(xhtml: Data("<html><head/></html>".utf8), chapterHref: href)
        }
    }

    @Test("UTF-16/32 chapters with encoding declarations normalize identically")
    func encodedXML() throws {
        for (encoding, declaration) in [
            (String.Encoding.utf16, "UTF-16"), (.utf16BigEndian, "UTF-16BE"), (.utf32, "UTF-32"),
        ] {
            let xml = "<?xml version='1.0' encoding='\(declaration)'?><html><body>A&nbsp;😀</body></html>"
            let data = try #require(xml.data(using: encoding))
            #expect(try EpubTextExtractor.extract(xhtml: data, chapterHref: href).text == "A 😀")
        }
    }

    @Test("Input bytes, normalized UTF-16, element count and depth have hard limits")
    func bounds() throws {
        #expect(throws: EpubTextError.limitExceeded("input bytes")) {
            try extract("<p>x</p>", limits: .init(maxInputBytes: 8))
        }
        #expect(throws: EpubTextError.limitExceeded("text UTF-16")) {
            try extract("<p>😀x</p>", limits: .init(maxTextUTF16: 2))
        }
        #expect(try extract("<p>😀</p>", limits: .init(maxTextUTF16: 2)).utf16Count == 2)
        #expect(throws: EpubTextError.limitExceeded("elements")) {
            try extract("<p>x</p>", limits: .init(maxElements: 2))
        }
        #expect(throws: EpubTextError.limitExceeded("depth")) {
            try extract("<p>x</p>", limits: .init(maxDepth: 2))
        }
        #expect(throws: EpubTextError.limitExceeded("invalid limits")) {
            try extract("", limits: .init(maxTextUTF16: Int.min))
        }
    }

    @MainActor @Test("Worker extraction is awaitable from the main actor and cancellation is drained")
    func worker() async throws {
        let worker = EpubTextWorker()
        let data = Data("<html><body><p>worker</p></body></html>".utf8)
        #expect(try await worker.extract(xhtml: data, chapterHref: href).text == "worker")
        let cancelled = Task {
            return try await worker.extract(xhtml: data, chapterHref: href)
        }
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Cancelled extraction unexpectedly succeeded")
        } catch is CancellationError {
        }
    }

    @Test("Archive worker reads only the requested chapter, caps inflation and preserves original bytes")
    func archiveWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("epub-text-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var zip = ZipFixture()
        zip.add(href, "<html><body><p>requested</p></body></html>")
        zip.add("other.xhtml", "not valid XML")
        let original = zip.archiveData()
        let url = directory.appendingPathComponent("book.epub")
        try original.write(to: url)
        let container = try EpubContainer(url: url)
        let worker = EpubTextWorker()
        #expect(try await worker.chapter(container: container, chapterHref: href).text == "requested")
        let hits = try await worker.search(container: container, chapterHref: href, query: "requested")
        #expect(hits.count == 1)
        let anchor = try #require(hits.first)
        #expect(try await worker.quote(container: container, anchor: anchor) == "requested")
        let missing = EpubTextAnchor(chapterHref: href, quote: "missing", prefix: "", suffix: "")
        #expect(try await worker.quote(container: container, anchor: missing) == nil)
        do {
            _ = try await worker.chapter(container: container, chapterHref: href, limits: .init(maxInputBytes: 8))
            Issue.record("Oversized chapter was not rejected")
        } catch let error as EpubError {
            #expect(error == .resourceTooLarge(href))
        }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test("Old PDF/web JSON decodes without EPUB fields and retains existing values")
    func oldJSON() throws {
        let decoder = JSONDecoder()
        let pdf = try decoder.decode(
            PositionData.self,
            from: Data(
                """
                {"rects":[{"x":1,"y":2,"width":3,"height":4}],"page_width":612,"page_height":792}
                """.utf8))
        #expect(pdf.epubAnchor == nil && pdf.rects.count == 1)
        let web = try decoder.decode(
            PositionData.self,
            from: Data(
                """
                {"rects":[],"page_width":800,"page_height":600,"selected_text":"web","start_offset":3,
                "end_offset":6,"prefix":"before","suffix":"after","viewport_offset":12}
                """.utf8))
        #expect(web.epubAnchor == nil && web.selectedText == "web" && web.startOffset == 3)
        #expect(web.prefix == "before" && web.suffix == "after" && web.viewportOffset == 12)
        let position = try decoder.decode(
            ReadingPosition.self,
            from: Data(
                """
                {"page":3,"page_count":10,"scroll_fraction":0.5,"anchor_prefix":"before","anchor_suffix":"after","viewport_offset":12}
                """.utf8))
        #expect(position.epubLocation == nil && position.page == 3 && position.scrollFraction == 0.5)
        #expect(position.anchorPrefix == "before" && position.viewportOffset == 12)
        let minimal = try decoder.decode(ReadingPosition.self, from: Data("{\"page\":1}".utf8))
        #expect(minimal == ReadingPosition(page: 1))
        #expect(!String(decoding: try JSONEncoder().encode(minimal), as: UTF8.self).contains("epub_location"))
        #expect(!String(decoding: try JSONEncoder().encode(web), as: UTF8.self).contains("epub_anchor"))
    }

    @Test("EPUB anchor/location wire keys round-trip and optional offsets can be absent")
    func newJSON() throws {
        let chapter = try extract("<p>quote</p>")
        let anchor = try #require(chapter.anchor(in: NSRange(location: 0, length: 5)))
        let location = EpubLocation(chapterHref: href, textAnchor: anchor, progression: 0.25)
        let position = ReadingPosition(page: 2, epubLocation: location)
        let data = try JSONEncoder().encode(position)
        #expect(try JSONDecoder().decode(ReadingPosition.self, from: data) == position)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let locator = try #require(json["epub_location"] as? [String: Any])
        let quote = try #require(locator["text_anchor"] as? [String: Any])
        #expect(locator["chapter_href"] as? String == href)
        #expect(quote["start_utf16"] as? Int == 0 && quote["end_utf16"] as? Int == 5)
        var annotation = PositionData(rects: [], pageWidth: 0, pageHeight: 0)
        annotation.epubAnchor = anchor
        #expect(try JSONDecoder().decode(PositionData.self, from: JSONEncoder().encode(annotation)) == annotation)
        let noOffsets = try JSONDecoder().decode(
            EpubTextAnchor.self,
            from: Data(
                """
                {"chapter_href":"OPS/text/chapter 1.xhtml","quote":"quote","prefix":"","suffix":""}
                """.utf8))
        #expect(noOffsets.startUTF16 == nil && noOffsets.endUTF16 == nil)
        #expect(chapter.resolve(noOffsets) == NSRange(location: 0, length: 5))
    }

    @MainActor @Test("Only EPUB tabs map durable locators into reading positions")
    func readingPositionMapping() {
        var tab = PdfTab(
            id: "epub",
            document: DocumentInfo(
                kind: .epub, pdfPath: "/isolated/book.epub", title: nil,
                pageCount: 5, lastPage: nil, docId: String(repeating: "a", count: 64)),
            currentPage: 2, numPages: 5, zoom: 1, visiblePages: [], webVisibleRange: nil,
            webVisibleBookmarks: [], mode: .view)
        #expect(tab.epubLocation == nil)
        tab.epubLocation = EpubLocation(chapterHref: href, progression: 0.25)
        tab.epubProgression = 0.25
        #expect(WorkspaceStore.readingPosition(for: tab).epubLocation == tab.epubLocation)
        #expect(WorkspaceStore.readingPosition(for: tab).scrollFraction == 0.25)
        for kind in [DocumentKind.pdf, .web] {
            tab.document?.kind = kind
            #expect(WorkspaceStore.readingPosition(for: tab).epubLocation == nil)
            #expect(WorkspaceStore.readingPosition(for: tab).scrollFraction == nil)
        }
    }
}
