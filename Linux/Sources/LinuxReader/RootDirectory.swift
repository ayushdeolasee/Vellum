import CShell
import Foundation
import Glibc
import VellumCore

/// An open library directory. Moving or replacing its name does not redirect the reader.
public final class RootDirectory: Sendable {
    public let url: URL
    private let components: [String]
    private let descriptor: Int32

    public static func open(_ url: URL = URL(fileURLWithPath: "/library", isDirectory: true)) async throws -> RootDirectory {
        let components = try pathComponents(of: url)
        return try await LibraryIO.run { _ in
            let fd = library_open_root("/" + components.joined(separator: "/"))
            guard fd >= 0 else { throw fileError(errno, at: url) }
            return RootDirectory(url: url, components: components, descriptor: fd)
        }
    }

    private init(url: URL, components: [String], descriptor: Int32) {
        self.url = url
        self.components = components
        self.descriptor = descriptor
    }

    deinit {
        let fd = descriptor
        LibraryIO.queue.addOperation { _ = close(fd) }
    }

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

    func readRegularFile(_ url: URL, byteLimit: Int) async throws -> Data? {
        let path = try relativePath(to: url)
        return try await LibraryIO.run { [self] checkCancellation in
            var info = stat()
            let fd = withExtendedLifetime(self) { library_open_file(descriptor, path, &info) }
            guard fd >= 0 else {
                if errno == ENOENT { return nil }
                throw Self.fileError(errno, at: url)
            }
            defer { _ = close(fd) }
            guard info.st_size <= byteLimit else { throw ReaderFileError.fileTooLarge }
            return try Self.readBytes(from: fd, byteLimit: byteLimit, checkCancellation: checkCancellation)
        }
    }

    // A regular file can grow after fstat or report a zero size despite having bytes.
    static func readBytes(from fd: Int32, byteLimit: Int,
                          checkCancellation: () throws -> Void = Task.checkCancellation) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try checkCancellation()
            let remaining = byteLimit - data.count
            let count = buffer.withUnsafeMutableBytes {
                Glibc.read(fd, $0.baseAddress, remaining < $0.count ? remaining + 1 : $0.count)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw ioError(errno)
            }
            if count == 0 { return data }
            guard count <= remaining else { throw ReaderFileError.fileTooLarge }
            data.append(buffer, count: count)
        }
    }

    func listDirectory(_ url: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        let path = try relativePath(to: url)
        return try await LibraryIO.run { [self] checkCancellation in
            let directory = withExtendedLifetime(self) { library_open_directory(descriptor, path) }
            guard let stream = directory else {
                if errno == ENOENT { return [] }
                throw Self.fileError(errno, at: url)
            }
            defer { _ = closedir(stream) }
            var entries: [LibraryFileEntry] = []
            while let rawName = library_next_name(stream) {
                try checkCancellation()
                guard let name = String(validatingCString: rawName),
                      !name.hasPrefix("."), !name.contains(".sync-conflict-"),
                      suffix.map({ name.hasSuffix($0) }) ?? true else { continue }
                var info = stat()
                let result = library_entry_info(stream, rawName, &info)
                guard result >= 0 else { throw Self.fileError(errno, at: url) }
                if result == 0 { continue }
                let isDirectory = info.st_mode & S_IFMT == S_IFDIR
                let modified = Double(info.st_mtim.tv_sec) + Double(info.st_mtim.tv_nsec) / 1e9
                entries.append(LibraryFileEntry(
                    url: url.appendingPathComponent(name, isDirectory: isDirectory),
                    name: name, readiness: .current, byteSize: Int64(info.st_size),
                    contentModifiedAt: Date(timeIntervalSince1970: modified)))
            }
            guard errno == 0 else { throw Self.fileError(errno, at: url) }
            return entries.sorted { $0.name < $1.name }
        }
    }

    private static func ioError(_ code: Int32) -> LibraryFileError {
        .io(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)
    }

    private static func fileError(_ code: Int32, at url: URL) -> LibraryFileError {
        switch code {
        case ELOOP: return .symbolicLink(url)
        case EXDEV: return .outsideAllowedRoot(url)
        default: return ioError(code)
        }
    }
}
