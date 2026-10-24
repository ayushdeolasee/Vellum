import Foundation
import ZIPFoundation

// Bounded, thread-safe read access to one EPUB's ZIP archive. The archive is
// validated up front (entry count, declared expansion, traversal paths,
// symlinks) and every read is capped again while streaming, so a lying
// central directory cannot expand past the limits either. Nothing is
// extracted to disk: the original file stays the durable copy.

final class EpubContainer: @unchecked Sendable {
    struct Limits: Sendable {
        var maxEntryCount: Int
        var maxEntrySize: UInt64
        var maxTotalSize: UInt64
        var maxXMLSize: UInt64

        static let standard = Limits(
            maxEntryCount: 10_000,
            maxEntrySize: 128 * 1024 * 1024,
            maxTotalSize: 1024 * 1024 * 1024,
            maxXMLSize: 8 * 1024 * 1024)
    }

    let url: URL
    let limits: Limits
    /// File (non-directory) entry paths in the archive.
    let paths: Set<String>

    private let lock = NSLock()
    private let archive: Archive
    private let entries: [String: Entry]

    init(url: URL, limits: Limits = .standard) throws {
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            throw EpubError.notAnArchive
        }
        var entries: [String: Entry] = [:]
        var count = 0
        var total: UInt64 = 0
        for entry in archive {
            count += 1
            guard count <= limits.maxEntryCount else {
                throw EpubError.unsafeArchive("it contains too many files")
            }
            let path = entry.path
            guard Self.isSafeEntryPath(path) else {
                throw EpubError.unsafeArchive("it contains an unsafe path")
            }
            switch entry.type {
            case .symlink:
                throw EpubError.unsafeArchive("it contains a symbolic link")
            case .directory:
                continue
            case .file:
                break
            }
            guard entry.uncompressedSize <= limits.maxEntrySize else {
                throw EpubError.resourceTooLarge(path)
            }
            total += entry.uncompressedSize
            guard total <= limits.maxTotalSize else { throw EpubError.archiveTooLarge }
            if entries[path] == nil {
                entries[path] = entry
            }
        }
        self.url = url
        self.limits = limits
        self.archive = archive
        self.entries = entries
        self.paths = Set(entries.keys)
    }

    func contains(_ path: String) -> Bool {
        entries[path] != nil
    }

    /// Reads one entry, enforcing `maxSize` (default: the per-entry limit)
    /// against both the declared and the actually inflated size.
    func data(at path: String, maxSize: UInt64? = nil) throws -> Data {
        guard let entry = entries[path] else { throw EpubError.missingResource(path) }
        let cap = min(maxSize ?? limits.maxEntrySize, limits.maxEntrySize, entry.uncompressedSize)
        guard entry.uncompressedSize <= min(maxSize ?? limits.maxEntrySize, limits.maxEntrySize) else {
            throw EpubError.resourceTooLarge(path)
        }
        lock.lock()
        defer { lock.unlock() }
        var output = Data()
        output.reserveCapacity(Int(cap))
        do {
            _ = try archive.extract(entry) { chunk in
                try Task.checkCancellation()
                guard UInt64(output.count + chunk.count) <= cap else {
                    throw EpubError.resourceTooLarge(path)
                }
                output.append(chunk)
            }
        } catch let error as EpubError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EpubError.unsafeArchive("“\(path)” is corrupt")
        }
        return output
    }

    func xmlDocument(at path: String) throws -> EpubXMLElement {
        try EpubXML.parse(data(at: path, maxSize: limits.maxXMLSize), source: path)
    }

    /// ZIP entry names must be relative, forward-slash paths that stay inside
    /// the archive root.
    static func isSafeEntryPath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains("\0")
        else { return false }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        if let first = components.first, first.count == 2, first.hasSuffix(":") { return false }
        return !components.contains("..")
    }
}

/// Resolution of publisher hrefs to archive-relative paths.
enum EpubPath {
    /// Resolves `href` as written inside `baseFile` (an archive path; "" for the
    /// archive root). Returns nil for external URLs, absolute paths and paths
    /// that would climb above the archive root. A bare `#fragment` resolves to
    /// `baseFile` itself.
    static func resolve(_ href: String, relativeTo baseFile: String) -> (path: String, fragment: String?)? {
        var body = Substring(href.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !body.isEmpty else { return nil }
        var fragment: String?
        if let hash = body.firstIndex(of: "#") {
            let raw = String(body[body.index(after: hash)...])
            let decoded = raw.removingPercentEncoding ?? raw
            fragment = decoded.isEmpty ? nil : decoded
            body = body[..<hash]
        }
        if let query = body.firstIndex(of: "?") {
            body = body[..<query]
        }
        if let colon = body.firstIndex(of: ":"), !body[..<colon].contains("/") {
            return nil
        }
        guard !body.hasPrefix("/"), !body.contains("\\"),
              let decoded = String(body).removingPercentEncoding,
              !decoded.contains("\0")
        else { return nil }
        if decoded.isEmpty {
            return baseFile.isEmpty ? nil : (baseFile, fragment)
        }
        var components = directory(of: baseFile).split(separator: "/").map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".":
                continue
            case "..":
                guard !components.isEmpty else { return nil }
                components.removeLast()
            default:
                components.append(String(part))
            }
        }
        guard !components.isEmpty else { return nil }
        return (components.joined(separator: "/"), fragment)
    }

    static func directory(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
