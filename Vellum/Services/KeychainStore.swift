import Foundation
import Security

/// Thin wrapper over the macOS Keychain for storing AI provider API keys as
/// generic passwords. All keys live under one service; the account string is
/// the provider identifier (e.g. "gemini", "openai", "openrouter").
enum KeychainStore {
    /// The production service remains stable for existing credentials. UI tests
    /// reserve a separate name and use the inert backend below, so a test launch
    /// cannot read, migrate, overwrite, or delete a real user's credentials.
    static let productionService = "com.vellum.ai"
    static let uiTestService = "com.vellum.ai.uitesting"
    static var service: String {
        UITestLaunchConfiguration.isEnabled ? uiTestService : productionService
    }

    private static let backend: any Backend = {
        if UITestLaunchConfiguration.isEnabled {
            return InertBackend()
        }
        return SecurityBackend(service: service)
    }()

    /// Returns the stored secret for an account, or nil if absent/unreadable.
    static func get(_ account: String) -> String? {
        backend.get(account)
    }

    /// Stores (or updates) the secret for an account. An empty value deletes it.
    /// Returns `true` only when the Keychain reflects the requested state, so
    /// callers can avoid dropping the plaintext copy before the write lands.
    @discardableResult
    static func set(_ account: String, _ value: String) -> Bool {
        backend.set(account, value)
    }

    /// Removes the secret for an account. Returns `true` when the account is
    /// absent afterwards (either deleted now or already missing).
    @discardableResult
    static func delete(_ account: String) -> Bool {
        backend.delete(account)
    }

    private protocol Backend: Sendable {
        func get(_ account: String) -> String?
        func set(_ account: String, _ value: String) -> Bool
        func delete(_ account: String) -> Bool
    }

    /// Production backend. Keep all Security calls here so the UI-test backend
    /// cannot accidentally reach the production service through a new path.
    private struct SecurityBackend: Backend {
        let service: String

        func get(_ account: String) -> String? {
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

        func set(_ account: String, _ value: String) -> Bool {
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

        func delete(_ account: String) -> Bool {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
    }

    /// UI tests exercise the app's configuration flow, not Keychain services.
    /// Treat writes/deletes as successful while retaining no data, which leaves
    /// every test launch credential-free and performs no Security operation.
    private struct InertBackend: Backend {
        func get(_ account: String) -> String? { nil }
        func set(_ account: String, _ value: String) -> Bool { true }
        func delete(_ account: String) -> Bool { true }
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
