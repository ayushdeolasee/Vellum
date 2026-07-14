# Plan 009: Stop typesetting unclosed display-math blocks on every streamed token

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c874e13..HEAD -- Vellum/Views/AI/MarkdownMessage.swift Vellum/Views/AI/MathRenderer.swift Tests/MarkdownParserTests.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: advisor-plans/001 (compiling test target) and advisor-plans/011 (creates `Tests/MarkdownParserTests.swift`, which this plan extends)
- **Category**: perf
- **Planned at**: commit `c874e13`, 2026-07-14

## Why this matters

AI replies re-render on every streamed token. When the model is in the middle of a display equation (`$$ ... $$` or `\[ ... \]`), the markdown parser has no closing delimiter yet, so it emits the entire remaining text as one `.math` block whose LaTeX source **changes on every token**. Both message renderers hand that block to `MathRenderer.render`, which caches by exact LaTeX string — so mid-equation, every single token is a guaranteed cache miss that runs a full synchronous SwiftMath parse + layout **on the main actor** (and each miss's render stays in the unbounded cache for the session). Streaming a long equation therefore stutters exactly while the equation is being written. The fix: while a display-math block is still open (no closing delimiter yet), emit it as a cheap monospaced `.code` block — mirroring how the parser already treats an unterminated code fence — and only typeset once the block closes. Users see the raw LaTeX stream in monospace, then it snaps to a typeset equation when complete. Also bound the render cache.

## Current state

- `Vellum/Views/AI/MarkdownMessage.swift:198-212` — `MarkdownParser.parse`'s display-math branch, exactly:

```swift
if line.hasPrefix("$$") || line.hasPrefix("\\[") {
    let close = line.hasPrefix("$$") ? "$$" : "\\]"
    var math = String(line.dropFirst(2))
    if math.hasSuffix(close), !math.isEmpty { math = String(math.dropLast(2)); index += 1 }
    else {
        index += 1
        var parts = [math]
        while index < lines.count, !lines[index].hasSuffix(close) {
            parts.append(lines[index]); index += 1
        }
        if index < lines.count { parts.append(String(lines[index].dropLast(2))); index += 1 }
        math = parts.joined(separator: "\n")
    }
    blocks.append(.math(math))
    continue
}
```

The unclosed case is the `while` loop exhausting `lines` without ever seeing the close: `index == lines.count` afterwards, and `.math(everything-to-end)` is emitted anyway.

- `Vellum/Views/AI/MathRenderer.swift:30` — `private static let cache = NSCache<NSString, CachedRender>()` — no `countLimit`. Lines 46-47 — the cache key embeds the exact trimmed LaTeX: `"\(display ? "D" : "T")|\(fontSize)|\(resolved.description)|\(trimmed)"`, so a partial equation that grows each token never hits.
- `MathRenderer.render` is `@MainActor` (line 17-18 declare the enum `@MainActor`) and does synchronous `MTMathUILabel` layout — this is the per-token cost being eliminated for open blocks.
- Both renderers consume `MarkdownParser.parse` output: the SwiftUI `MarkdownMessage` (user bubbles, `blocks` computed property at `MarkdownMessage.swift:140-142`) and the AppKit `AiAttributedRenderer` (assistant bubbles, `SelectableMessageText.swift:227-235`). Both render `.code` cheaply (monospaced text, no SwiftMath). Changing the parser fixes both.
- Comparison behavior this matches: an unterminated ``` fence (lines 188-197 of the same file) already emits `.code` with everything to end-of-input — streaming code renders as it arrives, monospaced.
- `Tests/MarkdownParserTests.swift` — created by plan 011. If it does not exist when you start, STOP (see conditions): plan 011 must run first.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

## Scope

**In scope** (the only files you should modify):
- `Vellum/Views/AI/MarkdownMessage.swift` (the `MarkdownParser.parse` math branch only)
- `Vellum/Views/AI/MathRenderer.swift` (add a cache `countLimit` only)
- `Tests/MarkdownParserTests.swift` (append tests only)

**Out of scope** (do NOT touch):
- `MarkdownMessage`'s SwiftUI view body, `SelectableMessageText.swift` / `AiAttributedRenderer` — they pick the change up automatically via the parser. (The separate per-update re-render memoization is plan 004.)
- `MathRenderer.render`'s rendering logic and `segments(in:)` (inline `$...$` spans only typeset once the closing `$` exists on the line — the regex requires it — so inline math has no open-block problem).
- The `MarkdownBlock` enum shape — do not add cases or associated values; `.code` reuse is the point.
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/009-stream-math-gate`.
- One commit, e.g. "Render unclosed display math as code while streaming; bound math render cache".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Emit `.code` for a display-math block that never closes

In the excerpted branch of `MarkdownParser.parse`, track whether the closing delimiter was actually found and pick the block kind accordingly. Target shape:

```swift
if line.hasPrefix("$$") || line.hasPrefix("\\[") {
    let close = line.hasPrefix("$$") ? "$$" : "\\]"
    var math = String(line.dropFirst(2))
    var closed = false
    if math.hasSuffix(close), !math.isEmpty {
        math = String(math.dropLast(2)); index += 1; closed = true
    } else {
        index += 1
        var parts = [math]
        while index < lines.count, !lines[index].hasSuffix(close) {
            parts.append(lines[index]); index += 1
        }
        if index < lines.count {
            parts.append(String(lines[index].dropLast(2))); index += 1; closed = true
        }
        math = parts.joined(separator: "\n")
    }
    // Still-open block (mid-stream): typesetting a partial equation is a
    // guaranteed MathRenderer cache miss per token — show it as code until
    // the closing delimiter arrives (same treatment as an unterminated
    // code fence above).
    blocks.append(closed ? .math(math) : .code(math))
    continue
}
```

**Verify**: build succeeds.

### Step 2: Bound the MathRenderer cache

In `Vellum/Views/AI/MathRenderer.swift`, replace the bare cache declaration (line 30) with:

```swift
private static let cache: NSCache<NSString, CachedRender> = {
    let cache = NSCache<NSString, CachedRender>()
    // Rendered equations are small, but keys are exact LaTeX strings —
    // long sessions with many one-off renders shouldn't grow unbounded.
    cache.countLimit = 300
    return cache
}()
```

**Verify**: build succeeds.

### Step 3: Tests

Append to `Tests/MarkdownParserTests.swift` (follow the table-driven style plan 011 established there):

1. `$$E = mc^2$$` (single line, closed) → one block, `.math("E = mc^2")` — pins no regression.
2. `"$$\na + b\n= c\n$$"` (multi-line, closed) → `.math("a + b\n= c")` — pins the multi-line close path (note the parser drops the last line's trailing `$$` via `dropLast(2)`; assert against actual current behavior if the exact string differs — the block KIND being `.math` is the load-bearing assertion).
3. `"$$\n\\frac{a}{b}"` (opened, never closed — the mid-stream shape) → last block is `.code`, not `.math`, and contains `\frac{a}{b}`.
4. `"before\n$$x$$\nafter"` → three blocks: `.paragraph("before")`, `.math("x")`, `.paragraph("after")` — pins that closing detection doesn't leak into neighbors.

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`, including the 4 new tests.

## Test plan

Covered in step 3 — the unclosed-block case (test 3) is the behavior this plan introduces; tests 1, 2, and 4 are the regression net proving closed math still typesets. Manual (optional): stream an AI reply containing display math and watch the equation render as monospace while streaming, then snap to typeset on completion.

## Done criteria

- [ ] Build and full test suite pass, including the 4 new parser tests
- [ ] `MarkdownParser.parse` emits `.code` for an unclosed `$$`/`\[` block and `.math` only when the delimiter closed
- [ ] `MathRenderer` cache has `countLimit = 300`
- [ ] `git diff --stat` touches only the three in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `Tests/MarkdownParserTests.swift` does not exist — plan 011 has not run; this plan's test gate depends on it.
- The parse branch doesn't match the "Current state" excerpt (drift since `c874e13`).
- An existing test in `MarkdownParserTests` (from plan 011) fails after step 1 — 011 may have pinned `.math` for the unclosed case; the two plans then disagree and the maintainer decides. Do not edit 011's tests to make them pass.

## Maintenance notes

- Intended UX: partial equations show as monospaced LaTeX while streaming, then typeset when closed. A reviewer seeing "math flashes from code style to rendered" is seeing the design, not a bug.
- If someone later adds new block types to `MarkdownParser`, the unterminated-input convention is now consistent: fences AND display math both degrade to `.code` — keep it that way.
- This plan removes the pathological per-token typesetting; plan 004 (separate) removes the per-update full re-parse/re-render of unchanged messages. Both are worth landing; they compose.
