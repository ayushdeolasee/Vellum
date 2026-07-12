# Plan 002: Only auto-attach the page screenshot when the page is low-text, as the code already documents

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 314cf9f..HEAD -- Vellum/Views/AI/AiPanel.swift Vellum/Stores/AiStore.swift Tests/AiPipelineTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: advisor-plans/001-land-ai-pipeline-helpers-fix-test-target.md (for a working test gate; the code changes don't conflict)
- **Category**: bug
- **Planned at**: commit `314cf9f`, 2026-07-12

## Why this matters

`AiStore` declares `autoPageImageTextThreshold = 200` with a doc comment stating the contract: pages with real extracted text send **no** screenshot, because "screenshots are volatile, expensive, and poor cache material." But the constant is dead code — `grep -rn autoPageImageTextThreshold Vellum/` returns only the declaration. `AiPanel.submit()` captures and attaches a ~1280px JPEG of the current page on **every** PDF chat turn. Every message pays image tokens it doesn't need, and because the screenshot changes with every page move and zoom, it churns the provider prompt caches that recent commits (`e43068a`, `1ca0928`) were specifically built to exploit. The fix is to implement the gate the comment already describes.

## Current state

- `Vellum/Stores/AiStore.swift:369–373` — the declared-but-unused constant:

```swift
/// Below this many extracted characters the current page is treated as
/// scanned/low-text and its rendered image is auto-attached so the model
/// can read it visually. Pages with real text send no image by default —
/// screenshots are volatile, expensive, and poor cache material (§6).
static let autoPageImageTextThreshold = 200
```

- `Vellum/Views/AI/AiPanel.swift:~345–370` — `submit()` captures unconditionally:

```swift
// Capture the session and context synchronously, before any await, so
// a tab switch during image capture can't send to the wrong tab
// (mirrors the original's atomic submit -> sendMessage state read).
let sessionId = appStore.activeTabId
let document = appStore.document
let currentPage = appStore.currentPage
...
let task = Task {
    let image = await aiStore.capturePageImageHandler?(currentPage)
    guard !Task.isCancelled, appStore.activeTabId == sessionId else { return }
    let context = AiContextSnapshot(
        title: document?.title,
        ...
        currentPageImage: image,
        references: references
    )
    await aiStore.sendMessage(messageText, context: context)
}
```

- `Vellum/Stores/AiStore.swift:433–435` — `sendMessage` forwards whatever arrives:

```swift
var images: [AiPageImageSnapshot] = []
if let pageImage = context.currentPageImage { images.append(pageImage) }
images.append(contentsOf: context.references.compactMap(\.image))
```

- `aiStore.pageTexts` is a `[Int: String]` of extracted page text, populated by the background extraction walk and on demand. At submit time the current page may **not be extracted yet** (extraction is ensured later, inside `sendMessage`) — the gate must treat "not extracted yet" as low-text (attach the image) rather than skipping it, so scanned PDFs whose extraction returns nothing still get visual context.
- User-attached snapshot references (`context.references`) are explicit user intent and must NOT be gated.
- Convention: decision logic lives on the store (testable), views stay thin — put the predicate on `AiStore`, not inline in the view.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` (requires Plan 001 landed) |

## Scope

**In scope**:
- `Vellum/Stores/AiStore.swift` (add one small method)
- `Vellum/Views/AI/AiPanel.swift` (gate the capture call)
- `Tests/AiPipelineTests.swift` (append new tests only — do not modify existing ones)

**Out of scope**:
- `Vellum/Views/PDF/PdfSelectionBridge.swift` (`capturePageImage`) — the renderer is fine; only the *decision to call it* changes.
- `Vellum/Views/AI/ComposerReferences.swift` / anything about user-attached snapshots.
- The web-document path (capture already returns nil there).
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/002-gate-auto-page-image`.
- Commit message style: short imperative, e.g. "Gate auto page image on the low-text threshold".
- Stage only your own files; never `*.pbxproj`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add the predicate to `AiStore`

Directly below the `autoPageImageTextThreshold` declaration (`AiStore.swift:373`), add:

```swift
/// Whether the current page's screenshot should be auto-attached: only
/// when the page looks scanned/low-text (or hasn't been extracted yet, so
/// a scan with no extractable text still gets visual context).
static func shouldAutoAttachPageImage(pageText: String?) -> Bool {
    (pageText?.count ?? 0) < autoPageImageTextThreshold
}
```

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → BUILD SUCCEEDED

### Step 2: Gate the capture in `AiPanel.submit()`

In `Vellum/Views/AI/AiPanel.swift`, inside the `Task` in `submit()`, replace:

```swift
let image = await aiStore.capturePageImageHandler?(currentPage)
```

with:

```swift
let image: AiPageImageSnapshot?
if AiStore.shouldAutoAttachPageImage(pageText: aiStore.pageTexts[currentPage]) {
    image = await aiStore.capturePageImageHandler?(currentPage)
} else {
    image = nil
}
```

Note: `aiStore.pageTexts` must be read where `@MainActor` state is accessible — the enclosing view context is main-actor, and reading it before/inside the Task is fine as long as it happens before any suspension or on the main actor. If the compiler objects, read `let pageText = aiStore.pageTexts[currentPage]` alongside the other synchronous captures (next to `let currentPage = appStore.currentPage`) and use that local in the Task — that placement is also more correct (snapshot semantics, matching the surrounding comment).

**Verify**: build succeeds.

### Step 3: Add tests

Append to `Tests/AiPipelineTests.swift` (do not modify existing tests):

```swift
// MARK: - Auto page-image gating

/// Pages with real text send no auto screenshot; scanned/low-text pages
/// (and pages not yet extracted) do.
func testAutoPageImageAttachesOnlyForLowTextPages() {
    XCTAssertTrue(AiStore.shouldAutoAttachPageImage(pageText: nil))
    XCTAssertTrue(AiStore.shouldAutoAttachPageImage(pageText: ""))
    XCTAssertTrue(AiStore.shouldAutoAttachPageImage(
        pageText: String(repeating: "a", count: AiStore.autoPageImageTextThreshold - 1)))
    XCTAssertFalse(AiStore.shouldAutoAttachPageImage(
        pageText: String(repeating: "a", count: AiStore.autoPageImageTextThreshold)))
}
```

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` → TEST SUCCEEDED, new test listed.

## Test plan

- New unit test above (threshold boundary: nil / empty / threshold−1 / threshold).
- Manual smoke (optional, if you can run the app): open a text PDF, send a chat message, and confirm via the usage footer / request logging that no image part is attached; open a scanned PDF (or a page with <200 extracted chars) and confirm the image IS attached.

## Done criteria

- [ ] Build and full test suite pass
- [ ] `grep -rn "autoPageImageTextThreshold" Vellum/ | wc -l` ≥ 2 (declaration + at least one use)
- [ ] `git diff --stat` touches only the three in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

- The excerpts above don't match the live code.
- `AiPanel.submit()` has no `capturePageImageHandler` call (behavior moved) — find where the auto image is captured and report before changing anything else.
- Gating requires touching `sendMessage` or the provider clients — that means the attach decision moved; report instead of expanding scope.

## Maintenance notes

- If OCR-for-scanned-pages ever lands, this gate is where "page has no text but OCR text exists" should be consulted.
- The threshold (200 chars) is a heuristic; if users report the model "can't see" sparse-but-real-text pages (e.g. figure-heavy pages), consider gating on visible-text density instead of raw count.
- Reviewer scrutiny: confirm user-attached snapshot references still flow through unconditionally (`context.references` path untouched).
