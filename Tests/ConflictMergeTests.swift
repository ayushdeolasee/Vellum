import Foundation
import Testing

@testable import Vellum

@Suite("Coordination seam — typed conflict merges")
struct ConflictMergeTests {
    private static let current = ConflictVersion(id: "current", isCurrent: true)
    private static let loser = ConflictVersion(id: "loser")

    @Test("Conversation conflicts union messages while the current side wins collisions")
    func conversationsUnionByID() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/documents/key/conversations.json")
        let current = [message("same", "current", "2026-08-05T09:00:00Z")]
        let loser = [
            message("same", "loser", "2026-08-05T08:00:00Z"),
            message("new", "new", "2026-08-05T10:00:00Z"),
        ]
        let container = FakeSyncedContainer()
        container.seed(target, data: try JSONEncoder().encode(current))
        container.injectConflict(
            at: target,
            versions: [Self.current, Self.loser],
            payloads: ["loser": try JSONEncoder().encode(loser)])

        let resolution = try await container.resolveConflict(event(target))
        let merged = try JSONDecoder().decode(
            [AiMessage].self, from: #require(container.peek(target)))

        #expect(resolution == .merged(target))
        #expect(merged.map(\.id) == ["same", "new"])
        #expect(merged.first?.content == "current")
    }

    @Test("An unreadable current conversation defers without touching its bytes")
    func unreadableCurrentConversationDefers() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/documents/key/conversations.json")
        let unreadable = Data("not-json".utf8)
        let container = FakeSyncedContainer()
        container.seed(target, data: unreadable)
        container.injectConflict(
            at: target,
            versions: [Self.current, Self.loser],
            payloads: ["loser": try JSONEncoder().encode([message("new", "new", "2026-08-05T10:00:00Z")])])

        let resolution = try await container.resolveConflict(event(target))

        #expect(resolution == .deferred)
        #expect(container.peek(target) == unreadable)
        #expect(container.hasUnresolvedConflict(at: target))
    }

    @Test("Document metadata keeps the newest path and a nonempty title")
    func metadataUsesNewestVisit() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/documents/key/meta.json")
        let current = DocumentDataStore.Meta(
            version: 1, kind: "pdf", title: "Known title", lastKnownPath: "/old.pdf",
            lastOpened: "2026-08-05T08:00:00.000000+00:00")
        let loser = DocumentDataStore.Meta(
            version: 1, kind: "pdf", title: nil, lastKnownPath: "/new.pdf",
            lastOpened: "2026-08-05T10:00:00.000000+00:00")
        let container = FakeSyncedContainer()
        container.seed(target, data: try JSONEncoder().encode(current))
        container.injectConflict(
            at: target, versions: [Self.current, Self.loser],
            payloads: ["loser": try JSONEncoder().encode(loser)])

        _ = try await container.resolveConflict(event(target))
        let merged = try JSONDecoder().decode(
            DocumentDataStore.Meta.self, from: #require(container.peek(target)))

        #expect(merged.lastKnownPath == "/new.pdf")
        #expect(merged.lastOpened == loser.lastOpened)
        #expect(merged.title == "Known title")
    }

    @Test("Scratchpad conflicts preserve the losing bytes instead of merging text")
    func scratchpadPreservesLoser() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/documents/key/scratchpad.md")
        let container = FakeSyncedContainer()
        container.seed(target, data: Data("current".utf8))
        container.injectConflict(
            at: target, versions: [Self.current, Self.loser],
            payloads: ["loser": Data("loser".utf8)])

        let resolution = try await container.resolveConflict(event(target))
        let archive = target.deletingLastPathComponent()
            .appendingPathComponent("conflicts/scratchpad.loser.md")

        #expect(resolution == .keptCurrent(archivedLosers: [archive]))
        #expect(container.peek(target) == Data("current".utf8))
        #expect(container.peek(archive) == Data("loser".utf8))
    }

    private func event(_ url: URL) -> ConflictEvent {
        ConflictEvent(url: url, detectedAt: .now, versions: [Self.current, Self.loser])
    }

    private func message(_ id: String, _ content: String, _ createdAt: String) -> AiMessage {
        AiMessage(id: id, role: .user, content: content, createdAt: createdAt)
    }
}
