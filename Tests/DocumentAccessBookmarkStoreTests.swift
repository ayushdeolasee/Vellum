import Foundation
import CoreGraphics
import Testing

@testable import Vellum

@Suite("Document access bookmarks")
struct DocumentAccessBookmarkStoreTests {
    @Test("Local bookmark store round-trips entries atomically")
    func localStoreRoundTrips() throws {
        try withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let data = Data("bookmark-a".utf8)

            try store.upsert(key: "doc-a", lastKnownPath: "/external/a.pdf", bookmarkData: data)

            let restored = try #require(store.entry(forKey: "doc-a"))
            #expect(restored.lastKnownPath == "/external/a.pdf")
            #expect(restored.bookmarkData == data)
            #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        }
    }

    @Test("Corrupt bookmark JSON is quarantined and ignored")
    func corruptStoreIsQuarantined() throws {
        try withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try Data("{not-json".utf8).write(to: store.fileURL)

            #expect(store.entry(forKey: "missing") == nil)
            #expect(FileManager.default.fileExists(atPath: store.corruptFileURL.path))
            #expect(FileManager.default.fileExists(atPath: store.fileURL.path) == false)
        }
    }

    @Test("Removing a bookmark drops only that key")
    func removeDropsOneEntry() throws {
        try withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            try store.upsert(key: "a", lastKnownPath: "/a.pdf", bookmarkData: Data("a".utf8))
            try store.upsert(key: "b", lastKnownPath: "/b.pdf", bookmarkData: Data("b".utf8))

            try store.remove(key: "a")

            #expect(store.entry(forKey: "a") == nil)
            #expect(store.entry(forKey: "b")?.bookmarkData == Data("b".utf8))
        }
    }

    @Test("A stale bookmark is refreshed after a validated restore")
    func staleBookmarkRefreshes() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let adapter = RecordingDocumentAccessAdapter()
            let oldData = Data("old-bookmark".utf8)
            let docId = "11111111-2222-3333-4444-555555555555"
            let moved = external.appendingPathComponent("moved.pdf")
            try makeTestPDF(at: moved, docId: docId)
            adapter.resolvedBookmarks[oldData] = (moved, true)
            try store.upsert(key: docId, lastKnownPath: "/external/old.pdf", bookmarkData: oldData)
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            let opened = try await resolver.restoreSavedPDF(
                DocumentInfo(kind: .pdf, pdfPath: "/external/old.pdf", title: "Old",
                             pageCount: 1, lastPage: 1, docId: docId),
                sessionId: "session",
                resolveExistingPath: { _ in nil }
            ) { path, _ in
                #expect(path.hasPrefix(library.path + "/"))
                #expect(path != moved.path)
                return DocumentInfo(kind: .pdf, pdfPath: path, title: "Moved",
                                    pageCount: 1, lastPage: 1, docId: docId)
            }

            #expect(opened.bookmarkData == nil)
            #expect(store.entry(forKey: docId)?.lastKnownPath == opened.pdfPath)
            #expect(FileManager.default.fileExists(atPath: opened.pdfPath))
        }
    }

    @Test("Picked external PDFs are copied local before open and picker scope closes")
    func pickedExternalCopiesLocalBeforeOpen() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let adapter = RecordingDocumentAccessAdapter()
            let url = external.appendingPathComponent("lifetime.pdf")
            try makeTestPDF(at: url, docId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            _ = try await resolver.openPickedPDF(url: url, sessionId: "session") { path, _ in
                #expect(path.hasPrefix(library.path + "/"))
                #expect(path != url.path)
                #expect(adapter.isActive(url.path) == false)
                await Task.yield()
                #expect(adapter.isActive(url.path) == false)
                return DocumentInfo(kind: .pdf, pdfPath: path, title: nil,
                                    pageCount: 1, lastPage: 1,
                                    docId: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
            }

            #expect(adapter.startCount(for: url.path) == 1)
            #expect(adapter.stopCount(for: url.path) == 1)
            #expect(adapter.isActive(url.path) == false)
            #expect(store.entry(forKey: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")?.lastKnownPath.hasPrefix(library.path) == true)
        }
    }

    @Test("Saved-tab restore uses the local bookmark when the raw path is unavailable")
    @MainActor
    func savedRestoreUsesLocalBookmark() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let adapter = RecordingDocumentAccessAdapter()
            let docId = "22222222-3333-4444-5555-666666666666"
            let bookmark = Data("restore-bookmark".utf8)
            let live = external.appendingPathComponent("live.pdf")
            try makeTestPDF(at: live, docId: docId)
            adapter.resolvedBookmarks[bookmark] = (live, false)
            try store.upsert(key: docId, lastKnownPath: "/gone/raw.pdf", bookmarkData: bookmark)
            let sessions = RecordingAccessSessionService(openDocId: docId)
            let app = AppStore(
                sessions: sessions,
                documentAccess: DocumentAccessResolver(
                    store: store,
                    adapter: adapter,
                    libraryDirectory: { library },
                    appOwnedRoots: { [library] }))
            let descriptor = TabDescriptor(
                document: DocumentInfo(kind: .pdf, pdfPath: "/gone/raw.pdf", title: "Saved",
                                       pageCount: 1, lastPage: 1, docId: docId),
                currentPage: 1,
                zoom: 1,
                mode: .view)

            await app.restoreTabs([descriptor], activeIndex: 0)

            #expect(sessions.openedPaths.count == 1)
            #expect(sessions.openedPaths.first?.hasPrefix(library.path + "/") == true)
            #expect(app.document?.pdfPath == sessions.openedPaths.first)
        }
    }

    @Test("Bookmark creation failure after open does not close a usable local PDF")
    func bookmarkCreationFailureRemainsOpen() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let local = library.appendingPathComponent("local.pdf")
            try makeTestPDF(at: local, docId: nil)
            let adapter = RecordingDocumentAccessAdapter()
            adapter.failBookmarkCreation = true
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            let opened = try await resolver.openPickedPDF(url: local, sessionId: "session") { path, _ in
                DocumentInfo(kind: .pdf, pdfPath: path, title: nil, pageCount: 1, lastPage: 1)
            }

            #expect(opened.pdfPath == local.path)
            #expect(store.entry(forKey: DocumentIdentity.sha256Hex(local.path)) == nil)
        }
    }

    @Test("Failed external open removes the staged library copy")
    func failedExternalOpenRemovesStagedCopy() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let picked = external.appendingPathComponent("failed.pdf")
            try makeTestPDF(at: picked, docId: nil)
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: RecordingDocumentAccessAdapter(),
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            do {
                _ = try await resolver.openPickedPDF(url: picked, sessionId: "session") { _, _ in
                    throw TestOpenError.failed
                }
                Issue.record("Expected open failure")
            } catch DocumentAccessError.unavailable {
                #expect((try? FileManager.default.contentsOfDirectory(atPath: library.path))?.isEmpty ?? true)
            } catch {
                Issue.record("Wrong error: \(error)")
            }
        }
    }

    @Test("Restore falls back after bad bookmark candidate and closes failed session")
    func restoreFallsBackAfterBadBookmark() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let adapter = RecordingDocumentAccessAdapter()
            let docId = "55555555-6666-7777-8888-999999999999"
            let bad = external.appendingPathComponent("bad.pdf")
            let raw = library.appendingPathComponent("raw.pdf")
            try makeTestPDF(at: bad, docId: docId)
            try makeTestPDF(at: raw, docId: docId)
            let bookmark = Data("bad-bookmark".utf8)
            adapter.resolvedBookmarks[bookmark] = (bad, false)
            try store.upsert(key: docId, lastKnownPath: "/gone/bad.pdf", bookmarkData: bookmark)
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })
            var openedPaths: [String] = []
            var closed: [String] = []

            let opened = try await resolver.restoreSavedPDF(
                DocumentInfo(kind: .pdf, pdfPath: raw.path, title: "Raw",
                             pageCount: 1, lastPage: 1, docId: docId),
                sessionId: "session",
                resolveExistingPath: { _ in nil }
            ) { path, _ in
                openedPaths.append(path)
                if path.contains("bad") {
                    throw TestOpenError.failed
                }
                return DocumentInfo(kind: .pdf, pdfPath: path, title: nil,
                                    pageCount: 1, lastPage: 1, docId: docId)
            } close: { sessionId in
                closed.append(sessionId)
            }

            #expect(opened.pdfPath == raw.path)
            #expect(openedPaths.count == 2)
            #expect(closed == ["session"])
            let libraryFiles = (try? FileManager.default.contentsOfDirectory(atPath: library.path)) ?? []
            #expect(libraryFiles.contains("bad.pdf") == false)
        }
    }

    @Test("Post-open identity mismatch closes the failed restore candidate")
    func postOpenIdentityMismatchClosesSession() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let local = library.appendingPathComponent("wrong.pdf")
            let expected = "66666666-7777-8888-9999-aaaaaaaaaaaa"
            try makeTestPDF(at: local, docId: expected)
            let adapter = RecordingDocumentAccessAdapter()
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })
            var closed: [String] = []

            do {
                _ = try await resolver.restoreSavedPDF(
                    DocumentInfo(kind: .pdf, pdfPath: local.path, title: nil,
                                 pageCount: 1, lastPage: 1, docId: expected),
                    sessionId: "session",
                    resolveExistingPath: { _ in nil }
                ) { path, _ in
                    DocumentInfo(kind: .pdf, pdfPath: path, title: nil,
                                 pageCount: 1, lastPage: 1,
                                 docId: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")
                } close: { sessionId in
                    closed.append(sessionId)
                }
                Issue.record("Expected identity mismatch")
            } catch DocumentAccessError.unavailable {
                #expect(closed == ["session"])
            } catch {
                Issue.record("Wrong error: \(error)")
            }
        }
    }

    @Test("Relink validates identity and commits metadata plus bookmark")
    func relinkCommitsMatch() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch.appendingPathComponent("access"))
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let documents = scratch.appendingPathComponent("documents")
            DocumentDataStore.rootDirectoryOverride = documents
            defer { DocumentDataStore.rootDirectoryOverride = nil }
            let adapter = RecordingDocumentAccessAdapter()
            let key = "33333333-4444-5555-6666-777777777777"
            let oldLocal = library.appendingPathComponent("old.pdf")
            try makeTestPDF(at: oldLocal, docId: key)
            let oldPath = oldLocal.path
            let newURL = external.appendingPathComponent("new.pdf")
            try makeTestPDF(at: newURL, docId: key)
            try DocumentDataStore.saveScratchpad(forKey: key, text: "notes")
            try DocumentDataStore.touch(
                document: DocumentInfo(kind: .pdf, pdfPath: oldPath, title: "Doc",
                                       pageCount: 1, lastPage: 1, docId: key))
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            let result = await resolver.relink(key: key, isDocIdKeyed: true, to: newURL)

            guard case .success = result else {
                Issue.record("Expected relink to succeed")
                return
            }
            let relinkedPath = try #require(DocumentDataStore.loadMeta(forKey: key)?.lastKnownPath)
            #expect(relinkedPath.hasPrefix(library.path + "/"))
            #expect(relinkedPath != newURL.path)
            #expect(store.entry(forKey: key)?.lastKnownPath == relinkedPath)
            #expect(adapter.startCount(for: newURL.path) == 1)
            #expect(adapter.stopCount(for: newURL.path) == 1)
            #expect(FileManager.default.fileExists(atPath: oldPath) == false)
        }
    }

    @Test("Relink mismatch preserves old metadata and bookmark")
    func relinkMismatchPreservesState() async throws {
        try await withAccessScratch { scratch in
            let store = DocumentAccessBookmarkStore(directory: scratch.appendingPathComponent("access"))
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let documents = scratch.appendingPathComponent("documents")
            DocumentDataStore.rootDirectoryOverride = documents
            defer { DocumentDataStore.rootDirectoryOverride = nil }
            let adapter = RecordingDocumentAccessAdapter()
            let key = "44444444-5555-6666-7777-888888888888"
            let oldPath = "/external/old.pdf"
            let newURL = external.appendingPathComponent("wrong.pdf")
            let oldBookmark = Data("old-bookmark".utf8)
            try makeTestPDF(at: newURL, docId: "99999999-0000-0000-0000-000000000000")
            try store.upsert(key: key, lastKnownPath: oldPath, bookmarkData: oldBookmark)
            try DocumentDataStore.saveScratchpad(forKey: key, text: "notes")
            try DocumentDataStore.touch(
                document: DocumentInfo(kind: .pdf, pdfPath: oldPath, title: "Doc",
                                       pageCount: 1, lastPage: 1, docId: key))
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: adapter,
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            let result = await resolver.relink(key: key, isDocIdKeyed: true, to: newURL)

            guard case .failure(.identityMismatch(expected: key, found: "99999999-0000-0000-0000-000000000000")) = result else {
                Issue.record("Expected identity mismatch, got \(String(describing: result))")
                return
            }
            #expect(DocumentDataStore.loadMeta(forKey: key)?.lastKnownPath == oldPath)
            #expect(store.entry(forKey: key)?.bookmarkData == oldBookmark)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: library.path))?.isEmpty ?? true)
        }
    }

    @Test("Relink persistence failure rolls metadata back and removes staged copy")
    func relinkPersistenceFailureCleansStagedCopy() async throws {
        try await withAccessScratch { scratch in
            let accessPath = scratch.appendingPathComponent("access")
            try Data("not a directory".utf8).write(to: accessPath)
            let store = DocumentAccessBookmarkStore(directory: accessPath)
            let library = scratch.appendingPathComponent("library", isDirectory: true)
            let external = scratch.appendingPathComponent("external", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let documents = scratch.appendingPathComponent("documents")
            DocumentDataStore.rootDirectoryOverride = documents
            defer { DocumentDataStore.rootDirectoryOverride = nil }
            let key = "77777777-8888-9999-aaaa-bbbbbbbbbbbb"
            let oldPath = "/external/old.pdf"
            let picked = external.appendingPathComponent("picked.pdf")
            try makeTestPDF(at: picked, docId: key)
            try DocumentDataStore.saveScratchpad(forKey: key, text: "notes")
            try DocumentDataStore.touch(
                document: DocumentInfo(kind: .pdf, pdfPath: oldPath, title: "Doc",
                                       pageCount: 1, lastPage: 1, docId: key))
            let resolver = DocumentAccessResolver(
                store: store,
                adapter: RecordingDocumentAccessAdapter(),
                libraryDirectory: { library },
                appOwnedRoots: { [library] })

            let result = await resolver.relink(key: key, isDocIdKeyed: true, to: picked)

            guard case .failure(.storeUnavailable) = result else {
                Issue.record("Expected store failure, got \(String(describing: result))")
                return
            }
            #expect(DocumentDataStore.loadMeta(forKey: key)?.lastKnownPath == oldPath)
            #expect((try? FileManager.default.contentsOfDirectory(atPath: library.path))?.isEmpty ?? true)
        }
    }

    @Test("Synced document metadata never serializes bookmark bytes")
    func syncedMetaContainsNoBookmarkBytes() throws {
        let meta = DocumentDataStore.Meta(
            version: 1,
            kind: "pdf",
            title: "Doc",
            lastKnownPath: "/external/doc.pdf",
            lastOpened: "2026-08-04T00:00:00Z")
        let data = try WebLibrary.jsonEncoderPretty.encode(meta)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(json.contains("bookmark") == false)
        #expect(json.contains("bookmark_data") == false)
        #expect(json.contains(Data("secret-bookmark".utf8).base64EncodedString()) == false)
    }
}

private enum TestOpenError: Error {
    case failed
}

private func makeTestPDF(at url: URL, docId: String?) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true)
    var mediaBox = CGRect(x: 0, y: 0, width: 72, height: 72)
    let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil)!
    context.beginPDFPage(nil)
    context.endPDFPage()
    context.closePDF()
    if let docId {
        try PdfMetadata.stampDocumentId(atPath: url.path, id: docId)
    }
}

private func withAccessScratch<R>(_ body: (URL) throws -> R) throws -> R {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellum-access-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    return try body(scratch)
}

@MainActor
private func withAccessScratch<R>(_ body: (URL) async throws -> R) async throws -> R {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("vellum-access-\(UUID().uuidString.lowercased())", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    return try await body(scratch)
}

private final class RecordingDocumentAccessAdapter: DocumentAccessAdapter, @unchecked Sendable {
    var bookmarksByPath: [String: Data] = [:]
    var resolvedBookmarks: [Data: (url: URL, isStale: Bool)] = [:]
    var documentIds: [String: String?] = [:]
    var failBookmarkCreation = false
    private var activePaths: Set<String> = []
    private var starts: [String] = []
    private var stops: [String] = []

    func makeBookmark(for url: URL, access: DocumentBookmarkAccess) throws -> Data {
        if failBookmarkCreation {
            throw DocumentAccessError.storeUnavailable("bookmark failed")
        }
        return bookmarksByPath[url.path] ?? Data("bookmark:\(url.path)".utf8)
    }

    func resolveBookmark(_ data: Data, access: DocumentBookmarkAccess) throws -> (url: URL, isStale: Bool) {
        guard let resolved = resolvedBookmarks[data] else {
            throw DocumentAccessError.unavailable("unresolved bookmark")
        }
        return resolved
    }

    func startAccessing(_ url: URL) -> Bool {
        starts.append(url.path)
        activePaths.insert(url.path)
        return true
    }

    func stopAccessing(_ url: URL) {
        stops.append(url.path)
        activePaths.remove(url.path)
    }

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func documentId(atPath path: String) -> String? {
        if let explicit = documentIds[path] {
            return explicit
        }
        return PdfMetadata.documentId(atPath: path)
    }

    func isActive(_ path: String) -> Bool {
        activePaths.contains(path)
    }

    func startCount(for path: String) -> Int {
        starts.filter { $0 == path }.count
    }

    func stopCount(for path: String) -> Int {
        stops.filter { $0 == path }.count
    }
}

@MainActor
private final class RecordingAccessSessionService: SessionService {
    var openedPaths: [String] = []
    var closedSessionIds: [String] = []
    let openDocId: String?

    init(openDocId: String? = nil) {
        self.openDocId = openDocId
    }

    func openFile(path: String, sessionId: String) async throws -> DocumentInfo {
        openedPaths.append(path)
        return DocumentInfo(
            kind: .pdf,
            pdfPath: path,
            title: URL(fileURLWithPath: path).lastPathComponent,
            pageCount: 1,
            lastPage: 1,
            docId: openDocId)
    }

    func openWebDocument(url: String, sessionId: String) async throws -> DocumentInfo {
        DocumentInfo(kind: .web, pdfPath: url, title: nil, pageCount: nil, lastPage: nil)
    }

    func openVellumwebFile(path: String, sessionId: String) async throws -> DocumentInfo {
        try await openFile(path: path, sessionId: sessionId)
    }

    func saveFile(sessionId: String) async throws {}
    func closeFile(sessionId: String) async throws {
        closedSessionIds.append(sessionId)
    }
    func readPdfBytes(sessionId: String) async throws -> Data { Data() }
    func setWebpageSaved(sessionId: String, saved: Bool) async throws {}
    func getWebpageSaved(sessionId: String) async throws -> Bool { false }
    func listSavedWebpages() async throws -> [WebLibraryEntry] { [] }
    func removeSavedWebpage(url: String) async throws {}
    func exportVellumweb(
        sessionId: String,
        destPath: String,
        pages: [WebPageText]
    ) async throws -> VellumwebExportSummary {
        VellumwebExportSummary(path: destPath, bytes: 0, assetCount: 0, assetsSkipped: 0)
    }
    func archiveWebpageDefault(
        sessionId: String,
        pages: [WebPageText],
        expectedUrl: String
    ) async throws -> Bool { false }
    func getAnnotations(sessionId: String, pageNumber: Int?) async throws -> [Annotation] { [] }
    func createAnnotation(sessionId: String, input: CreateAnnotationInput) async throws -> Annotation {
        Annotation(
            id: "annotation",
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color,
            content: input.content,
            positionData: input.positionData,
            createdAt: "2026-08-04T00:00:00Z",
            updatedAt: "2026-08-04T00:00:00Z")
    }
    func updateAnnotation(sessionId: String, input: UpdateAnnotationInput) async throws -> Bool { true }
    func deleteAnnotation(sessionId: String, id: String) async throws -> Bool { true }
    func setDocumentMetadata(sessionId: String, key: String, value: String) async throws {}
    func ensureDocumentId(sessionId: String) async throws -> String {
        openDocId ?? "eeeeeeee-ffff-0000-1111-222222222222"
    }
}
