# Packet 2 — `.vellum` bundles (parity issue #129, phase 2 / sub-issue #131)

**Source of delta:** `/Users/ayushdeolasee/Developer/Vellum/main`, range `a42705d1~1..7742a895`
**Target:** `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`, iOS-only, xcodegen from `project.yml`)

**Scope of this packet:** the `.vellum` "share with notes" container — codec (write/read, checksums,
size caps, path-traversal guards), sidecar install + merge rules, the export-with-notes UI entry
point, the import flow (destination choice + merge prompts as iOS alerts, since the Mac uses
`NSAlert.runModal`), `.vellum` / `.vellumweb` UTI + document-type registration in
`Info-iOS.plist`, routing Files-app opens through the iPad's existing `vellumOpenFile`
notification path, human-readable `<Page Title>.vellumweb` filenames, safe rejection of malicious
bundles, and the bundle round-trip test suite.

The upstream commits that produced this surface are:
`1ba3a5d9` (Storage PR 3 — the bundle itself), `f2a71c03` (first-round review fixes: doc-id stamp
on import), `a3606d93` (second-round hardening: canonical doc_id, atomic import write, attachment
failure surfacing, pre-parse caps, silent-open-no-op fix), `9919858a` (discard-and-reload on
sidecar import), `ec3b4877` (`AiPersistence.decodeMessages` lossy merge — consumed by the merge).

---

## 1. Delta files claimed

### VERBATIM (1)

| File | Note |
|---|---|
| `Vellum/Services/VellumBundle.swift` | Pure Foundation. Copy byte-for-byte from main. |

### MERGE (5)

| File | Note |
|---|---|
| `Tests/VellumBundleTests.swift` | No iPad counterpart; copy then apply the 3 iOS adaptations in §4. |
| `Vellum/Services/Web/WebArchive.swift` | **Shared file.** I own only the two `MiniZip` pre-parse accessors (`entryCount`, `totalDeclaredUncompressedSize`). The `nonisolated(unsafe)` removals in the same diff move to **packet 9** (packet 10 §3.2) — packet 9 owns the single repo-wide decision on those removals and on `SWIFT_TREAT_WARNINGS_AS_ERRORS`; the decision is stated once, in packet 9. |
| `Vellum/Services/SessionService.swift` | **Shared file.** I own `Notification.Name.vellumDocumentSidecarImported`. `vellumDocumentDataDeleted` belongs to the packet 1; `ensureDocumentId(sessionId:)` on the protocol belongs to packet 1. |
| `Vellum/Stores/AppStore.swift` | **Shared file.** I own the `.vellum` branch in `openOneFile`, `importVellumBundleCore` (+ the two-phase split it needs on iOS), and the iOS-native replacement for `importVellumBundle`. Everything else in that 58 KB diff (TabTeardownRegistry, LiveTabRuntime, residency, integrations) is other packets. **Edit order (packet 10 §2.3): 1 → 4 → 2 — packet 2 goes LAST of the three `MERGE` owners.** Packet 7's one addition (`restorePendingNote`) is a surgical insert after all three. |
| `Vellum/Stores/ScratchpadStore.swift` | **Shared file.** I own `discardAndReload(for:)` + the `cancelPendingSave()` primitive it needs. The rest (clear/undo/redo, identity stamping, iCloud pause, attachment sweeps) belongs to the packets 6 and 1. |

### REBUILD (4) — AppKit-only UI re-derived iOS-natively

| File | iOS deliverable |
|---|---|
| `Vellum/Views/PDF/ToolbarView.swift` | `OverflowMenu.exportWithNotes` / `buildBundle` / `loadAttachments` → `Vellum/Platform/iOS/PdfChrome_iOS.swift` (`PdfToolbar_iOS` More menu + a new `ExportBundleSheet_iOS`). The macOS file is compiled out (`#if os(macOS)`) and its whole-file copy is contended with the Liquid Glass toolbar packet (#115) — do NOT copy it here. |
| `Vellum/Views/Panes/PaneView.swift` | **[REBUILD → `Platform/iOS/PaneView_iOS.swift`]** (normalised, packet 10 §2.2). The `.vellumDocumentSidecarImported` observer lands in `Vellum/Platform/iOS/PaneView_iOS.swift`. **Packet 4 owns the file**; packets 1 and 2 each add one observer to it. |
| `Vellum/App/VellumApp.swift` | **[REBUILD → `Platform/iOS/VellumApp_iOS.swift`]** (normalised, packet 10 §2.2). `VellumAppDelegate.application(_:open:)` → `.onOpenURL` in `Vellum/Platform/iOS/VellumApp_iOS.swift`. **Packet 4 is the sequencer** for this file — packets 2, 3 and 4 all route hunks into it, and packet 4 touches it most. |
| `Vellum/App/ContentView.swift` | **[REBUILD → `Platform/iOS/ContentView_iOS.swift`]** (normalised, packet 10 §2.2). The open-panel `allowedContentTypes` list (adds `.vellum`) → `DocumentImport.openableTypes` + the payload-carrying `vellumOpenFile` handler. **Sequence: packet 4 → packet 2.** |

### SKIP (19)

| File | Reason |
|---|---|
| `Vellum/Resources/Info.plist` | **[SKIP — packet 9 owns `Info-iOS.plist`]** (packet 10 §2.2, resolving a direct conflict with packet 9's `[MERGE]`). Copying this macOS plist wholesale was cosmetic — it is excluded from the iOS target (`project.yml` `excludes: Resources/Info.plist`), so a byte-for-byte copy is a needless write to dead weight. The genuinely required change is to `Info-iOS.plist`; packet 2 still specifies it in §3, but packet 9 is the one who applies it. |
| `Vellum/App/VellumCommands.swift` | macOS-gated; the only bundle-relevant hunk is the same `allowedContentTypes` list, already covered by `DocumentImport.openableTypes`. Whole-file copy owned by the keyboard/commands packet. |
| `Vellum/Views/Welcome/WelcomeScreen.swift` | Same — macOS open-panel type list only. iPad Home uses `DocumentImport.openableTypes`. Owned by the Home/search packet. |
| `Vellum/Services/DocumentDataStore.swift` | **Hard dependency**, owned by packet 1. |
| `Vellum/Services/DocumentIdentity.swift` | **Hard dependency**, owned by packet 1. |
| `Vellum/Services/Pdf/PdfMetadata.swift` | **Hard dependency** (`documentId(atPath:)`, `stampDocumentId(atPath:id:)`), packet 1. |
| `Vellum/Services/Pdf/PdfDocIdRegistry.swift` | Packet 1. |
| `Vellum/Services/Pdf/PdfSessionBackend.swift` | Packet 1 (`ensureDocumentId`; PdfFileGate stays per standing decision). |
| `Vellum/Models/Models.swift` | Packet 1 (`DocumentInfo.docId`). |
| `Vellum/Services/DocumentSessionManager.swift` | Packet 1 (`ensureDocumentId` plumbing). |
| `Vellum/Services/Ai/AiPersistence.swift` | **Hard dependency** (`decodeMessages`, `limitedMessages`, `invalidateCachedConversation`, reference/tool-summary caps), owned by the packet 5. |
| `Vellum/Models/AiToolSummary.swift` | packet 5 (needed only by one ported test). |
| `Vellum/Services/Scratchpad/ScratchpadPersistence.swift` | packets 6 and 1 (`save(forKey:schemeText:)`, `load(forKey:)`). |
| `Vellum/Services/Web/WebStorage.swift` | packet 1 (`documentsDir`, relocation). No bundle content. |
| `Vellum/Services/Web/WebLibrary.swift` | packet 1. `rfc3339Now` / `jsonEncoderPretty` already exist on iPad. |
| `Vellum/Services/StorageHousekeeping.swift`, `Vellum/Views/Settings/StorageSettingsTab.swift`, `Vellum/Views/Settings/StorageInventory.swift` | packet 1. |
| `Tests/StorageManagementTests.swift`, `Tests/DocumentDataStoreTests.swift`, `Tests/DocumentIdentityTests.swift`, `Tests/DocumentsRelocationTests.swift`, `Tests/RecentsResolveTests.swift`, `Tests/AiConversationStoreTests.swift` | packets 1 and 5. |
| `UITests/**` (`VellumConsistencyUITests.swift`, `VellumUITestCase.swift`, `README.md`, `ScratchpadSnapshotUITests.swift`), `Vellum.xcodeproj/**` | macOS XCUITest target; the iPad project has no UI-test target and is generated by xcodegen. |
| `plans/read-later-integrations.html`, `plans/storage-design.html`, `plans/00*.md`, `CHANGELOG.md`, `AGENTS.md`, `CLAUDE.md`, `.github/workflows/claude.yml`, `.gitignore` | Docs/plans/CI — not ported. `.gitignore` confirmed [SKIP — packet 9 owns] per packet 10 §2.2. |

**Note on `project.yml`:** main's diff to it is entirely the macOS UI-test target + stable signing + warnings-as-errors. **No change is needed for this packet** — see §3. Confirmed [SKIP]: **packet 9 is the sole editor of `project.yml`** (packet 10 §2.2/§2.3).

---

## 2. Port order & instructions

Execute in this order. Steps 0–2 are the codec (no UI); 3–6 are the flows.

---

### Step 0 — `Vellum/Services/Web/WebArchive.swift` [MERGE, tiny]

**What main changed (bundle-relevant hunk only):** two computed properties added to `struct MiniZip`,
right after `var entryNames: [String] { orderedNames }` (main line ~813):

```swift
    /// Number of entries the central directory declares.
    var entryCount: Int { orderedNames.count }

    /// Sum of every entry's DECLARED uncompressed size. Attacker-controlled in a
    /// shared archive, so a caller uses it only as a pre-parse budget gate — never
    /// as ground truth (`readCapped` re-checks each entry while inflating).
    var totalDeclaredUncompressedSize: Int {
        entries.values.reduce(0) { $0 + $1.uncompressedSize }
    }
```

**iPad today:** `Vellum/Services/Web/WebArchive.swift` has `MiniZip` with `orderedNames`,
`entries: [String: Entry]`, `Entry.uncompressedSize` (line ~805), `readCapped(_:cap:)` (line ~896),
`write(entries:)` (line ~731), `sha256Hex` (line ~150), `isPrecompressed` (line ~313),
`safeAssetName` (line ~486). All the primitives `VellumBundle` needs are present.

**Instructions:** insert the two properties verbatim after `var entryNames`. Nothing else in main's
`WebArchive.swift` diff belongs to this packet — in particular, do **not** touch the
`nonisolated(unsafe) private static let scriptRegex` → `private static let scriptRegex` changes.
Those move to **packet 9** (packet 10 §3.2; there is no "warnings-free packet" — that phantom
packet's scope, including the `SWIFT_TREAT_WARNINGS_AS_ERRORS` decision, folds into packet 9, which
states the decision once). Dropping `nonisolated(unsafe)` under `SWIFT_STRICT_CONCURRENCY: minimal`
is a no-op either way, so leaving it untouched here costs nothing.

**Verify:** `MiniZip.Entry` on iPad exposes `uncompressedSize` as a stored `var Int` — confirmed at
`WebArchive.swift:805`.

---

### Step 1 — `Vellum/Services/VellumBundle.swift` [VERBATIM]

**Source:** `/Users/ayushdeolasee/Developer/Vellum/main/Vellum/Services/VellumBundle.swift` (464 lines)
**Dest:** `/Users/ayushdeolasee/Developer/Vellum/ipad-app/Vellum/Services/VellumBundle.swift`

Copy byte-for-byte. It is pure Foundation — `import Foundation` only, no AppKit, no availability
guards, no `#if os(...)` needed. xcodegen picks it up automatically (`sources: - path: Vellum`
is recursive).

**What it contains (so the implementer knows what must not drift):**

- `formatName = "vellum"`, `formatVersion = 1`.
- Read caps: `maxManifestBytes` 4 MiB, `maxDocumentBytes` 2 GiB, `maxScratchpadBytes` 8 MiB,
  `maxConversationsBytes` 32 MiB, `maxAttachmentBytes` 16 MiB, `maxTotalAttachmentBytes` 256 MiB,
  `maxAttachments` 1000.
- Pre-parse guards: `maxArchiveBytes` 2 684 354 560 (2.5 GiB, checked with a `stat`, not a read);
  `maxEntries` 4096 (central-directory entry count); `maxTotalUncompressedBytes` (sum of declared
  uncompressed sizes). All three fire **before** MiniZip touches a single entry payload.
- `Manifest: Codable` with an explicit `CodingKeys` mapping to **snake_case** JSON:
  `doc_id`, `document_file`, `exported_at`, `includes_conversations`. **This is a persistence
  format — byte compatibility with the Mac is mandatory. Do not rename, do not add a
  `keyEncodingStrategy`.** The manifest is encoded with `WebLibrary.jsonEncoderPretty`
  (`.prettyPrinted, .withoutEscapingSlashes`) and decoded with a plain `JSONDecoder()`.
- Zip layout: `manifest.json`, `document/<document_file>`, `scratchpad.md`,
  `attachments/<id>.<ext>`, `conversations.json`.
- `safeName(_:)` — rejects empty / `..` / `/` / `\` / leading-dot names.
- `hasTraversal(_:)` — rejects any *physical* entry name containing `..`, starting `/`, or
  containing `\`, regardless of whether the manifest references it.
- `write(_:to:)` — atomic: temp sibling `.<name>.tmp-<pid>-<uuid>`, `FileHandle.synchronize()`,
  then `rename(2)`. Document entry is `stored: true` (never deflated).
- `read(at:)` — size gate → MiniZip parse → entry-count gate → declared-size gate → traversal scan
  → manifest decode → `format` check → `version > 1` rejection with the exact string
  `"please update Vellum"` → `DocumentIdentity.isCanonicalKey(manifest.docId)` gate → per-entry
  `readCapped` + sha256 verification for document / scratchpad / each attachment / conversations,
  with a running `maxTotalAttachmentBytes` budget.
- `installSidecar(_:forKey:resolveScratchpadConflict:)` — the merge rules:
  - scratchpad: written when none exists locally or the local copy is byte-identical; a *differing*
    local note calls `resolveConflict(title)`;
  - attachments: copied, never overwriting an existing id (compared by lowercased stem);
    failures are collected and **returned** (never silently swallowed);
  - conversations: `mergeConversations` — both sides decoded through
    `AiPersistence.decodeMessages` (lossy, per-message), local-wins on id collision, sorted by
    `createdAt`, then `AiPersistence.limitedMessages(...)`, then written back.
    If the *local* file exists but decodes to nothing, it **throws** rather than overwriting.

**Compile dependencies (all cross-packet — see §5):**
`DocumentKind`, `SessionServiceError.io/.invalidDocument` (present on iPad),
`WebArchive.sha256Hex/.isPrecompressed`, `MiniZip.Entry/.write/.readCapped/.entryCount/.totalDeclaredUncompressedSize`
(present after Step 0), `WebLibrary.rfc3339Now/.jsonEncoderPretty` (present on iPad),
`DocumentIdentity.isCanonicalKey` (**packet 1**), `DocumentDataStore.*` (**packet 1**),
`AiMessage`, `AiPersistence.decodeMessages/.limitedMessages` (**packet 5**).

---

### Step 2 — `Vellum/Services/SessionService.swift` [MERGE, tiny]

**What main changed (mine):** one entry appended to the `extension Notification.Name` block:

```swift
    /// Broadcast after a `.vellum` import installs a sidecar under a storage key
    /// (userInfo["key"]). Any pane showing a document with that key reloads its
    /// scratchpad + conversation so the freshly-merged notes/chat replace stale
    /// live state instead of being clobbered by its next flush. (vellum:sidecar-imported)
    static let vellumDocumentSidecarImported = Notification.Name("vellum.sidecar-imported")
```

**iPad today:** `SessionService.swift:52-64` has `vellumAnnotationsUpdated`, `vellumAddWebpage`,
`vellumOpenFile`, `vellumAiSettingsChanged`. `vellumOpenFile` is iPad-only — **preserve it**.

**Instructions:** append the one constant above after `vellumAiSettingsChanged`. Leave
`vellumDocumentDataDeleted` to the packet 1 and the `ensureDocumentId(sessionId:)` protocol
requirement to packet 1 — if either has already landed, just don't duplicate them.

---

### Step 3 — `Vellum/Stores/ScratchpadStore.swift` [MERGE, bundle-scoped hunk only]

**What main changed (mine — two additions):**

```swift
    /// Reload this document's note from disk WITHOUT first flushing the stale
    /// in-memory text — used when a `.vellum` import rewrote scratchpad.md on
    /// disk under this document's key. The normal `loadForDocument` FLUSHES the
    /// current text first, which would rewrite the just-imported file with the
    /// pre-import note before reading it back. This cancels any pending debounced
    /// save so a write armed before the import can never fire afterward, then
    /// restores from disk under the restore guard.
    func discardAndReload(for document: DocumentInfo?) {
        cancelPendingSave()
        restore(document: document)
    }

    /// Cancel any armed debounced save WITHOUT persisting.
    private func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }
```

Main also refactored `loadForDocument` into `flush()` + `restore(document:)`, where `restore` is the
"retarget + load from disk, never persist" body.

**iPad today:** `ScratchpadStore.loadForDocument` is (pre-delta shape) `flush()` then
`ScratchpadPersistence.documentKey(document)` then `setRestored(...)` then `pruneOrphanedAttachments()`.
There is no `restore(...)` split and no `cancelPendingSave`.

**Instructions (bundle-scoped, safe whether or not the packet 6 has landed):**

1. Extract the *body after* `flush()` in `loadForDocument` into `private func restore(document: DocumentInfo?)`,
   leaving `loadForDocument` as `flush(); restore(document: document)`. **Do not otherwise change the
   body** — whatever key-resolution the packets 6 and 1 has installed at that point stays.
2. Add `private func cancelPendingSave()` and make `flush()` call it instead of inlining
   `saveTask?.cancel(); saveTask = nil`.
3. Add `discardAndReload(for:)` exactly as above.

**Preserve:** every iPad-only behavior already in the file. Coordinate with the packet 6 —
if it lands first with the full main-side rewrite (clear/undo/redo, `isPersistencePaused`,
`ensureIdentityForFirstWriteIfNeeded`), `discardAndReload` and `cancelPendingSave` come with it and
this step is a no-op; just verify both symbols exist.

---

### Step 4 — `Vellum/Stores/AppStore.swift` [MERGE] — import core

**Sequencing (packet 10 §2.3).** `AppStore.swift` is a three-owner `MERGE` file (packets 1, 4, 2).
**Edit order: 1 → 4 → 2 — packet 2 lands LAST.** Land packet 1's and packet 4's hunks first, then
apply this step against the result. Packet 7's `restorePendingNote` addition is a surgical insert
after all three, not part of this ordering.

**What main changed (mine, three hunks):**

**(a) `openOneFile` gains a `.vellum` branch** (main `AppStore.swift:1138-1149`):

```swift
    private func openOneFile(path: String) async throws {
        // A `.vellum` bundle unpacks into a document (written where the user
        // chooses) + its sidecar; then that document opens through the normal
        // path. Everything else is opened directly.
        if path.lowercased().hasSuffix(".vellum") {
            guard let documentPath = try await importVellumBundle(bundlePath: path) else { return }
            try await openDocumentFile(path: documentPath)
            return
        }
        try await openDocumentFile(path: path)
    }
```

Main also split the old body into `openDocumentFile(path:)`, which additionally calls
`await awaitTeardowns(ofDocumentAt: path)` (TabTeardownRegistry — **another packet**).

**iPad today:** `AppStore.swift:535-553` — `openOneFile` is the whole body (mint sessionId, branch
on `.vellumweb`, `adoptOpenedDocument`, post `vellumAnnotationsUpdated`). No `openDocumentFile`,
no `awaitTeardowns`.

**Instructions:** rename the existing iPad `openOneFile` body to `private func openDocumentFile(path: String) async throws`
**unchanged** (do NOT add `awaitTeardowns` — if the tab-teardown packet lands it will add it there),
then add the new `openOneFile` above. On iOS, after a successful bundle import, also clean up a
staged temp bundle:

```swift
    private func openOneFile(path: String) async throws {
        if path.lowercased().hasSuffix(".vellum") {
            guard let documentPath = try await importVellumBundle(bundlePath: path) else { return }
            #if os(iOS)
            // A bundle picked from Files is staged into tmp/ (see DocumentImport):
            // it is a container, not a document, so it must not linger.
            if path.hasPrefix(FileManager.default.temporaryDirectory.path) {
                try? FileManager.default.removeItem(
                    at: URL(fileURLWithPath: path).deletingLastPathComponent())
            }
            #endif
            try await openDocumentFile(path: documentPath)
            return
        }
        try await openDocumentFile(path: path)
    }
```

**(b) `importVellumBundleCore` — adopt, but split into two phases.**

Main's version (`AppStore.swift:1244-1330`) is a single `@MainActor static` async function. It is
platform-free **except** that its `resolveScratchpadConflict` closure is **synchronous** — which
works on macOS because `NSAlert.runModal()` blocks, and cannot work on iOS where a
`UIAlertController` / SwiftUI alert must be awaited.

Adopt main's body verbatim but split it at the point where the storage `key` is resolved, and keep
main's exact public signature as a thin wrapper so the ported tests compile unchanged:

```swift
    /// Phase 1 of an import: write the document bytes ATOMICALLY (temp sibling +
    /// rename(2), never a pre-delete), stamp an unstamped PDF with the manifest
    /// id, and resolve the storage key the sidecar will install under.
    /// Split out from `importVellumBundleCore` so iOS can await a merge prompt
    /// between the two halves (a UIAlertController can't be run modally).
    @MainActor
    static func writeImportedDocument(
        _ imported: VellumBundle.Imported, to destination: URL
    ) async throws -> String {
        // ... main's lines from `let manifest = imported.manifest` through the
        //     `let key: String = ...` detached-task block, verbatim ...
        return key
    }

    /// Phase 2: install the sidecar under the merge rules, drop the AI memory
    /// cache, broadcast the reload, and stamp meta.json.
    @MainActor
    static func finishImportedBundle(
        _ imported: VellumBundle.Imported,
        to destination: URL,
        key: String,
        resolveScratchpadConflict resolveConflict: (_ title: String) -> VellumBundle.ScratchpadDecision
    ) throws -> (path: String, failedAttachments: [String]) {
        let failedAttachments = try VellumBundle.installSidecar(
            imported, forKey: key, resolveScratchpadConflict: resolveConflict)
        AiPersistence.invalidateCachedConversation(forKey: key)
        NotificationCenter.default.post(
            name: .vellumDocumentSidecarImported, object: nil, userInfo: ["key": key])
        if imported.manifest.kind != "web" {
            let info = DocumentInfo(
                kind: .pdf, pdfPath: destination.path, title: imported.manifest.title,
                pageCount: nil, lastPage: nil, docId: key)
            try? DocumentDataStore.touch(document: info)
        }
        return (destination.path, failedAttachments)
    }

    /// Main's signature, preserved so the upstream tests port unchanged.
    @MainActor
    @discardableResult
    static func importVellumBundleCore(
        _ imported: VellumBundle.Imported,
        to destination: URL,
        resolveScratchpadConflict resolveConflict: (_ title: String) -> VellumBundle.ScratchpadDecision
    ) async throws -> (path: String, failedAttachments: [String]) {
        let key = try await writeImportedDocument(imported, to: destination)
        return try finishImportedBundle(
            imported, to: destination, key: key, resolveScratchpadConflict: resolveConflict)
    }
```

Details that must survive the split, verbatim from main:

- `createDirectory(at: parent, withIntermediateDirectories: true)` first, with
  `SessionServiceError.io("Failed to prepare the import destination: …")` on failure.
- Temp sibling name: `".\(destination.lastPathComponent).import-\(UUID().uuidString.lowercased())"`,
  written with `imported.documentData.write(to: tmp)`, then `rename(tmp.path, destination.path)`,
  removing the temp on either failure. **Never pre-delete the destination.**
- Key resolution for `kind == .pdf` happens in **one** `Task.detached(priority: .userInitiated)` hop
  (a stamp + a raw load are each a full PDF parse; on the main actor they froze the UI):
  ```swift
  key = await Task.detached(priority: .userInitiated) {
      if PdfMetadata.documentId(atPath: destinationPath) == nil {
          try? PdfMetadata.stampDocumentId(atPath: destinationPath, id: manifestId)
      }
      if let raw = try? PdfDocumentLoader.loadRaw(path: destinationPath),
         let stamped = PdfMetadata.documentId(raw) {
          return stamped
      }
      return manifestId
  }.value
  ```
  For `kind == .web`, `key = manifest.docId` (the URL hash) — web documents are never stamped.
- Nothing main-actor-isolated and no PDFKit/CGPDF value escapes the detached hop.

**(c) `importVellumBundle(bundlePath:)` — REBUILD for iOS.** Main's version is AppKit
(`NSApplication.shared.activate`, `NSSavePanel`, two `NSAlert`s). Replace under `#if os(iOS)`:

```swift
    /// Import a `.vellum` bundle: verify it, place the document in the app's
    /// library, then install the sidecar — pausing between the two for the merge
    /// prompt when the local note differs. Returns nil if the user cancels.
    ///
    /// macOS asks the user where the document lands (NSSavePanel). iOS has no
    /// save panel and the whole path layer expects writable in-container files,
    /// so the document lands in `DocumentImport.libraryDirectory` — the same
    /// place every picked PDF is copied to.
    private func importVellumBundle(bundlePath: String) async throws -> String? {
        let imported = try VellumBundle.read(at: URL(fileURLWithPath: bundlePath))
        let destination = DocumentImport.bundleDestination(
            documentFile: imported.manifest.documentFile, docId: imported.manifest.docId)

        let key = try await Self.writeImportedDocument(imported, to: destination)

        // Resolve the scratchpad conflict BEFORE installSidecar, because the
        // codec's resolver is synchronous (NSAlert.runModal on the Mac) and an
        // iOS alert can only be awaited.
        var decision = VellumBundle.ScratchpadDecision.keepLocal
        if let incoming = imported.scratchpad, !incoming.isEmpty,
           DocumentDataStore.scratchpadExists(forKey: key),
           DocumentDataStore.loadScratchpad(forKey: key) != incoming {
            decision = await BundleImportPrompts_iOS.scratchpadConflict(
                title: imported.manifest.title ?? "this document")
        }

        let result = try Self.finishImportedBundle(
            imported, to: destination, key: key) { _ in decision }

        // Never a silent success with broken image refs: name the attachments
        // that could not be installed.
        if !result.failedAttachments.isEmpty {
            await BundleImportPrompts_iOS.failedAttachments(result.failedAttachments)
        }
        return result.path
    }
```

**Preserve on the iPad side:** everything else in `AppStore.swift`, notably
`CreateAnnotationInput.createdAt`, the iPad `openFiles`/`adoptOpenedDocument` shape, and the
`vellumAnnotationsUpdated` post after a `.vellumweb` open.

**New file — `Vellum/Platform/iOS/BundleImportPrompts_iOS.swift`:**

```swift
#if os(iOS)
import UIKit

/// Modal prompts for the `.vellum` import flow. macOS runs these as `NSAlert.runModal()`
/// inside the synchronous merge-resolver; iOS can't block, so each is an async
/// `UIAlertController` bridged through a continuation and presented over the
/// frontmost view controller. Presented from UIKit rather than as a SwiftUI
/// `.alert` on purpose: an import can arrive via `.onOpenURL` during a cold
/// launch, before any view that owns sheet state has appeared.
@MainActor
enum BundleImportPrompts_iOS {
    static func scratchpadConflict(title: String) async -> VellumBundle.ScratchpadDecision {
        await withCheckedContinuation { continuation in
            let alert = UIAlertController(
                title: "Notes already exist for \(title)",
                message: "This document already has notes on this iPad. Keep the notes you have, "
                    + "or replace them with the imported notes? Your highlights and reading "
                    + "position are not affected either way.",
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Keep My Notes", style: .cancel) { _ in
                continuation.resume(returning: .keepLocal)
            })
            alert.addAction(UIAlertAction(title: "Use Imported Notes", style: .destructive) { _ in
                continuation.resume(returning: .useImported)
            })
            alert.view.accessibilityIdentifier = "import.scratchpadConflict"
            guard let presenter = Self.topViewController() else {
                return continuation.resume(returning: .keepLocal)   // fail safe: never lose local notes
            }
            presenter.present(alert, animated: true)
        }
    }

    static func failedAttachments(_ names: [String]) async { /* single-OK alert, same idiom */ }
    static func importFailed(_ message: String) async { /* single-OK alert, same idiom */ }
    private static func topViewController() -> UIViewController? { /* copy from DocumentPickerCoordinator_iOS */ }
}
#endif
```

- `Keep My Notes` is `.cancel` so it is the safe default and the swipe-away outcome, matching
  main's "default button = Keep My Notes".
- The `guard let presenter … else { .keepLocal }` fallback matters: losing the user's own notes
  because no presenter was available would be unrecoverable.
- Consider factoring `topViewController()` out of `DocumentPickerCoordinator_iOS` into a shared
  internal helper rather than duplicating it.

---

### Step 5 — `Vellum/Platform/iOS/DocumentImport.swift` [iPad-only, extend]

**Instructions:**

1. `openableTypes` gains the bundle type, and both custom types become deterministic
   `exportedAs` lookups (the app declares them — see §3; `TabDrag.swift:11` already uses this idiom):
   ```swift
   static let openableTypes: [UTType] = [
       .pdf,
       UTType(exportedAs: "com.vellum.webarchive"),
       UTType(exportedAs: "com.vellum.bundle"),
   ]
   ```
   *(If you keep `UTType(filenameExtension:)` instead, guard both with `if let` — it returns nil
   when LaunchServices hasn't picked up the declaration yet.)*

2. `importPicked(_:)` stages `.vellum` files into `tmp/` instead of the library — a bundle is a
   container that gets unpacked, not a document to keep:
   ```swift
   private static func isBundle(_ url: URL) -> Bool {
       url.pathExtension.lowercased() == "vellum"
   }

   private static func stagingDestination(for filename: String) -> URL {
       let dir = FileManager.default.temporaryDirectory
           .appendingPathComponent("vellum-import-\(UUID().uuidString.lowercased())", isDirectory: true)
       try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
       return dir.appendingPathComponent(filename)
   }
   ```
   In the copy loop, use `isBundle(url) ? stagingDestination(for: url.lastPathComponent) : uniqueDestination(for: url.lastPathComponent)`.
   Keep the existing `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource`
   pairing and the "already inside the container → open in place" short-circuit, but exclude
   bundles from that short-circuit (a `.vellum` sitting in the library should still be staged and
   removed after import — or simply left alone; either is acceptable, just be consistent with the
   cleanup in Step 4a which only removes staged copies under `tmp/`).

3. New `bundleDestination(documentFile:docId:)` — where an imported bundle's document lands:
   ```swift
   /// Where a `.vellum` bundle's document file lands. Re-importing an updated
   /// bundle for a document already in the library must overwrite that copy, not
   /// pile up "paper 2.pdf" — so an existing same-named file whose embedded
   /// /VellumDocId matches the manifest is reused. Anything else gets a unique name.
   /// `documentFile` has already passed `VellumBundle.safeName`, so it is a bare
   /// filename with no separators.
   static func bundleDestination(documentFile: String, docId: String) -> URL {
       let candidate = libraryDirectory.appendingPathComponent(documentFile)
       guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
       if PdfMetadata.documentId(atPath: candidate.path) == docId { return candidate }
       return uniqueDestination(for: documentFile)
   }
   ```
   Change `uniqueDestination` from `private` to internal (no keyword).
   *`PdfMetadata.documentId(atPath:)` is a packet-1 dependency; until it exists, drop the middle
   `guard`/`if` and always return `uniqueDestination(for:)`.*
   Note this parses a PDF synchronously — call it from `importVellumBundle`, which is already off
   the hot path, or wrap in the same detached hop as the stamp if profiling shows a hitch.

---

### Step 6 — Files-app open routing [REBUILD → `VellumApp_iOS.swift` + `ContentView_iOS.swift`]

**Ownership & sequencing (packet 10 §2.2).** `VellumApp.swift` is normalised to
`[REBUILD → Platform/iOS/VellumApp_iOS.swift]` with **packet 4 as sequencer** (packets 2, 3 and 4
all route hunks into it; packet 4 touches it most — land its hunks first). `ContentView.swift` is
normalised to `[REBUILD → Platform/iOS/ContentView_iOS.swift]`, sequence **packet 4 → packet 2**.
Apply the instructions below as hunks into files whose overall shape packet 4 owns.

**What main does:** `VellumAppDelegate.application(_ application: NSApplication, open urls: [URL])`
maps to paths and calls `workspace.focusedPane.app.openFiles(paths:)`, which dispatches by
extension (bundle import / archive import / plain PDF).

**iPad today:** `.vellumOpenFile` is a *payload-free* notification meaning "present the file
importer". It is posted from `ShortcutRouter_iOS.swift:56` (⌘O) and `PaneView_iOS.swift:152`
(a pane's "Open File…") and received in `ContentView_iOS.swift:65`. There is **no**
`.onOpenURL` handler at all, so a `.vellum` / `.vellumweb` / `.pdf` tapped in Files currently
launches Vellum and does nothing.

**Instructions:**

**(a) `Vellum/Platform/iOS/VellumApp_iOS.swift`** — add to the `WindowGroup` content, next to the
existing `.task`/`.sheet` modifiers:

```swift
                .onOpenURL { url in handleIncomingFile(url) }
```

and the handler:

```swift
    /// Files-app open / share-sheet "Open in Vellum" for a registered type
    /// (.pdf, .vellumweb, .vellum). The iOS analogue of macOS's
    /// `NSApplicationDelegate.application(_:open:)`: it copies the
    /// security-scoped file into the writable library (or stages a bundle in
    /// tmp/) off the main actor, then hands the local paths to the shell
    /// through the SAME `vellumOpenFile` channel ⌘O uses — a payload means
    /// "open these", no payload still means "show the picker".
    @MainActor
    private func handleIncomingFile(_ url: URL) {
        Task {
            let paths = await Task.detached(priority: .userInitiated) {
                DocumentImport.importPicked([url])
            }.value
            guard !paths.isEmpty else { return }
            NotificationCenter.default.post(
                name: .vellumOpenFile, object: nil, userInfo: ["paths": paths])
        }
    }
```

**(b) `Vellum/Platform/iOS/ContentView_iOS.swift`** — teach the existing receiver (line 65) about
the payload:

```swift
        .onReceive(NotificationCenter.default.publisher(for: .vellumOpenFile)) { note in
            // A payload means "open these files" (a Files-app open routed here by
            // VellumApp_iOS); no payload keeps the original meaning, "present the
            // importer" (⌘O and a pane's Open File…).
            if let paths = note.userInfo?["paths"] as? [String], !paths.isEmpty {
                let app = workspace.focusedPane.app
                Task { await app.openFiles(paths: paths) }
            } else {
                presentImporter()
            }
        }
```

**Do not change** the two existing posters (`ShortcutRouter_iOS`, `PaneView_iOS`) — they post with
`object: nil` and no `userInfo`, so they keep hitting the `else` branch.

**Cold-launch ordering:** `.onOpenURL` can fire before `ContentView_iOS`'s
`.onReceive` subscription exists. If a Files open on a cold launch is observed to drop, buffer it:
keep a `@State private var pendingOpenPaths: [String]` on `VellumApp_iOS`, and have
`ContentView_iOS` drain it in an `.onAppear`. Verify on device before adding the complexity —
in practice SwiftUI delivers `onOpenURL` after the first body pass.

**Error surfacing:** a corrupt/hostile bundle throws out of `openFiles`. Check how the iPad's
`AppStore.openFiles` currently reports failures; if it swallows them, route
`SessionServiceError.invalidDocument`'s message to
`BundleImportPrompts_iOS.importFailed(_:)` so "Bundle document failed its integrity check",
"Bundle contains an unsafe entry path", etc. are actually seen. This is the whole point of the
"safe rejection of malicious bundles" requirement — silent rejection reads as a broken app.

---

### Step 7 — Export with notes [REBUILD of `ToolbarView.swift`]

**What main added** (`ToolbarView.swift` `OverflowMenu`, lines 628, 677-684, 824-935):

- `@State private var exportingBundle = false` — a *separate* guard from the web-only `exporting`
  flag, so the two flows can't interfere.
- A menu section, shown for **both** PDF and web documents:
  ```swift
  if hasDocument {
      Section {
          Button(action: exportWithNotes) {
              Label("Export Vellum Bundle with Notes…", systemImage: "arrow.up.doc")
          }
          .disabled(exportingBundle)
          .accessibilityIdentifier("toolbar.exportWithNotes")
      }
  }
  ```
- `exportWithNotes()` — NSSavePanel with an `accessoryView` holding an
  `NSButton(checkboxWithTitle: "Include AI conversation")`, **default OFF** (conversations are
  semi-private; sharing them must be explicit), `accessibilityIdentifier "export.includeConversation"`.
- `buildBundle(sessionId:document:destination:includeConversations:pages:)` — the real work.
- `loadAttachments(forKey:)` and `slugifiedTitle()`.

**iPad today:** `Vellum/Platform/iOS/PdfChrome_iOS.swift` — `PdfToolbar_iOS` has a `moreMenu`
(around line 230-320) with `Open File…`, `Add Webpage…`, `Save`, the web `Save for Offline Use` /
`Export a Copy…` pair, zoom fallbacks, split/merge, `Settings…`. It already has
`@State private var exporting`, `exportVellumweb()` (temp file → `DocumentPickerCoordinator_iOS.shared.presentExport`)
and an identical `slugifiedTitle()` (line ~413). `DocumentKey_iOS` resets toolbar state per tab.

**Instructions:**

1. Add `@State private var exportingBundle = false` and `@State private var showExportBundle = false`
   next to `exporting`.

2. In the More menu, after the `Save` / web section and before the zoom fallbacks, add:
   ```swift
   if appStore.document != nil {
       Button { showExportBundle = true } label: {
           Label("Export with Notes…", systemImage: "arrow.up.doc")
       }
       .disabled(exportingBundle)
       .accessibilityIdentifier("toolbar.exportWithNotes")
   }
   ```
   (Shorter title than the Mac's — it reads better in a compact iPad menu. Keep the accessibility
   identifier identical to main's so any shared test/automation matches.)

3. Attach the sheet to the same view the `showSettings` sheet hangs off:
   ```swift
   .sheet(isPresented: $showExportBundle) {
       ExportBundleSheet_iOS(
           title: appStore.document?.title,
           isWeb: isWeb
       ) { includeConversations in
           startBundleExport(includeConversations: includeConversations)
       }
   }
   ```

4. New view in the same file (the iOS stand-in for the NSSavePanel accessory checkbox):
   ```swift
   /// The `.vellum` export options. macOS puts this one checkbox in the save
   /// panel's accessoryView; iOS has no save panel, so the choice is made in a
   /// sheet and the finished bundle is handed to the Files export picker.
   struct ExportBundleSheet_iOS: View {
       var title: String?
       var isWeb: Bool
       var onExport: (Bool) -> Void

       @Environment(\.dismiss) private var dismiss
       @Environment(\.palette) private var palette
       // Conversations are semi-private: sharing them is explicit, so OFF.
       @State private var includeConversations = false

       var body: some View {
           NavigationStack {
               Form {
                   Section {
                       Toggle("Include AI conversation", isOn: $includeConversations)
                           .accessibilityIdentifier("export.includeConversation")
                   } header: {
                       Text("Include")
                   } footer: {
                       Text("The \(isWeb ? "page" : "document"), your notes and their images, and "
                            + "your highlights are always included. The AI conversation is not, "
                            + "unless you turn it on.")
                   }
               }
               .navigationTitle("Export with Notes")
               .navigationBarTitleDisplayMode(.inline)
               .toolbar {
                   ToolbarItem(placement: .cancellationAction) {
                       Button("Cancel") { dismiss() }
                   }
                   ToolbarItem(placement: .confirmationAction) {
                       Button("Export") { onExport(includeConversations); dismiss() }
                   }
               }
           }
           .presentationDetents([.medium])
       }
   }
   ```

5. `startBundleExport` + `buildBundle` + `loadAttachments` on `PdfToolbar_iOS`, ported from main's
   `OverflowMenu` with the panel replaced by the Files export picker:
   ```swift
   private func startBundleExport(includeConversations: Bool) {
       guard !exportingBundle,
             let sessionId = appStore.activeTabId,
             let document = appStore.document else { return }
       let pages = aiStore.pageTexts
           .sorted { $0.key < $1.key }
           .map { WebPageText(number: $0.key, text: $0.value) }
       exportingBundle = true
       Task {
           defer { exportingBundle = false }
           let tmp = FileManager.default.temporaryDirectory
               .appendingPathComponent("\(slugifiedTitle()).vellum")
           try? FileManager.default.removeItem(at: tmp)
           do {
               try await buildBundle(
                   sessionId: sessionId, document: document, destination: tmp,
                   includeConversations: includeConversations, pages: pages)
           } catch { return }
           DocumentPickerCoordinator_iOS.shared.presentExport(urls: [tmp])
       }
   }
   ```
   `buildBundle` is main's **verbatim** (it contains no AppKit):
   - `let pullKey = DocumentIdentity.storageKey(for: document)` — resolved **before** the stamp,
     because the stamp changes `DocumentInfo.docId`;
   - `let durableId = (try? await appStore.sessions.ensureDocumentId(sessionId: sessionId)) ?? pullKey`
     then `await appStore.syncDocumentId(sessionId: sessionId)`;
   - web: re-export through `sessions.exportVellumweb` into a temp `.vellumweb`, read the bytes,
     delete the temp, `documentFile = "\(slugifiedTitle()).vellumweb"`;
   - pdf: `documentData = try await appStore.sessions.readPdfBytes(sessionId: sessionId)` **after**
     the stamp (so the exported PDF carries `/VellumDocId`),
     `documentFile = VellumBundle.safeName(lastPathComponent) ?? "document.pdf"`;
   - sidecar pulled by `pullKey`: `DocumentDataStore.loadScratchpad`, `loadAttachments(forKey:)`,
     and `loadConversationsData` **only** when `includeConversations`;
   - `VellumBundle.write(content, to: destination)`.

   `loadAttachments(forKey:)` verbatim (sorted directory listing → `(name, data)` pairs).
   Reuse the existing `slugifiedTitle()` — do not add a second copy.

   `readPdfBytes` and `exportVellumweb` already exist on the iPad `SessionService`
   (`SessionService.swift:30, 37`). `ensureDocumentId` and `AppStore.syncDocumentId` do **not** —
   packet-1 dependency (§5).

6. Do **not** delete the temp `.vellum` after handing it to `presentExport` — the picker copies it
   asynchronously. This matches the existing `exportVellumweb` behaviour; `tmp/` is reclaimed by
   the system.

---

### Step 8 — Sidecar-imported reload [REBUILD → `Platform/iOS/PaneView_iOS.swift`]

**Ownership (packet 10 §2.2).** `PaneView.swift` is normalised to
`[REBUILD → Platform/iOS/PaneView_iOS.swift]`. **Packet 4 owns the file**; packets 1 and 2 each add
one observer to it (this step is packet 2's observer). Land after packet 4's shape is in place.

**What main added** (`PaneView.swift`, after the `vellumAnnotationsUpdated` observer):

```swift
        .onReceive(NotificationCenter.default.publisher(for: .vellumDocumentSidecarImported)) { note in
            guard let key = note.userInfo?["key"] as? String,
                  let document = app.document,
                  DocumentIdentity.storageKey(for: document) == key else { return }
            AiPersistence.invalidateCachedConversation(forKey: key)
            pane.ai.loadConversationForDocument(document)
            pane.scratchpad.discardAndReload(for: document)
        }
```

Rationale (commit `9919858a`): importing over an **open** document leaves the pane's live
`ScratchpadStore` / `AiStore` holding pre-import state whose next flush would overwrite the merge.
A plain `loadForDocument` flushes first and therefore rewrites the just-imported `scratchpad.md`
with the pre-import text — hence `discardAndReload` (Step 3).

**iPad today:** `PaneView_iOS.swift:103-106` has the `vellumAnnotationsUpdated` observer;
`loadDocumentState()` (line ~160) calls `pane.ai.loadConversationForDocument` and
`pane.scratchpad.loadForDocument`.

**Instructions:** add the observer verbatim immediately after the `vellumAnnotationsUpdated` one in
`PaneView_iOS.swift`. Do **not** add the `vellumDocumentDataDeleted` observer from the same diff —
that is the packet 1's.

**Preserve:** the iPad-only `.onAppear { inkRegistry.register(ink, for: pane.id) }` /
`.onDisappear { ink.flushPendingInk(); inkRegistry.remove(pane.id) }` pair, the
`PaneFocusCatcher_iOS` background, and the `#if DEBUG` auto-ink hook.

---

### Step 9 — Human-readable `<Page Title>.vellumweb` filenames

**Status: already at parity — verify only, no code change expected.**

The pretty archive layout (`WebStorageLayout.pretty`, `WebStorage.assignFileName(forKey:title:url:at:archivesDir:)`
which names managed archives `<Page Title>.vellumweb` via `.vellum/index.json`) exists in main at
the delta base (`git show a42705d1~1:Vellum/Services/Web/WebStorage.swift` — `assignFileName` at
line 220, `pretty` at 140) **and** in the iPad tree today
(`Vellum/Services/Web/WebStorage.swift` — `assignFileName` at line 306, `pretty` at 226,
`archivePath` selection at 578-594). The CHANGELOG entry "Offline copies are now human-navigable:
one `<Page Title>.vellumweb` per page" predates this delta.

**Verify** three things after the port and record the result:
1. `WebStorage.assignFileName` on iPad still title-derives and de-duplicates against
   `WebICloud.itemExists(at: archivesDir/candidate)`.
2. The `.vellumweb` export default filename in `PdfChrome_iOS.exportVellumweb` is
   `"\(slugifiedTitle()).vellumweb"` — same as main's `ToolbarView.exportVellumweb`. (Both are the
   lowercase-dashed *slug*, not the raw title; that is intentional parity, not a regression.)
3. The `.vellum` bundle's web `documentFile` is likewise `"\(slugifiedTitle()).vellumweb"`
   (Step 7's `buildBundle`), so a bundle imported on a Mac produces the same name.

The only delta-side change to this area is `WebLibrary.setTitle(rawUrl:title:)` (session-less
rename from the Home screen) — that belongs to the packet 3, not here.

---

## 3. `project.yml` / `Info-iOS.plist` / entitlements

### `project.yml` — **no change required.**

**[SKIP — packet 9 owns.]** Packet 9 is the sole editor of `project.yml` (packet 10 §2.2/§2.3);
confirmed here since this packet needs no hunk in it anyway.

- `Vellum/Services/VellumBundle.swift` and the new `Vellum/Platform/iOS/BundleImportPrompts_iOS.swift`
  are picked up automatically: the `Vellum` target's `sources: - path: Vellum` is a recursive
  directory reference with only `Resources/Info.plist`, `Resources/Info-iOS.plist` and
  `Resources/katex` excluded.
- `Tests/VellumBundleTests.swift` is picked up by `VellumTests`' `sources: - path: Tests`.
- `INFOPLIST_FILE: Vellum/Resources/Info-iOS.plist` is already set, `GENERATE_INFOPLIST_FILE: "NO"`.
- Main's `project.yml` diff in this range is entirely the macOS `VellumUITests` target,
  `CODE_SIGN_IDENTITY: "Apple Development"` + `DEVELOPMENT_TEAM: 9DCG97VASG` (the iPad project
  already has automatic signing with that team), warnings-as-errors, and the `UITesting`
  configuration. None of it belongs to this packet.

Re-run `xcodegen generate` after adding files anyway, per the project's normal workflow.

### `Vellum/Resources/Info-iOS.plist` — **required changes**

**Ownership (packet 10 §2.2).** Packet 9 owns `Info-iOS.plist` and is the one who applies the two
edits below; packet 2 no longer copies `Vellum/Resources/Info.plist` (see §1 — re-tagged
`[SKIP — packet 9 owns Info-iOS.plist]`). What follows is the specification packet 2 hands to
packet 9, not an edit packet 2 makes itself.

Two edits. Both are additive except the UTI rename in (a).

**(a) Rename the web-archive UTI to match the Mac.** The iPad currently exports
`com.vellum.vellumweb`; main exports `com.vellum.webarchive`. Nothing in the iPad Swift sources or
any persisted file references the identifier (verified: `grep -rn 'com\.vellum' Vellum Tests project.yml`
matches only `Info-iOS.plist`, `Info.plist`, `TabDrag.swift`'s `com.vellum.tab`, `KeychainStore`'s
`com.vellum.ai` service name, and comments) — the binding that matters is the filename extension.
Align on `com.vellum.webarchive` so a `.vellumweb` moved between the Mac and the iPad resolves to
one declared type rather than two competing ones.

*Caveat:* on a device with the old build installed, LaunchServices keeps the stale
`com.vellum.vellumweb` registration until the app is deleted and reinstalled. Delete the app from
the simulator/device before verifying the Files-app open path.

**(b) Add the `Vellum Bundle` document type + exported UTI, and make the existing web-archive UTI
conform to `public.zip-archive` like main's.**

Replace the `CFBundleDocumentTypes` array with:

```xml
	<key>CFBundleDocumentTypes</key>
	<array>
		<dict>
			<key>CFBundleTypeName</key>
			<string>PDF Document</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Alternate</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.adobe.pdf</string>
			</array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Vellum Web Archive</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.vellum.webarchive</string>
			</array>
		</dict>
		<dict>
			<key>CFBundleTypeName</key>
			<string>Vellum Bundle</string>
			<key>CFBundleTypeRole</key>
			<string>Editor</string>
			<key>LSHandlerRank</key>
			<string>Owner</string>
			<key>LSItemContentTypes</key>
			<array>
				<string>com.vellum.bundle</string>
			</array>
		</dict>
	</array>
```

(The iPad's current entries lack `CFBundleTypeRole`; main sets `Editor` on all three. Add it — it
is what makes the type appear in Files' "Open in" list rather than only in a viewer role.)

And in `UTExportedTypeDeclarations`, replace the `com.vellum.vellumweb` dict with these two,
keeping the existing `com.vellum.tab` dict untouched (it backs the iPad tab-drag payload):

```xml
		<dict>
			<key>UTTypeIdentifier</key>
			<string>com.vellum.webarchive</string>
			<key>UTTypeDescription</key>
			<string>Vellum Web Archive</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
				<string>public.zip-archive</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>vellumweb</string>
				</array>
			</dict>
		</dict>
		<dict>
			<key>UTTypeIdentifier</key>
			<string>com.vellum.bundle</string>
			<key>UTTypeDescription</key>
			<string>Vellum Bundle</string>
			<key>UTTypeConformsTo</key>
			<array>
				<string>public.data</string>
				<string>public.zip-archive</string>
			</array>
			<key>UTTypeTagSpecification</key>
			<dict>
				<key>public.filename-extension</key>
				<array>
					<string>vellum</string>
				</array>
			</dict>
		</dict>
```

**Already correct on the iPad, leave alone:**
`LSSupportsOpeningDocumentsInPlace = true` (required for `.onOpenURL` to deliver in-place
security-scoped URLs from Files), `UIFileSharingEnabled = true` (lets the user see and manage the
imported library in Files), `UISupportsDocumentBrowser = false`,
`UIApplicationSceneManifest / UIApplicationSupportsMultipleScenes = false`.

Also verify `NSMicrophoneUsageDescription` / `NSSpeechRecognitionUsageDescription` are absent from
`Info-iOS.plist` (main deletes both from `Info.plist` in the same diff) — the iPad copy never had
them, so this is a check for packet 9 to make while applying (a)/(b) above, not a copy step (packet
2 no longer copies `Vellum/Resources/Info.plist`; voice/TTS stays removed either way).

### Entitlements — **no change.**

`.vellum`/`.vellumweb` handling needs no capability. The iPad target deliberately has no
`CODE_SIGN_ENTITLEMENTS` (the iCloud entitlement is commented out in `project.yml` because the
Personal team can't provision it) — **do not add one**; nothing in this packet requires iCloud,
App Groups, or a document-browser entitlement. `UIFileSharingEnabled` +
`LSSupportsOpeningDocumentsInPlace` are Info.plist keys, not entitlements.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.** Everything in this section is
> the adaptation list packet 9 applies — do not create or modify these files yourself.

### `Tests/VellumBundleTests.swift` [MERGE — copy + 3 adaptations]

**Source:** `/Users/ayushdeolasee/Developer/Vellum/main/Tests/VellumBundleTests.swift` (632 lines,
XCTest, `@MainActor final class VellumBundleTests: XCTestCase`).
**Dest:** `/Users/ayushdeolasee/Developer/Vellum/ipad-app/Tests/VellumBundleTests.swift`.

The iPad test suite is XCTest throughout (`Tests/WebLibraryStorageTests.swift`,
`Tests/PdfPersistenceTests.swift`, …), so no Swift Testing conversion is needed.

**Cases it covers (all must survive):**

| Test | What it proves |
|---|---|
| `testExportImportRoundTripInstallsSidecarUnderDocId` | Full write→read→install: relative `attachments/<id>.png` refs intact, attachment bytes copied, conversation id-unioned and sorted (`["local-1","imp-1","imp-2"]`). |
| `testUnstampedPdfImportStampsManifestDocId` | An unstamped imported PDF is stamped with `manifest.docId` so its reopen `DocumentIdentity.storageKey` matches the sidecar. |
| `testHashTamperOnDocumentThrows` / `testHashTamperOnAttachmentThrows` | sha256 integrity checks. |
| `testZipSlipRawEntryRejected` | A physical `../evil` entry is rejected (error text contains "unsafe"). |
| `testZipSlipAttachmentPathRejected` | A manifest-declared `attachments/../evil` path is rejected. |
| `testConversationsExcludedByDefault` | `conversations: nil` → no hash, no entry, nothing installed. |
| `testImportedConversationReferencesAreCappedLikeAPersistedOne` | Imported references are truncated/stripped like `AiPersistence.limit` does on save. |
| `testImportKeepsLocalMessagesAroundAnUndecodableOne` | One bad local record costs that record, not the conversation. |
| `testImportRefusesToOverwriteAnUndecodableLocalConversation` | A wholly-undecodable local file is left byte-identical and the merge throws. |
| `testVersionTwoRejected` | Error text contains "please update Vellum". |
| `testScratchpadConflictKeepLocal` / `…UseImported` | The merge prompt's two outcomes. |
| `testImportedConversationCapsNestedToolSummaries` | Hostile tool-summary counts/lengths/page numbers are capped. |
| `testAttachmentNeverOverwritesExistingId` | Local attachment id wins. |
| `testTraversalManifestDocIdRejected` | Manifest `doc_id = "../../../../etc/passwd"` → "invalid document id". |
| `testDocumentDirNeutralizesTraversalKey` | `DocumentDataStore.documentDir` maps a non-canonical key to its sha256 folder, still a direct child of the root. |
| `testEmbeddedTraversalDocIdReadsAsNil` | A PDF stamped with `../../evil` reads back nil. |
| `testImportCoreWritesDocumentAndInstallsSidecar` | The panel-free import core end-to-end. |
| `testImportCoreAtomicallyReplacesExistingDestination` | temp+rename over an existing file, no `.….import-` sibling left behind. |
| `testInstallSidecarSurfacesFailedAttachments` | A 0o555 attachments dir yields `["img1.png"]`, not a silent success. |
| `testEntryCountCapRejected` | 4098 entries → "too many entries" before any payload is read. |

**iOS adaptations:**

1. **`makeRealPdfData()`** uses `CGDataConsumer` / `CGContext(consumer:mediaBox:nil)` /
   `beginPDFPage` / `closePDF` — all available on iOS via `import CoreGraphics` (already the second
   import). **No change.** Verify `PdfMetadata.stampDocumentId` round-trips through `PDFDocument`
   on iOS the same way (PDFKit is available on iOS 11+).

2. **`testInstallSidecarSurfacesFailedAttachments`** sets `.posixPermissions: 0o555` on a directory
   inside the temp dir. This works on the iOS simulator and on device (the app never runs as root),
   so keep it. If it proves flaky on device, replace the read-only-directory trick with
   pre-creating a **file** at the attachments-dir path so `createDirectory` fails — but prefer the
   original.

3. **Tests blocked on the packet 5.** `testImportedConversationReferencesAreCappedLikeAPersistedOne`
   and `testImportedConversationCapsNestedToolSummaries` need `AiMessage.references`,
   `AiMessage.toolSummaries`, `AiReference: Codable`, `AiToolSummary`, and
   `AiPersistence.maxReferenceCharacters` / `maxToolSummariesPerMessage` /
   `maxToolSummaryTitleCharacters` / `maxToolSourcesPerSummary` /
   `maxToolSourceExcerptCharacters`. **None exist on the iPad today** — the iPad's `AiMessage`
   (`Vellum/Stores/AiStore.swift:54`) is `{ id, role, content, createdAt, usage }` and its
   `AiReference` (line 81) is not `Codable`. If the packet 5 has not landed, comment these two
   tests out with a `// TODO(parity-129, packet 5): …` marker and re-enable them; **do not** weaken
   `VellumBundle.mergeConversations` to compile without `limitedMessages` — the cap is the security
   property the tests assert.

**New iPad-only tests to add** (they cover the pieces this packet rebuilt rather than copied):

```swift
    /// The bundle type is offered by the picker, so a `.vellum` in Files is
    /// tappable and a share-sheet "Open in Vellum" is offered.
    func testOpenableTypesIncludesBundleAndWebArchive()

    /// `.vellum` is a container, not a document: it is staged into tmp/ so it
    /// never litters the visible library, while a PDF still lands there.
    func testImportPickedStagesBundlesInTemporaryDirectory()

    /// Re-importing an updated bundle for a document already in the library
    /// overwrites that copy instead of creating "paper 2.pdf"; a DIFFERENT
    /// document with the same filename gets a unique name.
    func testBundleDestinationReusesMatchingDocIdAndUniquifiesOtherwise()

    /// The whole iOS import minus the alert: read → write to the library →
    /// resolve the key → install, with the conflict resolver pinned.
    func testTwoPhaseImportMatchesImportVellumBundleCore()
```

For the last one, drive `AppStore.writeImportedDocument` + `AppStore.finishImportedBundle` directly
and assert the result equals what `AppStore.importVellumBundleCore` produces — that is what keeps
the split from drifting from main.

**Test harness note:** every case relies on `DocumentDataStore.rootDirectoryOverride` being a
`nonisolated(unsafe) static var URL?` set in `setUp` and cleared in `tearDown` (main
`DocumentDataStore.swift:18`). Packet 1 must ship that seam.

---

## 5. Risks & cross-packet dependencies

### Hard blockers — this packet cannot compile until these land

| Needed symbol | Owner | Used by |
|---|---|---|
| `DocumentIdentity` (`storageKey(for:)`, `byteHash(_:)`, `isCanonicalKey(_:)`, `sha256Hex(_:)`) | **Packet 1** | `VellumBundle.read` doc_id gate; `buildBundle` pull key; `PaneView_iOS` observer; tests |
| `DocumentDataStore` (`rootDirectoryOverride`, `documentDir`, `attachmentsDir`, `touch(document:force:)`, `scratchpadExists`, `loadScratchpad`, `saveScratchpad`, `conversationsExist`, `loadConversationsData`, `saveConversationsData`) | **Packet 1** | `VellumBundle.installSidecar`; import core; export `buildBundle`; every test |
| `DocumentInfo.docId` | **Packet 1** | key resolution, `touch` |
| `PdfMetadata.documentId(atPath:)`, `PdfMetadata.stampDocumentId(atPath:id:)`, `PdfDocumentLoader.loadRaw(path:)` | **Packet 1** | import key resolution; `DocumentImport.bundleDestination`; 3 tests |
| `SessionService.ensureDocumentId(sessionId:)` + `AppStore.syncDocumentId(sessionId:)` (and the `PdfFileGate`-preserving backend implementation) | **Packet 1** | `buildBundle`'s durable manifest id |
| `AiPersistence.decodeMessages(_:)`, `limitedMessages(_:)`, `invalidateCachedConversation(forKey:)`, and the `DocumentDataStore`-backed conversation storage | **packet 5** | `VellumBundle.mergeConversations`; `finishImportedBundle`; `PaneView_iOS` observer |
| `AiMessage.references` / `.toolSummaries`, `AiToolSummary`, `AiPersistence.max*` caps | **packet 5** | 2 of the 20 ported tests (see §4 adaptation 3) |
| `ScratchpadPersistence.save(forKey:schemeText:)` / `load(forKey:)` (the `DocumentDataStore`-backed shape) | **packets 6 and 1** | `ScratchpadStore.restore` after Step 3's split |

**Recommended sequencing:** packet 1 (identity + DocumentDataStore) → packet 5 (AiPersistence
per-document conversations) → this packet. Steps 0–2 (MiniZip counters, `VellumBundle.swift`,
the notification name) can land ahead of that as long as the build is allowed to be red, but the
suite won't be green.

### Risks

1. **Codec byte-compatibility.** `Manifest`'s snake_case `CodingKeys`, the `manifest.json` /
   `document/<file>` / `scratchpad.md` / `attachments/<id>` / `conversations.json` entry names, the
   `stored: true` document entry, the `formatVersion = 1` marker, and every sha256 must stay
   identical or Mac↔iPad sharing breaks silently in *one* direction (a hash mismatch surfaces as
   "corrupted file?", a key mismatch surfaces as a document with no notes). Copy the file, don't
   retype it. Add a fixture round-trip check by exporting a bundle from the Mac build and importing
   it on the iPad, and vice versa.

2. **The synchronous conflict resolver.** This is the single real API impedance between AppKit and
   UIKit here. The two-phase split (Step 4b) is what lets `VellumBundle.swift` stay verbatim. If an
   implementer instead makes `installSidecar`'s resolver `async`, `VellumBundle.swift` diverges from
   main permanently and every future re-port of it becomes a hand-merge. **Prefer the split.**

3. **`resolveConflict` fail-safe.** If the alert can't be presented (no key window during a cold
   `.onOpenURL`), the resolver must return `.keepLocal`. Returning `.useImported` would destroy the
   user's own notes with no undo.

4. **UTI rename `com.vellum.vellumweb` → `com.vellum.webarchive`.** Safe in source (no Swift
   reference), but stale LaunchServices state on an already-installed build will keep the old
   registration until reinstall. Delete-and-reinstall before verifying, and mention it in the PR.

5. **Import destination policy differs from macOS by design.** The Mac asks with an `NSSavePanel`;
   the iPad writes into `DocumentImport.libraryDirectory`. Consequences to call out in the PR:
   re-importing the same bundle updates the existing library copy when the doc ids match, and
   creates a `"<name> 2.pdf"` otherwise. Web bundles also leave a `.vellumweb` in the library
   (the WebLibrary owns the real storage) — acceptable, and visible/deletable in Files thanks to
   `UIFileSharingEnabled`.

6. **`.onOpenURL` cold-launch ordering.** If the notification is posted before `ContentView_iOS`
   subscribes, the open is dropped. Verify on device; buffer only if needed (Step 6).

7. **Contended files.** `AppStore.swift`, `ScratchpadStore.swift`, `SessionService.swift`,
   `WebArchive.swift`, and the four macOS-gated REBUILD sources are touched by several packets in
   this parity effort. Apply only the hunks listed here, and re-read the file before editing rather
   than assuming its pre-delta shape.

8. **iPad-only behavior that must survive every edit in this packet:** the `.vellumOpenFile`
   payload-free contract for ⌘O and the pane "Open File…" button (Step 6 extends it, never replaces
   it); `PdfToolbar_iOS`'s width-tier pod folding (`showZoomPod` / `showPageChevrons` /
   `showActionsPod`) when adding the new menu item; `PaneView_iOS`'s ink registry
   register/flush/remove lifecycle; `DocumentImport`'s security-scoped copy semantics and
   `resolveExistingPath` container-UUID fallback; and `CreateAnnotationInput.createdAt` in
   `AppStore`.

9. **No `Task.detached` regressions in the export path.** `buildBundle` reads the whole PDF into
   memory (`readPdfBytes`) and hashes it. On a large PDF this must not run on the main actor —
   `sessions.readPdfBytes` is already an actor hop, but `VellumBundle.write`'s `sha256Hex` +
   `MiniZip.write` are synchronous. `startBundleExport` runs them inside a `Task`, which on a
   `@MainActor` view inherits main-actor isolation — **wrap `VellumBundle.write` in a
   `Task.detached(priority: .userInitiated)`** in the iOS `buildBundle`, or the export will freeze
   the UI for the duration of a multi-hundred-MB zip. (Main has the same latent issue on a machine
   where it is less noticeable; this is a deliberate, documented iPad improvement, not a divergence
   in behavior.)
