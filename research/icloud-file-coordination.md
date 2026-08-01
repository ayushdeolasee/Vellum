# File coordination & materialization in iCloud containers — deep-dive supplement

> Supplements `icloud-shared-library.md` (question 3). Produced by a dedicated primary-source sweep of Apple documentation (DocC JSON behind the rendered pages, archived guides, technotes) and Apple-staff (DTS) forum answers, quoted with source URLs. Claims Apple does **not** substantiate are listed at the end — treat those as unknowns, not facts.

---

## (a) When is file coordination MANDATORY vs optional?

**Apple states unambiguously and repeatedly that ALL file access inside an iCloud container must go through NSFileCoordinator.** It is *not* required for an app's own private sandbox files (Application Support / Caches / tmp).

**TN2336: Handling version conflicts in the iCloud environment** — https://developer.apple.com/library/archive/technotes/tn2336/_index.html

> "Note: In the iCloud environment, every file access in your app, unless it is in the context of the reading or writing methods of `UIDocument` or `NSDocument`, should go through `NSFileCoordinator` so that it can be queued up and coordinated."

**iCloud Design Guide — "Designing for Documents in iCloud"** — https://developer.apple.com/library/archive/documentation/General/Conceptual/iCloudDesignGuide/Chapters/DesigningForDocumentsIniCloud.html

> "The use of file coordinators and presenters is mandatory when working with iCloud documents."

> "When accessing files and directories in a container, iCloud apps are required to use file coordination to do so. File coordination uses file coordinator and file presenter objects to serialize access to files and directories in order to preserve data integrity. File presenters monitor a file and are notified whenever another thread or process takes action on it. **All actions on a file must happen through a file coordinator**, which coordinates those actions with any interested file presenters."

> "If you are not using document objects to access files, you must handle the file coordination yourself."

**File System Programming Guide — "iCloud File Management"** — https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/iCloud/iCloud.html

> "To prevent large numbers of conflicting changes from occurring at the same time, apps are expected to use file coordinator objects to perform all changes. File coordinators mediate changes between your app and the daemon that facilitates the transfer of the document to and from iCloud. In this way, the file coordinator acts like a locking mechanism for the document, preventing your app and the daemon from modifying the document simultaneously."

> "Here is a checklist of the things your app must do to work with documents in iCloud: … **All file-related operations must be performed through a file coordinator object.**"

**File System Programming Guide — "The Role of File Coordinators and Presenters"** — https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileCoordinators/FileCoordinators.html

> "Apps that use the document classes don't need to use file coordinators when the app reads and writes private files in the `Application Support`, `Cache`, or temporary directories. These files are considered private."

**App Extension Programming Guide — Document Provider** (File Provider–backed storage generally) — https://developer.apple.com/library/archive/documentation/General/Conceptual/ExtensibilityPG/FileProvider.html

> "At least four separate processes may be trying to access the files provided by this extension at any one time; therefore, you must use file coordinators for all read and write operations."

Boundary of the mandate: the *class* docs for `NSFileCoordinator` never say "iCloud requires this" — the mandate lives in the iCloud-specific guides and TN2336.

---

## (b) Are plain atomic writes safe inside a ubiquity container without NSFileCoordinator?

**NOT SUBSTANTIATED as safe — and Apple's blanket mandate implies the opposite.** No Apple primary source says an uncoordinated atomic write (temp + `replaceItemAt`/`rename(2)`) is acceptable in a ubiquity container. Apple's positive guidance is the inverse: do the atomic replace *inside* a `coordinate(writingItemAt:options: .forReplacing)` block.

- `Data.WritingOptions.atomic` says nothing about iCloud or coordination — https://developer.apple.com/documentation/foundation/nsdata/writingoptions/atomic
- `FileManager.replaceItemAt(...)` likewise — https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:)

Why it's unsafe in principle ("iCloud File Management"): the sync daemon is a second writer, and the coordinator is "a locking mechanism… preventing your app and the daemon from modifying the document simultaneously." An atomic rename is atomic with respect to *readers of the path*, but it does not exclude the daemon, and it does not notify file presenters (see (e): presenters only see coordinated changes).

### `.forReplacing` — the option designed for exactly this pattern

https://developer.apple.com/documentation/foundation/nsfilecoordinator/writingoptions/forreplacing

> "**Use this method when the moving or creating an item should replace any item currently stored at that location. To avoid a race condition, use it regardless of whether an item is actually in the way before the writing begins. Do not use this method when simply updating the contents of the existing file.**"

So: `.forReplacing` = "I am about to swap the inode at this path" (temp+rename / `replaceItemAt`). Plain `[]` (no option) = "I am updating the existing file's bytes in place."

From `coordinate(with:queue:byAccessor:)`: writes with `forDeleting`/`forMoving`/`forReplacing` widen the lock — "all coordinated access to the directory and its contents interact as if they were accessing the same URL," and `.forDeleting`/`.forReplacing` trigger presenters' `accommodatePresentedItemDeletion`.

### All `NSFileCoordinator.WritingOptions` (one at a time per operation)

- **`.forDeleting`** — presenters get `accommodatePresentedItemDeletion(completionHandler:)` before the delete.
- **`.forMoving`** — waits for running coordinated reads/writes of a directory's contents before moving it; "no effect on files."
- **`.forMerging`** — presenters get `savePresentedItemChanges(completionHandler:)` first.
- **`.forReplacing`** — quoted above.
- **`.contentIndependentMetadataOnly`** — metadata-only writes; content changes during such a write "may not be preserved or may fail."

### All `NSFileCoordinator.ReadingOptions`

- **`.withoutChanges`** — skip forcing presenters to save first.
- **`.resolvesSymbolicLink`** — resolve symlinks; not usable with `prepare(forReadingItemsAt:...)`.
- **`.immediatelyAvailableMetadataOnly`** — "read an item's metadata **without triggering a download**"; grant is immediate "instead of waiting for the system to download the file's contents"; reading contents under this option "may give unexpected results or fail." **THE option for stat-like inspection without materializing.** (File Provider guide: this option "just triggers the creation of a placeholder.")
- **`.forUploading`** — snapshots the item (zips directories) and relinquishes the claim so a long upload doesn't block writers; the coordinator unlinks the snapshot after the block returns unless you open an fd or relocate it inside the block.

### `item(at:willMoveTo:)` — not the answer to atomic replacement

https://developer.apple.com/documentation/foundation/nsfilecoordinator/item(at:willmoveto:)

> "This method is intended for apps that adopt App Sandbox." … "**If your macOS app is not sandboxed, this method serves no purpose. This method is nonfunctional in iOS.**"

---

## (c) Materialization / download-on-demand: which APIs trigger a download and block?

### Coordinated reads DO block until download completes

`coordinate(readingItemAt:options:error:byAccessor:)` — https://developer.apple.com/documentation/foundation/nsfilecoordinator/coordinate(readingitemat:options:error:byaccessor:)

> "**If the device has not yet downloaded the file at the given URL, this method blocks (potentially for a long time) while the file is downloaded. If the file cannot be downloaded, this method fails.** Alternatively; use a metadata query to check for the `NSMetadataUbiquitousItemDownloadingStatusKey` key, and then call the `startDownloadingUbiquitousItem(at:)` method to download the file before trying to read it."

iCloud Design Guide: on iOS, downloads happen only on request — implicitly via `NSFileCoordinator` access or explicitly via `startDownloadingUbiquitousItemAtURL:`. "A Mac downloads files automatically as soon as it detects them on the server… a 'greedy peer.'"

### TN3150: Getting ready for dataless files — the definitive modern source

https://developer.apple.com/documentation/technotes/tn3150-getting-ready-for-data-less-files

> "Materializing a dataless file can take time… the app may become unresponsive. **If an app's main queue remains unresponsive for a long time, the system may terminate the app and trigger a watchdog crash.**"

> "This typically affects apps that store files in their own `url(forUbiquityContainerIdentifier:)` or access files from network file providers like iCloud Drive."

> "**Examples of actions that may result in one or more of these symptoms are enumerating a directory's contents and checking whether a file exists using `fileExists(atPath:)`.**"

Apple's own stack trace shows `contentsOfDirectoryAtPath:` → `getattrlistbulk` → `apfs_materialize_dataless_file_ext`.

> "UIDocument and NSDocument… will automatically do the right thing with dataless files. (**The system still materializes the intermediate folders, if they themselves are dataless.**)"

### The two documented ways to inspect without materializing

**Option 1 — `stat`/`getattrlist` + `SF_DATALESS`:** `stat()` on the file itself does NOT materialize the file's contents — check `SF_DATALESS` in `st_flags`. But it DOES materialize dataless *intermediate directories* in the path.

**Option 2 — per-thread/process I/O policy opt-out:** `setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD /* or PROCESS */, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)` — then "handle any `EDEADLK` errors that arise when accessing dataless files." Restore the prior policy afterwards.

### Download-status APIs

- `FileManager.startDownloadingUbiquitousItem(at:)` — "starts the download process"; not documented as blocking. Already-local items: no work, returns YES.
- `FileManager.evictUbiquitousItem(at:)` — "**Don't use a coordinated write to perform this operation**" (deadlock history); removes only the local copy. **A documented exception to the always-coordinate rule.** Permanent deletion uses regular FileManager routines.
- `URLResourceKey.ubiquitousItemDownloadingStatusKey` + `URLUbiquitousItemDownloadingStatus`: `.current` = up to date; **`.downloaded` = local copy exists but STALE**; `.notDownloaded` = not yet local. ⚠️ Do not treat `.downloaded` as "ready."
- Also: `ubiquitousItemIsDownloadingKey`, `ubiquitousItemDownloadingErrorKey`, `isUbiquitousItemKey` (vs `FileManager.isUbiquitousItem(at:)`, which only reflects `setUbiquitous` intent, not upload state).

### DTS (secondary, Apple staff) confirmations

- Kevin Elliott (DTS): opening a dataless file **blocks the calling thread in `open`** while fileproviderd orchestrates the download — https://developer.apple.com/forums/thread/764131
- Kevin Elliott (DTS): `stat`+`SF_DATALESS` is fine for detect-and-skip during bulk iteration; for actual download management "use FileCoordination… The low-level calls are ultimately a compatible layer, not a full solution." — https://developer.apple.com/forums/thread/825820
- Ziqiao Chen (DTS): directory access triggers provider enumeration; TN3150 opt-out applies — https://developer.apple.com/forums/thread/756129
- Ziqiao Chen (DTS): coordinated read of a *file* always downloads first; of a *folder*, not necessarily recursively — https://developer.apple.com/forums/thread/764270

---

## (d) Enumerating a ubiquity container without materializing

**Apple explicitly says use `NSMetadataQuery`, not filesystem APIs — current guidance, not just archived.**

**"Synchronizing documents in the iCloud environment"** — https://developer.apple.com/documentation/UIKit/synchronizing-documents-in-the-icloud-environment

> "**iOS apps use `NSMetadataQuery` rather than file system APIs to discover documents in an iCloud container.** … When an iOS app receives a notification that a new document exists, **the document data may not physically exist on the local file system, so it isn't discoverable with file system APIs.**"

Recommended config: `notificationBatchingInterval = 1`; scopes `NSMetadataQueryUbiquitousDataScope` (files *outside* `Documents/`) + `NSMetadataQueryUbiquitousDocumentsScope` (files *inside* `Documents/`); listen for `NSMetadataQueryDidFinishGathering` then `NSMetadataQueryDidUpdate`; wrap result access in `disableUpdates()`/`enableUpdates()`.

Archived "iCloud File Management" adds: "**You should always use query objects instead of saving URLs persistently**… Using a query to search is the only way to ensure an accurate list of documents." and "it is not possible to combine local file system searches with iCloud searches."

### ❌ The `.icloud` placeholder filename convention is NOT documented API

Apple documents that placeholders exist (`NSFileProviderExtension.placeholderURL(for:)`) but **never documents the `.<name>.icloud` filename format**. It appears only in a developer's debug output on an unanswered forum thread. **Do not parse or construct it.** Use `placeholderURL(for:)` for mapping and `NSMetadataQuery` + `ubiquitousItemDownloadingStatusKey` for state.

---

## (e) NSFilePresenter requirements

**A presenter is required to receive coordination notifications, but discovery of remote files is `NSMetadataQuery`'s job — they are complementary.**

`NSFilePresenter` — https://developer.apple.com/documentation/foundation/nsfilepresenter

> "**Your presenter objects are not notified about changes made directly using low-level read and write calls to the file. Only changes that go through a file coordinator result in notifications.**"

(That sentence is also the second-order reason uncoordinated atomic writes are hazardous: nobody hears about them.)

iCloud guides: "Manage each document in iCloud using a file presenter… **Registration is essential** (`NSFileCoordinator.addFilePresenter:`). The system can notify only registered presenter objects." Unregister with `removeFilePresenter:` before releasing.

Key callbacks:

- `presentedItemDidChange()` — content *and* attribute changes; check the modification date (under a coordinated read) before rereading content.
- `accommodatePresentedItemDeletion(completionHandler:)` — **must call the completion handler** or "threads in your application or other processes" stall.
- `presentedSubitemDidChange(at:)` — directory presenters; file packages fall back to `presentedItemDidChange()`.
- Ubiquity-specific: `observedPresentedItemUbiquityAttributes` + `presentedItemDidChangeUbiquityAttributes(_:)`.

Keep callbacks lightweight; defer change-processing asynchronously — except relinquish/save callbacks, which must act immediately.

DTS confirmation of the split (Apple Engineer, https://developer.apple.com/forums/thread/830586): security-scoped external files → URL resource values + `NSFilePresenter`; own-container files → `NSMetadataQuery` "pushes batched update deltas with the cloud-state keys."

---

## (f) Main-thread and deadlock guidance

### Blocking

- The synchronous `coordinate(readingItemAt:...)`/`coordinate(writingItemAt:...)` block the calling thread — potentially for the full download.
- "Improving performance and stability when accessing the file system" (https://developer.apple.com/documentation/foundation/improving-performance-and-stability-when-accessing-the-file-system): "avoid performing immediate file I/O on the app's main thread"; "**By specifying a background operation queue, the coordinator works asynchronously and is therefore safe to call from the main thread.** See `coordinate(with:queue:byAccessor:)`."
- Same doc, a non-iCloud trap: URL initializers without an explicit `directoryHint` perform "a potentially blocking call to the file system" to sniff file-vs-directory. Always pass the hint.

### Reentrancy — a hard exception

Nesting a write inside a write's accessor block **throws an exception**. A read nested in a write is allowed only for modification-date rechecks. Use the multi-item variants (`coordinate(writingItemAt:options:writingItemAt:...)`, `prepare(forReadingItemsAt:...)`) for batch operations.

### Concurrency deadlock & escape hatches

`coordinate(with:queue:byAccessor:)`:

> "if you make multiple, concurrent calls… you risk deadlocking with another process that is similarly making multiple concurrent calls to its file coordinator. Wherever possible, invoke `coordinate(with:queue:byAccessor:)` once, passing in multiple file access intent objects."

> "Your file coordinator has access to the files only until the accessor block returns. **Do not dispatch tasks that continue to access these files onto other threads or queues… could result in data corruption or data loss.**"

> "always use the `URL` property of your intent objects when accessing the files inside the accessor block."

### `NSFileCoordinator(filePresenter:)` — the reentrancy-safety constructor

> "**Specifying a file presenter at initialization time is strongly recommended**… Receiving such notifications could also deadlock if the file presenter's code and its notifications run on the same thread." … "**Prevents deadlocks that could occur when the file presenter performs a coordinated write operation in response to a `savePresentedItemChanges(completionHandler:)` message.**" … "the coordinator must be initialized on the same operation queue that the file presenter uses to receive its messages."

### iOS background/termination hazards

`NSFileCoordinator` class overview:

> "**If your app or extension enters the background with an active file presenter, it may be terminated by the system in order to prevent deadlock on that file.** To prevent this situation, call `removeFilePresenter(_:)`… in response to a `didEnterBackgroundNotification`… re-add on foreground." (`UIDocument` does this automatically.)

> "A coordinated read or write will automatically begin a background task when granted… If a process is suspended while waiting for a coordinated read or write to be granted, the request is canceled (`NSUserCancelledError`). If the background task expires, the process is terminated."

> "**Threading:** Each file coordinator object you create should be used on a single thread only." One coordinator per operation; don't keep them around (they retain presenters).

### DTS (secondary) on scale

Kevin Elliott (DTS), https://developer.apple.com/forums/thread/802972: each pending coordination request consumes a Mach port — unbounded fan-out dies by port exhaustion (reproduced at ~1.7M objects); Swift `Task` disables GCD overcommit, which large-scale I/O actually needs — manually queue operations and use the synchronous API per queued item. Recommended coordinated recursive walk: async coordinated read per directory + shallow `enumerator(...skipsSubdirectoryDescendants)`, recursing per subdirectory — never one nested coordinated read over a huge hierarchy.

---

## Claims NOT substantiated by any Apple primary source

| Claim | Status |
|---|---|
| Uncoordinated atomic write (temp + rename) is safe in a ubiquity container | **Not substantiated.** No Apple source blesses it; the blanket mandate says the opposite. (No source explicitly condemns it either — the mandate is general.) |
| `.<name>.icloud` placeholder filename convention | **Not documented.** Implementation detail; do not parse or construct. |
| `F_GETPATH`/`fcntl` as a non-materializing stat mechanism | **Not substantiated.** |
| `open(O_NOFOLLOW)` / `getattrlist(FSOPT_NOFOLLOW)` avoiding materialization | **Not substantiated.** `getattrlist` is a *detection* call that still materializes intermediate dirs. |
| `startDownloadingUbiquitousItem(at:)` blocking behavior | **Not documented either way.** Treat as non-blocking-but-not-on-main. |
| "MetadataQuery alone is insufficient" | **Partial.** Presenter is called mandatory for iCloud documents; no source says MetadataQuery can't observe remote changes. Documented split: MetadataQuery for discovery, coordinator+presenter for access. |
| Whether `NSMetadataQuery` itself materializes anything | **Not substantiated explicitly**; positioned as the alternative to filesystem APIs precisely because data may not be local — strongly implying it doesn't. |

---

## Practical distillation for an iOS app writing to its own ubiquity container

1. **Coordinate everything.** Every read, write, move, delete inside `url(forUbiquityContainerIdentifier:)` goes through `NSFileCoordinator`. The one documented exception: `evictUbiquitousItem(at:)` must NOT be coordinated.
2. **Use the async variant.** `coordinate(with:queue:byAccessor:)` with a background `OperationQueue` — "safe to call from the main thread." The synchronous variants block for the full download and must never touch the main thread.
3. **Atomic replace goes inside a `.forReplacing` coordinated write** — "regardless of whether an item is actually in the way." Plain `[]` for in-place byte updates. `item(at:willMoveTo:)` is a no-op on iOS.
4. **Never enumerate with `contentsOfDirectory` / `fileExists`.** Use `NSMetadataQuery` (both ubiquitous scopes), wrap result access in `disableUpdates()`/`enableUpdates()`, retain the query.
5. **Check status before reading.** Only `.current` means ready; `.downloaded` means stale. Metadata-only inspection: `.immediatelyAvailableMetadataOnly`.
6. **One coordinator per operation, per thread; construct with `NSFileCoordinator(filePresenter:)` on the presenter's queue.** Never nest coordinate calls (write-in-write throws).
7. **Bound concurrency.** No unbounded concurrent `coordinate(with:queue:)` fan-out — documented cross-process deadlock risk plus Mach-port exhaustion (DTS).
8. **Don't escape the accessor block.** No `Task { }` capturing the URL for later — that's uncoordinated access, "could result in data corruption or data loss."
9. **Drop presenters on background.** `removeFilePresenter(_:)` on `didEnterBackgroundNotification`, re-add on foreground — or the system may terminate the app.
