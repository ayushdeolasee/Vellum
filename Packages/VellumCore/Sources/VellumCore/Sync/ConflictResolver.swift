import Foundation

/// The injected merge hook. `reading` hands the resolver each version's bytes,
/// so merge policy stays a function over `Data` and never has to import
/// `NSFileVersion`.
public protocol ConflictResolver: Sendable {
    func resolve(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> ConflictResolution
}

/// The policy is independent of file coordination and the application's record models.
public struct PreserveLosersConflictResolver: ConflictResolver {
    public enum Decision: Sendable {
        case merged(Data), preserve, deferred
    }

    public typealias Reader = @Sendable (ConflictVersion) async throws -> Data
    public typealias Merge = @Sendable (ConflictEvent, Reader) async throws -> Decision
    private let merge: Merge
    private let archive: @Sendable (URL, Data) async throws -> Void

    public init(merge: @escaping Merge, archive: @escaping @Sendable (URL, Data) async throws -> Void) {
        self.merge = merge
        self.archive = archive
    }

    public func resolve(_ event: ConflictEvent, reading: Reader) async throws -> ConflictResolution {
        let decision = try await merge(event, reading)
        return try await Self.apply(decision, to: event, archiveOnMerge: false, replace: { data in
            try await archive(event.url, data)
        }, preserve: { version in
            let destination = Self.archiveURL(for: event.url, version: version)
            try await archive(destination, reading(version))
            return destination
        })
    }

    /// Folder recovery moves the actual losing inode, while iCloud archives a
    /// coordinated NSFileVersion. Both commit only after the merge policy returns.
    static func apply(
        _ decision: Decision, to event: ConflictEvent, archiveOnMerge: Bool,
        replace: (Data) async throws -> Void, preserve: (ConflictVersion) async throws -> URL
    ) async throws -> ConflictResolution {
        switch decision {
        case .deferred: return .deferred
        case .merged(let bytes):
            try await replace(bytes)
            if archiveOnMerge {
                for version in event.losingVersions { _ = try await preserve(version) }
            }
            return .merged(event.url)
        case .preserve:
            var archives: [URL] = []
            for version in event.losingVersions { archives.append(try await preserve(version)) }
            return .keptCurrent(archivedLosers: archives)
        }
    }

    public static func archiveURL(for url: URL, version: ConflictVersion) -> URL {
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

}
