import Foundation
import VellumCore

public enum ReaderFileError: Error, Equatable {
    case readOnly
    case fileTooLarge
}

public struct ReadOnlyLibraryFileStore: LibraryFileStore {
    public let isCoordinated = false
    public let root: RootDirectory

    public init(root: RootDirectory) {
        self.root = root
    }

    public func read(_ url: URL) async throws -> Data? {
        // Whole-file budgets. The archive budget matches the Apple WebArchive
        // input cap, and the PDF budget matches the offline PDF downloader.
        let limitMiB: Int
        switch url.pathExtension.lowercased() {
        case "vellumweb": limitMiB = 315
        case "pdf": limitMiB = 250
        default: limitMiB = 32
        }
        return try await root.readRegularFile(url, byteLimit: limitMiB * 1024 * 1024)
    }

    public func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        try await root.listDirectory(directory, suffix: suffix)
    }

    public func replace(_ url: URL, with data: Data) async throws {
        throw ReaderFileError.readOnly
    }

    public func remove(_ url: URL) async throws {
        throw ReaderFileError.readOnly
    }
}
