import Foundation

/// The file vocabulary used above the local/iCloud routing decision. Callers
/// cannot enumerate, stat, or write a synced URL behind coordination because
/// those operations simply do not exist here.
protocol LibraryFileStore: Sendable {
    func read(_ url: URL) async throws -> Data?
    func replace(_ url: URL, with data: Data) async throws
    func remove(_ url: URL) async throws
    func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry]
    var isCoordinated: Bool { get }
}

struct LibraryFileEntry: Sendable, Equatable {
    var url: URL
    var name: String
    var readiness: ItemReadiness
    var byteSize: Int64?
    var contentModifiedAt: Date?
}

enum LibraryFileError: Error, Sendable, Equatable {
    case notDownloaded(URL, ItemReadiness)
    case outsideAllowedRoot(URL)
    case symbolicLink(URL)
    case retryable
    case unavailable
    case nestedCoordination(URL)
    case io(String)
}

/// The existing local/custom-folder behavior, lifted behind the shared seam.
struct DirectLibraryFileStore: LibraryFileStore {
    let isCoordinated = false
    private let allowedRoot: URL?

    init(allowedRoot: URL? = nil) {
        self.allowedRoot = allowedRoot?.standardizedFileURL
    }

    func read(_ url: URL) async throws -> Data? {
        let url = try checkedURL(url)
        let fileManager = FileManager.default
        if allowedRoot != nil,
           !fileManager.fileExists(atPath: url.path) {
            let placeholder = try checkedURL(WebICloud.placeholderURL(for: url))
            if fileManager.fileExists(atPath: placeholder.path) {
                _ = WebICloud.materialize(at: url, timeout: 0)
                guard fileManager.fileExists(atPath: url.path) else {
                    throw LibraryFileError.notDownloaded(url, .notDownloaded)
                }
            }
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let readiness = try readiness(of: url)
        guard readiness.isReady else {
            throw LibraryFileError.notDownloaded(url, readiness)
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
    }

    func replace(_ url: URL, with data: Data) async throws {
        let url = try checkedURL(url)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(url.lastPathComponent).tmp-\(UUID().uuidString.lowercased())")
        do {
            try data.write(to: temporary)
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw LibraryFileError.io(error.localizedDescription)
        }
        guard rename(temporary.path, url.path) == 0 else {
            try? fileManager.removeItem(at: temporary)
            throw LibraryFileError.io("Failed to commit \(url.lastPathComponent)")
        }
    }

    func remove(_ url: URL) async throws {
        let url = try checkedURL(url)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
    }

    func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        let directory = try checkedURL(directory)
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                ],
                options: allowedRoot == nil ? [.skipsHiddenFiles] : [])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
        var entries: [String: LibraryFileEntry] = [:]
        for candidate in urls {
            let candidate = try checkedURL(candidate)
            let url: URL
            let isPlaceholder: Bool
            if let logical = WebICloud.logicalURL(forPlaceholder: candidate) {
                guard allowedRoot != nil else { continue }
                url = try checkedURL(logical)
                isPlaceholder = true
            } else {
                guard !candidate.lastPathComponent.hasPrefix(".") else { continue }
                url = candidate
                isPlaceholder = false
            }
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) { continue }
            if isPlaceholder {
                _ = WebICloud.materialize(at: url, timeout: 0)
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                entries[url.lastPathComponent] = LibraryFileEntry(
                    url: url,
                    name: url.lastPathComponent,
                    readiness: .notDownloaded,
                    byteSize: nil,
                    contentModifiedAt: nil)
                continue
            }
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .fileSizeKey,
                    .contentModificationDateKey,
                    .isUbiquitousItemKey,
                    .ubiquitousItemDownloadingStatusKey,
                ])
            } catch {
                throw LibraryFileError.io(error.localizedDescription)
            }
            entries[url.lastPathComponent] = LibraryFileEntry(
                url: url,
                name: url.lastPathComponent,
                readiness: readiness(from: values),
                byteSize: values.fileSize.map(Int64.init),
                contentModifiedAt: values.contentModificationDate)
        }
        return entries.values.sorted { $0.name < $1.name }
    }

    private func checkedURL(_ url: URL) throws -> URL {
        let candidate = url.standardizedFileURL
        guard let allowedRoot else { return candidate }
        guard Self.contains(candidate, within: allowedRoot) else {
            throw LibraryFileError.outsideAllowedRoot(candidate)
        }

        if (try? FileManager.default.destinationOfSymbolicLink(atPath: allowedRoot.path)) != nil {
            throw LibraryFileError.symbolicLink(allowedRoot)
        }
        var current = allowedRoot
        let relativeComponents = candidate.pathComponents.dropFirst(
            allowedRoot.pathComponents.count)
        for component in relativeComponents {
            current.appendPathComponent(component)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: current.path)) != nil {
                throw LibraryFileError.symbolicLink(current)
            }
        }

        let resolvedRoot = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
        guard Self.contains(resolvedCandidate, within: resolvedRoot) else {
            throw LibraryFileError.outsideAllowedRoot(candidate)
        }
        return candidate
    }

    private func readiness(of url: URL) throws -> ItemReadiness {
        guard allowedRoot != nil else { return .current }
        do {
            return readiness(from: try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ]))
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
    }

    private func readiness(from values: URLResourceValues) -> ItemReadiness {
        guard allowedRoot != nil else { return .current }
        guard values.isUbiquitousItem == true else { return .current }
        switch values.ubiquitousItemDownloadingStatus {
        case .current: return .current
        case .downloaded: return .downloaded
        default: return .notDownloaded
        }
    }

    private static func contains(_ url: URL, within root: URL) -> Bool {
        let rootComponents = root.pathComponents
        let candidateComponents = url.pathComponents
        return candidateComponents.count >= rootComponents.count
            && Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

/// The iCloud implementation. It deliberately contains no FileManager use:
/// discovery is metadata-only and all byte access goes through SyncedContainer.
struct CoordinatedLibraryFileStore: LibraryFileStore {
    let container: any SyncedContainer
    let isCoordinated = true

    func read(_ url: URL) async throws -> Data? {
        do {
            let items = try await container.list(
                url.deletingLastPathComponent(),
                matching: SyncedItemFilter(namePrefix: url.lastPathComponent))
            guard let item = items.first(where: { $0.name == url.lastPathComponent }) else {
                return nil
            }
            guard item.readiness.isReady else {
                throw LibraryFileError.notDownloaded(url, item.readiness)
            }
            return try await container.data(at: url)
        } catch {
            throw Self.map(error, url: url)
        }
    }

    func replace(_ url: URL, with data: Data) async throws {
        do {
            try await container.replace(url, with: data)
        } catch {
            throw Self.map(error, url: url)
        }
    }

    func remove(_ url: URL) async throws {
        do {
            try await container.remove(url)
        } catch {
            throw Self.map(error, url: url)
        }
    }

    func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        do {
            return try await container.list(directory).compactMap { item in
                if let suffix, !item.name.hasSuffix(suffix) { return nil }
                return LibraryFileEntry(
                    url: item.url,
                    name: item.name,
                    readiness: item.readiness,
                    byteSize: item.byteSize,
                    contentModifiedAt: item.contentModifiedAt)
            }
        } catch {
            throw Self.map(error, url: directory)
        }
    }

    private static func map(_ error: any Error, url: URL) -> LibraryFileError {
        if let error = error as? LibraryFileError { return error }
        guard let error = error as? SyncedContainerError else {
            return .io(error.localizedDescription)
        }
        switch error {
        case .notReady(_, let readiness): return .notDownloaded(url, readiness)
        case .cancelled, .timedOut: return .retryable
        case .unavailable: return .unavailable
        case .nestedCoordination(let nestedURL): return .nestedCoordination(nestedURL)
        case .io(let message): return .io(message)
        }
    }
}

extension StorageCoordinator.StorageContext {
    var fileStore: any LibraryFileStore {
        switch self {
        case .direct:
            DirectLibraryFileStore()
        case .coordinated(let container, _):
            CoordinatedLibraryFileStore(container: container)
        }
    }
}
