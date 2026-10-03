import Foundation

enum DocumentAccessError: Error, Equatable, LocalizedError, Sendable {
    case unavailable(String)
    case identityMismatch(expected: String, found: String?)
    case missingMetadata(String)
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let path):
            return "The PDF could not be opened from \(path). Relink it in Settings > Storage, or pick the file again."
        case .identityMismatch(let expected, let found):
            return "That PDF is a different document. Expected \(expected), found \(found ?? "no document identity")."
        case .missingMetadata(let key):
            return "No stored document metadata exists for \(key)."
        case .storeUnavailable(let message):
            return message
        }
    }
}

enum DocumentBookmarkAccess: Sendable {
    case local
    case external
}

protocol DocumentAccessAdapter: Sendable {
    func makeBookmark(for url: URL, access: DocumentBookmarkAccess) throws -> Data
    func resolveBookmark(_ data: Data, access: DocumentBookmarkAccess) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
    func fileExists(_ url: URL) -> Bool
    func documentId(atPath path: String) -> String?
}

struct SystemDocumentAccessAdapter: DocumentAccessAdapter {
    func makeBookmark(for url: URL, access: DocumentBookmarkAccess) throws -> Data {
        try url.bookmarkData(
            options: Self.creationOptions(for: access),
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
    }

    func resolveBookmark(_ data: Data, access: DocumentBookmarkAccess) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: Self.resolutionOptions(for: access),
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    private static func creationOptions(for access: DocumentBookmarkAccess) -> URL.BookmarkCreationOptions {
        #if os(macOS)
        return access == .external ? [.withSecurityScope] : []
        #else
        return []
        #endif
    }

    private static func resolutionOptions(for access: DocumentBookmarkAccess) -> URL.BookmarkResolutionOptions {
        #if os(macOS)
        return access == .external ? [.withSecurityScope] : []
        #else
        return []
        #endif
    }

    func startAccessing(_ url: URL) -> Bool {
        url.startAccessingSecurityScopedResource()
    }

    func stopAccessing(_ url: URL) {
        url.stopAccessingSecurityScopedResource()
    }

    func fileExists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func documentId(atPath path: String) -> String? {
        PdfMetadata.documentId(atPath: path)
    }
}

struct DocumentAccessResolver: Sendable {
    // Cancellation must close the session without deleting a copied PDF
    // after its durable bookmark has already replaced the previous entry.
    private struct CommittedOpenCancellation: Error {}

    // Destination selection and copy used to be serialized by the main
    // actor. Keep that atomicity when imports run on background threads.
    private static let localCopyLock = NSLock()

    static let live = DocumentAccessResolver(
        store: .shared,
        adapter: SystemDocumentAccessAdapter())

    let store: DocumentAccessBookmarkStore
    let adapter: any DocumentAccessAdapter
    private let libraryDirectory: @Sendable () -> URL
    private let appOwnedRootsOverride: @Sendable () -> [URL]?

    init(
        store: DocumentAccessBookmarkStore,
        adapter: any DocumentAccessAdapter,
        libraryDirectory: @escaping @Sendable () -> URL = defaultDocumentLibraryDirectory,
        appOwnedRoots: @escaping @Sendable () -> [URL]? = { nil }
    ) {
        self.store = store
        self.adapter = adapter
        self.libraryDirectory = libraryDirectory
        self.appOwnedRootsOverride = appOwnedRoots
    }

    func sourceExists(key: String, lastKnownPath: String) -> Bool {
        if adapter.fileExists(URL(fileURLWithPath: lastKnownPath)) { return true }
        guard let entry = store.entry(forKey: key) else { return false }
        guard let resolved = resolveBookmark(entry.bookmarkData, preferred: [.local, .external]) else {
            return false
        }
        return withSecurityScopeIfNeeded(to: resolved.url, access: resolved.access) {
            let exists = adapter.fileExists(resolved.url)
            if exists, resolved.isStale,
               let refreshed = try? adapter.makeBookmark(for: resolved.url, access: resolved.access) {
                try? store.upsert(key: key, lastKnownPath: resolved.url.path, bookmarkData: refreshed)
            }
            return exists
        }
    }

    @MainActor
    func openPickedPDF(
        url: URL,
        sessionId: String,
        open: (String, String) async throws -> DocumentInfo,
        close: (String) async -> Void = { _ in }
    ) async throws -> DocumentInfo {
        let local = try await localReadableURL(for: url)
        do {
            return try await openLocalPDF(
                url: url,
                localURL: local.url,
                expectedDocId: nil,
                priorKey: nil,
                sessionId: sessionId,
                open: open,
                close: close)
        } catch is CommittedOpenCancellation {
            throw CancellationError()
        } catch {
            await removeStagedCopyIfNeeded(local)
            throw error
        }
    }

    @MainActor
    func restoreSavedPDF(
        _ savedDocument: DocumentInfo,
        sessionId: String,
        resolveExistingPath: @escaping @Sendable (String) -> String?,
        open: (String, String) async throws -> DocumentInfo,
        close: (String) async -> Void = { _ in }
    ) async throws -> DocumentInfo {
        let key = DocumentAccessBookmarkStore.key(for: savedDocument)

        let entry = try await performFileOperation { store.entry(forKey: key) }
        try Task.checkCancellation()
        if let entry,
           let opened = await tryRestoreCandidate(
            bookmarkData: entry.bookmarkData,
            preferredAccesses: [.local, .external],
            savedDocument: savedDocument,
            priorKey: key,
            sessionId: sessionId,
            open: open,
            close: close
           ) {
            return opened
        }

        try Task.checkCancellation()
        if let bookmarkData = savedDocument.bookmarkData,
           let opened = await tryRestoreCandidate(
            bookmarkData: bookmarkData,
            preferredAccesses: [.external, .local],
            savedDocument: savedDocument,
            priorKey: key,
            sessionId: sessionId,
            open: open,
            close: close
           ) {
            return opened
        }

        try Task.checkCancellation()
        var paths: [String] = []
        if let resolvedPath = try await performFileOperation({ resolveExistingPath(savedDocument.pdfPath) }) {
            paths.append(resolvedPath)
        }
        try Task.checkCancellation()
        paths.append(savedDocument.pdfPath)
        var tried: Set<String> = []
        for path in paths where tried.insert(path).inserted {
            try Task.checkCancellation()
            do {
                let local = try await localReadableURL(for: URL(fileURLWithPath: path))
                do {
                    return try await openLocalPDF(
                        url: URL(fileURLWithPath: path),
                        localURL: local.url,
                        expectedDocId: savedDocument.docId,
                        priorKey: key,
                        sessionId: sessionId,
                        open: open,
                        close: close)
                } catch is CommittedOpenCancellation {
                    throw CancellationError()
                } catch {
                    await removeStagedCopyIfNeeded(local)
                    throw error
                }
            } catch {
                try Task.checkCancellation()
                continue
            }
        }
        throw DocumentAccessError.unavailable(savedDocument.pdfPath)
    }

    func relink(
        key: String,
        isDocIdKeyed: Bool,
        to url: URL,
        coordinator: StorageCoordinator? = nil
    ) async -> Result<Void, DocumentAccessError> {
        var stagedURL: URL?
        do {
            let local = try await localReadableURL(for: url)
            stagedURL = local.staged ? local.url : nil
            if isDocIdKeyed {
                let found = adapter.documentId(atPath: local.url.path)
                guard found == key else {
                    throw DocumentAccessError.identityMismatch(expected: key, found: found)
                }
            }
            let bookmarkData = try adapter.makeBookmark(for: local.url, access: .local)
            let previousStore = store.entry(forKey: key)
            let previousMeta: DocumentDataStore.Meta? = if let coordinator {
                try await DocumentDataStore.loadMeta(forKey: key, coordinator: coordinator)
            } else {
                DocumentDataStore.loadMeta(forKey: key)
            }
            guard let previousMeta else {
                throw DocumentAccessError.missingMetadata(key)
            }
            do {
                if let coordinator {
                    try await DocumentDataStore.relink(
                        forKey: key, newPath: local.url.path, coordinator: coordinator)
                } else {
                    try DocumentDataStore.relink(forKey: key, newPath: local.url.path)
                }
                do {
                    try store.upsert(key: key, lastKnownPath: local.url.path, bookmarkData: bookmarkData)
                } catch {
                    if let coordinator {
                        try? await DocumentDataStore.restoreMeta(
                            previousMeta, forKey: key, coordinator: coordinator)
                    } else {
                        try? DocumentDataStore.restoreMeta(previousMeta, forKey: key)
                    }
                    throw error
                }
            } catch {
                if let previousStore {
                    try? store.upsert(
                        key: previousStore.key,
                        lastKnownPath: previousStore.lastKnownPath,
                        bookmarkData: previousStore.bookmarkData)
                } else {
                    try? store.remove(key: key)
                }
                throw error
            }
            removePreviousLibraryCopyIfNeeded(previousMeta.lastKnownPath, replacingWith: local.url)
            return .success(())
        } catch let error as DocumentAccessError {
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            return .failure(error)
        } catch {
            if let stagedURL { try? FileManager.default.removeItem(at: stagedURL) }
            return .failure(.storeUnavailable(error.localizedDescription))
        }
    }

    @MainActor
    private func tryRestoreCandidate(
        bookmarkData: Data,
        preferredAccesses: [DocumentBookmarkAccess],
        savedDocument: DocumentInfo,
        priorKey: String,
        sessionId: String,
        open: (String, String) async throws -> DocumentInfo,
        close: (String) async -> Void
    ) async -> DocumentInfo? {
        guard let resolved = try? await performFileOperation({
            resolveBookmark(bookmarkData, preferred: preferredAccesses)
        }), !Task.isCancelled else {
            return nil
        }
        do {
            let local = try await localReadableURL(for: resolved.url, access: resolved.access)
            do {
                return try await openLocalPDF(
                    url: resolved.url,
                    localURL: local.url,
                    expectedDocId: savedDocument.docId,
                    priorKey: priorKey,
                    sessionId: sessionId,
                    open: open,
                    close: close)
            } catch is CommittedOpenCancellation {
                throw CancellationError()
            } catch {
                await removeStagedCopyIfNeeded(local)
                throw error
            }
        } catch {
            return nil
        }
    }

    @MainActor
    private func openLocalPDF(
        url: URL,
        localURL: URL,
        expectedDocId: String?,
        priorKey: String?,
        sessionId: String,
        open: (String, String) async throws -> DocumentInfo,
        close: (String) async -> Void
    ) async throws -> DocumentInfo {
        try await performFileOperation { try validate(url: localURL, expectedDocId: expectedDocId) }
        try Task.checkCancellation()
        var opened: DocumentInfo
        do {
            opened = try await open(localURL.path, sessionId)
        } catch {
            await close(sessionId)
            throw DocumentAccessError.unavailable(url.path)
        }
        do {
            try Task.checkCancellation()
            try validate(opened: opened, expectedDocId: expectedDocId)
            let key = DocumentAccessBookmarkStore.key(for: opened)
            let validatedDocument = opened
            let bookmarkCommitted = try await performFileOperation {
                let committed = persistLocalBookmarkBestEffort(for: validatedDocument)
                // Finish the rekey once the new bookmark is committed. A
                // cancelled open keeps that file but never adopts its session.
                if !committed { try Task.checkCancellation() }
                if let priorKey, priorKey != key {
                    try? store.remove(key: priorKey)
                }
                return committed
            }
            if Task.isCancelled {
                if bookmarkCommitted { throw CommittedOpenCancellation() }
                throw CancellationError()
            }
            opened.bookmarkData = nil
            return opened
        } catch let error as DocumentAccessError {
            await close(sessionId)
            throw error
        } catch {
            await close(sessionId)
            throw error
        }
    }

    private func persistLocalBookmarkBestEffort(for document: DocumentInfo) -> Bool {
        let url = URL(fileURLWithPath: document.pdfPath)
        guard adapter.fileExists(url),
              let bookmarkData = try? adapter.makeBookmark(for: url, access: .local)
        else { return false }
        guard !Task.isCancelled else { return false }
        let key = DocumentAccessBookmarkStore.key(for: document)
        do {
            try store.upsert(key: key, lastKnownPath: document.pdfPath, bookmarkData: bookmarkData)
            return true
        } catch {
            return false
        }
    }

    private func localReadableURL(
        for url: URL,
        access: DocumentBookmarkAccess = .external
    ) async throws -> (url: URL, staged: Bool) {
        let local = try await performFileOperation {
            if isAppOwnedURL(url) {
                return (url: url, staged: false)
            }
            return try withSecurityScopeIfNeeded(to: url, access: access) {
                Self.localCopyLock.lock()
                defer { Self.localCopyLock.unlock() }
                try Task.checkCancellation()
                guard adapter.fileExists(url) else {
                    throw DocumentAccessError.unavailable(url.path)
                }
                let destination = uniqueLocalDestination(for: url.lastPathComponent)
                do {
                    try FileManager.default.copyItem(at: url, to: destination)
                    return (url: destination, staged: true)
                } catch {
                    try? FileManager.default.removeItem(at: destination)
                    throw DocumentAccessError.storeUnavailable(
                        "Failed to copy PDF into the local library: \(error.localizedDescription)")
                }
            }
        }
        if Task.isCancelled {
            await removeStagedCopyIfNeeded(local)
            try Task.checkCancellation()
        }
        return local
    }

    private func uniqueLocalDestination(for filename: String) -> URL {
        let dir = libraryDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var candidate = dir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = dir.appendingPathComponent(name)
            index += 1
        }
        return candidate
    }

    private func removeStagedCopyIfNeeded(_ local: (url: URL, staged: Bool)) async {
        guard local.staged else { return }
        // Cleanup still runs after cancellation and is fully joined before the
        // failed/cancelled open returns to its caller.
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: local.url)
        }.value
    }

    /// Bookmark APIs can wait on FileProvider XPC even for local URLs. Keep
    /// all synchronous access work off the main actor and join its lifetime.
    private func performFileOperation<Value: Sendable>(
        _ operation: @escaping @Sendable () throws -> Value
    ) async throws -> Value {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try operation()
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func removePreviousLibraryCopyIfNeeded(_ path: String, replacingWith url: URL) {
        let previous = URL(fileURLWithPath: path)
        guard normalizedPath(previous) != normalizedPath(url),
              isManagedLibraryURL(previous)
        else { return }
        try? FileManager.default.removeItem(at: previous)
    }

    private func isAppOwnedURL(_ url: URL) -> Bool {
        let path = normalizedPath(url)
        return appOwnedRoots().contains { root in
            path == root || path.hasPrefix(root + "/")
        }
    }

    private func isManagedLibraryURL(_ url: URL) -> Bool {
        let path = normalizedPath(url)
        let root = normalizedPath(libraryDirectory())
        return path == root || path.hasPrefix(root + "/")
    }

    private func appOwnedRoots() -> [String] {
        let overrideRoots = appOwnedRootsOverride()
        var roots = [libraryDirectory()]
        if let overrideRoots {
            roots.append(contentsOf: overrideRoots)
        } else {
            let manager = FileManager.default
            roots.append(contentsOf: manager.urls(for: .documentDirectory, in: .userDomainMask))
            roots.append(contentsOf: manager.urls(for: .applicationSupportDirectory, in: .userDomainMask))
            roots.append(manager.temporaryDirectory)
            roots.append(URL(fileURLWithPath: "/tmp", isDirectory: true))
            roots.append(URL(fileURLWithPath: "/private/tmp", isDirectory: true))
        }
        var seen = Set<String>()
        return roots
            .map(normalizedPath)
            .filter { seen.insert($0).inserted }
    }

    private func normalizedPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func resolveBookmark(
        _ data: Data,
        preferred accesses: [DocumentBookmarkAccess]
    ) -> (url: URL, isStale: Bool, access: DocumentBookmarkAccess)? {
        for access in accesses {
            if let resolved = try? adapter.resolveBookmark(data, access: access) {
                return (resolved.url, resolved.isStale, access)
            }
        }
        return nil
    }

    private func validate(url: URL, expectedDocId: String?) throws {
        guard let expectedDocId, expectedDocId.isEmpty == false else { return }
        let found = adapter.documentId(atPath: url.path)
        guard found == expectedDocId else {
            throw DocumentAccessError.identityMismatch(expected: expectedDocId, found: found)
        }
    }

    private func validate(opened: DocumentInfo, expectedDocId: String?) throws {
        guard let expectedDocId, expectedDocId.isEmpty == false else { return }
        guard opened.docId == expectedDocId else {
            throw DocumentAccessError.identityMismatch(expected: expectedDocId, found: opened.docId)
        }
    }

    private func withSecurityScopeIfNeeded<R>(
        to url: URL,
        access: DocumentBookmarkAccess,
        _ operation: () throws -> R
    ) rethrows -> R {
        let started = access == .external ? adapter.startAccessing(url) : false
        defer {
            if started {
                adapter.stopAccessing(url)
            }
        }
        return try operation()
    }
}

#if os(iOS)
private let defaultDocumentLibraryDirectory: @Sendable () -> URL = {
    DocumentImport.libraryDirectory
}
#else
private let defaultDocumentLibraryDirectory: @Sendable () -> URL = {
    if let root = TestEnvironment.storageRoot { return root.appendingPathComponent("Documents", isDirectory: true) }
    let base = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base
        .appendingPathComponent(RuntimeProfile.current.localStorageDirectoryName, isDirectory: true)
        .appendingPathComponent("Documents", isDirectory: true)
}
#endif
