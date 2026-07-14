# Plan 005: Neutralize script execution in archived webpage snapshots (stored-XSS hardening)

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
> mismatch, treat it as a STOP condition. **Also verify plan 004 is DONE in
> `plans/README.md`** — this plan's primary mechanism only works after it.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: 004 (content script must be injected as a world-scoped WKUserScript, not inline page HTML)
- **Category**: security
- **Planned at**: commit `bff7de4`, 2026-07-14

## Why this matters

Pages viewed in web reading mode are auto-archived to disk, and shared `.vellumweb` files can be imported. The snapshot sanitizer only strips `<script>` tags, preload `<link>`s, and four attributes — inline event-handler attributes (`onerror`, `onload`, …), `javascript:` URIs, `<iframe>`/`<object>`/`<embed>`, and SVG event handlers all survive. A page visited once (or a malicious imported archive) can therefore plant markup that re-executes every time the snapshot is reopened — in the same document where Vellum's trusted script runs. Regex sanitization can never fully win this game, so the fix has two layers: **turn page JavaScript off entirely** when serving archived/snapshot content (the robust layer, possible after plan 004 because our own script is a user script, which WebKit exempts), and **strengthen the capture-time strip** as defense in depth for the archive bytes themselves.

## Current state

- `Vellum/Services/Web/WebArchive.swift` — `sanitizeSnapshotHtml` (~line 187):
  ```swift
  static func sanitizeSnapshotHtml(_ html: String) -> String {
      var out = replaceAll(scriptRegex, in: html)
      out = replaceAll(preloadRegex, in: out)
      out = replaceAll(attrStripRegex, in: out)   // only srcset|sizes|integrity|crossorigin
      return out
  }
  ```
  Regexes are defined ~lines 160–178 (`scriptRegex`, `preloadRegex`, `attrStripRegex`, …). Called from `captureSnapshot(pageUrl:rawHtml:)` at line 321. The sanitized HTML is written into the archive as `snapshot/index.html` (line 446) and installed locally as `snapshot.html` (line 597).

- `Vellum/Services/Web/WebPageExtractor.swift` — the scheme handler's serve paths (~lines 795–825): live pages return `WebHtml.prepareHtml(html, pageUrl:, offline: false)`; on fetch failure it falls back to `serveInstalledSnapshot(...)` or the plain saved snapshot with `offline: true`. So **the `offline` parameter already distinguishes snapshot-served content from live content** at the exact point of serving.

- `Vellum/Views/Web/WebViewerView.swift` — `WebViewerController` owns the WKWebView and (after plan 004) implements a pre-load `WKNavigationDelegate` callback. WebKit's per-navigation JS switch is `WKWebpagePreferences.allowsContentJavaScript`, set in
  `webView(_:decidePolicyFor:preferences:decisionHandler:)`. Per Apple's documentation, `allowsContentJavaScript` disables JavaScript **from web content** (script tags, inline handlers, `javascript:` URIs) while `WKUserScript`s still execute — which is exactly the split we need, and why plan 004 is a prerequisite.

- Existing test conventions: plain XCTest in `Tests/`, see `Tests/ScratchpadImportTests.swift` for a small pure-function test file shape. `sanitizeSnapshotHtml` is a pure static `String -> String` — ideal unit-test material.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` |
| Regenerate project (new test file) | `xcodegen generate` | exit 0 |

## Scope

**In scope** (the only files you should modify/create):
- `Vellum/Views/Web/WebViewerView.swift` (the decidePolicyFor preferences hook)
- `Vellum/Services/Web/WebPageExtractor.swift` (only if needed to expose "this navigation serves a snapshot" to the controller — see step 1)
- `Vellum/Services/Web/WebArchive.swift` (the sanitizer regexes + `sanitizeSnapshotHtml`)
- `Tests/WebArchiveSanitizerTests.swift` (create)
- `Vellum.xcodeproj/*` (regenerated)

**Out of scope** (do NOT touch):
- The ZIP/MiniZip codec, manifest, and asset-capture logic in `WebArchive.swift` — only the HTML sanitizer.
- `WebContentScript.swift` and the plan-004 world/user-script machinery.
- Live-page JS behavior — live browsing keeps JavaScript enabled exactly as today.
- Visual layout of archived pages beyond what stripping active content implies.

## Git workflow

- Fresh worktree: from the repo's parent folder, `git worktree add 005-snapshot-hardening`.
- Commit style: sentence-case imperative, e.g. "Disable page JS for archived snapshots and harden capture sanitizer".
- Do NOT push or open a PR unless the operator instructed it.
- Test fixtures must use inert markers (e.g. `onerror="document.title='XSS-RAN'"`), never real exfiltration payloads.

## Steps

### Step 1: Wire "snapshot navigation ⇒ JS off" in the controller

Find how the controller knows a navigation will be served from a snapshot. After plan 004 it already tracks an offline/page state per navigation (plan 004, step 1 mapped this). Implement:

```swift
func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
             preferences: WKWebpagePreferences,
             decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
    preferences.allowsContentJavaScript = !servesSnapshot(for: navigationAction)
    decisionHandler(.allow, preferences)
}
```

where `servesSnapshot` reflects the same condition under which the scheme handler returns snapshot HTML (`offline: true` paths and `serveInstalledSnapshot`). If the controller cannot know this before the scheme handler runs (the fallback happens *inside* the handler after a live fetch fails), take the conservative documented alternative: mark the session/tab as offline-mode when the scheme handler serves a snapshot, store that on shared state the controller reads, and **reload once with JS disabled** when a snapshot response is detected on a navigation that started with JS enabled. Choose the smaller correct mechanism and record which you used. Explicitly-offline opens (user opens a saved `.vellumweb`) must always start with JS disabled.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 2: Strengthen `sanitizeSnapshotHtml` (defense in depth for archive bytes)

Add regexes (same `nonisolated(unsafe) static let` + `regex(...)` style as the existing ones) and apply them in `sanitizeSnapshotHtml`:

1. Inline event handlers: strip attributes matching `\son[a-z]+\s*=\s*("..."|'...'|unquoted)` (case-insensitive).
2. `javascript:` URIs in `href`/`src`/`action`/`formaction`/`xlink:href` attribute values — strip the attribute.
3. Active embedding tags: `<iframe|frame|object|embed|applet ...>...</...>` and self-closing forms — remove entirely.
4. `<me