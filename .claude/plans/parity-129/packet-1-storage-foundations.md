# Packet 1 — Storage foundations (parity phase 1, issue #130)

Delta source: `/Users/ayushdeolasee/Developer/Vellum/main`, range `a42705d1~1..7742a895`.
Target: `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`, iOS-only, xcodegen from `project.yml`).

Read every diff with:
`git -C /Users/ayushdeolasee/Developer/Vellum/main diff a42705d1~1..7742a895 -- <path>`
Read main's final file with:
`git -C /Users/ayushdeolasee/Developer/Vellum/main show 7742a895:<path>` (or just open the file — main's worktree is at that commit).

Useful fact established while writing this packet: several files in the iPad worktree are still **byte-identical to `a42705d1~1`** (main's pre-delta base). Those can take main's file wholesale. Verified identical: `Vellum/Services/RecentFilesService.swift`, `Vellum/Services/WorkspaceService.swift`, `Vellum/Services/DocumentSessionManager.swift`, `Vellum/Services/Pdf/PdfMetadata.swift`. Verified **diverged**: `SessionService.swift`, `Models.swift`, `PdfSessionBackend.swift`, `AppStore.swift`, `WorkspaceStore.swift`, `WebStorage.swift`, `WebLibrary.swift`, `StorageLocationChoiceSheet.swift`, `SettingsView.swift`.

---

## 1. Delta files claimed

### New services / views (adopt from main)

```
Vellum/Services/TestEnvironment.swift                          [VERBATIM]
Vellum/Services/AppDefaults.swift                              [VERBATIM]
Vellum/Services/DocumentIdentity.swift                         [VERBATIM]
Vellum/Services/DocumentDataStore.swift                        [VERBATIM]
Vellum/Services/StorageHousekeeping.swift                      [VERBATIM]
Vellum/Services/SecurityScopedBookmark.swift                   [VERBATIM]  (doc comment rewritten for iOS; code unchanged)
Vellum/Services/Pdf/PdfDocIdRegistry.swift                     [VERBATIM]  (+ two iPad-only additions, see §2.9)
Vellum/Views/Settings/StorageInventory.swift                   [VERBATIM]
Vellum/Views/Settings/StorageRelocationInventoryReloadPolicy.swift [VERBATIM]
Vellum/Views/Settings/StorageSettingsTab.swift                 [REBUILD]   (AppKit panels + NSWorkspace + macOS Form sizing)
```

### Existing files (hand-merge)

```
Vellum/Services/RecentFilesService.swift                       [VERBATIM]  (iPad copy == main's base; take main's file whole)
Vellum/Services/WorkspaceService.swift                         [VERBATIM]  (same; diff is only the AppDefaults swap)
Vellum/Services/DocumentSessionManager.swift                   [VERBATIM]  (same; diff is only ensureDocumentId)
Vellum/Services/Pdf/PdfMetadata.swift                          [MERGE]     (iPad copy == base, but stampDocumentId needs an iPadOS-26 guard)
Vellum/Services/SessionService.swift                           [MERGE]
Vellum/Services/Web/WebSessionBackend.swift                    [MERGE]
Vellum/Services/Web/WebStorage.swift                           [MERGE]
Vellum/Services/Web/WebLibrary.swift                           [MERGE]     (only totalRecordBytes() is mine)
Vellum/Services/Pdf/PdfSessionBackend.swift                    [MERGE]     (graft PdfDocumentIO's stamping onto PdfFileGate)
Vellum/Services/Ai/PageTextCache.swift                         [MERGE]
Vellum/Services/Ai/PageTextPersister.swift                     [MERGE]
Vellum/Models/Models.swift                                     [MERGE]     (shared file — only my hunks; preserve CreateAnnotationInput.createdAt)
Vellum/Stores/AppStore.swift                                   [MERGE]     (shared file — only my hunks)
Vellum/Stores/AnnotationStore.swift                            [MERGE]     (shared file — one hunk)
Vellum/Views/Settings/StorageLocationChoiceSheet.swift         [MERGE]
Vellum/Views/Settings/SettingsView.swift                       [MERGE]     (shared file — delete v1 Storage tab, wire v2)
project.yml                                                    [SKIP — hands hunks to packet 9]  (packet 9 is the SOLE editor of project.yml, per packet 10 §2.2; this packet needs no edit anyway — see §3)
```

### Tests claimed

```
Tests/ScratchDefaultsTrait.swift                               [VERBATIM]
Tests/AppDefaultsGuardTests.swift                              [VERBATIM]
Tests/DocumentIdentityTests.swift                              [MERGE]     (adapts to PdfFileGate stamping)
Tests/DocumentDataStoreTests.swift                             [MERGE]     (needs ScratchpadPersistence v2 — see §5)
Tests/DocumentsRelocationTests.swift                           [VERBATIM]
Tests/RecentsResolveTests.swift                                [VERBATIM]
Tests/StorageManagementTests.swift                             [MERGE]     (drop the two Integrations tests)
Tests/PageTextCacheTests.swift                                 [MERGE]
```

### Explicitly NOT mine (from delta-files.txt)

```
Vellum/App/VellumApp.swift                    [SKIP: macOS-gated dead file on iPad (`#if os(macOS)` line 1). My launch-sweep
                                                     change goes into Vellum/Platform/iOS/VellumApp_iOS.swift instead — see §2.17]
Vellum/Views/PDF/PdfViewerView.swift          [SKIP: macOS-gated dead file. My storage-key wiring goes into
                                                     Vellum/Platform/iOS/PdfViewerView_iOS.swift — see §2.12]
Vellum/Views/Panes/PaneView.swift             [SKIP: macOS-gated dead file. materializeIfNeeded + the two notification
                                                     handlers go into Vellum/Platform/iOS/PaneView_iOS.swift — see §2.20;
                                                     the packet 4 owns the rest of this file]
Vellum/Services/VellumBundle.swift            [SKIP: packet 2. It CONSUMES my DocumentDataStore +
                                                     DocumentIdentity.isCanonicalKey — hard dependency on this packet]
Vellum/Services/DocumentRenameService.swift   [SKIP: packet 3. Consumes DocumentDataStore.setTitle + RecentFilesService.updateTitle,
                                                     both delivered by this packet]
Vellum/Services/Scratchpad/ScratchpadPersistence.swift [SKIP: packet 6. Consumes DocumentDataStore + AppDefaults;
                                                     owes me listLegacyEntries()/removeLegacyEntry() — see §5]
Vellum/Services/Ai/AiPersistence.swift        [SKIP: packet 5. Same relationship — owes me listLegacyEntries()/
                                                     removeLegacyEntry()/invalidateCachedConversation(forKey:)]
Vellum/Stores/ScratchpadStore.swift           [SKIP: packet 6]
Vellum/Stores/AiStore.swift                   [SKIP: packet 5]
Vellum/Stores/WorkspaceStore.swift            [SKIP: packet 4]
Vellum/Services/Search/*                      [SKIP: packet 3. LibraryDocumentsSearchProvider consumes
                                                     DocumentDataStore.listDocumentMetas(), which I deliver]
Vellum/Services/Integrations/*, Vellum/Stores/IntegrationsStore.swift,
Vellum/Views/Settings/{Connect,Disconnect}ServiceSheet.swift,
Vellum/Views/Settings/IntegrationsSettingsTab.swift             [SKIP: packet 8]
Vellum/App/UITestLaunchConfiguration.swift, Vellum/App/SheetPresenceMonitor.swift,
UITests/*, Vellum.xcodeproj/*, .github/workflows/claude.yml     [SKIP: macOS UI-test infrastructure; the iPad project has no
                                                                       UI-test target and its .xcodeproj is xcodegen output]
Vellum/Services/Pdf/{PdfAtomicWriter,PdfBookmarks,PdfAnnotationCodec}.swift [SKIP: editable-bookmark-titles packet]
Vellum/Services/KeychainStore.swift           [SKIP: packet 9 owns Vellum/Services/KeychainStore.swift AND
                                                     Tests/KeychainStoreTests.swift outright (packet 10 §2.1) —
                                                     but it must adopt TestEnvironment.isHostedTestProcess,
                                                     which I deliver (main's KeychainStore.swift line 34).
                                                     Packet 8's D1 stopgap keychain shim must NOT ship on top
                                                     of packet 9's KeychainStore (packet 10 §2.1)]
Vellum/Resources/Info.plist                   [SKIP: macOS plist; the iPad uses Info-iOS.plist — see §3]
plans/*, CHANGELOG.md, AGENTS.md, CLAUDE.md, .gitignore        [SKIP: docs/plans]
everything else in delta-files.txt                             [SKIP: other packets]
```

---

## 2. Port order & instructions

Do them in this order — each step compiles on top of the previous ones.

---

### 2.1 `Vellum/Services/TestEnvironment.swift` — VERBATIM

`cp` main's file. 26 lines, pure Foundation, no platform API. No changes.

Note for the packet 9: main's `KeychainStore.usesInMemoryStore` becomes
`UITestLaunchConfiguration.isEnabled || TestEnvironment.isHostedTestProcess`. The iPad has no
`UITestLaunchConfiguration`, so if that packet lands, it should use `TestEnvironment.isHostedTestProcess` alone.

---

### 2.2 `Vellum/Services/AppDefaults.swift` — VERBATIM

`cp` main's file. Pure Foundation (`UserDefaults`, `@TaskLocal`). No changes.

Two things that matter and must NOT be "simplified" away:
- `base` is a lazily-initialised `nonisolated(unsafe) static let` that calls `removePersistentDomain(forName:)` on first access. Per-process suite name is intentionally **fixed** (`com.vellum.tests.defaults`) in main's final version — do not re-introduce a per-process UUID here; the review history went back and forth on this and the committed answer is the fixed name plus the first-access wipe.
- `isHostedInTestBundle` is a private copy of the same four probes as `TestEnvironment.isHostedTestProcess`. Main deliberately keeps it separate (narrower than KeychainStore's, which also counts `--ui-testing` launches). The iPad has no UITesting configuration at all, so you may either keep main's private copy verbatim (preferred: zero divergence) or replace the body with `TestEnvironment.isHostedTestProcess`. **Keep main's copy verbatim** — divergence here is what future merges trip on.

The iPad's `VellumTests` target is hosted (`TEST_HOST: $(BUILT_PRODUCTS_DIR)/Vellum.app/Vellum` in `project.yml`), so the guard is live and load-bearing on iPad exactly as on macOS.

---

### 2.3 `Vellum/Services/WorkspaceService.swift` — VERBATIM

iPad copy is byte-identical to main's base. Overwrite with main's file. The whole diff is:
- new `private static var defaults: UserDefaults { AppDefaults.current }`
- `save` / `load` / `clear` read `defaults` instead of `UserDefaults.standard`.

`storageKey` stays `"vellum.workspace"` — **byte-compatible defaults key, do not rename.**

---

### 2.4 `Vellum/Services/DocumentIdentity.swift` — VERBATIM

`cp` main's file. `import Foundation` + `import CryptoKit`, both available on iOS. No changes.

Contract other packets rely on: `sha256Hex` is bare lowercase hex of the full SHA-256, byte-identical to
`PageTextCache.pathKey` and `WebLibrary.pageKey`. Do not change the encoding.

---

### 2.5 `Vellum/Models/Models.swift` — MERGE (shared file)

**Edit order (packet 10 §2.3):** packets 1, 4, 6 all merge into this file — order **1 → 4 → 6** (packet
1 = `DocumentInfo.docId`; packet 4 = `PdfTab` find/region fields; packet 6 = pin fields). Packet 1 must
preserve `CreateAnnotationInput.createdAt` regardless of when it lands.

The iPad's `Models.swift` differs from main's base in exactly one place: `CreateAnnotationInput` has an extra
`var createdAt: String?` plus a reworded doc comment (iPad-only, protects optimistic ink/annotation creation).
**Preserve `createdAt` and its comment.** Do not take main's `CreateAnnotationInput` doc comment.

Apply ONLY these hunks from main's diff (the rest of the Models diff — `Annotation.isPinned` /
`sortedForDisplay`, `UpdateAnnotationInput.isPinned`, `RegionCaptureTarget`, the new `PdfTab` fields — belongs
to packets 6 (annotation pinning), 4 (find bar) and 5 (region capture); leave them to those packets):

1. **`DocumentInfo.docId`**

```swift
    /// Stable cross-session document identity. PDFs: the /VellumDocId UUID
    /// stamped into the Info dictionary, nil until a mutation (or
    /// ensureDocumentId) lazily stamps it. Web docs: the sha256 URL hash, set at
    /// open. Class-B/C stores resolve their storage key from this via
    /// DocumentIdentity.
    var docId: String? = nil
```

2. **`DocumentInfo.bookmarkData`** — main's comment says "defense-in-depth alongside stable code signing". On
iPad it is NOT defense-in-depth; the app IS sandboxed and this is the only durable way to regain access to a
picked file. Rewrite the comment accordingly, keep the property and coding key:

```swift
    /// Security-scoped bookmark for `pdfPath` (PDFs only), minted the moment the
    /// document is opened while read access is guaranteed. On iOS this is
    /// MANDATORY, not defense-in-depth: the app is sandboxed, a
    /// UIDocumentPicker URL's access does not survive relaunch, and the app
    /// container's UUID changes across reinstalls — so a saved raw path can stop
    /// resolving even for a file that is still there. Optional so data written
    /// before this field existed (and web docs, which never carry one) decodes
    /// cleanly; readers must fall back to `pdfPath` when nil.
    var bookmarkData: Data? = nil
```

3. **`DocumentInfo.CodingKeys`**: add `case docId = "doc_id"` and `case bookmarkData = "bookmark_data"`.
   **snake_case — byte-compatible with the persisted workspace JSON. Do not change.**

4. **`RecentDocument.docId`** + `case docId = "doc_id"` + the memberwise-init parameter
   (`docId: String? = nil`, defaulted so existing call sites compile) + the
   `init(from decoder:)` line `docId = try container.decodeIfPresent(String.self, forKey: .docId)`.
   The custom decoder is what makes legacy recents (no `doc_id`) decode cleanly — keep it.

---

### 2.6 `Vellum/Services/Web/WebStorage.swift` — MERGE

The iPad file has already diverged heavily (iOS ubiquity container, `customBookmarkKey`, `resolveICloudRoot()`,
`resolveBookmark`, `accessedCustomURLs`). **Preserve every one of those.** Do not import any of main's
`icloudVellumRoot` body (main resolves `~/Library/Mobile Documents/com~apple~CloudDocs`; the iPad's ubiquity-container
path plus graceful `.local` degradation is the standing decision).

Apply these four changes:

**(a) `WebStorageLayout.documentsDir`.** Add the stored property between `archivesDir` and `pretty`:

```swift
    /// Where `documents/<key>/` folders (scratchpad, conversations, meta,
    /// attachments — class-B user data) live. Mirrors the records rule: in
    /// iCloud mode it sits next to the records under the synced root, so notes
    /// and AI conversations sync too; in custom mode it stays LOCAL (custom
    /// mode's meaning is "my folder holds the visible web pages" — records and
    /// documents stay in the app container); in local mode it is the default
    /// app-container location.
    var documentsDir: URL
```

Add the derivation helper and update both factories (iPad `WebStorage.swift` lines ~230 and ~236):

```swift
    static func localDocumentsDir(storeDir: URL) -> URL {
        storeDir.deletingLastPathComponent().appendingPathComponent("documents", isDirectory: true)
    }

    static func local(storeDir: URL) -> WebStorageLayout {
        WebStorageLayout(
            recordsDir: storeDir, archivesDir: storeDir,
            documentsDir: localDocumentsDir(storeDir: storeDir),
            pretty: false, indexPath: nil)
    }
```

and inside `pretty(root:recordsInRoot:localStoreDir:)`:

```swift
            documentsDir: recordsInRoot
                ? internalDir.appendingPathComponent("documents", isDirectory: true)
                : localDocumentsDir(storeDir: localStoreDir),
```

`localDocumentsDir` derives from `storeDir` (the sibling of `web/`), which means the existing
`WebLibrary.storeDirOverride` test seam covers it and production lands on `<appData>/documents` — the same
path a fresh install would have used anyway.

**(b) `WebICloud.materializeOverride`.** Add the test seam and the one-line consult in `materialize`:

```swift
    nonisolated(unsafe) static var materializeOverride: ((URL) -> Bool)?
```
and in `materialize(at:timeout:)`, immediately after the `if fm.fileExists(atPath: url.path) { return true }` line:
```swift
        if let materializeOverride { return materializeOverride(url) }
```
(`DocumentsRelocationTests` cannot drive real iCloud downloads; without this its evicted-placeholder cases block
for the whole timeout.)

**(c) `WebStorageMigrator.relocate`** — add the documents move AFTER the records/archives loops and BEFORE the
`if clean, source.pretty { cleanUpEmptyPrettyDirs(of: source) }` line. Copy main's hunk exactly (it is pure
FileManager):

```swift
        if source.documentsDir != dest.documentsDir {
            let fm2 = FileManager.default
            if let names = try? fm2.contentsOfDirectory(atPath: source.documentsDir.path) {
                for name in names where name != ".DS_Store" {
                    let src = source.documentsDir.appendingPathComponent(name, isDirectory: true)
                    var isDir: ObjCBool = false
                    guard fm2.fileExists(atPath: src.path, isDirectory: &isDir), isDir.boolValue
                    else { continue }
                    let dst = dest.documentsDir.appendingPathComponent(name, isDirectory: true)
                    if !DocumentDataStore.moveOrMergeDirectory(from: src, into: dst) { clean = false }
                }
            }
        }
```

The `clean = false` on a skipped folder is what keeps the pending-relocation marker so the next launch sweep
retries — do not "simplify" it to ignore the return value.

**(d) `cleanUpEmptyPrettyDirs`** — add the documents dir as a removal candidate, guarded so a custom layout's
(shared, local) documents dir is never removed:

```swift
        if let internalDir = layout.indexPath?.deletingLastPathComponent(),
           layout.documentsDir.deletingLastPathComponent().standardizedFileURL
            == internalDir.standardizedFileURL {
            dirs.append(layout.documentsDir)
        }
```
(insert before the existing `if let internalDir = layout.indexPath?...  { dirs.append(internalDir) }`, and
update that line's comment from "the two above" to "the others above").

**Build break to expect:** any other `WebStorageLayout(...)` memberwise call. Grep confirmed only the two
factories construct it, so there should be none — but re-grep after the edit.

---

### 2.7 `Vellum/Services/DocumentDataStore.swift` — VERBATIM

`cp` main's file (657 lines). Pure Foundation. It compiles on iOS once §2.6 has landed, because it depends on:
- `WebLibrary.activeLayout.documentsDir` (§2.6a) ✅ present
- `WebStorageLayout.local(storeDir:).documentsDir` (§2.6a) ✅
- `WebICloud.placeholderURL / materialize / itemExists / requestDownload / removeItem / size` ✅ all already exist in the iPad's `WebStorage.swift` (verified at lines 382, 389, 399, 414, 421, 427)
- `WebLibrary.jsonEncoderPretty`, `WebLibrary.rfc3339Now()` ✅ exist
- `SessionServiceError.io` ✅ exists
- `DocumentKind` ✅ exists

Things future reviewers will want to "clean up" — do not:
- `documentDir(forKey:)`'s canonical-key guard (`isCanonicalKey ? key : sha256Hex(key)`) is a **path-traversal
  backstop** for attacker-supplied `/VellumDocId` / `.vellum` manifest ids. Keep it.
- `hasDataFiles` treats a top-level `meta.json` as *not* data. That is what makes an emptied document's folder
  get pruned.
- `mergeDirectory` special-cases `meta.json` (destination always wins) — that's how a leftover path-hash folder
  collapses on rekey instead of surviving as a bogus orphan.
- `moveOrMergeDirectory` removes `src` only when EVERY file merged. Partial failure keeps both copies.

On-disk layout produced: `<documentsDir>/<storageKey>/{meta.json, scratchpad.md, conversations.json, attachments/}`.
`meta.json` keys are `version`, `kind`, `title`, `last_known_path`, `last_opened` — **snake_case, byte-compatible.**

---

### 2.8 `Vellum/Services/Web/WebLibrary.swift` — MERGE (one function)

Add only `totalRecordBytes()` (main's diff hunk at the end of the snapshot-storage section):

```swift
    /// Total bytes of every sidecar record file (annotations + reading state).
    /// This is irreplaceable class-B user data — it feeds the Storage pane's
    /// "Your data" tile, never the deletable "Web archives" total.
    static func totalRecordBytes() -> Int64 {
        var total: Int64 = 0
        for file in allRecordFiles() {
            total += WebICloud.size(ofItemAt: file)
        }
        return total
    }
```

Do NOT take from main's `WebLibrary` diff:
- the `UITestLaunchConfiguration.storageRoot` branch in `appDataDir` (no UI-test target on iPad, and the iPad's
  `appDataDir` has its own `#if os(macOS)` fallback logic that must be preserved),
- `setTitle(rawUrl:title:)` (home-screen rename — packet 3),
- the `nonisolated(unsafe)` removals on the encoders/formatter (packet 9; the iPad still needs them
  under its `SWIFT_STRICT_CONCURRENCY: minimal` settings — leave them alone).

---

### 2.9 `Vellum/Services/Pdf/PdfDocIdRegistry.swift` — VERBATIM + two iPad-only additions

`cp` main's file first (48 lines, pure Foundation + `NSLock`).

Then append two things the iPad needs that macOS gets for free from the `PdfDocumentIO` actor's instance state.
Put them in the SAME file so they are discoverable next to the registry they complement:

```swift
extension PdfDocIdRegistry {
    // macOS keeps "this session already knows the file's docId" as the
    // PdfDocumentIO actor's `docId` property. The iPad's write path is a set of
    // `nonisolated static` functions behind PdfFileGate (plus InkDiskWriter,
    // which only ever has a path), so the equivalent fast path lives here —
    // otherwise every single write would pay a CGPDF re-parse just to discover
    // the file is already stamped.
    static func knownStamp(forPath path: String) -> String?
    static func recordStamp(_ id: String, forPath path: String)
}

/// Session-stable page-text cache key per canonical PDF path.
///
/// Resolved ONCE, at open, to `DocumentInfo.docId ?? PageTextCache.pathKey(path)`
/// and deliberately NOT updated by a mid-session /VellumDocId stamp: the cache
/// lookup and the persister keyed the whole session by this value, so every
/// `refreshHash` must agree with them or the next reopen misses. macOS keeps
/// this as `PdfDocumentIO.cacheKey`; the iPad's writers are static, so it lives
/// here.
enum PdfSessionCacheKeys {
    static func register(path: String, key: String)
    /// The registered key, else `PageTextCache.pathKey(path)`.
    static func key(forPath path: String) -> String
    /// Test seam.
    static func reset()
}
```

Implement both with the same `NSLock` + `nonisolated(unsafe)` dictionary idiom the registry already uses.
`PdfDocIdRegistry.reset()` must also clear the `knownStamp` map (tests depend on `reset()` meaning "clean map").

---

### 2.10 `Vellum/Services/Pdf/PdfMetadata.swift` — MERGE

iPad copy is byte-identical to main's base, so main's diff applies cleanly. Take all of it:

- `import PDFKit` at the top.
- `documentInfo(document:path:)` return type becomes a **4-tuple** `(title:pageCount:lastPage:docId:)`.
- new `documentId(_ document: CGPDFDocument) -> String?` — reads `/VellumDocId` and returns it only when
  `DocumentIdentity.isCanonicalKey(raw)` (crafted-PDF traversal guard).
- new `documentId(atPath:) -> String?` — used by recents re-resolution and the Storage pane's Relink verification.
- `setMetadataIncrement(normalizedData:key:value:)` becomes a one-entry wrapper around a new
  `setMetadataIncrement(normalizedData:entries:)` that folds several Info entries into ONE incremental update.
- new `stampDocumentId(atPath:id:)`.

**Two required iPad adaptations:**

**(a) `documentInfo` callers.** Grep for `PdfMetadata.documentInfo(`. The iPad has one call site:
`Vellum/Services/Pdf/PdfSessionBackend.swift` line ~51 inside `PdfSessionBackend.open`. Destructure four values
and pass `docId:` into the `DocumentInfo` (see §2.13).

**(b) `stampDocumentId` must not wipe custom Info keys on iPadOS 26.** Main's body is
`loadForMutation → PDFKit dataRepresentation() → doc_id increment → atomic write`. On iPadOS 26 PDFKit's
serializer **drops custom Info keys** (that is exactly what the iPad's existing `pdfKitDropsCustomKeys` /
`restoreInfoDictionary` machinery exists for), so that round-trip would destroy `/VellumLastPage`,
`/VellumCreatedAt`, etc. Mirror the shape `performSetMetadata` already uses on iPad — try the byte increment on
the ORIGINAL file bytes first, and only fall back to the PDFKit normalize:

```swift
    static func stampDocumentId(atPath path: String, id: String) throws {
        // iPadOS 26's PDFKit serializer drops custom Info keys, so a
        // normalize-then-stamp round trip would erase /VellumLastPage and
        // friends. The increment is a pure byte append, so try it against the
        // file's own bytes first; only fall back to PDFKit normalization when
        // the file's xref shape defeats ClassicPdfFile.
        if let original = try? PdfDocumentLoader.readFile(path),
           let stamped = try? setMetadataIncrement(
               normalizedData: original, entries: [(key: "doc_id", value: id)]) {
            try PdfAtomicWriter.save(stamped, toPath: path)
            return
        }
        let (document, _) = try PdfDocumentLoader.loadForMutation(path: path)
        guard let normalized = document.dataRepresentation() else {
            throw SessionServiceError.io("Failed to stamp document id: PDFKit produced no data")
        }
        let stamped = try setMetadataIncrement(
            normalizedData: normalized, entries: [(key: "doc_id", value: id)])
        try PdfAtomicWriter.save(stamped, toPath: path)
    }
```

Keep main's `default:` branch mapping in `setMetadataIncrement`: key `"doc_id"` → Info key
`/VellumDocId` via `metadataKeySuffix` PascalCasing. **`/Vellum*` PDF key names are the persistence format —
do not rename.**

---

### 2.11 `Vellum/Services/RecentFilesService.swift` — VERBATIM

iPad copy is byte-identical to main's base → **overwrite with main's file wholesale.** Pure Foundation.
Landing it whole also hands the recents-undo and rename work in packet 3 their helpers with zero conflict.

What lands: the `AppDefaults` swap, `record(_:)` now carrying `docId: document.docId`, `remove(paths:)`,
`restore(_:)`, `removeIfUnchanged(_:)`, `updateTitle(path:title:)`, and `resolvedPath(for:)`.

`resolvedPath(for:)` is the piece **this** packet needs: for a `.pdf` recent with a `docId`, it loads
`documents/<docId>/meta.json` and — only when `meta.last_known_path` names a *rival* existing file — reads the
embedded `/VellumDocId` from both candidates to decide which file really is this document. Requires
`DocumentDataStore.loadMeta` (§2.7) and `PdfMetadata.documentId(atPath:)` (§2.10) to be in place first.

**iPad wiring (see §2.15):** the iPad has its own path-healing helper, `DocumentImport.resolveExistingPath(_:)`,
which handles the app-container-UUID-changed case. The two are complementary, not rivals. Order at every recents
open site: `RecentFilesService.resolvedPath(for: entry)` first (identity-based), then
`DocumentImport.resolveExistingPath(_:)` on the result (container-relocation heal), then the bookmark
(§2.14/§2.15) as the last resort.

`storageKey` stays `"vellum.recent-pdfs"`, `maxRecent` stays 8. **Byte-compatible defaults key.**

---

### 2.12 `Vellum/Services/Ai/PageTextCache.swift` + `PageTextPersister.swift` — MERGE

Take main's diff for both, with **one omission** and **one call-site sweep**.

**`PageTextCache.swift`** — the whole diff is a rename of the identity axis from "path" to "session-stable
storage key":
- `lookup(path:data:title:)` → `lookup(key:path:data:title:)`, with the new legacy-adoption block: on a miss
  under `key`, if `PageTextCache.pathKey(path)` has an entry, rename `<legacyKey>.json` → `<key>.json`, move the
  index row, then validate as usual. This is the **lazy path-keyed→identity migration on open** in my scope.
- `write(path:...)` → `write(key:path:...)`; the index row keeps storing `path` for Settings display.
- `refreshHash(path:data:)` → `refreshHash(key:data:)`.
- `delete(pathKey:)` → `delete(key:)`.
- `evictStale(olderThan:excludingPaths:)` → `evictStale(olderThan:excludingKeys:)` (now matches on the map key,
  not `entry.path`).
- `latestHash` is now keyed by storage key.
- `lookup` refreshes `entry.path` when the same document is seen at a new path.
- Directory moves from `<appData>/text-cache` to `<caches>/<bundleId>/text` via the new `defaultDirectory` +
  one-shot `migrateFromLegacyLocationIfNeeded`. **This works on iOS** (`.cachesDirectory` resolves inside the
  app container) and is desirable — class-C data belongs in Caches so iOS can purge it.

**OMIT** the `UITestLaunchConfiguration.storageRoot` branch inside `defaultDirectory`; the iPad has no such type.
The body becomes just the `FileManager.default.urls(for: .cachesDirectory, ...)` path.

**`PageTextPersister.swift`** — add `let key: String` and the `key:` init parameter, and pass `key: key` into
`cache.write(...)`.

**Call sites to update (grep `PageTextCache.shared` and `PageTextPersister(`):**

| File | Line (approx) | Change |
|---|---|---|
| `Vellum/Platform/iOS/PdfViewerView_iOS.swift` | 125–150 | resolve `let storageKey = app.document.map { DocumentIdentity.storageKey(for: $0) }`, then `lookup(key: storageKey, path: path, data: data, title:)` and `PageTextPersister(key: storageKey, path: path, ...)`. Mirror main's `PdfViewerView.swift` hunk exactly (guard on `let storageKey` in both `if let` conditions). |
| `Vellum/Platform/iOS/VellumApp_iOS.swift` | 88 | replaced wholesale in §2.17 |
| `Vellum/Views/Settings/SettingsView.swift` | 587 | dies with the v1 Storage tab in §2.21 |
| `Vellum/Services/Pdf/PdfSessionBackend.swift` | 630 | `refreshHash(key: PdfSessionCacheKeys.key(forPath: path), data:)` — see §2.13 |
| `Tests/PageTextCacheTests.swift` | 77, 127 | see §4 |

---

### 2.13 `Vellum/Services/Pdf/PdfSessionBackend.swift` — MERGE (the hardest file in the packet)

**Edit order (packet 10 §2.3):** packets 1, 6, 7 all merge into this file (and its sibling
`WebSessionBackend.swift`, §2.15) — order **1 → 6 → 7**. Note: `PdfSessionBackend.swift`,
`WebSessionBackend.swift`, and `Platform/iOS/PdfChrome_iOS.swift` were previously flagged as dirty in
the iPad worktree ahead of this packet; that work has already landed in commit `783c8835`, so there is
nothing to stash or commit before starting §2.13/§2.15.

**What main changed** (in `PdfDocumentIO`, an `actor` with per-session mutable state):

1. `private var docId: String?` — the session's resolved id; nil until read-or-stamped.
2. `private var cacheKey: String` — the page-text cache key, set to `PageTextCache.pathKey(path)` at init and
   promoted to `docId` in `open()` **only if the file already carried one**. Never changes after a mid-session
   stamp.
3. `open()` reads the 4-tuple from `PdfMetadata.documentInfo`, stores `docId`, promotes `cacheKey`, and returns
   `DocumentInfo(..., docId: docId)`. **`open` never stamps** — opening a file the user hasn't invested in must
   not modify it.
4. `ensureDocumentId()` — `resolved → return`; `on disk → read+return (no write)`; `absent → full rewrite whose
   only change is the piggybacked stamp`; `write fails → sha256 of the whole file bytes (persisting nothing)`;
   `file unreadable → sha256(path)`. It never surfaces stamping failure as an error.
5. `StampPlan { data, pendingStamp }` + `stampDocIdIfNeeded(_:)` + `commitStamp(_:)` — the **two-phase commit**.
   `stampDocIdIfNeeded` (a) returns unchanged when `docId != nil`; (b) if the bytes already contain an id,
   commits it immediately and clears the registry (it is already persisted); (c) otherwise takes
   `PdfDocIdRegistry.pendingOrAssign(forPath:)` — so two split panes stamping the same file agree on ONE uuid —
   and appends a single incremental Info update carrying `doc_id`. The actor's `docId` is deliberately NOT set
   for a fresh stamp; `commitStamp` sets it only **after** `PdfAtomicWriter.save` returns, so a failed write can
   never leave the actor claiming a UUID that is not in the file.
6. Both write chokepoints (`writeAndRefreshCache`, `saveThroughPdfKit`) run `stampDocIdIfNeeded` → save →
   `commitStamp` → `refreshHash(key: cacheKey, data: plan.data)`.
7. Also in the diff but **NOT MINE**: `canonicalize`'s NUL-trimmed `String(decoding:)` fix, `open`'s
   `Task.detached` for realpath/stat, `Annotation.sortedForDisplay`, and the whole outline-bookmark
   update branch (bookmark-titles packet).

**What the iPad counterpart looks like today:** there is no `PdfDocumentIO` actor. `PdfDocumentSession` is a
`@MainActor` facade holding `let path` / `let info`; every mutation is a `nonisolated static func perform*`
executed inside `PdfFileGate.shared.perform { ... }` (a real lock+continuation queue, not just an actor). The
two write chokepoints are `nonisolated private static func writeAndRefreshCache(_:path:)` and
`nonisolated private static func saveThroughPdfKit(_:path:)`, plus a third public one,
`nonisolated static func persistPdfKitRewrite(_:preservingMetadataFrom:path:)`, called by
`InkDiskWriter` in `Vellum/Platform/iOS/InkController_iOS.swift:544`. The iPad also carries the
`pdfKitDropsCustomKeys` / `rehydrateAnnotationMetadata` / `rehydrateBookmarkMetadata` / `restoreInfoDictionary`
machinery for iPadOS 26.

**Standing decision: PdfFileGate stays. Do NOT swap in main's actor.** Graft the behaviours instead.

**Concrete instructions:**

**(a) `PdfSessionBackend.open`** — inside the existing `offMainRead` closure:

```swift
            let document = try PdfDocumentLoader.loadRaw(path: canonical)
            let (title, pageCount, lastPage, docId) = PdfMetadata.documentInfo(
                document: document, path: canonical)
            // Session-stable cache key: the docId if the file ALREADY carries
            // one, else the path hash. A docId stamped later this session must
            // NOT change it — the lookup and persister keyed the whole session
            // by this value.
            let cacheKey = (docId?.isEmpty == false) ? docId! : PageTextCache.pathKey(canonical)
            PdfSessionCacheKeys.register(path: canonical, key: cacheKey)
            if let docId, !docId.isEmpty { PdfDocIdRegistry.recordStamp(docId, forPath: canonical) }
            return (canonical, DocumentInfo(
                kind: .pdf, pdfPath: canonical, title: title,
                pageCount: pageCount, lastPage: lastPage, docId: docId))
```

`open` still must not go through `PdfFileGate` and still must not stamp. Keep the existing doc comment.

**(b) `PdfDocumentSession.ensureDocumentId()`** — add to the class (and to the `DocumentSession` protocol, §2.16):

```swift
    /// The document's resolved /VellumDocId, once this session has seen or
    /// written one. Set ONLY after a stamp is durably on disk — the two-phase
    /// commit macOS gets from `PdfDocumentIO.commitStamp`.
    private var resolvedDocId: String?

    func ensureDocumentId() async throws -> String {
        if let resolvedDocId { return resolvedDocId }
        if let known = info.docId, !known.isEmpty {
            resolvedDocId = known
            return known
        }
        let path = self.path
        // Read-only probe first: an id another session already landed needs no
        // write, and reads deliberately run off the gate.
        if let existing = try? await offMainRead({ () -> String? in
            guard let raw = try? PdfDocumentLoader.loadRaw(path: path) else { return nil }
            return PdfMetadata.documentId(raw)
        }), let existing {
            PdfDocIdRegistry.recordStamp(existing, forPath: path)
            resolvedDocId = existing
            return existing
        }
        // Stamp: a full rewrite whose only change is the piggybacked doc_id,
        // serialized against every other writer of this file by the gate.
        let key = PdfSessionCacheKeys.key(forPath: path)
        let id = await PdfFileGate.shared.perform {
            Self.performEnsureDocumentId(path: path, cacheKey: key)
        }
        resolvedDocId = id
        return id
    }
```

```swift
    /// Never throws — a stamping failure degrades to a stable fallback identity
    /// rather than failing the caller (matching macOS `ensureDocumentId`).
    nonisolated static func performEnsureDocumentId(path: String, cacheKey: String) -> String {
        if let raw = try? PdfDocumentLoader.loadRaw(path: path),
           let existing = PdfMetadata.documentId(raw) {
            PdfDocIdRegistry.recordStamp(existing, forPath: path)
            PdfDocIdRegistry.clear(forPath: path)
            return existing
        }
        do {
            let original = try Self.readBytes(path: path)
            let plan = Self.stampDocIdIfNeeded(original, path: path)
            guard let pending = plan.pendingStamp else {
                throw SessionServiceError.io("Failed to stamp document id")
            }
            try PdfAtomicWriter.save(plan.data, toPath: path)
            // COMMIT: only now is the id real.
            PdfDocIdRegistry.recordStamp(pending, forPath: path)
            PdfDocIdRegistry.clear(forPath: path)
            Task { await PageTextCache.shared.refreshHash(key: cacheKey, data: plan.data) }
            return pending
        } catch {
            // Read-only dir / locked file: a stable byte hash, persisting
            // nothing (stable precisely because the file can't be rewritten).
            if let data = try? Data(contentsOf: URL(fileURLWithPath: path)) {
                return DocumentIdentity.byteHash(data)
            }
            return DocumentIdentity.sha256Hex(path)
        }
    }
```

Note the deliberate difference from main: main goes through `loadForMutation → serialize → writeAndRefreshCache`
(a PDFKit normalize). On iPadOS 26 that normalize drops custom Info keys, so this stamps the file's own bytes
directly, same reasoning as §2.10(b). If `ClassicPdfFile` can't parse them, `stampDocIdIfNeeded` returns
`pendingStamp == nil` and we fall into the byte-hash fallback — which is exactly the degradation main documents
for an unwritable file.

**(c) `StampPlan` + `stampDocIdIfNeeded` as statics.** Port main's, with two changes: the "already resolved this
session" fast path reads `PdfDocIdRegistry.knownStamp(forPath:)` instead of actor state, and **it must never
throw**, because on iPad it sits inside write paths that previously could not fail this way:

```swift
    private struct StampPlan {
        var data: Data
        var pendingStamp: String?
    }

    /// Lazy /VellumDocId stamp, folded into a write that was happening anyway.
    /// BEST-EFFORT AND NON-THROWING: on macOS this sits on the IO actor and may
    /// throw, but here it is inside the annotation/ink/metadata write path, and
    /// a document whose xref shape defeats `ClassicPdfFile` must still save its
    /// annotations. A failure returns the ORIGINAL bytes with no pending stamp,
    /// leaving the registry entry so the next write reuses the same uuid.
    nonisolated private static func stampDocIdIfNeeded(_ data: Data, path: String) -> StampPlan {
        if PdfDocIdRegistry.knownStamp(forPath: path) != nil {
            return StampPlan(data: data, pendingStamp: nil)
        }
        if let raw = PdfDocumentLoader.cgDocument(from: data),
           let existing = PdfMetadata.documentId(raw) {
            // Already on disk in these bytes — safe to record now (persisted).
            PdfDocIdRegistry.recordStamp(existing, forPath: path)
            PdfDocIdRegistry.clear(forPath: path)
            return StampPlan(data: data, pendingStamp: nil)
        }
        let uuid = PdfDocIdRegistry.pendingOrAssign(forPath: path)
        guard let stamped = try? PdfMetadata.setMetadataIncrement(
            normalizedData: data, entries: [(key: "doc_id", value: uuid)]) else {
            return StampPlan(data: data, pendingStamp: nil)
        }
        return StampPlan(data: stamped, pendingStamp: uuid)
    }
```

**(d) `writeAndRefreshCache`** — the single place every iPad write funnels through:

```swift
    nonisolated private static func writeAndRefreshCache(_ data: Data, path: String) throws {
        let plan = stampDocIdIfNeeded(data, path: path)
        try PdfAtomicWriter.save(plan.data, toPath: path)
        // Two-phase commit: the stamp becomes "real" only after the atomic
        // rename lands, so a failed write can never leave a phantom docId.
        if let pending = plan.pendingStamp {
            PdfDocIdRegistry.recordStamp(pending, forPath: path)
            PdfDocIdRegistry.clear(forPath: path)
        }
        let key = PdfSessionCacheKeys.key(forPath: path)
        Task { await PageTextCache.shared.refreshHash(key: key, data: plan.data) }
    }
```

**Ordering is load-bearing**: in `performCreate` / `performUpdate` / `performDelete`, the iPadOS-26
`restoreInfoDictionary(from: originalData, into: data)` step already ran before `writeAndRefreshCache` is called,
so the stamp increment is appended last and survives. Do not move the stamp earlier.

`saveThroughPdfKit` and `persistPdfKitRewrite` both already end in `writeAndRefreshCache`, so they inherit the
stamp for free — no signature changes, and `InkDiskWriter` needs no edit at all. **This is why
`PdfSessionCacheKeys` exists**: the ink writer only has a path.

**(e) Do NOT take** from main's `PdfSessionBackend` diff: the `Annotation.sortedForDisplay` swap in
`readAnnotations`, the whole outline-bookmark `updateAnnotation` branch, `input.content` bookmark titles, and
the `canonicalize` NUL-trim (all other packets — leave the iPad's current bodies).

**(f) `PdfDocumentSession` becomes stateful** (`private var resolvedDocId`). It is `@MainActor`, so no
concurrency change. Its `let info: DocumentInfo` now carries `docId` from `open`.

---

### 2.14 `Vellum/Services/SessionService.swift` — MERGE

The iPad's file has diverged. Add exactly three things from main's diff:

1. In `protocol SessionService`:
```swift
    /// Resolve the document's stable identity, lazily stamping /VellumDocId into
    /// a PDF that has none. Web documents return their sha256 URL-hash key.
    func ensureDocumentId(sessionId: String) async throws -> String
```
2. `extension Notification.Name`: `vellumDocumentSidecarImported` (`"vellum.sidecar-imported"`) and
   `vellumDocumentDataDeleted` (`"vellum.document-data-deleted"`), verbatim with main's comments.
   The Storage pane posts `vellumDocumentDataDeleted`; the `.vellum` packet 2 posts the other.
   **Take both now** so the packet 2 doesn't have to touch this file.

Also add to `protocol DocumentSession` in `Vellum/Services/DocumentSessionManager.swift` (§2.15).

---

### 2.15 `Vellum/Services/DocumentSessionManager.swift` — VERBATIM · `Vellum/Services/Web/WebSessionBackend.swift` — MERGE

**Edit order (packet 10 §2.3):** `WebSessionBackend.swift` is a 1/6/7 MERGE file, same as
`PdfSessionBackend.swift` (§2.13) — order **1 → 6 → 7**. The commit landing this file already carries
`783c8835`; no dirty-worktree stashing is needed.

**`DocumentSessionManager.swift`**: iPad copy == main's base. Overwrite with main's file. The whole diff is
`func ensureDocumentId() async throws -> String` on the `DocumentSession` protocol and
`func ensureDocumentId(sessionId:) async throws -> String { try await session(sessionId).ensureDocumentId() }`
on the manager.

**`WebSessionBackend.swift`** (diverged — merge two small hunks into `WebDocumentSession`):
- in the `openInfo = DocumentInfo(...)` construction (iPad line ~158), add `docId: key`;
- add:
```swift
    /// The document identity for a webpage is its sha256 URL-hash key — already
    /// stable across sessions and byte-compatible with the Tauri-era library,
    /// so nothing is stamped or re-keyed.
    func ensureDocumentId() async throws -> String { key }
```
Do not take the rest of main's `WebSessionBackend` diff (web-note composer / #116 / #125 — other packets).

---

### 2.16 `Vellum/Services/SecurityScopedBookmark.swift` — VERBATIM (comment rewritten)

`cp` main's file, then replace the header comment — main's says "this app is not sandboxed … defense-in-depth",
which is false and misleading on iPad:

```swift
// Durable, out-of-container file access for PDFs picked in Files, opened from
// another app, or restored from a saved tab.
//
// On iOS this is MANDATORY, not defense-in-depth. The app is sandboxed: a
// UIDocumentPicker URL grants access only for the life of its security scope,
// and the app container's UUID changes across reinstalls and some OS updates,
// so a persisted absolute path can stop resolving for a file that is still
// there. A minted bookmark is the only thing that reliably re-opens a document
// after a relaunch without another trip through the picker.
//
// Every operation is best-effort and never throws: callers always have the raw
// path (and, on iPad, DocumentImport.resolveExistingPath) to fall back to.
```

Code is unchanged — `URL.bookmarkData(options:includingResourceValuesForKeys:relativeTo:)` and
`URL(resolvingBookmarkData:options:relativeTo:bookmarkDataIsStale:)` exist on iOS.

**One iOS API note:** `.withSecurityScope` is a macOS-only `URL.BookmarkCreationOptions` /
`BookmarkResolutionOptions` value. On iOS it does not exist. Change both option arrays to `[]`:

```swift
    static func make(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
    ...
        guard let url = try? URL(
            resolvingBookmarkData: data, options: [],
            relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
```

(This matches what the iPad's `WebStorageSettings.resolveBookmark` already does for the custom-folder bookmark —
`options: []` + `startAccessingSecurityScopedResource()`. Keep the two consistent.)

---

### 2.17 `Vellum/Stores/AppStore.swift` — MERGE (shared file — only my hunks)

**Edit order (packet 10 §2.3):** packets 1, 2, 4 all merge into this file (58 KB diff in main). Order
**1 → 4 → 2**. Packet 7's single `restorePendingNote` addition is a surgical insert after those three.

`AppStore.swift` is the single most contended file in the delta (995 changed lines across ~8 packets). Take ONLY
these four changes. Everything else in main's `AppStore` diff — `TabTeardownRegistry`, the open watchdog /
`beginOpen`/`endOpen`, `WebDocumentActionIdentity`, `renameDocument`, the `restoreTabs` rewrite's
per-descriptor-index mapping, `importVellumBundle*`, `applyActiveState`'s find/region-capture fields — belongs to
other packets.

**(a) `syncDocumentId(sessionId:)`** — copy main's method verbatim (introduced in `a42705d1`):

```swift
    /// After a PDF mutation may have lazily stamped /VellumDocId, pull the
    /// resolved id up into the in-memory DocumentInfo so class-B stores can key
    /// off it this session. The stamp itself already happened during the write —
    /// for a just-stamped session the backend returns the id without touching
    /// disk. No-op once the active document already carries an id (web docs are
    /// always stamped at open, so this never fires for them).
    func syncDocumentId(sessionId: String) async {
        guard let tab = tabs.first(where: { $0.id == sessionId }),
              tab.document?.kind == .pdf, tab.document?.docId == nil else { return }
        guard let id = try? await sessions.ensureDocumentId(sessionId: sessionId), !id.isEmpty else { return }
        updateTab(sessionId) { tab in
            if tab.document != nil, tab.document?.docId == nil {
                tab.document?.docId = id
            }
        }
        if activeTabId == sessionId, document?.docId == nil {
            document?.docId = id
        }
    }
```

Place it right after `updateDocumentTitle`. The iPad's pane identity (`PaneDocumentIdentity_iOS`, keyed on
`tabId` + `path`) is path-based, so setting `docId` does **not** re-run `loadDocumentState` — same as macOS. Do
not add `docId` to `PaneDocumentIdentity_iOS`.

**(b) Mint the bookmark in `adoptOpenedDocument`** (iPad line ~555):

```swift
    private func adoptOpenedDocument(_ doc: DocumentInfo, sessionId: String) async {
        var doc = doc
        // Mint a security-scoped bookmark right now, while the just-completed
        // open guarantees read access. Web docs have no filesystem path.
        if doc.kind == .pdf {
            doc.bookmarkData = SecurityScopedBookmark.make(forPath: doc.pdfPath)
        }
        RecentFilesService.record(doc)
        ...
```
Everything after this line stays as the iPad has it (including `workspace?.sidebarOpen = true` in its current
position — main moved it, that's the packet 4's change).

Also thread `doc` (the local `var`) through the rest of the method — the existing body references `doc` for the
already-open check and the `PdfTab` construction, so shadowing it is enough.

**(c) Resolve the bookmark in `restoreTabs`** (iPad line ~323). Keep the iPad's `DocumentImport.resolveExistingPath`
heal and its `newStartTab()` / `setZoom`/`setCurrentPage`/`setMode` structure (main's rewrite of this method is
the packet 4's). Change only the PDF branch:

```swift
                #if os(iOS)
                // Resolution order: the saved bookmark first (survives a
                // container-UUID change and a move/rename), then the path heal,
                // then the raw saved path.
                var resolvedPath = doc.pdfPath
                var resolvedURL: URL?
                var bookmarkNeedsRefresh = false
                if let bookmarkData = doc.bookmarkData,
                   let resolved = SecurityScopedBookmark.resolve(bookmarkData) {
                    resolvedPath = resolved.url.path
                    resolvedURL = resolved.url
                    bookmarkNeedsRefresh = resolved.isStale
                } else {
                    resolvedPath = DocumentImport.resolveExistingPath(doc.pdfPath) ?? doc.pdfPath
                }
                // The scope must be held for the whole open: PDFKit/CGPDF have
                // read everything they need by the time `openFile` returns.
                let accessStarted = resolvedURL?.startAccessingSecurityScopedResource() ?? false
                defer { if accessStarted { resolvedURL?.stopAccessingSecurityScopedResource() } }
                await openFiles(paths: [resolvedPath])
                if bookmarkNeedsRefresh || doc.bookmarkData == nil {
                    // adoptOpenedDocument minted a fresh one already; nothing to do.
                }
                #else
                await openFiles(paths: [doc.pdfPath])
                #endif
```

Because the iPad routes restore through `openFiles → openOneFile → adoptOpenedDocument`, the bookmark is re-minted
automatically for the resolved path by (b). That is simpler than main's explicit
`opened.bookmarkData = bookmarkNeedsRefresh ? make(...) : saved` and produces the same result. Drop the dead `if`
above; it's there only to make the intent explicit while you write the code.

`defer` inside a `for` body runs at the end of each iteration — correct here.

**(d) `DocumentDataStore.touch` on document open.** macOS does this from `ScratchpadStore.loadForDocument`
(packet 6) and `AiPersistence` (packet 5). To keep this packet self-sufficient, do **not** add a touch
call in AppStore; instead confirm §2.20's `PaneView_iOS.loadDocumentState` change lands. If packets 6 and 5
slip, the `documents/<key>/meta.json` stamp will simply not be written until a note or conversation is
saved — which is main's own `force:` semantics (`touch` refuses to create a meta-only folder unless `force: true`).
Do not "fix" this by forcing a touch on every open: a merely-opened document must not grow a synced folder holding
nothing but a stamp.

---

### 2.18 `Vellum/Stores/AnnotationStore.swift` — MERGE (one hunk)

In the optimistic-create success path (main's `a42705d1` hunk, around iPad line 236), after
`_ = try await sessions.createAnnotation(...)`:

```swift
                // The create just lazily stamped /VellumDocId (first mutation on
                // an unstamped PDF); surface the resolved id into the in-memory
                // document so class-B stores can key off it this session.
                if app.activeTabId == sessionId {
                    await app.syncDocumentId(sessionId: sessionId)
                }
```

Find the exact insertion point by matching main's context — the iPad's `AnnotationStore` has diverged around
optimistic creates (`CreateAnnotationInput.createdAt`), so apply by hand, not by patch.

---

### 2.19 `Vellum/Services/StorageHousekeeping.swift` — VERBATIM · `VellumApp_iOS.swift` launch sweep

**`StorageHousekeeping.swift`**: `cp` main's file. Pure Foundation. It compiles once §2.12 has renamed
`evictStale(…excludingKeys:)`.

Deliberate detail: `retentionMonths` reads `UserDefaults.standard`, NOT `AppDefaults.current`. That is main's
committed choice (it is a user preference, not app state, and no test asserts on the real domain). Keep it.
Defaults key `"storage.retentionMonths"`, default 6 months, `0` = "Never". **Byte-compatible defaults key.**

**`Vellum/Platform/iOS/VellumApp_iOS.swift`** (iPad-only file, not in delta-files.txt) — replace the eviction
block inside `launchMaintenance()` (lines 67–92):

```swift
    @MainActor
    private func launchMaintenance() async {
        let openDocuments = workspace.root.allLeaves()
            .flatMap { $0.app.tabs }.compactMap(\.document)
        // The text cache excludes open documents by STORAGE KEY now (docId when
        // stamped, else path hash) — the same key their lookup/persister used.
        let openKeys = Set(
            openDocuments.filter { $0.kind == .pdf }
                .map { DocumentIdentity.storageKey(for: $0) })
        let openWebUrls = Set(openDocuments.filter { $0.kind == .web }.map(\.pdfPath))

        // (unchanged) resolve the iCloud ubiquity container off-main FIRST …
        await Task.detached(priority: .utility) {
            WebStorageSettings.resolveICloudRoot()
        }.value

        Task.detached(priority: .background) {
            // The sweep runs regardless of the retention policy.
            await WebStorageRelocator.sweepAtLaunch()
            // TTL eviction of derived data, using the user's chosen retention
            // window (Settings ▸ Storage ▸ Housekeeping; "Never" skips it).
            await StorageHousekeeping.runCleanup(
                openPdfKeys: openKeys, openWebUrls: openWebUrls)
        }

        showStorageChoice = WebStorageSettings.needsFirstLaunchChoice
    }
```

Delete the now-unused `let cutoff = ...` line and the two direct `evictStale` / `evictStaleUnsavedSnapshots`
calls. **Keep the `resolveICloudRoot()` await and its comment** — that is the iPad's iCloud decision and it must
still run before both the sweep and the first-launch sheet.

---

### 2.20 `Vellum/Platform/iOS/PaneView_iOS.swift` — iPad-only edit (not in delta-files.txt)

In `loadDocumentState()` (line ~162), insert the materialization step between the annotation load and the
AI/scratchpad loads, mirroring main's `PaneView.swift`:

```swift
        await pane.annotations.loadAnnotations()
        guard !Task.isCancelled else { return }
        // In iCloud mode the document's notes/conversations may be evicted
        // placeholders — download them off-main before the sync reads below so
        // they load real bytes rather than degrading to empty.
        await DocumentDataStore.materializeIfNeeded(
            forKey: DocumentIdentity.storageKey(for: document))
        guard !Task.isCancelled else { return }
        pane.ai.loadConversationForDocument(app.document)
        pane.scratchpad.loadForDocument(app.document)
```

Also add the `.vellumDocumentDataDeleted` receiver so a Storage-pane delete cannot be resurrected by a live
pane's next flush (main's `PaneView.swift` hunk). The two calls it makes —
`pane.scratchpad.discardNotesForExternalDelete(matchingKey:)` and
`AiPersistence.invalidateCachedConversation(forKey:)` + `pane.ai.loadConversationForDocument` — **do not exist on
iPad yet**; they are owned by the packets 6 and 5. Two options:
1. (preferred) land the receiver with the calls, and coordinate so the packets 6 and 5 land first;
2. if this packet must land alone, add the `.onReceive` with a `// TODO(parity-129): needs
   ScratchpadStore.discardNotesForExternalDelete / AiPersistence.invalidateCachedConversation` body that only
   reloads what exists. Do NOT call `pane.scratchpad.loadForDocument` there — that flushes the stale note over
   the just-deleted file, which is the exact bug the discard path exists to prevent.

The `.vellumDocumentSidecarImported` receiver belongs to the `.vellum` packet 2 — skip it.

---

### 2.21 `Vellum/Views/Settings/StorageInventory.swift` + `StorageRelocationInventoryReloadPolicy.swift` — VERBATIM

`cp` both. Pure value transforms, no platform API.

`StorageInventory` compiles once `DocumentDataStore.DocumentDataEntry` (§2.7), `PageTextCacheEntry` (already on
iPad with all needed fields: `pathKey`, `title`, `sourcePath`, `sourceExists`, `lastOpened`, `byteSize`) and
`WebLibrary.SnapshotStorageEntry` (already on iPad) exist.

`StorageRelocationInventoryReloadPolicy` needs `WebStorageRelocator.Status`, which lands in §2.22 — port them in
that order, or accept one compile error until §2.22 lands.

`isLikelyDocId(_:)` = "contains a hyphen" (UUID vs bare-hex sha256). Terse but correct — keep it.

---

### 2.22 `Vellum/Views/Settings/StorageLocationChoiceSheet.swift` — MERGE

The iPad file is `#if os(iOS)`-wrapped and has already replaced `pickCustomFolder()` (NSOpenPanel) with
`chooseCustomFolder(then:)` (UIDocumentPicker folder mode + security-scoped bookmark) and made
`apply(mode:customPath:customBookmark:)` carry the bookmark. **Preserve all of that.**

Take from main's diff:

1. **`WebStorageRelocator.Status`** + `private(set) static var status = Status()`:
```swift
    struct Status: Equatable {
        var isInProgress = false
        var needsRecovery = false
        var message = ""
    }
    private(set) static var status = Status()
```
2. **`extension Notification.Name { static let vellumStorageRelocationChanged = Notification.Name("vellumStorageRelocationChanged") }`**
3. **`sweepAtLaunch()`**'s resume detection + terminal status posting — copy main's body verbatim (it is pure
   `UserDefaults` + generation comparison; no AppKit).
4. **`apply(...)`**'s status transitions — copy main's structure verbatim, but keep the iPad's extra
   `customBookmark` parameter and its `WebStorageSettings.setMode(mode, customPath:, customBookmark:)` call.
   Note the ordering fix in main's diff: `relocationGeneration += 1` moves **above** the `guard sourceReachable`
   so an older queued move can't clear a newer request's recovery marker. Keep that ordering.
5. **Copy text**: main added "AI conversations" to the iCloud and custom-folder descriptions. Apply the same to
   the iPad's already-iPad-ified strings:
   - iCloud: `"Everything — offline copies, highlights, notes, AI conversations, and reading positions — lives in iCloud Drive ▸ Vellum and syncs across your devices."`
   - Custom: `"Offline copies go in a folder you pick in Files. Your highlights, notes, AI conversations, and reading positions stay on this iPad and won't sync."`
   Keep "this iPad" / "your devices" / "turn on iCloud Drive" — do not regress to "Mac".

Keep the iPad's `.frame(maxWidth: 520)` and `.interactiveDismissDisabled()`.

---

### 2.23 `Vellum/Views/Settings/StorageSettingsTab.swift` — REBUILD (new file) + `SettingsView.swift` — MERGE

**Edit order (packet 10 §2.3):** `SettingsView.swift` is a four-packet file (3, 1, 5, 8), each hunk
<10 lines in the `TabView`. Land **3 → 1 → 5 → 8** or accept a mechanical conflict.

**Delete first:** in `Vellum/Views/Settings/SettingsView.swift`, remove the entire v1 storage block —
`// MARK: - Storage` through end of file (iPad lines 262–718): `private struct StorageSettingsTab`,
`private struct StorageCacheRow`, `private struct WebStorageRow`. Leave the `StorageSettingsTab()` /
`.tabItem { Label("Storage", systemImage: "internaldrive") }` entry in `SettingsView.body` — it now resolves to
the new top-level type.

**Then create** `Vellum/Views/Settings/StorageSettingsTab.swift` as an iOS-native rebuild of main's 942-line file.
Port the whole structure and every string verbatim; the rebuild is confined to five things:

| macOS | iPad rebuild |
|---|---|
| `import AppKit` | delete |
| `relink(_:)` uses `NSOpenPanel` (`allowedContentTypes = [.pdf]`, `runModal()`) | `DocumentPickerCoordinator_iOS.shared.present { urls in … }` — but that picker is configured with `DocumentImport.openableTypes` and `allowsMultipleSelection = true`. Add a `presentPdfPicker(onPick: @escaping (URL) -> Void)` to `DocumentPickerCoordinator_iOS` (single selection, `[.pdf]`), and drive relink from its callback. Hold `startAccessingSecurityScopedResource()` around the `PdfMetadata.documentId(atPath:)` verification read. |
| `Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(...) }` | delete the button (there is no Finder). Keep the `LabeledContent("Folder") { Text(path) … }` row. |
| `Button("Change Folder…") { guard let path = WebStorageRelocator.pickCustomFolder() … }` and `locationBinding`'s `.custom` case | `WebStorageRelocator.chooseCustomFolder { … }` — the iPad's async picker already applies the mode and persists the bookmark itself, so it does NOT flow through `pendingLocation`. Mirror what the iPad's v1 tab does today (`SettingsView.swift` lines ~443 and ~500), including its `Task { try? await Task.sleep(for: .seconds(1)); await reload() }` refresh. |
| `.frame(height: 520)` on the `Form`; `.help(...)` on buttons | drop `.frame(height:)` (the iPad Settings sheet fills its presentation; the tab renders in a bottom tab bar). Drop `.help(...)` — macOS-only tooltip. **Keep every `.accessibilityLabel(...)` and `.accessibilityIdentifier(...)`** — they are the only handle tests and VoiceOver have. |
| `"This Mac"` / `"…on this Mac"` / `"across your Macs"` copy | `"This iPad"` / `"…on this iPad"` / `"across your devices"`. The iPad's v1 tab already has the correct wording for `locationFooterText` — copy those strings across rather than re-translating main's. |

Everything else ports 1:1: the five `@State` inventory sources, `rows` / `linkedRows` / `orphanRows`, the
`summaryTilesSection` / `documentsSection` / `orphansSection` / `housekeepingSection` /
`removeStoredDataSection` / `storageLocationSection` layout, `DisclosureGroup` per-document breakdown with the
four delete buttons, `reload()`'s `Task.detached` listing, all seven `.confirmationDialog`s and the
"Couldn't relink" `.alert`, `postDataDeleted`, `runCleanupNow`, `deleteLegacy`, `LegacyRow`,
`DocumentRowHeader`, `BreakdownLine`, `OrphanRow`, `LegacyRowView`.

`@Environment(WorkspaceStore.self) private var workspace` — verify it resolves. The iPad presents `SettingsView()`
from `Vellum/Platform/iOS/PdfChrome_iOS.swift:181`; check that call site injects `.environment(workspace)`, and
add it if not (the app-level `WindowGroup` injects it, but a `.sheet` does **not** inherit the environment
through a `UIHostingController` boundary in every case — verify, don't assume).

**Blocked dependencies** (see §5): `reload()` calls `ScratchpadPersistence.listLegacyEntries()` and
`AiPersistence.listLegacyEntries()`; `deleteLegacy` calls their `removeLegacyEntry(key:)`; `postDataDeleted` calls
`AiPersistence.invalidateCachedConversation(forKey:)`. None exist on iPad yet.

---

## 3. project.yml / Info-iOS.plist / entitlements

**Packet 9 is the sole editor of `project.yml` (packet 10 §2.2).** This packet is not a `project.yml`
editor — it hands packet 9 the hunks below rather than touching the file itself, so xcodegen only needs
to regenerate once per landing instead of once per packet. This packet needs no hunks in practice: the
`Vellum` target globs `sources: - path: Vellum`, so the eight new `.swift` files are picked up
automatically by `xcodegen generate` with no edit at all. Confirmed present already and NOT to be
re-taken from main's diff (i.e. nothing to hand packet 9 for these):
- `CODE_SIGN_STYLE: Automatic` + `DEVELOPMENT_TEAM: 9DCG97VASG` — the iPad already has both (PR #114's signing half is done).
- `SWIFT_STRICT_CONCURRENCY: minimal`, `SWIFT_VERSION: "6.0"` — keep.

Also flag to packet 9 that it should NOT take from main's `project.yml` diff: the `configs:` block, the
`UITesting` configuration, the `VellumUITests` target/scheme, `SWIFT_TREAT_WARNINGS_AS_ERRORS`, the
`Tests/Integrations/Fixtures` resource folder. (Warnings-as-errors and the fixtures wiring are packet 9's
own call to make — see packet 10 §1.1/§3.2 — but turning warnings-as-errors on mid-parity would block
every other packet regardless of who owns the decision.)

**`Vellum/Resources/Info-iOS.plist` — no changes required by this packet.** Verified already present:
`LSSupportsOpeningDocumentsInPlace = true`, `UIFileSharingEnabled = true`, `UISupportsDocumentBrowser = false`,
`CFBundleDocumentTypes` for `com.adobe.pdf` and `com.vellum.vellumweb`, and the `UTExportedTypeDeclarations`
for `com.vellum.vellumweb`. (Note the iPad's UTI is `com.vellum.vellumweb` while main uses
`com.vellum.webarchive` — that is a pre-existing, persisted-format-adjacent divergence; leave it. The `.vellum`
bundle type is the packet 2's addition.)

**Entitlements — a decision the human must make.** `Vellum/Vellum-iOS.entitlements` already declares
`com.apple.developer.icloud-container-identifiers`, `icloud-services: CloudDocuments`, and
`ubiquity-container-identifiers`, but `project.yml` deliberately does **not** set `CODE_SIGN_ENTITLEMENTS`,
with this comment:

> the free/Personal signing team can't provision the iCloud capability, which breaks device builds. Re-add
> `CODE_SIGN_ENTITLEMENTS` once on a paid Apple Developer account.

Consequence for this packet: `FileManager.url(forUbiquityContainerIdentifier: nil)` returns nil, so
`WebStorageSettings.icloudVellumRoot` is nil, `chosenMode == .icloud` degrades to `.local`, and
`WebStorageLayout.documentsDir` is always the app-container `documents/`. **That is a correct, tested
degradation path — do not "fix" it by wiring the entitlement.** Everything in §2.6/§2.7 (documents relocation,
placeholder tolerance, evicted-read guards) still needs to be ported and unit-tested via
`WebStorageSettings.icloudDriveRootOverride` + `WebICloud.materializeOverride`, so that switching the entitlement
on later is a one-line project.yml change and nothing else.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`; every
> other packet's test claim is a specification, not an edit.** Everything in this section is the
> adaptation list packet 9 applies — do not create or modify these files yourself.

The iPad target `VellumTests` is a hosted unit-test bundle (`platform: iOS`, `TEST_HOST` set), so
`AppDefaults`' hosted-test guard is live. New test files under `Tests/` are auto-globbed — no project.yml edit.

| File | Tag | iOS adaptations |
|---|---|---|
| `Tests/ScratchDefaultsTrait.swift` | VERBATIM | None. `removeSuite` builds `NSHomeDirectory()/Library/Preferences/<name>.plist`, which is the correct path inside an iOS container too. |
| `Tests/AppDefaultsGuardTests.swift` | VERBATIM | None. Pure `UserDefaults` + `WorkspaceService` + `RecentFilesService`. Keep the `requireFloor()` guard in the two write tests — it is what makes the mutation "point the floor at `.standard`" safe to run. |
| `Tests/DocumentIdentityTests.swift` | MERGE | XCTest, CoreGraphics fixtures, no AppKit. Adapt: `testSplitPaneStampsConvergeOnOneDocId` opens two `PdfSessionBackend().open(...)` sessions and calls `ensureDocumentId()` on both — with `PdfFileGate` these serialize instead of racing two actors, but the assertion (both return the same id, file carries it once) is unchanged. `testFailedStampWriteDoesNotCachePhantomDocId` chmods the temp dir to `0o555` — works in the iOS simulator container. `testEnsureDocumentIdIdempotentAndWritesOnce` compares file mtime/size across two calls; on iPad the second call hits `PdfDocIdRegistry.knownStamp`, so it still must not rewrite. Add `PdfSessionCacheKeys.reset()` alongside the existing `PdfDocIdRegistry.reset()` in `setUp`/`tearDown`. |
| `Tests/DocumentDataStoreTests.swift` | MERGE | **Blocked on the packet 6.** ~60% of the file (`testPersistenceSaveWritesRelativeAndLoadsScheme`, all the `relativeToScheme`/`schemeToRelative` cases, the three lazy-migration tests, the GC tests, `testStuckInICloudNotePausesPersistence`, `testDiscardNotesForExternalDelete*`) exercises `ScratchpadPersistence` v2. Port the DocumentDataStore-only tests now (`testScratchpadRoundTripsUnderOverrideRoot`, `testTouchDoesNotCreateMetaOnlyFolder`, `testRekey*` ×4, `testClearingNoteRemovesFileAttachmentAndFolder`, `testFolderKeptWhenMetaButPrunedWhenNoData`) and hand the rest to the packet 6. |
| `Tests/DocumentsRelocationTests.swift` | VERBATIM | None — it already drives everything through `WebLibrary.storeDirOverride`, `WebStorageSettings.icloudDriveRootOverride`, `DocumentDataStore.rootDirectoryOverride` and the new `WebICloud.materializeOverride`. This is the suite that proves the iCloud documents relocation without a real ubiquity container, which matters given §3's entitlement situation. |
| `Tests/RecentsResolveTests.swift` | VERBATIM | None. Pure CoreGraphics PDF fixtures + `DocumentDataStore.rootDirectoryOverride`. |
| `Tests/StorageManagementTests.swift` | MERGE | **Drop two tests** that belong to the packet 8: `testConnectionValidationMapsTransportOutcomesToUserFacingStates` and `testConnectionValidationRequestsNeverPutCredentialsInURLs` (plus any `StubURLProtocol`/`IntegrationTestDoubles` imports they pull in). Port the rest as-is. `testScratchpadLegacyListAndRemove` / `testAiLegacyListAndRemove` are blocked on §5's `listLegacyEntries` — hold them back with the rest of that dependency. |
| `Tests/PageTextCacheTests.swift` | MERGE | Take main's diff: every `lookup`/`write`/`refreshHash`/`delete`/`evictStale` call gains the `key:` axis, plus the new legacy-adoption test. The iPad's copy is at the same base, so main's diff applies with light hand-editing. |

**Not claimed:** `Tests/UITestLaunchConfigurationTests.swift`, `Tests/SafeClearTests.swift`, `Tests/VellumBundleTests.swift`,
`Tests/HomeSearch*`, `Tests/Integrations/*`, `Tests/AiConversationStoreTests.swift`, `Tests/DocumentRenameTests.swift`.

**Test-run hygiene:** after landing, run `xcodegen generate && xcodebuild test -scheme Vellum -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M4)'`.
`DocumentIdentityTests` writes real PDFs to `FileManager.default.temporaryDirectory` — fine in the simulator.

---

## 5. Risks & cross-packet dependencies

**File-edit ordering with other packets (packet 10 §2.3):**

- `Vellum/Stores/AppStore.swift` — packets 1, 2, 4 all MERGE (58 KB diff in main). Order **1 → 4 → 2**.
  Packet 7's single `restorePendingNote` addition is a surgical insert after those (§2.17).
- `Vellum/Models/Models.swift` — order **1 → 4 → 6** (packet 1 = `DocumentInfo.docId`; packet 4 =
  `PdfTab` find/region fields; packet 6 = pin fields). Packet 1 must preserve
  `CreateAnnotationInput.createdAt` (§2.5).
- `Vellum/Services/Pdf/PdfSessionBackend.swift` and `Vellum/Services/Web/WebSessionBackend.swift` —
  packets 1, 6, 7 all MERGE. Order **1 → 6 → 7** (§2.13, §2.15). The prior dirty-worktree caveat on
  these files (plus `Platform/iOS/PdfChrome_iOS.swift`) is stale — that work landed in `783c8835`.
- `Vellum/Views/Settings/SettingsView.swift` — four-packet file (3, 1, 5, 8), each hunk <10 lines in the
  `TabView`. Land **3 → 1 → 5 → 8** or accept a mechanical conflict (§2.23).

**Hard inbound dependencies (this packet cannot fully land without them):**

1. **`ScratchpadPersistence.listLegacyEntries() -> [(key: String, bytes: Int)]` and
   `removeLegacyEntry(key:)`** — consumed by `StorageSettingsTab.reload()` / `deleteLegacy`. Owned by the
   packet 6. Main's implementations are 10 lines each over its `readEntries()`/`writeEntries()` pair
   (`main:Vellum/Services/Scratchpad/ScratchpadPersistence.swift:152–167`). **Mitigation if the scratchpad
   packet slips:** stub `legacyScratchpad` to `[]` behind a
   `// TODO(parity-129 packet-1): needs ScratchpadPersistence.listLegacyEntries` and hold back
   `testScratchpadLegacyListAndRemove`. The orphans section degrades to "orphaned documents only" — visible but
   not wrong. **(breaks cycle C1 — packet 10 §3.1)**
2. **`AiPersistence.listLegacyEntries()`, `removeLegacyEntry(key:)`, `invalidateCachedConversation(forKey:)`** —
   same relationship, owned by the packet 5 (`main:Vellum/Services/Ai/AiPersistence.swift:500–521`). Same
   mitigation; `postDataDeleted`'s chat branch is the one that actually matters (without it, a Delete Chat on a
   document open in a pane can be resurrected by the write-behind cache's next flush) — **call that out in the
   PR body if it ships stubbed.** **(breaks cycle C2 — packet 10 §3.1)**
3. **`ScratchpadStore.discardNotesForExternalDelete(matchingKey:)`** — needed by §2.20's
   `.vellumDocumentDataDeleted` receiver. Packet 6.

**Hard outbound dependencies (other packets are blocked on this one):**

- `VellumBundle` (packet 2) needs `DocumentDataStore.{scratchpadExists, loadScratchpad, saveScratchpad,
  attachmentsDir, loadConversationsData, saveConversationsData}` and `DocumentIdentity.isCanonicalKey`.
- `DocumentRenameService` (packet 3) needs `DocumentDataStore.setTitle(forKey:title:)` and
  `RecentFilesService.updateTitle(path:title:)` — both land here.
- `LibraryDocumentsSearchProvider` (packet 3) needs `DocumentDataStore.listDocumentMetas()`.
- `KeychainStore` (packet 9) should adopt `TestEnvironment.isHostedTestProcess`.
- `ScratchpadPersistence` / `AiPersistence` v2 both key off `DocumentIdentity.storageKey` and write through
  `DocumentDataStore` — **land this packet first.**
- Anything reading `PageTextCache` must use the `key:` API after §2.12.

**Shared-file write conflicts to coordinate** (do not let two packets edit these concurrently):
`Vellum/Models/Models.swift`, `Vellum/Stores/AppStore.swift`, `Vellum/Views/Settings/SettingsView.swift`,
`Vellum/Services/Pdf/PdfSessionBackend.swift`, `Vellum/Platform/iOS/PaneView_iOS.swift`.
This packet's hunks in each are enumerated above; keep them surgical.

**Behavioural risks specific to this port:**

1. **iPadOS 26 drops custom Info keys.** `/VellumDocId` is a custom Info key, so every write path that
   round-trips through `PDFDocument.dataRepresentation()` can erase it. Mitigated by (a) stamping *after*
   `restoreInfoDictionary` inside `writeAndRefreshCache` (§2.13d), and (b) the byte-increment-first
   `stampDocumentId` (§2.10b). **Verify on a real iPadOS 26 device/simulator**: create a highlight on an
   unstamped PDF, quit, reopen, and confirm `PdfMetadata.documentId(atPath:)` still returns the id and
   `/VellumLastPage` survived.
2. **`stampDocIdIfNeeded` must never fail an annotation write.** Main's version throws; the iPad's must not
   (§2.13c). A PDF whose xref shape defeats `ClassicPdfFile` would otherwise stop accepting highlights the
   moment doc-id stamping landed — a severe regression on a code path that currently works.
3. **Cache-key drift.** If `PdfSessionCacheKeys` is not registered at `open` (or is registered with a
   non-canonical path), `refreshHash` writes under a key the persister never used and every reopen misses,
   silently re-extracting page text on large PDFs. Register with the **canonicalized** path — the same string
   the session and the ink writer carry.
4. **Bookmark scope leaks.** `startAccessingSecurityScopedResource()` is balanced by `defer` in §2.17c.
   `WebStorageSettings.resolveBookmark` intentionally holds its custom-folder scope for the process; do not
   "fix" that by adding a stop.
5. **Two path-healing mechanisms.** `RecentFilesService.resolvedPath` (identity-based) and
   `DocumentImport.resolveExistingPath` (container-UUID-based) must be applied in that order at every recents/
   restore site. Applying only one leaves a real class of iPad-specific dead recents.
6. **`documents/` under the app container is user-visible.** `UIFileSharingEnabled = true` +
   `LSSupportsOpeningDocumentsInPlace = true` mean the container's `Documents/` is browsable in Files. The
   `documents/<key>/` store lives under **Application Support**, not `Documents/` — confirm
   `WebLibrary.appDataDir` still resolves to `.applicationSupportDirectory` after §2.8 so users don't see a
   folder of hex-named directories in Files.
7. **iPad-only features to re-verify after §2.13** (the file this packet touches most invasively):
   Pencil ink writes (`InkDiskWriter` → `persistPdfKitRewrite` → `writeAndRefreshCache`), scribble-to-erase,
   `CreateAnnotationInput.createdAt` optimistic creates, and the ink-write coalescing battery fix. Every one of
   them now passes through the stamp. Sanity check: ink a page on an unstamped PDF and confirm exactly ONE extra
   incremental Info object is appended, and only on the first write.
