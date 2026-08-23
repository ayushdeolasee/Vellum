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

/// A `.live` provider that never answers on its own. `StubProvider`'s response
/// is synchronous, so it can never be caught mid-flight; this one parks on a
/// long sleep, which is the only way a test can observe what the engine does
/// when the surrounding task is cancelled underneath an in-flight remote
/// source — exactly what the 120ms debounce does on every keystroke.
private struct HangingLiveProvider: HomeSearchProvider {
    let id = "later"
    let displayName = "Read Later"
    let mode = HomeSearchProviderMode.live

    func items(matching _: String) async throws -> [HomeSearchItem] {
        // Throws `CancellationError` as soon as the task is cancelled.
        try await Task.sleep(for: .seconds(30))
        return []
    }
}

private func stubItem(
    id: String,
    identity: String,
    section: HomeSearchSection = .readLater,
    title: String,
    badges: HomeSearchBadges = []
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
        badges: badges,
        canRevealInFinder: false,
        haystack: HomeSearchHaystack(title: title, name: identity, location: identity))
}

private func pdfStubItem(
    id: String,
    path: String,
    section: HomeSearchSection,
    storageKey: String
) -> HomeSearchItem {
    HomeSearchItem(
        id: id,
        identity: HomeSearchItemBuilder.identity(path, kind: .pdf),
        section: section,
        kind: .pdf,
        target: .file(path: path, recordedPath: path),
        title: "Paper",
        subtitle: "Paper.pdf",
        detail: "",
        tooltip: path,
        date: nil,
        badges: [],
        canRevealInFinder: true,
        haystack: HomeSearchHaystack(title: "Paper", name: "Paper.pdf", location: path),
        storageKey: storageKey)
}

/// A snapshot provider that answers instantly the first time and then parks
/// forever. The only way to get an engine into a known-good state and *then*
/// cancel a reload out from under it, which is what the welcome screen's
/// `.task` does every time a pane is torn down mid-load.
private struct StallsAfterFirstLoadProvider: HomeSearchProvider {
    let id = "flip"
    let displayName = "Flip"
    let mode = HomeSearchProviderMode.snapshot
    let calls: CallCounter

    func items(matching _: String) async throws -> [HomeSearchItem] {
        calls.increment()
        if calls.value > 1 {
            // Throws `CancellationError` the moment the surrounding task is
            // cancelled.
            try await Task.sleep(for: .seconds(30))
        }
        return [stubItem(id: "flip:1", identity: "flip", title: "Flip")]
    }
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
    @Test("A captured page stays New until the device-local ledger is cleared")
    func mapsCapturedUnreadState() async throws {
        let url = "https://example.com/captured"
        let key = WebLibrary.pageKey(url)
        let provider = SavedWebpagesSearchProvider(load: {
            [
                WebLibraryEntry(
                    url: url, title: "Captured", pageCount: nil,
                    savedAt: nil, hasSnapshot: true)
            ]
        }, isCapturedUnread: { $0 == key })

        let item = try #require(try await provider.items(matching: "").first)
        #expect(item.badges.contains(.capturedUnread))
    }

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

    /// A meta.json can carry a blank `last_known_path`. Those entries must be
    /// dropped, not mapped: the locator IS the dedupe identity, so two of them
    /// would share the identity `""` and `HomeSearchEngine.deduplicated` would
    /// silently collapse them into one row — and that row's target is
    /// `.file(path: "")`, which cannot open. Asserting through the engine
    /// (rather than the provider alone) is what pins the collapse.
    @Test("Documents with no recorded path are dropped, not collapsed into one row")
    func blankPathDocumentsAreDropped() async throws {
        let provider = LibraryDocumentsSearchProvider(
            load: {
                [
                    DocumentDataStore.DocumentMetaEntry(
                        key: "blank-1", meta: meta(title: "First", path: ""), hasUserData: true),
                    DocumentDataStore.DocumentMetaEntry(
                        key: "blank-2", meta: meta(title: "Second", path: "   "),
                        hasUserData: true),
                    DocumentDataStore.DocumentMetaEntry(
                        key: "real", meta: meta(title: "Real", path: "/docs/real.pdf"),
                        hasUserData: true),
                ]
            },
            fileExists: { _ in true })

        #expect(try await provider.items(matching: "").map(\.title) == ["Real"])

        let engine = HomeSearchEngine(providers: [provider])
        await engine.reload()
        #expect(await engine.corpus.map(\.title) == ["Real"])
    }
}

// MARK: - Dedupe identity

/// The cross-provider merge key. Getting this wrong is invisible in the happy
/// path and ugly at the edges: too loose and two different pages become one
/// row, too strict and the same article shows up three times because three
/// sources spell its URL three ways.
@Suite("Home search dedupe identity")
struct HomeSearchIdentityTests {
    private func web(_ url: String) -> String {
        HomeSearchItemBuilder.identity(url, kind: .web)
    }

    @Test("One article spelled three ways is one identity")
    func normalizesWebSpellings() {
        // The recents list keeps what the user typed; the web library keeps the
        // normalized form; a shared link arrives with a tracking tail and an
        // anchor. All the same page.
        let canonical = web("https://example.com/post")
        #expect(web("example.com/post") == canonical)
        #expect(web("https://EXAMPLE.com/post") == canonical)
        #expect(web("https://example.com/post?utm_source=newsletter") == canonical)
        #expect(web("https://example.com/post#introduction") == canonical)
    }

    /// The tempting cheap version — `locator.lowercased()` — folds these two,
    /// and most servers treat them as different pages. A merge is destructive
    /// (one of the rows stops being reachable at all), so the tie goes to
    /// keeping them apart.
    @Test("Paths that differ only in case stay two documents")
    func keepsCaseSensitivePathsApart() {
        #expect(web("https://example.com/Foo") != web("https://example.com/foo"))
    }

    @Test("File paths are verbatim, because case-sensitive volumes exist")
    func fileIdentityIsVerbatim() {
        #expect(HomeSearchItemBuilder.identity("/A/Paper.pdf", kind: .pdf) == "/A/Paper.pdf")
        #expect(
            HomeSearchItemBuilder.identity("/A/Paper.pdf", kind: .pdf)
                != HomeSearchItemBuilder.identity("/a/paper.pdf", kind: .pdf))
    }

    /// Normalization throws on input it cannot parse. Falling back to the raw
    /// locator can at worst show one page twice; it can never merge two pages,
    /// which is the failure that loses data from the user's view.
    @Test("Unparseable input falls back instead of throwing")
    func unparseableFallsBack() {
        // Empty, and a scheme the web pipeline refuses — both throw out of
        // `WebUrl.normalize` and must come back as themselves rather than
        // taking the corpus build down with them. (A blank identity is then
        // dropped by `HomeSearchEngine.deduplicated`, which is the right end
        // for a row nothing can open.)
        #expect(web("") == "")
        #expect(web("file:///docs/paper.pdf") == "file:///docs/paper.pdf")
    }

    @Test("A recent and a saved copy of the same article are one row end to end")
    func recentAndSavedCollapse() async throws {
        let engine = HomeSearchEngine(providers: [
            RecentDocumentsSearchProvider(
                load: { [recent(path: "example.com/post", kind: .web, title: "The Post")] },
                resolvePath: { $0.pdfPath },
                fileExists: { _ in false }),
            SavedWebpagesSearchProvider(load: {
                [
                    WebLibraryEntry(
                        url: "https://example.com/post?utm_source=newsletter",
                        title: "The Post", pageCount: nil,
                        savedAt: "2026-01-02T03:04:05.000Z", hasSnapshot: true)
                ]
            }),
        ])
        await engine.reload()

        let corpus = await engine.corpus
        let row = try #require(corpus.first)
        #expect(corpus.count == 1)
        // The recents row survives (freshest date, priority order) and inherits
        // what only the web library knew.
        #expect(row.section == .recents)
        #expect(row.badges.contains(.saved))
        #expect(row.badges.contains(.offline))
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

    @Test("A duplicate upgrades a recent's path hash to its durable document key")
    func dedupeAdoptsStableKeyOverLegacyPathHash() async throws {
        let path = "/docs/Paper.pdf"
        let legacyKey = DocumentIdentity.sha256Hex(path)
        let stableKey = "11111111-1111-1111-1111-111111111111"
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "recents", displayName: "Recents", mode: .snapshot) { _ in
                [pdfStubItem(
                    id: "recents:paper", path: path, section: .recents,
                    storageKey: legacyKey)]
            },
            StubProvider(id: "library", displayName: "Library", mode: .snapshot) { _ in
                [pdfStubItem(
                    id: "library:paper", path: path, section: .documents,
                    storageKey: stableKey)]
            },
        ])
        await engine.reload()

        let item = try #require(await engine.corpus.first)
        #expect(item.id == "recents:paper")
        #expect(item.storageKey == stableKey)

        // Upgrading the row must keep both generations of position identity
        // resolvable: the stable id and the pre-stamp path hash.
        let stableResume = ResumeEntry(
            key: .pdf(stableIdentifier: stableKey), title: "Paper",
            openedAt: Date(timeIntervalSince1970: 2), position: nil,
            lastOpenedOn: nil, openElsewhere: [])
        let legacyResume = ResumeEntry(
            key: .pdfPath(path), title: "Paper",
            openedAt: Date(timeIntervalSince1970: 1), position: nil,
            lastOpenedOn: nil, openElsewhere: [])
        #expect(ContinueReadingResolver.resolve([stableResume], in: [item]).count == 1)
        #expect(ContinueReadingResolver.resolve([legacyResume], in: [item]).count == 1)
    }

    @Test("Dedupe does not replace one durable document key with another")
    func dedupeKeepsPriorityWhenStableKeysConflict() async throws {
        let path = "/docs/Paper.pdf"
        let firstStableKey = "11111111-1111-1111-1111-111111111111"
        let secondStableKey = "22222222-2222-2222-2222-222222222222"
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "recents", displayName: "Recents", mode: .snapshot) { _ in
                [pdfStubItem(
                    id: "recents:paper", path: path, section: .recents,
                    storageKey: firstStableKey)]
            },
            StubProvider(id: "library", displayName: "Library", mode: .snapshot) { _ in
                [pdfStubItem(
                    id: "library:paper", path: path, section: .documents,
                    storageKey: secondStableKey)]
            },
        ])
        await engine.reload()

        let item = try #require(await engine.corpus.first)
        #expect(item.storageKey == firstStableKey)
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

    /// The debounce cancels the previous pass on every keystroke, and that
    /// cancellation propagates into any in-flight live provider. If the engine
    /// treated the resulting error like a source outage, a connected read-later
    /// account would flash "Read Later: cancelled" under the results of nearly
    /// every word typed — a broken-looking integration that is in fact working
    /// perfectly.
    @Test("A pass cancelled by the debounce is not reported as a broken source")
    func cancellationIsNotAFailure() async throws {
        let engine = HomeSearchEngine(providers: [HangingLiveProvider()])
        await engine.reload()

        let task = Task { await engine.results(query: "remote", now: Date()) }
        // Let the provider actually reach its suspension point, so cancellation
        // is observed INSIDE `items(matching:)` rather than before the task body
        // starts — otherwise the test could pass without exercising the catch.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        _ = await task.value

        #expect(await engine.failures.isEmpty)
    }

    /// The identity is the merge key, so a blank one is not merely a useless
    /// row — it is a row that swallows every OTHER blank-identity document in
    /// the library, and whose target can only fail to open. Every source can
    /// produce one (a corrupt recents record, a `meta.json` with no
    /// `last_known_path`, a web entry with no URL), which is why the guard
    /// lives in the engine rather than in the one provider that was known to
    /// need it.
    @Test("Items with no locator are dropped, not collapsed into one dead row")
    func dropsBlankIdentitiesFromEverySource() async {
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "recents", displayName: "Recents", mode: .snapshot) { _ in
                [
                    stubItem(id: "recents:1", identity: "", section: .recents, title: "Ghost one"),
                    stubItem(id: "recents:2", identity: "/a.pdf", section: .recents, title: "Real"),
                ]
            },
            StubProvider(id: "webpages", displayName: "Saved", mode: .snapshot) { _ in
                [stubItem(id: "webpages:1", identity: "   ", section: .webpages, title: "Ghost two")]
            },
        ])
        await engine.reload()

        let corpus = await engine.corpus
        #expect(corpus.map(\.id) == ["recents:2"])
    }

    /// Each source knows something the others do not: only the web library
    /// knows a page is bookmarked or has an offline snapshot, only the
    /// documents directory knows a file carries notes. Keeping the
    /// highest-priority row but discarding what the others knew would make the
    /// Recents row of a saved, annotated article claim it is neither.
    @Test("A row absorbs the badges of the duplicates it replaces")
    func mergesBadgesAcrossSources() async throws {
        let shared = "https://x.test/article"
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "recents", displayName: "Recents", mode: .snapshot) { _ in
                [stubItem(id: "recents:1", identity: shared, section: .recents, title: "Article")]
            },
            StubProvider(id: "webpages", displayName: "Saved", mode: .snapshot) { _ in
                [
                    stubItem(
                        id: "webpages:1", identity: shared, section: .webpages, title: "Article",
                        badges: [.saved, .offline])
                ]
            },
            StubProvider(id: "library", displayName: "Library", mode: .snapshot) { _ in
                [
                    stubItem(
                        id: "library:1", identity: shared, section: .documents, title: "Article",
                        badges: [.notes])
                ]
            },
        ])
        await engine.reload()

        let corpus = await engine.corpus
        let row = try #require(corpus.first)
        #expect(corpus.count == 1)
        // Still the recents row — dedupe priority is unchanged.
        #expect(row.id == "recents:1")
        #expect(row.section == .recents)
        // …but it now says everything the discarded rows knew.
        #expect(row.badges.contains(.saved))
        #expect(row.badges.contains(.offline))
        #expect(row.badges.contains(.notes))
    }

    /// A cancelled task group hands back whatever its children finished before
    /// the cancellation propagated. Committing that would install a corpus with
    /// documents silently missing AND record every unfinished source as broken
    /// — so an abandoned load must change nothing at all.
    @Test("A reload cancelled mid-flight leaves the previous corpus intact")
    func cancelledReloadChangesNothing() async throws {
        let engine = HomeSearchEngine(providers: [
            StallsAfterFirstLoadProvider(calls: CallCounter())
        ])
        await engine.reload()
        #expect(await engine.corpus.count == 1)

        let task = Task { await engine.reload() }
        // Let the provider reach its suspension point, so cancellation is
        // observed INSIDE the task group rather than before it starts.
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        await task.value

        #expect(await engine.corpus.map(\.id) == ["flip:1"])
        #expect(await engine.failures.isEmpty)
    }

    /// `reload()` speaks only for the snapshot providers and `results()` only
    /// for the live ones. When both used to assign the whole failure list, a
    /// corpus rebuild landing after a live query would erase a genuine
    /// read-later outage and the warning would vanish from under the results.
    @Test("Rebuilding the corpus does not erase a live source's outage")
    func snapshotReloadKeepsLiveFailure() async {
        let engine = HomeSearchEngine(providers: [
            StubProvider(id: "local", displayName: "Local", mode: .snapshot) { _ in
                [stubItem(id: "local:1", identity: "a", title: "Alpha")]
            },
            StubProvider(id: "later", displayName: "Read Later", mode: .live) { _ in
                throw StubError()
            },
        ])
        await engine.reload()
        _ = await engine.results(query: "alpha", now: Date())
        #expect(await engine.failures.count == 1)

        await engine.reload()
        #expect(await engine.failures.first?.hasPrefix("Read Later: ") == true)
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
