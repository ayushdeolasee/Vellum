import Foundation

enum AiPersistence {
    static let settingsKey = "research-reader-ai-settings-v1"
    static let conversationsKey = "research-reader-ai-conversations-v1"
    static let maxMessagesPerDocument = 120
    static let maxMessageCharacters = 12_000
    static let maxDocuments = 25

    private struct ConversationEntry {
        var key: String
        var messages: [AiMessage]
    }

    static func loadSettings() -> AiSettings {
        let defaults = AiSettings()
        guard let raw = UserDefaults.standard.string(forKey: settingsKey),
              let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // No stored blob yet: still surface any keys already in the Keychain.
            var settings = defaults
            settings.apiKey = KeychainStore.get(KeychainStore.Account.gemini) ?? ""
            settings.openaiApiKey = KeychainStore.get(KeychainStore.Account.openai) ?? ""
            settings.openrouterApiKey = KeychainStore.get(KeychainStore.Account.openrouter) ?? ""
            settings.opencodeApiKey = KeychainStore.get(KeychainStore.Account.opencode) ?? ""
            settings.opencodeGoApiKey = KeychainStore.get(KeychainStore.Account.opencodeGo) ?? ""
            return settings
        }

        var settings = defaults
        if let provider = value["provider"] as? String {
            settings.provider = AiProvider(rawValue: provider) ?? .gemini
        }
        if let model = value["model"] as? String { settings.model = model }
        if let model = value["openaiModel"] as? String { settings.openaiModel = model }
        if let model = value["openrouterModel"] as? String { settings.openrouterModel = model }
        if let model = value["chatgptModel"] as? String { settings.chatgptModel = model }
        if let model = value["opencodeModel"] as? String { settings.opencodeModel = model }
        if let model = value["opencodeGoModel"] as? String { settings.opencodeGoModel = model }
        if let pinned = value["pinnedModels"] as? [String] { settings.pinnedModels = pinned }
        settings.voiceMode = value["voiceMode"] as? String == "push-to-talk" ? .pushToTalk : .off
        if let enabled = value["ttsEnabled"] as? Bool { settings.ttsEnabled = enabled }
        if let effort = value["reasoningEffort"] as? String { settings.reasoningEffort = AiThinkingMode(rawValue: effort) ?? .auto }

        // Keys now live in the Keychain. Migrate any legacy plaintext keys still
        // present in the UserDefaults blob, then prefer the Keychain copy.
        var didMigrate = false
        migrate(account: KeychainStore.Account.gemini, legacy: value["apiKey"] as? String, didMigrate: &didMigrate)
        migrate(account: KeychainStore.Account.openai, legacy: value["openaiApiKey"] as? String, didMigrate: &didMigrate)
        migrate(account: KeychainStore.Account.openrouter, legacy: value["openrouterApiKey"] as? String, didMigrate: &didMigrate)
        migrate(account: KeychainStore.Account.opencode, legacy: value["opencodeApiKey"] as? String, didMigrate: &didMigrate)
        migrate(account: KeychainStore.Account.opencodeGo, legacy: value["opencodeGoApiKey"] as? String, didMigrate: &didMigrate)
        settings.apiKey = KeychainStore.get(KeychainStore.Account.gemini) ?? ""
        settings.openaiApiKey = KeychainStore.get(KeychainStore.Account.openai) ?? ""
        settings.openrouterApiKey = KeychainStore.get(KeychainStore.Account.openrouter) ?? ""
        settings.opencodeApiKey = KeychainStore.get(KeychainStore.Account.opencode) ?? ""
        settings.opencodeGoApiKey = KeychainStore.get(KeychainStore.Account.opencodeGo) ?? ""

        // Rewrite the blob without plaintext keys once migrated.
        if didMigrate { saveSettings(settings) }
        return settings
    }

    /// Copies a legacy plaintext key into the Keychain if the Keychain slot is
    /// empty and the legacy value is non-empty. Only flags `didMigrate` once the
    /// Keychain actually holds the value, so a failed write keeps the plaintext
    /// copy in the blob rather than silently dropping the only recoverable key.
    private static func migrate(account: String, legacy: String?, didMigrate: inout Bool) {
        let value = legacy?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            if legacy != nil { didMigrate = true } // strip empty key field on rewrite
            return
        }
        // Already migrated: the Keychain copy exists, so the blob can drop it.
        if !(KeychainStore.get(account)?.isEmpty ?? true) {
            didMigrate = true
            return
        }
        if KeychainStore.set(account, value) {
            didMigrate = true
        }
    }

    static func saveSettings(_ settings: AiSettings) {
        // Keys go to the Keychain, never the UserDefaults blob. Track per-key
        // write success so we only strip the plaintext copy that actually landed
        // in the Keychain; a failed write leaves its plaintext key in the blob.
        let geminiWritten = KeychainStore.set(KeychainStore.Account.gemini, settings.apiKey)
        let openaiWritten = KeychainStore.set(KeychainStore.Account.openai, settings.openaiApiKey)
        let openrouterWritten = KeychainStore.set(KeychainStore.Account.openrouter, settings.openrouterApiKey)
        let opencodeWritten = KeychainStore.set(KeychainStore.Account.opencode, settings.opencodeApiKey)
        let opencodeGoWritten = KeychainStore.set(KeychainStore.Account.opencodeGo, settings.opencodeGoApiKey)

        var stripped = settings
        if geminiWritten { stripped.apiKey = "" }
        if openaiWritten { stripped.openaiApiKey = "" }
        if openrouterWritten { stripped.openrouterApiKey = "" }
        if opencodeWritten { stripped.opencodeApiKey = "" }
        if opencodeGoWritten { stripped.opencodeGoApiKey = "" }
        guard let data = try? JSONEncoder().encode(stripped),
              let raw = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(raw, forKey: settingsKey)
    }

    static func loadConversation(for document: DocumentInfo?) -> [AiMessage] {
        guard let key = documentKey(document) else { return [] }
        return readConversations().first(where: { $0.key == key })?.messages ?? []
    }

    static func saveConversation(for document: DocumentInfo?, messages: [AiMessage]) {
        guard let key = documentKey(document) else { return }
        var entries = readConversations()
        let bounded = limit(messages)
        if let index = entries.firstIndex(where: { $0.key == key }) {
            if bounded.isEmpty {
                entries.remove(at: index)
            } else {
                // Replacing a JS object property does not change insertion order.
                entries[index].messages = bounded
            }
        } else if !bounded.isEmpty {
            entries.append(ConversationEntry(key: key, messages: bounded))
        }
        if entries.count > maxDocuments {
            entries.removeFirst(entries.count - maxDocuments)
        }
        writeConversations(entries)
    }

    static func makeMessage(role: AiRole, content: String, id: String? = nil) -> AiMessage {
        AiMessage(
            id: id ?? UUID().uuidString.lowercased(),
            role: role,
            content: content,
            createdAt: ISO8601DateFormatter.aiTimestamp.string(from: Date())
        )
    }

    private static func documentKey(_ document: DocumentInfo?) -> String? {
        guard let key = document?.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    private static func limit(_ messages: [AiMessage]) -> [AiMessage] {
        messages.suffix(maxMessagesPerDocument).map { message in
            var message = message
            if message.content.count > maxMessageCharacters {
                let end = message.content.index(message.content.startIndex, offsetBy: maxMessageCharacters)
                message.content = String(message.content[..<end]) + "\n[truncated]"
            }
            return message
        }
    }

    private static func readConversations() -> [ConversationEntry] {
        guard let raw = UserDefaults.standard.string(forKey: conversationsKey),
              let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }

        let orderedKeys = topLevelObjectKeys(in: raw)
        var entries: [ConversationEntry] = []
        for key in orderedKeys where object[key] is [Any] {
            guard let values = object[key] as? [Any] else { continue }
            let messages = values.compactMap(sanitizeMessage)
            let bounded = limit(messages)
            if !bounded.isEmpty {
                entries.append(ConversationEntry(key: key, messages: bounded))
            }
        }
        // A malformed order scan should not discard otherwise readable data.
        for key in object.keys.sorted() where !entries.contains(where: { $0.key == key }) {
            guard let values = object[key] as? [Any] else { continue }
            let bounded = limit(values.compactMap(sanitizeMessage))
            if !bounded.isEmpty { entries.append(ConversationEntry(key: key, messages: bounded)) }
        }
        return Array(entries.suffix(maxDocuments))
    }

    private static func sanitizeMessage(_ raw: Any) -> AiMessage? {
        guard let value = raw as? [String: Any],
              let roleString = value["role"] as? String,
              let role = AiRole(rawValue: roleString),
              let content = value["content"] as? String else { return nil }
        let rawId = (value["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let rawDate = (value["createdAt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        var usage: AiUsage? = nil
        if let usageValue = value["usage"] as? [String: Any],
           let usageData = try? JSONSerialization.data(withJSONObject: usageValue) {
            usage = try? JSONDecoder().decode(AiUsage.self, from: usageData)
        }
        return AiMessage(
            id: rawId?.isEmpty == false ? rawId! : UUID().uuidString.lowercased(),
            role: role,
            content: content,
            createdAt: rawDate?.isEmpty == false ? rawDate! : ISO8601DateFormatter.aiTimestamp.string(from: Date()),
            usage: usage
        )
    }

    private static func writeConversations(_ entries: [ConversationEntry]) {
        let encoder = JSONEncoder()
        var pairs: [String] = []
        for entry in entries {
            guard let keyData = try? encoder.encode(entry.key),
                  let key = String(data: keyData, encoding: .utf8),
                  let valueData = try? encoder.encode(entry.messages),
                  let value = String(data: valueData, encoding: .utf8) else { continue }
            pairs.append("\(key):\(value)")
        }
        UserDefaults.standard.set("{" + pairs.joined(separator: ",") + "}", forKey: conversationsKey)
    }

    /// JSONSerialization uses a Dictionary, so recover the source object's key
    /// order separately to preserve JavaScript's oldest-inserted-first eviction.
    private static func topLevelObjectKeys(in json: String) -> [String] {
        let bytes = Array(json.utf8)
        var keys: [String] = []
        var index = 0
        var depth = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 123 { depth += 1; index += 1; continue }
            if byte == 125 { depth -= 1; index += 1; continue }
            guard depth == 1, byte == 34 else { index += 1; continue }
            let start = index
            index += 1
            var escaped = false
            while index < bytes.count {
                if !escaped, bytes[index] == 34 { break }
                escaped = !escaped && bytes[index] == 92
                if bytes[index] != 92 { escaped = false }
                index += 1
            }
            guard index < bytes.count else { break }
            let end = index
            index += 1
            while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
            guard index < bytes.count, bytes[index] == 58 else { continue }
            let encoded = Data(bytes[start...end])
            if let key = try? JSONDecoder().decode(String.self, from: encoded) { keys.append(key) }
        }
        return keys
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let aiTimestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
