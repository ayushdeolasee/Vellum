import Foundation
import os

struct ScratchpadStagedAttachment: Equatable, Sendable {
    var id: String
    var name: String
    var data: Data
}

/// One serialized write lane per storage key. Imports and destructive Storage
/// actions invalidate and join the same lane before replacing/removing bytes,
/// so a save that was already coordinating cannot land afterward and resurrect
/// stale text.
actor ScratchpadWriteCoordinator {
    static let shared = ScratchpadWriteCoordinator()

    private var generations: [String: Int] = [:]
    private var tails: [String: Task<Void, Never>] = [:]

    func enqueue(
        forKey key: String,
        operation: @escaping @Sendable () async -> Bool
    ) async -> Bool {
        let generation = generations[key, default: 0]
        let previous = tails[key]
        let result = Task<Bool, Never> {
            await previous?.value
            guard self.isCurrent(generation, forKey: key) else { return false }
            return await operation()
        }
        tails[key] = Task { _ = await result.value }
        return await result.value
    }

    func enqueueCommit(
        forKey key: String,
        operation: @escaping @Sendable () async -> String?
    ) async -> String? {
        let generation = generations[key, default: 0]
        let previous = tails[key]
        let result = Task<String?, Never> {
            await previous?.value
            guard self.isCurrent(generation, forKey: key) else { return nil }
            return await operation()
        }
        tails[key] = Task { _ = await result.value }
        return await result.value
    }

    /// Invalidate earlier saves and install an exclusive barrier for the whole
    /// mutation. The barrier is put in every key's lane before this actor first
    /// suspends, so a save enqueued while `operation` runs waits behind it.
    func withExclusiveAccess<T: Sendable>(
        forKeys keys: [String],
        operation: @escaping @Sendable () async -> T
    ) async -> T {
        let keys = Array(Set(keys)).sorted()
        for key in keys { generations[key, default: 0] &+= 1 }
        let pending = keys.compactMap { tails[$0] }
        let result = Task<T, Never> {
            for task in pending { await task.value }
            return await operation()
        }
        let barrier = Task<Void, Never> { _ = await result.value }
        for key in keys { tails[key] = barrier }
        return await result.value
    }

    func withExclusiveAccess<T: Sendable>(
        forKeys keys: [String],
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let keys = Array(Set(keys)).sorted()
        for key in keys { generations[key, default: 0] &+= 1 }
        let pending = keys.compactMap { tails[$0] }
        let result = Task<T, Error> {
            for task in pending { await task.value }
            return try await operation()
        }
        let barrier = Task<Void, Never> { _ = try? await result.value }
        for key in keys { tails[key] = barrier }
        return try await result.value
    }

    func awaitPendingWrites() async {
        let pending = Array(tails.values)
        for task in pending { await task.value }
    }

    private func isCurrent(_ generation: Int, forKey key: String) -> Bool {
        generations[key, default: 0] == generation
    }
}

/// Folder-backed Scratchpad persistence. `vellum.scratchpad.notes.v1` is never
/// written by live code; it remains only as a lazy, recoverable migration source.
enum ScratchpadPersistence {
    static let notesKey = "vellum.scratchpad.notes.v1"
    static let maxCharacters = 200_000
    private static let legacyWriteLaneKey = "legacy:\(notesKey)"

    private struct Entry: Codable, Sendable {
        var key: String
        var text: String
    }

    struct LegacySnapshot: Sendable {
        var key: String
        var text: String
        var attachments: [ScratchpadStagedAttachment]
    }

    enum MigrationResult: Sendable {
        case none
        case migrated
        case retainedForRetry(LegacySnapshot)
    }

    // MARK: - Coordinated live storage

    static func load(
        forKey key: String,
        coordinator: StorageCoordinator
    ) async throws -> String {
        relativeToScheme(try await DocumentDataStore.loadScratchpad(
            forKey: key, coordinator: coordinator))
    }

    static func save(
        forKey key: String,
        document: DocumentInfo,
        schemeText: String,
        expectedBaseline: String,
        attachments: [ScratchpadStagedAttachment],
        dirtyAttachmentNames: Set<String>,
        coordinator: StorageCoordinator
    ) async -> String? {
        return await ScratchpadWriteCoordinator.shared.enqueueCommit(forKey: key) {
            do {
                let durable = relativeToScheme(try await DocumentDataStore.loadScratchpad(
                    forKey: key, coordinator: coordinator))
                let committed = mergeConcurrentEdit(
                    durable: durable,
                    expectedBaseline: expectedBaseline,
                    edited: schemeText)

                // Attachment bytes are durable and verified before the markdown
                // that references them becomes visible at the destination.
                for attachment in attachments where dirtyAttachmentNames.contains(attachment.name) {
                    try await DocumentDataStore.saveAttachment(
                        forKey: key, name: attachment.name, data: attachment.data,
                        coordinator: coordinator)
                    guard try await DocumentDataStore.loadAttachment(
                        forKey: key, name: attachment.name, coordinator: coordinator)
                        == attachment.data else { return nil }
                }

                let existingNames = try await DocumentDataStore.listAttachmentNames(
                    forKey: key, coordinator: coordinator)
                var extensions = Dictionary(uniqueKeysWithValues: existingNames.map {
                    (($0 as NSString).deletingPathExtension.lowercased(),
                     ($0 as NSString).pathExtension)
                })
                for attachment in attachments {
                    extensions[attachment.id.lowercased()] =
                        (attachment.name as NSString).pathExtension
                }
                let referenced = ScratchpadAttachmentStore.referencedIds(in: committed)
                let relative = schemeToRelative(committed) {
                    extensions[$0.lowercased()]
                }
                if relative.isEmpty {
                    try await DocumentDataStore.removeScratchpadSafely(
                        forKey: key, coordinator: coordinator)
                } else {
                    try await DocumentDataStore.saveScratchpad(
                        forKey: key, text: relative, coordinator: coordinator)
                }

                // Publish the new note first. Attachment cleanup is deliberately
                // best-effort afterward: an orphan is recoverable; a broken ref is not.
                let names = try await DocumentDataStore.listAttachmentNames(
                    forKey: key, coordinator: coordinator)
                for name in names {
                    let id = (name as NSString).deletingPathExtension.lowercased()
                    // A staged image can be flushed before the WebView delivers
                    // its markdown change (for example, on immediate background).
                    // Keep attachments written by this save for one cycle; the
                    // next clean save either sees the reference or collects it.
                    if !referenced.contains(id), !dirtyAttachmentNames.contains(name) {
                        await DocumentDataStore.removeAttachment(
                            forKey: key, name: name, coordinator: coordinator)
                    }
                }
                if relative.isEmpty {
                    await DocumentDataStore.pruneEmptyDocumentDir(
                        forKey: key, coordinator: coordinator)
                } else {
                    try await DocumentDataStore.touch(
                        document: document, force: true, coordinator: coordinator)
                }
                return committed
            } catch {
                return nil
            }
        }
    }

    /// Preserve a pane's complete edit when another pane committed first. The
    /// explicit recovery block is deliberately used even when both versions
    /// still contain their common baseline: trying to replace that substring
    /// again on retry would append the same delta twice. The exact marker/body
    /// guard makes every retry idempotent.
    static func mergeConcurrentEdit(
        durable: String,
        expectedBaseline: String,
        edited: String
    ) -> String {
        guard durable != expectedBaseline else { return edited }
        guard durable != edited else { return durable }
        guard !edited.isEmpty else { return durable }
        let marker = "\n\n---\n\n## Recovered edit from another Scratchpad pane\n\n"
        guard !durable.contains(marker + edited) else { return durable }
        guard !durable.isEmpty else { return edited }
        return durable + marker + edited
    }

    // MARK: - Relative <-> live-scheme references

    private static let idPattern = "[0-9a-fA-F-]+"

    static func relativeToScheme(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let pattern = "attachments/(\(idPattern))(?:\\.[A-Za-z0-9]+)?"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(location: 0, length: ns.length),
            withTemplate: "\(ScratchpadAttachmentStore.scheme)://$1")
    }

    static func schemeToRelative(
        _ text: String,
        extensionFor: (String) -> String?
    ) -> String {
        guard !text.isEmpty else { return text }
        let pattern = "\(ScratchpadAttachmentStore.scheme)://(\(idPattern))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = text
        for match in regex.matches(
            in: text, range: NSRange(location: 0, length: ns.length)).reversed()
        {
            guard match.numberOfRanges > 1,
                  let fullRange = Range(match.range(at: 0), in: result) else { continue }
            let id = ns.substring(with: match.range(at: 1))
            let replacement = extensionFor(id).map { "attachments/\(id).\($0)" }
                ?? "attachments/\(id)"
            result.replaceSubrange(fullRange, with: replacement)
        }
        return result
    }

    // MARK: - Lazy legacy migration

    static func migrateLegacyIfNeeded(
        document: DocumentInfo,
        key: String,
        coordinator: StorageCoordinator
    ) async -> MigrationResult {
        await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
            forKeys: [key, legacyWriteLaneKey]
        ) {
            let entries = readEntries()
            guard let index = legacyIndex(for: document, in: entries) else { return .none }
            let entry = entries[index]
            let fallback = (try? legacySnapshot(entry)) ?? LegacySnapshot(
                key: entry.key, text: entry.text, attachments: [])

            do {
                let snapshot = try legacySnapshot(entry)
                var migratedText = snapshot.text
                var migratedAttachments: [ScratchpadStagedAttachment] = []
                var namesByStem: [String: String] = [:]
                for name in try await DocumentDataStore.listAttachmentNames(
                    forKey: key, coordinator: coordinator)
                {
                    let stem = (name as NSString).deletingPathExtension.lowercased()
                    if namesByStem[stem] == nil { namesByStem[stem] = name }
                }

                // Existing attachment ids are authoritative. Equal bytes can be
                // reused; a differing legacy attachment receives a deterministic
                // recovered id and its legacy markdown is rewritten to point at
                // that copy, preserving both without overwriting either.
                for var attachment in snapshot.attachments {
                    if let existingName = namesByStem[attachment.id.lowercased()] {
                        let existing = try await DocumentDataStore.loadAttachment(
                            forKey: key, name: existingName, coordinator: coordinator)
                        if existing == attachment.data {
                            attachment.name = existingName
                        } else {
                            let recoveredID = DocumentIdentity.sha256Hex(
                                "legacy-scratchpad:\(entry.key):\(attachment.id):"
                                    + WebArchive.sha256Hex(attachment.data))
                            migratedText = migratedText.replacingOccurrences(
                                of: "\(ScratchpadAttachmentStore.scheme)://\(attachment.id)",
                                with: "\(ScratchpadAttachmentStore.scheme)://\(recoveredID)")
                            attachment.id = recoveredID
                            attachment.name = "\(recoveredID).\((attachment.name as NSString).pathExtension)"
                        }
                    }

                    if let existingName = namesByStem[attachment.id.lowercased()] {
                        guard try await DocumentDataStore.loadAttachment(
                            forKey: key, name: existingName, coordinator: coordinator)
                                == attachment.data else {
                            throw LibraryFileError.io(
                                "A recovered Scratchpad attachment id is already in use")
                        }
                        attachment.name = existingName
                    } else {
                        try await DocumentDataStore.saveAttachment(
                            forKey: key, name: attachment.name, data: attachment.data,
                            coordinator: coordinator)
                        guard try await DocumentDataStore.loadAttachment(
                            forKey: key, name: attachment.name, coordinator: coordinator)
                                == attachment.data else {
                            throw LibraryFileError.io(
                                "Failed to verify a migrated Scratchpad attachment")
                        }
                        namesByStem[attachment.id.lowercased()] = attachment.name
                    }
                    migratedAttachments.append(attachment)
                }

                let byID = Dictionary(uniqueKeysWithValues:
                    migratedAttachments.map { ($0.id.lowercased(), $0) })
                let legacyRelative = schemeToRelative(migratedText) {
                    byID[$0.lowercased()].map { ($0.name as NSString).pathExtension }
                }
                let destination = try await DocumentDataStore.loadScratchpad(
                    forKey: key, coordinator: coordinator)
                let merged = mergeLegacyScratchpad(
                    destination: destination, legacy: legacyRelative)
                if !merged.isEmpty, merged != destination {
                    try await DocumentDataStore.saveScratchpad(
                        forKey: key, text: merged, coordinator: coordinator)
                }
                if !merged.isEmpty {
                    guard try await DocumentDataStore.loadScratchpad(
                        forKey: key, coordinator: coordinator) == merged else {
                        throw LibraryFileError.io("Failed to verify the migrated Scratchpad")
                    }
                }

                // The blob and shared pool remain untouched until attachment and
                // markdown verification both succeed. A partial copy is harmless
                // and the same deterministic ids make retry idempotent.
                var updated = entries
                updated.remove(at: index)
                writeEntries(updated)
                if updated.isEmpty {
                    try? FileManager.default.removeItem(at: ScratchpadAttachmentStore.directory)
                }
                return .migrated
            } catch {
                return .retainedForRetry(fallback)
            }
        }
    }

    private static func legacyIndex(for document: DocumentInfo, in entries: [Entry]) -> Int? {
        let path = document.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        if let exact = entries.firstIndex(where: { $0.key == path }) { return exact }
        guard document.kind == .pdf else { return nil }
        let filename = (path as NSString).lastPathComponent
        guard filename.lowercased().hasSuffix(".pdf") else { return nil }
        let matches = entries.indices.filter {
            (entries[$0].key as NSString).lastPathComponent == filename
        }
        return matches.count == 1 ? matches[0] : nil
    }

    private static func mergeLegacyScratchpad(
        destination: String,
        legacy: String
    ) -> String {
        guard destination != legacy else { return destination }
        guard !destination.isEmpty else { return legacy }
        guard !legacy.isEmpty else { return destination }
        let marker = "\n\n---\n\n## Recovered notes from an older Scratchpad\n\n"
        guard !destination.contains(marker + legacy) else { return destination }
        return destination + marker + legacy
    }

    private static func legacySnapshot(_ entry: Entry) throws -> LegacySnapshot {
        var attachments: [ScratchpadStagedAttachment] = []
        for id in ScratchpadAttachmentStore.referencedIds(in: entry.text).sorted() {
            guard let url = ScratchpadAttachmentStore.fileURL(for: id),
                  let data = try? Data(contentsOf: url) else {
                throw CocoaError(.fileNoSuchFile)
            }
            attachments.append(.init(id: id, name: url.lastPathComponent, data: data))
        }
        return LegacySnapshot(key: entry.key, text: entry.text, attachments: attachments)
    }

    // MARK: - Read-only legacy inventory

    static func listLegacyEntries() -> [(key: String, bytes: Int)] {
        readEntries().map { (key: $0.key, bytes: $0.text.utf8.count) }
    }

    static func removeLegacyEntry(key: String) async {
        await ScratchpadWriteCoordinator.shared.withExclusiveAccess(
            forKeys: [legacyWriteLaneKey]
        ) {
            var entries = readEntries()
            entries.removeAll { $0.key == key }
            writeEntries(entries)
        }
    }

    private static func readEntries() -> [Entry] {
        guard let data = AppDefaults.current.data(forKey: notesKey),
              let entries = try? JSONDecoder().decode([Entry].self, from: data)
        else { return [] }
        return entries
    }

    private static func writeEntries(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        AppDefaults.current.set(data, forKey: notesKey)
    }

    static func awaitPendingFlush() async {
        await ScratchpadWriteCoordinator.shared.awaitPendingWrites()
    }

    // MARK: - Legacy direct compatibility (non-workspace tests/tools only)

    static func documentKey(_ document: DocumentInfo?) -> String? {
        guard let key = document?.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { return nil }
        return key
    }

    static func load(for key: String) -> String {
        let entries = readEntries()
        if let exact = entries.first(where: { $0.key == key })?.text { return exact }
        let filename = (key as NSString).lastPathComponent
        guard filename.lowercased().hasSuffix(".pdf") else { return "" }
        return entries.first {
            ($0.key as NSString).lastPathComponent == filename
        }?.text ?? ""
    }

    static func save(for key: String, text: String) {
        var entries = readEntries()
        entries.removeAll { $0.key == key }
        let bounded = String(text.prefix(maxCharacters))
        if !bounded.isEmpty { entries.append(Entry(key: key, text: bounded)) }
        writeEntries(entries)
    }

    static func persistedTextsSnapshot() -> [String] {
        readEntries().map(\.text)
    }
}

/// Legacy flat attachment pool. Live panes stage bytes in their own resolver
/// and persist them under `documents/<key>/attachments`; this remains solely so
/// old AppDefaults notes can be migrated lazily without losing their images.
enum ScratchpadAttachmentStore {
    static let scheme = "vellum-scratchpad"

    /// Test-only redirect for the attachment directory so tests never read or
    /// delete a real user's attachments. Nil in production.
    nonisolated(unsafe) static var directoryOverride: URL?

    static var directory: URL {
        directoryOverride
            ?? WebLibrary.appDataDir.appendingPathComponent(
                "scratchpad-attachments", isDirectory: true)
    }

    /// Persist `data` and return its id (the token used in note markdown), or
    /// nil if the write failed.
    static func save(
        data: Data,
        fileExtension ext: String,
        in preferredDirectory: URL? = nil
    ) -> String? {
        let id = UUID().uuidString.lowercased()
        let dir = preferredDirectory ?? directory
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try data.write(to: dir.appendingPathComponent("\(id).\(ext)"))
            return id
        } catch {
            return nil
        }
    }

    // MARK: - Pending attachments (written, reference not landed yet)

    /// Ids written but not yet seen in any saved note text, mapped to the moment
    /// their exemption lapses.
    ///
    /// A lock rather than main-actor isolation because the readers are not all
    /// on the main actor: `pruneOrphanedAttachments` dispatches `collectGarbage`
    /// to a detached task. The state is a plain Sendable dictionary, so this
    /// stays a lock around a value — no actor hop on the drop path.
    private static let pendingAttachments = OSAllocatedUnfairLock<[String: Date]>(
        initialState: [:])

    /// How long a written attachment stays exempt from collection while its
    /// reference is in flight.
    ///
    /// The window it has to cover is the editor delivering the snippet, posting
    /// its "change" message back, and the 400 ms save debounce — a fraction of a
    /// second. It deliberately does NOT have to cover the editor's WebView still
    /// loading: an insert requested before the bundle is ready is buffered, and
    /// the mark is re-armed when it is finally delivered (see
    /// `ScratchpadLiveEditor.Coordinator.flush`), so a slow cold start cannot eat
    /// the budget. A minute against a sub-second window is generous on purpose,
    /// because the failure modes are not symmetric: an exemption held too long
    /// only delays a sweep that will collect the file anyway, while one released
    /// too early deletes bytes the note is about to point at. Settable so a test
    /// can exercise the lapse without waiting a minute.
    nonisolated(unsafe) static var pendingGracePeriod: TimeInterval = 60

    /// Declare that `id`'s bytes are on disk and its markdown reference is on
    /// its way. Until that reference lands in saved text (or `pendingGracePeriod`
    /// elapses), `collectGarbage` will not reap the file.
    ///
    /// Called by the code that is *about to* insert a reference, not by `save`
    /// itself: writing bytes does not on its own imply a reference is coming
    /// (imports and tests write attachments whose text already exists, or none).
    static func markPending(_ id: String) {
        let deadline = Date().addingTimeInterval(pendingGracePeriod)
        pendingAttachments.withLock { $0[id.lowercased()] = deadline }
    }

    /// Drop every pending id that has now been observed in saved text — its
    /// reference landed, so ordinary reachability governs it from here — along
    /// with any whose grace period has lapsed. Returns what is still exempt.
    ///
    /// Keyed by id alone. On iPad every sweep covers the one flat pool, so the
    /// cross-document asymmetry main documents here does not arise; either way
    /// an entry can only ever spare a file, never select one for deletion, and
    /// ids are fresh UUIDs so two documents sharing one is not reachable from
    /// the write path.
    private static func settlePending(observing referencedIds: Set<String>) -> Set<String> {
        let now = Date()
        return pendingAttachments.withLock { pending in
            pending = pending.filter { !referencedIds.contains($0.key) && $0.value > now }
            return Set(pending.keys)
        }
    }

    /// Test seam: the registry is process-global (#102), so a suite touching it
    /// must not inherit or leak entries.
    static func resetPending() {
        pendingAttachments.withLock { $0.removeAll() }
    }

    /// Extensions a saved attachment can carry (`save(data:fileExtension:)`
    /// only ever writes one of these), probed directly so a lookup is O(1)
    /// rather than scanning the whole global attachments directory.
    private static let knownExtensions = [
        "jpg", "jpeg", "png", "gif", "webp", "tiff", "tif", "heic",
    ]

    /// The file backing `id` (`<id>.<known-extension>`), if present. Probes the
    /// candidate extensions instead of listing the directory, so cost is fixed
    /// no matter how many attachments exist across all documents. `preferredDir`
    /// is probed ahead of the legacy pool. Production live panes do not use this
    /// for coordinated roots; they resolve staged bytes through their own store.
    static func fileURL(for id: String, preferredDir: URL? = nil) -> URL? {
        let clean = id.lowercased()
        guard !clean.isEmpty else { return nil }
        var searched = Set<String>()
        for dir in [preferredDir, directory].compactMap({ $0 }) {
            guard searched.insert(dir.path).inserted else { continue }
            for ext in knownExtensions {
                let url = dir.appendingPathComponent("\(clean).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// Every attachment id referenced by `text`.
    static func referencedIds(in text: String) -> Set<String> {
        guard !text.isEmpty else { return [] }
        let pattern = "\(scheme)://([0-9a-fA-F-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        var ids = Set<String>()
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            if match.numberOfRanges > 1 {
                ids.insert(ns.substring(with: match.range(at: 1)).lowercased())
            }
        }
        return ids
    }

    /// Delete attachment files not referenced by any persisted note.
    ///
    /// `referencedIds` is a snapshot of the notes as they read at some moment,
    /// and this sweep can run later — `pruneOrphanedAttachments` dispatches it to
    /// a background task, and a debounced save persists text captured earlier. An
    /// attachment written in that gap is, correctly, not in the snapshot, but it
    /// is also not garbage: it belongs to an edit the snapshot predates. Passing
    /// the moment the snapshot was taken as `referencedAsOf` keeps the sweep
    /// from reaping it. Without that, dropping an image immediately after
    /// opening a document (which sweeps with an empty reference set) could
    /// delete the bytes just written and leave a broken reference in the note
    /// (#104).
    ///
    /// A file spared this way is not leaked: if it really is an orphan, the next
    /// sweep sees it as older than that snapshot and collects it.
    ///
    /// The cutoff cannot cover the *other* half of the race (#105). When an
    /// image is dropped, the bytes are written first and the markdown reference
    /// arrives afterwards, through the editor's WebView round trip. A debounced
    /// save landing in between computes a reference set that is genuinely current
    /// and genuinely does not mention the new attachment — nothing about the
    /// timestamps distinguishes it from an orphan. `markPending` closes that
    /// window instead, by naming the attachment before its reference exists; this
    /// sweep also settles pending ids it can now see referenced, so the exemption
    /// lasts until the first save that observes the reference rather than for a
    /// fixed span.
    static func collectGarbage(
        referencedIds: Set<String>, referencedAsOf: Date? = nil
    ) {
        let stillPending = settlePending(observing: referencedIds)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [
                .creationDateKey, .contentModificationDateKey,
            ]) else { return }
        for url in entries {
            let id = url.deletingPathExtension().lastPathComponent.lowercased()
            guard !referencedIds.contains(id) else { continue }
            guard !stillPending.contains(id) else { continue }
            if let referencedAsOf, isNewerThan(referencedAsOf, url: url) { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// True when the file was created or last written at or after `date` — i.e.
    /// it may postdate the reference snapshot being collected against.
    private static func isNewerThan(_ date: Date, url: URL) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [.creationDateKey, .contentModificationDateKey])
        else {
            // Unreadable timestamps: keep the file. A missed collection is
            // recoverable, deleting a live attachment is not.
            return true
        }
        return [values.creationDate, values.contentModificationDate]
            .compactMap { $0 }
            .contains { $0 >= date }
    }

    /// MIME type inferred from a file's extension.
    static func mediaType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "tiff", "tif": return "image/tiff"
        case "heic": return "image/heic"
        default: return "application/octet-stream"
        }
    }
}
