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
    case retryable
    case unavailable
    case nestedCoordination(URL)
    case io(String)
}

/// The existing local/custom-folder behavior, lifted behind the shared seam.
struct DirectLibraryFileStore: LibraryFileStore {
    let isCoordinated = false

    func read(_ url: URL) async throws -> Data? {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
    }

    func replace(_ url: URL, with data: Data) async throws {
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
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
    }

    func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        } catch {
            throw LibraryFileError.io(error.localizedDescription)
        }
        return urls.compactMap { url in
            if let suffix, !url.lastPathComponent.hasSuffix(suffix) { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return LibraryFileEntry(
                url: url,
                name: url.lastPathComponent,
                readiness: .current,
                byteSize: values?.fileSize.map(Int64.init),
                contentModifiedAt: values?.contentModificationDate)
        }.sorted { $0.name < $1.name }
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
