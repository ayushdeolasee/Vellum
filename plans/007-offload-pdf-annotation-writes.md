# Plan 007: Move PDF annotation serialization and disk writes off the main actor

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat bff7de4..HEAD -- Vellum/Services/Pdf/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: 001 (CI/test gate) — strongly recommended, since `Tests/PdfPersistenceTests.swift` is the safety net for this change
- **Category**: perf / concurrency
- **Planned at**: commit `bff7de4`, 2026-07-14

## Why this matters

Every highlight, note, and bookmark create/update/delete synchronously does a full read → PDFKit parse → mutate → re-serialize → atomic disk write, **on the main actor**. On a large or heavily annotated PDF that means the UI freezes for the duration of every single annotation edit. The web subsystem already solved exactly this: `WebSessionBackend` hops off the main actor with `Task.detached(priority: .userInitiated)` for its heavy archive write. The PDF path never got the same treatment. This plan applies the established pattern — keeping PDFKit object mutation on the main actor (PDFKit is not documented as thread-safe) and offloading only the byte-level serialize + write.

## Current state

- `Vellum/Services/Pdf/PdfSessionBackend.swift` (403 lines) — `PdfSessionBackend` (line ~11) and `PdfDocumentSession` (line ~104) are both `@MainActor`; the file contains **no** `Task.detached`. Class comment (~lines 114–116) states mutations "are written immediately".
  - `createAnnotation` (~lines 168–216), `updateAnnotation` (~lines 222–254), `deleteAnnotation` (~lines 258–299) each do, inline and synchronously:
    1. `PdfDocumentLoader.loadForMutation(...)` — full file read + PDFKit + CGPDF parse
    2. mutate `PDFAnnotation` objects on the `PDFDocument`
    3. `document.dataRepresentation()` — full re-serialize to `Data`
    4. `PdfAtomicWriter.save(...)` — write + rename (and/or `saveThroughPdfKit`)
- The exemplar to copy — `Vellum/Services/Web/WebSessionBackend.swift` (~lines 296–306) — offloads its heavy write:
  ```swift
  Task.detached(priority: .userInitiated) { ... write ... }
  ```
  Read this function in full before starting; match its error-propagation and ordering conventions.
- `Vellum/Services/Pdf/PdfAtomicWriter.swift` (902 lines) — the write-and-rename machinery. **Do not change its logic**; it is the crash-safety guarantee. You are changing *where it is called from*, not what it does.
- Serialization ordering matters: two annotation edits in quick succession must not race to write the same file out of order. Whatever you build must serialize writes per session (an actor, or a single-flight task chain), not fire N unordered detached tasks.
- The safety net: `Tests/PdfPersistenceTests.swift` (705 lines) covers the embed/round-trip behavior. It must keep passing unchanged.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` — all existing PDF persistence tests still pass |

## Suggested executor toolkit

- If the `swift-concurrency-pro` skill is available, invoke it before finalizing the design in step 2 — the actor-isolation boundaries here are the whole risk of this plan.

## Scope

**In scope** (the only files you should modify/create):
- `Vellum/Services/Pdf/PdfSessionBackend.swift`
- `Tests/PdfWriteConcurrencyTests.swift` (create)

**Out of scope** (do NOT touch):
- `Vellum/Services/Pdf/PdfAtomicWriter.swift` — the atomic-write algorithm stays byte-identical.
- `Vellum/Services/Pdf/PdfAnnotationCodec.swift`, `PdfBookmarks.swift`, `PdfDocumentLoader` — the parse/encode layers.
- `Vellum/Stores/AnnotationStore.swift` — the async call signatures it awaits must not change (the store already `await`s these; keep the same `async throws` API surface so no call site changes).
- `Tests/PdfPersistenceTests.swift` — must pass **unmodified**. If you find yourself editing it, that's a behavior change; STOP.

## Git workflow

- Fresh worktree: `git worktree add 007-pdf-write-offload` from the parent folder.
- Commit style: sentence-case imperative, e.g. "Offload PDF annotation serialization and writes off the main actor".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Map the three write paths

Read `createAnnotation`, `updateAnnotation`, `deleteAnnotation` in full and write down, for each: what runs before the mutation (load), what the mutation touches (PDFKit objects), and exactly which calls produce/consume `Data` (`dataRepresentation()`, `PdfAtomicWriter.save`, `saveThroughPdfKit`). Identify the precise cut line where PDFKit objects stop being needed and only `Data` + a file URL remain. Do not edit yet.

**Verify**: you can state the cut line for all three paths. If any path *interleaves* PDFKit access after serialization, note it — that path may need restructuring, or STOP if it can't be cleanly cut.

### Step 2: Introduce a per-session serialized writer

Add a private `actor` (e.g. `PdfFileWriter`) owned by `PdfDocumentSession`, with one method that takes `Data` + destination URL and performs the `PdfAtomicWriter.save` call. Because it's an actor, calls from the session are serialized in submission order — this preserves today's write ordering. The session's `create/update/delete` methods keep their `async throws` signatures and `await` the writer, so errors still propagate to `AnnotationStore` (which surfaces them — see plan 002).

Keep on the main actor: `loadForMutation`, all PDFKit mutation, and `document.dataRepresentation()` **if and only if** step 1 shows it must touch PDFKit objects on the main actor. Prefer moving `dataRepresentation()` off only if you can demonstrate it's safe; the guaranteed win (the disk write) is the file I/O.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 3: Existing suite must pass untouched

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, `Tests/PdfPersistenceTests.swift` unmodified (`git diff --stat Tests/PdfPersistenceTests.swift` → empty).

### Step 4: Add an ordering/concurrency test

`Tests/PdfWriteConcurrencyTests.swift`: fire several annotation creates/updates in rapid succession against a temp copy of a fixture PDF (reuse `PdfPersistenceTests`' fixture setup — read how it builds its temp PDF), await them all, then reopen the file and assert **every** annotation is present and the file parses. This is the regression guard against out-of-order or lost writes.

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, new test passes; run it 3 times to catch flakiness.

### Step 5: Behavioral spot-check

Open a large PDF (ideally 100+ pages with existing annotations), add several highlights in quick succession, and confirm the UI stays responsive (scrolling/typing doesn't hitch) and every highlight persists after close+reopen. Report if you can't drive the GUI.

## Test plan

- Existing: `Tests/PdfPersistenceTests.swift` passes unmodified (the round-trip contract).
- New: `Tests/PdfWriteConcurrencyTests.swift` — rapid successive writes all land, in order, file remains valid.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "actor " Vellum/Services/Pdf/PdfSessionBackend.swift` → ≥ 1 (the serialized writer)
- [ ] `git diff --stat Vellum/Services/Pdf/PdfAtomicWriter.swift` → empty (unchanged)
- [ ] `git diff --stat Tests/PdfPersistenceTests.swift` → empty (unchanged)
- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED` (3 consecutive runs, no flakes)
- [ ] `AnnotationStore` unmodified — the `async throws` API of create/update/delete is unchanged
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 1 finds a path where PDFKit object access is interleaved with serialization such that no clean cut line exists.
- Any existing test in `Tests/PdfPersistenceTests.swift` fails, or you feel the need to modify it.
- The compiler forces you to make `PDFDocument`/`PDFAnnotation` `Sendable` (e.g. via `@unchecked Sendable`) to cross the actor boundary — that would be moving PDFKit objects off the main actor, which this plan explicitly forbids. Re-cut the boundary so only `Data` crosses.
- The new concurrency test is flaky across the 3 runs.

## Maintenance notes

- The write ordering guarantee now lives in the actor's serialized mailbox. Any future code that writes the PDF from outside `PdfDocumentSession` bypasses it — reviewers should reject direct `PdfAtomicWriter.save` calls from new sites.
- With plan 002 landed, a failed background write surfaces as a user-visible banner; without it, failures are still only `NSLog`-ed. Land 002 first if you can.
- Deferred: batching/debouncing multiple rapid edits into one file write (a bigger design change — today each edit is one full rewrite by design, since annotations live in the PDF).
