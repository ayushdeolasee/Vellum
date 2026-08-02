# Packet 6 — Annotations & Scratchpad (parity phase 6, issue #135)

Source of the delta: `/Users/ayushdeolasee/Developer/Vellum/main`, range `a42705d1~1..7742a895`.
Target: `/Users/ayushdeolasee/Developer/Vellum/ipad-app` (branch `ipad-app`).

Feature scope covered here:

| Feature | Upstream commits |
|---|---|
| Pin-to-top for highlights / notes / bookmarks (PR #63) | `8b6b9144`, `a8aa2bad`, merge `696cf938` |
| Editable PDF bookmark titles (PR #61) | `34f8c65c` |
| Scratchpad Markdown export with images (PR #81) | `ba6e4e61` |
| Undoable Clear Scratchpad / Clear Conversation (PR #79) | `dc3ac525` |
| Attachment GC vs. snapshot cutoff (PR #104) | `1d9d4469` |
| Attachment GC vs. in-flight save / pending registry (PR #117) | `5b6b03ce` |
| Re-tap already-selected annotation re-scrolls + late-loading web settle | `5a8842e6` (PRE-RANGE — see §5.1, already on iPad) |

Read the source diffs with, e.g.:

```
git -C /Users/ayushdeolasee/Developer/Vellum/main show 8b6b9144 -- <path>
git -C /Users/ayushdeolasee/Developer/Vellum/main diff 7742a895 ipad-app -- <path>   # main HEAD vs iPad
```

---

## 1. Delta files claimed

### 1.1 Product code

```
Vellum/Models/Models.swift                              [MERGE]   pin fields only
Vellum/Models/PaneTree.swift                            [MERGE]   one-line scratchpad.app wiring only (shared with pane packet)
Vellum/Services/Pdf/PdfAnnotationCodec.swift            [MERGE]   /VellumPinned read
Vellum/Services/Pdf/PdfAtomicWriter.swift               [MERGE]   add PdfDictSource.setTextString only
Vellum/Services/Pdf/PdfBookmarks.swift                  [MERGE]   findBookmarkNumber + 2x updateBookmarkIncrement + defaultTitle + /VellumContent
Vellum/Services/Pdf/PdfSessionBackend.swift             [MERGE]   bookmark update branch + pin write + rehydration extensions + sortedForDisplay
Vellum/Services/Web/WebSessionBackend.swift             [MERGE]   is_pinned in sidecar + sortedForDisplay
Vellum/Stores/AnnotationStore.swift                     [MERGE]   togglePin + sortedForDisplay calls
Vellum/Views/Annotations/AnnotationSidebar.swift        [MERGE]   pin control, pin badge, bookmark edit affordance, save-on-blur
Vellum/Services/Scratchpad/ScratchpadMarkdownExporter.swift  [VERBATIM]  new file, pure Foundation/Darwin
Vellum/Services/Scratchpad/ScratchpadPersistence.swift  [MERGE]   GC cutoff (#104) + pending registry (#117)
Vellum/Stores/ScratchpadStore.swift                     [MERGE]   clear/undo/redo transactions + markPending + referencedAsOf
Vellum/Views/Scratchpad/ScratchpadPanel.swift           [REBUILD] -> Vellum/Platform/iOS/ScratchpadPanel_iOS.swift
Vellum/Stores/AiStore.swift                             [MERGE]   clearConversation transaction + undoClear/redoClear only
Vellum/Views/AI/AiPanel.swift                           [MERGE into AiPanel_iOS.swift, after packet 5] (clear-conversation slice only — see §2.14)
Vellum/Services/Ai/AiPersistence.swift                  [MERGE]   migrateToCurrentStorageKeyIfNeeded — CONDITIONAL, see §2.14
```

### 1.2 Tests

```
Tests/PdfPersistenceTests.swift                         [MERGE]   +3 tests (pin highlight, pin bookmark, bookmark title)
Tests/WebLibraryStorageTests.swift                      [MERGE]   +1 test (is_pinned sidecar)
Tests/ScratchpadMarkdownExporterTests.swift             [VERBATIM] new file (469 lines)
Tests/SafeClearTests.swift                              [MERGE]   new file on iPad, but needs adaptation — see §4.4
Tests/ScratchpadImportTests.swift                       [MERGE]   +3 lines: resetPending() in tearDown
```

### 1.3 Out of scope for this packet

```
Tests/DocumentDataStoreTests.swift                      [SKIP: packet 1 owns this file. The one test this packet
                                                         cares about (testGCSparesAttachmentsWrittenAfterTheReferenceSnapshot,
                                                         added by 1d9d4469) is relocated into SafeClearTests — see §4.5]
Tests/ScratchDefaultsTrait.swift                        [SKIP: belongs to the packet 1 (c403615f)]
Tests/AppDefaultsGuardTests.swift                       [SKIP: packet 1]
UITests/ScratchpadSnapshotUITests.swift                 [SKIP: bcab835e is a macOS-only XCUITest target (#87); the iPad
                                                         project has no UITests target]
UITests/README.md, UITests/README-setup.md,
UITests/VellumUITestCase.swift,
UITests/VellumConsistencyUITests.swift                  [SKIP: macOS UI-test target]
Vellum.xcodeproj/project.pbxproj                        [SKIP: macOS project file; iPad is xcodegen from project.yml]
Vellum.xcodeproj/xcshareddata/xcschemes/VellumUITests.xcscheme [SKIP: macOS scheme]
CHANGELOG.md, AGENTS.md, CLAUDE.md, plans/*             [SKIP: docs/plans]
Vellum/Views/Shared/Controls.swift                      [SKIP: inspector-switcher packet (333d9ebe / 79a65591)]
Vellum/Views/Web/WebViewerView.swift                    [SKIP: no scroll/selection changes in this range — see §5.1]
Vellum/Views/Web/WebContentScript.swift                 [SKIP: not in the delta range at all; iPad's copy has
                                                         iPad-only touch-selection work that must not be touched]
tools/scratchpad-editor/**, Vellum/Resources/katex/**   [SKIP: ZERO changes in the delta range. Verified:
                                                         `git log a42705d1~1..7742a895 -- tools/ Vellum/Resources/katex`
                                                         is empty, and `git diff 7742a895 ipad-app -- tools/
                                                         Vellum/Resources/katex` is empty. The bundled CodeMirror
                                                         editor resources the iPad uses need NO work.]
project.yml                                             [SKIP for this packet — no changes needed; see §3]
```

---

## 2. Port order & instructions

Recommended execution order: **2.1 → 2.9** (annotations, self-contained, no cross-packet deps) then **2.10 → 2.15** (scratchpad/AI, has cross-packet deps).

---

### 2.1 `Vellum/Models/Models.swift` — [MERGE]

**Edit order (packet 10 §2.3):** **1 → 4 → 6** — packet 6 lands last, contributing only the pin
fields below. Packets 1 and 4 add `DocumentInfo.docId`/`bookmarkData`/`RecentDocument.docId` and the
`PdfTab` find/region fields respectively; do not touch those.

**What main changed** (`8b6b9144`): added `isPinned` to `Annotation` with coding key `is_pinned`, a `pinned` convenience, a static `sortedForDisplay`, and `isPinned` to `UpdateAnnotationInput`.

**iPad today:** `Annotation` has no `isPinned`; `CreateAnnotationInput` has an extra iPad-only `createdAt: String?`; `UpdateAnnotationInput` has `pageNumber` but no `isPinned`. Several *other* main-only fields (`DocumentInfo.docId`, `bookmarkData`, `RecentDocument.docId`, `PdfTab.pendingNoteContent/regionCaptureTarget/find*`, `RegionCaptureTarget`) are absent on iPad — **those belong to other packets; do not touch them.**

**Preserve:** `CreateAnnotationInput.createdAt` and its doc comment (iPad optimistic-create identity).

**Concrete edits** — surgical, three hunks only:

1. In `struct Annotation`, after `var updatedAt: String`, add:
```swift
    /// Pinned annotations float to the top of the sidebar list. Optional so
    /// records written before pinning existed decode cleanly (missing → false).
    var isPinned: Bool? = nil
```
2. In `Annotation.CodingKeys`, after `case updatedAt = "updated_at"`, add `case isPinned = "is_pinned"`. **Byte compatibility: the key MUST be the literal `is_pinned`.**
3. After the `CodingKeys` enum, inside `struct Annotation`, add `pinned` and `sortedForDisplay` verbatim from main (lines 71–92 of main's `Models.swift`):
```swift
    /// True when the user has pinned this annotation.
    var pinned: Bool { isPinned == true }

    /// Sidebar / backend list order: pinned first, then page, then created_at.
    /// `enumerated` keeps relative order stable when the sort keys tie.
    static func sortedForDisplay(_ annotations: [Annotation]) -> [Annotation] {
        annotations.enumerated()
            .sorted { left, right in
                if left.element.pinned != right.element.pinned {
                    return left.element.pinned && !right.element.pinned
                }
                if left.element.pageNumber != right.element.pageNumber {
                    return left.element.pageNumber < right.element.pageNumber
                }
                if left.element.createdAt != right.element.createdAt {
                    return left.element.createdAt < right.element.createdAt
                }
                return left.offset < right.offset
            }
            .map(\.element)
    }
```
4. In `struct UpdateAnnotationInput`, after `var pageNumber: Int? = nil`, add:
```swift
    /// When set, pin or unpin the annotation in the sidebar list.
    var isPinned: Bool? = nil
```

**Compile check:** every existing `UpdateAnnotationInput(id:color:content:positionData:)` call site keeps working because `pageNumber` and `isPinned` both default to `nil`.

---

### 2.2 `Vellum/Services/Pdf/PdfAnnotationCodec.swift` — [MERGE]

**What main changed** (`8b6b9144`): 2-line change in `PdfAnnotationReader.annotation(from:...)` to read `/VellumPinned`.

**iPad today:** this file has iPad-only work (`PlatformColor` instead of `NSColor`, `PDFAnnotation(bounds:forType:withProperties:)` bulk-properties construction, `NSValue(cgPoint:)` under `#if os(iOS)`). **Do not touch any of that.**

**Concrete edits** — in `PdfAnnotationReader.annotation(from:pageNumber:index:geometry:)`:

after
```swift
        let updatedAt = CgPdf.string(dictionary, "VellumUpdatedAt") ?? now
```
add
```swift
        let isPinned = CgPdf.integer(dictionary, "VellumPinned") == 1 ? true : nil
```
and change the returned `Annotation(...)` trailer from `updatedAt: updatedAt)` to `updatedAt: updatedAt,\n            isPinned: isPinned)`.

`CgPdf.integer` already exists on iPad (`Vellum/Services/Pdf/PdfGeometry.swift:52`).

---

### 2.3 `Vellum/Services/Pdf/PdfAtomicWriter.swift` — [MERGE]

**What main changed** (`34f8c65c`): one new 3-line helper on `PdfDictSource`.

**iPad today:** this file carries substantial iPad-only work that must be preserved verbatim — `PdfArraySource.references(inArray:)`, `ClassicPdfFile`'s `/Prev`-chain xref merging (`xrefSection`), `ClassicPdfFile.rawObjectValue(_:)`, and the `PdfIncrement` doc comment about keeping increments intact on iPadOS 26. **Do not import main's version of this file.**

**Concrete edit** — in `struct PdfDictSource`, immediately after `mutating func setInteger(forKey:to:)` (iPad line ~528–530), insert:
```swift
    mutating func setTextString(forKey key: String, to value: String) {
        setValue(forKey: key, raw: PdfTextString.encode(value))
    }
```
That's the entire change to this file.

---

### 2.4 `Vellum/Services/Pdf/PdfBookmarks.swift` — [MERGE]

**What main changed** (`8b6b9144` + `a8aa2bad` + `34f8c65c`):
- `readBookmarks` now reads `/VellumContent` into `Annotation.content` (empty → nil) and `/VellumPinned` into `isPinned`.
- new `static func defaultTitle(pageNumber: Int) -> String` returning `"Bookmark - page \(pageNumber)"`.
- `createBookmarkIncrement` gained a `content: String? = nil` parameter: the title written to `/Title` is `content` when non-empty else `defaultTitle(pageNumber:)`, and a non-empty `content` is additionally written to `/VellumContent`.
- new `private static func findBookmarkNumber(in:id:)` factoring the catalog → `/Outlines` → item walk (extracted by `a8aa2bad`), used by the update and delete paths.
- two `updateBookmarkIncrement` overloads: `(normalizedData:id:content:defaultTitle:now:)` and `(normalizedData:id:isPinned:now:)`.

**iPad today:** this file matches main's *pre*-#63 state exactly (the diff `7742a895..ipad-app` for it is purely the removal of the above). `deleteBookmarkIncrement` still inlines the catalog/outlines walk.

**Preserve:** nothing iPad-specific in this file — the diff is a clean revert of main's additions. This is the closest thing to a verbatim adoption in the packet, but do it as edits rather than a file copy so you keep the iPad's git history clean and avoid pulling in anything else that drifted.

**Concrete edits:**

1. In `readBookmarks`, in the `bookmarks.append(Annotation(...))` block, replace
```swift
                    let now = PdfDates.rfc3339Now()
                    bookmarks.append(Annotation(
                        id: id,
                        type: .bookmark,
                        pageNumber: page,
                        color: nil,
                        content: nil,
                        positionData: nil,
                        createdAt: CgPdf.string(current, "VellumCreatedAt") ?? now,
                        updatedAt: CgPdf.string(current, "VellumUpdatedAt") ?? now))
```
with
```swift
                    let now = PdfDates.rfc3339Now()
                    // The user title lives in /VellumContent; /Title mirrors it
                    // for external viewers and holds the default when untitled.
                    let content = CgPdf.string(current, "VellumContent")
                    let isPinned = CgPdf.integer(current, "VellumPinned") == 1 ? true : nil
                    bookmarks.append(Annotation(
                        id: id,
                        type: .bookmark,
                        pageNumber: page,
                        color: nil,
                        content: content?.isEmpty == false ? content : nil,
                        positionData: nil,
                        createdAt: CgPdf.string(current, "VellumCreatedAt") ?? now,
                        updatedAt: CgPdf.string(current, "VellumUpdatedAt") ?? now,
                        isPinned: isPinned))
```

2. Just above `// MARK: - Creation (incremental update)`, add:
```swift
    /// /Title for a bookmark with no user title.
    static func defaultTitle(pageNumber: Int) -> String {
        "Bookmark - page \(pageNumber)"
    }
```

3. `createBookmarkIncrement`: add `content: String? = nil,` between the `id: String,` and `now: String` parameters. Replace
```swift
        var bookmark: [UInt8] = Array("<< /Title ".utf8)
        bookmark.append(contentsOf: PdfTextString.encode("Bookmark - page \(pageNumber)"))
```
with
```swift
        let title = content?.isEmpty == false ? content! : defaultTitle(pageNumber: pageNumber)
        var bookmark: [UInt8] = Array("<< /Title ".utf8)
        bookmark.append(contentsOf: PdfTextString.encode(title))
```
and after the `/VellumUpdatedAt` append block, insert:
```swift
        if let content, !content.isEmpty {
            bookmark.append(contentsOf: Array(" /VellumContent ".utf8))
            bookmark.append(contentsOf: PdfTextString.encode(content))
        }
```
Key order in the emitted dictionary must stay: `/Title /Parent /Dest /VellumType /VellumNM /VellumCreatedAt /VellumUpdatedAt [/VellumContent] [/Prev]` (matches main byte-for-byte).

4. Add a new `// MARK: - Update (incremental update)` section before `// MARK: - Deletion`, containing (verbatim from main's `PdfBookmarks.swift` lines 179–241):
```swift
    /// Walk catalog → /Outlines → outline tree for the Vellum bookmark
    /// carrying this id, returning its object number. nil when the document
    /// has no outline or no item matches.
    private static func findBookmarkNumber(in file: ClassicPdfFile, id: String) -> Int? {
        guard let catalogNumber = file.rootNumber, let catalog = file.objectSource(catalogNumber),
              let outlinesNumber = catalog.reference(forKey: "Outlines"),
              let root = file.objectSource(outlinesNumber)
        else { return nil }
        return findBookmarkObject(in: file, rootNumber: outlinesNumber, root: root, id: id)
    }

    /// Retitle a bookmark: set /VellumContent and mirror it into /Title, or —
    /// when `content` is empty — clear the title back to `defaultTitle`.
    /// /VellumUpdatedAt always refreshes. Returns nil when no Vellum bookmark
    /// carries the id.
    static func updateBookmarkIncrement(
        normalizedData: Data,
        id: String,
        content: String,
        defaultTitle: String,
        now: String
    ) throws -> Data? {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let bookmarkNumber = findBookmarkNumber(in: file, id: id),
              var bookmark = file.objectSource(bookmarkNumber)
        else { return nil }

        if content.isEmpty {
            bookmark.removeEntry(forKey: "VellumContent")
            bookmark.setTextString(forKey: "Title", to: defaultTitle)
        } else {
            bookmark.setTextString(forKey: "VellumContent", to: content)
            bookmark.setTextString(forKey: "Title", to: content)
        }
        bookmark.setTextString(forKey: "VellumUpdatedAt", to: now)

        var increment = PdfIncrement(file: file)
        increment.setObject(bookmarkNumber, source: bookmark.sourceBytes)
        return increment.appended()
    }

    /// Patch pin state on an outline bookmark. Returns nil when no Vellum
    /// bookmark carries the id. PDFKit cannot write custom keys on outline
    /// items, so this rewrites the outline object in place.
    static func updateBookmarkIncrement(
        normalizedData: Data,
        id: String,
        isPinned: Bool,
        now: String
    ) throws -> Data? {
        let file = try ClassicPdfFile(data: normalizedData)
        guard let bookmarkNumber = findBookmarkNumber(in: file, id: id),
              var bookmark = file.objectSource(bookmarkNumber)
        else { return nil }

        bookmark.setInteger(forKey: "VellumPinned", to: isPinned ? 1 : 0)
        bookmark.setValue(forKey: "VellumUpdatedAt", raw: PdfTextString.encode(now))

        var increment = PdfIncrement(file: file)
        increment.setObject(bookmarkNumber, source: bookmark.sourceBytes)
        return increment.appended()
    }
```

5. Simplify `deleteBookmarkIncrement`'s prologue to use the new helper (matches main after `a8aa2bad`):
```swift
        let file = try ClassicPdfFile(data: normalizedData)
        guard let bookmarkNumber = findBookmarkNumber(in: file, id: id) else { return nil }
```
replacing the inlined catalog/`/Outlines`/`findBookmarkObject` block.

**Byte compatibility:** `/VellumPinned` is a PDF *integer* (`1`/`0`), never a boolean. `/VellumContent` and `/Title` are PDF text strings via `PdfTextString.encode` (UTF-16BE hex for non-ASCII).

---

### 2.5 `Vellum/Services/Pdf/PdfSessionBackend.swift` — [MERGE] ⚠ hardest file in the packet

**Edit order (packet 10 §2.3):** **1 → 6 → 7** — packets 1, 6 and 7 all MERGE this file; land in
that order. (Packet 10 §2.3 also flagged this file as "already dirty in the iPad worktree" — that
caveat is **stale**, the in-flight work landed in commit `783c8835`. Nothing to stash.)

**What main changed:**
- `8b6b9144`: `PdfDocumentIO.getAnnotations` sort replaced by `Annotation.sortedForDisplay(annotations)`; `updateAnnotation` restructured from "find page annotation or return false" into "if page annotation … else if outline bookmark …"; page annotations gained `if let isPinned { PdfAnnotationWriter.setValue(annotation, "VellumPinned", (isPinned ? 1 : 0) as NSNumber) }`; a new outline-bookmark branch pins via `PdfBookmarks.updateBookmarkIncrement(normalizedData:id:isPinned:now:)` + `saveThroughPdfKit`.
- `34f8c65c`: `createAnnotation` passes `content:` through to `createBookmarkIncrement` and returns `content: title` on the created bookmark; the bookmark branch of `updateAnnotation` handles `input.content` (retitle) *and* `input.isPinned`, and when both are present it **reloads the document between the two increments** ("The title save above rewrote the file; reload so the pin increment patches PDFKit-normalized data").

**iPad today:** heavily restructured. `PdfDocumentIO` is gone; the logic lives in `PdfDocumentSession` as `nonisolated static func performCreate/performUpdate/performDelete/performSetMetadata`, driven through the `PdfFileGate` actor from `@MainActor` wrappers. There is an entire iPadOS-26 metadata-preservation layer: `pdfKitDropsCustomKeys`, `readBytes`, `annotationMetadataRecords(in:)`, `rehydrateAnnotationMetadata(normalizedData:records:)`, `rehydrateBookmarkMetadata(normalizedData:bookmarks:)`, `restoreInfoDictionary(from:into:)`, `persistPdfKitRewrite(_:preservingMetadataFrom:path:)`, and an `originalData`-first fast path in `performCreate`/`performDelete`/`performSetMetadata`.

**Preserve (non-negotiable):** `PdfFileGate` and its `perform` wrappers (standing decision — do NOT swap to main's `actor PdfDocumentIO`); `offMainRead`; `pdfKitDropsCustomKeys` and every rehydration/restore helper; `persistPdfKitRewrite` (used by the Pencil ink path); `input.createdAt` honoring in `performCreate`.

**Concrete edits:**

**(a) `readAnnotations` — sort order.** Replace the trailing sort block
```swift
        // Stable sort: page_number asc, then created_at as a plain string.
        return annotations.enumerated()
            .sorted { left, right in
                ...
            }
            .map(\.element)
```
with
```swift
        // Pinned first, then page_number asc, then created_at as a plain string.
        return Annotation.sortedForDisplay(annotations)
```

**(b) `performCreate` — bookmark titles.** After `let now = input.createdAt ?? PdfDates.rfc3339Now()`, add:
```swift
        let bookmarkTitle = input.content?.isEmpty == false ? input.content : nil
```
In the `if input.type == .bookmark {` block, both `createBookmarkIncrement` calls gain `content: bookmarkTitle,` and both returned `Annotation(...)` literals change `content: nil` → `content: bookmarkTitle`. (There are two call sites and two `Annotation` literals: the `originalData` fast path and the `serialize`+`saveThroughPdfKit` fallback. Update all four.)

**(c) `performUpdate` — page-annotation pin.** Inside the existing PDFKit-mutation block, after the `if let content = input.content { annotation.contents = content }` line, add:
```swift
        if let isPinned = input.isPinned {
            PdfAnnotationWriter.setValue(annotation, "VellumPinned", (isPinned ? 1 : 0) as NSNumber)
        }
```

**(d) `performUpdate` — restructure the not-found path into a bookmark branch.** iPad currently does:
```swift
        guard let (pageIndex, annotation) = Self.findAnnotation(id: input.id, in: document, raw: raw) else {
            return false
        }
```
Change this to `if let (pageIndex, annotation) = ... { <existing body, ending in `return true`> }`, then append the bookmark branch and a final `return false`. The bookmark branch must follow the **iPad's** increment conventions (prefer raw `originalData`, fall back to `serialize` + `saveThroughPdfKit`), not main's macOS-only shape:

```swift
        // Outline bookmarks: title (content) and pin state only — color and
        // position don't apply here. PDFKit can't mutate outline custom keys,
        // so these are incremental byte rewrites of the outline item; an
        // update carrying neither field is a no-op on an existing record.
        if PdfBookmarks.containsBookmark(document: raw, id: input.id) {
            var retitled = false

            if let content = input.content {
                let pageNumber = bookmarks.first { $0.id == input.id }?.pageNumber ?? 1
                let defaultTitle = PdfBookmarks.defaultTitle(pageNumber: pageNumber)
                let now = PdfDates.rfc3339Now()
                if let originalData,
                   let patched = try? PdfBookmarks.updateBookmarkIncrement(
                       normalizedData: originalData, id: input.id, content: content,
                       defaultTitle: defaultTitle, now: now) {
                    try Self.writeAndRefreshCache(patched, path: path)
                } else {
                    let normalized = try serialize(document)
                    guard let patched = try PdfBookmarks.updateBookmarkIncrement(
                        normalizedData: normalized, id: input.id, content: content,
                        defaultTitle: defaultTitle, now: now)
                    else { return false }
                    try saveThroughPdfKit(patched, path: path)
                }
                retitled = true
            }

            if let isPinned = input.isPinned {
                // The title save above rewrote the file; re-read so the pin
                // increment patches the data that is actually on disk.
                let now = PdfDates.rfc3339Now()
                let base: Data
                if retitled {
                    base = try Self.readBytes(path: path)
                } else if let originalData {
                    base = originalData
                } else {
                    base = try serialize(document)
                }
                guard let patched = try PdfBookmarks.updateBookmarkIncrement(
                    normalizedData: base, id: input.id, isPinned: isPinned, now: now)
                else { return false }
                if pdfKitDropsCustomKeys || retitled {
                    try Self.writeAndRefreshCache(patched, path: path)
                } else {
                    try saveThroughPdfKit(patched, path: path)
                }
            }

            return true
        }

        return false
```
`bookmarks` is already computed at the top of `performUpdate` (`let bookmarks = PdfBookmarks.readBookmarks(document: raw, pageNumber: nil)`) — reuse it rather than re-reading, and note that after the retitle the `document`/`raw` handles are stale, which is exactly why the pin step re-reads bytes from `path`.

**(e) ⚠ `rehydrateBookmarkMetadata` — MUST-FIX, silent data loss otherwise.** Today it identifies Vellum bookmarks after an iPadOS-26 PDFKit rewrite by:
```swift
                if item.textString(forKey: "Title")?.hasPrefix("Bookmark - page ") == true {
```
With editable titles, a user-titled bookmark's `/Title` becomes the user's string, so it stops matching, `candidates.count < bookmarks.count`, and the function **throws `"Failed to match all PDF bookmarks"`** — every subsequent highlight/note create on that document fails. Replace the predicate with one that also accepts the current title and the default for a bookmark that has one:
```swift
        let knownTitles = Set(bookmarks.compactMap(\.content).filter { !$0.isEmpty })
        ...
                let title = item.textString(forKey: "Title")
                if title?.hasPrefix("Bookmark - page ") == true
                    || (title.map(knownTitles.contains) ?? false) {
                    candidates.append(number)
                }
```
Also extend the write loop so titles and pin state survive the rewrite:
```swift
        for (number, bookmark) in zip(candidates, bookmarks) {
            guard var source = file.objectSource(number) else { continue }
            source.setValue(forKey: "VellumType", raw: Array("/Bookmark".utf8))
            source.setValue(forKey: "VellumNM", raw: PdfTextString.encode(bookmark.id))
            source.setValue(
                forKey: "VellumCreatedAt", raw: PdfTextString.encode(bookmark.createdAt))
            source.setValue(
                forKey: "VellumUpdatedAt", raw: PdfTextString.encode(bookmark.updatedAt))
            if let content = bookmark.content, !content.isEmpty {
                source.setTextString(forKey: "VellumContent", to: content)
                source.setTextString(forKey: "Title", to: content)
            } else {
                source.removeEntry(forKey: "VellumContent")
                source.setTextString(
                    forKey: "Title",
                    to: PdfBookmarks.defaultTitle(pageNumber: bookmark.pageNumber))
            }
            source.setInteger(forKey: "VellumPinned", to: bookmark.pinned ? 1 : 0)
            increment.setObject(number, source: source.sourceBytes)
        }
```

**(f) `rehydrateAnnotationMetadata` — carry `/VellumPinned` on highlights/notes.** Otherwise pinning a highlight is lost the next time any other mutation triggers a PDFKit rewrite on iPadOS 26. In the per-record stamping block, after the `VellumUpdatedAt` line, add:
```swift
                    if record.pinned {
                        source.setInteger(forKey: "VellumPinned", to: 1)
                    } else {
                        source.removeEntry(forKey: "VellumPinned")
                    }
```

**(g) `annotationMetadataRecords` — ownership probe.** Add `VellumPinned` to the `isVellumOwned` disjunction so a third-party annotation Vellum has only ever pinned still counts as owned:
```swift
                let isVellumOwned = CgPdf.has(rawAnnotation, "VellumCreatedAt")
                    || CgPdf.has(rawAnnotation, "VellumUpdatedAt")
                    || CgPdf.has(rawAnnotation, "VellumSelectedText")
                    || CgPdf.has(rawAnnotation, "VellumPinned")
```

**(h) `performUpdate`'s record reconciliation** (the `pdfKitDropsCustomKeys` block that rebuilds `records[index]`) constructs a fresh `Annotation(...)` without `isPinned`, which would silently drop the pin. Add `isPinned: input.isPinned ?? current.isPinned` to that literal.

---

### 2.6 `Vellum/Services/Web/WebSessionBackend.swift` — [MERGE]

**Edit order (packet 10 §2.3):** **1 → 6 → 7**, same as `PdfSessionBackend.swift` above. The
dirty-worktree caveat in packet 10 §2.3 for this file is likewise stale — landed in `783c8835`.

**What main changed** (`8b6b9144`): `WebDocumentIO.annotations(pageNumber:)` returns `Annotation.sortedForDisplay(list)`; `updateAnnotation` gained `pageNumber` and `isPinned` write-through.

**iPad today:** the file has substantial iPad-only work — the `openWebDocument` / `openWebArchive` detached-task restructuring with `(normalized:record:)` tuple returns, no `docId`, no `ensureDocumentId`, `isSaved()` without the `hasLocalSnapshot` gate, `createdAt` echo in `createAnnotation`, and (already present, main regressed it) the `pageNumber` write-through in `updateAnnotation`. **Preserve all of it.**

**Concrete edits — two hunks only:**

1. `func annotations(pageNumber: Int?) -> [Annotation]`: replace
```swift
        guard let pageNumber else { return record.annotations }
        return record.annotations.filter { $0.pageNumber == pageNumber }
```
with
```swift
        let list: [Annotation]
        if let pageNumber {
            list = record.annotations.filter { $0.pageNumber == pageNumber }
        } else {
            list = record.annotations
        }
        return Annotation.sortedForDisplay(list)
```
2. In `updateAnnotation`, after the existing `if let pageNumber = input.pageNumber { ... }` block (keep its iPad comment), add:
```swift
            if let isPinned = input.isPinned {
                record.annotations[index].isPinned = isPinned
            }
```

**Byte compatibility:** the sidecar is `Annotation`'s own `Codable`, so the key lands as `is_pinned` automatically via the `CodingKeys` added in §2.1. No other sidecar change; existing records without the key decode to `nil` → `pinned == false`.

---

### 2.7 `Vellum/Stores/AnnotationStore.swift` — [MERGE]

**What main changed** (`8b6b9144`): `loadAnnotations` wraps the loaded list in `sortedForDisplay`; new `func togglePin(id:) async`; `updateAnnotation`'s optimistic map is wrapped in `sortedForDisplay` and applies `input.isPinned`.

**iPad today:** heavily diverged and **more advanced** than main. Preserve every one of these:
- `selectAnnotation(_ id: String?, scrollIntoView: Bool = true)` and the `if id != nil, scrollIntoView { selectionRequestCount &+= 1 }` guard (iPad touch selection must not re-scroll).
- `pendingCreates: [String: Task<Bool, Never>]` with `@ObservationIgnored`, and the `if let pendingCreate, !(await pendingCreate.value) { return }` early-outs in `updateAnnotation`/`deleteAnnotation`.
- the item-scoped rollback in `deleteAnnotation` (`removedIndex`/`removed`/`wasSelected`).
- the async `create(_:label:)` with `input.createdAt = now`, `PdfDates.rfc3339Now()`, and the in-place reconciliation that preserves concurrent color/content/position/page edits.
- `resolvedDefaultColor` returning `nil` for `.note` (iPad's chosen default; **do not** adopt main's `"#fde68a"`).
- Do **not** adopt main's `await app.syncDocumentId(sessionId:)` — that is packet-1 work.

**Concrete edits — three hunks:**

1. `loadAnnotations`: `annotations = loaded` → `annotations = Annotation.sortedForDisplay(loaded)`.
2. Insert `togglePin` immediately before `func updateAnnotation`:
```swift
    /// Pin or unpin an annotation so it floats to (or leaves) the top of the
    /// sidebar list. Works for highlights, notes, and bookmarks.
    func togglePin(id: String) async {
        guard let annotation = annotations.first(where: { $0.id == id }) else { return }
        await updateAnnotation(UpdateAnnotationInput(
            id: id,
            color: nil,
            content: nil,
            positionData: nil,
            isPinned: !annotation.pinned))
    }
```
3. In `updateAnnotation`, wrap the optimistic map and add the pin field:
```swift
        annotations = Annotation.sortedForDisplay(annotations.map { annotation in
            guard annotation.id == input.id else { return annotation }
            var next = annotation
            if let color = input.color { next.color = color }
            if let content = input.content { next.content = content }
            if let positionData = input.positionData { next.positionData = positionData }
            if let pageNumber = input.pageNumber { next.pageNumber = pageNumber }
            if let isPinned = input.isPinned { next.isPinned = isPinned }
            next.updatedAt = ISO8601DateFormatter.recentTimestamp.string(from: Date())
            return next
        })
```
Note `UpdateAnnotationInput` is a memberwise-init struct with `isPinned` last (after `pageNumber`), so the call in `togglePin` must use labels as written.

**Also check:** iPad's `create(...)` appends the optimistic annotation with `annotations.append(optimistic)` and reconciles by index. Since `sortedForDisplay` is now applied on `updateAnnotation`, a freshly created annotation still lands at the end until the next load/update; that matches main's behavior — do not add a sort to `create`, or the index-based reconciliation breaks.

---

### 2.8 `Vellum/Views/Annotations/AnnotationSidebar.swift` — [MERGE]

**What main changed:**
- `8b6b9144`: `onTogglePin` closure threaded into `AnnotationRow`; `pin.fill` badge in the meta line when pinned; a pin `Button` sibling to the trash button (opacity gated on `hovering || selected || annotation.pinned`); `.contextMenu { Pin to Top / Delete }`; comment on `filteredAnnotations`.
- `34f8c65c`: `.onChange(of: editFieldFocused)` save-on-blur for bookmark rows; a `pencil` edit-title button for bookmark rows; `TextField` gains `prompt: annotation.type == .bookmark ? Text("Add a title…") : nil`; the empty-state hint re-flowed to two lines.

**iPad today:** the same shared file, minus all of the above, plus two iOS adaptations: `.onExitCommand` is wrapped in `#if os(macOS)`, and note content renders as plain `Text(content)` rather than `MarkdownMessage`. **Preserve both.**

**Concrete edits:**

1. **Thread the callback.** In the `ForEach(filteredAnnotations)` `AnnotationRow(...)` call, add between `onChangeColor:` and `onDelete:`:
```swift
                                onTogglePin: {
                                    Task { await annotationStore.togglePin(id: annotation.id) }
                                },
```
and in `private struct AnnotationRow`, add `let onTogglePin: () -> Void` between `onChangeColor` and `onDelete`.

2. **Save bookmark title on blur.** After `.frame(maxWidth: .infinity, maxHeight: .infinity)` on the sidebar `body`, add main's modifier verbatim:
```swift
        .onChange(of: editFieldFocused) { wasFocused, isFocused in
            guard wasFocused, !isFocused, let editingId,
                  annotationStore.annotations.first(where: { $0.id == editingId })?.type == .bookmark
            else { return }
            saveEdit(editingId)
        }
```
(On iPadOS this fires when the software/hardware keyboard focus leaves the field, which is the touch equivalent of macOS blur.)

3. **Pinned badge** in the meta `HStack`, after `Text("p.\(annotation.pageNumber)")`:
```swift
                    if annotation.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: metaSize - 1))
                            .foregroundStyle(palette.primary)
                            .accessibilityLabel("Pinned")
                    }
```

4. **Bookmark title prompt.** Replace `TextField("", text: $editText)` with
```swift
                    TextField(
                        "", text: $editText,
                        prompt: annotation.type == .bookmark ? Text("Add a title…") : nil
                    )
```
Keep the `#if os(macOS) .onExitCommand #endif` wrapping exactly as-is.

5. **Bookmark edit-title button + pin button**, inserted between the content `VStack`'s `.frame(...)` and the existing trash `Button`. Adopt main's code with **one iPad deviation**: `.onHover` never fires for finger touch, so the controls must not be hover-gated on iPad. Use:
```swift
            // Bookmarks have no content to double-tap until a title exists, so
            // they get an explicit edit affordance next to the trash. Touch has
            // no hover, so it stays visible whenever the row is on screen.
            if annotation.type == .bookmark, !editing {
                let hasTitle = annotation.content?.isEmpty == false
                Button(action: onStartEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 14))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(palette.mutedForeground)
                .help(hasTitle ? "Edit bookmark title" : "Add bookmark title")
                .accessibilityLabel(hasTitle ? "Edit bookmark title" : "Add bookmark title")
                .accessibilityIdentifier("annotationRow.editTitle")
            }

            // Pin is a sibling control (not nested under the row tap) so it
            // never also navigates.
            Button(action: onTogglePin) {
                Image(systemName: annotation.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 13))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(annotation.pinned ? palette.primary : palette.mutedForeground)
            .help(annotation.pinned ? "Unpin annotation" : "Pin annotation to top")
            .accessibilityLabel(annotation.pinned ? "Unpin annotation" : "Pin annotation")
            .accessibilityAddTraits(annotation.pinned ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("annotationRow.pin")
```
44×44 pt is the HIG minimum touch target; keep the drawn glyph at main's size by using `.frame(width: 44, height: 44)` on the `Image` (the SF Symbol itself stays at 13/14 pt). If the row gets visually too tall, use `.frame(width: 32, height: 32)` plus `.contentShape(Rectangle().inset(by: -6))` instead — but do NOT go back to a 22×22 hit area.

  **Also apply the same de-hovering to the existing trash button** (`.opacity(hovering || selected ? 1 : 0)` → always visible, 44 pt target) so the three row controls are consistent under touch. Keep `.onHover { hovering = $0 }` on the row for pointer/trackpad users and keep the row's hover background.

6. **Context menu** — long-press on iPadOS, and the touch-friendly path to pin without aiming at a small control. After `.onHover { hovering = $0 }` on the row:
```swift
        .contextMenu {
            Button(annotation.pinned ? "Unpin" : "Pin to Top", action: onTogglePin)
            if annotation.type == .bookmark {
                Button(annotation.content?.isEmpty == false ? "Edit Title" : "Add Title",
                       action: onStartEdit)
            }
            Button("Delete", role: .destructive, action: onDelete)
        }
```

7. Add main's comment on `filteredAnnotations` (`// Store already keeps pin/page/created order; filter only by type.`).

8. **Do NOT** port main's two-line re-flow of the empty-state "Select text to highlight, / or press N to drop a note." hint — that was a macOS-sidebar-width fix and the iPad sidebar differs. Leave the iPad's single `HStack` as-is.

**VoiceOver check:** `annotationRow.pin` must expose a distinct label from the row's select action. The row uses `.onTapGesture(perform: onSelect)` which VoiceOver surfaces as the row's activate action; the pin `Button` is a separate accessibility element because it is a real `Button` sibling. Verify with the `device-interaction` skill that VoiceOver reads "Pin annotation, button" separately from the row.

---

### 2.9 Annotations: verification

Build, then run `PdfPersistenceTests` and `WebLibraryStorageTests` (see §4). Then on device/simulator:
- pin a highlight, a note, and a bookmark; confirm each floats to the top and the `pin.fill` badge appears;
- reopen the document (close tab → reopen) and confirm the pin survived — this is the iPadOS-26 rehydration path (§2.5e/f), the single most likely place for a silent regression;
- title a bookmark, confirm the title is visible in another PDF reader (Files' Quick Look outline, or Apple Books);
- clear a bookmark title back to empty and confirm `/Title` returns to `Bookmark - page N`.

---

### 2.10 `Vellum/Services/Scratchpad/ScratchpadMarkdownExporter.swift` — [VERBATIM]

**Source:** `/Users/ayushdeolasee/Developer/Vellum/main/Vellum/Services/Scratchpad/ScratchpadMarkdownExporter.swift` (720 lines, added by `ba6e4e61`).
**Dest:** `/Users/ayushdeolasee/Developer/Vellum/ipad-app/Vellum/Services/Scratchpad/ScratchpadMarkdownExporter.swift`

Copy the file byte-for-byte. It imports only `Darwin` and `Foundation` — no AppKit, no UIKit, no `#if os(...)`. Verified: `grep -n "AppKit\|NSImage\|NSSavePanel\|NSWorkspace\|UIKit\|#if os" ` returns nothing.

**Two external symbols it needs:**
- `WebStorageMode` (used by `storageExplanation(mode:degraded:)`) — exists on iPad at `Vellum/Services/Web/WebStorage.swift:29` with the same `local/icloud/custom` cases. No change needed. **Do adapt the copy in `storageExplanation` from "on this Mac" to "on this iPad"** — three string literals, cases `.custom`, `.local`, and the `degraded` branch. This is the only edit permitted to this file.
- `ScratchpadAttachmentStore.fileURL(for:preferredDir:)` — see §5.2. On iPad today the signature is `fileURL(for id: String) -> URL?` with no `preferredDir`. **Add the parameter with a default** so both call shapes compile (edit in §2.11).

**Availability notes:** `renameatx_np` + `RENAME_EXCL` (in `publishExclusively`) and `open`/`fstat`/`S_IFMT` (in `copySafeSourceAsset`) are Darwin libc and available on iOS 26. If `renameatx_np` fails to resolve, do NOT downgrade to `FileManager.moveItem` (that reintroduces the TOCTOU the function exists to close) — use `link()`/`unlink()` with `EEXIST` handling instead and note the deviation.

---

### 2.11 `Vellum/Services/Scratchpad/ScratchpadPersistence.swift` — [MERGE] ⚠ cross-packet

**What main changed in *this packet's* commits:**
- `dc3ac525`: hoists `DocumentDataStore.attachmentsDir(forKey: key)` into a local and passes it as `preferredDir` (a storage-layer detail).
- `1d9d4469`: `collectGarbage(in:referencedIds:referencedAsOf:)` gains the `referencedAsOf: Date?` cutoff plus the `isNewerThan(_:url:)` helper (unreadable timestamps → keep the file).
- `5b6b03ce`: `import os`; a `pendingAttachments` `OSAllocatedUnfairLock<[String: Date]>` registry with `pendingGracePeriod` (default 60 s, `nonisolated(unsafe) var` so tests can zero it), `markPending(_:)`, `settlePending(observing:)`, `resetPending()`; `collectGarbage` consults `settlePending` and skips still-pending ids.

**iPad today:** this file is at the *pre-storage-PR* shape — `UserDefaults`-backed `[Entry]` blob keyed by document path, `documentKey(_:)`, `load(for:)`, `save(for:text:)`, `persistedTextsSnapshot()`, coalesced flush; and `ScratchpadAttachmentStore` with a single global flat directory, `collectGarbage(referencedIds:)` (**no `in directory:` parameter**), and `fileURL(for:)` (**no `preferredDir`**). The whole `DocumentDataStore` / `documents/<key>/scratchpad.md` layer belongs to the **packet 1** and is not here.

**Do NOT port** the `DocumentDataStore` rewrite of `ScratchpadPersistence` — that is the packet 1's job. Port only the GC behaviors, adapted to the iPad's current single-directory model.

**Concrete edits:**

1. `import Foundation` → add `import os`.

2. `ScratchpadAttachmentStore.fileURL` — widen the signature so the exporter (§2.10) and any future packet-1 caller both compile:
```swift
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
```
(When the packet 1 lands it will add `?? activeDirectory` to the `preferredDir` element and a `writeDirectory` for `save`. Leave a `// TODO(packet 1)` marker.)

3. Add the pending-attachment registry section verbatim from `5b6b03ce`, placed just above the `knownExtensions` constant:
```swift
    // MARK: - Pending attachments (written, reference not landed yet)

    private static let pendingAttachments = OSAllocatedUnfairLock<[String: Date]>(
        initialState: [:])

    nonisolated(unsafe) static var pendingGracePeriod: TimeInterval = 60

    static func markPending(_ id: String) {
        let deadline = Date().addingTimeInterval(pendingGracePeriod)
        pendingAttachments.withLock { $0[id.lowercased()] = deadline }
    }

    private static func settlePending(observing referencedIds: Set<String>) -> Set<String> {
        let now = Date()
        return pendingAttachments.withLock { pending in
            pending = pending.filter { !referencedIds.contains($0.key) && $0.value > now }
            return Set(pending.keys)
        }
    }

    /// Test seam: the registry is process-global, so a suite touching it must
    /// not inherit or leak entries.
    static func resetPending() {
        pendingAttachments.withLock { $0.removeAll() }
    }
```
Carry main's full doc comments across (they explain the asymmetric failure modes and are the reason the design is defensible).

4. `collectGarbage` — keep the iPad's **global-directory** signature (no `in directory:` parameter; the iPad still has one flat pool) and add both new behaviors:
```swift
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
```
Carry main's long doc comment on `collectGarbage` verbatim (it documents #104 and #105 and why the two mechanisms are both needed).

**Byte compatibility:** none of this touches the `vellum.scratchpad.notes.v1` UserDefaults blob or the attachment filenames. No format change.

---

### 2.12 `Vellum/Stores/ScratchpadStore.swift` — [MERGE] ⚠ cross-packet

**Sequencing note (packet 10 §2.3):** shared with packet 2 (same-tag, not a conflict) — coordinate
hunks rather than diffing the whole file.

**What main changed:**
- `dc3ac525`: three new value types (`ScratchpadAttachmentSnapshot`, `ScratchpadClearTransaction`, `ScratchpadClearRestoration`) and five methods (`clearText`, `undoClear`, `redoClear`, plus private `currentTarget`, `isShowing`, `adoptVisibleIdentity`, `isSameDocument`) on the store; `weak var app: AppStore?`; `currentDocument`/`currentSessionId` fields.
- `1d9d4469`: `pruneOrphanedAttachments` captures `let referencedAsOf = Date()` before dispatching and passes it into `collectGarbage`.
- `5b6b03ce`: `addImage` calls `ScratchpadAttachmentStore.markPending(id)` immediately after `save(...)` returns and **before** `insertMarkdownHandler?` runs.

**iPad today:** no `app`, no `currentDocument`, no `currentSessionId`, no `DocumentDataStore`; `currentKey` comes from `ScratchpadPersistence.documentKey(document)`; `pruneOrphanedAttachments` uses `persistedTextsSnapshot()` and the global-pool `collectGarbage(referencedIds:)`; `flush()` calls `ScratchpadPersistence.save(for:text:)`.

**Port strategy — adapt to the iPad's path-key model.** The packet 1's doc-ID stamping/rekey machinery does not exist here, so drop `DocumentIdentity`, `DocumentDataStore.rekey`, `adoptVisibleIdentity`, and the "post-clear stamp" reasoning. On the iPad, a document's key never changes mid-session, which makes the whole `currentTarget` resolution collapse to a tab lookup.

**Concrete edits:**

1. **Small changes first (no dependencies).**
   - `pruneOrphanedAttachments`: capture the cutoff before dispatching —
```swift
        let texts = ScratchpadPersistence.persistedTextsSnapshot()
        // The sweep runs on a background task while this actor keeps going, so
        // an attachment saved right after this line (a drop or region snapshot
        // landing on a freshly opened note) would not be in `referenced` and
        // would be deleted out from under the note. Collect only against files
        // that already existed when the snapshot was taken.
        let referencedAsOf = Date()
        Task.detached(priority: .utility) {
            var referenced = Set<String>()
            for text in texts {
                referenced.formUnion(ScratchpadAttachmentStore.referencedIds(in: text))
            }
            ScratchpadAttachmentStore.collectGarbage(
                referencedIds: referenced, referencedAsOf: referencedAsOf)
        }
```
   - `addImage`: after the `guard let id = ScratchpadAttachmentStore.save(...)` line, insert `ScratchpadAttachmentStore.markPending(id)` with main's full comment (`5b6b03ce`). It must sit **before** `insertMarkdownHandler?(markdown)` — `insertMarkdownHandler` can hand the snippet straight to a ready editor, so "after" is already too late.

2. **Add the transaction types** at file scope, after `struct ScratchpadImageCapture`:
```swift
struct ScratchpadAttachmentSnapshot: Equatable, Sendable {
    var id: String
    var fileExtension: String
    var data: Data
}

struct ScratchpadClearTransaction: Equatable, Sendable {
    var document: DocumentInfo
    var key: String
    var sessionId: String
    var removedText: String
    var attachments: [ScratchpadAttachmentSnapshot]
}

struct ScratchpadClearRestoration: Equatable, Sendable {
    var transaction: ScratchpadClearTransaction
    /// Exact prefix inserted by Undo. Redo removes only this prefix, preserving
    /// work appended after the clear or after Undo.
    var insertedPrefix: String
}
```

3. **Add store state:**
```swift
    /// Weak like `AiStore.app` — the store is owned by the pane, which owns the
    /// AppStore too, so a strong reference here would be a cycle.
    @ObservationIgnored weak var app: AppStore?
    private var currentDocument: DocumentInfo?
    /// The session (tab) id the current document was loaded under, captured at
    /// load so a clear registered now can be undone against the right tab even
    /// if the active tab changed in the meantime.
    private var currentSessionId: String?
```
and set them in `loadForDocument`:
```swift
    func loadForDocument(_ document: DocumentInfo?) {
        flush()
        let key = ScratchpadPersistence.documentKey(document)
        currentKey = key
        currentDocument = document
        currentSessionId = app?.activeTabId
        setRestored(key.map { ScratchpadPersistence.load(for: $0) } ?? "")
        pruneOrphanedAttachments()
    }
```
and clear them in `clearDocumentContext` (`currentDocument = nil; currentSessionId = nil`).

4. **`clearText` / `undoClear` / `redoClear`** — adapted from `dc3ac525`:
```swift
    /// Capture the note and every referenced attachment before clearing. If any
    /// referenced byte cannot be read, fail closed: leaving the note untouched
    /// is safer than offering an Undo that restores broken image references.
    @discardableResult
    func clearText() -> ScratchpadClearTransaction? {
        guard !text.isEmpty,
              let currentDocument,
              let currentKey,
              let currentSessionId else { return nil }
        let ids = ScratchpadAttachmentStore.referencedIds(in: text)
        var attachments: [ScratchpadAttachmentSnapshot] = []
        for id in ids {
            guard let url = ScratchpadAttachmentStore.fileURL(for: id),
                  let data = try? Data(contentsOf: url) else {
                showWarning("Couldn't safely clear this note because one of its images is unavailable.")
                return nil
            }
            attachments.append(.init(
                id: id, fileExtension: url.pathExtension.lowercased(), data: data))
        }
        let transaction = ScratchpadClearTransaction(
            document: currentDocument, key: currentKey, sessionId: currentSessionId,
            removedText: text, attachments: attachments)
        text = ""
        return transaction
    }

    /// Restore the cleared note ahead of any work created afterward. Attachment
    /// bytes are restored before the markdown is persisted.
    @discardableResult
    func undoClear(_ transaction: ScratchpadClearTransaction) -> ScratchpadClearRestoration? {
        guard let document = currentDocument(for: transaction) else { return nil }
        let showing = isShowing(transaction, document: document)
        if showing { cancelPendingSave() }
        let current = showing ? text : ScratchpadPersistence.load(for: transaction.key)
        let separator = current.isEmpty ? "" : "\n\n"
        let prefix = transaction.removedText + separator
        let restored = prefix + current
        let directory = ScratchpadAttachmentStore.directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for attachment in transaction.attachments {
                try attachment.data.write(
                    to: directory.appendingPathComponent(
                        "\(attachment.id).\(attachment.fileExtension)"),
                    options: .atomic)
            }
        } catch {
            showWarning("Couldn't restore the cleared note. Its recovery data is still available in Undo.")
            return nil
        }
        ScratchpadPersistence.save(for: transaction.key, text: restored)
        if showing { setRestored(restored) }
        return ScratchpadClearRestoration(transaction: transaction, insertedPrefix: prefix)
    }

    /// Remove only the prefix reinserted by Undo. If the restored portion was
    /// edited in place, fail closed rather than deleting ambiguous content.
    @discardableResult
    func redoClear(_ restoration: ScratchpadClearRestoration) -> Bool {
        let transaction = restoration.transaction
        guard let document = currentDocument(for: transaction) else { return false }
        let showing = isShowing(transaction, document: document)
        if showing { cancelPendingSave() }
        let current = showing ? text : ScratchpadPersistence.load(for: transaction.key)
        guard current.hasPrefix(restoration.insertedPrefix) else {
            showWarning("Couldn't redo Clear Scratchpad because the restored text was edited.")
            return false
        }
        let remaining = String(current.dropFirst(restoration.insertedPrefix.count))
        ScratchpadPersistence.save(for: transaction.key, text: remaining)
        if showing { setRestored(remaining) }
        return true
    }

    /// Resolve through the transaction's tab. The path/kind guard keeps a stale
    /// undo transaction from following a reused tab into another document.
    private func currentDocument(for transaction: ScratchpadClearTransaction) -> DocumentInfo? {
        guard let document = app?.tabs.first(where: { $0.id == transaction.sessionId })?.document,
              isSameDocument(document, transaction.document) else { return nil }
        return document
    }

    private func isShowing(_ transaction: ScratchpadClearTransaction, document: DocumentInfo) -> Bool {
        guard currentSessionId == transaction.sessionId, let currentDocument else { return false }
        return isSameDocument(currentDocument, document)
    }

    private func isSameDocument(_ lhs: DocumentInfo, _ rhs: DocumentInfo) -> Bool {
        lhs.kind == rhs.kind && lhs.pdfPath == rhs.pdfPath
    }

    private func cancelPendingSave() {
        saveTask?.cancel()
        saveTask = nil
    }
```
Notes on the deviations from main, and why they are safe on iPad:
- `ScratchpadPersistence.save(for:text:)` is non-throwing on iPad (it writes to the in-memory cache and schedules a coalesced defaults flush), so the `do/catch` wraps only the attachment writes. Keep the `showWarning` for that failure.
- `adoptVisibleIdentity` / `DocumentDataStore.rekey` / `DocumentIdentity.storageKey` are dropped: on iPad the key is `document.pdfPath` and never changes mid-session. Add a `// TODO(packet 1)` comment pointing at `dc3ac525` so the rekey logic can be reinstated when doc-ID stamping lands. (This "adapted form + TODO marker" is how packet 6 breaks cycle C1 — packet 10 §3.1; the cycle breaks at packet 1, which is why this file never blocks on packet 1 landing first.)
- `ScratchpadAttachmentStore.directory` replaces `DocumentDataStore.attachmentsDir(forKey:)` for the same reason.

5. **`Vellum/Models/PaneTree.swift`** — [MERGE], one hunk. Shared with packet 4 (same-tag
   sequencing, not a conflict — packet 10 §2.3); this is the only hunk packet 6 touches in this
   file, packet 4 owns the rest (tab-ownership-on-pane-merge). Change
```swift
        self.scratchpad = ScratchpadStore()
```
to
```swift
        let scratchpad = ScratchpadStore()
        scratchpad.app = app
        self.scratchpad = scratchpad
```
Make no other change to this file — the rest of main's `PaneTree.swift` delta (`b7f71742`, tab ownership on pane merge) belongs to the packet 4.

---

### 2.13 `Vellum/Views/Scratchpad/ScratchpadPanel.swift` → `Vellum/Platform/iOS/ScratchpadPanel_iOS.swift` — [REBUILD]

The iPad has **no** `Vellum/Views/Scratchpad/` directory; the panel lives at `Vellum/Platform/iOS/ScratchpadPanel_iOS.swift` (a UIKit/`UIViewRepresentable` rebuild of the same panel, with `UIDropInteraction`, `ScratchpadWebView`, and the same `vellum-scratchpad://` scheme handler). Everything below goes into that file. **Preserve** the existing drop plumbing, `dropTargeted` overlay, `ScratchpadWebView`, the `UIDropInteractionDelegate` work, and `touchIconButton`-style sizing conventions.

**(a) Undoable clear (from `dc3ac525`).**

Add `@Environment(\.undoManager) private var undoManager` to `struct ScratchpadPanel`. Replace
```swift
    private func clear() {
        scratchpadStore.text = ""
    }
```
with
```swift
    /// Clear first, then register Undo if this context has an undo manager.
    /// SwiftUI only supplies `\.undoManager` where the environment supports
    /// undo, so gating the clear itself on one would leave the only clear
    /// affordance permanently disabled wherever it is absent.
    private func clear() {
        guard let transaction = scratchpadStore.clearText() else { return }
        guard let undoManager else { return }
        registerScratchpadUndo(transaction, store: scratchpadStore, undoManager: undoManager)
    }
```
and add the two free functions from `dc3ac525` (`registerScratchpadUndo` / `registerScratchpadRedo`) at file scope, verbatim, both `@MainActor private func`.

Change the clear button to main's disabled-when-empty form:
```swift
            IconButton(
                help: "Clear scratchpad note",
                disabled: scratchpadStore.text.isEmpty,
                action: clear
            ) {
                Image(systemName: "trash").font(.system(size: 15))
            }
            .accessibilityIdentifier("scratchpad.clear")
```
(`IconButton` on iPad already has `disabled` — `Vellum/Views/Shared/Controls.swift:18`.)

**iPad undo surfacing:** on iPadOS `\.undoManager` is supplied by the window scene's `UIResponder` chain, and users reach it via three-finger swipe / shake / the ⌘Z shortcut. The iPad already has a keyboard shortcut router (`Vellum/Platform/iOS/ShortcutRouter_iOS.swift` + `KeyboardShortcuts_iOS.swift`) — check whether ⌘Z is already routed; if the router swallows ⌘Z for ink undo, it MUST NOT also consume it while the scratchpad editor has focus. Verify the interaction manually before signing off.

**(b) Attachment mark-pending re-arm (from `5b6b03ce`).**

In the `Coordinator`'s `flush()` (iPad `ScratchpadPanel_iOS.swift` line ~480), inside the `for markdown in inserts` loop and **before** `webView.evaluateJavaScript(...)`, add:
```swift
                    // Restart the attachment's GC exemption from the moment the
                    // snippet actually reaches the editor (issue #105). An insert
                    // requested before `ready` sits in `pendingInserts` for the
                    // whole of editor.html + the JS bundle load, which on a cold
                    // start is not the couple of frames the window is sized for.
                    for id in ScratchpadAttachmentStore.referencedIds(in: markdown) {
                        ScratchpadAttachmentStore.markPending(id)
                    }
```

**(c) Markdown export (from `ba6e4e61`) — iOS-native rebuild.**

Main's macOS version uses `NSSavePanel` (destination chosen first, exporter writes straight to it). iOS has no save panel; the iPad's established pattern is stage-to-temp then `DocumentPickerCoordinator_iOS.shared.presentExport(urls:)` (`Vellum/Platform/iOS/DocumentPicker_iOS.swift:69`, already used by the web "Export a Copy…" flow).

Add to `struct ScratchpadPanel`:
```swift
    @State private var showsExportOptions = false
    @State private var exportFeedback: ExportFeedback?
```
plus main's `ExportFeedback` struct, `exportFeedbackBanner(_:)`, `showExportFeedback(_:)`, and `documentTitle` — all four are platform-neutral SwiftUI/Foundation and port verbatim.

Change the bottom overlay to main's shape (export feedback takes precedence over the drop warning) and add `.animation(.easeInOut(duration: 0.2), value: exportFeedback)`.

Add the export button to `header`, immediately before the clear button:
```swift
            IconButton(
                help: "Export scratchpad as Markdown",
                disabled: scratchpadStore.text.isEmpty,
                action: { showsExportOptions = true }
            ) {
                Image(systemName: "square.and.arrow.up").font(.system(size: 15))
            }
            .accessibilityIdentifier("scratchpad.exportMarkdown")
```

Add the sheet:
```swift
        .sheet(isPresented: $showsExportOptions) {
            ScratchpadExportOptionsSheet(
                suggestedTitle: documentTitle,
                storageExplanation: ScratchpadMarkdownExporter.storageExplanation(
                    mode: WebStorageSettings.effectiveMode,
                    degraded: WebStorageSettings.modeIsDegraded
                ),
                onCancel: { showsExportOptions = false },
                onExport: { options in
                    showsExportOptions = false
                    Task { await exportMarkdown(options: options) }
                }
            )
        }
```

Port `private struct ScratchpadExportOptionsSheet` from `ba6e4e61` with these iOS adaptations:
- drop `.frame(width: 480)`; use `.presentationDetents([.medium, .large])` on the sheet content (or wrap in a `NavigationStack` with Cancel/Export toolbar items — either is acceptable; pick the one that matches the iPad's other sheets, e.g. `Vellum/Views/Settings/StorageLocationChoiceSheet.swift`).
- `Form { … }.formStyle(.grouped)` → `Form { … }` (`.formStyle(.grouped)` is macOS-only; `Form` is already grouped on iOS).
- rename the confirm button from "Choose Location…" to **"Export…"** (the iOS flow presents the Files picker *after* the export is staged, so "Choose Location" would be a lie about ordering — keep the identifier `scratchpad.export.chooseLocation` so the accessibility contract matches main).
- keep every `accessibilityIdentifier`: `scratchpad.export.options`, `.copyImages`, `.frontMatter`, `.title`, `.storageExplanation`, `.chooseLocation`.
- `.keyboardShortcut(.cancelAction)` / `.keyboardShortcut(.defaultAction)` are available on iOS — keep them.

Replace main's `exportMarkdown(options:)` entirely:
```swift
    @MainActor
    private func exportMarkdown(options: ScratchpadMarkdownExportOptions) async {
        // iOS has no save panel: stage the export into a private temp dir, then
        // hand the finished file (and its assets folder, if any) to the Files
        // export picker, which copies it wherever the user chooses.
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("scratchpad-export-\(UUID().uuidString)", isDirectory: true)
        let markdown = scratchpadStore.text
        let attachmentsDirectory: URL? = ScratchpadAttachmentStore.directory
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let destination = ScratchpadMarkdownExporter.conflictSafeURL(
                in: staging,
                baseName: ScratchpadMarkdownExporter
                    .suggestedFilename(title: options.title, in: staging)
                    .replacingOccurrences(of: ".md", with: ""),
                pathExtension: "md")
            let summary = try await Task.detached(priority: .userInitiated) {
                try ScratchpadMarkdownExporter.export(
                    markdown: markdown,
                    to: destination,
                    options: options,
                    attachmentsDirectory: attachmentsDirectory
                )
            }.value
            var urls = [summary.markdownURL]
            if let assets = summary.assetsDirectoryURL { urls.append(assets) }
            DocumentPickerCoordinator_iOS.shared.presentExport(urls: urls)
            let imageDetail: String
            switch summary.copiedImageCount {
            case 0: imageDetail = ""
            case 1: imageDetail = " 1 image copied."
            case let count: imageDetail = " \(count) images copied."
            }
            showExportFeedback(ExportFeedback(
                message: "Exported \(summary.markdownURL.lastPathComponent).\(imageDetail)",
                isError: false))
        } catch {
            showExportFeedback(ExportFeedback(
                message: "Couldn’t export the scratchpad: \(error.localizedDescription)",
                isError: true))
        }
    }
```
`attachmentsDirectory` is `ScratchpadAttachmentStore.directory` on iPad today (the flat pool); when the packet 1 lands, switch it to `ScratchpadAttachmentStore.activeDirectory`. Leave a `// TODO(packet 1)` marker.

Do **not** delete the staging directory eagerly — `presentExport` is fire-and-forget and the picker reads from it after this function returns. Temp dirs are reaped by the system; if you want a cleanup, schedule it for ≥ 60 s later.

Note the `documentTitle` helper's `URL(string: path)` web branch: on iPad `appStore.document?.pdfPath` holds the URL for web documents just as on macOS, so it ports unchanged.

**Imports needed in `ScratchpadPanel_iOS.swift`:** it already imports `UniformTypeIdentifiers` (used by `handleDrop`), so no new imports beyond what's there.

---

### 2.14 `Vellum/Stores/AiStore.swift` + `Vellum/Services/Ai/AiPersistence.swift` + `AiPanel_iOS.swift` — undoable Clear Conversation

**`Vellum/Stores/AiStore.swift` — [MERGE].** Shared with packet 5 (packet 10 §2.3, same-tag
sequencing, not a conflict). Port the `dc3ac525` slice only. iPad's `AiStore` diverges from main by
~700 lines (main gained tool summaries, sent-reference chips, per-message lossy decoding, etc. —
those belong to the packet 5). **Take only the six named symbols below — do NOT diff-and-apply the
whole file**, or packet 5's work gets dragged in or clobbered (reinforced again at §5.3 risk 8).
Touch only:

1. Add at file scope, after `LossyAiReference` (or wherever the other AI value types live):
```swift
/// A clear transaction is tied to the exact document and tab that owned it.
/// Undo/Redo can therefore repair that document on disk without ever replacing
/// the transcript of a different tab that happens to be visible later.
struct AiConversationClearTransaction: Equatable, Sendable {
    var document: DocumentInfo
    var sessionId: String
    var removedMessages: [AiMessage]
}
```
2. Replace `func clearConversation()` (iPad line ~348) with main's `@discardableResult func clearConversation() -> AiConversationClearTransaction?` verbatim. **⚠ Behavior change to be aware of:** main *removed* `composerReferences = []` from the clear ("Composer attachments are deliberately left alone: they belong to the next message, not to the transcript being cleared"). Adopt that removal.
3. Add `undoClear(_:)`, `redoClear(_:)`, `currentDocument(for:)`, `isShowing(_:document:)`, `isSameDocument(_:_:)` verbatim from `dc3ac525`. They depend only on `AiPersistence.loadConversation/saveConversation`, `app?.tabs`, `app?.activeTabId`, `cancelActiveRequest()` — all present on iPad.

**`Vellum/Services/Ai/AiPersistence.swift` — [MERGE], CONDITIONAL.** Shared with packet 5 (packet 10
§2.3, same-tag sequencing, not a conflict). The `dc3ac525` change here (`migrateToCurrentStorageKeyIfNeeded` + `migrateCachedConversation`) exists purely to keep the doc-ID rekey in sync, and depends on `DocumentIdentity.sha256Hex`, `DocumentDataStore.rekey`, and `DocumentInfo.docId` — **none of which exist on the iPad branch**. 
- If the **packet 1 has already landed** on `ipad-app`: port both helpers verbatim and add the two call sites (`migrateToCurrentStorageKeyIfNeeded(document:key:)` at the top of `loadConversation` — replacing the inline rekey block — and at the top of `saveConversation`).
- If it has **not**: `[SKIP for now]` — leave `AiPersistence.swift` untouched and record it as a follow-up in the packet 1. The undo/redo above works correctly without it on iPad, because iPad conversation keys are path-derived and stable within a session.

**`Vellum/Platform/iOS/AiPanel_iOS.swift` — [MERGE into `AiPanel_iOS.swift`, after packet 5]**
(packet 10 §2.2). This is not actually a conflict with packet 5's `[VERBATIM]` claim on
`Vellum/Views/AI/AiPanel.swift`: that claim covers the dead `#if os(macOS)`-wrapped file plus the
*structure* of `AiPanel_iOS.swift`; packet 6 contributes only the clear-conversation slice below,
landed **after** packet 5, and **must not otherwise restructure the file**. The iPad AI panel is its
own file with `touchIconButton(system:label:)` chrome. Change the clear button (line ~100) from
```swift
                touchIconButton(
                    system: "trash", label: "Clear conversation"
                ) {
                    aiStore.clearConversation()
                }
                .accessibilityIdentifier("aiPanel.clearConversation")
```
to
```swift
                touchIconButton(
                    system: "trash", label: "Clear AI conversation"
                ) {
                    clearConversation()
                }
                .accessibilityIdentifier("aiPanel.clearConversation")
                .disabled(aiStore.messages.isEmpty)
```
Add `@Environment(\.undoManager) private var undoManager` to the panel struct, plus main's `clearConversation()` helper and the two file-scope `@MainActor private func registerConversationUndo/registerConversationRedo` functions verbatim from `dc3ac525`.

If `touchIconButton` has no `disabled` parameter, add one rather than wrapping in `.disabled(...)` after the fact, so the dimmed styling matches the other controls.

---

### 2.15 Scratchpad/AI: verification

- Type into the scratchpad, drop an image, press Clear, then ⌘Z (or three-finger swipe): the note AND the image must come back. Then Redo: the note goes away again but any text typed after the Undo survives.
- Clear document A's note, switch to tab B, Undo: B's visible note must be untouched and A's note must be restored on disk (switch back to A to confirm).
- Drop an image and immediately switch documents (forces a `pruneOrphanedAttachments` sweep): the image must still render (this is the #104 + #117 fix).
- Export: with an image in the note, export with "Copy linked images" on; open the resulting `.md` in another Markdown app and confirm the image resolves from the adjacent assets folder.

---

## 3. project.yml / Info-iOS.plist / entitlements

**No changes required for this packet.** Consistent with packet 10 §2.2, which names **packet 9 as
the sole editor of `project.yml`** across the whole effort — packet 6 has nothing to hand it.
Confirmed by reading `/Users/ayushdeolasee/Developer/Vellum/ipad-app/project.yml`:

- The `Vellum` target uses directory-based sources (`- path: Vellum` with only `Resources/Info.plist`, `Resources/Info-iOS.plist`, and `Resources/katex` excluded), so the new `Vellum/Services/Scratchpad/ScratchpadMarkdownExporter.swift` is picked up automatically. No pbxproj-equivalent edit exists on iPad — main's `Vellum.xcodeproj/project.pbxproj` hunks in `ba6e4e61` and `dc3ac525` are simply not needed.
- The `VellumTests` target uses `- path: Tests`, so `Tests/ScratchpadMarkdownExporterTests.swift` and `Tests/SafeClearTests.swift` are picked up automatically.
- `Info-iOS.plist`: **no new keys.** `UIDocumentPickerViewController(forExporting:asCopy:)` needs no usage description or entitlement. Nothing in this packet touches photo library, camera, or file-access declarations.
- Entitlements: **none.** `Vellum/Vellum-iOS.entitlements` is deliberately not wired up (free-signing constraint documented in `project.yml`); nothing here needs it.
- No new SPM packages (`OSAllocatedUnfairLock` is in the `os` module shipped with the SDK; `renameatx_np` is Darwin libc).

**Run `xcodegen generate` after adding the new files** so the generated project picks them up before building.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into `Tests/`;
> every other packet's test claim is a specification, not an edit.** Everything in this section is
> the adaptation list packet 9 applies — do not create or modify these files yourself.

### 4.1 `Tests/PdfPersistenceTests.swift` — [MERGE], +3 tests

Graft into `final class PdfPersistenceTests: XCTestCase` (iPad line 162+). All helpers used by these tests already exist in the iPad file: `makeTestPdf` (184), `openSession` (234), `position(_:)` (270), `rawAnnotation` (299), `rawOutlineItems` (304).

- `testBookmarkTitleCreateUpdateClear` — from `34f8c65c`, insert after `testMetadataLastPageTitleAndCustomKeys`'s predecessor (main places it right before that test). Copy **verbatim**; no iOS adaptation needed.
- `testPinHighlightPersistsAndSortsFirst` — from `8b6b9144`, insert before `testDeleteHighlight`. Verbatim.
- `testPinBookmarkPersistsAndSortsFirst` — from `8b6b9144` **plus** the unpin tail added by `a8aa2bad`. Take the post-`a8aa2bad` version (asserts raw `/VellumPinned == 0` and that unpin restores page order). Verbatim.

**⚠ These three tests are the acceptance gate for §2.5(e)(f).** On iPadOS 26 they exercise the rehydration path; if `rehydrateBookmarkMetadata`'s title matcher was not widened, `testBookmarkTitleCreateUpdateClear` will fail at the second `createAnnotation`.

### 4.2 `Tests/WebLibraryStorageTests.swift` — [MERGE], +1 test

Packet 9's `[VERBATIM]` claim on this file (packet 10 §2.1) is downgraded to `[MERGE — content per
packet 6 §4.2]`: packet 6 supplies the adaptation below, packet 9 applies it when it lands the file.
Packet 7 separately adds its own `+1` offline test to the same file — the two additions are
independent inserts, not a conflict.

`testPinAnnotationPersistsAndSortsFirst` — from `8b6b9144` plus the raw-JSON `is_pinned` assertion added by `a8aa2bad`. Insert before the `// MARK: - TTL eviction` section. Verbatim; it uses `WebDocumentIO(url:key:)` directly, which is identical on iPad.

This is the byte-compatibility guard: it asserts the literal `is_pinned` key in the on-disk sidecar JSON. Do not weaken it.

### 4.3 `Tests/ScratchpadMarkdownExporterTests.swift` — [VERBATIM]

Copy `/Users/ayushdeolasee/Developer/Vellum/main/Tests/ScratchpadMarkdownExporterTests.swift` (469 lines) unchanged. It imports only `XCTest` + `@testable import Vellum`, and touches only `ScratchpadAttachmentStore.directoryOverride` / `.activeDirectory` and `ScratchpadMarkdownExporter`.

**One adaptation:** `ScratchpadAttachmentStore.activeDirectory` does not exist on the iPad branch (packet 1). Either
(a) add a no-op-safe `nonisolated(unsafe) static var activeDirectory: URL?` to `ScratchpadAttachmentStore` as part of §2.11 (it costs nothing and makes both this suite and the packet 1's landing easier — **preferred**), or
(b) delete the four `activeDirectory = nil` lines in `setUpWithError`/`tearDownWithError` and note the deviation.

If any test in the file asserts the exact `storageExplanation` strings, update those expectations to match the "on this iPad" wording from §2.10.

### 4.4 `Tests/SafeClearTests.swift` — [MERGE] (new file on iPad, but adapted)

Packet 9's `[VERBATIM]` claim on this file (packet 10 §2.1) is downgraded to `[MERGE — content per
packet 6 §4.4]`: packet 6 supplies the adaptation below (2 tests dropped, see below) and packet 9
applies it when it creates the file — a plain verbatim copy would silently restore the 2 dropped
doc-ID-stamp tests and the pre-relocation `DocumentDataStoreTests` GC-cutoff test (§4.5), producing
duplicates.

`dc3ac525` adds 246 lines and `5b6b03ce` adds 106 more; `1d9d4469` adds 4 lines to `setUp`. Take the **final** version at `7742a895`. It contains a local `SafeClearSessionService` double and `AppStore` fixtures.

**Required adaptations for the iPad branch:**
- Remove `DocumentDataStore.rootDirectoryOverride` set/reset from `setUp`/`tearDown` **if the packet 1 has not landed** (that type does not exist yet); keep `ScratchpadAttachmentStore.directoryOverride` pointed at a per-test temp dir.
- Replace every `DocumentDataStore.attachmentsDir(forKey:)` with `ScratchpadAttachmentStore.directory`.
- Replace `ScratchpadAttachmentStore.fileURL(for:preferredDir:)` calls with `fileURL(for:)` (or keep the labelled form — §2.11 gives it a default, so both compile).
- Drop the two doc-ID-stamp tests, which have no meaning on the iPad's path-key model:
  - `testAiClearFollowsSameSessionStampForUndoAndRedo`
  - `testScratchpadClearFollowsSameSessionStampForUndoRedoAndAttachments`
  Add a file-level comment recording that they are deferred to the packet 1 and cite `dc3ac525`.
- Keep, unchanged in spirit: `testAiUndoRedoIsDocumentScopedAndPreservesNewMessages`, `testScratchpadUndoRestoresAttachmentBytesAndRedoPreservesNewWork`, `testScratchpadUndoForADoesNotReplaceVisibleB`, `testEmptyClearsAreNoOps`, and the three #117 tests: `testAttachmentSurvivesASaveFiredBeforeItsReferenceLands`, `testSettledAttachmentIsCollectedOnceItsReferenceIsRemoved`, `testPendingExemptionLapsesSoAnAbandonedAttachmentIsStillCollected`.
- Keep the `savedGracePeriod` capture/restore and the `resetPending()` on both setUp and tearDown — the registry is process-global and one test sets `pendingGracePeriod = 0`.
- `AiPersistence.awaitPendingFlush()` — confirm it exists on the iPad's `AiPersistence`; if not, drop that line from `tearDown`.

### 4.5 GC-cutoff test relocation (from `Tests/DocumentDataStoreTests.swift`)

`1d9d4469` added `testGCSparesAttachmentsWrittenAfterTheReferenceSnapshot` to `DocumentDataStoreTests`, a file this packet does not own (packet 1 owns it; packet 9's `[VERBATIM]` claim on
`DocumentDataStoreTests.swift` is downgraded per packet 10 §2.1 to `[MERGE — content per owning
packet]`, and this test is the one case packet 6 cares about). Add an equivalent to `SafeClearTests` instead, rewritten for the iPad's global-pool `collectGarbage`. **This relocation is why packet 9 must not copy `DocumentDataStoreTests.swift` verbatim from main** — main's file still has this test in its original location, and a verbatim copy plus this relocated copy in `SafeClearTests` would leave the suite with the same assertion twice, once orphaned from packet 1's actual (`DocumentDataStore`-backed) GC path:

```swift
    /// A sweep collects against a reference set captured at some moment, and it
    /// can run after that moment — `pruneOrphanedAttachments` hands the work to
    /// a background task. An attachment written in that gap is absent from the
    /// set but is not garbage, and deleting it leaves a broken image in the note.
    func testGCSparesAttachmentsWrittenAfterTheReferenceSnapshot() throws {
        let dir = ScratchpadAttachmentStore.directory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let old = dir.appendingPathComponent("old.jpg")
        try Data([1]).write(to: old)

        // Everything already on disk predates the snapshot; the new file does not.
        let referencedAsOf = Date()
        let fresh = dir.appendingPathComponent("fresh.jpg")
        try Data([2]).write(to: fresh)

        ScratchpadAttachmentStore.collectGarbage(
            referencedIds: [], referencedAsOf: referencedAsOf)

        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path),
                       "an attachment older than the snapshot is still collected")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fresh.path),
                      "an attachment written after the snapshot belongs to a later edit")
    }
```

### 4.6 `Tests/ScratchpadImportTests.swift` — [MERGE], +3 lines

In `tearDown`, after the `activeDirectory = nil` line (or after `directoryOverride = nil` if you skipped `activeDirectory`), add:
```swift
        // This suite calls `addImage`, which claims a GC exemption for each id it
        // writes (#105). Harmless if it leaks — the keys are UUIDs — but the
        // registry is process-global, so leave it as we found it.
        ScratchpadAttachmentStore.resetPending()
```

### 4.7 Suites this packet must not break

Run these after the merge — they exercise the same files:
`InkPersistenceTests` (uses `persistPdfKitRewrite` / the rehydration path), `PdfPersistenceTests` (all of it, not just the new tests), `WebLibraryStorageTests`, `ScratchpadImportTests`, `WebStorageLocationTests`.

---

## 5. Risks & cross-packet dependencies

### 5.1 Already done — do not re-port

**`selectionRequestCount` and the scroll-settle-on-late-loading-web-page fix are PRE-RANGE and already on the iPad branch.** They came from `5a8842e6` ("Fix scroll-to-annotation for re-selection and late-loading content", Jul 14), which predates `a42705d1~1`. Confirmed:
- `AnnotationStore.selectionRequestCount` exists on iPad (line 52) with the iPad's *stronger* `scrollIntoView:` gate (line 203) — this is an iPad-only refinement for touch selection and **must be preserved**.
- `WebViewerView_iOS.swift:170` already has `.onChange(of: annotationStore.selectionRequestCount)`.
- `WebViewerView_iOS.scrollToSelected` (line 741) is byte-identical to main's (`WebViewerView.swift:967`).
- `Vellum/Views/Web/WebContentScript.swift` has **zero** changes in the delta range; the iPad's copy has +228/−42 lines of iPad-only touch-selection work that must not be disturbed.

Action: **no port.** Just re-verify the behavior after §2.7's `sortedForDisplay` changes — re-tapping the already-selected sidebar row must still re-scroll, and pinning must not itself trigger a scroll (`togglePin` goes through `updateAnnotation`, which never calls `selectAnnotation`, so it shouldn't — confirm on device).

### 5.2 Cross-packet dependencies (blocking or degrading)

| Dependency | Owner | Effect if missing |
|---|---|---|
| `DocumentDataStore`, `DocumentIdentity`, `DocumentInfo.docId` | **packet 1** | §2.11/§2.12/§2.14 are ported in the *adapted* form described above. Everything works, but the post-clear doc-ID-stamp rekey (`adoptVisibleIdentity`, `migrateToCurrentStorageKeyIfNeeded`) is deferred, and 2 SafeClearTests are dropped. **When the packet 1 lands, revisit every `// TODO(packet 1)` marker this packet leaves behind.** This adapted-forms-plus-TODO-marker strategy is how packet 6 breaks cycle C1 (packet 10 §3.1) — the cycle breaks at packet 1, so packet 6 never has to block on it. |
| `ScratchpadAttachmentStore.activeDirectory` / `writeDirectory` | **packet 1** | §2.10's exporter takes `attachmentsDirectory:`; on iPad we pass the flat `directory`. §4.3 needs a stub `activeDirectory` or four deleted lines. |
| `AppDefaults` + `ScratchDefaultsTrait` | **packet 1 (`c403615f`)** | Not needed by this packet — `SafeClearTests` is XCTest and uses explicit overrides, not the trait. No blocking dependency. |
| `IconButton(disabled:)` | already present on iPad | none |
| `MarkdownMessage` in annotation rows | packet 5 | iPad renders note content as plain `Text`; main renders Markdown. **Out of scope — leave as-is.** |

### 5.2a Edit-order summary for shared files (packet 10 §2.3)

Same-tag, multi-owner files are sequencing, not conflicts. Land in this order:

| file | owners | order |
|---|---|---|
| `Vellum/Models/Models.swift` | 1, 4, 6 | **1 → 4 → 6** — packet 6 last, pin fields only (§2.1) |
| `Vellum/Services/Pdf/PdfSessionBackend.swift` | 1, 6, 7 | **1 → 6 → 7** (§2.5) |
| `Vellum/Services/Web/WebSessionBackend.swift` | 1, 6, 7 | **1 → 6 → 7** (§2.6) |
| `Vellum/Stores/AiStore.swift` | 5, 6 | packet 6 takes only its six named symbols, no ordering requirement beyond that (§2.14) |
| `Vellum/Services/Ai/AiPersistence.swift` | 5, 6 | packet 6's hunk is CONDITIONAL on packet 1 having landed (§2.14) |
| `Vellum/Models/PaneTree.swift` | 4, 6 | packet 6 touches one hunk only; packet 4 owns the rest (§2.12 step 5) |
| `Vellum/Stores/ScratchpadStore.swift` | 2, 6 | coordinate hunks, do not diff-and-apply the whole file (§2.12) |
| `Vellum/Views/AI/AiPanel.swift` → `AiPanel_iOS.swift` | 5, 6 | packet 5 first (owns structure), packet 6's clear-conversation slice after (§2.14) |

`project.yml` is a SKIP for packet 6 (packet 9 is the sole editor across the whole effort, packet 10
§2.2 — see §3), so it is not in this table.

### 5.3 Risks, ranked

1. **`rehydrateBookmarkMetadata` title matcher (§2.5e) — highest risk, silent data loss.** The iPad's iPadOS-26 rehydration identifies Vellum bookmarks by `/Title` prefix `"Bookmark - page "`. Editable titles break that invariant. If not fixed, every mutation on a document with a titled bookmark throws `"Failed to match all PDF bookmarks"` and the user loses the ability to add highlights. `testBookmarkTitleCreateUpdateClear` catches it. Consider matching on `/VellumNM` presence instead of `/Title` entirely as a hardening follow-up.
2. **Pin lost across a PDFKit rewrite on iPadOS 26 (§2.5f/g/h).** A pin written to a page annotation via `PdfAnnotationWriter.setValue` is dropped by the serializer; only the rehydration pass puts it back. `testPinHighlightPersistsAndSortsFirst` catches it only if the test device/simulator is on iPadOS 26 (on 27, `pdfKitDropsCustomKeys` is `false` and the whole path is skipped). **Run the PDF suites on an iPadOS 26 simulator at least once.**
3. **Two-increment bookmark update ordering (§2.5d).** Retitle then pin, in one `UpdateAnnotationInput`, rewrites the file twice. The second increment must be built from bytes re-read from disk, not from the now-stale `document`/`raw` handles. Getting this wrong produces a truncated or double-`/Prev`-chained file. The `ClassicPdfFile` `/Prev` chain support the iPad already has (see §2.3) makes the second increment valid — but only if the base data is the just-written file.
4. **Undo manager availability on iPadOS.** `\.undoManager` is nil in some SwiftUI contexts. Both clear paths intentionally clear first and register undo only if a manager exists (main's comment explains why), so the worst case is "clear works, undo doesn't". Verify ⌘Z reaches the scratchpad and does not collide with the iPad's ink-undo shortcut router (`ShortcutRouter_iOS.swift`).
5. **Touch targets and hover gating (§2.8).** Main hides the pin/trash/edit buttons behind `.onHover`. On a finger-only iPad they would be permanently invisible. The packet's instruction is: always visible + 44 pt targets + `.contextMenu` as the secondary path. This is a deliberate deviation from main and should be called out in the PR body.
6. **`renameatx_np` / `RENAME_EXCL` on iOS (§2.10).** Expected to resolve, but if the build fails, do not fall back to a non-atomic `moveItem`.
7. **`clearConversation` no longer clears `composerReferences` (§2.14).** Behavior change adopted from main. If the iPad AI panel shows composer reference chips, verify they survive a Clear as intended and that no iPad-only code assumed the old behavior.
8. **`AiStore` merge surface.** The iPad's `AiStore` is ~700 lines behind main. Take only the six symbols listed in §2.14; do **not** diff-and-apply the whole file, or you will drag in tool summaries and the packet 5's work.
9. **`ScratchpadPersistence.save` is non-throwing on iPad.** Main's `undoClear`/`redoClear` wrap it in `do/catch`. The adapted versions in §2.12 move it out of the `do` block; make sure the failure banner still fires for the attachment-write failure, which is the case that actually matters.
