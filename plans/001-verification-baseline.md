# Plan 001: Establish a verification baseline — CI, wired-in UI test target, editor-bundle drift check

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat bff7de4..HEAD -- project.yml README.md UITests/ tools/scratchpad-editor/package.json .github/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: dx / tests
- **Planned at**: commit `bff7de4`, 2026-07-14

## Why this matters

This repo has no CI, no automated gate of any kind: `find .github .circleci` returns nothing, so a commit can break the build or the 705-line PDF-persistence test suite and nobody finds out until someone builds locally. The only UI test (`UITests/ScratchpadSnapshotUITests.swift`) is not part of the Xcode project at all — `UITests/README-setup.md` documents a manual per-machine Xcode setup, and any manually added target is wiped by the next `xcodegen generate`. Finally, the scratchpad editor's shipped JS (`Vellum/Resources/katex/editor.bundle.js`, 549 KB, committed) is built from `tools/scratchpad-editor/src/` by hand; nothing detects when someone edits the source and forgets `npm run build`. Every other plan in `plans/` relies on `xcodebuild build`/`test` as its verification gate — this plan makes those gates trustworthy and automatic.

## Current state

- `project.yml` — XcodeGen project definition. Defines exactly two targets, `Vellum` (application) and `VellumTests` (`bundle.unit-test`); no UI-testing bundle. The `Vellum` scheme's test action lists only `VellumTests`:

  ```yaml
  schemes:
    Vellum:
      build:
        targets:
          Vellum: all
      run:
        config: Debug
      test:
        config: Debug
        targets:
          - VellumTests
  ```

  The pbxproj is **generated** — never hand-edit `Vellum.xcodeproj`; edit `project.yml` and run `xcodegen generate` (this is the repo's documented convention, see `README.md` "Development").

- `UITests/README-setup.md` — instructs a human to create a `VellumUITests` target manually in Xcode. Its premise ("adding it means editing the hand-maintained `Vellum.xcodeproj`") is wrong for this repo: the project is XcodeGen-generated, so the target belongs in `project.yml`. The UI test itself (`UITests/ScratchpadSnapshotUITests.swift`) expects an env var `VELLUM_TEST_PDF` pointing at a small real PDF and defaults `appBundleID` to `com.vellum.app`.

- `tools/scratchpad-editor/package.json` — sole script:

  ```json
  "scripts": {
    "build": "esbuild src/main.js --bundle --format=iife --outfile=../../Vellum/Resources/katex/editor.bundle.js --minify --legal-comments=none"
  }
  ```

  `package-lock.json` is committed, so `npm ci` gives a deterministic toolchain and the built bundle is reproducible byte-for-byte on the same lockfile.

- `README.md` lines 14–15 state "macOS 15.0+" and "Xcode 16+ (Swift 6)". This is stale: `project.yml` sets `deploymentTarget.macOS: "26.0"` and `MACOSX_DEPLOYMENT_TARGET: "26.0"`, which requires Xcode 26+.

- There is no `.github/` directory at all.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regenerate project | `xcodegen generate` | exit 0, "Created project" |
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` |
| Editor bundle | `cd tools/scratchpad-editor && npm ci && npm run build` | exit 0, bundle rewritten |
| List targets | `xcodebuild -project Vellum.xcodeproj -list` | shows `VellumUITests` after step 1 |

## Scope

**In scope** (the only files you should modify/create):
- `project.yml`
- `.github/workflows/ci.yml` (create)
- `UITests/README-setup.md`
- `README.md` (Requirements section only)
- `Vellum.xcodeproj/*` (regenerated output of `xcodegen generate` — commit the regenerated project)

**Out of scope** (do NOT touch, even though they look related):
- `UITests/ScratchpadSnapshotUITests.swift` — the test code itself is fine; only its wiring is missing. If it fails to compile inside the new target, that's a STOP condition, not a license to rewrite it.
- `Tests/` — existing unit tests must keep passing unmodified.
- `tools/scratchpad-editor/src/**` and `Vellum/Resources/katex/**` — the drift check *reads* these; do not rebuild or commit a new bundle in this plan.
- Any Swift source under `Vellum/`.

## Git workflow

- The working tree at `bff7de4` carries uncommitted scratchpad changes from an active session. **Do not work directly in this worktree** — create a fresh one: from the repo's parent folder run `git worktree add 001-verification-baseline` (this creates branch + folder), and work there. Never `git add -A` in a shared worktree.
- Commit style (match `git log`): sentence-case imperative summary, e.g. "Add CI workflow and wire UI test target into project.yml".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Declare the `VellumUITests` target in `project.yml`

Add under `targets:`:

```yaml
  VellumUITests:
    type: bundle.ui-testing
    platform: macOS
    sources:
      - path: UITests
        excludes:
          - "README-setup.md"
    dependencies:
      - target: Vellum
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.vellum.app.uitests
        GENERATE_INFOPLIST_FILE: "YES"
        TEST_TARGET_NAME: Vellum
```

And extend the scheme's test action:

```yaml
      test:
        config: Debug
        targets:
          - VellumTests
          - VellumUITests
```

**Verify**: `xcodegen generate && xcodebuild -project Vellum.xcodeproj -list` → target list includes `VellumUITests`.

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build-for-testing` → `BUILD SUCCEEDED` (this compiles both test bundles without running them; UI snapshot tests need a GUI session + a test PDF, so don't require them to *pass* headlessly here).

### Step 2: Rewrite `UITests/README-setup.md`

Replace the manual-Xcode-target instructions with: the target is defined in `project.yml` (regenerate with `xcodegen generate`); to run, set `VELLUM_TEST_PDF` to a small real PDF and run
`xcodebuild test -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' -only-testing:VellumUITests`.
Keep the existing "What it asserts" section unchanged.

**Verify**: `grep -c "File → New → Target" UITests/README-setup.md` → `0`.

### Step 3: Fix the README requirements

In `README.md`, change "macOS 15.0+" → "macOS 26.0+" and "Xcode 16+ (Swift 6)" → "Xcode 26+ (Swift 6)".

**Verify**: `grep -n "macOS 26" README.md` → one match in Requirements.

### Step 4: Add `.github/workflows/ci.yml`

Create a workflow with two jobs:

1. **build-and-test** on `macos-26` (GitHub-hosted; if that label is unavailable, use `macos-latest` and add an `xcode-select` step choosing the newest installed Xcode ≥ 26):
   - `brew install xcodegen`
   - `xcodegen generate`
   - `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build`
   - `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests -destination 'platform=macOS'`
   (Run only unit tests in CI; the UI snapshot test needs a real PDF + display session — leave it local-only for now.)
2. **editor-bundle** on `ubuntu-latest`:
   - `cd tools/scratchpad-editor && npm ci && npm run build`
   - `git diff --exit-code ../../Vellum/Resources/katex/editor.bundle.js` — fails the job if the committed bundle doesn't match a fresh build of `src/`
   - `npm audit --audit-level=high` (advisory gate; `|| true` is NOT allowed — a high advisory should fail)

Trigger on `push` to `main` and on `pull_request`.

**Verify**: `ruby -ryaml -e 'YAML.load_file(".github/workflows/ci.yml"); puts "ok"'` → `ok` (syntax check; actual runner execution happens after push).

### Step 5: Full local gate

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` → `TEST SUCCEEDED`, same pass count as before this plan.

## Test plan

No new test code — this plan wires existing tests into an enforced pipeline. The machine gates are the step verifications above.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild -project Vellum.xcodeproj -list` shows `VellumUITests`
- [ ] `xcodebuild ... build-for-testing` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`
- [ ] `.github/workflows/ci.yml` exists and parses as YAML
- [ ] `README.md` no longer contains "macOS 15.0"
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `UITests/ScratchpadSnapshotUITests.swift` fails to **compile** inside the new target (e.g. it references app internals that need `@testable import` wiring you'd have to invent).
- `xcodegen generate` errors on the new target block twice after a syntax fix attempt.
- The existing `VellumTests` suite does not pass **before** your changes (pre-existing breakage — report the failure, don't fix it here).
- You find yourself wanting to edit any Swift file under `Vellum/`.

## Maintenance notes

- Any future plan's "Verify" gates assume this CI exists; if the scheme or target names change, update `ci.yml` in the same commit.
- The editor-bundle drift job pins reproducibility on `package-lock.json`; bumping esbuild (there is a known moderate dev-server-only advisory on esbuild ≤ 0.24.2, GHSA-67mh-4wv8-2f99) will change the bundle output — rebuild and commit the bundle in the same PR as the bump.
- Deferred out of this plan: running the UI snapshot test in CI (needs a checked-in tiny fixture PDF and display-session handling) and SwiftLint/ESLint adoption (finding DX-02, see `plans/README.md` backlog).
