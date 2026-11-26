#if os(Linux)
import CFolderSync
import Foundation
import Glibc

// A sync client or another reader can hold an advisory lock indefinitely.
func lockLinuxFile(_ fd: Int32) throws {
    let deadline = ContinuousClock.now + .milliseconds(400)
    while flock(fd, LOCK_EX | LOCK_NB) != 0 {
        guard errno == EWOULDBLOCK || errno == EINTR else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        guard ContinuousClock.now < deadline else { throw LibraryFileError.retryable }
        usleep(10_000)
    }
}

extension LocalFolderFileStore {
    /// The caller owns an independently opened description of the destination directory.
    /// All live and staging names resolve against that inode, even after a root rename.
    public static func replace(in directory: Int32, name: String, with data: Data,
                               ifCurrent expected: Data?, limit: Int) throws -> Bool {
        guard !name.isEmpty, name != ".", name != "..", !name.utf8.contains(47),
              !name.utf8.contains(0), data.count <= limit, (expected?.count ?? 0) <= limit
        else { throw POSIXError(.EINVAL) }
        func error() -> POSIXError { POSIXError(.init(rawValue: errno) ?? .EIO) }
        try lockLinuxFile(directory)
        defer { _ = flock(directory, LOCK_UN) }

        // Compare in chunks, including EOF. Never follow a replaced leaf or allocate
        // from the size of a peer file. Keep the existing file's permission bits.
        var mode: mode_t = 0o600
        func matches(_ leaf: String, _ bytes: Data?) throws -> Bool {
            let fd = vellum_open_beneath(directory, leaf, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_NOCTTY)
            guard fd >= 0 else {
                if errno == ENOENT { return bytes == nil }
                throw error()
            }
            defer { _ = close(fd) }
            var info = stat()
            guard fstat(fd, &info) == 0 else { throw error() }
            guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EINVAL) }
            guard let bytes, info.st_size == bytes.count else { return false }
            mode = info.st_mode & 0o777
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            var offset = 0
            while true {
                let count = Glibc.read(fd, &buffer, buffer.count)
                if count == 0 { return offset == bytes.count }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw error()
                }
                guard count <= bytes.count - offset else { return false }
                let start = bytes.startIndex + offset
                guard buffer.prefix(count).elementsEqual(bytes[start..<(start + count)]) else { return false }
                offset += count
            }
        }
        guard try matches(name, expected) else { return false }
        let temp = ".vellum.tmp-\(UUID().uuidString.lowercased())"
        let fd = openat(directory, temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw error() }
        var owned = true
        defer { if owned { _ = unlinkat(directory, temp, 0) } }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try file.write(contentsOf: data)
        guard fchmod(fd, mode) == 0 else { throw error() }
        try file.synchronize()
        try file.close()

        let result = vellum_rename_at(directory, temp, directory, name, expected == nil ? 0 : 1)
        if result == EEXIST || result == ENOENT { return false }
        guard result == 0 else { throw POSIXError(.init(rawValue: result) ?? .EIO) }
        guard expected != nil else { return true }
        // Exchange pins the actual displaced object. A sync daemon ignores flock.
        // On a race preserve both versions, including an unexpected directory.
        owned = false
        if (try? matches(temp, expected)) == true {
            guard unlinkat(directory, temp, 0) == 0 else { throw error() }
            return true
        }
        if (try? matches(name, data)) == true {
            _ = vellum_rename_at(directory, temp, directory, name, 1)
        }
        let recovery = PreserveLosersConflictResolver.archiveURL(
            for: URL(fileURLWithPath: "/").appendingPathComponent(name),
            version: ConflictVersion(id: UUID().uuidString))
        guard mkdirat(directory, "conflicts", 0o700) == 0 || errno == EEXIST else { throw error() }
        let archive = vellum_open_beneath(directory, "conflicts", O_DIRECTORY | O_RDONLY)
        guard archive >= 0 else { throw error() }
        defer { _ = close(archive) }
        let archived = vellum_rename_at(directory, temp, archive, recovery.lastPathComponent, 0)
        guard archived == 0 else { throw POSIXError(.init(rawValue: archived) ?? .EIO) }
        throw LibraryFileError.retryable
    }
}
#endif
