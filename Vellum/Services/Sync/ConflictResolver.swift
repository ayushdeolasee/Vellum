import Foundation

/// The injected merge hook. Detection is what the seam ships; a real content
/// merge arrives later and slots in here without a line of detection code
/// changing. `reading` hands the resolver each version's bytes, so a merge
/// implementation is a function over `Data` and never has to import
/// `NSFileVersion`.
protocol ConflictResolver: Sendable {
    func resolve(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> ConflictResolution
}

/// The default shipping policy. Keeps the current version, copies every losing
/// version aside to `<dir>/conflicts/<name>.<versionID>.<ext>`, and reports
/// them archived so the caller can mark them resolved.
///
/// It performs NO content merge — that is deliberate and asserted by the test
/// suite. A literal no-op resolver would leave conflicts unresolved until the
/// system garbage-collects the losing versions, which is a silent drop; this is
/// the cleanup half that TN2336 concedes is the minimum bar.
struct PreserveLosersConflictResolver: ConflictResolver {
    /// Where a losing version's bytes are copied. Injected so the container can
    /// route the copy back through coordination instead of writing behind it.
    let archive: @Sendable (URL, Data) async throws -> Void

    init(archive: @escaping @Sendable (URL, Data) async throws -> Void = PreserveLosersConflictResolver.writeAtomically) {
        self.archive = archive
    }

    func resolve(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> ConflictResolution {
        var archived: [URL] = []
        for version in event.losingVersions {
            let data = try await reading(version)
            let destination = Self.archiveURL(for: event.url, version: version)
            try await archive(destination, data)
            archived.append(destination)
        }
        return .keptCurrent(archivedLosers: archived)
    }

    static func archiveURL(for url: URL, version: ConflictVersion) -> URL {
        let directory = url.deletingLastPathComponent()
            .appendingPathComponent("conflicts", isDirectory: true)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let id = sanitized(version.id)
        let name = ext.isEmpty ? "\(stem).\(id)" : "\(stem).\(id).\(ext)"
        return directory.appendingPathComponent(name)
    }

    /// A version identifier is opaque and may contain path separators.
    private static func sanitized(_ id: String) -> String {
        let allowed = id.map { character -> Character in
            character.isLetter || character.isNumber || character == "-" ? character : "-"
        }
        return String(allowed)
    }

    /// Fallback used when nobody injects a writer: the same tmp+rename the rest
    /// of the app uses.
    static let writeAtomically: @Sendable (URL, Data) async throws -> Void = { url, data in
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw SyncedContainerError.io("Failed to create conflicts dir: \(error.localizedDescription)")
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp)
        } catch {
            throw SyncedContainerError.io("Failed to archive conflict version: \(error.localizedDescription)")
        }
        guard rename(tmp.path, url.path) == 0 else {
            try? fileManager.removeItem(at: tmp)
            throw SyncedContainerError.io("Failed to commit archived conflict version")
        }
    }
}
