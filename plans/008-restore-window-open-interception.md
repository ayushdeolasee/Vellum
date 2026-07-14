# Plan 008: Restore `window.open` interception with a minimal `WKUIDelegate`

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving on. Touch
> only the in-scope files. If a STOP condition occurs, stop and report — do not
> improvise.
>
> **BASE**: the repaired trunk **plus plan 004**, i.e. branch
> `worktree-agent-a1adc64230e2b5594` (commit `65a8bad`). In your worktree, first
> run `git merge --no-edit worktree-agent-a1adc64230e2b5594` and confirm
> `BUILD SUCCEEDED` + `TEST SUCCEEDED` (38 tests) before changing anything.
>
> **Drift check**: `git diff --stat 65a8bad..HEAD -- Vellum/Views/Web/` → expect empty.

## Status

- **Priority**: P3
- **Effort**: S
- **Risk**: LOW
- **Depends on**: 004 (this exists *because* of 004)
- **Category**: bug (accepted regression from a security fix)
- **Planned at**: commit `65a8bad`, 2026-07-14

## Why this matters

Plan 004 moved the Vellum content script into a private `WKContentWorld` so that
page JavaScript can no longer reach the native bridge. That was the right trade,
but it cost one behavior: the content script overrides `window.open`
(`Vellum/Views/Web/WebContentScript.swift:1477`) to route JS-initiated navigation
back into the reader as a `post("navigate", …)` message. Because the override now
patches only the **bridge world's** `window`, a page calling `window.open(...)` from
its own JS no longer reaches the app — the call hits WKWebView's default, which
does nothing without a `WKUIDelegate`, so the navigation is silently dropped.

Scope of the regression is narrow: ordinary link **clicks** are unaffected (they're
DOM events, and the DOM is shared across content worlds). Only JS-initiated opens
are lost. This plan restores parity the correct way — at the native layer, where
the request now surfaces — rather than by weakening the world isolation.

## Current state

- `Vellum/Views/Web/WebContentScript.swift:1477` — the page-world override that no
  longer fires for page JS:
  ```js
  window.open = function (u) {
  ```
  It calls the script's `post("navigate", …)` bridge. **Leave this in place**: it
  still correctly handles `window.open` calls made *by the content script's own
  world*, and removing it is out of scope.

- `Vellum/Views/Web/WebViewerView.swift` — `WebViewerController` builds the webview
  in `makeWebView()`. After plan 004 it registers the content script as a
  `WKUserScript` in `Self.bridgeWorld` and adds the message handler with
  `contentWorld:`. There is **no** `WKUIDelegate` anywhere in the app (and, as of
  plan 004, no `WKNavigationDelegate` either — though plan 005 may add one; if it
  has landed, coexist with it, don't remove it).

- The inbound `navigate` message is already handled: `handleMessage(_:)`'s switch has
  a `navigate` case that rebinds the session/tab to the new URL. You are re-routing a
  lost signal into that **existing** path — you should not need to add a new message
  type or touch the switch.

## Target design

Implement `WKUIDelegate` on `WebViewerController` and assign
`webView.uiDelegate = self` in `makeWebView()`.

Implement exactly one method:

```swift
func webView(_ webView: WKWebView,
             createWebViewWith configuration: WKWebViewConfiguration,
             for navigationAction: WKNavigationAction,
             windowFeatures: WKWindowFeatures) -> WKWebView? {
    // A page asked for a new window/tab (window.open, target=_blank).
    // Route it through the same path the content script used to, and
    // return nil so WebKit does not create a second webview.
    if let url = navigationAction.request.url {
        // reuse the existing inbound `navigate` handling
    }
    return nil
}
```

Returning `nil` is what tells WebKit not to open a real second webview. Feed the URL
into the same code path `handleMessage`'s `navigate` case uses — call that shared
routine directly rather than synthesizing a fake script message.

**Only route http/https URLs.** A page can request `javascript:`, `data:`, `file:`,
or a custom scheme here; anything that isn't `http`/`https` must be dropped, not
navigated to. Reuse `WebUrl.normalize` if it already enforces this (check — it is
referenced in `WebPageExtractor.swift`).

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Merge base (FIRST) | `git merge --no-edit worktree-agent-a1adc64230e2b5594` | clean merge |
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests -destination 'platform=macOS'` | `TEST SUCCEEDED` (38 baseline) |

## Scope

**In scope**:
- `Vellum/Views/Web/WebViewerView.swift` (add `WKUIDelegate` conformance + the one method + the `uiDelegate` assignment)

**Out of scope** (do NOT touch):
- `Vellum/Views/Web/WebContentScript.swift` — the JS override stays as-is.
- The `handleMessage` switch, the bridge world, the message handler, `prepareHtml` — plan 004 owns these and they are DONE.
- `WebArchive.swift` / snapshot sanitization — plan 005.
- Any `WKNavigationDelegate` that plan 005 may have added — coexist, don't modify.

## Git workflow

- You are already in an isolated worktree; do NOT run `git worktree add`.
- Commit style: sentence-case imperative — e.g. "Restore window.open interception with a WKUIDelegate".
- Do NOT push, merge to main, or open a PR.

## Steps

### Step 1: Merge the base and establish a green baseline
**Verify**: `BUILD SUCCEEDED`; `TEST SUCCEEDED` (38 tests). If either fails, STOP.

### Step 2: Find the existing inbound `navigate` path
Read `handleMessage(_:)` in `WebViewerView.swift` and identify the exact routine its
`navigate` case calls. Note its signature. Do not edit yet.

**Verify**: you can name the function you will call from the delegate. If the
`navigate` case's logic is inlined in the switch rather than factored into a callable
routine, extract it into a private method **without changing its behavior**, and say
so in your report.

### Step 3: Add the `WKUIDelegate`
Implement per the target design, including the http/https-only guard.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 4: Behavioral check
Serve a local page with a button whose handler calls
`window.open('https://example.com')`, open it in web reading mode, click it, and
confirm the reader navigates to example.com in the same tab (no second window).
Then confirm a non-http scheme (e.g. a `javascript:` URL passed to `window.open`) is
**dropped**, not navigated to.

Note from a previous executor: the WKWebView is not the key window, so posted clicks
can be swallowed; a `--steal` click may be needed to drive this. If you cannot drive
the GUI, say so plainly — do not claim the check.

**Verify**: `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED` (no regressions).

## Test plan

The behavior lives in a WebKit delegate callback, so it is not unit-testable without
a webview. If you extracted a navigate routine in step 2 and it is pure enough to test
(e.g. a URL-validation helper), add a small test asserting that `javascript:`/`data:`
URLs are rejected and `https:` accepted. Otherwise rely on step 4 and say so.

## Done criteria

- [ ] `grep -c "WKUIDelegate" Vellum/Views/Web/WebViewerView.swift` → ≥ 1
- [ ] `grep -n "uiDelegate" Vellum/Views/Web/WebViewerView.swift` → 1 match (the assignment)
- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`; `xcodebuild ... test` → `TEST SUCCEEDED`
- [ ] The delegate method returns `nil` (no second webview is ever created)
- [ ] Non-http(s) schemes are dropped, not navigated to
- [ ] `git diff --stat 65a8bad..HEAD` shows only `WebViewerView.swift` (+ any test file)
- [ ] `Vellum/Views/Web/WebContentScript.swift` is unchanged

## STOP conditions

- The merge conflicts, or the baseline build/tests fail before you change anything.
- The `navigate` case's logic cannot be reused without changing its behavior.
- Restoring this appears to require re-exposing the bridge to the page world in any
  form — that would undo plan 004's entire purpose. STOP and report instead.

## Maintenance notes

- This is the native-layer counterpart to a JS override that can no longer fire.
  If someone later removes the `window.open` override from the content script, this
  delegate becomes the *only* path — don't let a future cleanup delete both.
- A reviewer should confirm the delegate returns `nil` (returning a new `WKWebView`
  would spawn an unmanaged second webview outside the tab model) and that the
  scheme guard is present — `createWebViewWith:` is page-controlled input.
