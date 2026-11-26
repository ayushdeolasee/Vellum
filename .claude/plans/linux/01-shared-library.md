# Layer 2 — The shared library

Decides: where the library both machines use lives, how changes travel between
them, and the on-disk format contract both apps must obey.

Depends on: D3 (Mac and Linux share the same library).

## Question

Linux cannot reach iCloud. How do a Mac and a Linux machine read and write one
Vellum library without corrupting it or silently dropping each other's data?

## What exists today

- **Three storage modes on the Mac**: local, custom folder, iCloud. They all sit behind
  `StorageCoordinator` → `LibraryFileStore` (`DirectLibraryFileStore` for local/custom,
  the coordinated store for iCloud) and the 8-member `SyncedContainer` seam
  (`Vellum/Services/Sync/SyncedContainer.swift`).
- **Writes are already sync-friendly**: tmp-file + `rename(2)` atomic replace everywhere
  (`DocumentDataStore`, `WebLibrary.saveRecord`, `PdfAtomicWriter`).
- **Per-document folders** (`DocumentDataStore`): `documents/<storageKey>/meta.json`,
  `scratchpad.md`, `attachments/`. One small file per concern, which keeps conflicts small.
- **Positions are per-device files** (`positions/<device>.v<N>.json`, merged by `PositionMerge`).
  Two devices never write the same file, so this part never conflicts.
- **Custom-folder mode does not share most of the library today.** Only iCloud mode puts
  `records/`, `documents/` and `positions/` under the library root
  (`WebStorageLayout.resolve`, `recordsInRoot: true`). Custom mode passes
  `recordsInRoot: false`, so only `Web Pages/` and `.vellum/index.json` live in the chosen
  folder. Notes, scratchpads, conversations and positions stay in Application Support.
  **Pointing Syncthing at a custom folder today would sync almost nothing that matters.**
- **Conflicts today are iCloud-shaped**: `ConflictResolver` reacts to `NSFileVersion`
  conflict events. Folder-sync tools signal conflicts differently (extra files with a
  marker in the name), which nothing in Vellum recognises yet.

## Options for carrying the library

| Option | How it works | Good | Bad |
|---|---|---|---|
| **Syncthing** (recommended) | Peer-to-peer folder sync between the Mac and Linux; both apps use custom-folder mode | No server, no account, works offline and over Tailscale/LAN, open source, conflict copies are plain files we can detect | Both machines must be online at the same time to sync; another tool to run |
| Dropbox / similar | Cloud folder client on each machine | Always-on relay, mobile access | Proprietary client on Linux; same conflict-copy behaviour; privacy |
| NAS / SMB share | Both apps open the same network folder live | One copy of the truth, no conflicts by design | Breaks offline; network-filesystem locking and `rename` semantics are unreliable; slow PDFs |
| Own sync server | Vellum talks to a service we run | Full control, real merges | Far too big for personal use; revisit only for public release |

**Recommendation:** Syncthing, with a new **shared-folder** storage mode on both apps that uses the
iCloud layout (`recordsInRoot: true`) inside any plain folder.
iCloud stays available on Apple devices, but anything shared with Linux lives in the
Syncthing folder.

## The format contract (both apps must obey)

Two different apps now write the same files. These rules become a written,
versioned contract (`docs/library-format.md` when implemented) and a test suite in
`VellumCore` that both platforms run.

1. **Never drop unknown fields.** Swift `Codable` silently deletes keys it does not
   know when it re-saves a file. The codebase already hit this (see the comment at
   `WebInkStore.swift:6-10`). Every shared JSON type must round-trip unknown keys
   (for example, keep a `[String: JSONValue]` "extras" bag and re-emit it).
2. **Every shared file carries a format version.** A reader that sees a *newer* major
   version opens it read-only and says so; it never rewrites it.
3. **Atomic writes only** (tmp + rename, tmp files named so sync tools ignore them).
4. **One writer per file where possible.** Prefer per-device files (like positions)
   over shared ones for anything written often.
5. **Conflict copies are data, not garbage.** The adapter detects sync-tool conflict
   copies, surfaces them through the existing conflict UI, and never deletes them silently
   (CLAUDE.md: destructive actions must be recoverable or confirmed).
6. **PDF files are shared bytes.** Annotation writes on Linux must produce files the
   Mac reads identically, and vice versa (layer 3 owns how).
7. **Derived caches are per-device.** Page-text caches, thumbnails and search indexes are
   rebuilt locally and kept out of the synced folder, because each platform's PDF engine
   extracts text slightly differently.

## Files in the library, and their risk under folder sync

| Path | Writer pattern | Risk | Rule |
|---|---|---|---|
| `positions/<device>.v<N>.json` | One device per file | None | Keep as is |
| `documents/<key>/meta.json` | Any device, rarely | Low | Unknown-field round-trip; conflict copy → merge by newest field |
| `documents/<key>/scratchpad.md` | Any device, every keystroke | **Medium**: two machines editing the same note offline | Detect conflict copies; show both versions |
| `documents/<key>/attachments/*` | Append-only, unique IDs | Low | Keep as is |
| Web records `<key>.json`, `<key>.vellumweb` | Any device | Low/medium | Unknown-field round-trip |
| `<key>.ink.json` | Any device | Medium | Covered by `04-ink.md` |
| PDFs (annotations inside the file) | Any device, whole-file rewrite | **High**: a rewrite on one side while the other side also edits → one side's annotations lost | Detect conflict copies; layer 3 checks whether incremental saves shrink the risk |
| AI conversations | Any device | Medium | Same rule as `meta.json` |
| Page-text caches | Derived, per device | None today: already in the per-device Caches directory (`PageTextCache.defaultDirectory`) | Keep it that way on Linux (`$XDG_CACHE_HOME`) |

## Identity risk: same PDF, two paths

A PDF that has not been stamped with `/VellumDocId` yet is identified by a hash of its
path (`DocumentIdentity`). The Syncthing folder will sit at different absolute paths on the
Mac and on Linux, so one unstamped PDF gets **two different identities**, and its
notes, scratchpad and conversations split in two.

Rules:
- Stamp `/VellumDocId` on import into the shared library (Vellum already stamps on first
  write in `PdfSessionBackend.writeAndRefreshCache`), so identity never depends on the path.
  For read-only PDFs that can't be stamped, hash the path **relative to the library root**.
- Until the cross-platform round-trip test passes, **only one machine writes** to the
  shared library at a time. Linux starts read-only (layer 4, step 5).

## What Syncthing needs from Vellum (Gemini 4 Neon research)

- **Ignore Vellum's temp files.** Atomic writes create `.{name}.tmp-{uuid}`
  (`DirectLibraryFileStore.replace`) and `.{name}.vellum-{uuid}.tmp` (`PdfAtomicWriter`).
  Syncthing only ignores its own temp files. Vellum writes a `.stignore` into the shared
  root with `(?d).*.tmp-*` and `(?d).*.vellum-*.tmp`.
- **Conflict copies look like real files.** Syncthing names the losing copy
  `<stem>.sync-conflict-YYYYMMDD-HHMMSS-<DEVICE>.<ext>`. `DirectLibraryFileStore.list`
  matches on suffix, so `abc.sync-conflict-….json` in `records/` would load as a
  **phantom duplicate web page**. The list must filter these out.
- **The merge logic already exists.** `PreserveLosersConflictResolver` works on
  `ConflictEvent` + `Data`, not on `NSFileVersion`, so a folder adapter can feed it
  Syncthing conflict copies. It already merges web records, `meta.json` and conversations,
  and archives the losing copy.
- **`meta.json` stores an absolute `lastKnownPath`.** `/Users/…` vs `/home/…`: store it
  relative to the library root inside the shared folder, or treat it as per-device.
- **Linux file watching (inotify) costs one watch per directory.** Large libraries can hit the
  default limit. Fall back to periodic rescans on `ENOSPC`.

## Work this layer implies (not done in this PR)

- A **shared-folder storage mode** (iCloud layout in a plain folder) on the Mac and Linux.
- `.stignore` management, plus filtering of `.sync-conflict-` files in `DirectLibraryFileStore.list`.

- A Linux `SyncedContainer` adapter for a plain folder: inotify change watching,
  ignoring sync-tool temp files, conflict-copy detection.
- The same conflict-copy detection on the Mac's shared-folder mode (FSEvents instead of inotify).
- An unknown-field-preserving JSON pattern in `VellumCore`, adopted by every shared type.
- A cross-platform round-trip test fixture: a library written by the Mac, opened and
  re-saved by Linux, then diffed.

## Open questions

- **N2** — Is Syncthing OK? Does your current Mac library move out of iCloud into the
  Syncthing folder, or does the Mac keep an iCloud library and a separate shared one?
- **N6** — Who owns format migrations? Proposed: the format spec lives in `VellumCore`,
  and a version bump needs both apps updated in the same PR.
- Should scratchpad conflicts auto-merge (line-level), or always show both copies?
