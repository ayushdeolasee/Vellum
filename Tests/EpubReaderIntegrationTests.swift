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

    @Test("Large-font paged chapters have no blank trailing page")
    func pagedLastContentPage() async throws {
        let (html, _) = try resizeFixture()
        try await withDOM(html, size: NSSize(width: 420, height: 540)) { view in
            _ = try await js(view, configure(font: 36, spacing: 2.4, layout: .paged))
            @MainActor
            func measure(_ view: WKWebView) async throws -> (
                reportedCount: Int, contentCount: Int, page: Int, lastPage: Int, tailVisible: Bool,
                edge: String, scrollWithinCount: Bool
            ) {
                let state = try await js(view, """
                (()=>{const api=window.__vellumEpub,range=document.createRange();range.selectNodeContents(document.body);
                  const rects=Array.from(range.getClientRects()).filter(rect=>rect.width>0&&rect.height>0);
                  const right=rects.reduce((value,rect)=>Math.max(value,rect.right+scrollX),0);
                  const contentCount=Math.max(1,Math.ceil(right/innerWidth)),lastPage=contentCount-1;
                  const scrollWithinCount=scrollX<contentCount*innerWidth;
                  api.goTo(lastPage);
                  const page=api.pageInfo();
                  const tailRange=document.createRange();tailRange.selectNodeContents(document.querySelector('p:last-child'));
                  const tail=Array.from(tailRange.getClientRects()).filter(rect=>rect.width>0&&rect.height>0)
                    .reduce((last,rect)=>!last||rect.right>last.right?rect:last,null);
                  const edge=api.turn(1);
                  return JSON.stringify({contentCount,reportedCount:page.count,page:page.page,lastPage,
                    tailVisible:!!tail&&tail.left>=0&&tail.right<=innerWidth,edge,scrollWithinCount});
                })()
                """) as? String
                let value = try #require(state)
                let data = try #require(value.data(using: .utf8))
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                return (
                    try #require(object["reportedCount"] as? Int),
                    try #require(object["contentCount"] as? Int),
                    try #require(object["page"] as? Int),
                    try #require(object["lastPage"] as? Int),
                    try #require(object["tailVisible"] as? Bool),
                    try #require(object["edge"] as? String),
                    try #require(object["scrollWithinCount"] as? Bool)
                )
            }

            view.setFrameSize(NSSize(width: 360, height: 460))
            _ = try await js(view, "window.dispatchEvent(new Event('resize'))")
            try await Task.sleep(for: .milliseconds(400))
            let narrow = try await measure(view)
            #expect(narrow.reportedCount == narrow.contentCount)
            #expect(narrow.page == narrow.lastPage)
            #expect(narrow.tailVisible)
            #expect(narrow.edge == "edge")
            #expect(narrow.scrollWithinCount)

            try await Task.sleep(for: .milliseconds(250))
            view.setFrameSize(NSSize(width: 420, height: 540))
            _ = try await js(view, "window.dispatchEvent(new Event('resize'))")
            try await Task.sleep(for: .milliseconds(400))
            let wide = try await measure(view)
            #expect(wide.reportedCount == wide.contentCount)
            #expect(wide.page == wide.lastPage)
            #expect(wide.tailVisible)
            #expect(wide.edge == "edge")
            #expect(wide.scrollWithinCount)
        }
    }

    @Test("Paged page count includes a trailing rendered image")
    func pagedTrailingImage() async throws {
        let continuation = "Words fill the final page before the image. "
        let paragraphs = (0..<100).map {
            "<p>Paragraph \($0). \(String(repeating: continuation, count: 5))</p>"
        }.joined()
        let image = """
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="300" style="break-before:column">
          <rect width="320" height="300" fill="blue"/>
        </svg>
        """
        try await withDOM("<html><body>\(paragraphs)\(image)</body></html>",
            size: NSSize(width: 420, height: 540)) { view in
            _ = try await js(view, configure(font: 36, spacing: 2.4, layout: .paged))
            let result = try await js(view, """
            (()=>{const api=window.__vellumEpub,image=document.querySelector('svg');
              const rects=Array.from(image.getClientRects()).filter(rect=>rect.width>0&&rect.height>0);
              const right=rects.reduce((value,rect)=>Math.max(value,rect.right+scrollX),0);
              const expected=Math.max(1,Math.ceil(right/innerWidth)),info=api.pageInfo();
              api.goTo(info.count-1);
              const rect=image.getBoundingClientRect(),imagePage=Math.floor((scrollX+rect.left)/innerWidth);
              return `${info.count},${expected},${imagePage},${api.turn(1)}`;
            })()
            """) as? String
            let values = try #require(result).split(separator: ",")
            let count = try #require(Int(values[0]))
            let expected = try #require(Int(values[1]))
            let imagePage = try #require(Int(values[2]))
            #expect(values.count == 4)
            #expect(count > 1)
            #expect(count == expected)
            #expect(imagePage == count - 1)
            #expect(values[3] == "edge")
        }
    }

    @Test("Paged page count includes a trailing background image block")
    func pagedTrailingBackgroundImage() async throws {
        let continuation = "Words fill the final page before the illustration. "
        let paragraphs = (0..<80).map {
            "<p>Paragraph \($0). \(String(repeating: continuation, count: 5))</p>"
        }.joined()
        let illustration = """
        <div id="end-illustration" style="break-before:column;height:60vh;background-image:url('data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%20120%20120%22%3E%3Crect%20width=%22120%22%20height=%22120%22%20fill=%22red%22/%3E%3C/svg%3E');background-size:cover"></div>
        """
        try await withDOM("<html><body>\(paragraphs)\(illustration)</body></html>",
            size: NSSize(width: 360, height: 460)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .paged))
            let result = try await js(view, """
            (()=>{const api=window.__vellumEpub,illustration=document.getElementById('end-illustration');
              const initial=api.pageInfo(),rect=illustration.getBoundingClientRect();
              const expected=Math.max(1,Math.ceil((scrollX+rect.right)/innerWidth));
              const illustrationPage=Math.floor((scrollX+rect.left)/innerWidth);
              let reached=false;
              for(let turn=0;turn<initial.count;turn++){
                if(api.pageInfo().page===illustrationPage){reached=true;break;}
                if(api.turn(1)!=='moved')break;
              }
              const page=api.pageInfo(),visibleRect=illustration.getBoundingClientRect();
              const visible=visibleRect.width>0&&visibleRect.height>0&&visibleRect.left<innerWidth&&visibleRect.right>0;
              const hasBackground=getComputedStyle(illustration).backgroundImage!=='none';
              const edge=api.turn(1);
              return [initial.count,expected,illustrationPage,page.page,reached,visible,hasBackground,edge].join('|');
            })()
            """) as? String
            let values = try #require(result).split(separator: "|")
            let count = try #require(Int(values[0]))
            let expected = try #require(Int(values[1]))
            let illustrationPage = try #require(Int(values[2]))
            #expect(values.count == 8)
            #expect(count == expected && count > 1)
            #expect(illustrationPage == count - 1)
            #expect(Int(values[3]) == illustrationPage && values[4] == "true")
            #expect(values[5] == "true" && values[6] == "true")
            #expect(values[7] == "edge")
        }
    }

    @Test("Fixed background elements do not limit the paged chapter count")
    func pagedFixedBackgroundDoesNotLimitPageCount() async throws {
        let continuation = "Paragraph text continues across the paged chapter. "
        let paragraphs = (0..<80).map {
            "<p>Paragraph \($0). \(String(repeating: continuation, count: 5))</p>"
        }.joined()
        let illustration = """
        <div id="fixed-illustration" style="position:fixed;right:0;bottom:0;width:100vw;height:60vh;background-image:url('data:image/svg+xml,%3Csvg%20xmlns=%22http://www.w3.org/2000/svg%22%20viewBox=%220%200%20120%20120%22%3E%3Crect%20width=%22120%22%20height=%22120%22%20fill=%22red%22/%3E%3C/svg%3E');background-size:cover"></div>
        """
        try await withDOM("<html><body>\(paragraphs)\(illustration)</body></html>",
            size: NSSize(width: 360, height: 460)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .paged))
            let result = try await js(view, """
            (()=>{const api=window.__vellumEpub,fixed=document.getElementById('fixed-illustration');
              const range=document.createRange();
              range.selectNodeContents(document.querySelector('p:last-of-type'));
              const right=Array.from(range.getClientRects()).reduce((value,rect)=>
                rect.width>0&&rect.height>0?Math.max(value,rect.right+scrollX):value,0);
              const textCount=Math.max(1,Math.ceil(right/innerWidth)),initial=api.pageInfo();
              const turn=api.turn(1),after=api.pageInfo();
              return [initial.count,textCount,turn,after.page,getComputedStyle(fixed).position,
                getComputedStyle(fixed).backgroundImage!=='none'].join('|');
            })()
            """) as? String
            let values = try #require(result).split(separator: "|")
            let count = try #require(Int(values[0]))
            let textCount = try #require(Int(values[1]))
            #expect(values.count == 6)
            #expect(textCount > 1 && count == textCount)
            #expect(values[2] == "moved" && Int(values[3]) == 1)
            #expect(values[4] == "fixed" && values[5] == "true")
        }
    }

    @Test("RTL EPUB text progresses through paged columns without skipping content")
    func rtlPagedPagination() async throws {
        let paragraphs = (0..<80).map {
            "<p>فقرة \($0) تحتوي على كلمات كافية لاختبار اتجاه النص وانتقال الصفحات في الكتاب الإلكتروني.</p>"
        }.joined()
        let html = "<html xmlns=\"http://www.w3.org/1999/xhtml\" dir=\"rtl\"><body>\(paragraphs)</body></html>"
        try await withDOM(html, size: NSSize(width: 360, height: 460)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .paged))
            let result = try await js(view, """
            (()=>{const api=window.__vellumEpub,initial=api.pageInfo(),count=initial.count;
              let moved=0;
              for(let page=1;page<count;page++){
                if(api.turn(1)!=='moved'||api.pageInfo().page!==page)break;
                moved++;
              }
              const last=api.pageInfo(),range=document.createRange();
              range.selectNodeContents(document.querySelector('p:last-child'));
              const lastVisible=Array.from(range.getClientRects()).some(rect=>
                rect.width>0&&rect.height>0&&rect.left>=0&&rect.left<innerWidth&&rect.top<innerHeight&&rect.bottom>0);
              const edge=api.turn(1),pagedRoot=getComputedStyle(document.documentElement).direction;
              const pagedBody=getComputedStyle(document.body).direction;
              return [count,initial.page,last.page,moved,lastVisible,edge,pagedRoot,pagedBody].join('|');
            })()
            """) as? String
            let values = try #require(result).split(separator: "|")
            let count = try #require(Int(values[0]))
            #expect(values.count == 8)
            #expect(count > 1 && Int(values[1]) == 0)
            #expect(Int(values[2]) == count - 1 && Int(values[3]) == count - 1)
            #expect(values[4] == "true" && values[5] == "edge")
            #expect(values[6] == "ltr" && values[7] == "rtl")

            _ = try await js(view, configure(layout: .scroll))
            let scrollDirections = try await js(view,
                "getComputedStyle(document.documentElement).direction+'|'+(document.body.style.direction||'empty')") as? String
            #expect(scrollDirections == "rtl|empty")
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

    @Test("A fresh paged chapter opens on its initial deep fragment")
    func initialPagedFragmentRestore() async throws {
        let (book, _) = try resizeFixture()
        let html = book.replacingOccurrences(of: "<p>Paragraph 60 contains a unique passage.",
            with: "<h2 id=\"old-bridge\">Old Bridge checkpoint</h2><p>Paragraph 60 contains a unique passage.")
        try await withDOM(html, size: NSSize(width: 420, height: 480), configureBeforeBody: false) { view in
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentView = nil }
            let location = "{anchor:null,progression:0,fragment:'old-bridge'}"
            let fragmentIsVisible = """
            (()=>{const target=document.getElementById('old-bridge'),rect=target.getBoundingClientRect();
              const info=window.__vellumEpub.pageInfo();
              return document.documentElement.hasAttribute('data-vellum-paged') &&
                rect.left>=0&&rect.left<innerWidth&&info.page===Math.floor((scrollX+rect.left)/innerWidth);})()
            """
            _ = try await js(view, "\(configure(font: 28, spacing: 2.4, layout: .paged));window.setTimeout(()=>document.body.style.setProperty('font-size','40px','important'),0);window.__vellumEpub.restore(\(location))")
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await js(view, fragmentIsVisible) as? Bool == false)
            _ = try await js(view, "window.__vellumEpub.restoreAfterLayout(\(location))")
            try await Task.sleep(for: .milliseconds(250))
            #expect(try await js(view, fragmentIsVisible) as? Bool == true)
        }
    }

    @Test("A fresh chapter restores its initial search anchor in either layout")
    func initialAnchorRestore() async throws {
        let (html, anchor) = try resizeFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        for layout in [EpubReaderLayout.scroll, .paged] {
            try await withDOM(html, size: NSSize(width: 420, height: 480), configureBeforeBody: false) { view in
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
                window.alphaValue = 0
                window.ignoresMouseEvents = true
                window.contentView = view
                window.orderFrontRegardless()
                defer { window.orderOut(nil); window.contentView = nil }
                _ = try await js(view, "\(configure(font: 28, spacing: 2.4, layout: layout));window.setTimeout(()=>document.body.style.setProperty('font-size','40px','important'),0);window.__vellumEpub.restoreAfterLayout({anchor:\(encoded),progression:0})")
                try await Task.sleep(for: .milliseconds(400))
                #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
                let range = layout == .paged
                    ? rangeStartsInsideViewport("Paragraph 60 contains a unique passage")
                    : rangeWithinViewport("Paragraph 60 contains a unique passage")
                #expect(try await js(view, range) as? Bool == true)
            }
        }
    }

    @Test("Cross-chapter Find restores its target through the surface coordinator in both layouts")
    func coordinatedCrossChapterFindRestore() async throws {
        struct RestoreTarget: Encodable {
            let anchor: EpubTextAnchor?
            let progression: Double
            let fragment: String?
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-coordinator-find-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldDocuments = DocumentDataStore.rootDirectoryOverride, oldBooks = EpubLibrary.directoryOverride
        let oldWeb = WebLibrary.storeDirOverride
        DocumentDataStore.rootDirectoryOverride = root.appendingPathComponent("documents")
        EpubLibrary.directoryOverride = root.appendingPathComponent("Books")
        WebLibrary.storeDirOverride = root.appendingPathComponent("web")
        defer {
            DocumentDataStore.rootDirectoryOverride = oldDocuments
            EpubLibrary.directoryOverride = oldBooks
            WebLibrary.storeDirOverride = oldWeb
            try? FileManager.default.removeItem(at: root)
        }

        var fixture = EpubFixture.epub2()
        fixture.items.removeAll { $0.path == "OEBPS/a.html" || $0.path == "OEBPS/b.html" }
        fixture.add("OEBPS/a.html", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>First chapter</h1>
            <p>needle first result.</p></body></html>
            """)
        let paragraphs = (0..<80).map {
            "<p>Paragraph \($0) fills the chapter before the requested cross-chapter search result.</p>"
        }.joined()
        fixture.add("OEBPS/b.html", """
            <html xmlns="http://www.w3.org/1999/xhtml"><body><h1>Second chapter</h1>
            \(paragraphs)<p>needle target passage.</p></body></html>
            """)
        let file = try fixture.write(to: root.appendingPathComponent("book.epub"))
        let manager = DocumentSessionManager()
        let workspace = WorkspaceStore(sessions: manager,
            positions: DocumentPositionService(storage: InMemoryPositionStorage()))
        let app = workspace.focusedPane.app
        let ai = AiStore(settings: AiSettings()); ai.app = app
        let annotations = AnnotationStore(app: app)
        let scratchpad = ScratchpadStore()
        await app.openFile(path: file.path)
        let binding = try #require(app.activeDocumentBinding)
        let session = try #require(manager.documentSession(sessionId: binding.tabId) as? EpubDocumentSession)

        for layout in [EpubReaderLayout.scroll, .paged] {
            let reader = EpubReaderController()
            reader.bind(app: app, ai: ai, annotations: annotations, scratchpad: scratchpad,
                session: session, tabId: binding.tabId)
            reader.settings.layout = layout
            reader.activate(true)
            await reader.drain()
            reader.go(chapter: 0)
            let initialLocation = try #require(reader.location)

            let coordinator = EpubReaderSurface.Coordinator(session: session)
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            configuration.defaultWebpagePreferences.allowsContentJavaScript = false
            configuration.setURLSchemeHandler(coordinator.resources, forURLScheme: EpubResourceSchemeHandler.scheme)
            configuration.userContentController.addUserScript(WKUserScript(
                source: EpubReaderJavaScript.source, injectionTime: .atDocumentEnd,
                forMainFrameOnly: true, in: .defaultClient))
            configuration.userContentController.add(coordinator, contentWorld: .defaultClient, name: "epubReader")
            let view = EpubChapterWebView(frame: NSRect(x: 0, y: 0, width: 420, height: 480),
                configuration: configuration)
            view.navigationDelegate = coordinator
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderFrontRegardless()
            var surface = EpubReaderSurface(reader: reader, session: session, location: initialLocation,
                settings: reader.settings, annotations: annotations.annotations, dark: false, palette: .light)
            coordinator.parent = surface
            coordinator.show(in: view)
            try await waitForBridge(view, path: "OEBPS/a.html")

            app.performFind("")
            app.performFind("needle")
            await reader.drain()
            #expect(reader.searchResults.count == 2)
            #expect(app.findCurrentMatch == 1)
            app.findNext()
            let requested = try #require(reader.location)
            #expect(requested.chapter == 1 && requested.anchor?.quote == "needle")
            surface = EpubReaderSurface(reader: reader, session: session, location: requested,
                settings: reader.settings, annotations: annotations.annotations, dark: false, palette: .light)
            coordinator.parent = surface
            coordinator.show(in: view)
            try await waitForBridge(view, path: "OEBPS/b.html")
            try await Task.sleep(for: .milliseconds(200))
            let target = EpubReaderJavaScript.literal(RestoreTarget(anchor: requested.anchor,
                progression: requested.progression, fragment: requested.fragment))
            _ = try await js(view, """
                window.__vellumEpub.restore({progression:0});
                window.__vellumEpub.restoreAfterLayout(\(target));
                document.dispatchEvent(new Event('load'));
                """)
            try await Task.sleep(for: .milliseconds(400))

            let targetRange = layout == .paged
                ? pagedRangeVisibleOnCurrentPage("needle target passage")
                : rangeWithinViewport("needle target passage")
            #expect(app.findCurrentMatch == 2)
            #expect(try await js(view, targetRange) as? Bool == true)

            view.stopLoading()
            coordinator.invalidateLoad()
            coordinator.resources.cancelAll()
            await coordinator.resources.drain()
            view.navigationDelegate = nil
            view.configuration.userContentController.removeAllScriptMessageHandlers()
            window.orderOut(nil)
            window.contentView = nil
            _ = await reader.close()
        }
        await app.closeFile()
        await app.awaitPendingTabTeardowns()
        await workspace.awaitMaintenance()
    }

    @Test("Paged resize bursts keep the original passage on the current page")
    func pagedResizeBurst() async throws {
        let (html, anchor) = try resizeFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .paged))
            _ = try await js(view, "window.__vellumEpub.restore({anchor:\(encoded),progression:0})")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentView = nil }
            try await resizeBurst(view, in: window)
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            #expect(try await js(view, rangeStartsInsideViewport("Paragraph 60 contains a unique passage")) as? Bool == true)
        }
    }

    @Test("Paged note selection remains anchored through a collapsed resize and paints only its quote")
    func pagedNoteSelectionResize() async throws {
        let (html, _) = try resizeFixture()
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .paged))
            _ = try await js(view, "window.__vellumEpub.restore({progression:0})")
            _ = try await js(view, """
            (()=>{const q='Paragraph 60 contains a unique passage';
              const node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
                .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!node)return false;
              const start=node.data.indexOf(q),r=document.createRange();r.setStart(node,start);r.setEnd(node,start+q.length);
              const rect=r.getBoundingClientRect();window.__vellumEpub.goTo(Math.floor((scrollX+rect.left)/innerWidth));})()
            """)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentView = nil }
            #expect(try await js(view, pagedRangeVisibleOnCurrentPage("Paragraph 60 contains a unique passage")) as? Bool == true)

            let captured = try await js(view, """
            (()=>{const q='Paragraph 60 contains a unique passage';
              const node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
                .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!node)return false;
              const start=node.data.indexOf(q),range=document.createRange();range.setStart(node,start);range.setEnd(node,start+q.length);
              const selection=window.getSelection();selection.removeAllRanges();selection.addRange(range);
              document.dispatchEvent(new Event('selectionchange'));
              window.__testNoteAnchor=window.__vellumEpub.selection();
              selection.removeAllRanges();document.dispatchEvent(new Event('selectionchange'));
              return window.__testNoteAnchor?.quote||false;})()
            """) as? String
            #expect(captured == "Paragraph 60 contains a unique passage")

            try await resizeBurst(view, in: window, includeNearZeroHeight: true,
                keepingVisible: "Paragraph 60 contains a unique passage")
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?
                .contains("Paragraph 60") == true)
            #expect(try await js(view, pagedRangeVisibleOnCurrentPage("Paragraph 60 contains a unique passage")) as? Bool == true)
            _ = try await js(view, """
            window.__vellumEpub.annotations([{id:'selected-note',anchor:window.__testNoteAnchor,color:'#ff0000'}])
            """)
            #expect(try await js(view, annotationRectsMatchSelection("Paragraph 60 contains a unique passage")) as? Bool == true)
        }
    }

    @Test("Paged restore during a resize burst replaces its pending target")
    func pagedResizeBurstRestore() async throws {
        let (html, anchor) = try resizeFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .paged))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentView = nil }
            try await resizeBurst(view, in: window,
                restoringDuringBurst: "window.__vellumEpub.restore({anchor:\(encoded),progression:0})")
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            #expect(try await js(view, rangeStartsInsideViewport("Paragraph 60 contains a unique passage")) as? Bool == true)
        }
    }

    @Test("Scroll resize bursts keep the original passage within the viewport")
    func scrollResizeBurst() async throws {
        let (html, anchor) = try resizeFixture()
        let encoded = EpubReaderJavaScript.literal(anchor)
        try await withDOM(html, size: NSSize(width: 420, height: 480)) { view in
            _ = try await js(view, configure(font: 28, spacing: 2.4, layout: .scroll))
            _ = try await js(view, "window.__vellumEpub.restore({anchor:\(encoded),progression:0})")
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.contentView = view
            window.orderFrontRegardless()
            defer { window.orderOut(nil); window.contentView = nil }
            try await resizeBurst(view, in: window)
            #expect((try await js(view, "window.__vellumEpub.snapshot().anchor?.quote") as? String)?.contains("Paragraph 60") == true)
            #expect(try await js(view, rangeWithinViewport("Paragraph 60 contains a unique passage")) as? Bool == true)
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

    @Test("Reactivating an EPUB reader republishes its cached Find state without navigating")
    func findStateAfterReactivation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-find-reactivation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let oldDocuments = DocumentDataStore.rootDirectoryOverride, oldBooks = EpubLibrary.directoryOverride
        let oldWeb = WebLibrary.storeDirOverride
        let oldLayout = AppDefaults.current.string(forKey: EpubReaderSettings.layoutKey)
        DocumentDataStore.rootDirectoryOverride = root.appendingPathComponent("documents")
        EpubLibrary.directoryOverride = root.appendingPathComponent("Books")
        WebLibrary.storeDirOverride = root.appendingPathComponent("web")
        defer {
            DocumentDataStore.rootDirectoryOverride = oldDocuments
            EpubLibrary.directoryOverride = oldBooks
            WebLibrary.storeDirOverride = oldWeb
            if let oldLayout { AppDefaults.current.set(oldLayout, forKey: EpubReaderSettings.layoutKey) }
            else { AppDefaults.current.removeObject(forKey: EpubReaderSettings.layoutKey) }
            try? FileManager.default.removeItem(at: root)
        }

        var fixture = EpubFixture.epub2()
        fixture.items.removeAll { $0.path == "OEBPS/a.html" || $0.path == "OEBPS/b.html" }
        fixture.add("OEBPS/a.html", "<html><body><p>needle first.</p><p>needle second.</p></body></html>")
        let repeated = (0..<600).map { "<p>needle result \($0).</p>" }.joined()
        fixture.add("OEBPS/b.html", "<html><body>\(repeated)</body></html>")
        let file = try fixture.write(to: root.appendingPathComponent("book.epub"))
        let manager = DocumentSessionManager()
        let workspace = WorkspaceStore(sessions: manager,
            positions: DocumentPositionService(storage: InMemoryPositionStorage()))
        let app = workspace.focusedPane.app
        let ai = AiStore(settings: AiSettings()); ai.app = app
        let notes = AnnotationStore(app: app)
        let scratchpad = ScratchpadStore()
        await app.openFile(path: file.path)
        let binding = try #require(app.activeDocumentBinding)
        let session = try #require(manager.documentSession(sessionId: binding.tabId) as? EpubDocumentSession)
        let reader = EpubReaderController()
        reader.bind(app: app, ai: ai, annotations: notes, scratchpad: scratchpad, session: session, tabId: binding.tabId)
        reader.activate(true)
        await reader.drain()
        app.performFind("needle")
        await reader.drain()
        app.findNext()
        app.findNext()
        let location = try #require(reader.location)
        let expectedCount = reader.searchResults.count
        let expectedCurrent = reader.searchIndex + 1
        #expect(expectedCount > 1 && expectedCurrent == 3 && reader.searchTruncated)

        reader.deactivate()
        app.setFindSearching(true)
        app.setFindTruncated(!reader.searchTruncated)
        app.setFindResults(count: 0, current: 0)
        reader.activate(true)
        await reader.drain()

        #expect(!app.findIsSearching)
        #expect(app.findTruncated == reader.searchTruncated)
        #expect(app.findMatchCount == expectedCount)
        #expect(app.findCurrentMatch == expectedCurrent)
        #expect(reader.location == location)

        app.newStartTab()
        AppDefaults.current.set(EpubReaderLayout.paged.rawValue, forKey: EpubReaderSettings.layoutKey)
        app.activateTab(binding.tabId)
        let replacement = EpubReaderController()
        replacement.bind(app: app, ai: ai, annotations: notes, scratchpad: scratchpad, session: session, tabId: binding.tabId)
        replacement.activate(true)
        await replacement.drain()
        app.performFind(app.findQuery)
        await replacement.drain()
        #expect(!app.findIsSearching)
        #expect(app.findTruncated)
        #expect(app.findMatchCount == expectedCount)
        #expect(app.findCurrentMatch == expectedCurrent)
        #expect(replacement.location?.chapter == location.chapter)
        #expect(replacement.location?.anchor == location.anchor)
        #expect(replacement.location?.progression == location.progression)

        _ = await replacement.close()
        await app.closeFile()
        await app.awaitPendingTabTeardowns()
        await workspace.awaitMaintenance()
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
        reader.settings.layout = .scroll
        pane.performFind("Text"); await reader.drain()
        #expect(pane.findMatchCount == 2 && !pane.findTruncated)
        pane.findNext()
        let selectedResult = try #require(reader.location?.anchor)
        #expect(reader.searchIndex == 1 && pane.findCurrentMatch == 2)
        reader.deactivate()
        reader.settings.layout = .paged
        reader.activate(true); await reader.drain()
        #expect(reader.searchIndex == 1 && pane.findCurrentMatch == 2 && reader.location?.anchor == selectedResult)
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

    private func resizeFixture() throws -> (html: String, anchor: EpubTextAnchor) {
        let quote = "Paragraph 60 contains a unique passage"
        let continuation = Array(repeating:
            "This paragraph continues through the resized EPUB page so a live reflow can move the reading position between columns.",
            count: 6).joined(separator: " ")
        let paragraphs = (0..<100).map {
            "<p>Paragraph \($0) contains a unique passage. \(continuation)</p>"
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

    private func pagedRangeVisibleOnCurrentPage(_ quote: String) -> String {
        let literal = EpubReaderJavaScript.literal(quote)
        return """
        (()=>{const q=\(literal),node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
          .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!node)return false;
          const start=node.data.indexOf(q),r=document.createRange();r.setStart(node,start);r.setEnd(node,start+q.length);
          const page=window.__vellumEpub.pageInfo().page;
          return Array.from(r.getClientRects()).some(rect=>rect.width>0&&rect.left>=0&&rect.left<innerWidth&&
            rect.top<innerHeight&&rect.bottom>0&&Math.floor((scrollX+rect.left)/innerWidth)===page);})()
        """
    }

    private func rangeWithinViewport(_ quote: String) -> String {
        let literal = EpubReaderJavaScript.literal(quote)
        return """
        (()=>{const q=\(literal),node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
          .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!node)return false;
          const start=node.data.indexOf(q),r=document.createRange();r.setStart(node,start);r.setEnd(node,start+q.length);
          const rect=r.getClientRects()[0];return !!rect&&rect.left>=0&&rect.right<=innerWidth&&rect.top>=0&&rect.bottom<=innerHeight;})()
        """
    }

    private func annotationRectsMatchSelection(_ quote: String) -> String {
        let literal = EpubReaderJavaScript.literal(quote)
        return """
        (()=>{const q=\(literal),node=Array.from(document.querySelectorAll('p')).map(p=>p.firstChild)
          .find(n=>n&&n.nodeType===Node.TEXT_NODE&&n.data.includes(q));if(!node)return false;
          const start=node.data.indexOf(q),r=document.createRange();r.setStart(node,start);r.setEnd(node,start+q.length);
          const textRects=Array.from(r.getClientRects()),marks=Array.from(document.querySelectorAll('button[aria-label="Open annotation"]'));
          return textRects.length>0&&marks.length===textRects.length&&textRects.every(text=>marks.some(mark=>{
            const rect=mark.getBoundingClientRect();
            return Math.abs(rect.left-text.left)<=2&&Math.abs(rect.top-text.top)<=2&&
              Math.abs(rect.width-text.width)<=2&&Math.abs(rect.height-text.height)<=2;}));})()
        """
    }

    private func waitForBridge(_ view: WKWebView, path: String) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if EpubResourceSchemeHandler.archivePath(for: view.url ?? URL(string: "about:blank")!) == path,
               (try? await js(view, "!!window.__vellumEpub")) as? Bool == true {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(EpubResourceSchemeHandler.archivePath(for: view.url ?? URL(string: "about:blank")!) == path)
        #expect(try await js(view, "!!window.__vellumEpub") as? Bool == true)
    }

    private func resizeBurst(_ view: WKWebView, in window: NSWindow, restoringDuringBurst: String? = nil,
                             includeNearZeroHeight: Bool = false, keepingVisible quote: String? = nil) async throws {
        _ = try await js(view, """
        window.__vellumResizeCount=0;window.__vellumScrollCount=0;window.__vellumSawNarrower=false;
        window.addEventListener('resize',()=>{
          window.__vellumResizeCount++;
          if (innerWidth<420) window.__vellumSawNarrower=true;
        });
        window.addEventListener('scroll',()=>window.__vellumScrollCount++);
        """)
        _ = try await js(view, "window.dispatchEvent(new Event('scroll'))")
        let sizes = includeNearZeroHeight
            ? [(404, 462), (388, 444), (360, 24), (372, 426), (356, 408), (420, 480)]
            : restoringDuringBurst == nil
            ? [(404, 462), (388, 444), (372, 426), (356, 408), (352, 403), (420, 480)]
            : [(404, 462), (388, 444), (420, 480)]
        for (index, (width, height)) in sizes.enumerated() {
            if index == 2, let restoringDuringBurst {
                _ = try await js(view, restoringDuringBurst)
            }
            window.setContentSize(NSSize(width: width, height: height))
            view.setFrameSize(NSSize(width: width, height: height))
            _ = try await js(view, "window.dispatchEvent(new Event('resize'))")
            if index == 1 {
                _ = try await js(view, "window.dispatchEvent(new Event('scroll'))")
            }
            try await Task.sleep(for: .milliseconds(90))
            if let quote, height > 100 {
                #expect(try await js(view, pagedRangeVisibleOnCurrentPage(quote)) as? Bool == true)
            }
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await js(view, "innerWidth") as? Int == 420)
        #expect(try await js(view, "window.__vellumSawNarrower") as? Bool == true)
        #expect(try await js(view, "window.__vellumResizeCount") as? Int ?? 0 >= sizes.count)
        #expect(try await js(view, "window.__vellumScrollCount") as? Int ?? 0 > 0)
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
                         size: NSSize = NSSize(width: 700, height: 480), configureBeforeBody: Bool = true,
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
        if configureBeforeBody { _ = try await js(view, configure()) }
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
