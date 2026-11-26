import Foundation

/// Required fields of an Apple conversations.json message. Rich references,
/// usage and tool summaries are owned by their respective feature codecs.
public struct ConversationText: Codable, Sendable, Equatable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: String
    public let role: Role
    public let content: String
    public let createdAt: String

    public init(id: String, role: Role, content: String, createdAt: String) {
        self.id = id
        self.role = role
        self.content = content
        self.createdAt = createdAt
    }

    public static func limitedContent(_ text: String) -> String {
        let prefix = text.prefix(characterLimit)
        return prefix.endIndex == text.endIndex ? text : String(prefix) + "\n[truncated]"
    }

    public static let messageLimit = 120
    public static let characterLimit = 12_000
}
