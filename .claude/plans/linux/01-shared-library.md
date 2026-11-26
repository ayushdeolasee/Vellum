# Layer 2 — The shared library

Decides: where the library both machines use lives, how changes travel between
them, which bytes are authoritative, and the on-disk format contract both apps obey.

Depends on: D3 (Mac and Linux share the same library).
Research: Gemini 4 Neon (round 1). Reviewed by Neon and GPT 6.2 Astra (round 2).

## Question

Linux cannot reach iCloud. How do a Mac and a Linux machine read and write one
Vellum library without corrupting it or silently dropping each other's data?

## What exists today

- **Three storage modes on the Mac**: local, custom folder, iCloud. They sit behind
  `StorageCoordinator` → `LibraryFileStore` (`DirectLibraryFileStore` for local/custom,
  the coordinated store for iCloud) and the 8-member `SyncedContainer` seam.
- **Writes are atomic**: tmp-file + `rename(2)` (`DocumentDataStore`, `WebLibrary.saveRecord`,
  `PdfAtomicWriter`).
- **iCloud layout** (`WebStorageLayout.resolve`, `recordsInRoot: true`):
  `<root>/Web Pages/*.vellumweb`, `<root>/.vellum/index.json`,
  `<root>/.vellum/records/<key>.json`,
  `<root>/.vellum/documents/<storageKey>/{meta.json, scratchpad.md, conversations.json, attachments/}`,
  `<root>/.vellum/positions/<device>.json`.
- **Custom-folder mode does not share most of the library.** It passes `recordsInRoot: false`,
  so only `Web Pages/` and `.vellum/index.json` live in the chosen folder. Notes, scratchpads,
  conversations and positions stay in Application Support. Pointing Syncthing at a custom folder
  today would sync almost nothing that matters.
- **PDFs are not in the library folder.** `meta.json` stores an absolute `lastKnownPath`, and
  recents store the path plus macOS security-scoped bookmark data. When you open a file outside
  the recognised roots, the Mac **copies it into its managed library**
  (`DocumentAccessResolver.localReadableURL`). So a user can open a synced PDF and end up annotating
  a private copy.
- **Positions are per-device files.** Two devices never write the same file.
- **Conflict handling is iCloud-only.** `PreserveLosersConflictResolver` works on `ConflictEvent`
  + `Data` (not on `NSFileVersion`), but only `ICloudSyncedContainer` feeds it today.

## Options for carrying the library

| Option | Good | Bad |
|---|---|---|
| **Syncthing** (recommended) | Peer-to-peer, no server or account, works offline and over Tailscale/LAN, open source, conflict copies are plain files | Both machines must be online to sync; one more tool to run |
| Dropbox / similar | Always-on relay | Proprietary Linux client; same conflict copies; privacy |
| NAS / SMB share | One live copy, no conflicts by design | Breaks offline; unreliable locking/`rename` over the network |
| Own sync server | Real merges, full control | Far too big for personal use; revisit for a public release |

**Recommendation:** Syncthing, plus a new **shared-folder** storage mode on both apps that uses
the iCloud layout inside a plain folder. iCloud stays available on Apple devices; anything
shared with Linux lives in the Syncthing folder.

## Decision: PDFs live inside the shared folder

- Shared PDFs live under `<root>/PDFs/` (name to be decided) and both apps **open them in place**.
  The Mac's copy-into-managed-library behaviour must not apply to this folder.
- `meta.json` stores the PDF path **relative to the library root** for anything inside it.
- Identity: every PDF is stamped with `/VellumDocId` on import into the shared folder, so identity
  never depends on a path. When stamping isn't allowed (encrypted, signed, or otherwise read-only per
  layer 3's eligibility check), fall back to the existing **byte hash** (`DocumentIdentity`), which is
  identical on both machines. (Round 3 replaced the earlier root-relative-path idea: a path hash still
  breaks if the file is renamed, a byte hash doesn't.) The absolute-path hash used today is migrated
  away from (S8).
- Migration: moving an existing Mac library into the shared folder must rekey metadata,
  scratchpad, conversations and attachments together (CLAUDE.md rule), and must be reversible.

## Blockers to fix before a shared-folder mode exists

1. **Layout is wired to iCloud coordination.** `WebStorageLayout.requiresCoordination` is inferred
   from `recordsDir`/`documentsDir` sitting inside `.vellum/`, not from the storage mode. A plain
   folder with `recordsInRoot: true` would be routed through iCloud's `NSFileCoordinator`
   (`StorageCoordinator`). Separate *layout* from *backend selection*.
2. **Positions ignore the layout in direct mode.** `CoordinatedPositionStorage` hard-codes the local
   `PositionLayout.root` when not coordinated, so positions would silently stay unsynced.
3. **Temp files.** Vellum writes three temp-name patterns: `.{name}.tmp-{uuid}`
   (`DirectLibraryFileStore`), `.{name}.vellum-{uuid}.tmp` (`PdfAtomicWriter`), and
   `{name}.tmp` (`WebLibrary`, `DocumentDataStore`, `WebInkStore`). The managed `.stignore` needs
   `(?d).*.tmp-*`, `(?d).*.vellum-*.tmp` and `(?d)*.tmp`.
4. **Conflict copies load as real files.** Syncthing names the losing copy
   `<stem>.sync-conflict-YYYYMMDD-HHMMSS-<DEVICE>.<ext>`. Both listing paths must skip them:
   `DirectLibraryFileStore.list` **and** `WebLibrary.recordFileNames` (the ordinary web listing).
   Otherwise `abc.sync-conflict-….json` shows up as a phantom duplicate web page.

## The format contract (both apps obey)

1. **Never drop unknown fields.** Today `WebPageRecord`, `WebInkRecord` and the document metadata drop
   unknown keys. `PositionDeviceRecord` and its document entries already keep them (via `PositionJSON`). This must ship on Mac **and** iPad
   before any new cross-platform field (for example portable ink, layer 5) is written anywhere.
2. **Every shared file carries a format version.** A reader seeing a newer major version opens
   the file read-only and says so.
3. **Atomic writes only**, with temp names the `.stignore` covers.
4. **One writer per file where possible** (as positions already are).
5. **Conflict copies are data.** Detect them, feed them to the conflict resolver, never delete silently.
6. **PDF files are shared bytes.** Linux writes must read back identically on the Mac (layer 3).
7. **Derived caches stay per device.** Page-text caches already live in the per-device Caches
   directory (`PageTextCache.defaultDirectory`). Linux uses `$XDG_CACHE_HOME`.

## Conflicts: what the existing resolver really does

| File | Today's resolver behaviour | Gap to close |
|---|---|---|
| `positions/<device>.json` | Never conflicts | None |
| `records/<key>.json` | Auto-merges only when `saved` state and annotation-ID sets match; otherwise archives the loser | Concurrent add/delete always archives. Acceptable for v1 |
| `documents/<key>/meta.json` | Record-level newest `lastOpened` wins | Field-level merge is out of scope for v1 |
| `documents/<key>/conversations.json` | Merges only when message-ID sets match; otherwise archives | Same as records |
| `documents/<key>/scratchpad.md` | No merge; loser preserved | **Scratchpad saves delete unreferenced attachments** (`ScratchpadPersistence`), so a preserved losing note can lose its images. Attachment cleanup must skip anything a conflict copy references |
| `attachments/*` | Unique IDs | See scratchpad row; they are not append-only |
| `Web Pages/*.vellumweb` + `index.json` | Pretty filenames assigned per device | Two offline devices can pick the same pretty name, or both update `index.json`. Needs a collision rule |
| PDFs | Whole-file conflict | Archive the losing copy; annotation-level merge is a later improvement |

Also: when a merge succeeds, the resolver returns before its loser-archive step. Decide whether a
merged conflict should still keep the loser for recovery (recommend yes, for a retention period).

## Acceptance before two machines may write

- Round trip: a library written by the Mac, opened and saved by Linux, diffed, then reopened on the Mac.
- **Two-peer offline conflict test**: both machines edit offline (scratchpad with an image,
  a web annotation, a new web page with the same pretty name), then reconnect. Both versions of
  every note and every referenced attachment must be recoverable.
- Until both pass, Linux stays read-only (see layer 4's read-only reader step).

## Open questions

- **N2**: Is Syncthing OK? Does your Mac library move out of iCloud into the shared folder, or does
  the Mac keep an iCloud library plus a separate shared one?
- **N6**: Format migrations: proposed that the spec lives in `VellumCore` and a version bump needs both
  apps updated in the same PR.
- Folder name for shared PDFs, and what happens to PDFs opened from outside it (copy in, or open
  read-only?).
- Linux file watching (inotify) uses one watch per directory, so large libraries can hit the default
  limit. Fall back to periodic rescans on `ENOSPC`.

## Work items (S1–S9)

Round 3: drafted by Gemini 4 Neon, paths checked against the repo, cross-checked against GPT 6.2 Astra's
layer-4 items. Sizes: **S** < half a day · **M** about 1 day · **L** 2–3 days (one agent session each).
IDs from other layers: `C*` core + shell (layer 4), `P*` PDF (layer 3), `I*` ink (layer 5).

Summary:

| ID | Item | Size | Depends on |
|---|---|---|---|
| S1 | Decouple `requiresCoordination`; add `.syncedFolder` storage mode | M | C1 |
| S2 | `CoordinatedPositionStorage` honours the layout in direct mode | S | — |
| S3 | Unknown-field preservation (`JSONValue`) on every shared Codable | M | C2 (or before, in-app) |
| S4 | `.stignore` manager (managed block, never clobbers user lines) | S | S1 |
| S5a | Conflict-copy and temp-file filtering in every listing path (Mac + Linux) | S | S1 |
| S5b | `FolderSyncedContainer` + platform watcher; resolver moved to Core with injected dependencies | L | S5a, C4 |
| S6 | Shared-folder mode never auto-deletes attachments; explicit recoverable cleanup | S | S5a |
| S7 | `.vellumweb` filename collisions + `index.json` merge (peer-independent) | M | S3, S5b, C4 |
| S8 | Shared `PDFs/` folder, open-in-place, stamp on import, portable paths, reversible migration | L | S1, S2, S3, P3 (= C7a) |
| S9 | Round-trip harness + two-peer offline conflict harness (`SyncthingSimulator`) | L | S1–S8 |

### Round 4 corrections (authoritative: where a sketch below disagrees, this wins)

Both agents cross-reviewed these items against the code. The sketches below are Neon's round-3 drafts; these
corrections override them.

- **S1/S2: extend the real types, don't replace them.** `WebStorageLayout` today stores `pretty` and `indexPath`
  and *computes* `positionsDir` (`WebStorage.swift:231–269`). `StorageAccess` is `.coordinated(container, root:)`
  and `StorageContext` is `.coordinated(container:layout:)` (`SyncedContainer.swift`). Add the `.syncedFolder`
  case and a separate backend selector to these shapes. Keep the direct-mode test root overrides
  (`PositionLayout.rootOverride`), the non-throwing `[PositionDeviceRecord]` load, and coordinated quarantine.
  Custom mode keeps positions local, as today. S2's sketch (`context.backend`, `[PositionLoadOutcome]`) doesn't
  match the code; implement it against the real `CoordinatedPositionStorage`.
- **S3: one implementation.** Promote the **existing** `PositionJSON` code verbatim, including its single-value
  decoder and encoder (`PositionModels.swift:529–589`), as `JSONValue` in Core, with `typealias PositionJSON = JSONValue`.
  The sketch's synthesized enum coding would wrap unknown values and change the wire format. Drop the `Decimal`
  claim (finite precision). C3 moves the type; S3 adopts it everywhere else.
- **S4: correct `.stignore` patterns.** Vellum's real temp names are `.{name}.tmp-{pid}-{uuid}`
  (`LibraryFileStore`, `PositionStorage`, `WebArchive`, `VellumBundle`), `.{name}.vellum-{uuid}.tmp`
  (`PdfAtomicWriter`) and `{name}.tmp` (`WebLibrary`, `DocumentDataStore`, `WebInkStore`). Managed block:
  `(?d).*.tmp-*`, `(?d).*.vellum-*.tmp`, `(?d)*.tmp`, plus OS clutter. Remove `(?d).vellum-tmp-*` (matches nothing).
  The writer is injected (Core can't instantiate the Apple `DirectLibraryFileStore`).
- **S5 is split.**
  - **S5a** filters `.sync-conflict-` and `.syncthing.*.tmp` names in `DirectLibraryFileStore.list`,
    `WebLibrary.recordFileNames`, `WebInkStore.inkFileNames` and the Linux read-only store. That is all the
    read-only Linux reader needs.
  - **S5b** builds the folder container. The file store and the watcher (inotify / FSEvents) are **injected
    protocols**. Conditional replace must be atomic under one per-path lock, and otherwise returns `false`, as the
    protocol's default already does. Losers are keyed by canonical path + version id (timestamp + peer alone can
    collide). Watch `.vellum/`, `PDFs/` and `Web Pages/`. Moving `PreserveLosersConflictResolver` into Core means
    injecting what it calls today: `WebLibrary.jsonEncoderPretty`, `WebArchive.mergeAnnotations`, and decoding
    `AiMessage` and `DocumentDataStore.Meta`. Replace `NSLog`. Ownership is settled: C5b moves `LibraryFileStore`;
    S5b moves `SyncedContainer`, the conflict types and the resolver. Apple storage implementations stay in the app.
- **S6: never auto-delete attachments in shared-folder mode.** Scanning conflict files can't protect an image that
  an offline peer already deleted before any conflict copy exists. So in shared-folder mode, unreferenced attachments
  are kept until an explicit, recoverable cleanup moves them to `.vellum/trash/` with a retention period. Directory
  enumeration failures abort cleanup (fail closed). Use real `URL`s, not `LibraryFileEntry`.
- **S7: archives are `.vellumweb` ZIP files**, and the index is `entries[key] → filename.vellumweb`
  (`WebStorage.swift:323–331`). There are no `.vellum/` directories with `manifest.json`. A same-title collision
  shows up as `Web Pages/<Title>.sync-conflict-….vellumweb`; read its manifest with `ArchiveCodec.readManifest` (C4).
  Filenames are a **peer-independent** function of (key, title): the lowest key keeps `<Title>.vellumweb`, others get
  `<Title> (<key prefix 6>).vellumweb`. Never prefer "the local winner", because that makes the result depend on
  which peer merges.
- **S8: use the real hooks, journal first.** Open-in-place extends the instance method `appOwnedRoots()` with the
  active, scoped `PDFs/` root, and keeps the separate managed-copy deletion check (`DocumentAccessResolver.swift:400–408,474–505`).
  The migrator **writes its journal before each mutation** and checks every `rekey` result before moving on. No
  stamping before P3 (= C7a) exists, because the PDFKit fallback would rewrite the file. Unstamped read-only PDFs use
  a validated embedded ID or `DocumentIdentity.byteHash(originalBytes)`.
- **S9: test the contract that ships.** The resolver deliberately archives the loser when annotation-ID or
  message-ID sets differ. So concurrent additions are **recoverable from the archived copy**, not unioned. Assert
  recovery from both the canonical and the archived version. Include: offline image deletion *before* any conflict
  sibling exists (reopen the image and compare bytes), and a `.vellumweb` same-title collision. Size raised to L.

### S1 — Decouple `WebStorageLayout.requiresCoordination` and add `.syncedFolder` mode

* **Goal**: Separate *on-disk layout* (`.vellum/` inside user-visible root vs flat `AppSupport`) from *sync backend* (iCloud `NSFileCoordinator` vs direct POSIX vs folder-sync container), add `.syncedFolder` to `WebStorageMode`, wire backend selection in `StorageCoordinator`, and expose the choice on macOS Settings.
* **Files changed**:
  * `Vellum/Services/Web/WebStorage.swift` (`WebStorageMode`, `WebStorageLayout`, `WebStorageLocation`)
  * `Vellum/Services/Sync/SyncedContainer.swift` (`StorageAccess`, `StorageAccessResolver`)
  * `Vellum/Services/Sync/StorageCoordinator.swift` (`Availability`, `DegradedReason`, `start()`/`refresh()`)
  * `Vellum/Platform/macOS/Restored/StorageSettingsTab_macOS.swift` (picker option + folder selection)
* **Code sketch**:
```swift
// Vellum/Services/Web/WebStorage.swift
enum WebStorageMode: String, CaseIterable, Equatable, Sendable {
    case local
    case icloud
    case custom
    case syncedFolder  // Syncthing / external folder sync; same .vellum/ layout as iCloud, no NSFileCoordinator
}

enum StorageBackendKind: String, Equatable, Sendable {
    case direct         // .local, .custom
    case icloud         // .icloud (NSFileCoordinator + NSMetadataQuery)
    case syncedFolder   // .syncedFolder (FolderSyncedContainer: direct POSIX + conflict watcher)
}

struct WebStorageLayout: Equatable, Sendable {
    let mode: WebStorageMode
    let backend: StorageBackendKind
    let rootDir: URL
    let recordsDir: URL
    let documentsDir: URL
    let positionsDir: URL
    let archivesDir: URL
    let pdfsDir: URL?               // <root>/PDFs for .syncedFolder (and optionally .icloud); nil for .local/.custom
    let indexURL: URL?
    let prettyArchiveNames: Bool

    /// True when records/documents/positions live under `<root>/.vellum/`.
    var storesMetadataInRoot: Bool {
        recordsDir.deletingLastPathComponent().lastPathComponent == ".vellum"
    }

    /// True ONLY when Apple NSFileCoordinator / NSMetadataQuery must mediate I/O.
    var requiresICloudCoordination: Bool { backend == .icloud }

    /// True when a SyncedContainer owns conflict discovery & recovery (iCloud OR syncedFolder).
    var usesSyncedContainer: Bool { backend == .icloud || backend == .syncedFolder }

    /// Deprecated alias during migration so call sites compile until audited.
    @available(*, deprecated, renamed: "requiresICloudCoordination")
    var requiresCoordination: Bool { requiresICloudCoordination }

    static func syncedFolder(root: URL) -> WebStorageLayout {
        let meta = root.appendingPathComponent(".vellum", isDirectory: true)
        return WebStorageLayout(
            mode: .syncedFolder,
            backend: .syncedFolder,
            rootDir: root,
            recordsDir: meta.appendingPathComponent("records", isDirectory: true),
            documentsDir: meta.appendingPathComponent("documents", isDirectory: true),
            positionsDir: meta.appendingPathComponent("positions", isDirectory: true),
            archivesDir: root.appendingPathComponent("Web Pages", isDirectory: true),
            pdfsDir: root.appendingPathComponent("PDFs", isDirectory: true),
            indexURL: meta.appendingPathComponent("index.json"),
            prettyArchiveNames: true
        )
    }
}
```
```swift
// WebStorageLayout.resolve(...)
case .syncedFolder:
    guard let root = syncedFolderRoot else { return .local(storeDir: storeDir) }
    return .syncedFolder(root: root)

// StorageAccessResolver.resolve(...)
case .syncedFolder:
    guard let layoutRoot = syncedFolderRoot else {
        return .unavailable(.syncedFolderUnavailable)
    }
    let layout = WebStorageLayout.syncedFolder(root: layoutRoot)
    let container = folderContainerFactory(layout) // returns FolderSyncedContainer (S5)
    return .coordinated(container: container, layout: layout)
```
```swift
// StorageSettingsTab_macOS.swift
// Add `.syncedFolder` ("Shared Folder (Syncthing)") radio/picker row beside iCloud & Custom Folder.
// Selecting it runs NSOpenPanel for a folder, writes security-scoped bookmark (macOS) under
// `vellum.storage.syncedFolderBookmark` + path fallback, triggers S4 `.stignore` ensure, and
// invokes WebStorageMigrator + S8 optional PDF migration sheet.
```
* **Tests**:
  * Reuse/extend: `Tests/WebStorageLocationTests.swift` (`testEffectiveModeDegradesToLocalWhenRootsMissing`, `testPrettyLayoutDirectories`), `Tests/SyncedContainerRoutingTests.swift` (`Only the iCloud mode resolves to a coordinated access` → update to assert `.icloud` uses iCloud container and `.syncedFolder` uses `FolderSyncedContainer`).
  * New tests:
    * `WebStorageLocationTests.testSyncedFolderLayoutMatchesICloudMetadataPathsWithoutICloudCoordination`
    * `SyncedContainerRoutingTests.testSyncedFolderResolvesToFolderSyncedContainerAndDoesNotTouchUbiquity`
    * `SyncedContainerRoutingTests.testMissingSyncedFolderRootDegradesToLocal`
* **Acceptance criteria**:
  * `WebStorageLayout.syncedFolder(root:)` produces `<root>/.vellum/{records,documents,positions,index.json}`, `<root>/Web Pages/`, `<root>/PDFs/`.
  * `requiresICloudCoordination == false` and `usesSyncedContainer == true` for `.syncedFolder`; `requiresICloudCoordination == true` ONLY for `.icloud`.
  * `WebStorageLayout.resolve` never calls `FileManager.url(forUbiquityContainerIdentifier:)` when mode is `.syncedFolder`.
  * macOS `StorageSettingsTab` lets user choose `.syncedFolder` and persists the root across relaunches.
* **Size**: `M`
* **Depends on**: `C1` *(core-extraction anchor for shared models)*; `FolderSyncedContainer` factory injected/stubbed until `S5`.
* **Risks**:
  * Existing call sites checking `layout.requiresCoordination` may actually mean "are records in `.vellum/`?" vs "do we use `NSFileCoordinator`?" vs "do we have a `SyncedContainer`?". Every call site must be audited (compiler deprecation warnings on `requiresCoordination` force complete audit).

---

### S2 — Fix `CoordinatedPositionStorage` honouring `layout.positionsDir` in `.direct` mode

* **Goal**: Fix the existing bug in `CoordinatedPositionStorage` (`Vellum/Services/Position/PositionStorage.swift`) where `.direct` ignores `context.layout.positionsDir` and writes to the hardcoded `PositionLayout.root` (`AppSupport/positions`).
* **Files changed**:
  * `Vellum/Services/Position/PositionStorage.swift`
* **Code sketch**:
```swift
// Vellum/Services/Position/PositionStorage.swift
func loadAll() async -> [PositionLoadOutcome] {
    await coordinator.withStorageContext { context in
        switch context.backend {
        case .direct:
            // BUG FIX: previously called FilePositionStorage() with default PositionLayout.root.
            return await FilePositionStorage(root: context.layout.positionsDir).loadAll()
        case .coordinated(let container):
            return await Self.loadAll(from: container, root: context.layout.positionsDir)
        }
    }
}

func write(_ record: PositionDeviceRecord) async throws {
    try await coordinator.withStorageContext { context in
        switch context.backend {
        case .direct:
            try await FilePositionStorage(root: context.layout.positionsDir).write(record)
        case .coordinated(let container):
            try await Self.write(record, to: container, root: context.layout.positionsDir)
        }
    }
}
```
* **Tests**:
  * Reuse/extend: `Tests/CoordinatedPositionStorageTests.swift`, `Tests/PositionSidecarIsolationTests.swift` (`The positions directory is a sibling of web/, never inside it`).
  * New tests:
    * `CoordinatedPositionStorageTests.testDirectModeUsesLayoutPositionsDirNotHardcodedRoot`
    * `CoordinatedPositionStorageTests.testCustomAndSyncedFolderWritePositionsInsideActiveLayoutRoot`
* **Acceptance criteria**:
  * In `.direct` mode with a custom `layout.positionsDir`, `CoordinatedPositionStorage.write` writes `<layout.positionsDir>/device-<id>.v1.json` and leaves `PositionLayout.root` untouched.
  * In `.coordinated` mode (both `.icloud` and `.syncedFolder`), positions live under `<root>/.vellum/positions/`.
* **Size**: `S`
* **Depends on**: None (independent fix; benefits `S1`).
* **Risks**:
  * Any test relying implicitly on `.direct` falling back to `PositionLayout.root` while passing a different `layout` will surface immediately; verify all `Position*Tests` pass.

---

### S3 — Unknown-field preservation across all shared `Codable` models

* **Goal**: Promote the existing lossless JSON bag `PositionJSON` (`Vellum/Services/Position/PositionModels.swift`) into a reusable `JSONValue` + `UnknownFields` helper in `VellumCore` and adopt it across every shared `Codable` type that Linux and Mac both read/write, preventing older clients from silently stripping fields written by newer clients.
* **Files changed**:
  * **New**: `Packages/VellumCore/Sources/VellumCore/Models/JSONValue.swift` (promoted from the existing `PositionJSON`; see Round 4 corrections)
  * `Vellum/Services/Position/PositionModels.swift` (`typealias PositionJSON = JSONValue`; add `unknownFields` to nested `ReadingPosition`, `OpenState`, `Stamped`)
  * `Vellum/Services/Web/WebLibrary.swift` (`WebPageRecord`, `WebAnnotation`, `WebAnchor` / nested structs — verify exact nested names during edit)
  * `Vellum/Services/Web/WebStorage.swift` (`WebArchiveIndex.Contents`)
  * `Vellum/Services/Web/WebArchive.swift` 
  * `Vellum/Services/Web/WebInkStore.swift` 
  * `Vellum/Services/DocumentDataStore.swift` (`DocumentDataStore.Meta`)
  * `Vellum/Stores/AiStore.swift` (`AiConversation`, `AiMessage`, `AiReference`)
  * `Vellum/Models/AiToolSummary.swift` (`AiToolSummary`, `AiToolSummary.Source`)
  * `Vellum/Services/Ai/AiUsage.swift` (`AiUsage`)
* **Complete shared `Codable` adoption list**:

| Shared File on Disk | `Codable` Types | Source File |
|---|---|---|
| `.vellum/positions/device-*.v1.json` | `PositionDeviceRecord`, `DocumentEntry` *(already done)*; add to `ReadingPosition`, `OpenState`, `Stamped` | `Vellum/Services/Position/PositionModels.swift` |
| `.vellum/records/<hash>.json` | `WebPageRecord`, `WebAnnotation` (+ anchor/rect sub-structs) | `Vellum/Services/Web/` (`WebModels.swift` / `WebLibrary.swift`) |
| `.vellum/records/<hash>.ink.json` | `WebInkRecord`, `WebInkRecord.Layout`, `Bounds`, `Anchor`, `Cluster` | `Vellum/Services/Web/WebInkStore.swift` (or `WebInkModels.swift`) |
| `.vellum/index.json` | `WebArchiveIndex.Contents` | `Vellum/Services/Web/WebStorage.swift` |
| `Web Pages/<name>.vellum/manifest.json` | `ArchiveManifest`, `ManifestAsset`, `ManifestHashes` | `Vellum/Services/Web/` *(verify exact file)* |
| `.vellum/documents/<key>/meta.json` | `DocumentDataStore.Meta` | `Vellum/Services/DocumentDataStore.swift` |
| `.vellum/documents/<key>/conversations.json` | `AiConversation`, `AiMessage`, `AiReference`, `AiToolSummary`, `AiToolSummary.Source`, `AiUsage` | `Vellum/Stores/AiStore.swift`, `Vellum/Models/AiToolSummary.swift`, `Vellum/Services/Ai/AiUsage.swift` |

* **Code sketch**:
```swift
// VellumCore/Models/JSONValue.swift (promoted verbatim from PositionJSON in PositionModels.swift:498-560)
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case decimal(Decimal)   // preserves arbitrary-precision integers & exact decimals
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public struct AnyCodingKey: CodingKey, Hashable {
        public let stringValue: String
        public let intValue: Int?
        public init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        public init?(intValue: Int) { self.stringValue = "\(intValue)"; self.intValue = intValue }
        public init(_ name: String) { self.stringValue = name; self.intValue = nil }
    }

    public static func decodeUnknownFields(
        from decoder: Decoder,
        knownKeys: Set<String>
    ) throws -> [String: JSONValue] {
        let raw = try decoder.container(keyedBy: AnyCodingKey.self)
        var extras: [String: JSONValue] = [:]
        for key in raw.allKeys where !knownKeys.contains(key.stringValue) {
            extras[key.stringValue] = try raw.decode(JSONValue.self, forKey: key)
        }
        return extras
    }

    public static func encodeUnknownFields(
        _ fields: [String: JSONValue],
        to encoder: Encoder,
        skipping knownKeys: Set<String>
    ) throws {
        guard !fields.isEmpty else { return }
        var raw = encoder.container(keyedBy: AnyCodingKey.self)
        for key in fields.keys.sorted() where !knownKeys.contains(key) {
            try raw.encode(fields[key]!, forKey: AnyCodingKey(key))
        }
    }
}

// Example adoption on DocumentDataStore.Meta:
struct Meta: Codable, Equatable, Sendable {
    var version: Int
    var kind: String
    var title: String?
    var lastKnownPath: String
    var lastOpened: String
    var unknownFields: [String: JSONValue] = [:]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case version, kind, title
        case lastKnownPath = "last_known_path"
        case lastOpened = "last_opened"
    }
    private static let knownKeys = Set(CodingKeys.allCases.map(\.rawValue))

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        lastKnownPath = try c.decode(String.self, forKey: .lastKnownPath)
        lastOpened = try c.decode(String.self, forKey: .lastOpened)
        unknownFields = try JSONValue.decodeUnknownFields(from: decoder, knownKeys: Self.knownKeys)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encode(lastKnownPath, forKey: .lastKnownPath)
        try c.encode(lastOpened, forKey: .lastOpened)
        try JSONValue.encodeUnknownFields(unknownFields, to: encoder, skipping: Self.knownKeys)
    }
}
```
* **Tests**:
  * Reuse/extend: `Tests/PositionWireFormatTests.swift` (`Unknown keys added by a future version survive decode`, `A future version's number too large for Int survives with every digit`), `Tests/AiReferencePersistenceTests.swift`, `Tests/DocumentDataStoreTests.swift`, `Tests/WebLibraryStorageTests.swift`.
  * New tests: `UnknownFieldsRoundTripTests` parameterized over every type in the table above (`decode → mutate known field → encode → verify unknown string, nested object, array, 64-bit int, and null survive verbatim`).
* **Acceptance criteria**:
  * Every shared `Codable` type in the table round-trips unknown top-level and nested keys without loss, including during conflict merges in `PreserveLosersConflictResolver` (merge preserves union of `unknownFields`, current wins on identical unknown key).
  * Zero regression on existing wire-format snapshot tests (`The encoded bytes match the documented example exactly`).
* **Size**: `M`
* **Depends on**: `C2` *(core-extraction anchor)* or can land in `Vellum/` first and move cleanly into `VellumCore`.
* **Risks**:
  * `Equatable` synthesis now includes `unknownFields`; ensure default `unknownFields: [String: JSONValue] = [:]` keeps all existing memberwise test initializers compiling.
  * `JSONSerialization` / `JSONEncoder` number representation differences between Apple Foundation and `swift-foundation` on Linux — must verify with `PositionWireFormatTests` under Linux Swift toolchain.

---

### S4 — Syncthing `.stignore` management

* **Goal**: Automatically ensure a safe `.stignore` at the shared library root when `.syncedFolder` is initialized or activated, excluding temp files, OS clutter, and local-only state without ever clobbering user-added rules.
* **Files changed**:
  * **New**: `Packages/VellumCore/Sources/VellumCore/Sync/StignoreManager.swift` (or `Vellum/Services/Sync/StignoreManager.swift`)
  * `Vellum/Services/Sync/StorageCoordinator.swift` (call on `.syncedFolder` activation / folder creation)
  * `Vellum/Platform/macOS/Restored/StorageSettingsTab_macOS.swift` (call when user selects a shared folder)
* **Code sketch**:
```swift
// VellumCore/Sync/StignoreManager.swift
public enum StignoreManager {
    public static let beginMarker = "# BEGIN VELLUM MANAGED - DO NOT EDIT THIS BLOCK"
    public static let endMarker   = "# END VELLUM MANAGED"

    /// Exact managed block. Note: `(?d)` allows Syncthing to delete ignored clutter
    /// when removing a directory so empty-dir deletes never stall sync.
    public static let managedLines: [String] = [
        beginMarker,
        "(?d).DS_Store",
        "(?d)._*",
        "(?d)Thumbs.db",
        "(?d)desktop.ini",
        "(?d)*.tmp",
        "(?d)*.tmp.*",
        "(?d).*.tmp*",
        "(?d).vellum-tmp-*",
        "(?d).vellum/cache",
        "(?d).vellum/locks",
        "(?d).vellum/local",
        "(?d).vellum/**/*.icloud",
        endMarker,
    ]

    /// Idempotent, atomic, non-destructive update of `<root>/.stignore`.
    /// - If absent: writes managed block.
    /// - If present with markers: replaces ONLY the lines between beginMarker..endMarker.
    /// - If present without markers: preserves all existing user lines verbatim and appends
    ///   a blank line + managed block (skipping if every managed rule is already present).
    /// - Does NOT rewrite the file if resulting bytes are identical (avoids spurious sync churn).
    @discardableResult
    public static func ensure(at libraryRoot: URL) throws -> Bool {
        let url = libraryRoot.appendingPathComponent(".stignore")
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = render(existing: existing)
        guard updated != existing else { return false }
        let data = Data(updated.utf8)
        try DirectLibraryFileStore().replace(url, with: data)
        return true
    }

    static func render(existing: String) -> String {
        let block = managedLines.joined(separator: "\n")
        if existing.isEmpty { return block + "\n" }
        let lines = existing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if let start = lines.firstIndex(of: beginMarker),
           let end = lines[start...].firstIndex(of: endMarker) {
            var out = Array(lines[..<start])
            out.append(contentsOf: managedLines)
            out.append(contentsOf: lines[(end + 1)...])
            let joined = out.joined(separator: "\n")
            return joined.hasSuffix("\n") ? joined : joined + "\n"
        }
        let trimmed = existing.hasSuffix("\n") ? existing : existing + "\n"
        return trimmed + "\n" + block + "\n"
    }
}
```
* **Tests**:
  * New tests (`StignoreManagerTests.swift`):
    * `testCreatesStignoreWhenMissing`
    * `testIdempotentSecondRunDoesNotRewriteMtime`
    * `testPreservesUserRulesBeforeAndAfterManagedBlock`
    * `testAppendsManagedBlockToPreexistingUserStignoreWithoutMarkers`
    * `testUpdatesManagedBlockInPlaceWhenRulesChange`
* **Acceptance criteria**:
  * Calling `StignoreManager.ensure(at:)` twice leaves file mtime/bytes untouched on the second call.
  * User lines above/below the sentinel block (or in a hand-authored `.stignore`) are preserved byte-for-byte.
  * Vellum's own atomic temp files (`*.tmp.*`, `.vellum-tmp-*`) and `.DS_Store` are matched by the managed rules.
* **Size**: `S`
* **Depends on**: `S1` (shared folder root lifecycle).
* **Risks**:
  * Syncthing intentionally does **not** sync `.stignore` between peers by default; therefore BOTH macOS and Linux must run `StignoreManager.ensure(at:)` on startup/activation of `.syncedFolder`.

---

### S5 — Sync-conflict filtering in all listing paths + `FolderSyncedContainer` with inotify/FSEvents watcher

* **Goal**:
  1. Exclude Syncthing conflict siblings (`*.sync-conflict-*`) and temp files (`*.syncthing.*.tmp`) in **every** directory listing path so conflict copies never appear as duplicate records, ink sidecars, or positions.
  2. Implement `FolderSyncedContainer: SyncedContainer` that discovers `*.sync-conflict-*` files via native filesystem watching (`inotify` on Linux, `FSEvents` / `DispatchSource` on macOS) plus a periodic/on-resume rescan fallback, translates them into `ConflictEvent`s, feeds `PreserveLosersConflictResolver`, and removes resolved `.sync-conflict-*` siblings once merged/archived.
* **Files changed**:
  * **New**: `Packages/VellumCore/Sources/VellumCore/Sync/SyncConflictNaming.swift` (parser & matcher for Syncthing `<stem>.sync-conflict-<YYYYMMDD>-<HHMMSS>-<PEERID>.<ext>`)
  * **New**: `Packages/VellumCore/Sources/VellumCore/Sync/FolderSyncedContainer.swift` (`actor FolderSyncedContainer: SyncedContainer`)
  * **New**: `Packages/VellumCore/Sources/VellumCore/Sync/DirectoryWatcher.swift` (`#if os(Linux)` recursive `inotify` watcher using `Glibc`, `#if os(macOS)` `FSEvents` wrapper, plus fallback timer)
  * `Vellum/Services/Sync/LibraryFileStore.swift` (`DirectLibraryFileStore.list(_:suffix:)`)
  * `Vellum/Services/Web/WebLibrary.swift` (`WebLibrary.recordFileNames(inDir:)`)
  * `Vellum/Services/Web/WebInkStore.swift` (`WebInkStore.inkFileNames(inDir:)`)
  * `Vellum/Services/Position/PositionStorage.swift` (`FilePositionStorage.loadAll()` — verify it skips `.sync-conflict-` via filename regex)
* **Code sketch**:
```swift
// VellumCore/Sync/SyncConflictNaming.swift
public enum SyncConflictNaming {
    // Matches Syncthing: "<base>.sync-conflict-20260410-142355-ABCDEFG.<ext>" or without ext
    public struct Parsed: Equatable, Sendable {
        public let canonicalName: String   // "<base>.<ext>" (or "<base>")
        public let versionID: String       // "sync-conflict-20260410-142355-ABCDEFG"
        public let timestamp: Date?
        public let peerID: String
    }

    public static func isSyncArtifact(_ fileName: String) -> Bool {
        fileName.contains(".sync-conflict-")
            || (fileName.hasPrefix(".syncthing.") && fileName.hasSuffix(".tmp"))
    }

    public static func parse(_ fileName: String) -> Parsed? {
        guard let range = fileName.range(of: ".sync-conflict-") else { return nil }
        let prefix = String(fileName[..<range.lowerBound])
        let rest = String(fileName[range.upperBound...])
        // Format of rest: YYYYMMDD-HHMMSS-PEERID[.ext...]
        // Split at first '.' after PEERID (if any).
        let parts = rest.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let token = String(parts[0]) // YYYYMMDD-HHMMSS-PEERID
        let segs = token.split(separator: "-")
        guard segs.count >= 3 else { return nil }
        let ext = parts.count == 2 ? "." + String(parts[1]) : ""
        return Parsed(
            canonicalName: prefix + ext,
            versionID: "sync-conflict-\(token)",
            timestamp: parseUTCStamp("\(segs[0])-\(segs[1])"),
            peerID: String(segs[2])
        )
    }
}
```
```swift
// Listing filter applied in ALL THREE listing paths:
// 1. DirectLibraryFileStore.list(_:suffix:) [LibraryFileStore.swift:101-162]
guard !SyncConflictNaming.isSyncArtifact(name) else { continue }
// 2. WebLibrary.recordFileNames(inDir:) [WebLibrary.swift:410-432]
guard !SyncConflictNaming.isSyncArtifact(name) else { continue }
// 3. WebInkStore.inkFileNames(inDir:) [WebInkStore.swift:651-665]
guard !SyncConflictNaming.isSyncArtifact(name) else { continue }
```
```swift
// VellumCore/Sync/FolderSyncedContainer.swift
public actor FolderSyncedContainer: SyncedContainer {
    private let root: URL
    private let fileStore: DirectLibraryFileStore
    private let resolver: any ConflictResolver
    private let watcher: any DirectoryWatcher
    private let rescanInterval: Duration
    private let conflictStream: AsyncStream<ConflictEvent>
    private let conflictContinuation: AsyncStream<ConflictEvent>.Continuation
    private var watchTask: Task<Void, Never>?
    private var fallbackTimerTask: Task<Void, Never>?
    private var inFlightCanonicals: Set<URL> = []

    // Maps ConflictVersion.id -> actual sibling URL on disk
    private var versionURLs: [String: URL] = [:]

    public nonisolated var conflicts: AsyncStream<ConflictEvent> { conflictStream }

    public func read<T: Sendable>(
        _ url: URL, materializing: Materialization, _ body: @Sendable (Data) throws -> T
    ) async throws -> T {
        try await SyncedContainerAccessor.guarded(url) {
            guard let data = try await self.fileStore.read(url) else {
                throw SyncedContainerError.notFound(url)
            }
            return try body(data)
        }
    }

    public func replace(_ url: URL, with data: Data) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            try await self.fileStore.replace(url, with: data)
        }
    }

    public func replace(_ url: URL, with data: Data, ifCurrent expected: Data?) async throws -> Bool {
        try await SyncedContainerAccessor.guarded(url) {
            // Serialized on actor; compare current bytes then atomic rename
            let current = try await self.fileStore.read(url)
            guard current == expected else { return false }
            try await self.fileStore.replace(url, with: data)
            return true
        }
    }

    public func remove(_ url: URL) async throws {
        try await SyncedContainerAccessor.guarded(url) {
            try await self.fileStore.remove(url)
        }
    }

    public func list(_ directory: URL, matching filter: SyncedItemFilter) async throws -> [SyncedItem] {
        // Uses DirectLibraryFileStore.list (which skips .sync-conflict-*) and wraps in SyncedItem(.current)
        ...
    }

    public func resolveConflict(_ event: ConflictEvent) async throws -> ConflictResolution {
        let resolution = try await resolver.resolve(event) { version in
            guard let url = await self.urlForVersion(version, canonical: event.url) else {
                throw SyncedContainerError.notFound(event.url)
            }
            return try Data(contentsOf: url)
        }
        switch resolution {
        case .merged, .keptCurrent:
            // Only remove the .sync-conflict-* sibling AFTER resolver confirmed archive/merge succeeded!
            for loser in event.losingVersions {
                if let siblingURL = versionURLs.removeValue(forKey: loser.id) {
                    try? FileManager.default.removeItem(at: siblingURL)
                }
            }
        case .deferred:
            break
        }
        inFlightCanonicals.remove(event.url.standardizedFileURL)
        return resolution
    }

    /// Walks `<root>/.vellum/{records,documents,positions,index.json}`, groups `*.sync-conflict-*`
    /// siblings by canonical URL, and yields one `ConflictEvent` per canonical URL with
    /// `currentVersion` = canonical file and `losingVersions` = sorted conflict siblings.
    func scanForConflicts(under dir: URL? = nil) async { ... }

    public func suspend() async {
        watchTask?.cancel(); fallbackTimerTask?.cancel()
        await watcher.stop()
    }

    public func resume() async {
        await watcher.start(root: root.appendingPathComponent(".vellum", isDirectory: true))
        await scanForConflicts()
        // Re-arm watch loop (debounced 250ms) + 60s periodic fallback rescan
    }
}
```
* **Tests**:
  * Reuse/extend: `Tests/LibraryFileStoreTests.swift`, `Tests/SyncedContainerConflictTests.swift` (run the same conflict test matrix against `FolderSyncedContainer` as well as fake iCloud container), `Tests/WebLibraryStorageTests.swift`.
  * New tests:
    * `SyncConflictNamingTests` (multi-dot names like `<hash>.ink.sync-conflict-20260410-120000-ABCD123.json` AND `<hash>.sync-conflict-20260410-120000-ABCD123.ink.json`, extensionless files, `.syncthing.*.tmp`)
    * `LibraryFileStoreTests.testDirectListExcludesSyncConflictAndSyncthingTmpFiles`
    * `WebLibraryStorageTests.testRecordAndInkListingExcludesSyncConflictFiles`
    * `FolderSyncedContainerTests.testDetectsInjectedSyncConflictAndArchivesLoser`
    * `FolderSyncedContainerTests.testDeferredResolutionLeavesSyncConflictSiblingOnDisk`
    * `FolderSyncedContainerTests.testFallbackRescanCatchesMissedWatcherEvents`
    * `FolderSyncedContainerTests.testNestedAccessThrowsNestedCoordination`
* **Acceptance criteria**:
  * Creating `foo.sync-conflict-20260410-120000-PEER123.json` in `records/`, `documents/<key>/`, or `positions/` NEVER causes duplicate entries in `DirectLibraryFileStore.list`, `WebLibrary.recordFileNames`, `WebInkStore.inkFileNames`, or `FilePositionStorage.loadAll`.
  * `FolderSyncedContainer` emits a `ConflictEvent` within ≤1s via watcher (or on `resume()` / fallback scan), routes through `PreserveLosersConflictResolver`, writes archive/merged output, and deletes the `.sync-conflict-*` sibling only on `.merged` or `.keptCurrent`.
  * Multi-dot filenames (`<hash>.ink.json` → Syncthing inserts `.sync-conflict-...` before the LAST dot: `<hash>.ink.sync-conflict-...json`) parse back to canonical `<hash>.ink.json`.
* **Size**: `L`
* **Depends on**: `S1`. First commit of S5 moves the `SyncedContainer` protocol, `ConflictEvent`/`ConflictVersion` and `PreserveLosersConflictResolver` into `VellumCore` (no layer-4 item does this), so the Linux adapter can reuse them.
* **Risks**:
  * **Syncthing multi-dot placement**: Syncthing inserts `.sync-conflict-<date>-<time>-<peer>` immediately before the *final* extension (e.g., `abc.ink.json` → `abc.ink.sync-conflict-20260410-120000-XYZ.json`), so `SyncConflictNaming.parse` MUST handle `prefix = "abc.ink"` + `ext = ".json"` → `"abc.ink.json"` cleanly!
  * **inotify watch limits on Linux**: Watching only `<root>/.vellum` (and dynamically adding `IN_CREATE | IN_ISDIR` watches for new `documents/<key>` dirs) keeps watch counts small (~O(number of documents)), avoiding `ENOSPC` on `fs.inotify.max_user_watches`; log warning and rely on 60s rescan fallback if `inotify_add_watch` returns `ENOSPC`.
  * **Partial write races**: Debounce watcher events (~250ms) and ignore `.syncthing.*.tmp` until Syncthing renames it into place.

---

### S6 — Attachment GC skips attachments referenced by conflict copies

* **Goal**: Prevent scratchpad attachment garbage collection from deleting images/snapshots that are unreferenced in the current `scratchpad.md` but still referenced in either archived conflicts (`documents/<key>/conflicts/scratchpad.*.md`) or uncollected Syncthing conflict siblings (`documents/<key>/scratchpad.sync-conflict-*.md`).
* **Files changed**:
  * `Vellum/Services/Scratchpad/ScratchpadPersistence.swift` (live prune around lines 199–214 AND legacy `ScratchpadAttachmentStore.collectGarbage` around lines 655–670)
* **Code sketch**:
```swift
// Vellum/Services/Scratchpad/ScratchpadPersistence.swift
/// Collects every `attachments/<name>` filename referenced by:
/// 1. `committed` (current scratchpad.md),
/// 2. any archived conflict under `<docDir>/conflicts/scratchpad.*.md`,
/// 3. any uncollected Syncthing conflict sibling `<docDir>/scratchpad.sync-conflict-*.md`.
/// If a conflict file cannot be read (e.g., iCloud placeholder not yet downloaded),
/// returns `nil` to signal GC MUST abort rather than risk deleting a live attachment.
static func protectedAttachmentNames(
    committedMarkdown: String,
    docDir: URL,
    fileStore: any LibraryFileStore
) async -> Set<String>? {
    var keep = ScratchpadAttachmentStore.referencedFileNames(in: committedMarkdown)

    // (a) Uncollected Syncthing conflict siblings directly inside docDir
    if let siblingNames = try? FileManager.default.contentsOfDirectory(atPath: docDir.path) {
        for name in siblingNames where name.hasPrefix("scratchpad.sync-conflict-") && name.hasSuffix(".md") {
            let url = docDir.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                return nil // conservative: fail closed
            }
            keep.formUnion(ScratchpadAttachmentStore.referencedFileNames(in: text))
        }
    }

    // (b) Archived conflicts under docDir/conflicts/
    let conflictsDir = docDir.appendingPathComponent("conflicts", isDirectory: true)
    do {
        let items = try await fileStore.list(conflictsDir, suffix: ".md")
        for item in items where item.lastPathComponent.hasPrefix("scratchpad.") {
            guard let data = try await fileStore.read(item),
                  let text = String(data: data, encoding: .utf8) else {
                return nil // fail closed if placeholder / unreadable
            }
            keep.formUnion(ScratchpadAttachmentStore.referencedFileNames(in: text))
        }
    } catch let error as LibraryFileError {
        if case .notDownloaded = error { return nil }
    } catch {
        // Directory absent is normal; any other error fails closed
        if FileManager.default.fileExists(atPath: conflictsDir.path) { return nil }
    }

    return keep
}
```
* **Tests**:
  * Reuse/extend: `Tests/ScratchpadImportTests.swift`, `Tests/SafeClearTests.swift`.
  * New tests (`ScratchpadAttachmentGCTests.swift`):
    * `testPruneRetainsAttachmentReferencedOnlyByArchivedConflict`
    * `testPruneRetainsAttachmentReferencedOnlyByUncollectedSyncConflict`
    * `testPruneDeletesAttachmentAfterConflictArchiveIsDeleted`
    * `testPruneAbortsConservativelyWhenConflictArchiveIsUnreadable`
* **Acceptance criteria**:
  * Editing `scratchpad.md` to remove an image link does NOT delete `attachments/<id>.png` if any `conflicts/scratchpad.*.md` or `scratchpad.sync-conflict-*.md` still references it.
  * Once the user deletes the conflict archive via `StorageCoordinator.deleteArchivedConflict`, the next prune cleans up the unreferenced attachment.
* **Size**: `S`
* **Depends on**: `S5` (uses `SyncConflictNaming` conventions; safe to implement right after or in parallel with `S5`).
* **Risks**:
  * Deleting an archived conflict via `StorageCoordinator.deleteArchivedConflict` won't immediately trigger a scratchpad save; optionally trigger a deferred prune pass after `deleteArchivedConflict` if disk reclamation is desired immediately.

---

### S7 — Pretty-name collision & `index.json` concurrent-update rule

* **Goal**: Make `Web Pages/<pretty>.vellum` naming and `.vellum/index.json` deterministic and lossless when two offline peers archive different pages with the same title (or edit `index.json` concurrently).
* **Files changed**:
  * `Vellum/Services/Sync/ConflictResolver.swift` (`PreserveLosersConflictResolver`: add `mergeIndexJson`, plus archive-loser-before-merge option/safety)
  * `Vellum/Services/Web/WebStorage.swift` (`WebArchiveIndex`: collision disambiguation + self-healing repair against on-disk `Web Pages/`)
  * `Vellum/Services/Web/WebLibrary.swift` (resolve archive path with fallback scan when `index.json` lags behind a synced bundle)
* **Code sketch**:
```swift
// ConflictResolver.swift — PreserveLosersConflictResolver
// Rule 1: `index.json` concurrent-update merge
// Structure of WebArchiveIndex.Contents: { version: Int, byHash: [urlHash: prettyName], unknownFields }
private func mergeArchiveIndex(
    _ event: ConflictEvent,
    reading: @Sendable (ConflictVersion) async throws -> Data
) async throws -> Data? {
    guard let currentVersion = event.currentVersion else { return nil }
    let decoder = JSONDecoder()
    guard var merged = try? decoder.decode(WebArchiveIndex.Contents.self, from: try await reading(currentVersion))
    else { return nil }

    // Collect every (hash -> candidatePrettyName) across current + all losers
    var allByHash: [String: Set<String>] = merged.byHash.mapValues { [$0] }
    for loser in event.losingVersions {
        guard let other = try? decoder.decode(WebArchiveIndex.Contents.self, from: try await reading(loser))
        else { return nil } // fail safe -> preserve losers
        for (hash, name) in other.byHash {
            allByHash[hash, default: []].insert(name)
        }
        for (k, v) in other.unknownFields where merged.unknownFields[k] == nil {
            merged.unknownFields[k] = v
        }
    }

    // Rule 2: Deterministic pretty-name collision resolution:
    // - If one hash has two names, pick the one whose bundle exists on disk (or lexicographically smallest).
    // - If TWO DIFFERENT hashes claim the SAME pretty name (offline same-title capture):
    //   Sort colliding hashes lexicographically; the lowest hash keeps "<Name>",
    //   every other hash is deterministically reassigned "<Name> (<hash.prefix(6)>)"
    //   and its conflicting bundle directory (if present as a sibling or mismatch) is reconciled on load.
    var resolved: [String: String] = [:]
    var ownerByLowerName: [String: String] = [:] // lowercased name -> winning hash
    for hash in allByHash.keys.sorted() {
        let preferred = (merged.byHash[hash] ?? allByHash[hash]!.sorted().first!)
        let lower = preferred.lowercased()
        if ownerByLowerName[lower] == nil {
            resolved[hash] = preferred
            ownerByLowerName[lower] = hash
        } else {
            let disambiguated = "\(preferred) (\(hash.prefix(6)))"
            resolved[hash] = disambiguated
            ownerByLowerName[disambiguated.lowercased()] = hash
        }
    }
    merged.byHash = resolved
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(merged)
}

// Archive-even-on-merge safety (recommended by 01-shared-library.md §Conflict Handling):
// Before returning `.merged(event.url)` for web records / conversations / meta / index.json,
// optionally write losing versions to `<dir>/conflicts/` (auto-marked reviewed, or guarded by
// a `preserveLosersOnMerge: Bool = true` flag) so no merge bug can ever cause silent data loss.
```
```swift
// WebStorage.swift — WebArchiveIndex.assignName collision rule for NEW captures in .syncedFolder:
// When two peers archive distinct URLs with identical sanitized title "Attention Is All You Need",
// the first peer gets "Attention Is All You Need.vellum" and if a bundle already exists on disk
// whose `manifest.json` has a DIFFERENT `urlHash`, immediately disambiguate using deterministic
// short hash suffix: "Attention Is All You Need (<urlHash.prefix(6)>).vellum" instead of numeric
// " (2)" so both peers converge on identical names without bouncing.
```
* **Tests**:
  * Reuse/extend: `Tests/ConflictMergeTests.swift`, `Tests/WebStorageLocationTests.swift` (`testIndexAssignsStableUniqueNames`).
  * New tests:
    * `ConflictMergeTests.testIndexJsonMergeUnionsDisjointCaptures`
    * `ConflictMergeTests.testIndexJsonMergeDisambiguatesSameTitleCollisionDeterministicallyByHash`
    * `ConflictMergeTests.testIndexJsonMergeIsCommutativeRegardlessOfWinnerOrder`
    * `WebStorageLocationTests.testPrettyBundleCollisionUsesHashSuffixWhenManifestDiffers`
* **Acceptance criteria**:
  * Peer A and Peer B capturing different pages with disjoint titles offline → `index.json` merges to contain both hashes cleanly.
  * Peer A and Peer B capturing different pages with the *exact same title* offline → both peers compute the exact same `byHash` mapping after conflict merge (commutative & deterministic), and neither `.vellum` bundle overwrites the other's `manifest.json` silently.
  * Unparseable `index.json` conflict falls back to preserving losers verbatim.
* **Size**: `M`
* **Depends on**: `S3`, `S5`.
* **Risks**:
  * If Syncthing syncs both peers' `Web Pages/Same Title.vellum/manifest.json` into the *same* bundle directory before `index.json` merges, Syncthing creates `manifest.sync-conflict-*.json` inside the bundle. Mitigation: in `.syncedFolder` mode, when `WebLibrary` opens a bundle and detects `manifest.json` `urlHash != expectedHash` (or `manifest.sync-conflict-*` inside a `.vellum` dir), relocate the mismatched bundle to `<title> (<hash.prefix(6)>).vellum` and update `index.json`.

---

### S8 — Shared `PDFs/` folder, Mac open-in-place, stamp-on-import, root-relative `lastKnownPath`, & reversible library migration

* **Goal**: Make PDFs first-class synced citizens under `<sharedRoot>/PDFs/`:
  1. Bypass Mac's copy-into-`AppSupport/Library` for PDFs already inside `<sharedRoot>/PDFs/` (open-in-place) without risking `removePreviousLibraryCopyIfNeeded` deleting user PDFs.
  2. Stamp `/VellumDocId` eagerly on import into `<sharedRoot>/PDFs/` (fallback to SHA-256 byte hash if read-only/unsupported PDF per `P3`) so Mac and Linux share one canonical `storageKey`.
  3. Store root-relative `lastKnownPath` (e.g., `PDFs/Papers/attention.pdf`) in `DocumentDataStore.Meta` for PDFs inside the shared library root, resolving against active `layout.rootDir` on load across macOS (`/Users/...`) and Linux (`/home/...`).
  4. Provide a reversible migration flow that moves/copies an existing Mac library's PDFs into `<sharedRoot>/PDFs/`, stamps them, and atomically rekeys `meta.json`, `scratchpad.md`, `conversations.json`, `attachments/`, AND `PositionDeviceRecord` entries from old path-hash keys to stamped `docId` keys.
* **Files changed**:
  * `Vellum/Services/DocumentAccessResolver.swift` (`isAppOwnedURL` / `isSharedLibraryPDFURL`, `localReadableURL`, `resolvePathForMeta`)
  * `Vellum/Services/DocumentDataStore.swift` (`Meta` root-relative path encode/resolve helpers, `rekey` integration)
  * `Vellum/Services/DocumentIdentity.swift` (helper for shared-root-relative path normalization)
  * `Vellum/Services/Position/PositionStore.swift` *(add `rekeyDocument(from:to:)`)*
  * **New**: `Vellum/Services/Sync/SharedLibraryPdfMigrator.swift` (stamp + copy-to-`PDFs/` + atomic rekey + rollback journal)
* **Code sketch**:
```swift
// 1. DocumentAccessResolver.swift — Open-in-place bypass on Mac
// CRITICAL INVARIANT: `removePreviousLibraryCopyIfNeeded` (line 366) checks `isManagedLibraryURL`
// (AppSupport/Library ONLY). We add `isSharedLibraryPDFURL(_:)` to `isAppOwnedURL(_:)` so
// `localReadableURL(for:access:)` (line 326) opens in place WITHOUT copying into AppSupport,
// while `isManagedLibraryURL(_:)` stays FALSE so relink/cleanup NEVER deletes a shared PDF!
static func isSharedLibraryPDFURL(_ url: URL, layout: WebStorageLayout = WebStorageLocation.activeLayout()) -> Bool {
    guard let pdfsDir = layout.pdfsDir else { return false }
    let standardized = url.standardizedFileURL.resolvingSymlinksInPath().path
    let rootPath = pdfsDir.standardizedFileURL.resolvingSymlinksInPath().path
    return standardized == rootPath || standardized.hasPrefix(rootPath + "/")
}

static func isAppOwnedURL(_ url: URL) -> Bool {
    if isSharedLibraryPDFURL(url) { return true }
    // ... existing appOwnedRoots() check ...
}
```
```swift
// 2. DocumentDataStore.swift — Root-relative `lastKnownPath`
extension DocumentDataStore {
    /// Serializes `<sharedRoot>/PDFs/sub/doc.pdf` as `"PDFs/sub/doc.pdf"` (POSIX `/` separators).
    /// Paths outside the active shared root remain absolute as before.
    static func portableLastKnownPath(for url: URL, layout: WebStorageLayout) -> String {
        guard layout.pdfsDir != nil else { return url.standardizedFileURL.path }
        let rootPath = layout.rootDir.standardizedFileURL.resolvingSymlinksInPath().path
        let filePath = url.standardizedFileURL.resolvingSymlinksInPath().path
        if filePath.hasPrefix(rootPath + "/") {
            return String(filePath.dropFirst(rootPath.count + 1))
        }
        return filePath
    }

    /// Resolves a stored `lastKnownPath` back to a local filesystem URL.
    static func resolveLastKnownPath(_ stored: String, layout: WebStorageLayout) -> URL {
        if !stored.hasPrefix("/") {
            return layout.rootDir.appendingPathComponent(stored).standardizedFileURL
        }
        return URL(fileURLWithPath: stored).standardizedFileURL
    }
}
```
```swift
// 3. SharedLibraryPdfMigrator.swift — Stamp-on-import + reversible migration
struct SharedLibraryMigrationPlan: Sendable {
    struct Entry: Sendable {
        let oldStorageKey: String      // path-hash or existing docId
        let sourceURL: URL
        let destinationURL: URL        // <sharedRoot>/PDFs/<uniqueName>.pdf
    }
    let entries: [Entry]
}

struct SharedLibraryMigrationManifest: Codable, Sendable {
    struct Record: Codable, Sendable {
        let oldKey: String
        let newKey: String
        let oldAbsolutePath: String
        let newRelativePath: String
        let stampedNewDocId: Bool
    }
    let createdAt: Date
    var records: [Record]
}

enum SharedLibraryPdfMigrator {
    /// Copies (does not delete source during forward migration -> reversible!),
    /// stamps `/VellumDocId` on the destination PDF (via PdfMetadata.stampDocumentId;
    /// falls back to byteHash key if P3 classifies PDF as non-writable),
    /// rekeys DocumentDataStore (meta, scratchpad, conversations, attachments) + PositionStore,
    /// updates Meta.lastKnownPath to portable relative path, and writes a rollback manifest.
    static func migrate(
        plan: SharedLibraryMigrationPlan,
        layout: WebStorageLayout,
        coordinator: StorageCoordinator,
        positionStore: PositionStore
    ) async throws -> SharedLibraryMigrationManifest {
        // For each entry:
        // 1. Copy sourceURL -> destinationURL (unique filename if collision)
        // 2. let stampedId = try? stampIfEligible(destinationURL)
        // 3. let newKey = stampedId ?? DocumentIdentity.byteHashKey(for: destinationURL)
        // 4. If oldKey != newKey:
        //      try await DocumentDataStore.rekey(from: oldKey, to: newKey, coordinator: coordinator)
        //      await positionStore.rekey(from: .pdf(oldKey), to: .pdf(newKey))
        // 5. Update Meta.lastKnownPath = portableLastKnownPath(for: destinationURL, layout: layout)
        // 6. Append Record to rollback manifest stored locally in AppSupport (NOT synced!)
    }

    /// Reverses migration using the local manifest: restores old keys & absolute paths,
    /// leaving original source files intact.
    static func rollback(
        manifest: SharedLibraryMigrationManifest,
        coordinator: StorageCoordinator,
        positionStore: PositionStore
    ) async throws { ... }
}
```
* **Tests**:
  * Reuse/extend: `Tests/DocumentAccessBookmarkStoreTests.swift` (`Picked external PDFs are copied local before open and picker scope closes`, `Relink validates identity and commits metadata plus bookmark`), `Tests/DocumentIdentityTests.swift` (`testEnsureDocumentIdIdempotentAndWritesOnce`), `Tests/DocumentDataStoreTests.swift`, `Tests/DocumentsRelocationTests.swift`.
  * New tests:
    * `DocumentAccessBookmarkStoreTests.testSharedLibraryPdfOpensInPlaceWithoutCopyingToAppSupport`
    * `DocumentAccessBookmarkStoreTests.testRelinkNeverDeletesSharedLibraryPdf`
    * `DocumentDataStoreTests.testPortableLastKnownPathRoundTripsAcrossDifferentRootPrefixes`
    * `SharedLibraryPdfMigratorTests.testMigrationStampsRekeysAllDataAndPositions`
    * `SharedLibraryPdfMigratorTests.testMigrationFallsBackToByteHashForEncryptedPdf`
    * `SharedLibraryPdfMigratorTests.testRollbackRestoresOriginalKeysAndPaths`
* **Acceptance criteria**:
  * Opening `<sharedRoot>/PDFs/paper.pdf` on macOS opens that exact file in place (no duplicate in `AppSupport/Library`).
  * Importing an external PDF into the shared library copies it to `<sharedRoot>/PDFs/`, stamps `/VellumDocId` if eligible, and writes `last_known_path: "PDFs/<name>.pdf"`.
  * Opening the same synced library at `/home/alice/Vellum` on Linux resolves `"PDFs/<name>.pdf"` to `/home/alice/Vellum/PDFs/<name>.pdf` and finds the exact same `documents/<docId>/` scratchpad, conversations, attachments, and reading position.
  * Migration + rollback leaves every note, attachment, conversation, and reading position intact with zero orphans.
* **Size**: `L`
* **Depends on**: `S1`, `S2`, `S3`, `P3` (eligibility check for stamp-on-import; can use existing `PdfMetadata.stampDocumentId` fallback until `P3` lands).
* **Risks**:
  * **Key stability for read-only/encrypted/signed PDFs**: If a PDF cannot be stamped with `/VellumDocId`, falling back to `DocumentIdentity.byteHash(of:)` (SHA-256 of PDF bytes, already implemented in `DocumentIdentity.swift`) produces the *same* key on Mac and Linux, whereas path-hash would diverge across OS prefixes! Note: if a user later decrypts/modifies that PDF externally, its byte hash changes — relink recovers it via existing `DocumentDataStore.rekey`.
  * **Security-scoped bookmarks on macOS**: The user grants folder access to `<sharedRoot>` once (stored as a folder bookmark in `S1`); child files inside `<sharedRoot>/PDFs/` are covered by that folder scope without per-file bookmarks.

---

### S9 — Cross-platform round-trip & two-peer offline conflict test harnesses

* **Goal**: Build two automated integration harnesses verifying the full shared-library contract:
  1. **Mac → Linux → Mac round-trip harness** (runs on macOS + Linux container via colima, verifying JSON wire compatibility, unknown-field preservation, portable paths, and position merge).
  2. **Two-peer offline conflict harness** (deterministic, zero-daemon Syncthing conflict simulator that runs in CI in <2s, plus an optional `VELLUM_SYNCTHING_E2E=1` containerized test running two real Syncthing instances via colima).
* **Files changed**:
  * **New**: `Tests/CrossPlatformRoundTripTests.swift` (runs on both macOS and Linux SwiftPM test targets)
  * **New**: `Tests/TwoPeerOfflineConflictTests.swift` (deterministic Syncthing simulator + conflict assertions)
  * **New**: `Tests/TestSupport/SyncthingSimulator.swift` (pure-Swift two-directory sync engine implementing Syncthing's exact conflict naming & `.stignore` filtering)
  * **New**: `Linux/scripts/roundtrip-e2e.sh` (optional colima script: Mac writes library → Linux container reads/mutates/writes → Mac reads/verifies; optionally spins up 2 Syncthing containers)
* **Code sketch**:
```swift
// Tests/TestSupport/SyncthingSimulator.swift
/// Deterministic, in-process 2-peer folder syncer matching Syncthing semantics:
/// - Respects `.stignore` patterns at each peer root
/// - Syncs disjoint changes both ways
/// - When both peers modified the same relative path since last sync snapshot:
///   higher mtime (tie-break: lexicographically higher peerID) becomes canonical,
///   loser is written as `<stem>.sync-conflict-<YYYYMMDD>-<HHMMSS>-<LOSER_PEERID><ext>` on BOTH peers.
struct SyncthingSimulator {
    struct Peer {
        let id: String   // e.g. "MACPEER", "LNXPEER"
        let root: URL
    }

    let peerA: Peer
    let peerB: Peer
    private var lastSyncedDigest: [String: Data] = [:] // relativePath -> SHA256

    mutating func sync(clock: Date = .now) throws -> SyncReport {
        // 1. Enumerate non-ignored files in peerA and peerB
        // 2. For each relative path:
        //    - Changed on one side only -> copy to other side, update lastSyncedDigest
        //    - Changed on BOTH sides with different bytes ->
        //        emit canonical winner + `<stem>.sync-conflict-<stamp>-<loserId><ext>` on both peers
        //    - Deleted on one side, modified on other -> keep modified (Syncthing rule)
    }
}
```
```swift
// Tests/TwoPeerOfflineConflictTests.swift — Test scenarios covered deterministically:
// 1. Concurrent web annotation edits on same WebPageRecord -> both annotations preserved after merge
// 2. Concurrent scratchpad.md edits where peer A deletes an image still referenced by peer B ->
//    conflict preserved under conflicts/ AND attachment NOT deleted by GC (verifies S5 + S6 together!)
// 3. Concurrent conversations.json edits -> union of conversations preserved
// 4. Concurrent meta.json edits -> newest path + non-empty title preserved + unknownFields preserved
// 5. Concurrent index.json + same-title web captures -> deterministic hash-suffixed resolution (verifies S7!)
// 6. Concurrent reading position updates -> separate device-<id>.v1.json files => ZERO conflicts, LWW merge
// 7. Future-version unknown fields injected by Peer B survive Peer A's read-modify-write (verifies S3!)
```
* **Tests**:
  * Reuse/extend: `Tests/PositionMergeTests.swift`, `Tests/ConflictMergeTests.swift`, `Tests/SyncedContainerConflictTests.swift`.
  * New tests:
    * `CrossPlatformRoundTripTests.testMacWritesLinuxMutatesMacReadsAllArtifactClasses`
    * `TwoPeerOfflineConflictTests.testWebAnnotationsMergeWithoutDataLoss`
    * `TwoPeerOfflineConflictTests.testScratchpadConflictProtectsAttachmentsFromGC`
    * `TwoPeerOfflineConflictTests.testIndexJsonSameTitleCollisionConverges`
    * `TwoPeerOfflineConflictTests.testPerDevicePositionsNeverConflictAcrossOfflinePeers`
    * `TwoPeerOfflineConflictTests.testUnknownFieldsSurviveCrossPeerRoundTrip`
    * `TwoPeerOfflineConflictTests.testRealSyncthingRoundTrip` (gated on `VELLUM_SYNCTHING_E2E=1`)
* **Acceptance criteria**:
  * Deterministic conflict suite runs via `swift test` on both macOS and Linux in <5 seconds with zero external daemons required.
  * Round-trip script executes end-to-end inside colima Linux container and exits 0 with byte/semantic equality verified on Mac after Linux mutations.
* **Size**: `M`
* **Depends on**: `S1`, `S2`, `S3`, `S4`, `S5`, `S6`, `S7`, `S8`.
* **Risks**:
  * Real-Syncthing E2E test can be flaky if polling timeouts are too tight; keep it opt-in (`VELLUM_SYNCTHING_E2E=1`) with deterministic `SyncthingSimulator` as the required CI gate.
