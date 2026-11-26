import Foundation
import VellumCore

public enum ReaderFileError: Error, Equatable {
    case readOnly
    case fileTooLarge
}

public struct ReadOnlyLibraryFileStore: LibraryFileStore {
    public let isCoordinated = false
    public let root: RootDirectory

    private let maxArchiveBytes: Int

    public init(root: RootDirectory, maxArchiveBytes: Int = ArchiveCodec.maxArchiveBytes) {
        self.root = root
        self.maxArchiveBytes = maxArchiveBytes
    }

    public func read(_ url: URL) async throws -> Data? {
        let byteLimit: Int
        switch url.pathExtension.lowercased() {
        case "vellumweb": byteLimit = maxArchiveBytes
        case "pdf": byteLimit = PdfiumDocument.maxInputBytes
        default: byteLimit = 32 * 1024 * 1024
        }
        return try await root.readRegularFile(url, byteLimit: byteLimit)
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
