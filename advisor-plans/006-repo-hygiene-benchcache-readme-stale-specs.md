# Plan 006: Repo hygiene — untrack the benchmark cache, fix the README requirements, banner the stale port-era docs

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c874e13..HEAD -- .gitignore README.md specs/ PORT-DESIGN.md Benchmarks/README.md project.yml Vellum.xcodeproj/project.pbxproj`
> If any of these changed since this plan was written, re-check the facts below before proceeding.
> (Baseline updated 2026-07-14: original facts re-verified at `c874e13`; steps 5–6 added by the 2026-07-14 audit round.)

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none in terms of ordering, but steps 5–6 touch build configuration (`project.yml`, the committed `Vellum.xcodeproj/project.pbxproj`) — do not run concurrently with any other plan that adds/renames source files or edits `project.yml`, since both would race on `xcodegen generate` output and the pbxproj diff
- **Category**: dx / docs
- **Planned at**: commit `314cf9f`, 2026-07-12

## Why this matters

Five small, unrelated hygiene problems, bundled because each is a few minutes of mechanical work:

1. **7.5 MB of regenerable cache is tracked in git.** Commit `314cf9f` committed `.benchmark-cache/` — 15 files including 800KB PNGs, a 22k-line extracted-text file, and a **compiled binary** (`bin/pdfkit-extract-93c0ca71ac5990ff`). `Benchmarks/README.md` itself describes this directory as a fingerprinted cache that the benchmark tooling regenerates. Every clone pays for it, and the binary will churn on every machine/Xcode difference.
2. **README requirements are actively wrong.** `README.md` says "macOS 15.0+ / Xcode 16+", but `project.yml` sets `deploymentTarget macOS: "26.0"`. A contributor following the README installs a toolchain that cannot build the project.
3. **The port-era docs read as current but describe a dead app.** `specs/SPECS-*.md`, `specs/GAPS.md`, `specs/VERIFY-CHECKLIST.md`, `specs/FIXLIST.md`, and `PORT-DESIGN.md` document the *original Tauri app* (3 providers, a Codex CLI provider that no longer exists, "NO token streaming anywhere", 3 tools, `macos/` paths) as reference material for the Tauri→SwiftUI port. The Swift app has moved on: 5 providers, streaming, 5 tools, repo-root layout. Worse, `specs/FIXLIST.md` lists findings as open that are all verifiably fixed at HEAD (confirmed during the 2026-07-12 audit). Any person or agent told to "check the specs" is actively misled. The files are valuable history — banner them as historical rather than deleting them (source comments like `AiStore.swift`'s "see SPECS-ai.md" still resolve).

Added by the 2026-07-14 audit round (same S-size mechanical class):

4. **The tracked `project.pbxproj` is not what `xcodegen generate` produces.** Commit `c874e13` inserted `Tests/WebProxyUrlTests.swift` into the project by hand-editing `project.pbxproj` (tell-tale non-XcodeGen UUIDs `FEEDA1B2C3D4E5F6...` where XcodeGen emits deterministic hash UUIDs), so anyone running the documented `xcodegen generate` step gets a spurious pbxproj diff before making any change of their own — verified by running exactly that at `c874e13`. `project.yml` is supposed to be the sole source of truth; re-baseline the generated project.
5. **SwiftMath is range-pinned against internal behavior.** `project.yml:8-10` declares `SwiftMath: from: 1.7.3` (any future 1.x accepted on re-resolve), but `Vellum/Views/AI/MathRenderer.swift:49-54`'s own comment documents that it reaches around SwiftMath's public API (offscreen `MTMathUILabel` layout, matching its internal centering clamp) to get exact baseline metrics — behavior a minor bump could silently change, shifting every rendered equation's baseline with no test to catch it. Pin exact until a geometry regression test exists.

## Current state / facts (verified 2026-07-12 at `314cf9f`)

- `git ls-files .benchmark-cache | wc -l` → 15; `du -sh .benchmark-cache` → 7.5M.
- `.gitignore` contents today: `xcuserdata/`, `build/`, `DerivedData/`, `*.xcuserstate`, `.dd/`, `SCRATCHPAD.md`, editor dirs, `Tests/Texts/` — no `.benchmark-cache`.
- `README.md` "Requirements" section: `macOS 15.0+`, `Xcode 16+ (Swift 6)`, XcodeGen.
- `project.yml:4-5`: `deploymentTarget: macOS: "26.0"`; building requires a current (beta) Xcode with the macOS 26 SDK.
- `Benchmarks/vellum_bench.py` uses only the Python standard library (no pip installs), but on non-macOS (or when PDFKit extraction is unavailable) it falls back to Poppler binaries via `shutil.which("pdftotext")` / `pdftoppm` (~lines 136–178) — a runtime-only surprise not mentioned in `Benchmarks/README.md`'s quick start.
- FIXLIST status (each verified fixed in current source): shift-shortcut handling now shift-aware (`Vellum/App/ContentView.swift:66,79,104`); open-file handling exists (`@NSApplicationDelegateAdaptor(VellumAppDelegate.self)`, `Vellum/App/VellumApp.swift:43`); Gemini no longer sends `additionalProperties` in function declarations (`GeminiClient.swift:230–288`); OpenAI no longer sends `strict: true`; SpeechService guards 0-Hz formats (`SpeechService.swift:43–46`); the Codex-CLI findings are obsolete (no `CodexClient` exists).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Untrack cache | `git rm -r --cached .benchmark-cache` | 15 files staged as deleted (working tree keeps them) |
| Confirm untracked | `git ls-files .benchmark-cache` | empty output |
| Build (sanity) | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` (nothing here should affect it) |

## Scope

**In scope**:
- `.gitignore`
- `.benchmark-cache/` (untrack only — do not delete from disk)
- `README.md` (Requirements section only)
- `Benchmarks/README.md` (add the Poppler note)
- `specs/SPECS-ai.md`, `specs/SPECS-annotations.md`, `specs/SPECS-app-shell.md`, `specs/SPECS-pdf-viewing.md`, `specs/SPECS-web.md`, `specs/GAPS.md`, `specs/VERIFY-CHECKLIST.md`, `specs/FIXLIST.md`, `PORT-DESIGN.md` (prepend a banner each; FIXLIST also gets the resolution note)
- `project.yml` (SwiftMath pin only)
- `Vellum.xcodeproj/project.pbxproj` (regenerated by `xcodegen generate` only — never hand-edited; committing the regenerated file is the point of step 6)
- `Vellum.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` (only if the pin change re-resolves it; commit whatever `xcodegen`/Xcode produce — the resolved revision must stay `1.7.3`)

**Out of scope**:
- Deleting or moving any specs file (source comments reference them by path).
- Rewriting spec content or writing new current-state specs (a possible follow-up, not this plan).
- `Benchmarks/*.py` code.
- `plans/` and `advisor-plans/` contents other than the index status row.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/006-repo-hygiene`.
- Commit message style: short imperative; this can be one commit ("Repo hygiene: untrack benchmark cache, fix README, banner port-era specs") or three logical ones.
- Stage only the in-scope files. (`project.pbxproj` IS in scope for this plan — step 6's regenerated file only. Hand edits to it remain forbidden.)
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Ignore and untrack `.benchmark-cache/`

Append to `.gitignore`:

```
# Benchmark suite cache: fingerprinted, regenerated by Benchmarks/vellum_bench.py
.benchmark-cache/
```

Then `git rm -r --cached .benchmark-cache`.

**Verify**: `git ls-files .benchmark-cache` → empty; `ls .benchmark-cache` → files still on disk; `git status` shows the 15 deletions plus `.gitignore`.

### Step 2: Fix the README requirements

In `README.md`, replace the Requirements list entries `macOS 15.0+` and `Xcode 16+ (Swift 6)` with the actual floor, e.g.:

```markdown
- macOS 26.0+ (pre-release; the project's deployment target — see `project.yml`)
- A current Xcode beta with the macOS 26 SDK (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
```

**Verify**: `grep -n "macOS 15" README.md` → no matches.

### Step 3: Note the Poppler fallback in `Benchmarks/README.md`

In the quick-start/setup area of `Benchmarks/README.md`, add one line:

```markdown
> Non-macOS (or non-PDFKit) runs shell out to Poppler's `pdftotext`/`pdftoppm` — install with `brew install poppler` (macOS) or your distro's poppler-utils.
```

Place it wherever the README first tells the reader to run the tool (read the file and fit the existing tone/format).

**Verify**: `grep -n "poppler" Benchmarks/README.md` → at least one match.

### Step 4: Banner the port-era docs as historical

Prepend to each of the nine files listed in Scope (as the very first lines, above any existing title):

```markdown
> **HISTORICAL — describes the pre-port Tauri app, not the current SwiftUI app.**
> Written as reference material for the Tauri→SwiftUI port (2025–2026). The current
> app has diverged (e.g. 5 streaming AI providers and 5 tools vs. the 3 non-streaming
> providers / 3 tools described here; no Codex CLI provider; repo-root layout, not
> `macos/`). Do not treat file paths, behavior, or UI specs here as current.

```

For `specs/FIXLIST.md`, use this variant instead:

```markdown
> **HISTORICAL — all findings below are RESOLVED as of commit `314cf9f` (verified 2026-07-12).**
> Shift-shortcuts: fixed in `Vellum/App/ContentView.swift`. Open-file handling: fixed via
> `VellumAppDelegate` in `Vellum/App/VellumApp.swift`. Gemini `additionalProperties` and
> OpenAI `strict`: removed from the current clients. SpeechService 0-Hz tap: guarded.
> Codex-CLI findings: obsolete (provider no longer exists). Paths below use the old
> `macos/` prefix; the app now lives at the repo root.

```

**Verify**: `head -2 specs/SPECS-ai.md specs/FIXLIST.md PORT-DESIGN.md` → each starts with the `> **HISTORICAL` banner; `grep -L "HISTORICAL" specs/*.md PORT-DESIGN.md` → empty (every file bannered).

### Step 5: Pin SwiftMath exactly

In `project.yml`, change the SwiftMath package declaration from `from: 1.7.3` to an exact pin:

```yaml
packages:
  SwiftMath:
    url: https://github.com/mgriebling/SwiftMath
    exactVersion: 1.7.3
```

(XcodeGen's key for an exact requirement is `exactVersion`; if `xcodegen generate` in step 6 rejects it, `version: 1.7.3` is the legacy spelling — use whichever the installed XcodeGen accepts, and note which in your report.)

**Verify**: step 6's `xcodegen generate` exits 0, and `grep -n "1.7.3" project.yml` shows the exact-pin key, not `from:`.

### Step 6: Re-baseline the generated Xcode project

Run `xcodegen generate`, then inspect `git diff Vellum.xcodeproj/project.pbxproj`. Expected changes ONLY: (a) the hand-typed `FEEDA1...` entries for `WebProxyUrlTests.swift` replaced by XcodeGen hash UUIDs and the file reference moved to its sorted position, (b) whatever the step-5 pin changes in the package requirement block. Commit the regenerated file — this is the one deliberate exception to the repo habit of never committing `project.pbxproj`, precisely so the tracked project matches `project.yml` again.

**Verify**: run `xcodegen generate` a SECOND time → `git status --short Vellum.xcodeproj/` is empty (generation is now idempotent against the tracked file).

### Step 7: Sanity build

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → BUILD SUCCEEDED (nothing here should change compiled code; this is a tripwire for accidental file damage — and confirms the regenerated project + exact pin still resolve and build).

## Test plan

No code paths change; the verifications above (greps + build) are the test plan.

## Done criteria

- [ ] `git ls-files .benchmark-cache` → empty, directory still on disk
- [ ] `.gitignore` contains `.benchmark-cache/`
- [ ] README requirements match `project.yml` (no "macOS 15", no "Xcode 16")
- [ ] All nine port-era docs carry the HISTORICAL banner; FIXLIST's banner records the resolutions
- [ ] `Benchmarks/README.md` mentions Poppler
- [ ] `project.yml` pins SwiftMath exactly at 1.7.3 (no `from:`)
- [ ] Running `xcodegen generate` on the committed tree produces zero pbxproj diff
- [ ] Build succeeds
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

- `git rm -r --cached` wants to delete more than the 15 expected files.
- A specs file already carries a historical banner or has been rewritten (drift — reconcile, don't double-banner).
- Anything in the working tree under `.benchmark-cache/` looks hand-authored rather than generated (inspect before untracking; the audit found only generated artifacts).
- Step 6's `git diff Vellum.xcodeproj/project.pbxproj` shows changes beyond the `WebProxyUrlTests` UUID normalization and the package-pin block — unexplained churn means `project.yml` and the tracked project have drifted in some other way; report the diff instead of committing it.
- Step 5's pin change makes SwiftPM resolve to anything other than SwiftMath `1.7.3` (check `Package.resolved`).

## Maintenance notes

- Follow-up worth considering (not this plan): a fresh, current-state `specs/SPECS-ai.md` for the AI subsystem — it's the highest-churn area and now has no accurate doc. The 17 tests in `Tests/AiPipelineTests.swift` are the closest thing to a current spec.
- If the benchmark suite is meant to run in CI later, the untracked cache means CI regenerates it — the `doctor` subcommand documented in `Benchmarks/README.md` handles that.
- The README macOS-26 floor documents current reality; whether the app *should* require macOS 26 (it uses Liquid Glass APIs, e.g. `.glassEffect` in `WebViewerView.swift:203`) is a separate product decision recorded in `advisor-plans/README.md` under deferred findings.
