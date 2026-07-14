# Plan 005: Neutralize scripts in archived webpage snapshots (stored-XSS in `.vellumweb`)

> **Canonical Plan 005.** A partial draft of this plan previously existed as
> `plans/005-neutralize-archived-snapshot-scripts.md`; it has been deleted and its
> unique requirements folded in here. If you encounter a reference to that
> filename, it means this document.

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat bff7de4..HEAD -- Vellum/Services/Web/WebArchive.swift Vellum/Services/Web/WebPageExtractor.swift Vellum/Views/Web/WebViewerView.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: 004 (the content script must be out of the page HTML and in a private world before page JS can be disabled; do NOT start 005 until 004 is DONE)
- **Category**: security
- **Planned at**: commit `bff7de4`, 2026-07-14

## Why this matters

When Vellum archives a page for offline reading (which happens automatically on nearly every page view), it "sanitizes" the HTML by stripping only `<script>` tags, preload `<link>`s, and a few attributes. It does **not** strip inline event handlers (`onerror`, `onload`, `onclick`), `javascript:` URIs, `<iframe>`/`<object>`/`<embed>`, or SVG `<script>`/`onload`. That surviving markup is written verbatim into the `.vellumweb` archive and re-served into the same WKWebView on every reopen. So a single visit to a hostile page — or opening a `.vellumweb` file received from someone else — can plant markup that executes every time the snapshot is viewed. Combined with the native bridge, that's persistent code tied to the reader. Two independent layers fix it: (a) serve snapshots with page JavaScript disabled, and (b) sanitize with a real allowlist instead of a handful of regexes.

## Current state

- `Vellum/Services/Web/WebArchive.swift`:
  - `sanitizeSnapshotHtml(_:)` (~line 187):
    ```swift
    static func sanitizeSnapshotHtml(_ html: String) -> String {
        var out = replaceAll(scriptRegex, in: html)
        out = replaceAll(preloadRegex, in: out)
        out = replaceAll(attrStripRegex, in: out)
        return out
    }
    ```
    Its regexes (~lines 164–178): `scriptRegex` (script tags), `preloadRegex`, and `attrStripRegex` which only matches `srcset|sizes|integrity|crossorigin`. No `on*`, no `javascript:`, no iframe/object/embed/svg handling.
  - `captureSnapshot(pageUrl:rawHtml:)` (~line 320) calls `sanitizeSnapshotHtml(rawHtml)` (line 321). The result is written into the archive at `snapshot/index.html` (line 446) and as `snapshot.html` in the installed dir (~line 597).
- `Vellum/Services/Web/WebPageExtractor.swift` — `WebHtml.prepareHtml` re-serves snapshots. After plan 004 it strips CSP/refresh metas and injects only `<base href>`; the content script now runs as a `WKUserScript` in a private world, **not** inside the page HTML. That is what makes disabling page JS safe.
- `Vellum/Views/Web/WebViewerView.swift` — `makeWebView()` builds the `WKWebViewConfiguration`. Page JS is currently enabled (default). WebKit controls per-navigation JS via `WKWebpagePreferences.allowsContentJavaScript`, set in the `WKNavigationDelegate` method `webView(_:decidePolicyFor:preferences:decisionHandler:)`.

Whether a given navigation is serving an offline snapshot vs. a live page is already known to the app: `prepareHtml` takes an `offline:` flag, and the scheme handler distinguishes live vs. snapshot/installed paths (`WebPageExtractor.swift` ~lines 800–825). Reuse that signal — do not invent a new one.

## Target design

Two layers:

1. **Disable page JavaScript for snapshot navigations.** In the navigation delegate's `decidePolicyFor navigationAction ... preferences` callback, when the navigation resolves to an offline/installed snapshot, set `preferences.allowsContentJavaScript = false`. Live pages keep JS enabled (reader mode needs it for extraction). The Vellum content script still runs because — post-004 — it's a `WKUserScript` in `bridgeWorld`, and content-world user scripts are governed separately from page content JS. **Verify this assumption in step 4**; if user scripts are also suppressed, the allowlist sanitizer (layer 2) becomes the sole defense and you keep JS enabled — see STOP conditions.
2. **Allowlist sanitizer at capture time.** Replace the regex `sanitizeSnapshotHtml` with a DOM-based allowlist pass so archives are clean at rest (defense in depth, and protects imported `.vellumweb` files that predate this change or came from elsewhere). Options, pick per what's reachable:
   - Preferred: run the raw HTML through the DOMPurify that already ships for the scratchpad (`Vellum/Resources/katex/purify.min.js`) inside an offscreen `WKWebView`/`JSContext` at capture time, with an allowlist that drops all `on*` attributes, `javascript:`/`data:text/html` URIs, and `<script>/<iframe>/<object>/<embed>/<link rel=import>` plus SVG scripting.
   - Acceptable fallback if wiring JS into the capture path is impractical: extend the regex set to also strip inline `on\w+=` attributes, `javascript:` in `href`/`src`, and `<iframe|object|embed|svg>` blocks. This is strictly weaker (regex HTML sanitizers are bypassable) — only use it if the STOP condition on the DOM approach fires, and say so in your report.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` |

## Suggested executor toolkit

- For step 4 behavioral verification, use codex computer-use or `macos-app-driver` if available.

## Scope

**In scope** (the only files you should modify/create):
- `Vellum/Services/Web/WebArchive.swift` (the `sanitizeSnapshotHtml` implementation and its regexes)
- `Vellum/Views/Web/WebViewerView.swift` (the `allowsContentJavaScript` decision only)
- `Vellum/Services/Web/WebPageExtractor.swift` — **only if** needed to expose "this navigation serves a snapshot" to the controller (see step 1)
- `Tests/SnapshotSanitizerTests.swift` (create)
- `Vellum.xcodeproj/*` (regenerated for the new test file)
- `plans/README.md` — status-row update only (per the executor instructions above)

**Out of scope** (do NOT touch):
- The archive binary format / MiniZip code in `WebArchive.swift` (that's covered by plan 006's tests, not this plan).
- `prepareHtml` — plan 004 owns the injection block; here it is unchanged.
- The content script and bridge world (plan 004).
- Live-page extraction/reader-mode logic (keeps JS on).

## Git workflow

- Fresh worktree: `git worktree add 005-sanitize-snapshots` from the parent folder. Do not touch the shared worktree's uncommitted work.
- Commit style: sentence-case imperative, e.g. "Sanitize archived snapshots and disable JS on snapshot navigations".
- Do NOT push or open a PR unless the operator instructed it.
- Test fixtures must use inert markers (e.g. `onerror="document.title='XSS-RAN'"`), never real exfiltration payloads.

## Steps

### Step 1: Confirm the snapshot-vs-live signal

Read `WebViewerView.swift`'s navigation delegate and `WebPageExtractor.swift`'s scheme-handler paths; state exactly how, at `decidePolicyFor navigationAction`, the controller can tell a snapshot navigation from a live one (URL scheme? a per-session offline flag? the installed-archive path?). Do not edit yet.

**Verify**: you can name the signal. If none exists at that callback, STOP.

### Step 2: Disable content JS for snapshot navigations

Implement the navigation-delegate `preferences` variant and set `preferences.allowsContentJavaScript = false` on snapshot navigations only. If the controller doesn't yet implement that delegate method, add it (it coexists with the existing `decidePolicyFor navigationAction` — WebKit calls the `preferences` overload when present).

If the controller cannot know the snapshot outcome before the scheme handler runs (the offline fallback happens *inside* the handler after a live fetch fails), take the conservative documented alternative: have the scheme handler mark the session/tab as offline-mode on shared state the controller reads, and **reload once with JS disabled** when a snapshot response is detected on a navigation that started with JS enabled. Choose the smaller correct mechanism and record which you used. Explicitly-offline opens (the user opens a saved `.vellumweb`) must always start with JS disabled — no first-pass-enabled window there.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 3: Allowlist sanitizer

Implement layer 2 per the target design. If using DOMPurify: add a capture-time async pass that loads `purify.min.js` into an offscreen web context and returns sanitized HTML; keep `captureSnapshot` calling it before writing the archive. Whichever route, the function must remove: all `on*` attributes, `javascript:`/`data:text/html` URIs in `href`/`src`, and `<script>`, `<iframe>`, `<object>`, `<embed>`, and SVG scripting.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 4: Behavioral verification (launch the app)

1. **JS disabled on snapshot**: capture a page that sets `document.title` from a script; reopen its snapshot offline; confirm the title reflects the *archived* text, not a freshly-run script.
2. **Content script still works** (the layer-1 assumption): on that reopened snapshot, confirm highlight creation and re-anchoring still function. **If they don't**, layer 1 is suppressing our own user script too — revert step 2 (re-enable JS) and rely solely on layer 2, and record this in your report and the README row.
3. **Sanitizer**: capture a locally served page containing `<img src=x onerror="document.title='XSS-RAN'">` and `<svg onload="document.title='XSS-RAN'">`; open its snapshot; confirm the title never becomes `XSS-RAN` and (optionally) that the stored `snapshot/index.html` inside the `.vellumweb` no longer contains `onerror`/`onload`.

Report any check you couldn't run in your environment rather than claiming it.

### Step 5: Regression — archive round-trip still renders

Open a normal article, archive it, reopen the snapshot; confirm layout/text are intact (over-aggressive sanitizing shouldn't blank the page). Use a couple of different real articles.

## Test plan

`Tests/SnapshotSanitizerTests.swift` (model on `Tests/ScratchpadImportTests.swift`), asserting `sanitizeSnapshotHtml`/the new sanitizer output for known payload shapes:
- input with `<img onerror=...>` → output has no `onerror`
- input with `<a href="javascript:...">` → output href neutralized
- input with `<iframe>`/`<svg onload=...>` → removed
- input with a benign `<p>`/`<h1>`/`<img src="...">` → preserved (no false positives)

If layer 2 uses async DOMPurify-in-webview, and that can't run in the unit-test bundle without a display session, test the pure/regex portions you can and note which cases are covered only by step 4.

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`, new tests pass.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "allowsContentJavaScript" Vellum/Views/Web/WebViewerView.swift` → 1 match, set false on snapshot path
- [ ] The sanitizer removes `on*` handlers and `javascript:` URIs (asserted by tests)
- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`; `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`
- [ ] Step 4 check 3 (payload does not execute) passes, or is reported not-runnable
- [ ] Step 5 confirms benign articles still render
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 004 is not DONE (the content script is still inline in page HTML) — disabling page JS would kill the bridge. Check `grep -n "WebContentScript.source" Vellum/Services/Web/WebPageExtractor.swift` returns 0 first; if it returns a match, STOP.
- Step 1 finds no way to distinguish snapshot vs live navigation at the delegate.
- Step 4 check 2 shows disabling page JS also disables the content-world user script AND wiring DOMPurify into the capture path proves impractical — you'd be left with only the weak regex fallback; report this so the team can decide, rather than shipping a false sense of safety.
- Sanitizing blanks out real article content (over-stripping) and one allowlist adjustment doesn't fix it.

## Maintenance notes

- Imported `.vellumweb` files from before this change are only protected by layer 1 (JS disabled on serve) unless re-sanitized on import — consider a follow-up that runs the sanitizer on import as well as capture.
- Reviewers should scrutinize: the snapshot-vs-live branch (a mislabeled live page with JS disabled would break reader-mode extraction), and that the sanitizer runs on **both** the archive `snapshot/index.html` and the installed `snapshot.html` write paths.
- Deferred: a Content-Security-Policy header on the custom scheme responses as a third layer.
