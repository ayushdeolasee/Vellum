# Plan 007: Narrow the `open-external` bridge message so page JS cannot open arbitrary URLs in the system browser

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c874e13..HEAD -- Vellum/Views/Web/WebViewerView.swift Vellum/Views/Web/WebContentScript.swift`
> If either file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (verification gate is the app build; the unit-test suite is broken until plan 001 lands and is not required here)
- **Category**: security
- **Planned at**: commit `c874e13`, 2026-07-14

## Why this matters

Vellum's web reading mode loads pages through a custom `vellum-web://` scheme handler and injects a content script that talks to native code via `window.webkit.messageHandlers.vellum`. Commit `c874e13` added an `open-external` message: the native side accepts a page-supplied URL, checks only that its scheme is `http`/`https`, and opens it in the user's default browser via `NSWorkspace.shared.open`. The message handler is reachable by **any** script running in the served page — not just Vellum's injected script — so a malicious or compromised page can silently pop the user's real browser onto an attacker-chosen URL with no click and no confirmation (a phishing / drive-by hand-off out of the reader). The only legitimate sender is Vellum's own YouTube-embed facade, which always opens `https://www.youtube.com/watch?v=<id>`. The fix: replace the general-purpose "open any URL" command with a narrow "open this YouTube video id" command, so the worst a hostile page can do is open a YouTube watch page.

## Current state

- `Vellum/Views/Web/WebViewerView.swift` — `WebViewerController.handleMessage` dispatches bridge messages in a `switch` on the message type. Around line 795 (inside that switch, between `case "navigate"` and `case "viewport-scrolled"`):

```swift
case "open-external":
    // Content that can't work inside the reader (e.g. YouTube embeds,
    // which require an http(s) Referer the proxy origin can't send)
    // hands off to the system browser.
    guard let raw = data["url"] as? String,
          let url = URL(string: raw),
          url.scheme == "https" || url.scheme == "http" else { break }
    NSWorkspace.shared.open(url)
```

- `Vellum/Views/Web/WebContentScript.swift:182` — the single sender, inside the YouTube facade's click handler (the facade replaces YouTube iframes with a thumbnail + "Watch on YouTube" badge; `id` is the video id the surrounding code extracted from the iframe src):

```js
facade.addEventListener("click", function (e) {
  e.preventDefault();
  e.stopPropagation();
  post("open-external", { url: "https://www.youtube.com/watch?v=" + id });
});
```

- Confirm sender uniqueness yourself: `grep -n "open-external" Vellum/Views/Web/WebContentScript.swift Vellum/Views/Web/WebViewerView.swift` must show exactly one JS `post(` site and one native `case`. (Verified true at `c874e13`.)
- Repo convention note: `WebContentScript.swift` is mostly a frozen verbatim port of the pre-Swift app's JS (its header says anchor-generation code must not drift). The YouTube facade block you are editing was **added after** that port, in the `c874e13` delta — editing this one `post(...)` line does not touch the frozen anchor code. Do not reformat or restructure anything else in the file.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Regenerate project (only if you add/remove files — this plan does not) | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |

(The full test suite does not compile until plan 001 lands — do not use `xcodebuild test` as a gate here.)

## Scope

**In scope** (the only files you should modify):
- `Vellum/Views/Web/WebViewerView.swift` (the `open-external` case only)
- `Vellum/Views/Web/WebContentScript.swift` (the one `post("open-external", ...)` line only)

**Out of scope** (do NOT touch, even though they look related):
- Every other `case` in `handleMessage` (`navigate`, `viewport-scrolled`, annotation cases, …).
- All other JS in `WebContentScript.swift` — most of it is an intentionally frozen port.
- `Vellum/Services/Web/WebPageExtractor.swift` (the scheme handler; CSP work is a separate, deferred item).
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/007-narrow-open-external`.
- One commit, e.g. "Narrow open-external bridge to validated YouTube video ids".
- Stage only the two in-scope files.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Replace the native `open-external` case with `open-youtube`

In `Vellum/Views/Web/WebViewerView.swift`, replace the `case "open-external":` block shown in "Current state" with:

```swift
case "open-youtube":
    // The YouTube facade (WebContentScript) hands embeds off to the system
    // browser — embeds need an http(s) Referer the proxy origin can't send.
    // Only a validated video id crosses the bridge, never a full URL, so a
    // hostile page script can at worst open a youtube.com/watch page.
    guard let id = data["id"] as? String,
          id.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil,
          let url = URL(string: "https://www.youtube.com/watch?v=\(id)") else { break }
    NSWorkspace.shared.open(url)
```

(YouTube video ids are 11 chars from `[A-Za-z0-9_-]`; the 6–20 range is deliberate slack so a format change doesn't silently break the facade.)

**Verify**: `grep -n "open-external" Vellum/Views/Web/WebViewerView.swift` → no matches; `grep -n "open-youtube" Vellum/Views/Web/WebViewerView.swift` → exactly one match.

### Step 2: Update the facade to send the id, not a URL

In `Vellum/Views/Web/WebContentScript.swift:182` (the facade click handler shown in "Current state"), replace the `post` line with:

```js
post("open-youtube", { id: id });
```

**Verify**: `grep -n "open-external" Vellum/Views/Web/WebContentScript.swift` → no matches; `grep -cn "open-youtube" Vellum/Views/Web/WebContentScript.swift` → 1.

### Step 3: Build

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → `** BUILD SUCCEEDED **`.

### Step 4 (optional, only if you can drive the app): facade smoke test

Run the app, open a web page containing a YouTube embed (e.g. a blog post with an embedded video) in web reading mode, click the "Watch on YouTube" facade, and confirm the system browser opens the correct watch URL. If you cannot drive the app, state that in your report — the grep + build gates above are the required verification.

## Test plan

No unit test target compiles until plan 001 lands, and this handler is WKWebView-bound glue with no pure logic beyond the id regex. The greps in steps 1–2 plus the build are the required gates. If plan 001 has ALREADY landed when you execute this (check `advisor-plans/README.md`), additionally run the full suite (`xcodebuild ... test`) and expect TEST SUCCEEDED.

## Done criteria

- [ ] `grep -rn "open-external" Vellum/` → no matches
- [ ] Native handler validates `id` against `^[A-Za-z0-9_-]{6,20}$` before constructing the URL
- [ ] Build succeeds
- [ ] `git diff --stat` touches only the two in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `grep -n "open-external"` finds MORE than one JS sender or more than one native case — there is a caller this plan doesn't know about; narrowing would break it.
- The `case "open-external"` block or the facade click handler doesn't match the excerpts above (drift since `c874e13`).
- You find any other bridge message case that passes a page-supplied URL to `NSWorkspace.open` or similar — report it as a finding; do not fix it here.

## Maintenance notes

- If a future feature legitimately needs "open arbitrary external link in browser" (e.g. a toolbar button), gate it on native-side UI interaction (a real button/menu click), never on a page-posted message.
- Reviewer scrutiny: confirm the JS change is inside the facade block only and no frozen-port lines moved (diff should be ±1 line in `WebContentScript.swift`).
- Related deferred work (recorded in `advisor-plans/README.md`): serving proxy responses with a real Content-Security-Policy, and scoping the asset route's `Access-Control-Allow-Origin`. Those need a design decision; this plan is independent of them.
