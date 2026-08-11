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
        libraryDirectory: @escaping @Sendable () -> URL = { DocumentImport.libraryDirectory },
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
        } catch {
            removeStagedCopyIfNeeded(local)
            throw error
        }
    }

    @MainActor
    func restoreSavedPDF(
        _ savedDocument: DocumentInfo,
        sessionId: String,
        resolveExistingPath: (String) -> String?,
        open: (String, String) async throws -> DocumentInfo,
        close: (String) async -> Void = { _ in }
    ) async throws -> DocumentInfo {
        let key = DocumentAccessBookmarkStore.key(for: savedDocument)

        if let entry = store.entry(forKey: key),
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

        var paths: [String] = []
        if let resolvedPath = resolveExistingPath(savedDocument.pdfPath) {
            paths.append(resolvedPath)
        }
        paths.append(savedDocument.pdfPath)
        var tried: Set<String> = []
        for path in paths where tried.insert(path).inserted {
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
                } catch {
                    removeStagedCopyIfNeeded(local)
                    throw error
                }
            } catch {
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
        guard let resolved = resolveBookmark(bookmarkData, preferred: preferredAccesses) else {
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
            } catch {
                removeStagedCopyIfNeeded(local)
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
        try validate(url: localURL, expectedDocId: expectedDocId)
        var opened: DocumentInfo
        do {
            opened = try await open(localURL.path, sessionId)
        } catch {
            await close(sessionId)
            throw DocumentAccessError.unavailable(url.path)
        }
        do {
            try validate(opened: opened, expectedDocId: expectedDocId)
            let key = DocumentAccessBookmarkStore.key(for: opened)
            persistLocalBookmarkBestEffort(for: opened)
            if let priorKey, priorKey != key {
                try? store.remove(key: priorKey)
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

    private func persistLocalBookmarkBestEffort(for document: DocumentInfo) {
        let url = URL(fileURLWithPath: document.pdfPath)
        guard adapter.fileExists(url),
              let bookmarkData = try? adapter.makeBookmark(for: url, access: .local)
        else { return }
        let key = DocumentAccessBookmarkStore.key(for: document)
        try? store.upsert(key: key, lastKnownPath: document.pdfPath, bookmarkData: bookmarkData)
    }

    private func localReadableURL(
        for url: URL,
        access: DocumentBookmarkAccess = .external
    ) async throws -> (url: URL, staged: Bool) {
        if isAppOwnedURL(url) {
            return (url, false)
        }
        return try await withSecurityScopeAsyncIfNeeded(to: url, access: access) {
            guard adapter.fileExists(url) else {
                throw DocumentAccessError.unavailable(url.path)
            }
            let destination = uniqueLocalDestination(for: url.lastPathComponent)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                return (destination, true)
            } catch {
                try? FileManager.default.removeItem(at: destination)
                throw DocumentAccessError.storeUnavailable(
                    "Failed to copy PDF into the local library: \(error.localizedDescription)")
            }
        }
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

    private func removeStagedCopyIfNeeded(_ local: (url: URL, staged: Bool)) {
        guard local.staged else { return }
        try? FileManager.default.removeItem(at: local.url)
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

    private func withSecurityScopeAsyncIfNeeded<R>(
        to url: URL,
        access: DocumentBookmarkAccess,
        _ operation: () async throws -> R
    ) async rethrows -> R {
        let started = access == .external ? adapter.startAccessing(url) : false
        defer {
            if started {
                adapter.stopAccessing(url)
            }
        }
        return try await operation()
    }
}
