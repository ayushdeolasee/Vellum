# Plan 011: Unit-test the markdown/math parsing core and fix `plainPreview`'s divergent math handling

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c874e13..HEAD -- Vellum/Views/AI/MarkdownMessage.swift Vellum/Views/AI/MathRenderer.swift Vellum/Views/Annotations/StickyNoteOverlay.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: advisor-plans/001 (the test target must compile before any new test can run)
- **Category**: tests / tech-debt
- **Planned at**: commit `c874e13`, 2026-07-14

## Why this matters

`MarkdownParser.parse` and `MathRenderer.segments` are the pure parsing core behind **every** rendered AI message and sticky note (both the SwiftUI and AppKit renderers consume them), yet neither has a single direct unit test — a regression in list/table/fence detection or in the currency-vs-math `$` disambiguation would silently mis-render user-facing content. Both are pure synchronous functions over plain data, so they are the cheapest high-value tests in the codebase.

There is also one already-shipped divergence to fix while pinning behavior: `MarkdownParser.plainPreview` (used for collapsed sticky-note pills and tooltips) strips **every** `$` as a math delimiter with a blind regex, while `MathRenderer.segments` — used by the real renderers — deliberately keeps `"$5 and $10"` as currency. So a note reading "$5 and $10 for the annual plan" previews as "5 and 10 for the annual plan" while its opened body renders the dollars correctly. The fix routes `plainPreview`'s math stripping through the same `segments` function the renderers use.

## Current state

- `Vellum/Views/AI/MarkdownMessage.swift:159-298` — `enum MarkdownParser`, containing:
  - `parse(_:) -> [MarkdownBlock]` (line 180) — hand-rolled block parser: headings `#`–`###`, ``` fences, `$$`/`\[` display math, `>` quotes, `-`/`*`/`+` bullets, `1.` ordered lists, `|`-tables (requires a separator row), paragraphs.
  - `plainPreview(_:) -> String` (lines 163-178), exactly:

```swift
static func plainPreview(_ source: String) -> String {
    var text = source
    for pattern in [
        #"(?m)^#{1,3}\s+"#,       // headings
        #"(?m)^>\s?"#,            // quotes
        #"(?m)^[-*+]\s+"#,        // bullets
        #"(?m)^\d+\.\s+"#,        // ordered lists
        "```[a-zA-Z]*",           // code fences
        #"\*\*|\*|__|`|\\\[|\\\]|\\\(|\\\)|\$\$|\$"#, // emphasis + math delimiters
    ] {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}
```

  The last pattern's `\$\$|\$` alternatives are the bug: every `$` is deleted regardless of context.

- `Vellum/Views/AI/MathRenderer.swift:90-109` — `MathRenderer.segments(in:)`, `nonisolated static`, returns `[MathSegment]` (`.text(String)` / `.math(String)`). Its regex `\$(?![\s$])([^$\n]*[^\s$])\$` implements the currency rule: a `$` span is math only when it doesn't butt against whitespace on the inside (doc comment: `"$5 and $10" stays currency, "$x^2$" is math`). Being `nonisolated`, it is callable from the non-main-actor `plainPreview` without concurrency friction.
- `MarkdownBlock` (MarkdownMessage.swift:147-157) — `Equatable` enum: `.heading(Int, String)`, `.paragraph(String)`, `.unordered([String])`, `.ordered([String])`, `.quote(String)`, `.code(String)`, `.table(String)`, `.math(String)`. Equatable means tests can assert whole-array equality.
- `plainPreview` call sites (all display-only, so behavior changes here are low-risk): `Vellum/Views/Annotations/StickyNoteOverlay.swift:84` (`Text(MarkdownParser.plainPreview(content))` — collapsed pill) and `:114` (`.help(...)` tooltip).
- Test conventions: existing suites in `Tests/` are XCTest classes named `<Thing>Tests` (see `Tests/WebProxyUrlTests.swift` for the smallest exemplar — plain `XCTestCase`, `@testable import Vellum`, helper methods with `file:/line:` passthrough). `project.yml` includes the whole `Tests/` directory as the `VellumTests` target's sources, so a new file only needs `xcodegen generate` to join the target.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regenerate project (REQUIRED — this plan adds a file) | `xcodegen generate` | exit 0; `Vellum.xcodeproj` regenerated |
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |
| One suite | append `-only-testing:VellumTests/MarkdownParserTests` | that suite passes |

## Scope

**In scope**:
- `Tests/MarkdownParserTests.swift` (create)
- `Vellum/Views/AI/MarkdownMessage.swift` (`plainPreview` only)
- `Vellum.xcodeproj/project.pbxproj` — exception to the repo's usual "never commit pbxproj" habit: adding a test file REQUIRES the regenerated project, and the regeneration must be committed or the file isn't in the target for anyone else. Commit the regenerated pbxproj produced by `xcodegen generate` (nothing hand-edited). Note: regeneration also normalizes a previously hand-patched entry for `WebProxyUrlTests.swift` — that's expected and desirable (see advisor-plans/006).

**Out of scope** (do NOT touch):
- `MarkdownParser.parse` and `MathRenderer.segments`/`render` — this plan PINS their behavior; changing it is plan 009's job (which depends on this plan's test file).
- The SwiftUI/AppKit renderers (`MarkdownMessage` view body, `SelectableMessageText.swift`).
- `StickyNoteOverlay.swift` / `WebNotePopovers.swift` — call sites don't change.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/011-parser-tests`.
- Two commits work well: "Add MarkdownParser/MathRenderer.segments unit tests" then "Route plainPreview math stripping through MathRenderer.segments"; one combined commit is also fine.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Create `Tests/MarkdownParserTests.swift` pinning current behavior

Model the file on `Tests/WebProxyUrlTests.swift` (XCTest, `@testable import Vellum`). Cover, as separate test methods:

- **Blocks** (assert full `[MarkdownBlock]` equality where stable):
  - `"# Title"` → `[.heading(1, "Title")]`; `"### Sub"` → `[.heading(3, "Sub")]`.
  - Two paragraphs separated by a blank line → two `.paragraph` blocks; consecutive non-blank lines merge into one paragraph joined with `\n`.
  - `"- a\n- b"` → `[.unordered(["a", "b"])]`; `"1. a\n2. b"` → `[.ordered(["a", "b"])]`.
  - `"> q1\n> q2"` → `[.quote("q1\nq2")]`.
  - ```swift
    "```swift\nlet x = 1\n```"
    ``` → `[.code("let x = 1")]`; unterminated fence (no closing ```) → one `.code` block containing the rest (pins the existing degrade-to-code convention).
  - Table: `"|a|b|\n|---|---|\n|1|2|"` → exactly one `.table` block (assert `blocks.count == 1` and `case .table` — the formatted string's exact padding is an implementation detail; don't pin it byte-for-byte).
  - Display math: `"$$E=mc^2$$"` → `[.math("E=mc^2")]`; multi-line `"$$\na+b\n$$"` → one `.math` block containing `a+b`.
    (NOTE: do NOT add a test for an UNCLOSED `$$` block — plan 009 changes that behavior; pinning it here would create a plan conflict. Leave it untested in this plan.)
- **Segments** (`MathRenderer.segments(in:)`):
  - `"$5 and $10"` → `[.text("$5 and $10")]` (currency untouched — the doc-comment contract).
  - `"$x^2$"` → `[.math("x^2")]`.
  - `"a \\(y\\) b"` → `[.text("a "), .math("y"), .text(" b")]`.
  - `"pay $5 for $x^2$"` → segments where `$5` stays in a `.text` and `x^2` is `.math`.
- **plainPreview** (write these to assert the CORRECT post-fix behavior; they will fail until step 2 — that's the point):
  - `plainPreview("**bold** and _x_")` → `"bold and _x_"`? — NO: check the actual pattern list; `__` is stripped but single `_` is not. Assert only what the patterns clearly define: `plainPreview("**bold** text")` → `"bold text"`.
  - `plainPreview("$5 and $10 for the plan")` → `"$5 and $10 for the plan"` (currency preserved — fails before step 2).
  - `plainPreview("solve $x^2$ now")` → `"solve x^2 now"` (math delimiters stripped, body kept).
  - `plainPreview("# H\n- item")` → `"H item"` (block markers stripped, whitespace collapsed — passes before and after).

Then `xcodegen generate` (adds the new file to the target).

**Verify**: `xcodebuild ... test -only-testing:VellumTests/MarkdownParserTests` → the blocks/segments tests PASS; the currency-preservation `plainPreview` test FAILS (expected red before the fix). If any blocks/segments test fails, the plan's excerpts have drifted — STOP.

### Step 2: Route `plainPreview`'s math handling through `MathRenderer.segments`

In `plainPreview`, remove the math-delimiter alternatives from the final regex (leaving emphasis: `\*\*|\*|__|` and backtick), and pre-process the source through `segments` so math spans lose their delimiters but keep their bodies, while currency `$`s survive. Target shape:

```swift
static func plainPreview(_ source: String) -> String {
    // Inline math: same definition as the renderers (MathRenderer.segments),
    // so "$5 and $10" stays currency in the pill exactly as it renders in
    // the note body, while "$x^2$" strips to its LaTeX body.
    var text = source.components(separatedBy: .newlines).map { line in
        MathRenderer.segments(in: line).map { segment in
            switch segment {
            case .text(let t): return t
            case .math(let latex): return latex
            }
        }.joined()
    }.joined(separator: "\n")
    for pattern in [
        #"(?m)^#{1,3}\s+"#,       // headings
        #"(?m)^>\s?"#,            // quotes
        #"(?m)^[-*+]\s+"#,        // bullets
        #"(?m)^\d+\.\s+"#,        // ordered lists
        "```[a-zA-Z]*",           // code fences
        #"\*\*|\*|__|`|\$\$|\\\[|\\\]"#, // emphasis + display-math delimiters
    ] {
        text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
    }
    return text
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespaces)
}
```

Notes:
- Per-line mapping matters: `segments`' regex excludes `\n` inside `$...$`, so feeding whole multi-line strings is equivalent — but the line map keeps it obviously so.
- Keep `\$\$` and the `\\\[`/`\\\]` alternatives in the block-level pattern list (display-math delimiters at line level), but the bare-`\$` alternative and `\\\(`/`\\\)` must GO — inline math is now handled by `segments` (which strips `\(...\)` delimiters itself by returning only the inner latex).
- `plainPreview` currently has no isolation annotation and `segments` is `nonisolated` — no actor changes needed. If the compiler objects, STOP rather than adding `@MainActor`.

**Verify**: `xcodebuild ... test -only-testing:VellumTests/MarkdownParserTests` → ALL tests pass, including the two that were red.

### Step 3: Full suite + visual sanity

**Verify**: full `xcodebuild ... test` → `** TEST SUCCEEDED **`. Optional if you can drive the app: create a sticky note with body `$5 and $10 for $x^2$`, collapse it, and confirm the pill shows `$5 and $10 for x^2`.

## Test plan

Step 1 IS the test plan (this is a tests-first plan): ~12 table-style cases across `parse`, `segments`, and `plainPreview`, with the two currency-preview cases as the red-then-green regression proof for step 2. Plan 009 will later append unclosed-math cases to this same file.

## Done criteria

- [ ] `Tests/MarkdownParserTests.swift` exists, is in the test target (via regenerated project), and all its tests pass
- [ ] `plainPreview` preserves currency `$` (test-proven) and no longer contains a bare `\$` alternative in its strip patterns
- [ ] Full test suite: TEST SUCCEEDED
- [ ] `git diff --stat` touches only: the new test file, `MarkdownMessage.swift`, `project.pbxproj` (regenerated, not hand-edited)
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 001 has not landed (the test target won't compile — check `advisor-plans/README.md` status first).
- Any step-1 blocks/segments test fails against UNMODIFIED source — the parser has drifted from this plan's excerpts; pinning wrong expectations would be worse than no tests.
- Step 2's compile requires actor-isolation changes to `plainPreview` or `segments`.
- `xcodegen generate` produces pbxproj changes beyond adding the new test file and normalizing the known `WebProxyUrlTests` entry — inspect the diff; unexplained churn means project.yml drifted (report it).

## Maintenance notes

- Any future change to `MarkdownParser.parse`'s grammar now has a place to land tests first — extend `MarkdownParserTests`, don't start a new file.
- Known accepted gap (recorded, not fixed here): `plainPreview` shows table rows as raw `| a | b |` text in pills. Cosmetic, rare in notes; fold a "compact table preview" into a future pass if users hit it.
- Reviewer scrutiny: the removed `\\\(`/`\\\)` strip patterns — step 2 relies on `segments` consuming those delimiters; the `"a \\(y\\) b"` segments test plus the preview tests cover it, but a reviewer should confirm no OTHER caller depended on `plainPreview` stripping bare `$`.
