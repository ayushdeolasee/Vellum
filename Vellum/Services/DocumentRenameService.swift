import Foundation

// Renaming a document or webpage from the home screen or the tab bar.
//
// WHAT A RENAME DOES, AND DELIBERATELY DOES NOT DO
//
// A rename changes the document's TITLE. It never touches the file on disk.
//
// That is a real decision, not an omission. Vellum does not own the user's
// files — a PDF lives wherever they filed it, and something else almost
// certainly points at it: a Finder alias, a citation manager, a cloud sync, a
// link in someone's notes. Silently renaming the file to match a label typed
// into a reading app would break all of those, and the user would have no way
// to know it happened. It would also invalidate the app's own bookkeeping at
// once — the recents list keys on `pdfPath`, `meta.json` records
// `last_known_path`, and an unstamped PDF's storage key is the sha256 OF ITS
// PATH — which is precisely the "locator no longer resolves" failure this
// screen has already had to defend against. So: the file keeps its name, and
// the title is a label Vellum maintains on top of it.
//
// The tab bar and the home rows already prefer `title` over the filename, so
// the rename shows up exactly where the user expects. "Show in Finder" still
// reveals the real file under its real name, which is the escape hatch for
// anyone who wanted the other behaviour.
//
// WHY THIS IS A SERVICE AND NOT THREE CALL SITES
//
// A title is stored in up to four independent places, written by four
// different subsystems:
//
//   1. `meta.json` in `documents/<key>/`  — DocumentDataStore
//   2. the recents list in UserDefaults   — RecentFilesService
//   3. the saved-page record on disk      — WebLibrary
//   4. the in-memory open tab             — AppStore
//
// Updating a subset is worse than updating none, because the screen the user
// is not looking at keeps the old name and the two disagree until something
// happens to reload. This type is the one place that knows the full set, so
// there is exactly one answer to "where does a title live".

enum DocumentRenameService {
    /// Everything a rename needs, flattened into `Sendable` values so the
    /// actual disk work can be handed to a detached task. Built from a
    /// `HomeSearchItem` (home screen) or a `DocumentInfo` (open tab); the
    /// service does not know or care which.
    struct Target: Sendable, Equatable {
        let kind: DocumentKind
        /// Absolute file path, or the page URL.
        let locator: String
        /// The path exactly as the recents list recorded it, which differs from
        /// `locator` when a moved PDF was re-resolved. Nil when the document is
        /// not in the recents list.
        let recordedPath: String?
        /// `documents/<key>/` folder name, when known.
        let storageKey: String?
    }

    /// Persist `title` everywhere it is stored for this document.
    ///
    /// Blocking disk work — call it off the main actor. Each store is
    /// independent and best-effort: a saved page whose record is stranded in
    /// iCloud should not stop the recents list from picking up the new name,
    /// so a failure in one is not allowed to abandon the others. Returns
    /// whether anything at all was written, which is what the caller needs to
    /// decide between "renamed" and "there was nothing here to rename".
    @discardableResult
    static func apply(_ target: Target, title: String?) -> Bool {
        var wrote = false

        // 1. The document's own metadata folder. Absent for a document that
        // has never been annotated or chatted about, which is normal, not an
        // error — the recents entry below still carries the name.
        if let key = target.storageKey, DocumentDataStore.setTitle(forKey: key, title: title) {
            wrote = true
        }

        // 2. The saved-page record, for pages in the web library. `setTitle`
        // throws when the record is an undownloaded iCloud placeholder;
        // refusing to write is correct there (it would clobber the real record
        // on reconnect) and is not a reason to skip the rest.
        if target.kind == .web, (try? WebLibrary.setTitle(rawUrl: target.locator, title: title)) != nil {
            wrote = true
        }

        // 3. The recents list. Keyed on the RECORDED path — the resolved one
        // is where the file is now, but the list is indexed by what it stored.
        if let recorded = target.recordedPath {
            let before = RecentFilesService.getRecent()
            let after = RecentFilesService.updateTitle(path: recorded, title: title)
            if before != after { wrote = true }
        }

        return wrote
    }

    /// Production variant: web sidecars cross the coordinated async gateway,
    /// while PDF metadata and the device-local recents list retain their
    /// existing stores.
    @discardableResult
    static func apply(
        _ target: Target,
        title: String?,
        storage: WebLibraryStorage
    ) async -> Bool {
        var wrote = false

        if let key = target.storageKey,
           await Task.detached(priority: .userInitiated, operation: {
               DocumentDataStore.setTitle(forKey: key, title: title)
           }).value {
            wrote = true
        }

        if target.kind == .web,
           (try? await storage.setTitle(rawUrl: target.locator, title: title)) != nil {
            wrote = true
        }

        if let recorded = target.recordedPath {
            let changed = await Task.detached(priority: .userInitiated) {
                let before = RecentFilesService.getRecent()
                let after = RecentFilesService.updateTitle(path: recorded, title: title)
                return before != after
            }.value
            if changed { wrote = true }
        }

        return wrote
    }

    /// The normalized title actually stored: trimmed, and nil when blank.
    ///
    /// Blank means "stop overriding", not "the title is the empty string" — an
    /// empty title would render as a nameless row that cannot be read, clicked
    /// with confidence, or found by search. Clearing falls back to the filename
    /// or the host, which is what the row showed before anyone renamed it.
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension DocumentRenameService.Target {
    /// Build a target from a home-screen result.
    init(item: HomeSearchItem) {
        let recorded: String?
        switch item.target {
        case .file(_, let recordedPath):
            // Only recents rows carry a recents record; a library-only document
            // has its recorded path set to its locator by the provider, and
            // updating a recents entry that does not exist is a harmless no-op.
            recorded = recordedPath
        case .url(let url):
            recorded = url
        }
        self.init(
            kind: item.kind,
            locator: item.target.openKey,
            recordedPath: recorded,
            storageKey: item.storageKey)
    }
}
