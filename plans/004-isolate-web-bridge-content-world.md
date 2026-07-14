# Plan 004: Isolate the web-reader's native bridge from page JavaScript with a WKContentWorld

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat bff7de4..HEAD -- Vellum/Views/Web/WebViewerView.swift Vellum/Services/Web/WebPageExtractor.swift Vellum/Views/Web/WebContentScript.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED
- **Depends on**: 001 (verification gates). Plan 005 depends on this plan.
- **Category**: security
- **Planned at**: commit `bff7de4`, 2026-07-14

## Why this matters

Web reading mode loads arbitrary user-chosen pages, and the Vellum content script currently runs **in the page's own JS world**: it is injected as an inline `<script>` into the served HTML, and the native message handler is registered without a content world. Any page can therefore call `window.webkit.messageHandlers.vellum.postMessage({vellum: true, ...})` itself and forge every message type the app trusts — rebinding navigation, poisoning the extracted page text that later flows into AI prompts, and corrupting what gets archived to disk. Moving the bridge and the content script into a private `WKContentWorld` makes the native handler unreachable from page scripts while the DOM (which the content script needs for anchoring) stays shared. This is also the prerequisite for plan 005, which disables page JavaScript entirely for archived snapshots — only possible once our own script no longer rides inside the page HTML.

## Current state

- `Vellum/Views/Web/WebViewerView.swift` (1035 lines) — `WebViewerController` owns the WKWebView.
  - Handler registration, `makeWebView()` (~line 283):
    ```swift
    let configuration = WKWebViewConfiguration()
    configuration.setURLSchemeHandler(
        VellumWebSchemeHandler(), forURLScheme: VellumWebSchemeHandler.scheme)
    configuration.userContentController.add(
        WeakScriptMessageHandler(self), name: "vellum")
    ```
  - Inbound trust check, `handleMessage(_:)` (~line 692): requires `data["vellum"] as? Bool == true`, a `type` string, and `app.activeTabId == mountTabId`. Keep all of this — it stays as defense in depth.
  - Outbound bridge, `post(_:_:)` (~line 366):
    ```swift
    webView.evaluateJavaScript("window.__vellumCmd && window.__vellumCmd(\(json));") { _, _ in }
    ```
    This is the **only** `evaluateJavaScript` call site in the file (line 372); confirm with `grep -n evaluateJavaScript Vellum/Views/Web/WebViewerView.swift`.

- `Vellum/Services/Web/WebPageExtractor.swift` — `WebHtml.prepareHtml(_:pageUrl:offline:)` (~line 611) rewrites every page served by the custom scheme handler and **injects the content script inline** into the page HTML:
  ```swift
  let injection = "<base href=\"\(safeUrlAttr)\"><script>"
      + "window.__VELLUM_PAGE_URL__=\(jsonString(pageUrl));"
      + "window.__VELLUM_OFFLINE__=\(offline);\n"
      + WebContentScript.source
      + "</script>"
  ```
  It is inserted right after `<head>` (or `<html>`, or prepended). `prepareHtml` is called from the scheme handler's live path, its offline/snapshot fallback paths, and for error pages (all in `WebPageExtractor.swift`, ~lines 795–825).

- `Vellum/Views/Web/WebContentScript.swift` — the content script as a raw Swift string (`WebContentScript.source`, ~1380 lines of JS). Its header comment declares a **byte-for-byte anchor-compatibility contract** with the original Tauri content script: the annotation-anchoring algorithm must not change. It reads `window.__VELLUM_PAGE_URL__` / `window.__VELLUM_OFFLINE__`, exposes `window.__vellumCmd`, and posts via `window.webkit.messageHandlers.vellum.postMessage`. Because it currently executes as an inline head script, it runs **before the body is parsed** — check how it defers its DOM work (readyState / DOMContentLoaded handling) before choosing injection timing.

## Target design (REVISED 2026-07-14 — v1 was structurally wrong)

**Why v1 failed.** The original design told the executor to re-register a
per-navigation `WKUserScript` from a `WKNavigationDelegate` callback. Two facts
kill that, both verified: (1) there is **no** `WKNavigationDelegate` anywhere in
the app — `git grep WKNavigationDelegate origin/main -- Vellum/` returns nothing;
(2) `offline` is not an input the controller could know at navigation time — it is
a *result* of `VellumWebSchemeHandler.handleRequest`'s own fetch attempt (live
fetch succeeds → `offline: false`; throws → snapshot fallback → `offline: true`).
Any design that pre-populates a user script before `webView.load()` cannot know it.
The executor's alternative — hand the scheme handler a `WKWebView` reference so it
can mutate `userContentController` as a side effect — would turn a pure
string-producing function into one with cross-object side effects that must also
disambiguate `/asset/` sub-requests from main-document requests. Rejected.

**v2: carry the config in the DOM, not in JS globals.** Content worlds share the
DOM. So the config crosses the world boundary as inert markup:

1. `prepareHtml` keeps injecting `<base href>` and **adds two `<meta>` tags** —
   `<meta name="vellum-page-url" content="…">` and
   `<meta name="vellum-offline" content="true|false">` — and **stops injecting
   `<script>…</script>` entirely**. Both values are already in scope at that call
   site; nothing new is threaded anywhere. Escape the `content` attribute values.
2. The content script is registered **once**, in `makeWebView()`, as a
   `WKUserScript(source: WebContentScript.source, injectionTime: .atDocumentStart,
   forMainFrameOnly: true, in: Self.bridgeWorld)`. No per-navigation
   re-registration, no `removeAllUserScripts()`, no navigation delegate.
3. The content script reads the two values from the DOM instead of from
   `window.__VELLUM_*`. It uses them in exactly two places (verified):
   `WebContentScript.swift:36` (`var PAGE_URL = window.__VELLUM_PAGE_URL__ || location.href;`)
   and `:1708` (`offline: !!window.__VELLUM_OFFLINE__,` in the `init` payload).
   **Timing matters**: at `.atDocumentStart` the `<head>` is not parsed yet, so the
   meta tags do not exist at module top level. Both reads must happen inside the
   script's existing deferred bootstrap (it already waits for
   `document.readyState === "complete"` / the `load` event with a 4s fallback,
   around lines 1818-1824). Concretely: leave `var PAGE_URL = location.href;` as the
   top-level default and reassign it inside the bootstrap from the meta tag; read
   `offline` from the meta tag at the point of use.
4. Handler registration moves to the world:
   `configuration.userContentController.add(WeakScriptMessageHandler(self), contentWorld: Self.bridgeWorld, name: "vellum")`.
   Page scripts then have no `window.webkit.messageHandlers.vellum`.
5. `post(_:_:)` targets the world: `webView.evaluateJavaScript(js, in: nil, in: Self.bridgeWorld)`.

This is strictly simpler than v1 (it deletes plumbing rather than adding it) and it
composes with plan 005: `<meta>` tags are inert, so the config still arrives even
once page JavaScript is disabled for archived snapshots.

**Guard rail**: `PAGE_URL` must not be *read* at module top level by anything other
than its own initializer — if any code captures it before the bootstrap runs, it
would capture the proxied `vellum-web://` href instead of the real page URL. Verify
this before relying on step 3, and if something does read it early, STOP and report.

**Known limitation (accepted, with mitigations)**: the meta tags live in the shared
DOM, so page JavaScript *can* rewrite them before the deferred bootstrap reads them.
A page can only spoof metadata about **itself** — the blast radius is a wrong
anchoring URL / offline flag for that page, not bridge access — but treat the values
as untrusted anyway: the bootstrap must validate `vellum-page-url` (accept only a
parseable `http(s)` URL, else fall back to `location.href`) and coerce
`vellum-offline` to a strict `"true"` comparison. On archived snapshots (plan 005)
the vector disappears entirely because page JS is disabled. **Follow-up hardening**
(out of this plan's scope, record it in the backlog if not done here): deliver the
config through a native-controlled path instead — after the navigation commits, the
controller pushes `{pageUrl, offline}` into the bridge world via the world-scoped
`evaluateJavaScript` channel that `post(_:_:)` already uses, which page JS cannot
observe or mutate.

## Superseded design (v1 — do not implement)

1. A single named world: `static let bridgeWorld = WKContentWorld.world(name: "VellumBridge")`.
2. The content script becomes a `WKUserScript(source:injectionTime: .atDocumentStart, forMainFrameOnly: true, in: bridgeWorld)`. Because the config values (`__VELLUM_PAGE_URL__`, `__VELLUM_OFFLINE__`) differ per navigation, the controller re-registers the user script **per navigation**: in the `WKNavigationDelegate` callback that runs before content loads (`decidePolicyFor navigationAction` or `didStartProvisionalNavigation` — whichever the controller already implements), call `userContentController.removeAllUserScripts()` and add a fresh script whose source is the config-assignment prefix + `WebContentScript.source`. This preserves today's timing (config + script execute before page content). The config values come from the same state the controller already tracks for the current page/session; if `offline` is only known inside the scheme handler, see STOP conditions.
3. Handler registration moves to the world: `configuration.userContentController.add(WeakScriptMessageHandler(self), contentWorld: Self.bridgeWorld, name: "vellum")`. Page-world scripts then have **no** `window.webkit.messageHandlers.vellum`.
4. `post(_:_:)` targets the world: `webView.evaluateJavaScript(js, in: nil, in: Self.bridgeWorld)` (the `callAsyncJavaScript`-style overload; completion handler optional).
5. `prepareHtml` stops injecting `<script>…</script>` — it keeps the `<base href>` injection and the CSP/refresh-meta stripping exactly as they are.

The scratchpad editor's WKWebView (`ScratchpadPanel.swift`) loads only bundled local HTML — it is **not** part of this plan.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `BUILD SUCCEEDED` |
| Unit tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum test -only-testing:VellumTests` | `TEST SUCCEEDED` |
| Find eval sites | `grep -rn "evaluateJavaScript" Vellum/Views/Web Vellum/Services/Web` | every hit accounted for in step 3 |

## Suggested executor toolkit

- Read Apple's `WKContentWorld` and `WKUserScript` docs before starting if unsure of the overload signatures.
- For step 5's behavioral verification, use codex computer-use or the `macos-app-driver` skill if available; the app must be built and launched.

## Scope

**In scope** (the only files you should modify):
- `Vellum/Views/Web/WebViewerView.swift`
- `Vellum/Services/Web/WebPageExtractor.swift` (only the `prepareHtml` injection block)
- `Vellum/Views/Web/WebContentScript.swift` — **only if** a minimal readyState guard is needed for the new injection timing; the anchoring algorithm itself must not change.
- `plans/README.md` — status-row update only (per the executor instructions above).
- `Tests/WebHtmlPrepareTests.swift` (create — see "Test plan").

**Out of scope** (do NOT touch):
- `Vellum/Views/Web/WebArchive.swift` / snapshot sanitization — that is plan 005.
- The `handleMessage` message-type switch and its `data["vellum"] == true` / `activeTabId` guards — keep them unchanged (defense in depth).
- The scratchpad editor webview (`ScratchpadPanel.swift`, `Vellum/Resources/katex/**`).
- The anchor/selection algorithm inside `WebContentScript.source`.

## Git workflow

- Fresh worktree: from the repo's parent folder, `git worktree add 004-web-bridge-world`. The shared worktree carries uncommitted scratchpad work.
- Commit style: sentence-case imperative, e.g. "Isolate web content script and bridge in a WKContentWorld".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reconnaissance inside the two files

Confirm (and note line numbers for your report): (a) where `WebViewerController` implements `WKNavigationDelegate` and which pre-load callback exists; (b) how the controller knows the current page URL and offline state at navigation time; (c) how `WebContentScript.source` defers DOM-dependent setup (search for `DOMContentLoaded`, `readyState` in the string). Do not edit anything yet.

**Verify**: you can state where per-navigation config values will come from. If the offline flag is genuinely unknowable outside the scheme handler, trigger the STOP condition instead of inventing plumbing.

### Step 2: Register handler + static user script in the named world (v2)

Implement the v2 target design's items 2 and 4 in `WebViewerView.swift`, inside
`makeWebView()`. The script is registered **once**, with no per-navigation config
prefix — the config travels as meta tags (step 3):

```swift
static let bridgeWorld = WKContentWorld.world(name: "VellumBridge")

let script = WKUserScript(source: WebContentScript.source,
    injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.bridgeWorld)
configuration.userContentController.addUserScript(script)
configuration.userContentController.add(
    WeakScriptMessageHandler(self), contentWorld: Self.bridgeWorld, name: "vellum")
```

Do **not** build a script source from `pageUrl`/`offline`, do not call
`removeAllUserScripts()`, and do not add a navigation delegate — those are v1
mechanics, rejected above.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 3: Route outbound JS through the world; swap the inline script for meta tags

- Change `post(_:_:)` to the world-scoped overload
  (`evaluateJavaScript(js, in: nil, in: Self.bridgeWorld)`). Account for **every**
  `evaluateJavaScript` hit from the grep in "Commands" — each must either target
  `bridgeWorld` (web reader) or be justified out of scope (scratchpad editor's own
  coordinator).
- In `prepareHtml`, delete the `<script>…</script>` portion of the injection and
  replace it with the two config meta tags, keeping `<base href>`. Escape the
  `content` attribute values with the same attribute-escaping used for
  `safeUrlAttr`:
  ```swift
  let injection = "<base href=\"\(safeUrlAttr)\">"
      + "<meta name=\"vellum-page-url\" content=\"\(safeUrlAttr)\">"
      + "<meta name=\"vellum-offline\" content=\"\(offline)\">"
  ```
  Remove the now-unused `window.__VELLUM_*` config lines. If
  `WebContentScript.source` has no remaining references from
  `WebPageExtractor.swift`, that's expected (its only consumer is now
  `WebViewerView.swift`).
- In `WebContentScript.source`, apply the target design's item 3: keep
  `var PAGE_URL = location.href;` as the top-level default, reassign it inside the
  existing deferred bootstrap from the `vellum-page-url` meta tag (validated per the
  "Known limitation" note), and read `vellum-offline` from the meta tag at its
  point of use.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.
**Verify**: `grep -n "WebContentScript.source" Vellum/Services/Web/WebPageExtractor.swift` → 0 matches.
**Verify**: `grep -n "vellum-page-url" Vellum/Services/Web/WebPageExtractor.swift` → 1 match.

### Step 4: Adjust script timing if needed

If step 1 found the content script assumes inline-in-head semantics that `.atDocumentStart` doesn't satisfy (or vice versa — e.g. a `DOMContentLoaded` listener that would never fire), add the **minimal** readyState guard at the top-level bootstrap of the script (e.g. run-now-if `document.readyState !== 'loading'`, else listen). Do not touch anchoring code. If more than ~10 lines of the content script would need to change, STOP.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 5: Behavioral verification (launch the app)

1. **Feature parity**: open a real webpage in web reading mode; confirm text selection → highlight popover → highlight creation and click-to-edit still work, and the AI panel still receives page text (send any message and confirm no "no page text" degradation). Reopen the page to confirm the highlight re-anchors.
2. **Isolation**: create `/tmp/vellum-bridge-test.html` containing a script that does
   `try { window.webkit.messageHandlers.vellum.postMessage({vellum:true,type:"navigate",url:"https://example.com"}); document.title="BRIDGE-REACHABLE" } catch(e) { document.title="BRIDGE-ISOLATED" }`
   Serve it (`python3 -m http.server` in /tmp) and open `http://localhost:8000/vellum-bridge-test.html` in web reading mode. Expected: the tab does **not** navigate away, and the page title reads `BRIDGE-ISOLATED`.
3. **Offline path**: open a page, let the auto-archive complete, kill network access to it (or reopen while offline), and confirm the snapshot renders **with** working highlights (the user script injects on snapshot navigations too).

If you cannot drive the GUI in your environment, report exactly which of these three checks you could not run — do not claim them.

## Test plan

The isolation property is inherently behavioral (it lives in WebKit), so the primary tests are step 5's checks. Additionally: if `prepareHtml` is unit-testable as a pure function (it is — static, string in/out), add `Tests/WebHtmlPrepareTests.swift` asserting the output of `prepareHtml("<html><head></head></html>", pageUrl:..., offline: false)` contains `<base href` and does **not** contain `<script`. Model on `Tests/ScratchpadImportTests.swift`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -n "add(.*contentWorld" Vellum/Views/Web/WebViewerView.swift` → 1 match (world-scoped handler registration)
- [ ] `grep -c "WKContentWorld" Vellum/Views/Web/WebViewerView.swift` → ≥ 1
- [ ] `grep -n "WebContentScript.source" Vellum/Services/Web/WebPageExtractor.swift` → 0 matches
- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`; `xcodebuild ... test -only-testing:VellumTests` → `TEST SUCCEEDED`
- [ ] Step 5 checks 1–3 pass (or are explicitly reported as not runnable in this environment)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts in "Current state" don't match the live code (drift — especially if someone already moved injection to `WKUserScript`).
- The offline flag or page URL is not derivable in the controller at navigation time without threading new state through the scheme handler — report the actual data flow you found and a proposed design; do not build new cross-object plumbing unreviewed.
- Step 4 would require touching more than ~10 lines of `WebContentScript.source`, or anything in its anchoring/selection logic.
- After step 3, highlights stop anchoring on reopened pages (the compatibility contract is at risk) and one timing fix attempt didn't resolve it.

## Maintenance notes

- Plan 005 builds directly on this: with the script out of the page HTML, archived snapshots can be served with `allowsContentJavaScript = false` while the user script keeps running.
- Reviewers should scrutinize: every `evaluateJavaScript` in the web subsystem names the world (a missed one fails silently — the function simply won't exist in the page world); and `removeAllUserScripts()` is called only on the web reader's controller, which owns its own `WKUserContentController` (verify the configuration isn't shared).
- Future message types added to `handleMessage` inherit the isolation automatically, but keep the `vellum: true` guard — it costs nothing and protects against same-world regressions.
