# Plan 006: Stop the scratchpad garbage collector from deleting a just-inserted image

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat bff7de4..HEAD -- Vellum/Stores/ScratchpadStore.swift Vellum/Services/Scratchpad/ScratchpadPersistence.swift Vellum/Views/Scratchpad/ScratchpadPanel.swift`
> **Note on the dirty tree (resolved — read this before triggering a STOP)**: when this plan was written the three files had uncommitted changes in the author's working tree. Those hunks have since been diffed against `bff7de4` and are **cosmetic with respect to this plan**: LRU eviction ordering in `ScratchpadPersistence.save`, extension-probing in `ScratchpadAttachmentStore.fileURL`, and a `showWarning` helper in `ScratchpadStore`. The three excerpts this plan actually depends on — `addImage`, `flush`, and `pruneOrphanedAttachments` — are **byte-identical at `bff7de4`**. Execute against committed code; do not STOP over those three unrelated hunks.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none
- **Category**: bug (data loss)
- **Planned at**: commit `bff7de4`, 2026-07-14 (working tree dirty — see note above)

## Why this matters

Images added to the scratchpad (a cropped PDF region snapshot, or a file dropped from Finder) are written to disk immediately, but the note text that *references* them is only updated after a round-trip through the CodeMirror WKWebView. A separate garbage collector deletes any attachment file no note references. If the user adds an image and switches tabs or quits within that round-trip window, the flush persists the note **without** the reference, the GC then treats the freshly-written image as an orphan, and the image is deleted permanently — with no error. The user loses a snapshot they just took. The fix is to give the store a pending-reference set that the GC must respect.

## Current state

`Vellum/Stores/ScratchpadStore.swift` (`@MainActor @Observable`):

- Insert path (lines 64–74) — writes the file, then hands the markdown to the **editor**, not to `text`:
  ```swift
  func addImage(_ capture: ScratchpadImageCapture, label: String) {
      guard let id = ScratchpadAttachmentStore.save(
          data: capture.data, fileExtension: capture.fileExtension) else { return }
      ...
      let markdown = "![\(safeLabel)](\(ScratchpadAttachmentStore.scheme)://\(id))"
      insertMarkdownHandler?(markdown)
  }
  ```
  `insertMarkdownHandler` is set by the editor coordinator (`Vellum/Views/Scratchpad/ScratchpadPanel.swift:407-410`, `enqueueInsert`) and does a fire-and-forget `webView.evaluateJavaScript("window.ScratchpadEditor.insertSnippet(...)")` (~line 454). `text` only updates when CodeMirror posts a `change` message back (`ScratchpadPanel.swift:423-426`), which sets `parent.text`.

- Persist + GC (lines 53–59, 100–111):
  ```swift
  func loadForDocument(_ document: DocumentInfo?) {
      flush()                                   // persists CURRENT text under the OLD key
      let key = ScratchpadPersistence.documentKey(document)
      currentKey = key
      setRestored(key.map { ScratchpadPersistence.load(for: $0) } ?? "")
      pruneOrphanedAttachments()
  }

  private func pruneOrphanedAttachments() {
      Task.detached(priority: .utility) {
          let referenced = ScratchpadPersistence.allReferencedAttachmentIds()
          ScratchpadAttachmentStore.collectGarbage(referencedIds: referenced)
      }
  }
  ```
  The existing comment claims deferring into the detached task "lets any in-flight debounced save settle" — it does not: `flush()` (line 123) *cancels* `saveTask` and writes the current `text`, which at that moment may still lack the just-inserted reference.

- `clearDocumentContext()` (lines 115–119) also flushes, and `Vellum/App/VellumApp.swift:13` flushes on `applicationShouldTerminate` — so quit hits the same window.

- The GC itself: `ScratchpadAttachmentStore.collectGarbage(referencedIds:)` in `Vellum/Services/Scratchpad/ScratchpadPersistence.swift:144-153` deletes every file in the attachments directory whose id isn't in the set. `allReferencedAttachmentIds()` (lines 64–70) scans **persisted** notes only.

- Test seam convention: `ScratchpadAttachmentStore.directoryOverride` (`ScratchpadPersistence.swift:84`, `nonisolated(unsafe) static var`) redirects the attachments dir in tests. `Tests/ScratchpadImportTests.swift` is the pattern to follow for new tests.

## Target design

Add a pending-attachment registry that survives until the id is durably referenced:

1. On `ScratchpadAttachmentStore.save`, the caller (`ScratchpadStore.addImage`) records the new id in a `pendingAttachmentIds: Set<String>` on the store **before** calling `insertMarkdownHandler`.
2. An id is removed from `pendingAttachmentIds` once it appears in a **persisted** note — i.e. after a `save`/`flush` whose text contains it. Simplest correct rule: in `flush()` and in the debounced save, after persisting, subtract `ScratchpadAttachmentStore.referencedIds(in: text)` from the pending set.
3. `pruneOrphanedAttachments()` passes `referenced ∪ pendingAttachmentIds` to `collectGarbage`, so a pending id is never collected.
4. **Belt and braces for quit/switch**: in `addImage`, also make the reference durable without waiting for the JS round-trip. The cleanest way that respects the editor's echo-guard: keep `insertMarkdownHandler` as the visual insert, but if the round-trip hasn't landed by the time `flush()` runs, append the pending markdown to the persisted text. Implement this by having `addImage` stash `(id, markdown)` and `flush()` persist `text` plus any stashed markdown whose id isn't already present in `text`. Do **not** mutate `text` directly from `addImage` — that would fight the coordinator's `pendingText`/`editorText` echo guard (`ScratchpadPanel.swift`, `flush()`), which exists to stop caret resets.

If (4) proves to interact badly with the echo guard, shipping (1)–(3) alone still closes the delete-the-image hole (the file survives; only its reference is lost, and the user can re-insert). Prefer both; degrade to (1)–(3) with a note rather than fighting the guard.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` |
| Editor bundle (only if JS changes — it should NOT) | `cd tools/scratchpad-editor && npm ci && npm run build` | bundle rebuilt |

## Scope

**In scope** (the only files you should modify/create):
- `Vellum/Stores/ScratchpadStore.swift`
- `Vellum/Services/Scratchpad/ScratchpadPersistence.swift` (only if the GC signature needs the extra set — prefer passing the union from the store, leaving this file untouched)
- `Tests/ScratchpadAttachmentGCTests.swift` (create)

**Out of scope** (do NOT touch):
- `tools/scratchpad-editor/src/**` and `Vellum/Resources/katex/editor.bundle.js` — no JS changes; if you think you need one, STOP.
- `Vellum/Views/Scratchpad/ScratchpadPanel.swift`'s coordinator echo guard (`pendingText`/`editorText`/`flush`) — read it, don't restructure it.
- The attachment file format, the `vellum-scratchpad://` scheme, and `ScratchpadAttachmentStore.save`/`fileURL`.

## Git workflow

- The working tree at `bff7de4` has **uncommitted changes in the exact files this plan touches**. Create a fresh worktree from the parent folder (`git worktree add 006-scratchpad-attachment-race`) — it will be based on the committed state, which may differ from what a collaborator has locally. If your drift check shows the committed code differs materially from the "Current state" excerpts (which describe the dirty tree), STOP and report.
- Commit style: sentence-case imperative, e.g. "Protect just-inserted scratchpad attachments from the orphan collector".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reproduce the race in a test (red)

`Tests/ScratchpadAttachmentGCTests.swift`, using `ScratchpadAttachmentStore.directoryOverride` for a temp dir and a temp `UserDefaults` suite (or by saving/restoring `ScratchpadPersistence.notesKey`). Simulate the window: save an attachment via `ScratchpadAttachmentStore.save`, do **not** put its reference in any persisted note, then run the GC as `pruneOrphanedAttachments` does (`allReferencedAttachmentIds()` → `collectGarbage`). Assert the file is gone — this is the bug. Then, after the fix, the assertion inverts (step 3). Structure the test so `ScratchpadStore.addImage`'s pending registration is what protects it.

Note: `ScratchpadStore` is `@MainActor`; mark tests `@MainActor` accordingly, and set `insertMarkdownHandler` to a stub that records the markdown (simulating the editor never round-tripping).

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → the new test **fails** in the way described (documents the bug).

### Step 2: Implement the pending registry (items 1–3 of the target design)

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 3: Flip the test to green + add the durability case

Update step 1's test to assert the file **survives** the GC when the round-trip hasn't landed. Add a second test: after the reference does land in `text` and is flushed, the pending set no longer protects it, and an unreferenced (genuinely orphaned) file is still collected — the GC must not become a no-op.

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, both tests pass.

### Step 4: Durable reference on flush (item 4) — optional, attempt it

Implement the stash-and-append-on-flush behavior. Add a test: `addImage` → immediately `flush()` (no round-trip) → the persisted note text contains the `vellum-scratchpad://<id>` reference.

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`.
If the echo guard makes this misbehave (duplicate insert when the round-trip *does* land — the dedupe check "id already present in `text`" should prevent it), and one fix attempt doesn't resolve it, drop step 4, keep steps 1–3, and say so in your report.

### Step 5: Behavioral spot-check

Launch the app, open a PDF, crop a region into the scratchpad, and **immediately** ⌘-switch tabs (and separately: immediately ⌘Q and relaunch). Expected: the image is still in the note (with step 4) or at minimum the attachment file still exists on disk under `~/Library/Application Support/…/scratchpad-attachments/` (steps 1–3 only). Report which you observed. If you can't drive the GUI, say so.

## Test plan

Three tests in `Tests/ScratchpadAttachmentGCTests.swift`:
1. pending attachment survives GC when its reference hasn't round-tripped;
2. genuinely orphaned attachment (no reference, not pending) is still collected;
3. (with step 4) `addImage` + `flush` persists the reference into the note text.

Pattern: `Tests/ScratchpadImportTests.swift`. Always use `directoryOverride` — never touch the real attachments directory.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "pendingAttachmentIds" Vellum/Stores/ScratchpadStore.swift` → ≥ 3 (declare, insert, union into GC)
- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, including the new GC tests
- [ ] `git diff --stat` shows **no** change to `tools/scratchpad-editor/` or `Vellum/Resources/katex/`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The committed code differs materially from the "Current state" excerpts (they were taken from a dirty tree — a real possibility; report the diff rather than guessing).
- The fix seems to require a JS change in `tools/scratchpad-editor/src/`.
- Step 4 causes duplicate image insertions and the id-dedupe doesn't fix it in one attempt (fall back to steps 1–3, don't keep iterating).
- You discover the GC also runs from a path other than `pruneOrphanedAttachments` (grep `collectGarbage`) — the union must be applied at every call site; if there's a call site outside `ScratchpadStore`, report it.

## Maintenance notes

- The pending set is in-memory: a hard crash between `save` and the reference landing still leaves an orphan file (harmless — it gets collected on the next load). That asymmetry is intended: leaking a file is fine, deleting the user's image is not.
- Reviewer should scrutinize: the GC must not become permanently permissive (test 2 guards this), and `pendingAttachmentIds` must be cleared on `clearDocumentContext` only *after* the flush that persists the references.
- Related: `ScratchpadPanel.performDragOperation` (~lines 265–298) still reads dropped file bytes (`Data(contentsOf:)`) on the main thread before dispatching to a background queue, despite a comment saying otherwise — a small separate fix, tracked in `plans/README.md` backlog, not in this plan.
