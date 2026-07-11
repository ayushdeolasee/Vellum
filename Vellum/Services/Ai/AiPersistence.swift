import Foundation

enum AiPersistence {
    static let settingsKey = "research-reader-ai-settings-v1"
    static let conversationsKey = "research-reader-ai-conversations-v1"
    static let maxMessagesPerDocument = 120
    static let maxMessageCharacters = 12_000
    static let maxDocuments = 25

    private struct ConversationEntry: Sendable {
        var key: String
        var messages: [AiMessage]
    }

    /// Last value synced with the Keychain per account this launch, so the
    /// per-keystroke saves coming from the settings bindings only pay a Keychain
    /// round-trip for the one account that actually changed. Main-actor-only in
    /// practice (AiStore owns all load/save calls).
    nonisolated(unsafe) private static var syncedKeys: [String: String] = [:]

    /// Reads an account's key and primes the sync cache with what the Keychain
    /// currently holds.
    private static func readKey(_ account: String) -> String {
        let value = KeychainStore.get(account) ?? ""
        syncedKeys[account] = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    /// Writes an account's key only when it differs from the last synced value.
    private static func syncKeychain(_ account: String, _ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if syncedKeys[account] == trimmed { return true }
        let written = KeychainStore.set(account, value)
        if written { syncedKeys[account] = trimmed }
        return written
    }

    static func loadSettings() -> AiSettings {
        let defaults = AiSettings()
        guard let raw = UserDefaults.standard.string(forKey: settingsKey),
              let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            // No stored blob yet: still surface any keys already in the Keychain.
            var settings = defaults
            settings.apiKey = readKey(KeychainStore.Account.gemini)
            settings.openaiApiKey = readKey(KeychainStore.Account.openai)
            settings.openrouterApiKey = readKey(KeychainStore.Account.openrouter)
            settings.opencodeApiKey = readKey(KeychainStore.Account.opencode)
            settings.opencodeGoApiKey = readKey(KeychainStore.Account.opencodeGo)
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
        settings.apiKey = readKey(KeychainStore.Account.gemini)
        settings.openaiApiKey = readKey(KeychainStore.Account.openai)
        settings.openrouterApiKey = readKey(KeychainStore.Account.openrouter)
        settings.opencodeApiKey = readKey(KeychainStore.Account.opencode)
        settings.opencodeGoApiKey = readKey(KeychainStore.Account.opencodeGo)

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
        // Keys go to the Keychain, never the UserDefaults blob — and only the
        // accounts whose value changed are written (this runs on every keystroke
        // in the settings key fields, and each Keychain write is a synchronous
        // securityd round-trip). Track per-key write success so we only strip
        // the plaintext copy that actually landed in the Keychain; a failed
        // write leaves its plaintext key in the blob.
        let geminiWritten = syncKeychain(KeychainStore.Account.gemini, settings.apiKey)
        let openaiWritten = syncKeychain(KeychainStore.Account.openai, settings.openaiApiKey)
        let openrouterWritten = syncKeychain(KeychainStore.Account.openrouter, settings.openrouterApiKey)
        let opencodeWritten = syncKeychain(KeychainStore.Account.opencode, settings.opencodeApiKey)
        let opencodeGoWritten = syncKeychain(KeychainStore.Account.opencodeGo, settings.opencodeGoApiKey)

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

    /// Decoded conversation entries, parsed from the UserDefaults blob once and
    /// kept authoritative in memory afterwards. Confined to the main actor —
    /// every caller (AiStore, PaneView) already is.
    @MainActor private static var cachedEntries: [ConversationEntry]?

    @MainActor private static func entries() -> [ConversationEntry] {
        if let cachedEntries { return cachedEntries }
        let loaded = readConversations()
        cachedEntries = loaded
        return loaded
    }

    @MainActor static func loadConversation(for document: DocumentInfo?) -> [AiMessage] {
        guard let key = documentKey(document) else { return [] }
        return entries().first(where: { $0.key == key })?.messages ?? []
    }

    @MainActor static func saveConversation(for document: DocumentInfo?, messages: [AiMessage]) {
        guard let key = documentKey(document) else { return }
        var updated = entries()
        let bounded = limit(messages)
        if let index = updated.firstIndex(where: { $0.key == key }) {
            if bounded.isEmpty {
                updated.remove(at: index)
            } else {
                // Replacing a JS object property does not change insertion order.
                updated[index].messages = bounded
            }
        } else if !bounded.isEmpty {
            updated.append(ConversationEntry(key: key, messages: bounded))
        }
        if updated.count > maxDocuments {
            updated.removeFirst(updated.count - maxDocuments)
        }
        cachedEntries = updated
        scheduleFlush()
    }

    @MainActor private static var pendingFlush: Task<Void, Never>?
    /// Bumped by every scheduleFlush — even one that lands while a flush is
    /// already running — so the active flush task can detect a save that arrived
    /// mid-write and loop to persist it. This keeps `pendingFlush` registered
    /// until the FINAL snapshot is on disk, so `awaitPendingFlush()` (called from
    /// applicationShouldTerminate) never returns while a write is still in flight.
    @MainActor private static var flushRevision = 0

    /// Encode + write off the main actor, coalescing bursts (a turn saves up to
    /// three times). ConversationEntry is Codable value data, safe to move.
    @MainActor private static func scheduleFlush() {
        flushRevision &+= 1
        guard pendingFlush == nil else { return }   // the running flush will pick up this revision
        pendingFlush = Task { @MainActor in
            // Let same-turn saves coalesce, but stay well under a second so the
            // "user message persisted before the request" crash contract holds.
            try? await Task.sleep(for: .milliseconds(200))
            // Write, then re-check the revision: a save that landed during the
            // detached write bumped it, so loop and persist the newer snapshot.
            // Only one detached write is awaited at a time, so writes are
            // serialized — a later snapshot can never overtake an earlier one.
            while true {
                let revision = flushRevision
                let snapshot = entries()
                await Task.detached(priority: .utility) {
                    writeConversations(snapshot)
                }.value
                // No await between this check and clearing pendingFlush, so on the
                // main actor a concurrent save can't slip in unnoticed here.
                if flushRevision == revision {
                    pendingFlush = nil
                    return
                }
            }
        }
    }

    /// Await any scheduled write — called from applicationShouldTerminate.
    @MainActor static func awaitPendingFlush() async {
        while let flush = pendingFlush {
            await flush.value
        }
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
