import Foundation
import Testing

@testable import Vellum

// Renaming a document or webpage (issue #62 follow-up).
//
// A title is stored in up to four places written by four subsystems, and the
// interesting failures are all "some of them agreed". Every store here is
// redirected to a temp directory or a scratch `UserDefaults` suite, so nothing
// touches the real library or the real recents list.

/// Redirects `DocumentDataStore` and `WebLibrary` at throwaway storage for the
/// life of one test, and puts them back after. A `class` with a `deinit`
/// because Swift Testing has no `tearDown` — the suite holds one and the
/// restore happens when the test's instance dies.
///
/// The recents domain is NOT handled here: it comes from the `.scratchDefaults`
/// trait, which scopes it to the test's own task instead of parking it in a
/// process-global this class would have to remember to restore (#102).
private final class ScratchStores {
    let root: URL

    init() {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vellum-rename-\(UUID().uuidString)")
        let documents = root.appendingPathComponent("documents")
        let web = root.appendingPathComponent("web")
        try? FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)

        DocumentDataStore.rootDirectoryOverride = documents
        WebLibrary.storeDirOverride = web
    }

    deinit {
        DocumentDataStore.rootDirectoryOverride = nil
        WebLibrary.storeDirOverride = nil
        try? FileManager.default.removeItem(at: root)
    }

    func seedRecents(_ entries: [RecentDocument]) {
        // Straight through the service so the on-disk shape is whatever the
        // real reader expects.
        for entry in entries.reversed() {
            RecentFilesService.record(
                DocumentInfo(
                    kind: entry.kind, pdfPath: entry.pdfPath, title: entry.title,
                    pageCount: entry.pageCount, docId: entry.docId))
        }
    }
}

private func recent(
    path: String, kind: DocumentKind = .pdf, title: String?, docId: String? = nil
) -> RecentDocument {
    RecentDocument(
        pdfPath: path, kind: kind, title: title, pageCount: 1,
        openedAt: ISO8601DateFormatter.recentTimestamp.string(from: Date()), docId: docId)
}

@Suite("Rename: title normalization")
struct DocumentRenameNormalizationTests {
    /// Blank means "stop overriding", never "the title is empty". An empty
    /// title renders as a nameless row that cannot be read, clicked with
    /// confidence, or found by search.
    @Test(
        "Blank input clears the override rather than storing an empty name",
        arguments: ["", "   ", "\n\t "])
    func blankClears(raw: String) {
        #expect(DocumentRenameService.normalized(raw) == nil)
    }

    @Test("Surrounding whitespace is not part of the name")
    func trims() {
        #expect(DocumentRenameService.normalized("  Attention  ") == "Attention")
        #expect(DocumentRenameService.normalized("Attention") == "Attention")
    }
}

@Suite("Rename: target mapping")
struct DocumentRenameTargetTests {
    /// A moved PDF's recents record is still filed under the path it was
    /// recorded at, so that — not the re-resolved one — is what the recents
    /// update has to key on. Getting this backwards would silently rename
    /// nothing for exactly the documents most likely to need it.
    @Test("A moved PDF renames against its recorded path, not its resolved one")
    func movedPdfUsesRecordedPath() {
        let item = HomeSearchItem(
            id: "recents:/new/paper.pdf",
            identity: "/new/paper.pdf",
            section: .recents,
            kind: .pdf,
            target: .file(path: "/new/paper.pdf", recordedPath: "/old/paper.pdf"),
            title: "Paper", subtitle: "paper.pdf", detail: "", tooltip: "/new/paper.pdf",
            date: nil, badges: [], canRevealInFinder: true,
            haystack: HomeSearchHaystack(title: "Paper", name: "paper.pdf", location: "/new/paper.pdf"),
            storageKey: "the-doc-id")

        let target = DocumentRenameService.Target(item: item)
        #expect(target.locator == "/new/paper.pdf")
        #expect(target.recordedPath == "/old/paper.pdf")
        #expect(target.storageKey == "the-doc-id")
        #expect(target.kind == .pdf)
    }

    @Test("A webpage renames against its URL")
    func webUsesUrl() {
        let url = "https://example.com/post"
        let item = HomeSearchItem(
            id: "webpages:\(url)", identity: url, section: .webpages, kind: .web,
            target: .url(url), title: "Post", subtitle: "example.com/post", detail: "",
            tooltip: url, date: nil, badges: [.saved], canRevealInFinder: false,
            haystack: HomeSearchHaystack(title: "Post", name: "example.com", location: url),
            storageKey: "abc123")

        let target = DocumentRenameService.Target(item: item)
        #expect(target.locator == url)
        #expect(target.recordedPath == url)
        #expect(target.kind == .web)
    }
}

/// `.serialized` for `ScratchStores`' remaining process-global directory
/// overrides; the recents domain is per-test via `.scratchDefaults`.
@Suite("Rename: persistence", .serialized, .scratchDefaults)
struct DocumentRenamePersistenceTests {
    private let stores = ScratchStores()

    /// `touch(document:)` is the other title writer and it rewrites
    /// `last_known_path` and `last_opened` too. Renaming must not disturb
    /// either — a rename is not a visit, and clobbering the path is the
    /// "locator no longer resolves" bug class this screen already had.
    @Test("Setting a title leaves the document's path and last-opened alone")
    func setTitleTouchesOnlyTheTitle() throws {
        let key = "0123abcd"
        let document = DocumentInfo(
            kind: .pdf, pdfPath: "/library/paper.pdf", title: "Original",
            pageCount: 3, docId: key)
        try DocumentDataStore.touch(document: document, force: true)

        let before = try #require(DocumentDataStore.loadMeta(forKey: key))
        #expect(DocumentDataStore.setTitle(forKey: key, title: "Renamed"))

        let after = try #require(DocumentDataStore.loadMeta(forKey: key))
        #expect(after.title == "Renamed")
        #expect(after.lastKnownPath == before.lastKnownPath)
        #expect(after.lastOpened == before.lastOpened)
    }

    @Test("Clearing a title removes it instead of writing an empty string")
    func setTitleClears() throws {
        let key = "89abcdef"
        try DocumentDataStore.touch(
            document: DocumentInfo(
                kind: .pdf, pdfPath: "/library/other.pdf", title: "Original",
                pageCount: 1, docId: key),
            force: true)

        #expect(DocumentDataStore.setTitle(forKey: key, title: "   "))
        let after = try #require(DocumentDataStore.loadMeta(forKey: key))
        #expect(after.title == nil)
    }

    @Test("Renaming a document with no metadata folder is a no-op, not a crash")
    func setTitleOnUnknownKey() {
        #expect(DocumentDataStore.setTitle(forKey: "deadbeef", title: "Nope") == false)
    }

    /// `record(_:)` is the only other way to change a recent's title, and it
    /// prepends and re-stamps `openedAt` — so renaming through it would jump
    /// the document to the top of the list and claim it was just opened.
    @Test("Renaming a recent keeps its position and its opened-at timestamp")
    func recentsUpdateInPlace() throws {
        stores.seedRecents([
            recent(path: "/a.pdf", title: "First"),
            recent(path: "/b.pdf", title: "Second"),
            recent(path: "/c.pdf", title: "Third"),
        ])
        let before = RecentFilesService.getRecent()
        #expect(before.map(\.pdfPath) == ["/a.pdf", "/b.pdf", "/c.pdf"])

        let after = RecentFilesService.updateTitle(path: "/b.pdf", title: "Renamed")

        #expect(after.map(\.pdfPath) == ["/a.pdf", "/b.pdf", "/c.pdf"])
        #expect(after.map(\.title) == ["First", "Renamed", "Third"])
        let renamed = try #require(after.first { $0.pdfPath == "/b.pdf" })
        let original = try #require(before.first { $0.pdfPath == "/b.pdf" })
        #expect(renamed.openedAt == original.openedAt)
    }

    @Test("Renaming a path that is not in the recents list changes nothing")
    func recentsUpdateUnknownPath() {
        stores.seedRecents([recent(path: "/a.pdf", title: "First")])
        let after = RecentFilesService.updateTitle(path: "/missing.pdf", title: "Nope")
        #expect(after.map(\.title) == ["First"])
    }

    @Test("Renaming a saved page rewrites the library record")
    func webLibraryRename() throws {
        let url = "https://example.com/post"
        try WebLibrary.withRecord(url: url, recordPath: WebLibrary.recordPath(
            forKey: WebLibrary.pageKey(try WebUrl.normalize(url)))) { record in
                record.saved = true
                record.title = "Original"
                record.savedAt = WebLibrary.rfc3339Now()
            }
        #expect(WebLibrary.listSaved().first?.title == "Original")

        try WebLibrary.setTitle(rawUrl: url, title: "Renamed")
        #expect(WebLibrary.listSaved().first?.title == "Renamed")

        try WebLibrary.setTitle(rawUrl: url, title: "  ")
        #expect(WebLibrary.listSaved().first?.title == nil)
    }

    /// The point of the service: one call, every store agrees afterwards.
    /// Updating a subset is worse than updating none, because whichever screen
    /// the user is not looking at keeps the old name.
    @Test("One rename updates the metadata, the recents entry and the saved record together")
    func renameFansOutToEveryStore() throws {
        let url = "https://example.com/article"
        let key = WebLibrary.pageKey(try WebUrl.normalize(url))

        try DocumentDataStore.touch(
            document: DocumentInfo(
                kind: .web, pdfPath: url, title: "Original", pageCount: nil, docId: key),
            force: true)
        try WebLibrary.withRecord(url: url, recordPath: WebLibrary.recordPath(forKey: key)) {
            record in
            record.saved = true
            record.title = "Original"
            record.savedAt = WebLibrary.rfc3339Now()
        }
        stores.seedRecents([recent(path: url, kind: .web, title: "Original")])

        let target = DocumentRenameService.Target(
            kind: .web, locator: url, recordedPath: url, storageKey: key)
        #expect(DocumentRenameService.apply(target, title: "Renamed"))

        #expect(DocumentDataStore.loadMeta(forKey: key)?.title == "Renamed")
        #expect(WebLibrary.listSaved().first?.title == "Renamed")
        #expect(RecentFilesService.getRecent().first?.title == "Renamed")
    }

    /// A PDF that was never annotated has no `documents/<key>/` folder, and a
    /// document that is not in the recents list has no entry there. Neither is
    /// an error — the rename still has to land wherever it CAN.
    @Test("A rename that only one store can accept still reports success")
    func renamePartialStoresStillSucceeds() {
        stores.seedRecents([recent(path: "/only-a-recent.pdf", title: "Original")])
        let target = DocumentRenameService.Target(
            kind: .pdf, locator: "/only-a-recent.pdf", recordedPath: "/only-a-recent.pdf",
            storageKey: "no-such-key")

        #expect(DocumentRenameService.apply(target, title: "Renamed"))
        #expect(RecentFilesService.getRecent().first?.title == "Renamed")
    }

    @Test("A rename with nothing at all to write reports that it wrote nothing")
    func renameWithNoStores() {
        let target = DocumentRenameService.Target(
            kind: .pdf, locator: "/nowhere.pdf", recordedPath: nil, storageKey: nil)
        #expect(DocumentRenameService.apply(target, title: "Renamed") == false)
    }
}

@MainActor
@Suite("Rename: availability")
struct DocumentRenameAvailabilityTests {
    private func item(section: HomeSearchSection) -> HomeSearchItem {
        HomeSearchItem(
            id: "x", identity: "x", section: section, kind: .web, target: .url("x"),
            title: "X", subtitle: "x", detail: "", tooltip: "x", date: nil, badges: [],
            canRevealInFinder: false,
            haystack: HomeSearchHaystack(title: "X", name: "x", location: "x"))
    }

    /// A remote read-later article has no local record to write, so offering
    /// rename would show a change that silently vanished on the next refresh.
    @Test("Everything local can be renamed; a remote read-later result cannot")
    func canRename() {
        let store = HomeSearchStore(engine: HomeSearchEngine(providers: []))
        #expect(store.canRename(item(section: .recents)))
        #expect(store.canRename(item(section: .documents)))
        #expect(store.canRename(item(section: .webpages)))
        #expect(!store.canRename(item(section: .readLater)))
    }
}
