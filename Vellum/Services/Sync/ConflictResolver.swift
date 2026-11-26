import Foundation
import VellumCore

typealias ConflictResolver = VellumCore.ConflictResolver
typealias PreserveLosersConflictResolver = VellumCore.PreserveLosersConflictResolver

extension PreserveLosersConflictResolver {
    init(archive: @escaping @Sendable (URL, Data) async throws -> Void = Self.writeAtomically) {
        self.init(merge: ConflictMerge.decide, archive: archive)
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

enum ConflictMerge {
    static func decide(_ event: ConflictEvent, reading: PreserveLosersConflictResolver.Reader) async throws
        -> PreserveLosersConflictResolver.Decision {
        let url = event.url
        if url.pathExtension == "json", !url.lastPathComponent.hasSuffix(".ink.json"),
           url.deletingLastPathComponent().lastPathComponent == "records",
           let data = try await mergeWebRecord(event, reading: reading) {
            return .merged(data)
        }
        if url.lastPathComponent == "conversations.json" {
            switch try await mergeConversations(event, reading: reading) {
            case .merged(let bytes): return .merged(bytes)
            case .preserve: return .preserve
            case .deferred: return .deferred
            }
        }
        if url.lastPathComponent == "meta.json", let data = try await mergeMeta(event, reading: reading) {
            return .merged(data)
        }
        return .preserve
    }

    static func mergeWebRecord(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> Data? {
        let decoder = JSONDecoder()
        guard let currentVersion = event.currentVersion else { return nil }
        let currentBytes = try await reading(currentVersion)
        guard var merged = try? decoder.decode(WebPageRecord.self, from: currentBytes) else {
            return nil
        }

        var losers: [WebPageRecord] = []
        let ids = Set(merged.annotations.map(\.id))
        guard ids.count == merged.annotations.count else { return nil }
        for version in event.losingVersions {
            let bytes = try await reading(version)
            guard let loser = try? decoder.decode(WebPageRecord.self, from: bytes) else { return nil }
            let losingIDs = Set(loser.annotations.map(\.id))
            // Absence has no version information. It may mean either a new
            // addition or a deletion, and a differing saved flag may be an unsave.
            // Decide for every version before writing any automatic merge.
            guard loser.saved == merged.saved, losingIDs == ids,
                  losingIDs.count == loser.annotations.count else { return nil }
            losers.append(loser)
        }
        for loser in losers { mergeWebPageRecord(&merged, loser) }
        return try WebLibrary.jsonEncoderPretty.encode(merged)
    }

    private static func mergeWebPageRecord(_ current: inout WebPageRecord, _ incoming: WebPageRecord) {
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
        current.unknownFields.fillMissing(from: incoming.unknownFields)
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

    enum ConversationMerge {
        case merged(Data)
        case preserve
        case deferred
    }

    static func mergeConversations(
        _ event: ConflictEvent,
        reading: @Sendable (ConflictVersion) async throws -> Data
    ) async throws -> ConversationMerge {
        guard let currentVersion = event.currentVersion else { return .deferred }
        let currentBytes = try await reading(currentVersion)
        guard let current = try? JSONDecoder().decode([AiMessage].self, from: currentBytes)
        else { return .deferred }
        var merged = current
        let ids = Set(current.map(\.id))
        guard ids.count == current.count else { return .preserve }
        for version in event.losingVersions {
            let bytes = try await reading(version)
            guard let incoming = try? JSONDecoder().decode([AiMessage].self, from: bytes)
            else { return .deferred }
            let losingIDs = Set(incoming.map(\.id))
            guard losingIDs == ids, losingIDs.count == incoming.count else { return .preserve }
            let byID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
            for index in merged.indices {
                if let other = byID[merged[index].id] { merged[index].inheritUnknownFields(from: other) }
            }
        }
        // Same-ID edits retain current bytes, including the digest used to
        // confirm a replacement after Clear. Re-encoding unchanged messages
        // would turn that verified copy into unknown data on the next load.
        // Changed membership cannot be distinguished from Clear.
        guard merged != current else { return .merged(currentBytes) }
        let key = event.url.deletingLastPathComponent().lastPathComponent
        // A journaled Clear verifies the exact winning bytes. Keep the loser
        // as a recovery copy until the user resolves that case.
        guard try ConversationOperationJournal.read(key) == nil else { return .preserve }
        // A reference with a newer discriminator is intentionally unreadable
        // in the UI. Re-encoding its enclosing message would drop that chip.
        struct References: Decodable { var references: [AiReference]? }
        guard (try? JSONDecoder().decode([References].self, from: currentBytes)) != nil
        else { return .preserve }
        return .merged(try WebLibrary.jsonEncoderPretty.encode(merged))
    }

    static func mergeMeta(
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
            var extras = merged.unknownFields
            extras.fillMissing(from: incoming.unknownFields)
            if incomingDate > mergedDate {
                let olderTitle = merged.title
                merged = incoming
                merged.title = incoming.title ?? olderTitle
            } else if merged.title == nil {
                merged.title = incoming.title
            }
            merged.unknownFields = extras
        }
        return try WebLibrary.jsonEncoderPretty.encode(merged)
    }
}
