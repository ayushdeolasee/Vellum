import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing AI provider API keys as
/// generic passwords. All keys live under one service; the account string is
/// the provider identifier (e.g. "gemini", "openai", "openrouter").
enum KeychainStore {
    static let service = "com.vellum.ai"

    /// Returns the stored secret for an account, or nil if absent/unreadable.
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return nil }
        return value
    }

    /// Stores (or updates) the secret for an account. An empty value deletes it.
    /// Returns `true` only when the Keychain reflects the requested state, so
    /// callers can avoid dropping the plaintext copy before the write lands.
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return delete(account)
        }
        let data = Data(trimmed.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = baseQuery
            addQuery[kSecValueData as String] = data
            return SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    /// Removes the secret for an account. Returns `true` when the account is
    /// absent afterwards (either deleted now or already missing).
    @discardableResult
    static func delete(_ account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // Account identifiers, one per provider with a stored secret.
    enum Account {
        static let gemini = "gemini"
        static let openai = "openai"
        static let openrouter = "openrouter"
        static let opencode = "opencode"
        static let opencodeGo = "opencode-go"
        /// JSON blob of the ChatGPT OAuth tokens (access/refresh/id/account id).
        static let chatgptTokens = "chatgpt-tokens"
    }
}
