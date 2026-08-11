import Foundation

/// The injected merge hook. `reading` hands the resolver each version's bytes,
/// so merge policy stays a function over `Data` and never has to import
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
/// Web sidecars merge user-owned fields and annotations. Unknown JSON and every
/// other file type keep the conservative policy: preserve each losing version
/// verbatim before marking the conflict resolved.
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
        if isWebRecord(event.url),
           let merged = try await mergeWebPageRecord(event, reading: reading) {
            try await archive(event.url, merged)
            return .merged(event.url)
        }
        if event.url.lastPathComponent == "conversations.json" {
            guard let merged = try await mergeConversations(event, reading: reading) else {
                return .deferred
            }
            try await archive(event.url, merged)
            return .merged(event.url)
        }
        if event.url.lastPathComponent == "meta.json",
           let merged = try await mergeMeta(event, reading: reading) {
            try await archive(event.url, merged)
            return .merged(event.url)
        }
        if event.url.deletingLastPathComponent().lastPathComponent == "positions" {
            NSLog("[Vellum] Position conflict at %@: one device record was written by multiple peers; preserving every version", event.url.path)
        }

        var archived: [URL] = []
        for version in event.losingVersions {
            let data = try await reading(version)
            let destination = Self.archiveURL(for: event.url, version: version)
            try await archive(destination, data)
            archived.append(destination)
        }
        return .keptCurrent(archivedLosers: archived)
    }

    private func isWebRecord(_ url: URL) -> Bool {
        return url.pathExtension == "json"
            && url.deletingLastPathComponent().lastPathComponent == "records"
    }

    private func mergeWebPageRecord(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> Data? {
        let decoder = JSONDecoder()
        guard let currentVersion = event.currentVersion else { return nil }
        let currentBytes = try await reading(currentVersion)
        guard var merged = try? decoder.decode(WebPageRecord.self, from: currentBytes) else {
            return nil
        }

        for version in event.losingVersions {
            let bytes = try await reading(version)
            guard let loser = try? decoder.decode(WebPageRecord.self, from: bytes) else {
                return nil
            }
            mergeWebPageRecord(&merged, loser)
        }
        return try WebLibrary.jsonEncoderPretty.encode(merged)
    }

    private func mergeWebPageRecord(_ current: inout WebPageRecord, _ incoming: WebPageRecord) {
        if current.url.isEmpty { current.url = incoming.url }
        current.saved = current.saved || incoming.saved
        current.savedAt = current.savedAt ?? incoming.savedAt
        current.title = current.title ?? incoming.title
        current.pageCount = current.pageCount ?? incoming.pageCount
        current.lastPage = current.lastPage ?? incoming.lastPage
        if current.loadingPolicy != "snapshot-only",
           incoming.loadingPolicy == "snapshot-only" {
            current.loadingPolicy = "snapshot-only"
        } else {
            current.loadingPolicy = current.loadingPolicy ?? incoming.loadingPolicy
        }
        WebArchive.mergeAnnotations(&current.annotations, incoming: incoming.annotations)
        current.annotations.sort { lhs, rhs in
            if lhs.pageNumber != rhs.pageNumber {
                return lhs.pageNumber < rhs.pageNumber
            }
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt < rhs.updatedAt
            }
            return lhs.id < rhs.id
        }
        current.openedAt = current.openedAt ?? incoming.openedAt
    }

    private func mergeConversations(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> Data? {
        guard let currentVersion = event.currentVersion else { return nil }
        let currentBytes = try await reading(currentVersion)
        guard let current = try? JSONDecoder().decode([AiMessage].self, from: currentBytes)
        else { return nil }
        var byID: [String: AiMessage] = [:]
        for message in current where byID[message.id] == nil {
            byID[message.id] = message
        }
        for version in event.losingVersions {
            let bytes = try await reading(version)
            guard let incoming = try? JSONDecoder().decode([AiMessage].self, from: bytes) else {
                return nil
            }
            for message in incoming where byID[message.id] == nil {
                byID[message.id] = message
            }
        }
        let merged = AiPersistence.limitedMessages(
            byID.values.sorted {
                $0.createdAt == $1.createdAt ? $0.id < $1.id : $0.createdAt < $1.createdAt
            })
        return try JSONEncoder().encode(merged)
    }

    private func mergeMeta(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> Data? {
        guard let currentVersion = event.currentVersion else { return nil }
        let currentBytes = try await reading(currentVersion)
        guard var merged = try? JSONDecoder().decode(
            DocumentDataStore.Meta.self, from: currentBytes) else { return nil }
        for version in event.losingVersions {
            let bytes = try await reading(version)
            guard let incoming = try? JSONDecoder().decode(DocumentDataStore.Meta.self, from: bytes)
            else { return nil }
            let mergedDate = WebLibrary.parseRfc3339(merged.lastOpened) ?? .distantPast
            let incomingDate = WebLibrary.parseRfc3339(incoming.lastOpened) ?? .distantPast
            if incomingDate > mergedDate {
                let olderTitle = merged.title
                merged = incoming
                merged.title = incoming.title ?? olderTitle
            } else if merged.title == nil {
                merged.title = incoming.title
            }
        }
        return try WebLibrary.jsonEncoderPretty.encode(merged)
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
