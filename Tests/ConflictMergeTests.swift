import Foundation
import Testing

@testable import Vellum

@Suite("Coordination seam — typed conflict merges")
struct ConflictMergeTests {
    private static let current = ConflictVersion(id: "current", isCurrent: true)
    private static let loser = ConflictVersion(id: "loser")

    @Test("Same-ID conversation edits keep current message contents")
    func conversationsUnionByID() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/documents/key/conversations.json")
        let current = [message("same", "current", "2026-08-05T09:00:00Z")]
        let loser = [
            message("same", "loser", "2026-08-05T08:00:00Z"),
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
        #expect(merged.map(\.id) == ["same"])
        #expect(merged.first?.content == "current")
    }

    @Test("Clear and addition ambiguity preserves conversations in both conflict orders")
    func conversationMembershipNeedsReview() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/documents/key/conversations.json")
        let history = [message("old", "old", "2026-08-05T10:00:00Z")]
        for (current, losing) in [(history, [AiMessage]()), ([AiMessage](), history)] {
            let currentBytes = try JSONEncoder().encode(current)
            let losingBytes = try JSONEncoder().encode(losing)
            let container = FakeSyncedContainer()
            container.seed(target, data: currentBytes)
            container.injectConflict(at: target, versions: [Self.current, Self.loser],
                                     payloads: ["loser": losingBytes])
            let resolution = try await container.resolveConflict(event(target))
            let archive = PreserveLosersConflictResolver.archiveURL(for: target, version: Self.loser)
            #expect(resolution == .keptCurrent(archivedLosers: [archive]))
            #expect(container.peek(target) == currentBytes)
            #expect(container.peek(archive) == losingBytes)
            // A repeated event has the same outcome without unioning either copy.
            container.injectConflict(at: target, versions: [Self.current, Self.loser],
                                     payloads: ["loser": losingBytes])
            _ = try await container.resolveConflict(event(target))
            #expect(container.peek(target) == currentBytes)
        }
    }

    @Test("Unsave and annotation membership ambiguity preserves every web version")
    func webMembershipNeedsReviewBeforeAnyMerge() async throws {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/records/key.json")
        let cases: [(Bool, Bool, [String], [String])] = [
            (false, true, ["a"], ["a"]),
            (true, true, [], ["a"]),
            (true, true, ["a"], ["a", "b"]),
        ]
        for (saved, losingSaved, ids, losingIDs) in cases {
            var first = WebPageRecord(url: "https://example.com/article")
            first.saved = saved
            first.annotations = ids.map(annotation)
            var second = first
            second.saved = losingSaved
            second.annotations = losingIDs.map(annotation)
            for (current, losing) in [(first, second), (second, first)] {
                let currentBytes = try WebLibrary.jsonEncoderPretty.encode(current)
                let losingBytes = try WebLibrary.jsonEncoderPretty.encode(losing)
                // A same-membership edit comes before the ambiguous version.
                // It must not be committed before all versions are considered.
                var edited = current
                edited.title = "metadata edit"
                let editVersion = ConflictVersion(id: "edited")
                let versions = [Self.current, editVersion, Self.loser]
                let container = FakeSyncedContainer()
                container.seed(target, data: currentBytes)
                container.injectConflict(at: target, versions: versions, payloads: [
                    "edited": try WebLibrary.jsonEncoderPretty.encode(edited), "loser": losingBytes])
                let resolution = try await container.resolveConflict(
                    ConflictEvent(url: target, detectedAt: .now, versions: versions))
                let archives = [editVersion, Self.loser].map {
                    PreserveLosersConflictResolver.archiveURL(for: target, version: $0)
                }
                #expect(resolution == .keptCurrent(archivedLosers: archives))
                #expect(container.peek(target) == currentBytes)
                #expect(container.peek(archives[1]) == losingBytes)
            }
        }
    }

    private func annotation(_ id: String) -> Annotation {
        Annotation(id: id, type: .note, pageNumber: 1, color: nil, content: id,
                   positionData: nil, createdAt: "2026-08-05T10:00:00Z", updatedAt: "2026-08-05T10:00:00Z")
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
            unknownFields: ["same": .null], version: 1, kind: "pdf", title: "Known title", lastKnownPath: "/old.pdf",
            lastOpened: "2026-08-05T08:00:00.000000+00:00")
        let loser = DocumentDataStore.Meta(
            unknownFields: ["same": .bool(true), "more": .int(4)], version: 1, kind: "pdf", title: nil, lastKnownPath: "/new.pdf",
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
        #expect(merged.unknownFields == ["same": .null, "more": .int(4)])
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

extension ConflictMergeTests {
    private func resolve<T: Codable>(current: T, loser: T, path: String) async throws -> T {
        let target = URL(fileURLWithPath: "/Vellum/.vellum/" + path)
        let container = FakeSyncedContainer()
        container.seed(target, data: try JSONEncoder().encode(current))
        container.injectConflict(at: target, versions: [Self.current, Self.loser],
                                 payloads: ["loser": try JSONEncoder().encode(loser)])
        let resolution = try await container.resolveConflict(event(target))
        #expect(resolution == .merged(target))
        return try JSONDecoder().decode(T.self, from: #require(container.peek(target)))
    }

    @Test("Newer annotation geometry wins while overlapping unknown keys keep the current value")
    func nestedWebUnion() async throws {
        var current = WebPageRecord(url: "https://example.test")
        var a = annotation("a")
        a.positionData = .init(rects: [.init(x: 1, y: 2, width: 3, height: 4)], pageWidth: 5, pageHeight: 6)
        let own: [String: PositionJSON] = ["same": .null]
        current.unknownFields = own
        a.unknownFields = own
        a.positionData?.unknownFields = own
        a.positionData?.rects[0].unknownFields = own
        current.annotations = [a]
        let other: [String: PositionJSON] = ["same": .bool(false), "next": .int(Int.max)]
        var incoming = current
        incoming.unknownFields = other
        incoming.annotations[0].updatedAt = "2026-08-06T10:00:00Z"
        incoming.annotations[0].positionData?.rects[0].x = 100
        incoming.annotations[0].unknownFields = other
        incoming.annotations[0].positionData?.unknownFields = other
        incoming.annotations[0].positionData?.rects[0].unknownFields = other
        let result = try await resolve(current: current, loser: incoming, path: "records/key.json")
        let ann = try #require(result.annotations.first)
        let pos = try #require(ann.positionData)
        #expect(pos.rects[0].x == 100)
        for bag in [result.unknownFields, ann.unknownFields, pos.unknownFields, pos.rects[0].unknownFields] {
            #expect(bag == ["same": .null, "next": .int(Int.max)])
        }
    }

    @Test("Transcript merge and save caps preserve fields in matching reference, payload, image, source and usage")
    func nestedConversationUnion() async throws {
        let json = #"""
        {"id":"m","createdAt":"t","role":"user","content":"old","same":null,
         "usage":{"inputTokens":1,"cachedInputTokens":0,"cacheWriteTokens":0,"reasoningTokens":0,"outputTokens":0},
         "references":[{"id":"r","kind":{"tag":"image","name":"photo","image":{"base64Data":"AQ==","mediaType":"png","width":1,"height":1}}}],
         "toolSummaries":[{"id":"s","title":"tool","sources":[{"id":"url","excerpt":"here"}]}]}
        """#
        let current = try JSONDecoder().decode(AiMessage.self, from: Data(json.utf8))
        let other = json.replacingOccurrences(of: "{", with: #"{"next":9223372036854775807,"#)
            .replacingOccurrences(of: #""same":null"#, with: #""same":false"#)
            .replacingOccurrences(of: #""content":"old""#, with: #""content":"loser""#)
        let incoming = try JSONDecoder().decode(AiMessage.self, from: Data(other.utf8))
        let merged = try await resolve(current: [current], loser: [incoming],
                                       path: "documents/" + UUID().uuidString + "/conversations.json")
        let message = try #require(AiPersistence.limitedMessages(merged).first)
        #expect(message.content == "old")
        #expect(message.unknownFields["same"] == .null)
        let ref = try #require(message.references.first)
        #expect(ref.image?.base64Data == "")
        let source = try #require(message.toolSummaries?.first)
        for bag in [message.unknownFields, message.usage?.unknownFields, ref.unknownFields,
                    ref.kindUnknownFields, ref.image?.unknownFields, source.unknownFields,
                    source.sources.first?.unknownFields] {
            #expect(bag?["next"] == .int(Int.max))
        }
    }
}

extension ConflictMergeTests {
    @Test("Ink conflicts archive original bytes without applying page defaults")
    func inkConflictsKeepBothCanvases() async throws {
        let url = URL(fileURLWithPath: "/Vellum/.vellum/records/key.ink.json")
        let current = Data(#"{"url":"u","version":3,"clusters":[],"future":1}"#.utf8)
        let loser = Data(#"{"url":"u","version":3,"clusters":[],"future":2}"#.utf8)
        let container = FakeSyncedContainer()
        container.seed(url, data: current)
        container.injectConflict(at: url, versions: [Self.current, Self.loser], payloads: ["loser": loser])
        let resolution = try await container.resolveConflict(event(url))
        let archive = PreserveLosersConflictResolver.archiveURL(for: url, version: Self.loser)
        #expect(resolution == .keptCurrent(archivedLosers: [archive]))
        #expect(container.peek(url) == current)
        #expect(container.peek(archive) == loser)
    }
}
