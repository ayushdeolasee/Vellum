import CShell
import Foundation
import Glibc
import VellumCore

/// An open library directory. Moving or replacing its name does not redirect the reader.
public actor RootDirectory {
    public nonisolated let url: URL
    private let components: [String]
    private let descriptor: Int32

    @concurrent
    public static func open(_ url: URL = URL(fileURLWithPath: "/library", isDirectory: true)) async throws -> RootDirectory {
        let components = try pathComponents(of: url)
        let fd = library_open_root("/" + components.joined(separator: "/"))
        guard fd >= 0 else { throw fileError(errno, at: url) }
        return RootDirectory(url: url, components: components, descriptor: fd)
    }

    private init(url: URL, components: [String], descriptor: Int32) {
        self.url = url
        self.components = components
        self.descriptor = descriptor
    }

    isolated deinit { _ = close(descriptor) }

    private static func pathComponents(of url: URL) throws -> [String] {
        guard url.isFileURL, url.baseURL == nil,
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              (parts.host ?? "").isEmpty, parts.user == nil, parts.password == nil,
              parts.port == nil, parts.query == nil, parts.fragment == nil,
              parts.percentEncodedPath.hasPrefix("/")
        else { throw LibraryFileError.outsideAllowedRoot(url) }

        // Validate before path standardization could erase traversal. Decode each
        // component separately so an encoded slash or NUL cannot change the C path.
        return try parts.percentEncodedPath.split(separator: "/").map { encoded in
            guard let name = encoded.removingPercentEncoding, name != ".", name != "..",
                  !name.utf8.contains(0), !name.utf8.contains(47)
            else { throw LibraryFileError.outsideAllowedRoot(url) }
            return name
        }
    }

    private func relativePath(to url: URL) throws -> String {
        let path = try Self.pathComponents(of: url)
        // Linux compares filesystem names bytewise, including Unicode normalization.
        guard path.count >= components.count,
              zip(path, components).allSatisfy({ $0.utf8.elementsEqual($1.utf8) })
        else { throw LibraryFileError.outsideAllowedRoot(url) }
        let relative = path.dropFirst(components.count)
        return relative.isEmpty ? "." : relative.joined(separator: "/")
    }

    func readRegularFile(_ url: URL, byteLimit: Int) throws -> Data? {
        try Task.checkCancellation()
        var info = stat()
        let fd = library_open_file(descriptor, try relativePath(to: url), &info)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw Self.fileError(errno, at: url)
        }
        defer { _ = close(fd) }
        guard info.st_size <= byteLimit else { throw ReaderFileError.fileTooLarge }
        return try Self.readBytes(from: fd, byteLimit: byteLimit)
    }

    // A regular file can grow after fstat or report a zero size despite having bytes.
    static func readBytes(from fd: Int32, byteLimit: Int) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try Task.checkCancellation()
            let remaining = byteLimit - data.count
            let count = buffer.withUnsafeMutableBytes {
                Glibc.read(fd, $0.baseAddress, min($0.count, remaining + 1))
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            if count == 0 { return data }
            guard count <= remaining else { throw ReaderFileError.fileTooLarge }
            data.append(buffer, count: count)
        }
    }

    func listDirectory(_ url: URL, suffix: String?) throws -> [LibraryFileEntry] {
        try Task.checkCancellation()
        guard let stream = library_open_directory(descriptor, try relativePath(to: url)) else {
            if errno == ENOENT { return [] }
            throw Self.fileError(errno, at: url)
        }
        defer { _ = closedir(stream) }
        var entries: [LibraryFileEntry] = []
        var info = stat()
        while let rawName = library_next_regular(stream, &info) {
            try Task.checkCancellation()
            guard let name = String(validatingCString: rawName),
                  !SyncArtifact.matches(name),
                  suffix.map({ name.hasSuffix($0) }) ?? true else { continue }
            let modified = Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
            entries.append(LibraryFileEntry(
                url: url.appendingPathComponent(name, isDirectory: false),
                name: name, readiness: .current, byteSize: Int64(info.st_size),
                contentModifiedAt: Date(timeIntervalSince1970: modified)))
        }
        guard errno == 0 else { throw Self.fileError(errno, at: url) }
        return entries.sorted { $0.name < $1.name }
    }

    private static func fileError(_ code: Int32, at url: URL) -> LibraryFileError {
        switch code {
        case ELOOP: return .symbolicLink(url)
        case EXDEV: return .outsideAllowedRoot(url)
        default: return .io(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)
        }
    }
}
