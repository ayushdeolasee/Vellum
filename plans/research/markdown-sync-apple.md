# Syncing a user-editable markdown folder across macOS, iPadOS and iOS

Research for [Vellum#172](https://github.com/ayushdeolasee/Vellum/issues/172), part of the knowledge-base map ([Vellum#170](https://github.com/ayushdeolasee/Vellum/issues/170)).

The vault must be **real files the user can open in any editor** *and* **present on all three devices**. This documents the option space. It deliberately does not recommend one — that is [Vellum#175](https://github.com/ayushdeolasee/Vellum/issues/175).

## The finding that dominates everything else

**iCloud does not merge files. It picks a winner and files the loser as a conflict version.**

> "For files in the cloud, there is usually only one version of the file at any given time. However, additional file versions may be created in cases where two different computers attempt to save the file to the cloud at the same time. In that case, one file is chosen as the current version and any other versions are tagged as being in conflict with the original. Conflict versions are reported to the appropriate file presenter objects and should be resolved as soon as possible so that the corresponding files can be removed from the cloud."
> — [NSFileVersion](https://developer.apple.com/documentation/foundation/nsfileversion)

There is no per-line, per-section or three-way merge anywhere in the iCloud stack. Whole-file, last-writer-nominated, losers preserved for the app to deal with. Any "the AI appended a paragraph while you edited a sentence on your iPad" scenario produces two complete files, not a merged one.

A second constraint compounds it: unresolved conflict versions **consume the user's iCloud storage** until the app resolves them.

> "When done resolving a conflict, be sure to delete any out-of-date document versions; if you don't, you needlessly consume capacity in the user's iCloud storage."
> — [Designing for Documents in iCloud](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html)

So conflict handling is not optional polish. An app that ignores it leaks the user's storage quota.

## Hard gate: the free Personal Team has none of this

Apple's [Supported capabilities (iOS)](https://developer.apple.com/help/account/reference/supported-capabilities-ios/) reference lists capabilities against membership type. For a free account ("Apple Account holders who have agreed to the Apple Developer Agreement… No cost is associated with this agreement and developers can't distribute apps"):

| Capability | Free account | Paid ADP/ADEP |
|---|---|---|
| iCloud: CloudKit | ✗ | ✓ |
| iCloud: iCloud documents | ✗ | ✓ |
| App groups | ✗ | ✓ |
| Push notifications | ✗ | ✓ |
| Background modes | ✗ | ✓ |
| Sign in with Apple | ✗ | ✓ |

This is broader than [Vellum#149](https://github.com/ayushdeolasee/Vellum/issues/149) currently records. #149 tracks the iCloud entitlement; the table shows **Background modes** is also gated. Any design that assumes background sync or background capture on iOS is blocked by the same wall, not just the iCloud part.

Everything below marked "requires iCloud" is therefore unavailable until the paid account lands (~2026-08-21).

## Option 1 — iCloud Drive ubiquity container

The app owns a container; files inside it sync; the user can see and edit them.

**Getting the container.** `FileManager.url(forUbiquityContainerIdentifier:)` returns the root URL; you append paths to it ([iCloud File Management](https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html)).

**Making files user-visible.** Two separate things are required, and both are easy to miss.

1. Files must live in a `Documents` subdirectory of the container:
   > "Place files in the `Documents` subdirectory of an iCloud container to make them visible to the user and make it possible for the user to delete them individually. Files you place outside of the `Documents` subdirectory are grouped together as 'data.'"

   Files outside `Documents` "can be deleted by the user only as a monolithic group."

2. `Info.plist` needs an `NSUbiquitousContainers` dictionary with `NSUbiquitousContainerIsDocumentScopePublic = YES`, plus `NSUbiquitousContainerName` for the Finder-visible name and `NSUbiquitousContainerSupportedFolderLevels`.

   A non-obvious trap from [Technical Q&A QA1893](https://developer.apple.com/library/archive/qa/qa1893/_index.html): the container does not appear until it has been used.
   > "Only the containers used by the user are being displayed in iCloud Drive. So even after you setting `NSUbiquitousContainerIsDocumentScopePublic` to `YES` and bumping the `Bundle` `version` of your app, your iCloud container will not appear in iCloud Drive if it has never been used. Try to copy at least one file to your iCloud container if it doesn't show up as expected."

   *Not established from primary sources:* the exact allowed values of `NSUbiquitousContainerSupportedFolderLevels`. Community sources use `None`, `One` and `Any` inconsistently and Apple's archived guide no longer renders the sample. Verify against a live Xcode build before relying on a specific value.

**Tracking files.** `NSMetadataQuery` with `NSMetadataQueryUbiquitousDocumentsScope` (inside `Documents`) or `NSMetadataQueryUbiquitousDataScope` (elsewhere). Apple's guidance is to start the query early in launch and register for `NSMetadataQueryDidUpdateNotification`.

**Coordinated access is mandatory.** All reads and writes go through `NSFileCoordinator`; anything displaying file contents needs an `NSFilePresenter`. This is how conflict versions get reported to the app in the first place.

**Conflict handling differs by platform.**

- iOS: the system nominates a winner but the app must confirm or override it.
  > "The iOS document architecture manages conflict resolution by nominating a winning `NSFileVersion` object, but it is your iOS app's responsibility to accept the suggested version or specify a different one."

  Detection is via `UIDocumentStateChangedNotification` and a `documentState` of `UIDocumentStateInConflict`.
- macOS: "In OS X, rely on the system to resolve document conflicts. OS X manages conflict resolution for you when you use documents." Note the qualifier — this applies when using the `NSDocument` architecture, which Vellum does not use for a markdown vault.

Relevant API surface: `unresolvedConflictVersionsOfItem(at:)`, `otherVersionsOfItem(at:)`, `isConflict`, `isResolved`, `remove()`, `replaceItem(at:options:)`.

There is also an explicit warning about cross-device races:
> "Keep in mind that another instance of your app, running on another device attached to the same iCloud account, might resolve the conflict before the local instance does."

**Offline.** Files remain locally available and sync on reconnect; `evictUbiquitousItem(at:)` refreshes a local copy. Offline edits on two devices are precisely the documented conflict-generating scenario.

**Capacity.** "Limited only by the space available in the user's iCloud account" ([iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)).

**Requires:** paid account.

## Option 2 — CloudKit records

Apple's stated positioning ([iCloud Fundamentals](https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/iCloudFundametals.html)):

- Key-value storage "is for discrete values such as preferences, settings, and simple app state" — capped at **1 MB total per app, 1 MB per key**. Far too small for a vault; noted only to rule it out.
- Document storage "is for user-visible file-based content."
- CloudKit "is for storing data as individual records in a private or public database accessible by all your app's users… Use CloudKit in situations where key-value storage and document storage are insufficient for your needs."

Apple's own framing puts a user-visible file-based vault in the *document storage* column, not CloudKit.

CloudKit's advantage is that records are structured, so conflict resolution can be **per-field** rather than per-file — the merge problem becomes tractable. Its cost is that the browsable-folder requirement no longer comes free: you would be projecting records out to disk and reconciling edits back in, which reintroduces the merge problem at the boundary you were trying to avoid.

Private database capacity is "limited only by the space available in the user's iCloud account."

**Requires:** paid account.

**Not established:** whether `NSPersistentCloudKitContainer` offers anything useful here. It is Core Data-shaped and Vellum's stores are plain-file; not investigated further.

## Option 3 — a user-chosen folder (e.g. an existing Obsidian vault)

The user points Vellum at a folder they already sync however they like — iCloud Drive, Dropbox, Syncthing. Vellum never owns the sync problem.

This is viable on iOS. `UIDocumentPickerViewController` is "A view controller that provides access to documents or destinations outside your app's sandbox" and the documentation is explicit about persisting that access:

> "Don't save URLs that the open and move operations provide. You can, however, save a bookmark to these URLs after calling `startAccessingSecurityScopedResource()` to ensure you have access. Call the `bookmarkData(options:includingResourceValuesForKeys:relativeTo:)` method and pass in the `withSecurityScope` option, creating a bookmark that contains a security-scoped URL."

The same three obligations apply as for option 1: `startAccessingSecurityScopedResource()` / `stopAccessingSecurityScopedResource()` around access, `NSFileCoordinator` for all reads and writes, `NSFilePresenter` when displaying contents ([UIDocumentPickerViewController](https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller)).

**This is the only option that works today on the free Personal Team**, because it needs no iCloud entitlement — the user's own sync service does the syncing.

Vellum already has `SecurityScopedBookmark` and stores `bookmarkData` on `DocumentInfo`, so the pattern is established in the codebase.

The tradeoff: conflict behaviour is now whatever the user's sync provider does, which Vellum can neither control nor reason about. Dropbox produces "conflicted copy" files; Syncthing produces its own. Vellum would see them as unexpected extra files in the vault.

## Option 4 — File Provider extension

Not investigated in depth. This is the API for *being* a cloud storage provider — surfacing a remote namespace inside Files.app. Vellum wants the opposite: to consume a synced folder, not to serve one. Recorded here to note it was considered and set aside, not because it was proven unsuitable.

## What this leaves for the decision

1. Whole-file conflict semantics are a property of the platform, not a choice. Any design where two devices can write the same file needs an answer for two complete divergent copies.
2. The most direct way to sidestep it is structural: **make concurrent writes to the same file impossible** — device-scoped or append-only file naming, so merges never arise. That is a vault-layout decision, which belongs to [Vellum#171](https://github.com/ayushdeolasee/Vellum/issues/171) and [Vellum#176](https://github.com/ayushdeolasee/Vellum/issues/176).
3. Option 3 is the only path that ships before ~2026-08-21, and it is also the only one that makes Vellum interoperable with a vault the user already has.
4. #149 should be widened to record that **Background modes** is gated too, not just iCloud.
