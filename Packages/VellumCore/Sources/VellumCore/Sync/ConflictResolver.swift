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
        switch try await merge(event, reading) {
        case .merged(let bytes):
            try await archive(event.url, bytes)
            return .merged(event.url)
        case .deferred:
            return .deferred
        case .preserve:
            var archived: [URL] = []
            for version in event.losingVersions {
                let destination = Self.archiveURL(for: event.url, version: version)
                try await archive(destination, reading(version))
                archived.append(destination)
            }
            return .keptCurrent(archivedLosers: archived)
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
