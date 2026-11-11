#if os(macOS)
import AppKit
import Foundation
import Testing
import WebKit
@testable import Vellum

@Suite("EPUB reader integration", .serialized, .isolatedStorage, .scratchDefaults)
@MainActor
struct EpubReaderIntegrationTests {
    private let href = "OEBPS/a.html"
    private let docId = String(repeating: "ab", count: 32)

    @Test("Bridge rejects stale document/chapter/request messages and oversized or invalid ranges")
    func bridgeValidation() throws {
        let anchor = EpubTextAnchor(chapterHref: href, quote: "😀", prefix: "", suffix: "", startUTF16: 0, endUTF16: 2)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(anchor))
        var body: [String: Any] = ["type": "progress", "token": "new", "href": href, "value": 0.4, "anchor": object]
        func decode(_ token: String = "new", chapter: String? = nil) -> EpubReaderMessage? {
            EpubReaderMessage.decode(body, token: token, href: chapter ?? href, docId: docId)
        }
        #expect(decode()?.anchor == anchor)
        #expect(decode("old") == nil)
        #expect(decode(chapter: "OEBPS/b.html") == nil)
        body["value"] = -0.1; #expect(decode() == nil)
        body["value"] = Double.nan; #expect(decode() == nil)
        body["value"] = 0.4
        body["anchor"] = ["chapter_href": href, "quote": "😀", "prefix": "", "suffix": "", "start_utf16": 0, "end_utf16": 1]
        #expect(decode() == nil)
        body["anchor"] = ["chapter_href": "../wrong", "quote": "a", "prefix": "", "suffix": ""]
        #expect(decode() == nil)
        body.removeValue(forKey: "anchor"); body["id"] = String(repeating: "x", count: 257)
        #expect(decode() == nil)
        body.removeValue(forKey: "id"); body["unresolved"] = Array(repeating: "a", count: 501)
        #expect(decode() == nil)
        body.removeValue(forKey: "unresolved"); body["type"] = "eval"
        #expect(decode() == nil)
    }

    @Test("Typography and layout settings persist globally with scroll as the default")
    func settings() {
        #expect(EpubReaderSettings().layout == .scroll)
        #expect(EpubReaderSettings(fontSize: -3, lineSpacing: 9) == .init(fontSize: 12, lineSpacing: 2.4))
        #expect(EpubReaderSettings(fontSize: .nan, lineSpacing: .infinity) == .init())
        EpubReaderSettings(fontSize: 24, lineSpacing: 1.9, layout: .paged).save()
        #expect(EpubReaderSettings.load() == .init(fontSize: 24, lineSpacing: 1.9, layout: .paged))
        AppDefaults.current.set("unknown-layout", forKey: EpubReaderSettings.layoutKey)
        #expect(EpubReaderSettings.load().layout == .scroll)
        let reader = EpubReaderController()
        reader.settings.layout = .paged
        reader.changeSettings(fontSize: 26, lineSpacing: 2)
        #expect(reader.settings == .init(fontSize: 26, lineSpacing: 2, layout: .paged))
    }

    @Test("Bridge validates page progress and chapter-edge directions")
    func pagedMessageValidation() {
        func decode(_ body: [String: Any]) -> EpubReaderMessage? {
            EpubReaderMessage.decode(body, token: "current", href: href, docId: docId)
        }
        var edge: [String: Any] = ["type": "edge", "token": "current", "href": href]
        edge["step"] = -1
        #expect(decode(edge)?.step == -1)
        edge["step"] = 1
        #expect(decode(edge)?.step == 1)
        edge["step"] = 0
        #expect(decode(edge) == nil)
        edge["step"] = 2
        #expect(decode(edge) == nil)
        edge.removeValue(forKey: "step")
        #expect(decode(edge) == nil)

        var progress: [String: Any] = ["type": "progress", "token": "current", "href": href, "value": 0.5]
        progress["page"] = 0; progress["pageCount"] = 1
        #expect(decode(progress)?.page == 0)
        progress["page"] = 1; #expect(decode(progress) == nil)
        progress["page"] = -1; #expect(decode(progress) == nil)
        progress["page"] = 0; progress["pageCount"] = 0; #expect(decode(progress) == nil)
        progress["pageCount"] = 100_001; #expect(decode(progress) == nil)
        progress["page"] = 99_999; progress["pageCount"] = 100_000; #expect(decode(progress)?.pageCount == 100_000)
        progress.removeValue(forKey: "page"); #expect(decode(progress) == nil)
    }

    @Test("Only active main-frame user links leave the book, using the injected opener")
    func externalLinks() {
        var opened: [URL] = []
        var chapters: [(Int, String?)] = []
        let follow: (String, Bool, Bool, Bool?) -> Void = { address, active, source, target in
            EpubReaderLinkRouter.follow(URL(string: address), active: active,
                sourceIsMainFrame: source, targetIsMainFrame: target,
                spineIndex: { $0 == self.href ? 2 : nil },
                navigate: { chapters.append(($0, $1)) }, openExternal: { opened.append($0) })
        }
        for address in ["https://example.org/article", "http://example.org/page", "mailto:reader@example.org"] {
            follow(address, true, true, true)
        }
        follow("https://example.org/new-tab", true, true, nil)
        #expect(opened.map(\.absoluteString) == ["https://example.org/article", "http://example.org/page",
            "mailto:reader@example.org", "https://example.org/new-tab"])
        follow(EpubResourceSchemeHandler.url(for: href).absoluteString + "#section", true, true, true)
        #expect(chapters.count == 1 && chapters[0].0 == 2 && chapters[0].1 == "section")
        for address in ["https://example.org/inactive", "https://example.org/subframe", "file:///tmp/leak",
                        "javascript:alert(1)", "ftp://example.org/book", "vellum-epub://other/OEBPS/a.html"] {
            follow(address, address != "https://example.org/inactive",
                address != "https://example.org/subframe", true)
        }
        follow("https://example.org/target-subframe", true, true, false)
        follow(EpubResourceSchemeHandler.url(for: href).absoluteString, false, true, true)
        #expect(opened.count == 4 && chapters.count == 1)
    }

    @Test("Only the latest document navigation may install a bridge after a repeated chapter load")
    func navigationNonce() async throws {
        var gate = EpubReaderLoadGate()
        let first = gate.begin(path: href)
        #expect(EpubResourceSchemeHandler.archivePath(for: first.url) == href)
        #expect(gate.allows(first.url, mainFrame: true, path: href))
        #expect(!gate.allows(first.url, mainFrame: false, path: href))
        #expect(!gate.allows(URL(string: "https://example.org"), mainFrame: true, path: href))
        let second = gate.begin(path: href)
        #expect(first.url != second.url && first.id != second.id)
        #expect(!gate.allows(first.url, mainFrame: true, path: href))
        let staleFinish = gate.finish(first.id, viewURL: first.url)
        let wrongDocument = gate.finish(second.id, viewURL: first.url)
        let currentFinish = gate.finish(second.id, viewURL: second.url)
        #expect(!staleFinish && !wrongDocument && currentFinish)
        #expect(gate.isLoaded(path: href, viewURL: second.url))
        #expect(!gate.isLoaded(path: href, viewURL: first.url))
        gate.invalidate()
        #expect(!gate.isLoaded(path: href, viewURL: second.url))
        try await withDOM("<html><body><p>Book</p></body></html>", loadURL: second.url) { view in
            #expect(view.url == second.url)
            let search = try await js(view, "location.search") as? String
            #expect(search == "?vellum-load=\(second.id.uuidString)")
        }
    }

    @Test("Only the focused book handles a native chapter shortcut in a split window")
    func splitPaneShortcuts() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let left = EpubChapterWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 400), configuration: WKWebViewConfiguration())
        let right = EpubChapterWebView(frame: NSRect(x: 300, y: 0, width: 300, height: 400), configuration: WKWebViewConfiguration())
        container.addSubview(left); container.addSubview(right); window.contentView = container
        defer { left.removeKeyMonitor(); right.removeKeyMonitor(); window.contentView = nil }
        var leftSteps = 0, rightSteps = 0
        var leftPageSteps: [Int] = [], rightPageSteps: [Int] = []
        left.onChapterStep = { _ in leftSteps += 1 }; right.onChapterStep = { _ in rightSteps += 1 }
        left.onPageStep = { leftPageSteps.append($0) }; right.onPageStep = { rightPageSteps.append($0) }
        func key(_ keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [], characters: String = "") throws -> NSEvent {
            try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: keyCode))
        }
        #expect(window.makeFirstResponder(right))
        let event = try key(30, modifiers: .command, characters: "]")
        #expect(!left.handleChapterShortcut(event) && right.handleChapterShortcut(event))
        #expect(leftSteps == 0 && rightSteps == 1)
        let leftArrow = try key(123)
        #expect(!right.handleChapterShortcut(leftArrow))
        let space = try key(49, characters: " ")
        #expect(!right.handleChapterShortcut(space))
        right.paged = true
        #expect(!left.handleChapterShortcut(leftArrow) && right.handleChapterShortcut(leftArrow))
        #expect(right.handleChapterShortcut(try key(124)))
        #expect(right.handleChapterShortcut(space))
        #expect(right.handleChapterShortcut(try key(49, modifiers: .shift, characters: " ")))
        for modifiers in [NSEvent.ModifierFlags.command, .option, .control, .shift] {
            #expect(!right.handleChapterShortcut(try key(123, modifiers: modifiers)))
        }
        #expect(!right.handleChapterShortcut(try key(124, modifiers: .command)))
        #expect(rightPageSteps == [-1, 1, 1, -1] && leftPageSteps.isEmpty)
        right.readerActive = false
        #expect(!right.handleChapterShortcut(event))
        #expect(!right.handleChapterShortcut(leftArrow) && !right.handleChapterShortcut(space))
        #expect(window.makeFirstResponder(left))
        #expect(left.handleChapterShortcut(event) && !right.handleChapterShortcut(event))
        #expect(leftSteps == 1 && rightSteps == 1)
    }

    @Test("Paged trackpad and mouse-wheel deltas map to natural page directions")
    func pagedScrollWheelDirection() {
        #expect(EpubChapterWebView.pageStep(forSwipeX: -41, y: 0) == 1)
        #expect(EpubChapterWebView.pageStep(forSwipeX: 41, y: 0) == -1)
        #expect(EpubChapterWebView.pageStep(forSwipeX: -40, y: 0) == nil)
        #expect(EpubChapterWebView.pageStep(forSwipeX: -80, y: 81) == nil)
        #expect(EpubChapterWebView.pageStep(forWheelX: 0, y: -1) == 1)
        #expect(EpubChapterWebView.pageStep(forWheelX: 0, y: 1) == -1)
        #expect(EpubChapterWebView.pageStep(forWheelX: 30, y: -30) == 1)
        #expect(EpubChapterWebView.pageStep(forWheelX: 31, y: -30) == nil)
        #expect(EpubChapterWebView.pageStep(forWheelX: 0, y: 0) == nil)
    }

    @Test("Isolated DOM text/UTF16 anchors match extractor without mutating publication text")
    func domParity() async throws {
        let xhtml = """
        <html><head><title>excluded</title></head><body><article><p>Alpha&#160;&#133;&#65279;😀 é</p>
        <div>nested<p>blocks <em>and</em> text</p>tail<br/>after</div></article>
        <p hidden="hidden">HIDDEN</p><section aria-hidden="TrUe"><p>HIDDEN</p></section>
        <script>document.body.textContent='BAD'</script><style>.x{}</style>
        <template>HIDDEN</template><noscript>HIDDEN</noscript><p>repeat repeat</p></body></html>
        """
        let expected = try EpubTextExtractor.extract(xhtml: Data(xhtml.utf8), chapterHref: href)
        try await withDOM(xhtml) { view in
            let original = try await js(view, "document.body.textContent") as? String
            let text = try await js(view, "window.__vellumEpub.text()") as? String
            #expect(text == expected.text)
            let range = (expected.text as NSString).range(of: "😀 é")
            let anchor = try #require(expected.anchor(in: range))
            #expect(try await js(view, "window.__vellumEpub.resolve(\(EpubReaderJavaScript.literal(anchor)))") as? Bool == true)
            var duplicate = EpubTextAnchor(chapterHref: href, quote: "repeat", prefix: "", suffix: "")
            #expect(try await js(view, "window.__vellumEpub.resolve(\(EpubReaderJavaScript.literal(duplicate)))") as? Bool == false)
            duplicate.prefix = "repeat "; duplicate.suffix = ""
            #expect(try await js(view, "window.__vellumEpub.resolve(\(EpubReaderJavaScript.literal(duplicate)))") as? Bool == true)
            // A low-surrogate start must not be accepted, even on the offset fast path.
            var invalid = anchor; invalid.startUTF16 = range.location + 1
            invalid.quote = String(UnicodeScalar(0xFFFD)!)
            #expect(try await js(view, "window.__vellumEpub.resolve(\(EpubReaderJavaScript.literal(invalid)))") as? Bool == false)
            _ = try await js(view, "window.__vellumEpub.annotations([{id:'note',anchor:\(EpubReaderJavaScript.literal(anchor)),color:'#abcdef'}])")
            #expect(try await js(view, "document.body.textContent") as? String == original)
            // The selection offset mapper must round-trip astral and combining text.
            _ = try await js(view, """
            (()=>{const n=document.querySelector('p').firstChild,s=n.data.indexOf('😀'),r=document.createRange();
            r.setStart(n,s);r.setEnd(n,s+5);getSelection().removeAllRanges();getSelection().addRange(r);})()
            """)
            let selected = try await js(view, "JSON.stringify(window.__vellumEpub.selection())") as? String
            let decoded = try JSONDecoder().decode(EpubTextAnchor.self, from: Data(try #require(selected).utf8))
            #expect(decoded == anchor)
        }
    }

    @Test("Losing WebKit selection to the note editor does not dismiss the captured passage")
    func selectionFocusTransfer() async throws {
        let messages = DOMMessages()
        try await withDOM("<html><body><p>Passage for a note</p></body></html>", messages: messages) { view in
            _ = try await js(view, """
            (()=>{const r=document.createRange();r.selectNodeContents(document.querySelector('p'));
            getSelection().removeAllRanges();getSelection().addRange(r);
            document.dispatchEvent(new Event('selectionchange'));
            setTimeout(()=>window.webkit.messageHandlers.epubReader.postMessage({checkpoint:'selected'}),0);})()
            """)
            try await messages.wait(for: "selected")
            #expect(messages.selections.last?["anchor"] is [String: Any])
            messages.bodies.removeAll()
            _ = try await js(view, """
            getSelection().removeAllRanges();
            document.dispatchEvent(new Event('selectionchange'));
            setTimeout(()=>window.webkit.messageHandlers.epubReader.postMessage({checkpoint:'blurred'}),0);
            """)
            try await messages.wait(for: "blurred")
            #expect(messages.selections.isEmpty)
            _ = try await js(view, """
            document.dispatchEvent(new Event('pointerup'));
            window.webkit.messageHandlers.epubReader.postMessage({checkpoint:'clicked'});
            void 0;
            """)
            try await messages.wait(for: "clicked")
            #expect(messages.selections.last?["anchor"] is NSNull)
            messages.bodies.removeAll()
            _ = try await js(view, """
            document.dispatchEvent(new Event('keyup'));
            window.webkit.messageHandlers.epubReader.postMessage({checkpoint:'keyed'});
            void 0;
            """)
            try await messages.wait(for: "keyed")
            #expect(messages.selections.last?["anchor"] is NSNull)
        }
    }

    @Test("Pencil ranges produce durable quotes and handwriting markers survive reflow")
    func pencilRangeAndHandwritingMarker() async throws {
        let html = "<html><body><p>Alpha bravo charlie delta echo</p></body></html>"
        let text = try EpubTextExtractor.extract(xhtml: Data(html.utf8), chapterHref: href)
        let expected = try #require(text.anchor(in: NSRange(location: 0, length: 6)))
        let messages = DOMMessages()
        try await withDOM(html, messages: messages) { view in
            _ = try await js(view, """
            (()=>{const n=document.querySelector('p').firstChild,r=document.createRange();
            r.setStart(n,0);r.setEnd(n,1);const a=r.getBoundingClientRect();
            r.setStart(n,5);r.setEnd(n,6);const b=r.getBoundingClientRect();
            window.__vellumEpub.pencil('begin',a.left,a.top+a.height/2);
            window.__vellumEpub.pencil('end',b.right,b.top+b.height/2);
            window.webkit.messageHandlers.epubReader.postMessage({checkpoint:'pencilled'});})()
            """)
            try await messages.wait(for: "pencilled")
            let message = try #require(messages.bodies.first { $0["type"] as? String == "pencilHighlight" })
            let anchor = try #require(message["anchor"] as? [String: Any])
            let decoded = try JSONDecoder().decode(EpubTextAnchor.self,
                from: JSONSerialization.data(withJSONObject: anchor))
            #expect(decoded == expected)
            let marks = "[{id:'ink:test',anchor:\(EpubReaderJavaScript.literal(expected)),handwriting:true}]"
            _ = try await js(view, "window.__vellumEpub.annotations(\(marks))")
            #expect(try await js(view, "document.querySelector('button[aria-label=\"Open passage handwriting\"]')!==null") as? Bool == true)
            _ = try await js(view, configure(font: 30, spacing: 2.1))
            view.setFrameSize(NSSize(width: 400, height: 500))
            _ = try await js(view, """
            window.__vellumEpub.annotations(\(marks));
            document.querySelector('button[aria-label="Open passage handwriting"]').click();
            window.webkit.messageHandlers.epubReader.postMessage({checkpoint:'opened'}); void 0;
            """)
            try await messages.wait(for: "opened")
            #expect(messages.bodies.contains { $0["type"] as? String == "annotation" && $0["id"] as? String == "ink:test" })
            #expect(try await js(view, "window.__vellumEpub.text()") as? String == text.text)
        }
    }

    @Test("Quote viewport survives typography, resize and chapter reload; stale messages cannot move a new visit")
    func reflow() async throws {
        let paragraphs = (0..<100).map { "<p>Paragraph \($0) contains a unique passage for reflow with enough words to wrap across lines.</p>" }.joined()
        let html = "<html><body>\(paragraphs)</body></html>"
        let chapter = try EpubTextExtractor.extract(xhtml: Data(html.utf8), chapterHref: href)
        let anchor = try #require(chapter.anchor(in: (chapter.text as NSString).range(of: "Paragraph 60 contains a unique passage")))
        try await withDOM(html) { view in
            let location = "{anchor:\(EpubReaderJavaScript.literal(anchor)),progression:0}"
            _ = try await js(view, "window.__vellumEpub.restore(\(location))")
            let before = try await js(view, "JSON.stringify(window.__vellumEpub.snapshot())") as? String
            _ = try await js(view, configure(font: 30, spacing: 2.1))
            let after = try await js(view, "JSON.stringify(window.__vellumEpub.snapshot())") as? String
            #expect(before != nil && after != nil)
            let beforeObject = try JSONSerialization.jsonObject(with: Data(try #require(before).utf8)) as? [String: Any]
            let afterObject = try JSONSerialization.jsonObject(with: Data(try #require(after).utf8)) as? [String: Any]
            let oldQuote = (beforeObject?["anchor"] as? [String: Any])?["quote"] as? String
            let newQuote = (afterObject?["anchor"] as? [String: Any])?["quote"] as? String
            #expect(oldQuote?.contains("Paragraph 60") == true)
            #expect(newQuote?.contains("Paragraph 60") == true)
            view.setFrameSize(NSSize(width: 420, height: 480))
            _ = try await js(view, "window.__vellumEpub.restore(\(location));window.__vellumEpub.resolve(\(EpubReaderJavaScript.literal(anchor)))")
            #expect(try await js(view, "window.__vellumEpub.resolve(\(EpubReaderJavaScript.literal(anchor)))") as? Bool == true)
        }
        try await withDOM(html) { view in
            _ = try await js(view, "window.__vellumEpub.restore({anchor:\(EpubReaderJavaScript.literal(anchor)),progression:0})")
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor.quote") as? String)?.contains("Paragraph 60") == true)
        }
    }

    @Test("Paged layout reports pages and turns without moving past chapter edges")
    func pagedPagination() async throws {
        let (html, _) = try pagedFixture()
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(layout: .paged))
            let count = try await js(view, "window.__vellumEpub.pageInfo().count") as? Int ?? 0
            #expect(count > 1)
            #expect(try await js(view, "window.__vellumEpub.turn(1)") as? String == "moved")
            #expect(try await js(view, "window.__vellumEpub.pageInfo().page") as? Int == 1)
            #expect(try await js(view, "scrollX===innerWidth") as? Bool == true)
            _ = try await js(view, "window.__vellumEpub.goTo(\(count - 1))")
            #expect(try await js(view, "window.__vellumEpub.turn(1)") as? String == "edge")
            _ = try await js(view, "window.__vellumEpub.goTo(0)")
            #expect(try await js(view, "window.__vellumEpub.turn(-1)") as? String == "edge")
        }
    }

    @Test("Paged restore keeps a passage through reflow, resizing and layout changes")
    func pagedRestore() async throws {
        let (html, anchor) = try pagedFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(layout: .paged))
            _ = try await js(view, "window.__vellumEpub.restore({anchor:\(encoded),progression:0})")
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            #expect(try await js(view, rangeStartsInsideViewport("Paragraph 60 contains a unique passage")) as? Bool == true)

            _ = try await js(view, configure(font: 30, spacing: 2.1, layout: .paged))
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            #expect(try await js(view, rangeStartsInsideViewport("Paragraph 60 contains a unique passage")) as? Bool == true)

            view.setFrameSize(NSSize(width: 360, height: 480))
            _ = try await js(view, "window.dispatchEvent(new Event('resize'))")
            try await Task.sleep(for: .milliseconds(150))
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            #expect(try await js(view, rangeStartsInsideViewport("Paragraph 60 contains a unique passage")) as? Bool == true)

            _ = try await js(view, "window.__vellumEpub.restore({progression:1})")
            #expect(try await js(view, "window.__vellumEpub.pageInfo().page===window.__vellumEpub.pageInfo().count-1") as? Bool == true)
        }
    }

    @Test("Scroll and paged modes restore the same text anchor")
    func layoutSwitch() async throws {
        let (html, anchor) = try pagedFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, "window.__vellumEpub.restore({anchor:\(encoded),progression:0})")
            _ = try await js(view, configure(layout: .paged))
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            _ = try await js(view, configure(layout: .scroll))
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            let before = try await js(view, "scrollX+','+scrollY") as? String
            #expect(try await js(view, "window.__vellumEpub.turn(1)") as? String == "scroll")
            #expect(try await js(view, "scrollX+','+scrollY") as? String == before)
        }
    }

    @Test("Paged annotation marks align with the anchored passage")
    func pagedOverlay() async throws {
        let (html, anchor) = try pagedFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(layout: .paged))
            _ = try await js(view, "window.__vellumEpub.restore({anchor:\(encoded),progression:0})")
            _ = try await js(view, "window.__vellumEpub.annotations([{id:'test-mark',anchor:\(encoded),color:'#ff0000'}])")
            #expect(try await js(view, overlayAligned("Paragraph 60 contains a unique passage")) as? Bool == true)
        }
    }

    @Test("Paged annotation taps do not trigger tap-zone page turns")
    func pagedOverlayTapZone() async throws {
        let (html, anchor) = try pagedFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(layout: .paged))
            _ = try await js(view, "window.__vellumEpub.annotations([{id:'test-mark',anchor:\(encoded),color:'#ff0000'}])")
            let pages = try await js(view, """
            (() => {
              const api=window.__vellumEpub,mark=document.querySelector('button[aria-label="Open annotation"]');
              if (!mark) return 'missing';
              api.goTo(0);
              const x=innerWidth*0.9,click=()=>new MouseEvent('click',{bubbles:true,clientX:x,clientY:20});
              mark.dispatchEvent(click());
              const afterMark=api.pageInfo().page;
              document.body.dispatchEvent(click());
              return `${afterMark},${api.pageInfo().page}`;
            })()
            """) as? String
            #expect(pages == "0,1")
        }
    }

    @Test("Active owner scopes search/AI/annotations, generic jumps clear anchors, close joins cancelled work")
    func lifecycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-reader-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldDocuments = DocumentDataStore.rootDirectoryOverride, oldBooks = EpubLibrary.directoryOverride
        let oldWeb = WebLibrary.storeDirOverride
        DocumentDataStore.rootDirectoryOverride = root.appendingPathComponent("documents")
        EpubLibrary.directoryOverride = root.appendingPathComponent("Books")
        WebLibrary.storeDirOverride = root.appendingPathComponent("web")
        defer {
            DocumentDataStore.rootDirectoryOverride = oldDocuments; EpubLibrary.directoryOverride = oldBooks
            WebLibrary.storeDirOverride = oldWeb; try? FileManager.default.removeItem(at: root)
        }
        let fixture = EpubFixture.epub2()
        let file = try fixture.write(to: root.appendingPathComponent("book.epub"))
        let manager = DocumentSessionManager()
        let positions = DocumentPositionService(storage: InMemoryPositionStorage())
        let workspace = WorkspaceStore(sessions: manager, positions: positions)
        let pane = workspace.focusedPane.app
        let ai = AiStore(settings: AiSettings()); ai.app = pane
        let notes = AnnotationStore(app: pane)
        let scratchpad = ScratchpadStore()
        await pane.openFile(path: file.path)
        let binding = try #require(pane.activeDocumentBinding)
        let session = try #require(manager.documentSession(sessionId: binding.tabId) as? EpubDocumentSession)
        let reader = EpubReaderController()
        reader.bind(app: pane, ai: ai, annotations: notes, scratchpad: scratchpad, session: session, tabId: binding.tabId)
        reader.activate(true); await reader.drain()
        #expect(reader.isCurrent && pane.epubHandlerOwner == binding)
        reader.settings.layout = .paged
        let firstHref = session.publication.spine[0].path
        let secondHref = session.publication.spine[1].path
        let firstToken = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "edge", token: firstToken, href: firstHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: -1))
        #expect(reader.location?.chapter == 0)
        reader.receive(EpubReaderMessage(type: "edge", token: firstToken, href: firstHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: 1))
        #expect(reader.location?.chapter == 1 && reader.location?.progression == 0)
        let secondToken = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "edge", token: firstToken, href: firstHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: -1))
        #expect(reader.location?.chapter == 1)
        reader.receive(EpubReaderMessage(type: "edge", token: secondToken, href: secondHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: -1))
        #expect(reader.location?.chapter == 0 && reader.location?.progression == 1)
        let resumedToken = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "edge", token: resumedToken, href: firstHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: -1))
        #expect(reader.location?.chapter == 0 && reader.location?.progression == 1)
        reader.receive(EpubReaderMessage(type: "edge", token: resumedToken, href: firstHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: 1))
        let lastToken = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "edge", token: lastToken, href: secondHref,
            value: nil, anchor: nil, id: nil, unresolved: nil, step: 1))
        #expect(reader.location?.chapter == 1)
        reader.go(chapter: 0)
        let pageToken = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "progress", token: pageToken, href: firstHref,
            value: 0.5, anchor: nil, id: nil, unresolved: nil, page: 2, pageCount: 4))
        #expect(reader.page == EpubReaderPage(index: 2, count: 4))
        reader.settings.layout = .scroll
        #expect(reader.page == nil)
        reader.settings.layout = .paged
        let chapter = try await session.chapterText(spineIndex: 0)
        let anchor = try #require(chapter.anchor(in: NSRange(location: 0, length: 5)))
        reader.go(chapter: 0, anchor: anchor)
        #expect(pane.tab(id: binding.tabId)?.epubLocation?.textAnchor == anchor)
        let request = try #require(reader.location?.request.uuidString)
        await ai.loadConversationForDocument(pane.document)
        await scratchpad.loadForDocument(pane.document).value
        reader.receive(EpubReaderMessage(type: "selection", token: request, href: anchor.chapterHref, value: nil, anchor: anchor, id: nil, unresolved: nil))
        reader.askAI(); await reader.drain()
        #expect(ai.composerReferences.last?.epubCitation?.anchor == anchor)
        reader.receive(EpubReaderMessage(type: "selection", token: request, href: anchor.chapterHref, value: nil, anchor: anchor, id: nil, unresolved: nil))
        reader.quoteToScratchpad()
        #expect(scratchpad.text.contains("> \(anchor.quote)"))
        reader.receive(EpubReaderMessage(type: "selection", token: request, href: anchor.chapterHref, value: nil, anchor: anchor, id: nil, unresolved: nil))
        reader.beginSelectionNote()
        reader.updateSelectionNoteDraft("draft", anchor: anchor)
        reader.receive(EpubReaderMessage(type: "selection", token: request, href: anchor.chapterHref, value: nil, anchor: nil, id: nil, unresolved: nil))
        #expect(reader.selectedAnchor == anchor && reader.selectionNoteDraft?.text == "draft")
        reader.deactivate()
        reader.activate(true)
        #expect(reader.selectedAnchor == anchor && reader.selectionNoteDraft?.text == "draft")
        let otherSelection = try #require(chapter.anchor(in: NSRange(location: 1, length: 1)))
        reader.receive(EpubReaderMessage(type: "selection", token: request, href: anchor.chapterHref, value: nil, anchor: otherSelection, id: nil, unresolved: nil))
        #expect(reader.selectedAnchor == otherSelection && reader.selectionNoteDraft == nil)
        reader.go(chapter: 1)
        #expect(reader.selectedAnchor == nil && reader.selectionNoteDraft == nil)
        let otherChapter = try await session.chapterText(spineIndex: 1)
        let otherAnchor = try #require(otherChapter.anchor(in: NSRange(location: 0, length: 1)))
        let otherRequest = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "selection", token: otherRequest, href: otherAnchor.chapterHref, value: nil, anchor: otherAnchor, id: nil, unresolved: nil))
        reader.annotate(type: .highlight, color: "yellow"); await reader.drain()
        let otherHighlight = try #require(notes.annotations.first)
        #expect(otherHighlight.pageNumber == 2 && otherHighlight.positionData?.epubAnchor == otherAnchor)
        await notes.deleteAnnotation(id: otherHighlight.id)
        reader.go(chapter: 0)
        let resumedRequest = try #require(reader.location?.request.uuidString)
        reader.receive(EpubReaderMessage(type: "selection", token: resumedRequest, href: anchor.chapterHref, value: nil, anchor: anchor, id: nil, unresolved: nil))
        #expect(reader.selectedAnchor == anchor && reader.selectionNoteDraft?.text == "draft")
        reader.annotate(type: .note, note: "draft"); await reader.drain()
        #expect(reader.selectionNoteDraft == nil && reader.selectedAnchor == nil)
        #expect(notes.annotations.first?.positionData?.epubAnchor == anchor)
        let note = try #require(notes.annotations.first)
        #expect(await notes.updateAnnotation(UpdateAnnotationInput(id: note.id, content: "edited")))
        pane.performFind("Text"); await reader.drain()
        #expect(pane.findMatchCount == 2 && !pane.findTruncated)
        pane.performFind("A"); pane.performFind("no such text"); await reader.drain()
        #expect(pane.findMatchCount == 0 && !pane.findIsSearching)
        reader.receive(EpubReaderMessage(type: "progress", token: request, href: anchor.chapterHref, value: 0.9, anchor: anchor, id: nil, unresolved: nil))
        #expect(pane.tab(id: binding.tabId)?.epubProgression != 0.9)
        pane.goToPage(2)
        #expect(reader.location?.chapter == 1)
        #expect(pane.tab(id: binding.tabId)?.epubLocation?.textAnchor == nil)
        reader.receive(EpubReaderMessage(type: "selection", token: request, href: anchor.chapterHref, value: nil, anchor: anchor, id: nil, unresolved: nil))
        #expect(reader.selection == nil)
        let handler = try #require(pane.scrollToPageHandler)
        reader.deactivate()
        #expect(pane.epubHandlerOwner == nil && ai.ensureExtractedHandler == nil)
        handler(1); #expect(reader.location?.chapter == 1)
        reader.activate(true)
        let replacement = EpubReaderController()
        replacement.bind(app: pane, ai: ai, annotations: notes, scratchpad: scratchpad, session: session, tabId: binding.tabId)
        replacement.activate(true); await reader.close(); await replacement.drain()
        #expect(replacement.isCurrent && ai.ensureExtractedHandler != nil && pane.scrollToPageHandler != nil)
        let chapterB = try await session.chapterText(spineIndex: 1)
        let anchorB = try #require(chapterB.anchor(in: NSRange(location: 0, length: 1)))
        replacement.go(chapter: 1, anchor: anchorB)
        let latest = try #require(replacement.location?.request.uuidString)
        replacement.receive(EpubReaderMessage(type: "progress", token: latest, href: anchorB.chapterHref, value: 0.64, anchor: anchorB, id: nil, unresolved: nil))
        var drained = false
        replacement.run { do { try await Task.sleep(for: .seconds(60)) } catch {} ; drained = true }
        await Task.yield()
        await pane.closeFile(); await pane.awaitPendingTabTeardowns()
        #expect(drained && !replacement.active)
        await positions.flush()
        let saved = await positions.resumePosition(for: session.info)
        #expect(saved?.epubLocation?.textAnchor == anchorB && saved?.scrollFraction == 0.64)
        await pane.openFile(path: file.path)
        let reopened = try #require(pane.activeDocumentBinding)
        #expect(pane.tab(id: reopened.tabId)?.epubLocation?.textAnchor == anchorB)
        let reopenedSession = try #require(manager.documentSession(sessionId: reopened.tabId) as? EpubDocumentSession)
        #expect(try await reopenedSession.annotations(pageNumber: nil).first?.content == "edited")
        pane.routeEpubCitation(AiEpubCitation(docId: try #require(reopened.docId), chapterNumber: 1,
            chapterHref: anchor.chapterHref, anchor: anchor))
        await pane.flushPendingPositionRecords()
        #expect(pane.takePendingEpubCitation(binding: reopened)?.anchor == anchor)
        await notes.loadAnnotations()
        await notes.deleteAnnotation(id: note.id)
        #expect(try await reopenedSession.annotations(pageNumber: nil).isEmpty)
        await pane.closeFile(); await pane.awaitPendingTabTeardowns()
        await workspace.awaitMaintenance()
        await AiPersistence.awaitPendingFlush(); await ScratchpadPersistence.awaitPendingFlush()
    }

    private func pagedFixture() throws -> (html: String, anchor: EpubTextAnchor) {
        let quote = "Paragraph 60 contains a unique passage"
        let paragraphs = (0..<100).map {
            "<p>Paragraph \($0) contains a unique passage for paged layout with enough words to wrap across lines.</p>"
        }.joined()
        let html = "<html><body>\(paragraphs)</body></html>"
        let chapter = try EpubTextExtractor.extract(xhtml: Data(html.utf8), chapterHref: href)
        let anchor = try #require(chapter.anchor(in: (chapter.text as NSString).range(of: quote)))
        return (html, anchor)
    }

    private func rangeStartsInsideViewport(_ quote: String) -> String {
        let literal = EpubReaderJavaScript.literal(quote)
        return """
        (()=>{const q=\(literal),node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
          .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!node)return false;
          const start=node.data.indexOf(q),r=document.createRange();r.setStart(node,start);r.setEnd(node,start+q.length);
          const rect=r.getClientRects()[0];return !!rect&&rect.left>=0&&rect.left<innerWidth;})()
        """
    }

    private func overlayAligned(_ quote: String) -> String {
        let literal = EpubReaderJavaScript.literal(quote)
        return """
        (()=>{const mark=document.querySelector('button[aria-label="Open annotation"]');
          const q=\(literal),node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
            .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!mark||!node)return false;
          const start=node.data.indexOf(q),r=document.createRange();r.setStart(node,start);r.setEnd(node,start+q.length);
          const textRect=r.getClientRects()[0],markRect=mark.getBoundingClientRect();
          return !!textRect&&Math.abs(markRect.left-textRect.left)<=2&&Math.abs(markRect.top-textRect.top)<=2;})()
        """
    }

    private func configure(font: Double = 18, spacing: Double = 1.6, layout: EpubReaderLayout = .scroll) -> String {
        "window.__vellumEpub.configure({token:'test',href:'\(href)',active:true,dark:false,settings:{fontSize:\(font),lineSpacing:\(spacing),layout:'\(layout.rawValue)'},colors:{well:'rgb(245, 245, 245)',surface:'rgb(255, 255, 255)',foreground:'rgb(30, 30, 30)',primary:'rgb(0, 90, 200)',border:'rgb(220, 220, 220)'}})"
    }

    private func js(_ view: WKWebView, _ code: String) async throws -> Any? {
        let result: ScriptValue = try await withCheckedThrowingContinuation { continuation in
            view.evaluateJavaScript(code, in: nil, in: .defaultClient) { result in
                continuation.resume(with: result.map { ScriptValue(value: $0) })
            }
        }
        return result.value
    }

    private func withDOM(_ html: String, loadURL: URL? = nil, messages: DOMMessages? = nil,
                         size: NSSize = NSSize(width: 700, height: 480),
                         body: (WKWebView) async throws -> Void) async throws {
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let namespaced = html.replacingOccurrences(of: "<html>", with: "<html xmlns=\"http://www.w3.org/1999/xhtml\">")
        config.setURLSchemeHandler(DOMDocument(data: Data(namespaced.utf8)), forURLScheme: EpubResourceSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: EpubReaderJavaScript.source,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        if let messages { config.userContentController.add(messages, contentWorld: .defaultClient, name: "epubReader") }
        let view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: config)
        let load = DOMLoad(); view.navigationDelegate = load
        defer {
            view.stopLoading(); view.navigationDelegate = nil
            view.configuration.userContentController.removeAllUserScripts()
            view.configuration.userContentController.removeAllScriptMessageHandlers()
        }
        view.load(URLRequest(url: loadURL ?? EpubResourceSchemeHandler.url(for: href)))
        try await load.wait()
        _ = try await js(view, configure())
        try await body(view)
    }
}

private struct ScriptValue: @unchecked Sendable { let value: Any? }

@MainActor private final class DOMMessages: NSObject, WKScriptMessageHandler {
    var bodies: [[String: Any]] = []
    var selections: [[String: Any]] { bodies.filter { $0["type"] as? String == "selection" } }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let body = message.body as? [String: Any] { bodies.append(body) }
    }

    func wait(for checkpoint: String) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !bodies.contains(where: { $0["checkpoint"] as? String == checkpoint }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(bodies.contains { $0["checkpoint"] as? String == checkpoint })
    }
}

@MainActor private final class DOMDocument: NSObject, WKURLSchemeHandler {
    let data: Data
    init(data: Data) { self.data = data }
    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/xhtml+xml; charset=utf-8",
                "Content-Security-Policy": EpubResourceSchemeHandler.contentSecurityPolicy]) else { return }
        task.didReceive(response); task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

@MainActor private final class DOMLoad: NSObject, WKNavigationDelegate {
    private var complete = false
    private var error: Error?
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { complete = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error; complete = true
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.error = error; complete = true
    }
    func wait() async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !complete && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        if let error { throw error }
        #expect(complete, "Headless WebKit load timed out")
    }
}
#endif
