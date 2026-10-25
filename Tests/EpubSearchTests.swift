import Foundation
import Testing
@testable import Vellum

@Suite("EPUB bounded book text and search", .serialized)
@MainActor
struct EpubSearchTests {
    private func environment(
        first: String = "Café 😀 needle e\u{301} needle",
        second: String = "Later needle résumé",
        limits: EpubTextIndex.Limits = .init(),
        _ body: (EpubDocumentSession) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("epub-search-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var zip = EpubFixture.epub2()
        zip.items.removeAll { $0.path == "OEBPS/a.html" || $0.path == "OEBPS/b.html" }
        zip.add("OEBPS/a.html", "<html><body><p>\(first)</p></body></html>")
        zip.add("OEBPS/b.html", "<html><body><p>\(second)</p></body></html>")
        let file = try zip.write(to: root.appendingPathComponent("book.epub"))
        let load = Task.detached { try EpubBook.load(path: file.path) }
        let book = try await load.value
        let session = EpubDocumentSession(book: book, textLimits: limits)
        do {
            try await body(session)
            try await session.close()
        } catch { try? await session.close(); throw error }
    }

    @Test("Whole book search is spine ordered, literal Unicode, and returns durable chapter metadata")
    func unicodeAndOrder() async throws {
        try await environment { session in
            let result = try await session.search(query: "needle")
            #expect(result.chaptersSearched == 2 && !result.truncated)
            #expect(result.results.map(\.chapterNumber) == [1, 1, 2])
            #expect(result.results.map(\.chapterTitle) == ["First", "First", "Second"])
            for hit in result.results {
                #expect(hit.snippet.contains("needle"))
                #expect(try await session.resolveAnchor(hit.anchor) == hit.anchor)
            }
            let emoji = try await session.search(query: "😀")
            #expect(emoji.results.first?.anchor.startUTF16 == 5)
            #expect(emoji.results.first?.anchor.endUTF16 == 7)
            #expect(try await session.search(query: "e\u{301}").results.count == 1)
            #expect(try await session.search(query: "é").results.count == 3)
            #expect(try await session.search(query: "Needle").results.isEmpty)
            let metadata = try await session.chapterMetadata()
            #expect(metadata.map(\.chapterHref) == ["OEBPS/a.html", "OEBPS/b.html"])
            #expect(try await session.chapterText(spineIndex: 1).text == "Later needle résumé")
            #expect(try await session.search(query: " \n ").results.isEmpty)
        }
    }

    @Test("Effort caps explicitly report incomplete coverage, including no-match searches")
    func effortLimits() async throws {
        var limits = EpubTextIndex.Limits()
        limits.maxChapters = 1
        try await environment(limits: limits) { session in
            let result = try await session.search(query: "Later")
            #expect(result.results.isEmpty && result.chaptersSearched == 1 && result.truncated)
        }
        limits.maxChapters = 256
        limits.maxTotalUTF16 = 1
        try await environment(limits: limits) { session in
            let result = try await session.search(query: "missing")
            #expect(result.results.isEmpty && result.chaptersSearched == 0 && result.truncated)
        }
        limits.maxTotalUTF16 = 16 * 1024 * 1024
        limits.maxTotalInputBytes = 1
        try await environment(limits: limits) { session async throws in
            #expect(try await session.search(query: "missing").truncated)
        }
    }

    @Test("Result and query caps are hard bounded")
    func resultLimits() async throws {
        try await environment(first: String(repeating: "x ", count: 800), second: "x") { session in
            let two = try await session.search(query: "x", limit: 2)
            #expect(two.results.count == 2 && two.truncated)
            let capped = try await session.search(query: "x", limit: Int.max)
            #expect(capped.results.count == 201 && capped.chaptersSearched == 2 && capped.truncated)
            #expect(try await session.search(query: "x", limit: 0).results.isEmpty)
            await #expect(throws: EpubTextError.limitExceeded("query UTF-16")) {
                try await session.search(query: String(repeating: "x", count: 4097))
            }
        }
    }

    @Test("Invalid chapter indices and missing or ambiguous anchors never resolve to a duplicate")
    func resolution() async throws {
        try await environment(first: "same same", second: "different") { session async throws in
            let ambiguous = EpubTextAnchor(chapterHref: "OEBPS/a.html", quote: "same", prefix: "", suffix: "")
            #expect(try await session.resolveAnchor(ambiguous) == nil)
            var unique = ambiguous
            unique.prefix = "same "
            #expect(try await session.resolveAnchor(unique)?.startUTF16 == 5)
            var missing = ambiguous
            missing.chapterHref = "../not-a-chapter"
            #expect(try await session.resolveAnchor(missing) == nil)
            await #expect(throws: EpubAnnotationError.invalidChapter) { try await session.chapterText(spineIndex: -1) }
            await #expect(throws: EpubAnnotationError.invalidChapter) { try await session.chapterText(spineIndex: 2) }
        }
    }

    @Test("Cache-disabled extraction remains identical and cached chapters still consume search effort")
    func cacheAndEffort() async throws {
        var limits = EpubTextIndex.Limits()
        limits.maxCachedChapters = 0
        try await environment(limits: limits) { session in
            let one = try await session.chapterText(spineIndex: 0)
            let two = try await session.chapterText(spineIndex: 0)
            #expect(one == two)
        }
        limits.maxCachedChapters = 4
        limits.maxTotalUTF16 = 1
        try await environment(limits: limits) { session in
            _ = try await session.chapterText(spineIndex: 0)
            let result = try await session.search(query: "needle")
            #expect(result.results.isEmpty && result.truncated && result.chaptersSearched == 0)
        }
    }

    @Test("Cancellation and close reject stale text/resource results and drain tasks")
    func cancellationAndClose() async throws {
        try await environment(first: String(repeating: "word ", count: 100_000)) { session in
            let cancelled = Task { try await session.search(query: "word") }
            cancelled.cancel()
            await #expect(throws: CancellationError.self) { try await cancelled.value }
            let search = Task { try await session.search(query: "missing") }
            while session.pendingOperationCount == 0 { await Task.yield() }
            try await session.close()
            await #expect(throws: CancellationError.self) { try await search.value }
            #expect(session.pendingOperationCount == 0)
            await #expect(throws: SessionServiceError.self) { try await session.chapterText(spineIndex: 0) }
            await #expect(throws: SessionServiceError.self) { try await session.resourceData(at: "OEBPS/a.html") }
        }
    }

    @Test("Search JSON exposes exact snake-case contract")
    func jsonContract() throws {
        let anchor = EpubTextAnchor(chapterHref: "OPS/a.xhtml", quote: "😀", prefix: "", suffix: "", startUTF16: 0, endUTF16: 2)
        let response = EpubSearchResponse(
            results: [.init(chapterNumber: 1, chapterTitle: "One", snippet: "😀", anchor: anchor)],
            chaptersSearched: 1, truncated: true)
        let data = try JSONEncoder().encode(response)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["chapters_searched"] as? Int == 1)
        let result = try #require((json["results"] as? [[String: Any]])?.first)
        #expect(result["chapter_number"] as? Int == 1 && result["chapter_title"] as? String == "One")
        #expect((result["anchor"] as? [String: Any])?["end_utf16"] as? Int == 2)
        #expect(try JSONDecoder().decode(EpubSearchResponse.self, from: data) == response)
    }
}
