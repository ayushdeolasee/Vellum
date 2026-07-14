# Plan 002: Surface annotation save/update/delete failures to the user instead of silently logging

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only the files listed as in scope. If any STOP condition occurs, stop and
> report — do not improvise.
>
> **BASE (read carefully)**: this plan targets the **trunk** (`origin/main`), not
> the `scratchpad` branch. `origin/main` at `f47e9ce` **does not compile** (a
> mis-merge from PR #41). The repair is committed on the local branch
> `worktree-agent-a766681e8b3218d4c` (commit `1740cf1`) and has been reviewed and
> approved, but is not yet merged to `main`. **First action in your worktree:**
> `git merge --no-edit worktree-agent-a766681e8b3218d4c`, then confirm
> `xcodebuild ... build` → `BUILD SUCCEEDED` **before** making any change of your
> own. If that merge conflicts or the build still fails, STOP.
>
> **Drift check (after the merge)**: `git diff --stat 1740cf1..HEAD -- Vellum/Stores/AnnotationStore.swift Vellum/Views/Panes/PaneView.swift` → expect empty.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 000 (trunk repair — merge it, per the BASE note)
- **Category**: bug
- **Planned at**: commit `1740cf1` (repaired trunk), 2026-07-14

## Why this matters

Vellum's core promise is that annotations are embedded in the PDF file itself.
When that write fails — disk full, a locked/read-only file, a PDF PDFKit refuses
to re-serialize — the app logs to `NSLog` and silently rolls back. The user sees
their highlight appear and then vanish, or never notices at all, and believes it
was saved. This is data-loss-by-silence on the app's most important path.

On the trunk this is **worse than it looks**: `create()` is now fully optimistic
— it appends the annotation, returns immediately, and does the actual write in a
detached `Task` whose `catch` logs and removes the row. So the failure happens
after the user has already moved on, with nothing on screen. The store knows
about every failure; it simply has no user-visible error channel.

## Current state (verified on the repaired trunk, `1740cf1`)

`Vellum/Stores/AnnotationStore.swift` — `@MainActor @Observable final class
AnnotationStore` (line 39), holding `private let app: AppStore` (line 40). It has
**no** error property — nothing a view can observe. Three swallow sites:

`updateAnnotation` (declared line 132), catch at **line 155**:
```swift
} catch {
    NSLog("[annotation-store] Failed to update annotation: \(error)")
    // Reload on failure to revert optimistic update
    if app.activeTabId == sessionId {
        await loadAnnotations()
    }
}
```

`deleteAnnotation` (declared line 163), catch at **line 181**:
```swift
} catch {
    NSLog("[annotation-store] Failed to delete annotation: \(error)")
    // Revert on failure
    if app.activeTabId == sessionId {
        annotations = previous
    }
}
```

`create(_:label:)` (declared line 209) — **synchronous**, returns the optimistic
annotation immediately and spawns an inner `Task` (registered in
`pendingCreates`) that performs the write. Its catch is at **line 232**:
```swift
} catch {
    NSLog("[annotation-store] Failed to create \(label): \(error)")
    // Roll back the optimistic insert if the write failed and we're
    // still on the same document.
    if app.activeTabId == sessionId {
        annotations.removeAll { $0.id == id }
        if selectedAnnotationId == id { selectedAnnotationId = nil }
    }
}
```
(There is also a `loadAnnotations` catch at line 78 — **leave it alone**; a failed
*read* already shows an empty list and is out of scope.)

### Where the banner goes

The trunk is **split-screen**: `WorkspaceStore` owns a tree of panes, and **each
pane has its own `AnnotationStore`**. So the banner is per-pane, not app-wide.
`Vellum/Views/Panes/PaneView.swift` (`struct PaneView`, line 9) is the correct
anchor — it already scopes the pane's stores into the environment:
```swift
.environment(pane.annotations)   // line 65
.environment(pane.ai)            // line 66
```
Put the banner overlay on the pane's content so it appears in the pane whose save
failed. Do **not** hoist it to `ContentView` — with two panes open, an app-wide
banner would misattribute the failure.

### Pattern to follow (inline — the exemplar does not exist on this branch)

There is no `ScratchpadStore` on the trunk, so implement this shape directly. A
transient, auto-clearing, observable message:
```swift
private(set) var saveError: String?
@ObservationIgnored private var saveErrorTask: Task<Void, Never>?

private func reportSaveError(_ message: String) {
    saveError = message
    saveErrorTask?.cancel()
    saveErrorTask = Task { [weak self] in
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        self?.saveError = nil
    }
}
```
For the banner's visual style, match the repo's existing chrome — read
`Vellum/Views/Shared/Controls.swift` and the palette usage in `PaneView.swift`
(`@Environment(\.palette)`), and use `palette.destructive` for the error tint.
Animate on the value (`.animation(.easeInOut(duration: 0.2), value:)`) and give
it `.accessibilityIdentifier("annotations.saveError")`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Merge the approved trunk repair (FIRST) | `git merge --no-edit worktree-agent-a766681e8b3218d4c` | clean merge |
| Regenerate project (only if a file is added) | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests -destination 'platform=macOS'` | `TEST SUCCEEDED` (32 tests pass on the repaired trunk) |

## Scope

**In scope** (the only files you should modify):
- `Vellum/Stores/AnnotationStore.swift`
- `Vellum/Views/Panes/PaneView.swift`
- `Tests/AnnotationStoreErrorTests.swift` (create — only if step 3's feasibility check passes)

**Out of scope** (do NOT touch):
- `Vellum/Services/Pdf/**`, `Vellum/Services/Web/**` — this is the error
  *reporting* path, not the persistence machinery. Do not change how saves work,
  and do not add retries.
- The optimistic-update / rollback logic in the three catch blocks — keep the
  existing revert behavior **exactly**; you are only *adding* an error signal.
- The `loadAnnotations` catch (line 78).
- `Vellum/App/ContentView.swift`, `WorkspaceStore.swift` — the banner is per-pane.

## Git workflow

- You are already in an isolated worktree; do NOT run `git worktree add`.
- Merge the repair branch first (see BASE note), then commit your own work on top.
- Commit style: sentence-case imperative — e.g. "Surface annotation save failures as a transient banner".
- Do NOT push, merge to main, or open a PR.

## Steps

### Step 1: Merge the approved trunk repair and establish a green baseline

`git merge --no-edit worktree-agent-a766681e8b3218d4c`, then run the build and the
tests. Both must pass **before** you change anything.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`; `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`. If either fails, STOP.

### Step 2: Add the error channel to `AnnotationStore`

Add `saveError` / `saveErrorTask` / `reportSaveError(_:)` per the pattern above.
Call `reportSaveError` from all three catch blocks (lines ~155, ~181, ~232),
**keeping** the existing `NSLog` lines and the existing rollback logic. Messages
should name the operation and carry `error.localizedDescription`, e.g.
`reportSaveError("Couldn't save highlight — \(error.localizedDescription)")`. In
`create`, use the existing `label` parameter to name the operation.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 3: Render the banner in `PaneView`

Overlay the pane's content when `pane.annotations.saveError != nil`, styled per
the pattern section, with `.accessibilityIdentifier("annotations.saveError")`.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 4: Unit-test the error channel (feasibility-gated)

`AnnotationStore` takes `app: AppStore` and reads `sessions` via
`app.sessions`. Determine whether a fake/stub `SessionService` can be injected
through `AppStore` without changing any initializer signature. Look at
`Tests/PdfPersistenceTests.swift` for the fixture pattern.

- If injectable: add `Tests/AnnotationStoreErrorTests.swift` — a failing create
  sets `saveError` and rolls the optimistic row back; a failing update sets
  `saveError` and reloads; a failing delete sets `saveError` and restores
  `previous`. For create, remember the write is in a detached `Task` — await it
  via the store's existing pending-create mechanism rather than sleeping.
- If NOT injectable without changing an initializer: **skip the test file**, say
  so plainly in your report, and rely on step 5.

**Verify** (if written): `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, new tests pass.

### Step 5: Behavioral spot-check

Open a PDF, `chmod 444` the file, add a highlight. Expected: the banner appears in
that pane and auto-clears; the highlight does not survive a reopen. `chmod 644`
afterwards. If you cannot drive the GUI, say so plainly — do not claim it.

## Done criteria (ALL must hold)

- [ ] `grep -c "reportSaveError" Vellum/Stores/AnnotationStore.swift` → ≥ 4 (declaration + 3 call sites)
- [ ] `grep -n "annotations.saveError" Vellum/Views/Panes/PaneView.swift` → 1 match
- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`
- [ ] Rollback logic intact: `grep -n "previous" Vellum/Stores/AnnotationStore.swift` still matches inside `deleteAnnotation`, and `create`'s catch still calls `annotations.removeAll`
- [ ] `git diff --stat 1740cf1..HEAD` shows only in-scope files

## STOP conditions

Stop and report (do not improvise) if:
- The merge of `worktree-agent-a766681e8b3218d4c` conflicts, or the build/tests fail before you change anything.
- The catch blocks don't match the excerpts above (drift since `1740cf1`).
- Showing the banner requires changing `PaneView`'s or `AnnotationStore`'s initializer signature, or plumbing a store through a new path.
- Step 4's stub would require making `SessionService` a protocol or otherwise refactoring production types — skip the tests instead and say so.

## Maintenance notes

- Each pane has its own store, so two panes can show two different banners; that
  is intended. A reviewer should confirm the banner does not cover the selection
  popover or the sticky-note overlay.
- `AiToolEngine` also creates annotations through this store, so AI-driven failures
  now surface through the same banner — acceptable, and arguably desirable.
- If a "Retry" affordance is added later, revisit `updateAnnotation`: on failure it
  reloads from disk, discarding the user's edit, so there is nothing to retry from.
