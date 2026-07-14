# Plan 008: Make same-page `#fragment` links scroll in place instead of full-reloading the web reader

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c874e13..HEAD -- Vellum/Views/Web/WebViewerView.swift Vellum/Services/Web/WebPageExtractor.swift Vellum/Views/Web/WebContentScript.swift`
> If any of these changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (verification gate is the app build + manual drive; plan 001's test suite is not required)
- **Category**: bug
- **Planned at**: commit `c874e13`, 2026-07-14

## Why this matters

In web reading mode, pages load from a custom `vellum-web://<real-host>/<path>` origin, and the serving layer injects `<base href="https://<real-host>/<path>">` so the page's relative URLs resolve to the real site. Side effect: a plain same-page anchor link (`<a href="#section-2">`, e.g. a Wikipedia table-of-contents entry) resolves against the base to `https://<real-host>/<path>#section-2` — a **different scheme** from the `vellum-web://` document, so WebKit treats it as a real cross-origin navigation instead of a scroll. Vellum's own click-interception script deliberately skips `#`-prefixed hrefs (expecting the browser to just scroll), so the click reaches the navigation delegate, which cancels ALL main-frame http/https navigations and calls `navigateTo(...)` — a full tab rebind and page reload. Worse, `WebUrl.normalize` strips fragments, so the reloaded page doesn't even land on the target section: the user clicks a table-of-contents link and gets a slow reload back to the top. The fix is a small check in the navigation delegate: when the destination is the current page and only the fragment differs, set `location.hash` in-page (a same-document navigation WebKit turns into a scroll) instead of rebinding.

## Current state

- `Vellum/Views/Web/WebViewerView.swift:1079-1096` — the navigation delegate, exactly:

```swift
extension WebViewerController: WKNavigationDelegate, WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        // The injected <base href> makes any link the content script misses —
        // and router location.assign calls — resolve to the real https
        // origin; without this the webview would leave the reader entirely.
        // Main frame only: subframes (article embeds, video iframes) load
        // their real content directly.
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              navigationAction.targetFrame?.isMainFrame == true else {
            return .allow
        }
        navigateTo(url.absoluteString)
        return .cancel
    }
```

- `Vellum/Views/Web/WebViewerView.swift:878-896` — `navigateTo(_:)` is the full-rebind path (cancels pending archive, rebinds the tab via `app.webNavigated`, resets `initCount`, reloads through the proxy URL). This is what fragment clicks wrongly hit today.
- `Vellum/Services/Web/WebPageExtractor.swift:15` — `WebUrl.normalize` doc comment: "Normalize a user-supplied URL: default to https, strip fragments and ..."; lines 66-67 do the stripping (`case "#": stop = true // fragment stripped`). So `WebUrl.normalize(anything)` never contains a `#` — useful below for "same page ignoring fragment" comparison.
- `Vellum/Services/Web/WebPageExtractor.swift:722-750` — `VellumWebSchemeHandler.realUrl(from:)` maps a `vellum-web://` / `vellum-webi://` URL back to the real `https://` / `http://` string; returns `nil` for reserved hosts (`assets.vellum.invalid`, `snapshot.vellum.invalid`) and foreign schemes.
- `Vellum/Views/Web/WebContentScript.swift:1589` — the click interceptor's skip: `if (rawHref.charAt(0) === "#") return; // same-document anchor` — i.e. the JS intentionally leaves fragment clicks to the browser; the delegate is the only place they can be mishandled. This line is in the frozen-port section — do NOT edit the JS.
- IMPORTANT — why `return .allow` is NOT the fix: allowing the navigation would make WKWebView actually load `https://<real-host>/...` from the network, leaving the proxy origin entirely (losing the injected script, annotations, and archive serving). The navigation must stay cancelled; the scroll has to be done in-page.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |

(The unit-test suite does not compile until plan 001 lands; it is not a gate here.)

## Suggested executor toolkit

- If available, use the `macos-app-driver` skill (or codex computer-use per the repo's `CLAUDE.md`) for step 3's behavioral verification — it can drive the running app and take screenshots without stealing focus.

## Scope

**In scope** (the only file you should modify):
- `Vellum/Views/Web/WebViewerView.swift` (the `decidePolicyFor` method only)

**Out of scope** (do NOT touch):
- `Vellum/Views/Web/WebContentScript.swift` — the `#`-skip at line 1589 is correct and frozen.
- `Vellum/Services/Web/WebPageExtractor.swift` — `normalize`/`realUrl` are shared identity logic (plan 010 hardens them separately; do not create conflicts).
- `navigateTo(_:)` itself — the rebind path is correct for real navigations.
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/008-fragment-scroll`.
- One commit, e.g. "Scroll in place for same-page fragment links instead of reloading the reader".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Intercept fragment-only navigations in `decidePolicyFor`

In `Vellum/Views/Web/WebViewerView.swift`, inside `decidePolicyFor` after the existing `guard` and before `navigateTo(url.absoluteString)`, insert:

```swift
// A same-page anchor click resolves against the injected <base href> to
// the real https origin, so WebKit sees a cross-origin navigation instead
// of a scroll. When only the fragment differs from the current page,
// scroll in place via location.hash (a same-document navigation) rather
// than rebinding and reloading the whole reader. normalize strips
// fragments, so equal normalized URLs == same page.
if let fragment = url.fragment,
   let currentProxy = webView.url,
   let currentReal = VellumWebSchemeHandler.realUrl(from: currentProxy),
   let incoming = try? WebUrl.normalize(url.absoluteString),
   let current = try? WebUrl.normalize(currentReal),
   incoming == current {
    // JSON-encode the fragment so quotes/backslashes can't break out of
    // the JS string.
    if let data = try? JSONEncoder().encode("#" + fragment),
       let literal = String(data: data, encoding: .utf8) {
        webView.evaluateJavaScript("location.hash = \(literal);", completionHandler: nil)
    }
    return .cancel
}
```

Notes for correct placement and types:
- `url.fragment` is non-nil only when the destination carries `#something`; destinations without a fragment keep today's behavior (full `navigateTo`), including a link to the exact same URL (browser-style reload) — that behavior change is out of scope.
- `WebUrl.normalize` throws; `try?` + `let` guards cover malformed edge cases by falling through to the existing `navigateTo` path.
- `location.hash = "#section-2"` on a document whose URL has no/other fragment is a same-document navigation: WebKit scrolls to the matching `id=`/`name=` anchor and does NOT call `decidePolicyFor` for http/https (the document URL stays `vellum-web://...`, which the guard already lets through as `.allow`).

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → `** BUILD SUCCEEDED **`.

### Step 2: Confirm no recursion / no scheme regression by reading

Re-read the modified method and confirm: (a) the new block is INSIDE the http/https + main-frame guard (fragment handling must not run for `vellum-web://` same-document navigations — those never enter the guarded region anyway); (b) every fall-through path still ends in `navigateTo` + `.cancel` exactly as before.

**Verify**: `git diff Vellum/Views/Web/WebViewerView.swift` shows changes only inside `decidePolicyFor`, and the method still contains exactly one `navigateTo(` call.

### Step 3: Behavioral verification in the running app

Launch the app, open web reading mode on a page with a table of contents (e.g. any long Wikipedia article: File → open web URL, `https://en.wikipedia.org/wiki/PDF`). Click a TOC entry. Expected: the view scrolls to the section **without** a reload (no flash/re-extraction; the scroll is instant). Then click a normal cross-page link and confirm it still navigates (full rebind) correctly. If you cannot drive the app, say so in your report and flag the plan as needing manual QA — the build gate alone does not prove the scroll behavior.

## Test plan

The delegate needs a live WKWebView + the app's session plumbing, so there is no reasonable unit seam; step 3's manual drive is the behavioral test. If plan 001 has landed (check `advisor-plans/README.md`), also run the full suite (`xcodebuild ... test` → TEST SUCCEEDED) to confirm no collateral damage.

## Done criteria

- [ ] Build succeeds
- [ ] `decidePolicyFor` cancels fragment-only navigations and sets `location.hash` in-page; all other main-frame http/https navigations still go through `navigateTo`
- [ ] Manual TOC-link check performed (or explicitly reported as not performed)
- [ ] `git diff --stat` touches only `Vellum/Views/Web/WebViewerView.swift`
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The `decidePolicyFor` body doesn't match the "Current state" excerpt (drift since `c874e13`).
- `WebUrl.normalize` or `VellumWebSchemeHandler.realUrl` is not accessible from `WebViewerView.swift` (visibility/module issue) — do not change their access levels yourself; report it.
- Step 3 shows the page still reloading on a TOC click — your comparison isn't matching (likely a normalize/realUrl mismatch); capture both normalized strings via a temporary log line, report them, and revert the temporary logging.

## Maintenance notes

- Plan 010 hardens `normalize`/`realUrl` round-tripping. If it lands after this plan, its changes can alter the equality comparison used here — the pair should stay consistent (both sides of the comparison go through `normalize`, so a canonicalization change affects both sides equally; a reviewer should still re-run the TOC check after 010).
- Deferred (do not build now): preserving the fragment across REAL cross-page navigations (`navigateTo` normalizes it away, so `page2#sec` lands at the top of page2). Same delegate, different fix (pass the fragment through and set `location.hash` after init) — worth a follow-up finding if users notice.
- Reviewer scrutiny: the JS string interpolation — the fragment is JSON-encoded before interpolation; confirm no path interpolates it raw.
