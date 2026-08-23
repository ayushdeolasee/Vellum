import Foundation

// Sources the home screen searches.
//
// The welcome screen never talks to `RecentFilesService`, `WebLibrary`, or
// `DocumentDataStore` directly any more — it asks `HomeSearchEngine`, which
// asks providers. That indirection exists for exactly one reason: issue #62
// wants the user to be able to "search more naturally from their connected
// read-later applications". That source now exists —
// `ReadLaterSearchProvider`, fed by `IntegrationsStore` and appended after the
// local providers by `HomeSearchStore` — and the entire home-screen UI —
// ranking, sections, keyboard navigation, empty states — works unchanged.

/// How the engine drives a provider.
enum HomeSearchProviderMode: Hashable, Sendable {
    /// The provider hands over its whole corpus once and the app matches
    /// locally. Right for the on-disk sources: they are small (tens to low
    /// hundreds of entries), so local matching is instant, offline, and ranked
    /// consistently against every other source.
    case snapshot
    /// The provider answers each debounced query itself. Right for a hosted
    /// read-later account, where the corpus lives on someone else's server, may
    /// be tens of thousands of articles, and has its own relevance engine worth
    /// deferring to.
    case live
}

/// A source of home-screen results.
///
/// `Sendable` and free of actor isolation on purpose: `items(matching:)` is
/// called from `HomeSearchEngine` (an actor), so implementations run off the
/// main thread and may block on disk or the network without janking the UI.
protocol HomeSearchProvider: Sendable {
    /// Stable, unique identifier — also the prefix of every item id it emits.
    var id: String { get }
    /// Human-readable name, shown when this source fails to load.
    var displayName: String { get }
    var mode: HomeSearchProviderMode { get }

    /// Items for `query`. Snapshot providers ignore the argument (the engine
    /// calls them exactly once, with `""`); live providers must honor it.
    func items(matching query: String) async throws -> [HomeSearchItem]
}

extension HomeSearchProvider {
    /// Most sources are local, so snapshot is the default a conformer gets for
    /// free.
    var mode: HomeSearchProviderMode { .snapshot }
}

// MARK: - Recently opened documents

/// The `RecentFilesService` list (max 8, PDFs and webpages alike).
struct RecentDocumentsSearchProvider: HomeSearchProvider {
    let id = "recents"
    let displayName = "Recents"

    /// Injected so the item-building logic can be unit-tested against fixtures
    /// without a real UserDefaults list or files on disk.
    private let load: @Sendable () -> [RecentDocument]
    private let resolvePath: @Sendable (RecentDocument) -> String
    private let fileExists: @Sendable (String) -> Bool

    init(
        load: @escaping @Sendable () -> [RecentDocument] = { RecentFilesService.getRecent() },
        // iPad: the container UUID in a stored path changes across reinstalls, so
        // fall back to the same-named file in the current library directory before
        // giving up. `RecentFilesService.resolvedPath` still runs first — it is the
        // docId-based re-resolve for a MOVED document (design §7) — and this only
        // rescues the path when that answer no longer exists on disk.
        resolvePath: @escaping @Sendable (RecentDocument) -> String = defaultRecentDocumentPath,
        fileExists: @escaping @Sendable (String) -> Bool = defaultRecentDocumentExists
    ) {
        self.load = load
        self.resolvePath = resolvePath
        self.fileExists = fileExists
    }

    func items(matching _: String) async throws -> [HomeSearchItem] {
        let now = Date()
        return load().map { entry in
            // A moved PDF re-resolves to its current location via the stable
            // docId; web entries and dead entries come back unchanged.
            let resolved = resolvePath(entry)
            let onDisk = entry.kind == .pdf && fileExists(resolved)
            let name = entry.kind == .web
                ? RecentFilesService.webpageDisplayName(for: entry.pdfPath)
                : RecentFilesService.fileName(for: entry.pdfPath)
            let title = HomeSearchItemBuilder.title(entry.title, fallback: name)
            let date = WebLibrary.parseRfc3339(entry.openedAt)

            var subtitle = name
            if entry.kind == .pdf, let count = entry.pageCount, count != 0 {
                subtitle += " · \(count) \(count == 1 ? "page" : "pages")"
            }
            var badges: HomeSearchBadges = []
            if entry.kind == .pdf, !onDisk { badges.insert(.missing) }

            return HomeSearchItem(
                id: "\(id):\(resolved)",
                identity: HomeSearchItemBuilder.identity(resolved, kind: entry.kind),
                section: .recents,
                kind: entry.kind,
                target: entry.kind == .web
                    ? .url(resolved)
                    : .file(path: resolved, recordedPath: entry.pdfPath),
                title: title,
                subtitle: subtitle,
                detail: HomeSearchDateLabel.short(for: date, now: now),
                tooltip: resolved,
                date: date,
                badges: badges,
                canRevealInFinder: onDisk,
                haystack: HomeSearchHaystack(
                    title: title, name: name, location: resolved, extra: "recent"),
                // The stamped docId when the file has one; otherwise the same
                // path hash the stores fell back to when it was last opened.
                storageKey: entry.docId.flatMap { $0.isEmpty ? nil : $0 }
                    ?? DocumentIdentity.sha256Hex(entry.pdfPath))
        }
    }
}

#if os(iOS)
private let defaultRecentDocumentPath: @Sendable (RecentDocument) -> String = { entry in
    let byIdentity = RecentFilesService.resolvedPath(for: entry)
    guard entry.kind == .pdf else { return byIdentity }
    return DocumentImport.resolveExistingPath(byIdentity) ?? byIdentity
}
private let defaultRecentDocumentExists: @Sendable (String) -> Bool = {
    DocumentImport.resolveExistingPath($0) != nil
}
#else
private let defaultRecentDocumentPath: @Sendable (RecentDocument) -> String = {
    RecentFilesService.resolvedPath(for: $0)
}
private let defaultRecentDocumentExists: @Sendable (String) -> Bool = {
    FileManager.default.fileExists(atPath: $0)
}
#endif

// MARK: - Saved webpages

/// Pages the user explicitly saved to the web library (`WebLibrary.listSaved`).
struct SavedWebpagesSearchProvider: HomeSearchProvider {
    let id = "webpages"
    let displayName = "Saved webpages"

    private let load: @Sendable () async throws -> [WebLibraryEntry]
    private let isCapturedUnread: @Sendable (String) async -> Bool

    /// Reads `WebLibrary` directly rather than going through
    /// `SessionService.listSavedWebpages()`: that method's only job is to hop
    /// the same call off the main thread, and this provider is already off it.
    init(load: @escaping @Sendable () async throws -> [WebLibraryEntry] = {
        WebLibrary.listSaved()
    }, isCapturedUnread: @escaping @Sendable (String) async -> Bool = { key in
        CapturedUnreadLedger.shared.isUnread(forKey: key)
    }) {
        self.load = load
        self.isCapturedUnread = isCapturedUnread
    }

    func items(matching _: String) async throws -> [HomeSearchItem] {
        let now = Date()
        let entries = try await load()
        var items: [HomeSearchItem] = []
        items.reserveCapacity(entries.count)
        for entry in entries {
            let name = RecentFilesService.webpageDisplayName(for: entry.url)
            let title = HomeSearchItemBuilder.title(entry.title, fallback: name)
            let date = WebLibrary.parseRfc3339(entry.savedAt)
            var badges: HomeSearchBadges = [.saved]
            if entry.hasSnapshot { badges.insert(.offline) }
            if await isCapturedUnread(WebLibrary.pageKey(entry.url)) {
                badges.insert(.capturedUnread)
            }

            items.append(HomeSearchItem(
                id: "\(id):\(entry.url)",
                identity: HomeSearchItemBuilder.identity(entry.url, kind: .web),
                section: .webpages,
                kind: .web,
                target: .url(entry.url),
                title: title,
                subtitle: name,
                detail: HomeSearchDateLabel.short(for: date, now: now),
                tooltip: entry.url,
                date: date,
                badges: badges,
                canRevealInFinder: false,
                haystack: HomeSearchHaystack(
                    title: title,
                    name: HomeSearchItemBuilder.host(of: entry.url) ?? name,
                    location: entry.url,
                    extra: "saved webpage"),
                // Web documents key on the sha256 of their normalized URL,
                // which is exactly what `WebLibrary.pageKey` computes.
                storageKey: WebLibrary.pageKey(entry.url)))
        }
        return items
    }
}

// MARK: - Library documents

/// Documents that own a `documents/<key>/` folder — i.e. anything the user has
/// written a note on or held an AI conversation about. This is the source that
/// reaches past the 8-entry recents list into the user's real back catalogue,
/// and it is the main reason the new home screen can find things the old one
/// could not.
struct LibraryDocumentsSearchProvider: HomeSearchProvider {
    let id = "library"
    let displayName = "Library"

    private let load: @Sendable () async throws -> [DocumentDataStore.DocumentMetaEntry]
    private let fileExists: @Sendable (String) -> Bool

    init(
        load: @escaping @Sendable () async throws -> [DocumentDataStore.DocumentMetaEntry],
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.load = load
        self.fileExists = fileExists
    }

    init(
        coordinator: StorageCoordinator,
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.init(
            load: { try await DocumentDataStore.listDocumentMetas(coordinator: coordinator) },
            fileExists: fileExists)
    }

    init(
        fileExists: @escaping @Sendable (String) -> Bool = {
            FileManager.default.fileExists(atPath: $0)
        }
    ) {
        self.init(load: { DocumentDataStore.listDocumentMetas() }, fileExists: fileExists)
    }

    func items(matching _: String) async throws -> [HomeSearchItem] {
        let now = Date()
        return try await load().compactMap { entry -> HomeSearchItem? in
            let meta = entry.meta
            let isWeb = meta.kind == DocumentKind.web.rawValue
            let kind: DocumentKind = isWeb ? .web : .pdf
            // For web documents `last_known_path` holds the normalized URL —
            // DocumentInfo.pdfPath is the generic document URI, not a file path.
            let locator = meta.lastKnownPath
            // A meta.json can carry a blank last_known_path (StorageInventory
            // guards the same case). Nothing is searchable or openable without
            // a locator, so there is no item to build. `HomeSearchEngine`
            // drops blank identities too — that is the guarantee that covers
            // every source — but this is the one provider whose upstream data
            // is known to contain them, so it is cheaper to never build the
            // item than to build it and have the engine discard it.
            guard !locator.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let name = isWeb
                ? RecentFilesService.webpageDisplayName(for: locator)
                : RecentFilesService.fileName(for: locator)
            let title = HomeSearchItemBuilder.title(meta.title, fallback: name)
            let date = WebLibrary.parseRfc3339(meta.lastOpened)
            let onDisk = !isWeb && fileExists(locator)

            var badges: HomeSearchBadges = []
            if entry.hasUserData { badges.insert(.notes) }
            if !isWeb, !onDisk { badges.insert(.missing) }

            return HomeSearchItem(
                id: "\(id):\(entry.key)",
                identity: HomeSearchItemBuilder.identity(locator, kind: kind),
                section: isWeb ? .webpages : .documents,
                kind: kind,
                target: isWeb ? .url(locator) : .file(path: locator, recordedPath: locator),
                title: title,
                subtitle: name,
                detail: HomeSearchDateLabel.short(for: date, now: now),
                tooltip: locator,
                date: date,
                badges: badges,
                canRevealInFinder: onDisk,
                haystack: HomeSearchHaystack(
                    title: title,
                    name: isWeb ? (HomeSearchItemBuilder.host(of: locator) ?? name) : name,
                    location: locator,
                    extra: entry.hasUserData ? "notes annotations library" : "library"),
                // This provider IS the documents directory, so the folder
                // name is the key by definition.
                storageKey: entry.key)
        }
    }
}

// MARK: - Shared item-building helpers

/// The few conventions every provider has to agree on. Factored out so two
/// sources describing the same document produce the same dedupe identity and
/// the same fallback title.
enum HomeSearchItemBuilder {
    /// A source's own title when it has a non-blank one, else the short name.
    static func title(_ raw: String?, fallback: String) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    /// The cross-provider dedupe key.
    ///
    /// URLs go through `WebUrl.normalize` — the same canonicalization that
    /// produces the web store's on-disk key — so that the three spellings of
    /// one article the sources can disagree about all collapse to one row:
    /// the recents list keeps whatever the user typed ("example.com/post"),
    /// the web library keeps the normalized form, and a link arriving with a
    /// `?utm_source=…` tail or a `#section` fragment is the same page again.
    /// Lowercasing the whole URL (the obvious cheap alternative) is actively
    /// wrong: it folds `/Foo` and `/foo`, which most servers treat as two
    /// different pages, while still failing to reconcile the scheme and the
    /// tracking parameters. Normalization throws on genuinely unparseable
    /// input, in which case the raw locator is its own identity — worst case
    /// two rows for one page, never two pages merged into one.
    ///
    /// File paths are left verbatim: two paths differing only in case are two
    /// different documents on a case-sensitive volume.
    static func identity(_ locator: String, kind: DocumentKind) -> String {
        guard kind == .web else { return locator }
        return (try? WebUrl.normalize(locator)) ?? locator.lowercased()
    }

    /// Host of a URL, for the "name" haystack field — typing "arxiv" should
    /// rank a page ON arxiv.org above one that merely links to it in a query
    /// string.
    static func host(of url: String) -> String? {
        guard let host = URL(string: url)?.host, !host.isEmpty else { return nil }
        return host
    }
}
