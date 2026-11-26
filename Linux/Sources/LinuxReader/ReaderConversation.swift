import Foundation
import VellumCore

/// Read a projection for display, but never transcode an existing message to
/// write it back. Even a future role or reference stays byte-for-byte intact.
public struct ReaderConversation: Sendable {
    private struct DisplayMessage: Decodable {
        let text: ConversationText?
        init(from decoder: Decoder) { text = try? ConversationText(from: decoder) }
    }

    private let url: URL
    private let original: Data?
    private let hasElements: Bool
    public let messageIDs: Set<String>
    public let messages: [ConversationText]

    @concurrent
    public static func load(key: String, from store: ReadOnlyLibraryFileStore) async throws -> Self {
        guard DocumentIdentity.isCanonicalKey(key) else { throw LibraryFileError.unavailable }
        let url = store.root.url.appendingPathComponent(".vellum/documents/\(key)/conversations.json")
        let data = try await store.read(url)
        let envelopes = try data.map { try JSONDecoder().decode([DisplayMessage].self, from: $0) } ?? []
        let messages = envelopes.compactMap(\.text).suffix(ConversationText.messageLimit)
        return Self(url: url, original: data, hasElements: !envelopes.isEmpty,
                    messageIDs: Set(envelopes.compactMap { $0.text?.id }), messages: messages.map { message in
            ConversationText(id: message.id, role: message.role, content: ConversationText.limitedContent(message.content),
                             createdAt: message.createdAt)
        })
    }

    public func save(appending turns: [ConversationText],
                     replace: @Sendable (URL, Data, Data?) async throws -> Bool) async throws -> Bool {
        guard !turns.isEmpty else { return true }
        var bytes = original ?? Data("[]".utf8)
        guard let end = bytes.lastIndex(where: { ![9, 10, 13, 32].contains($0) }), bytes[end] == 93 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let encoded = try JSONEncoder().encode(turns)
        var addition = Data()
        if hasElements { addition.append(44) }
        addition.append(contentsOf: encoded.dropFirst().dropLast())
        guard bytes.count + addition.count <= 32 * 1024 * 1024 else { throw ReaderFileError.fileTooLarge }
        bytes.insert(contentsOf: addition, at: end)
        return try await replace(url, bytes, original)
    }
}
