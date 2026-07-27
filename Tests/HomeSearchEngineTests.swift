import Foundation
import Testing

@testable import Vellum

// The provider layer behind the home screen's search field (issue #62): how
// each on-disk source is turned into corpus items, how the engine merges and
// dedupes them, and — the part that matters for the read-later follow-up — how
// a `.live` provider participates without the UI knowing anything about it.
//
// Every provider takes its data source as an injected closure, so nothing here
// touches the real recents list, web store, or documents directory.

// MARK: - Fixtures

private func recent(
    path: String,
    kind: DocumentKind = .pdf,
    title: String? = nil,
    pageCount: Int? = nil,
    openedAt: Date = Date()
) -> RecentDocument {
    RecentDocument(
        pdfPath: path,
        kind: kind,
        title: title,
        pageCount: pageCount,
        openedAt: ISO8601DateFormatter.recentTimestamp.string(from: openedAt),
        docId: nil)
}

private func meta(
    kind: DocumentKind = .pdf, title: String?, path: String, lastOpened: Date = Date()
) -> DocumentDataStore.Meta {
    DocumentDataStore.Meta(
        version: 1,
        kind: kind.rawValue,
        title: title,
        lastKnownPath: path,
        lastOpened: ISO8601DateFormatter.recentTimestamp.string(from: lastOpened))
}

/// A provider that answers from a fixed list — stands in for a connected
/// read-later account in the tests that exercise the `.live` path.
private struct StubProvider: HomeSearchProvider {
    let id: String
    let displayName: String
    let mode: HomeSearchProviderMode
    let response: @Sendable (String) throws -> [HomeSearchItem]

    func items(matching query: String) async throws -> [HomeSearchItem] {
        try response(query)
    }
}

private struct StubError: Error, LocalizedError {
    var errorDescription: String? { "not connected" }
}

private func stubItem(
    id: String, identity: String, section: HomeSearchSection = .readLater, title: String
) -> HomeSearchItem {
    HomeSearchItem(
        id: id,
        identity: identity,
        section: section,
        kind: .web,
        target: .url(identity),
        title: title,
        subtitle: identity,
        detail: "",
        tooltip: identity,
        date: nil,
        badges: [],
        canRevealInFinder: false,
        haystack: HomeSearchHaystack(title: title, name: identity, location: identity))
}

// MARK: - Recents provider

@Suite("Recent documents provider")
struct RecentDocumentsSearchProviderTests {
    @Test("A PDF recent becomes a searchable item with its filename and page count")
    func mapsPdfRecent() async throws {
        let provider = RecentDocumentsSearchProvider(
            load: { [recent(path: "/docs/1706.03762.pdf", title: "Attention Is All You Need", pageCount: 15)] },
            resolvePath: { $0.pdfPath },
            fileExists: { _ in true })

        let items = try await provider.items(matching: "")
        let item = try #require(items.first)
        #expect(item.title == "Attention Is All You Need")
        #expect(item.subtitle == "1706.03762.pdf · 15 pages")
        #expect(item.section == .recents)
        #expect(item.canRevealInFinder)
        #expect(!item.badges.contains(.missing))
        #expect(item.target == .file(path: "/docs/1706.03762.pdf", recordedPath: "/docs/1706.03762.pdf"))
        // The filename is searchable even though the title is what's displayed.
        #expect(item.haystack.name == "1706.03762.pdf")
    }

    @Test("A recent with no title falls back to its filename")
    func fallsBackToFilename() async throws {
        let provider = RecentDocumentsSearchProvider(
            load: { [recent(path: "/docs/untitled.pdf", title: "   ")] },
            resolvePath: { $0.pdfPath },
            fileExists: { _ in true })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.title == "untitled.pdf")
    }

    @Test("A single page reads 'page', not 'pages'")
    func singularPageCount() async throws {
        let provider = RecentDocumentsSearchProvider(
            load: { [recent(path: "/docs/one.pdf", pageCount: 1)] },
            resolvePath: { $0.pdfPath },
            fileExists: { _ in true })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.subtitle == "one.pdf · 1 page")
    }

    @Test("A moved PDF carries both its resolved and its recorded path")
    func movedPdfKeepsRecordedPath() async throws {
        let provider = RecentDocumentsSearchProvider(
            load: { [recent(path: "/old/paper.pdf")] },
            resolvePath: { _ in "/new/paper.pdf" },
            fileExists: { _ in true })
        let item = try #require(try await provider.items(matching: "").first)
        // Opening must use the new path but forget the stale entry (design §7).
        #expect(item.target == .file(path: "/new/paper.pdf", recordedPath: "/old/paper.pdf"))
    }

    @Test("A PDF that is no longer on disk is flagged, not hidden")
    func missingFileIsBadged() async throws {
        let provider = RecentDocumentsSearchProvider(
            load: { [recent(path: "/gone/paper.pdf")] },
            resolvePath: { $0.pdfPath },
            fileExists: { _ in false })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.badges.contains(.missing))
        #expect(!item.canRevealInFinder)
    }

    @Test("A web recent is a URL target with a host-and-path subtitle")
    func mapsWebRecent() async throws {
        let provider = RecentDocumentsSearchProvider(
            load: { [recent(path: "https://arxiv.org/abs/1706.03762", kind: .web, title: "Attention")] },
            resolvePath: { $0.pdfPath },
            fileExists: { _ in false })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.kind == .web)
        #expect(item.target == .url("https://arxiv.org/abs/1706.03762"))
        #expect(item.subtitle == "arxiv.org/abs/1706.03762")
        // A web recent is never "missing" — there is no file to lose.
        #expect(!item.badges.contains(.missing))
    }
}

// MARK: - Saved webpages provider

@Suite("Saved webpages provider")
struct SavedWebpagesSearchProviderTests {
    @Test("A saved page is badged saved, and offline when a snapshot exists")
    func mapsSavedPage() async throws {
        let provider = SavedWebpagesSearchProvider(load: {
            [
                WebLibraryEntry(
                    url: "https://example.com/article", title: "An Article",
                    pageCount: nil, savedAt: "2026-01-02T03:04:05.000Z", hasSnapshot: true)
            ]
        })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.section == .webpages)
        #expect(item.badges.contains(.saved))
        #expect(item.badges.contains(.offline))
        #expect(item.date != nil)
        // The host is indexed separately so "example" ranks as a name match.
        #expect(item.haystack.name == "example.com")
    }

    @Test("A page with no snapshot is saved but not offline")
    func withoutSnapshot() async throws {
        let provider = SavedWebpagesSearchProvider(load: {
            [
                WebLibraryEntry(
                    url: "https://example.com/b", title: nil, pageCount: nil,
                    savedAt: nil, hasSnapshot: false)
            ]
        })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.badges == [.saved])
        #expect(item.title == "example.com/b")
        #expect(item.detail.isEmpty)
    }
}

// MARK: - Library documents provider

@Suite("Library documents provider")
struct LibraryDocumentsSearchProviderTests {
    @Test("A noted PDF lands in Documents with a notes badge")
    func mapsPdfDocument() async throws {
        let provider = LibraryDocumentsSearchProvider(
            load: {
                [
                    DocumentDataStore.DocumentMetaEntry(
                        key: "abc", meta: meta(title: "Thesis", path: "/docs/thesis.pdf"),
                        hasUserData: true)
                ]
            },
            fileExists: { _ in true })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.section == .documents)
        #expect(item.kind == .pdf)
        #expect(item.badges.contains(.notes))
        #expect(item.canRevealInFinder)
    }

    @Test("A web document lands in Webpages and is never flagged missing")
    func mapsWebDocument() async throws {
        let provider = LibraryDocumentsSearchProvider(
            load: {
                [
                    DocumentDataStore.DocumentMetaEntry(
                        key: "def",
                        meta: meta(kind: .web, title: "Post", path: "https://example.com/post"),
                        hasUserData: false)
                ]
            },
            fileExists: { _ in false })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.section == .webpages)
        #expect(item.kind == .web)
        #expect(item.target == .url("https://example.com/post"))
        #expect(item.badges.isEmpty)
    }

    @Test("A PDF whose file has vanished is badged missing")
    func orphanedDocument() async throws {
        let provider = LibraryDocumentsSearchProvider(
            load: {
                [
                    DocumentDataStore.DocumentMetaEntry(
                        key: "ghi", meta: meta(title: "Gone", path: "/docs/gone.pdf"),
                        hasUserData: true)
                ]
            },
            fileExists: { _ in false })
        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.badges.contains(.missing))
        #expect(!item.canRevealInFinder)
    }
}

// MARK: - Engine

@Suite("Home search engine")
struct HomeSearchEngineTests {
    @Test("The same document reached from two sources collapses to one row")
    func dedupesAcrossProviders() async {
        let shared = "/docs/paper.pdf"
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "recents", displayName: "Recents", mode: .snapshot) { _ in
                [stubItem(id: "recents:x", identity: shared, section: .recents, title: "Paper")]
            },
            StubProvider(id: "library", displayName: "Library", mode: .snapshot) { _ in
                [stubItem(id: "library:x", identity: shared, section: .documents, title: "Paper")]
            },
        ])
        await engine.reload()

        let corpus = await engine.corpus
        #expect(corpus.count == 1)
        // Provider order is dedupe priority: the earlier source wins.
        #expect(corpus.first?.id == "recents:x")
    }

    @Test("Snapshot providers load once and are not re-queried per keystroke")
    func snapshotProvidersAreNotQueriedPerKeystroke() async {
        let counter = CallCounter()
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "local", displayName: "Local", mode: .snapshot) { _ in
                counter.increment()
                return [stubItem(id: "local:1", identity: "a", title: "Alpha")]
            }
        ])
        await engine.reload()
        _ = await engine.results(query: "al", now: Date())
        _ = await engine.results(query: "alp", now: Date())
        #expect(counter.value == 1)
    }

    @Test("A live provider is asked for each query and its hits are ranked alongside local ones")
    func liveProviderParticipates() async {
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "local", displayName: "Local", mode: .snapshot) { _ in
                [stubItem(id: "local:1", identity: "local-a", title: "Local Reading")]
            },
            StubProvider(id: "later", displayName: "Read Later", mode: .live) { query in
                [
                    stubItem(
                        id: "later:1", identity: "remote-a",
                        title: "Remote \(query.capitalized)")
                ]
            },
        ])
        await engine.reload()

        // Browsing must not touch the network-shaped source at all.
        let browse = await engine.results(query: "", now: Date())
        #expect(browse.flatMap(\.items).map(\.id) == ["local:1"])

        let searched = await engine.results(query: "reading", now: Date())
        let ids = searched.flatMap(\.items).map(\.id)
        #expect(ids.contains("local:1"))
        #expect(ids.contains("later:1"))
        #expect(searched.contains { $0.section == .readLater })
    }

    @Test("A local copy of an article wins over the live source's duplicate")
    func localWinsOverLiveDuplicate() async {
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "webpages", displayName: "Saved", mode: .snapshot) { _ in
                [stubItem(id: "webpages:1", identity: "https://x.test/a", section: .webpages, title: "Cached")]
            },
            StubProvider(id: "later", displayName: "Read Later", mode: .live) { _ in
                [stubItem(id: "later:1", identity: "https://x.test/a", title: "Cached")]
            },
        ])
        await engine.reload()
        let ids = await engine.results(query: "cached", now: Date()).flatMap(\.items).map(\.id)
        #expect(ids == ["webpages:1"])
    }

    @Test("A failing source is reported rather than silently narrowing the search")
    func failuresAreReported() async {
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "ok", displayName: "Recents", mode: .snapshot) { _ in
                [stubItem(id: "ok:1", identity: "a", title: "Alpha")]
            },
            StubProvider(id: "bad", displayName: "Read Later", mode: .snapshot) { _ in
                throw StubError()
            },
        ])
        await engine.reload()

        let failures = await engine.failures
        #expect(failures.count == 1)
        #expect(failures.first?.hasPrefix("Read Later: ") == true)
        // The healthy source still loaded.
        #expect(await engine.corpus.count == 1)
    }

    @Test("A live failure is recorded once, then cleared when the source recovers")
    func liveFailureClearsOnRecovery() async {
        let flaky = FlakyFlag()
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "later", displayName: "Read Later", mode: .live) { _ in
                if flaky.shouldFail { throw StubError() }
                return [stubItem(id: "later:1", identity: "r", title: "Remote")]
            }
        ])
        await engine.reload()

        _ = await engine.results(query: "remote", now: Date())
        _ = await engine.results(query: "remote", now: Date())
        #expect(await engine.failures.count == 1)

        flaky.shouldFail = false
        _ = await engine.results(query: "remote", now: Date())
        #expect(await engine.failures.isEmpty)
    }

    @Test("An engine that has loaded nothing still answers cleanly")
    func emptyEngine() async {
        let engine = HomeSearchEngine(providers: [])
        await engine.reload()
        #expect(await engine.hasLoaded)
        #expect(await engine.corpus.isEmpty)
        #expect(await engine.results(query: "anything", now: Date()).isEmpty)
    }
}

/// Counts provider invocations across the concurrent load. A `final class` with
/// a lock rather than an actor so the stub's synchronous closure can use it.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Flips a stub provider between failing and healthy mid-test.
private final class FlakyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var failing = true

    var shouldFail: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return failing
        }
        set {
            lock.lock()
            failing = newValue
            lock.unlock()
        }
    }
}
