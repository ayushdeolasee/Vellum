import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum StignoreManager {
    public enum UpdateError: Error, Equatable {
        case malformedMarkers
        case notRegularFile
        case changedDuringUpdate
    }

    private static let filename = ".stignore"
    private static let begin = " BEGIN VELLUM MANAGED - DO NOT EDIT THIS BLOCK"
    private static let end = " END VELLUM MANAGED"
    private static let nonce = "????????-????-????-????-????????????"

    private static let rules = [
        "(?d).DS_Store",
        "(?d)._*",
        "(?d)Thumbs.db",
        "(?d)desktop.ini",
        "(?d)/.vellum/cache",
        "(?d)/.vellum/locks",
        "(?d)/.vellum/local",
        "(?d)/.vellum/.*.icloud",
        "(?d)/.vellum/**/.*.icloud",
        // Fixed staging names in the index, record, document and ink writers.
        "(?d)/.vellum/index.json.tmp",
        "(?d)/.vellum/records/*.json.tmp",
        "(?d)/.vellum/documents/*/meta.json.tmp",
        "(?d)/.vellum/documents/*/scratchpad.md.tmp",
        "(?d)/.vellum/documents/*/conversations.json.tmp",
        "(?d)/Web Pages/*.vellumweb.tmp",
        // Sibling temp names used by the direct store, position and archive writers.
        "(?d)/.vellum/.*.tmp-\(nonce)",
        "(?d)/.vellum/**/.*.tmp-\(nonce)",
        "(?d)/.vellum/positions/.*.json.tmp-*-\(nonce)",
        "(?d)/Web Pages/.*.vellumweb.tmp-*-\(nonce)",
        "(?d)(?i)/PDFs/.*.pdf.vellum-\(nonce).tmp",
        "(?d)(?i)/PDFs/**/.*.pdf.vellum-\(nonce).tmp",
        // The folder backend stages replacements and recovery writes beside the destination.
        "(?d).vellum.tmp-\(nonce)",
        "(?d)/..stignore.tmp-\(nonce)",
    ]

    /// Call during explicit writable shared-folder activation. The root must already exist.
    /// The writer stages bytes through a private file handle. This method owns the commit.
    /// Concurrent Vellum activations serialize. Initial creation is exclusive, and updates
    /// recheck the existing file immediately before rename. An editor that ignores the
    /// directory lock can still write in the interval between that check and rename.
    @discardableResult
    public static func ensure(
        at libraryRoot: URL,
        write: (Data, FileHandle) throws -> Void = { data, file in try file.write(contentsOf: data) }
    ) throws -> Bool {
        let directory = open(libraryRoot.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw posixError() }
        defer { _ = close(directory) }

        // A directory lock serializes Vellum activations without leaving a lock file.
        while flock(directory, LOCK_EX) != 0 {
            guard errno == EINTR else { throw posixError() }
        }

        let original = try read(in: directory)
        let updated = try render(original?.bytes ?? Data())
        guard updated != original?.bytes else { return false }

        let staging = ".\(filename).tmp-\(UUID().uuidString.lowercased())"
        let descriptor = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError() }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer {
            try? file.close()
            _ = unlinkat(directory, staging, 0)
        }
        try write(updated, file)
        if let original {
            guard fchmod(descriptor, original.info.st_mode & 0o777) == 0 else { throw posixError() }
        }
        try file.synchronize()
        try file.close()

        if let original {
            // Other editors do not take our advisory lock. Recheck the identity,
            // timestamps and bytes immediately before the atomic replacement.
            guard let current = try read(in: directory),
                  original.matches(current) else { throw UpdateError.changedDuringUpdate }
            guard renameat(directory, staging, directory, filename) == 0 else { throw posixError() }
        } else {
            // Publishing a new file never overwrites one created since the read.
            guard linkat(directory, staging, directory, filename, 0) == 0 else {
                if errno == EEXIST { throw UpdateError.changedDuringUpdate }
                throw posixError()
            }
        }
        return true
    }

    private struct Snapshot {
        let bytes: Data
        let info: stat

        func matches(_ other: Snapshot) -> Bool {
            Self.isSameVersion(info, other.info) && bytes == other.bytes
        }

        static func isSameVersion(_ lhs: stat, _ rhs: stat) -> Bool {
            guard lhs.st_dev == rhs.st_dev, lhs.st_ino == rhs.st_ino,
                  lhs.st_mode == rhs.st_mode, lhs.st_size == rhs.st_size else { return false }
            #if canImport(Darwin)
            return equal(lhs.st_mtimespec, rhs.st_mtimespec) && equal(lhs.st_ctimespec, rhs.st_ctimespec)
            #else
            return equal(lhs.st_mtim, rhs.st_mtim) && equal(lhs.st_ctim, rhs.st_ctim)
            #endif
        }

        private static func equal(_ lhs: timespec, _ rhs: timespec) -> Bool {
            lhs.tv_sec == rhs.tv_sec && lhs.tv_nsec == rhs.tv_nsec
        }
    }

    private static func read(in directory: Int32) throws -> Snapshot? {
        let descriptor = openat(directory, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw posixError()
        }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }

        var before = stat()
        guard fstat(descriptor, &before) == 0 else { throw posixError() }
        guard before.st_mode & S_IFMT == S_IFREG else { throw UpdateError.notRegularFile }
        let bytes = try file.readToEnd() ?? Data()
        var after = stat()
        guard fstatat(directory, filename, &after, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw UpdateError.changedDuringUpdate }
            throw posixError()
        }
        guard Snapshot.isSameVersion(before, after) else { throw UpdateError.changedDuringUpdate }
        return Snapshot(bytes: bytes, info: after)
    }

    private static func render(_ original: Data) throws -> Data {
        let bom: [UInt8] = [0xef, 0xbb, 0xbf]
        let contentStart = original.starts(with: bom) ? bom.count : original.startIndex
        var start: Int?
        var endIndex: Int?
        var newline = "\n"

        var lineStart = contentStart
        while lineStart < original.endIndex {
            let lf = original[lineStart...].firstIndex(of: 0x0a) ?? original.endIndex
            let crlf = lf > lineStart && lf < original.endIndex && original[lf - 1] == 0x0d
            let lineEnd = crlf ? lf - 1 : lf
            let line = original[lineStart..<lineEnd]
            // Accept the planning sketch's # markers. Syncthing comments use //.
            if line.elementsEqual(("//" + begin).utf8) || line.elementsEqual(("#" + begin).utf8) {
                guard start == nil else { throw UpdateError.malformedMarkers }
                start = lineStart
                newline = crlf ? "\r\n" : "\n"
            } else if line.elementsEqual(("//" + end).utf8) || line.elementsEqual(("#" + end).utf8) {
                guard start != nil, endIndex == nil else { throw UpdateError.malformedMarkers }
                endIndex = lineEnd
            } else if start == nil && lf < original.endIndex {
                newline = crlf ? "\r\n" : "\n"
            }
            lineStart = lf + 1
        }

        let block = (["//" + begin] + rules + ["//" + end]).joined(separator: newline)
        if let start {
            guard let endIndex else { throw UpdateError.malformedMarkers }
            var updated = original
            updated.replaceSubrange(start..<endIndex, with: block.utf8)
            return updated
        }

        var updated = original
        if original.count > contentStart {
            if original.last != 0x0a { updated.append(contentsOf: newline.utf8) }
            updated.append(contentsOf: newline.utf8)
        }
        updated.append(contentsOf: (block + newline).utf8)
        return updated
    }

    private static func posixError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
