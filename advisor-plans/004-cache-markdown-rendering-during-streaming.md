# Plan 004: Stop rebuilding the full markdown NSAttributedString on every SwiftUI update pass

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 314cf9f..HEAD -- Vellum/Views/AI/SelectableMessageText.swift Tests/SelectableMessageTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: advisor-plans/001-land-ai-pipeline-helpers-fix-test-target.md (working test gate only; no file overlap)
- **Category**: perf
- **Planned at**: commit `314cf9f`, 2026-07-12

## Why this matters

AI replies render through `SelectableMessageText`, an `NSViewRepresentable` wrapping an `NSTextView`. Its `updateNSView` **unconditionally** runs the full markdown parse + `NSAttributedString` construction (`AiAttributedRenderer.attributedString`) and only *afterwards* compares the result against the text view to decide whether anything changed. During streaming, `AiStore.appendStreamDelta` mutates the message content once per streamed delta, so every delta re-parses the entire growing message from scratch — O(message length) work per token, O(n²) over a full reply — and every *unrelated* SwiftUI update pass (palette change, activity indicator tick, scroll-driven invalidation) re-parses **every visible message** just to discover nothing changed. Long streamed replies cause visible CPU spikes exactly while the model is talking. The fix: remember what was last rendered (raw content string + colors) on the view and return early before parsing when nothing changed. This turns per-pass cost for unchanged messages from "full parse" to "string compare," and during streaming limits the parse to the one message actually growing.

This plan deliberately does NOT attempt incremental block-level parsing of the streaming message (parse only the trailing open block) — that is a real but larger optimization; see Maintenance notes.

## Current state

`Vellum/Views/AI/SelectableMessageText.swift:31–49`:

```swift
func updateNSView(_ view: MessageContainerView, context: Context) {
    context.coordinator.onQuote = onQuote
    let resolvedColor = NSColor(color)
    let resolvedSecondary = NSColor(secondary)
    let attributed = AiAttributedRenderer.attributedString(   // ← expensive, runs every pass
        for: content,
        color: resolvedColor,
        secondary: resolvedSecondary
    )
    // Repaint when the content OR the palette-derived colors change, so a
    // light/dark appearance switch restyles already-rendered messages.
    let contentChanged = view.textView.textStorage?.string != attributed.string
        || view.textView.textStorage?.length != attributed.length
    let colorsChanged = view.appliedColor != resolvedColor
        || view.appliedSecondary != resolvedSecondary
    if contentChanged || colorsChanged {
        view.setAttributed(attributed, color: resolvedColor, secondary: resolvedSecondary)
    }
}
```

`MessageContainerView` (same file, line 84) already tracks the applied colors:

```swift
final class MessageContainerView: NSView {
    ...
    private(set) var appliedColor: NSColor?
    private(set) var appliedSecondary: NSColor?

    func setAttributed(_ attributed: NSAttributedString, color: NSColor, secondary: NSColor) {  // signature approximate — check line ~122
        self.appliedColor = color
        self.appliedSecondary = secondary
        ...
    }
```

Note why the existing `contentChanged` check compares *rendered* strings: two different markdown inputs can render to the same plain string. The replacement must compare the raw markdown `content` input instead — which is strictly more precise (same input ⇒ same output, because `AiAttributedRenderer.attributedString` is a pure function of `(content, color, secondary)`).

There is an existing test file `Tests/SelectableMessageTests.swift` (82 lines) — read it and follow its structure for any new test.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `Vellum/Views/AI/SelectableMessageText.swift`
- `Tests/SelectableMessageTests.swift` (append tests only)

**Out of scope**:
- `AiAttributedRenderer` / `MarkdownParser` internals — no incremental parsing in this plan.
- `Vellum/Views/AI/AiPanel.swift`, `MarkdownMessage.swift`, `AiStore.swift`.
- Text-selection / quote behavior (`Coordinator`, `onQuoteTapped`) — do not touch.
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/004-cache-message-render`.
- Commit message: e.g. "Skip markdown re-render when message content and palette are unchanged".
- Stage only your own files; never `*.pbxproj`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Track the applied raw content on `MessageContainerView`

In `MessageContainerView`, alongside `appliedColor`/`appliedSecondary`, add:

```swift
/// The raw markdown string the current attributed rendering was built
/// from. Compared by updateNSView to skip re-parsing unchanged messages.
private(set) var appliedContent: String?
```

and set it wherever `appliedColor` is set (the `setAttributed` method — extend its signature to take the raw `content: String` and assign it). Also audit the file for any *other* place that mutates `textView.textStorage` directly (e.g. a clear/reset path); if one exists, it must also reset `appliedContent = nil` — otherwise the cache would go stale. If you find such a path, handle it; if not, note that in your report.

**Verify**: build succeeds.

### Step 2: Early-return in `updateNSView` before parsing

Rewrite `updateNSView` so the comparison happens FIRST, on inputs:

```swift
func updateNSView(_ view: MessageContainerView, context: Context) {
    context.coordinator.onQuote = onQuote
    let resolvedColor = NSColor(color)
    let resolvedSecondary = NSColor(secondary)
    // Compare inputs, not rendered output: attributedString(for:) is a pure
    // function of (content, colors), and parsing is the expensive part —
    // during streaming this runs once per delta on the growing message, and
    // once per message on every unrelated update pass.
    let contentChanged = view.appliedContent != content
    let colorsChanged = view.appliedColor != resolvedColor
        || view.appliedSecondary != resolvedSecondary
    guard contentChanged || colorsChanged else { return }
    let attributed = AiAttributedRenderer.attributedString(
        for: content,
        color: resolvedColor,
        secondary: resolvedSecondary
    )
    view.setAttributed(attributed, content: content, color: resolvedColor, secondary: resolvedSecondary)
}
```

Keep the original comment about light/dark appearance switching (the `colorsChanged` branch preserves that behavior).

**Verify**: build succeeds; `xcodebuild ... test` → TEST SUCCEEDED (in particular `SelectableMessageTests` must still pass — it exercises this view's rendering).

### Step 3: Manual streaming smoke test (if you can run the app)

Run the app, open any PDF, and stream a long AI reply (any configured provider). Confirm: text streams smoothly, the finished message renders markdown correctly (headings, code blocks, lists), toggling system light/dark mode restyles already-rendered messages, and selecting text + quote still works.

If you cannot run the app interactively, state that in your report and rely on step 2's suite run — `SelectableMessageTests` covers render correctness.

## Test plan

- Existing `Tests/SelectableMessageTests.swift` is the regression net for render output — it must pass unchanged.
- Add one test (model it on the existing ones in that file) asserting idempotent updates don't clear or duplicate content: create the view/container the same way existing tests do, apply the same `(content, colors)` twice, and assert the text storage string is unchanged after the second application. If the existing tests construct the representable in a way that makes this awkward (e.g. they test `AiAttributedRenderer` directly rather than the NSView plumbing), instead add a test that `AiAttributedRenderer.attributedString` is deterministic for identical inputs (same `.string` out), and note that the early-return is then covered by build + manual smoke.

## Done criteria

- [ ] Build and full test suite pass, including all pre-existing `SelectableMessageTests`
- [ ] In `updateNSView`, `AiAttributedRenderer.attributedString` is only reachable after the changed-check (`guard` precedes it)
- [ ] `git diff --stat` touches only the two in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

- The `updateNSView` body doesn't match the excerpt.
- `AiAttributedRenderer.attributedString` turns out NOT to be a pure function of `(content, color, secondary)` — e.g. it reads global theme state not passed as a parameter. The input-comparison optimization would then be unsound; report what else it reads.
- `SelectableMessageTests` fails after step 2 — the early-return changed observable behavior; report the failing assertion rather than adjusting the test.

## Maintenance notes

- Deferred follow-up (bigger win, more risk): incremental parsing during streaming — cache parsed blocks and re-parse only the trailing open block as deltas arrive. Worth doing if long-reply streaming still shows CPU spikes after this lands; profile first.
- Related but separate: each streamed delta still triggers a SwiftUI invalidation of the transcript view. If profiling shows layout (not parsing) dominates after this change, the next lever is coalescing deltas in `AiStore.appendStreamDelta` (e.g. 30–60ms batches).
- Reviewer scrutiny: the `appliedContent` reset path (step 1's audit) — a stale cache would show as "message stops updating mid-stream."
