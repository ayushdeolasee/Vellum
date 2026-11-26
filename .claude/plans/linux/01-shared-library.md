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
  never depends on a path. When stamping fails (read-only, encrypted or signed files), fall back to
  a hash of the **root-relative** path. Today's fallbacks are an absolute-path hash and, for
  read-only PDFs, a byte hash. Both are reconciled in the migration below.
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

1. **Never drop unknown fields.** Today none of `WebPageRecord`, `WebInkRecord`, the document
   metadata or `PositionDeviceRecord` preserve unknown keys. This must ship on Mac **and** iPad
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
