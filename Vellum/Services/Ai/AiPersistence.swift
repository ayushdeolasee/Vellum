import Foundation

// Per-document AI settings + conversations. Settings stay in the global
// UserDefaults blob (device-scoped, class D). Conversations moved to
// `documents/<storageKey>/conversations.json` (class-B user data — see
// plans/storage-design.html §4): one small file per document, keyed by
// `DocumentIdentity.storageKey`, fronted by the #48 in-memory write-behind
// cache with a coalesced 200 ms flush drained on quit. The legacy path-keyed
// UserDefaults blob (`conversationsKey`) is now a read-only migration source —
// a document's entry is folded into its folder on first load and removed.
enum AiPersistence {
    static let settingsKey = "research-reader-ai-settings-v1"
    /// Legacy path-keyed conversation blob — migration read source only.
    static let conversationsKey = "research-reader-ai-conversations-v1"
    static let maxMessagesPerDocument = 120
    static let maxMessageCharacters = 12_000
    /// Per-reference excerpt cap, the counterpart to `maxMessageCharacters` for
    /// `AiMessage.references`. A single selection can be a whole page and one
    /// message may carry several, so without this a turn could write far more to
    /// `conversations.json` than the body cap allows. Generous enough that a
    /// realistic selection or quote is stored verbatim; the prompt applies its
    /// own, tighter bound separately (`AiPrompts.maxReferenceCharacters`).
    static let maxReferenceCharacters = 4_000
    /// Ceiling on references of any kind attached to one message, images
    /// included. `AiStore.maxImageReferences` bounds the *request* payload; this
    /// bounds the *transcript*. Every reference is persisted on the user message
    /// and `conversations.json` is rewritten in full on every turn, so a hundred
    /// selections attached in one gesture would be re-encoded forever after.
    /// Enforced by the composer (`AiStore.addReference`) and again on the way to
    /// disk, for lists that never came through the composer — an imported
    /// `.vellum` bundle, or a hand-edited file.
    static let maxReferencesPerMessage = 16
    static let maxToolSummariesPerMessage = 24
    static let maxToolSourcesPerSummary = 8
    static let maxToolSummaryTitleCharacters = 240
    static let maxToolSummaryDetailCharacters = 160
    static let maxToolSourceExcerptCharacters = 280
    static let maxToolIdentifierCharacters = 128
    static let maxToolPageNumber = 1_000_000

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

    /// Per-document message caches, loaded lazily on first access and
    /// authoritative in memory afterwards (the #48 write-behind contract).
    /// Keyed by `DocumentIdentity.storageKey` — one small `conversations.json`
    /// per document under `documents/<key>/`, never a cross-document blob.
    /// Confined to the main actor — every caller (AiStore, PaneView) already is.
    @MainActor private static var cache: [String: [AiMessage]] = [:]

    @MainActor static func loadConversation(for document: DocumentInfo?) -> [AiMessage] {
        guard let document, let key = storageKey(for: document) else { return [] }
        migrateToCurrentStorageKeyIfNeeded(document: document, key: key)
        if let cached = cache[key] { return cached }
        // First load this session: fold in any legacy blob entry, then read the
        // folder file (which the migration just wrote, if there was one).
        if !DocumentDataStore.conversationsExist(forKey: key) {
            migrateLegacyIfNeeded(document: document, key: key)
        }
        let loaded = readConversationsFile(forKey: key)
        // A conversation stuck in iCloud (an unmaterialized placeholder that
        // couldn't download) reads as empty — but that empty is NOT authoritative.
        // Leaving the cache unset means a later load, once the bytes land, re-reads
        // disk instead of serving (and eventually flushing) a phantom empty chat.
        if loaded.isEmpty, DocumentDataStore.conversationsUnavailableEvicted(forKey: key) {
            return []
        }
        cache[key] = loaded
        return loaded
    }

    @MainActor static func saveConversation(for document: DocumentInfo?, messages: [AiMessage]) {
        guard let document, let key = storageKey(for: document) else { return }
        migrateToCurrentStorageKeyIfNeeded(document: document, key: key)
        let limited = limitedMessages(messages)
        cache[key] = limited
        // A non-empty conversation is real class-B data; ensure meta.json exists
        // so recents can re-resolve the document by its docId later. The actual
        // conversations.json write is deferred to the coalesced flush; meta is a
        // single tiny stamp. An empty list is the delete signal — no stamp (§6).
        if !limited.isEmpty {
            try? DocumentDataStore.touch(document: document, force: true)
        }
        dirtyKeys.insert(key)
        scheduleFlush()
    }

    @MainActor private static var pendingFlush: Task<Void, Never>?
    /// Bumped by every scheduleFlush — even one that lands while a flush is
    /// already running — so the active flush task can detect a save that arrived
    /// mid-write and loop to persist it. This keeps `pendingFlush` registered
    /// until the FINAL snapshot is on disk, so `awaitPendingFlush()` (called from
    /// applicationShouldTerminate) never returns while a write is still in flight.
    @MainActor private static var flushRevision = 0
    /// storageKeys whose in-memory conversation changed since the last write.
    /// The coalesced flush persists ONLY these — one small file each, not the
    /// old cross-document blob (§7: "flushing one document writes one small file").
    /// A key whose write FAILED is re-inserted here so it is retried, never
    /// silently dropped.
    @MainActor private static var dirtyKeys: Set<String> = []

    /// How many times one flush task re-attempts keys whose write keeps failing
    /// before parking them (still dirty) for a later scheduleFlush / the quit
    /// drain — so a persistent disk-full condition can't hot-spin the loop.
    private static let maxFlushFailureRetries = 2

    /// Encode + write off the main actor, coalescing bursts (a turn saves up to
    /// three times). ConversationEntry is Sendable value data, safe to move.
    @MainActor private static func scheduleFlush() {
        flushRevision &+= 1
        guard pendingFlush == nil else { return }   // the running flush will pick up this revision
        pendingFlush = Task { @MainActor in
            // Let same-turn saves coalesce, but stay well under a second so the
            // "user message persisted before the request" crash contract holds.
            try? await Task.sleep(for: .milliseconds(200))
            var failureRetries = 0
            // Write, then re-check the revision: a save that landed during the
            // detached write bumped it, so loop and persist the newer snapshot.
            // Only one detached write is awaited at a time, so writes are
            // serialized — a later snapshot can never overtake an earlier one.
            while true {
                let revision = flushRevision
                let snapshot = dirtyKeys.map { ConversationEntry(key: $0, messages: cache[$0] ?? []) }
                dirtyKeys.removeAll()
                let failed = await Task.detached(priority: .utility) { () -> [String] in
                    snapshot.filter { !flushConversation($0) }.map(\.key)
                }.value
                // Re-mark any key whose write failed so its data is retried, never
                // dropped — a disk-full flush must NOT report success (data loss).
                for key in failed { dirtyKeys.insert(key) }

                // Done only when the queue is fully drained AND no save slipped in.
                if flushRevision == revision, dirtyKeys.isEmpty {
                    pendingFlush = nil
                    return
                }
                if !failed.isEmpty {
                    failureRetries += 1
                    if failureRetries > maxFlushFailureRetries {
                        // Give up THIS task but leave the keys dirty: the next
                        // scheduleFlush (a later save) or awaitPendingFlush (quit)
                        // retries them. Parking avoids a tight retry spin.
                        NSLog("[Vellum] AI conversation flush failed for \(failed.count) document(s) after \(failureRetries) attempts; keeping them dirty for a later flush")
                        pendingFlush = nil
                        return
                    }
                    // Back off before retrying a failed write (disk full / transient).
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }
        }
    }

    /// Persist (or, when empty, delete) one document's conversations.json. Runs
    /// off the main actor inside the coalesced flush. An empty message list is
    /// the delete signal: the file is removed and a now-empty folder pruned, so
    /// clearConversation's hard-delete contract keeps working (§8). Returns false
    /// when a non-empty conversation could not be written (encode or disk error),
    /// so the caller keeps the key dirty for a retry instead of losing the data.
    private static func flushConversation(_ entry: ConversationEntry) -> Bool {
        if entry.messages.isEmpty {
            DocumentDataStore.removeConversations(forKey: entry.key)
            DocumentDataStore.pruneEmptyDocumentDir(forKey: entry.key)
            return true
        }
        guard let data = try? JSONEncoder().encode(entry.messages) else { return false }
        do {
            try DocumentDataStore.saveConversationsData(forKey: entry.key, data: data)
            return true
        } catch {
            return false
        }
    }

    /// Read and decode a document's conversations.json (the plain JSON array
    /// form), applying the per-message caps defensively. Empty when absent or
    /// unreadable.
    private static func readConversationsFile(forKey key: String) -> [AiMessage] {
        guard let data = DocumentDataStore.loadConversationsData(forKey: key),
              let messages = try? JSONDecoder().decode([AiMessage].self, from: data)
        else { return [] }
        return limitedMessages(messages)
    }

    /// Await any scheduled write — called from applicationShouldTerminate.
    @MainActor static func awaitPendingFlush() async {
        while let flush = pendingFlush {
            await flush.value
        }
        // A prior flush may have exhausted its retry budget and parked keys still
        // dirty. Give them ONE more chance at quit; if it still fails the data
        // cannot be written now — log loudly rather than exit silently on loss.
        guard !dirtyKeys.isEmpty else { return }
        scheduleFlush()
        while let flush = pendingFlush {
            await flush.value
        }
        if !dirtyKeys.isEmpty {
            NSLog("[Vellum] \(dirtyKeys.count) AI conversation(s) could not be flushed before quit; unsaved changes remain in memory only")
        }
    }

    /// Drop the in-memory conversation for `key` and clear any pending-write
    /// flag it holds. Used after a `.vellum` import merges a fresh conversation
    /// into `documents/<key>/conversations.json` on disk: the memory cache is
    /// authoritative (#48 write-behind), so without this a still-open tab's stale
    /// cached messages — and their queued flush — would overwrite the just-merged
    /// file. The next `loadConversation` for this key re-reads from disk.
    @MainActor static func invalidateCachedConversation(forKey key: String) {
        cache.removeValue(forKey: key)
        dirtyKeys.remove(key)
    }

    /// Keep the main-actor write-behind state aligned with an on-disk rekey.
    /// The old key belongs to the same open document, so its cached snapshot is
    /// authoritative over any stale destination snapshot from before the stamp.
    @MainActor private static func migrateCachedConversation(from oldKey: String, to newKey: String) {
        guard oldKey != newKey else { return }
        if let cached = cache.removeValue(forKey: oldKey) {
            cache[newKey] = cached
        }
        if dirtyKeys.remove(oldKey) != nil {
            dirtyKeys.insert(newKey)
        }
    }

    /// A PDF may acquire its doc ID between any two calls (not only while a
    /// conversation is loaded). Move both disk and write-behind state before a
    /// read *or* write under the stamped key so an old queued Clear cannot later
    /// recreate the path-hash folder.
    @MainActor private static func migrateToCurrentStorageKeyIfNeeded(
        document: DocumentInfo, key: String
    ) {
        guard let docId = document.docId, !docId.isEmpty else { return }
        let pathKey = DocumentIdentity.sha256Hex(document.pdfPath)
        guard pathKey != key else { return }
        migrateCachedConversation(from: pathKey, to: key)
        DocumentDataStore.rekey(from: pathKey, to: key)
    }

    static func makeMessage(
        role: AiRole,
        content: String,
        id: String? = nil,
        references: [AiReference] = []
    ) -> AiMessage {
        AiMessage(
            id: id ?? UUID().uuidString.lowercased(),
            role: role,
            content: content,
            createdAt: ISO8601DateFormatter.aiTimestamp.string(from: Date()),
            references: references
        )
    }

    /// The per-document storage key: its docId, else the path-hash fallback.
    /// nil when a doc carries neither a stamped id nor a usable path, so a
    /// degenerate document never persists (matches the old empty-path guard).
    /// Uses `DocumentIdentity.storageKey` verbatim so the path-hash form is
    /// byte-identical to the pathKey computed for the folder rekey above.
    private static func storageKey(for document: DocumentInfo) -> String? {
        if document.docId?.isEmpty ?? true,
           document.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        return DocumentIdentity.storageKey(for: document)
    }

    // MARK: - Legacy migration (UserDefaults blob -> conversations.json)

    /// Fold this document's entry out of the legacy path-keyed blob into its
    /// folder: write conversations.json, then rewrite the blob without the entry
    /// (§7 lazy migration). The blob read path stays intact for every other
    /// document's still-unmigrated entry. Called only when the folder file is
    /// absent. On a write failure the blob entry is left in place so the next
    /// open retries.
    @MainActor private static func migrateLegacyIfNeeded(document: DocumentInfo, key: String) {
        let legacyKey = document.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !legacyKey.isEmpty else { return }
        var entries = readConversations()
        guard let index = entries.firstIndex(where: { $0.key == legacyKey }) else { return }
        do {
            let data = try JSONEncoder().encode(entries[index].messages)
            try DocumentDataStore.saveConversationsData(forKey: key, data: data)
        } catch {
            return
        }
        entries.remove(at: index)
        writeConversations(entries)
    }

    // MARK: - Orphaned legacy blobs (Storage pane "Not yet migrated")

    /// Every path-keyed conversation still sitting in the legacy blob — surfaced
    /// in the Storage pane's orphans section as pre-migration data the user can
    /// delete. `bytes` is the encoded message-array size.
    static func listLegacyEntries() -> [(key: String, bytes: Int)] {
        readConversations().map { entry in
            let bytes = (try? JSONEncoder().encode(entry.messages))?.count ?? 0
            return (key: entry.key, bytes: bytes)
        }
    }

    /// Drop one path-keyed conversation from the legacy blob (Storage-pane
    /// delete). Rewrites the blob without the entry, keeping the JS-order/LRU
    /// serialization the migration reader expects.
    static func removeLegacyEntry(key: String) {
        var entries = readConversations()
        entries.removeAll { $0.key == key }
        writeConversations(entries)
    }

    /// The single conversation boundary used by live saves, cold loads, legacy
    /// migration, and `.vellum` imports. Structured fields must be bounded here
    /// as well as message content so nested JSON cannot bypass storage/UI caps.
    static func limitedMessages(_ messages: [AiMessage]) -> [AiMessage] {
        messages.suffix(maxMessagesPerDocument).map { message in
            var message = message
            if message.content.count > maxMessageCharacters {
                let end = message.content.index(message.content.startIndex, offsetBy: maxMessageCharacters)
                message.content = String(message.content[..<end]) + "\n[truncated]"
            }
            message.references = capReferences(message.references)
            if let summaries = message.toolSummaries {
                message.toolSummaries = sanitizeToolSummaries(summaries)
            }
            return message
        }
    }

    /// The per-message reference caps. Reached only through `limitedMessages`,
    /// which is now the single conversation boundary for live saves, cold loads,
    /// legacy migration, and `.vellum` imports alike — `VellumBundle` used to
    /// keep a parallel `capConversation` that restated these rules and drifted
    /// out of sync once already; #64 deleted it in favour of calling
    /// `limitedMessages` directly, so there is exactly one implementation.
    /// Defensive on both save and load: a list that arrived oversized,
    /// was hand-edited on disk, or came out of a `.vellum` file we didn't write
    /// is clipped here rather than carried around in memory and rewritten in
    /// full on every flush.
    static func capReferences(_ references: [AiReference]) -> [AiReference] {
        guard !references.isEmpty else { return references }
        // Newest-last, so keep the *first* N: unlike messages, where the recent
        // turns matter most, references are a single message's attachment list
        // in the order the user built it, and truncating the tail is what the
        // composer's own cap would have done.
        return references.prefix(maxReferencesPerMessage).map {
            $0.truncatingText(to: maxReferenceCharacters).strippingImageData
        }
    }

    static func sanitizeToolSummaries(_ summaries: [AiToolSummary]) -> [AiToolSummary] {
        var seenSummaryIds = Set<String>()
        var sanitized: [AiToolSummary] = []
        for (summaryIndex, original) in summaries.prefix(maxToolSummariesPerMessage).enumerated() {
            var summary = original
            summary.title = bounded(summary.title, limit: maxToolSummaryTitleCharacters)
            guard summary.title.isEmpty == false else { continue }
            summary.id = uniqueIdentifier(
                summary.id,
                fallback: "summary-\(summaryIndex)",
                seen: &seenSummaryIds
            )
            summary.detail = summary.detail.map {
                bounded($0, limit: maxToolSummaryDetailCharacters)
            }
            summary.destinationPage = boundedPage(summary.destinationPage)
            var seenSourceIds = Set<String>()
            summary.sources = summary.sources.prefix(maxToolSourcesPerSummary)
                .enumerated()
                .map { sourceIndex, originalSource in
                var source = originalSource
                source.id = uniqueIdentifier(
                    source.id,
                    fallback: "source-\(sourceIndex)",
                    seen: &seenSourceIds
                )
                source.page = boundedPage(source.page)
                source.excerpt = bounded(
                    source.excerpt,
                    limit: maxToolSourceExcerptCharacters
                )
                return source
            }
            sanitized.append(summary)
        }
        return sanitized
    }

    private static func uniqueIdentifier(
        _ value: String,
        fallback: String,
        seen: inout Set<String>
    ) -> String {
        let candidate = bounded(value, limit: maxToolIdentifierCharacters)
        if candidate.isEmpty == false, seen.insert(candidate).inserted {
            return candidate
        }
        var attempt = 0
        while true {
            let suffix = attempt == 0 ? fallback : "\(fallback)-\(attempt)"
            let identifier = bounded(suffix, limit: maxToolIdentifierCharacters)
            if seen.insert(identifier).inserted { return identifier }
            attempt += 1
        }
    }

    private static func bounded(_ value: String, limit: Int) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func boundedPage(_ page: Int?) -> Int? {
        guard let page, (1...maxToolPageNumber).contains(page) else { return nil }
        return page
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
            let bounded = limitedMessages(messages)
            if !bounded.isEmpty {
                entries.append(ConversationEntry(key: key, messages: bounded))
            }
        }
        // A malformed order scan should not discard otherwise readable data.
        for key in object.keys.sorted() where !entries.contains(where: { $0.key == key }) {
            guard let values = object[key] as? [Any] else { continue }
            let bounded = limitedMessages(values.compactMap(sanitizeMessage))
            if !bounded.isEmpty { entries.append(ConversationEntry(key: key, messages: bounded)) }
        }
        // No cap: return every entry so lazy migration can find any document,
        // even if a legacy blob somehow held more than the old LRU limit.
        return entries
    }

    /// Legacy-blob reader. Deliberately does NOT look for `references`: the blob
    /// is a read-only migration source frozen before that field existed, so an
    /// entry can never carry one. Migrated messages come out with `references`
    /// empty, which is correct — those turns really had no attachments recorded.
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
