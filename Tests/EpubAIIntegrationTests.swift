import Foundation
import Testing
@testable import Vellum

@Suite("EPUB AI integration", .serialized, .isolatedStorage, .scratchDefaults)
@MainActor
struct EpubAIIntegrationTests {
    private let chapter = EpubChapterMetadata(chapterNumber: 1, chapterHref: "OEBPS/a.html", title: "First")

    private func citation(quote: String = "passage") -> AiEpubCitation {
        AiEpubCitation(docId: String(repeating: "a", count: 64), chapterNumber: 1,
            chapterTitle: "First", chapterHref: chapter.chapterHref,
            anchor: EpubTextAnchor(chapterHref: chapter.chapterHref, quote: quote, prefix: "", suffix: ""))
    }

    @Test("EPUB context is a bounded current chapter, with literal anchors and no hidden whole-book text")
    func contextFormatting() throws {
        let context = AiContextSnapshot(title: "Book", numPages: 2, currentPage: 1,
            visiblePages: [1, 2], annotations: [], currentPageImage: nil)
        let output = AiPrompts.buildContextBlock(pageTexts: [1: String(repeating: "😀 passage ", count: 4000),
            2: "HIDDEN-CHAPTER"], context: context, epubChapters: [chapter,
            .init(chapterNumber: 2, chapterHref: "OEBPS/b.html", title: "Second")], epubDocId: citation().docId)
        #expect(output.contains("Current chapter: 1 — First"))
        #expect(output.contains("chapter_href"))
        #expect(output.contains("start_utf16"))
        #expect(output.contains("truncated=true"))
        #expect(!output.contains("HIDDEN-CHAPTER"))
        #expect(!output.contains("Total pages:"))
        #expect(output.count < 15_000)
        let reference = AiReference(kind: .selection(text: "passage", page: 1), epubCitation: citation())
        let prompt = AiPrompts.buildNativeToolUserPrompt(.init(conversation: "", context: output,
            latestUserRequest: "Explain", references: [reference]))
        #expect(prompt.volatile.contains("EPUB Chapter 1"))
        #expect(!prompt.volatile.contains("p.1"))
        #expect(prompt.volatile.contains(citation().docId))
        #expect(reference.chipLabel.contains("Chapter 1"))
    }

    @Test("Saved passage citations survive sanitation, decoding and a different reader context")
    func citationRoundTripAndNavigation() throws {
        let locator = citation()
        let reference = AiReference(kind: .highlight(text: "passage", page: 1), epubCitation: locator)
        var message = AiMessage(id: "message", role: .assistant, content: "answer", createdAt: "now",
            references: [reference])
        message.toolSummaries = [AiToolSummary(title: "Read chapter 1",
            sources: [.init(page: nil, excerpt: "passage", epubCitation: locator)], destinationEpub: locator)]
        let data = try JSONEncoder().encode(AiPersistence.limitedMessages([message]))
        let restored = try #require(JSONDecoder().decode([AiMessage].self, from: data).first)
        #expect(restored.references.first?.epubCitation == locator)
        #expect(restored.toolSummaries?.first?.sources.first?.epubCitation == locator)
        #expect(restored.toolSummaries?.first?.destinationEpub == locator)
        let store = AiStore(settings: AiSettings())
        var destinations: [AiEpubCitation] = []
        store.epubCitationNavigationHandler = { destinations.append($0) }
        store.clearDocumentContext()
        var pdfPage: Int?
        store.navigateToReference(try #require(restored.references.first), fallback: { pdfPage = $0 })
        #expect(destinations == [locator])
        #expect(pdfPage == nil)
        store.navigateToEpubCitation(try #require(restored.toolSummaries?.first?.sources.first?.epubCitation))
        #expect(destinations.count == 2)
    }

    @Test("Legacy PDF/web reference storage, page callbacks and context remain unchanged")
    func legacyCompatibility() throws {
        let oldMessage = Data(#"{"id":"old","role":"assistant","content":"answer","createdAt":"now","toolSummaries":[{"id":"tool","title":"Read page 3","sources":[{"id":"source","page":3,"excerpt":"old excerpt"}],"destinationPage":3}]}"#.utf8)
        let decoded = try JSONDecoder().decode(AiMessage.self, from: oldMessage)
        #expect(decoded.references.isEmpty)
        #expect(decoded.toolSummaries?.first?.destinationEpub == nil)
        #expect(decoded.toolSummaries?.first?.sources.first?.page == 3)
        let oldReference = Data(#"{"id":"ref","kind":{"tag":"selection","text":"web passage","page":7}}"#.utf8)
        let reference = try JSONDecoder().decode(AiReference.self, from: oldReference)
        #expect(reference.epubCitation == nil)
        let store = AiStore(settings: AiSettings())
        var page: Int?
        store.navigateToReference(reference, fallback: { page = $0 })
        #expect(page == 7)
        let context = AiContextSnapshot(title: "PDF/web", numPages: 8, currentPage: 7,
            visiblePages: [7], annotations: [], currentPageImage: nil)
        #expect(AiPrompts.buildContextBlock(pageTexts: [7: "legacy"], context: context).contains("Current page: 7"))
        let prompt = AiPrompts.buildNativeToolUserPrompt(.init(conversation: "", context: "",
            latestUserRequest: "Explain", references: [reference]))
        #expect(prompt.volatile.contains("[selected text, p.7]"))
    }

    @Test("Locator bounds reject unsafe paths, oversized quotes and invalid UTF-16 without making false PDF links")
    func locatorBounds() {
        var value = citation(quote: "😀")
        value.anchor?.startUTF16 = 4
        value.anchor?.endUTF16 = 6
        #expect(value.bounded != nil)
        value.anchor?.endUTF16 = Int.max
        #expect(value.bounded == nil)
        let invalid = AiReference(kind: .selection(text: "😀", page: 1), epubCitation: value)
        #expect(AiPersistence.capReferences([invalid]).isEmpty)
        var source = AiToolSummary.Source(page: 1, excerpt: "😀", epubCitation: value)
        source = AiPersistence.sanitizeToolSummaries([.init(title: "Read", sources: [source])])[0].sources[0]
        #expect(source.page == nil && source.epubCitation == nil)
        #expect(citation(quote: String(repeating: "x", count: 4097)).bounded == nil)
        value = citation()
        value.chapterHref = "../escape"
        #expect(value.bounded == nil)
        value = citation()
        value.anchor?.prefix = String(repeating: "x", count: 257)
        #expect(value.bounded == nil)
        value = citation()
        value.anchor?.chapterHref = "OEBPS/b.html"
        #expect(value.bounded == nil)
    }

    private func environment(limits: EpubTextIndex.Limits = .init(), firstText: String? = nil,
                             _ body: (EpubDocumentSession, URL) async throws -> Void) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-ai-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let documents = DocumentDataStore.rootDirectoryOverride
        let books = EpubLibrary.directoryOverride
        let web = WebLibrary.storeDirOverride
        DocumentDataStore.rootDirectoryOverride = root.appendingPathComponent("documents")
        EpubLibrary.directoryOverride = root.appendingPathComponent("Books")
        WebLibrary.storeDirOverride = root.appendingPathComponent("web")
        defer {
            DocumentDataStore.rootDirectoryOverride = documents
            EpubLibrary.directoryOverride = books
            WebLibrary.storeDirOverride = web
            try? FileManager.default.removeItem(at: root)
        }
        var fixture = EpubFixture.epub2()
        if let firstText {
            fixture.items.removeAll { $0.path == "OEBPS/a.html" }
            fixture.add("OEBPS/a.html", "<html><body><p>\(firstText)</p></body></html>")
        }
        let file = try fixture.write(to: root.appendingPathComponent("book.epub"))
        let load = Task.detached { try EpubBook.load(path: file.path) }
        let session = EpubDocumentSession(book: try await load.value, textLimits: limits)
        do { try await body(session, file); try await session.close() }
        catch { try? await session.close(); throw error }
        await AiPersistence.awaitPendingFlush()
    }

    private func execution(_ session: EpubDocumentSession,
                           current: @escaping () -> Bool = { true },
                           chapterRead: ((Int) async throws -> EpubChapterText)? = nil,
                           navigate: @escaping (AiEpubCitation) -> Void = { _ in }) -> AiToolExecutionContext {
        var context = AiToolExecutionContext(binding: .init(tabId: "tab", docId: session.info.docId,
            storageKey: session.info.docId!, generation: UUID()), document: session.info,
            currentPage: 1, pageCount: session.info.pageCount ?? 0, pageTexts: [:], annotations: [],
            isCurrent: current, setActivity: { _ in }, extract: { _ in [:] }, locate: { _, _ in nil },
            createAnnotation: { try await session.createAnnotation($0) }, navigate: { _ in })
        context.epub = .init(metadata: { try await session.chapterMetadata() },
            chapter: chapterRead ?? { try await session.chapterText(spineIndex: $0) },
            search: { try await session.search(query: $0, limit: $1) },
            resolve: { try await session.resolveAnchor($0) }, navigate: navigate)
        return context
    }

    private func action(_ name: String, text: String? = nil, anchor: EpubTextAnchor? = nil) -> AiToolAction {
        .init(tool: name, args: .init(pageNumber: 1, text: text, epubAnchor: anchor))
    }

    @Test("Chapter reads and search expose navigable passage JSON and surface partial coverage")
    func chapterAndSearchTools() async throws {
        var limits = EpubTextIndex.Limits()
        limits.maxChapters = 1
        try await environment(limits: limits) { session, _ in
            var jumps: [AiEpubCitation] = []
            let engine = AiToolEngine(context: execution(session, navigate: { jumps.append($0) }))
            let raw = await engine.run(action("getPageText"), sessionIdAtStart: "tab", actionCount: 0)
            let read = try JSONDecoder().decode(AiEpubToolResult.self, from: Data(raw.utf8))
            let source = try #require(read.sources.first)
            #expect(source.docId == session.info.docId)
            #expect(source.anchor != nil)
            #expect(try await session.resolveAnchor(try #require(source.anchor)) == source.anchor)
            let search = await engine.run(action("searchDocument", text: "absent"), sessionIdAtStart: "tab", actionCount: 0)
            let result = try JSONDecoder().decode(AiEpubToolResult.self, from: Data(search.utf8))
            #expect(result.truncated && result.chaptersSearched == 1)
            #expect(engine.displayActions.last?.detail?.contains("truncated") == true)
            let query = String(try #require(source.anchor).quote.prefix(5))
            let hit = await engine.run(action("searchDocument", text: query), sessionIdAtStart: "tab", actionCount: 0)
            let found = try JSONDecoder().decode(AiEpubToolResult.self, from: Data(hit.utf8))
            #expect(found.sources.first?.anchor?.quote == query)
            #expect(found.sources.first?.chapterHref == source.chapterHref)
            _ = await engine.run(action("goToPage", anchor: source.anchor), sessionIdAtStart: "tab", actionCount: 0)
            #expect(jumps.first?.anchor == source.anchor)
            #expect(engine.displayActions.last?.destinationEpub?.docId == session.info.docId)
        }
    }

    @Test("Explicit large chapter reads cap text and passage metadata; ambiguous highlight quotes fail safely")
    func boundedReadAndAmbiguity() async throws {
        try await environment(firstText: String(repeating: "same 😀 ", count: 4000)) { session, _ in
            let engine = AiToolEngine(context: execution(session))
            let raw = await engine.run(action("getPageText"), sessionIdAtStart: "tab", actionCount: 0)
            let result = try JSONDecoder().decode(AiEpubToolResult.self, from: Data(raw.utf8))
            #expect(result.truncated)
            #expect(result.text?.count == AiToolEngine.maxPageReadCharacters)
            let anchor = try #require(result.sources.first?.anchor)
            #expect(anchor.quote.utf16.count <= 4096)
            #expect(try await session.resolveAnchor(anchor) == anchor)
            let failed = await engine.run(action("addHighlight", text: "same"), sessionIdAtStart: "tab", actionCount: 0)
            #expect(failed.contains("missing or ambiguous"))
            #expect(try await session.annotations(pageNumber: nil).isEmpty)
        }
    }

    @Test("EPUB AI annotations require backend-validated passage anchors and never rewrite original bytes")
    func anchoredAnnotations() async throws {
        try await environment { session, file in
            let original = try Data(contentsOf: file)
            let content = try await session.chapterText(spineIndex: 0)
            let anchor = try #require(content.anchor(in: NSRange(location: 0, length: 5)))
            let engine = AiToolEngine(context: execution(session))
            let rejected = await engine.run(action("addNote", text: "note"), sessionIdAtStart: "tab", actionCount: 0)
            #expect(rejected.contains("require an exact epubAnchor"))
            #expect(try await session.annotations(pageNumber: nil).isEmpty)
            _ = await engine.run(action("addNote", text: "note", anchor: anchor), sessionIdAtStart: "tab", actionCount: 0)
            _ = await engine.run(action("addHighlight", text: anchor.quote), sessionIdAtStart: "tab", actionCount: 0)
            let annotations = try await session.annotations(pageNumber: nil)
            #expect(annotations.count == 2)
            #expect(annotations.allSatisfy { $0.positionData?.epubAnchor == anchor })
            #expect(try Data(contentsOf: file) == original)
        }
    }

    @Test("Stale binding after awaited chapter read cannot publish sources, navigate or create annotations")
    func staleBinding() async throws {
        try await environment { session, _ in
            var current = true
            var navigated = false
            let engine = AiToolEngine(context: execution(session, current: { current }, chapterRead: { index in
                let content = try await session.chapterText(spineIndex: index)
                current = false
                return content
            }, navigate: { _ in navigated = true }))
            let result = await engine.run(action("getPageText"), sessionIdAtStart: "tab", actionCount: 0)
            #expect(result.contains("no longer current"))
            #expect(engine.displayActions.isEmpty)
            _ = await engine.run(action("goToPage"), sessionIdAtStart: "tab", actionCount: 0)
            _ = await engine.run(action("addNote", text: "must not save"), sessionIdAtStart: "tab", actionCount: 0)
            #expect(!navigated)
            let annotations = try await session.annotations(pageNumber: nil)
            #expect(annotations.isEmpty)
        }
    }

    @Test("Reader registration uses existing extraction/composer, and rejects an obsolete binding")
    func readerRegistration() async throws {
        try await environment { _, file in
            let manager = DocumentSessionManager()
            let app = AppStore(sessions: manager)
            let store = AiStore(settings: AiSettings())
            store.app = app
            await app.openFile(path: file.path)
            let binding = try #require(app.activeDocumentBinding)
            let backend = try #require(manager.documentSession(sessionId: binding.tabId) as? EpubDocumentSession)
            #expect(store.registerEpubSession(backend, binding: binding))
            let oldExtract = try #require(store.ensureExtractedHandler)
            #expect(await store.ensureExtracted(pages: nil) == 1)
            #expect(store.pageTexts.keys.sorted() == [1])
            let target = try #require(store.currentReferenceTarget())
            let content = try await backend.chapterText(spineIndex: 0)
            let anchor = try #require(content.anchor(in: NSRange(location: 0, length: 5)))
            #expect(await store.addEpubReference(anchor: anchor, chapterNumber: 1, target: target))
            #expect(store.composerReferences.first?.epubCitation?.anchor == anchor)
            store.unregisterEpubSession(binding: binding)
            await store.awaitCancelledRequests()
            #expect(await oldExtract([1]) == 0)
            #expect(store.pageTexts.isEmpty)
            #expect(!(await store.addEpubReference(anchor: anchor, chapterNumber: 1, target: target)))
            await app.closeFile()
            await app.awaitPendingTabTeardowns()
            #expect(!store.registerEpubSession(backend, binding: binding))
        }
    }
}
