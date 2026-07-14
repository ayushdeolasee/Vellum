# Plan 010: Harden the proxy-URL round trip — bare `%` in paths, userinfo encoding, adversarial tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat c874e13..HEAD -- Vellum/Services/Web/WebPageExtractor.swift Tests/WebProxyUrlTests.swift`
> If either file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S–M
- **Risk**: LOW
- **Depends on**: advisor-plans/001 (the test target must compile; this plan's gates are unit tests)
- **Category**: bug / security
- **Planned at**: commit `c874e13`, 2026-07-14

## Why this matters

Web reading mode identifies every page by its normalized URL: `WebUrl.normalize` canonicalizes, `VellumWebSchemeHandler.proxyUrl` maps it to a `vellum-web://` URL the WKWebView loads, and `realUrl` maps requests back. If any URL survives `normalize` but breaks this round trip, the reader silently binds a tab to the wrong identity (wrong archive key, wrong session) or falls back to an empty snapshot page. Two confirmed weak points:

1. **Bare `%` in paths.** `encodePathSegment` does not touch `%` at all — correct for already-encoded `%20`, wrong for a URL like `https://example.com/50%discount`, which normalize emits verbatim. `proxyUrl` then does `URL(string:)` on the mapped string and, on failure, **silently substitutes the snapshot host** — the user gets "Snapshot not found" instead of the page. Even if the platform parser accepts it, Foundation may re-encode `%` → `%25` en route, so `realUrl` returns a different string than the identity the tab was bound to.
2. **Userinfo divergence.** `normalize` hand-parses the authority and re-emits userinfo **verbatim and unvalidated** (`out += "\(userinfo)@"`), while `realUrl` re-parses with Foundation's `URLComponents`. Two different parsers on adversarial authorities (multi-`@`, exotic characters) can split userinfo/host differently — the WebKit origin the page runs in and the host the app actually fetches can then disagree. The existing round-trip tests cover only the benign `user:pw@example.com`.

The fix: percent-encode what each parser could disagree on (stray `%`, non-safe userinfo characters, including extra `@`s), make `proxyUrl`'s fallback loud in debug builds, and pin all of it with adversarial round-trip tests.

## Current state

All code in `Vellum/Services/Web/WebPageExtractor.swift`:

- `encodePathSegment` (lines 287-301), exactly:

```swift
private static func encodePathSegment(_ segment: String) -> String {
    var out = ""
    for byte in segment.utf8 {
        let c = Character(UnicodeScalar(byte))
        let needsEncoding = byte < 0x20 || byte > 0x7e
            || c == " " || c == "\"" || c == "<" || c == ">" || c == "`"
            || c == "#" || c == "?" || c == "{" || c == "}"
        if needsEncoding {
            out += String(format: "%%%02X", byte)
        } else {
            out.append(c)
        }
    }
    return out
}
```

- `normalize`'s userinfo handling: split at lines 84-87 (`if let at = authority.lastIndex(of: "@") { userinfo = String(authority[authority.startIndex..<at]) ... }`) and re-emit around line 146:

```swift
var out = "\(scheme)://"
if let userinfo, !userinfo.isEmpty { out += "\(userinfo)@" }
out += host
```

Note the split uses `lastIndex(of: "@")` — WHATWG behavior (everything before the LAST `@` is userinfo) — so for `a@b@example.com`, `userinfo` is the string `a@b`, which is then re-emitted with a raw inner `@`.

- `proxyUrl` (lines 698-711) ends with the silent fallback:

```swift
return URL(string: mapped) ?? URL(string: "\(scheme)://\(snapshotHost)/")!
```

- `realUrl` (lines 722-750) reconstructs the authority from `URLComponents.percentEncodedUser` / `.percentEncodedPassword` / `.encodedHost` — Foundation's parse, not `normalize`'s.
- `Tests/WebProxyUrlTests.swift` — existing round-trip suite; `assertRoundTrip` (lines 9-17) asserts `normalize(realUrl(proxyUrl(normalize(raw)))) == normalize(raw)`. Follow its structure for all new tests. Existing userinfo coverage is one benign case (line 31).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |
| One suite | append `-only-testing:VellumTests/WebProxyUrlTests` to the test command | that suite passes |

## Scope

**In scope** (the only files you should modify):
- `Vellum/Services/Web/WebPageExtractor.swift` — `encodePathSegment`, `normalize`'s userinfo emission, `proxyUrl`'s fallback. Nothing else in the file.
- `Tests/WebProxyUrlTests.swift` (append tests only)

**Out of scope** (do NOT touch):
- `realUrl` — it takes percent-encoding verbatim from `URLComponents`; once `normalize`'s output is unambiguous, `realUrl` is correct as-is.
- The scheme handler request pipeline (`handleRequest`, `serveArchiveAsset`, …).
- Query-string encoding (`formEncode`/`parseFormPairs`) — step 1 adds a characterization test; if it FAILS, report it (STOP condition) rather than expanding scope.
- `Vellum/Views/Web/WebViewerView.swift` (plan 008 works there — avoid conflicts).
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/010-proxy-url-hardening`.
- Commit per step or one commit, e.g. "Harden proxy URL round-trip: encode stray %, canonicalize userinfo, adversarial tests".
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Characterization tests first — pin today's behavior for the cases that already work

Append to `Tests/WebProxyUrlTests.swift` a new test method `testRoundTripAdversarial` using the existing `assertRoundTrip` helper, with these inputs — run it BEFORE any code change and record which cases fail:

```swift
try assertRoundTrip("https://example.com/a%20b")        // valid escape preserved
try assertRoundTrip("https://example.com/50%discount")  // bare % — expected to FAIL before the fix
try assertRoundTrip("https://example.com/100%")         // trailing bare %
try assertRoundTrip("https://example.com/%ZZbad")       // invalid escape — expected to FAIL before the fix
try assertRoundTrip("https://a%40b@example.com/x")      // pre-encoded @ in userinfo
try assertRoundTrip("https://a@b@example.com/x")        // multi-@ authority — may FAIL before the fix
try assertRoundTrip("https://example.com/?p=50%off")    // bare % in query (characterization: if this FAILS, STOP — see conditions)
```

**Verify**: the suite runs (some cases failing is EXPECTED at this point); note pass/fail per line in your report.

### Step 2: Encode stray `%` in `encodePathSegment`

Change `encodePathSegment` so a `%` NOT followed by two hex digits is emitted as `%25`, while valid escapes pass through untouched. Byte-indexed shape (replace the body):

```swift
private static func encodePathSegment(_ segment: String) -> String {
    let bytes = Array(segment.utf8)
    var out = ""
    var i = 0
    func isHex(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x46) || (b >= 0x61 && b <= 0x66)
    }
    while i < bytes.count {
        let byte = bytes[i]
        let c = Character(UnicodeScalar(byte))
        if c == "%" {
            // Keep valid %XX escapes verbatim (they're already-encoded input);
            // a stray % would otherwise produce an invalid URL that
            // URL(string:) rejects or re-encodes, breaking round-trip identity.
            if i + 2 < bytes.count, isHex(bytes[i + 1]), isHex(bytes[i + 2]) {
                out.append("%")
            } else {
                out += "%25"
            }
            i += 1
            continue
        }
        let needsEncoding = byte < 0x20 || byte > 0x7e
            || c == " " || c == "\"" || c == "<" || c == ">" || c == "`"
            || c == "#" || c == "?" || c == "{" || c == "}"
        if needsEncoding {
            out += String(format: "%%%02X", byte)
        } else {
            out.append(c)
        }
        i += 1
    }
    return out
}
```

(Bounds note: the lookahead reads `bytes[i + 1]` and `bytes[i + 2]`, which are valid exactly when `i + 2 < bytes.count` — the condition shown above is correct, including for a valid escape sitting at the very end of the segment. The `"a%2F"` unit case in the Verify line proves it.)

**Verify**: `.../test -only-testing:VellumTests/WebProxyUrlTests` → the bare-`%`/invalid-escape cases from step 1 now pass, plus add and pass: `try assertRoundTrip("https://example.com/a%2F")` (valid escape as the final characters).

### Step 3: Canonicalize userinfo in `normalize`

Where `normalize` re-emits userinfo (`if let userinfo, !userinfo.isEmpty { out += "\(userinfo)@" }`), percent-encode every byte that is not RFC 3986 userinfo-safe (unreserved / sub-delims / `:`), leaving valid `%XX` escapes verbatim (same lookahead rule as step 2). Notably this encodes any inner `@` (from a multi-`@` authority) as `%40`, so the emitted string has exactly one `@` and Foundation's parser cannot disagree with `normalize`'s split. Add a private helper next to `encodePathSegment`, e.g.:

```swift
/// RFC 3986 userinfo: unreserved / pct-encoded / sub-delims / ":".
/// Everything else — including a raw "@" from a multi-@ authority — gets
/// percent-encoded so normalize's WHATWG-style split (last "@") and
/// Foundation's URLComponents re-parse in realUrl agree on the same host.
private static func encodeUserinfo(_ userinfo: String) -> String
```

with the allowed set: ASCII letters, digits, `-._~`, `!$&'()*+,;=`, `:`; `%` handled with the valid-escape lookahead; all other bytes `%%%02X`-encoded.

**Verify**: `.../test -only-testing:VellumTests/WebProxyUrlTests` → all step 1 cases pass, including `a@b@example.com` (round trip must be stable; the normalized form will contain `a%40b@example.com`) and the pre-existing benign case at line 31 still passes.

### Step 4: Make `proxyUrl`'s fallback loud in debug

Replace the last line of `proxyUrl`:

```swift
guard let url = URL(string: mapped) else {
    // Normalize's output should always be URL(string:)-parseable; reaching
    // here means an encoding gap upstream — surface it in debug instead of
    // silently rebinding the tab to an empty snapshot page.
    assertionFailure("proxyUrl: unparseable mapped URL for target \(target)")
    return URL(string: "\(scheme)://\(snapshotHost)/")!
}
return url
```

**Verify**: build succeeds; full `WebProxyUrlTests` suite passes (no test should trip the assertion once steps 2–3 are in).

### Step 5: Full suite

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`.

## Test plan

Step 1 is the adversarial net (bare/trailing/invalid `%`, multi-`@`, pre-encoded `@`, `%` in query as characterization); step 2 adds the end-of-string escape case. All go in `Tests/WebProxyUrlTests.swift` using the existing `assertRoundTrip` pattern. Expected end state: every listed case passes.

## Done criteria

- [ ] All new adversarial round-trip cases pass; all pre-existing `WebProxyUrlTests` still pass
- [ ] `encodePathSegment` emits `%25` for stray `%` and preserves valid `%XX`
- [ ] `normalize` emits userinfo with exactly one raw `@` (inner `@`s encoded)
- [ ] `proxyUrl` has the debug assertion; release fallback behavior unchanged
- [ ] Full test suite: TEST SUCCEEDED
- [ ] `git diff --stat` touches only the two in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt doesn't match the live code (drift since `c874e13`).
- The bare-`%` query characterization case (step 1, last line) FAILS — query encoding (`formEncode`) has the same class of bug; that's a scope expansion the maintainer should size, not an improvisation.
- After step 3, the pre-existing benign userinfo test (line 31) fails — your encoding is over-broad (it must NOT encode `:` or already-valid escapes); report the actual normalized output.
- Fixing a failing case seems to require editing `realUrl` — that inverts the design (realUrl is the verbatim side); report instead.

## Maintenance notes

- Identity migration note: URLs whose normalized form CHANGES under this plan (bare `%` paths, multi-`@` authorities) get new page keys — any previously saved archive/session for such a URL is orphaned. These are vanishingly rare in real browsing; no migration is warranted, but a reviewer should know it's intended.
- Plan 008 (fragment scrolling) compares `normalize` outputs on both sides, so it inherits this canonicalization symmetrically — no interaction expected, but re-run its manual TOC check if both land in the same window.
- Deferred, recorded in `advisor-plans/README.md`: unit coverage for the scheme handler's serving path (`handleRequest` 204-guard, `serveArchiveAsset` traversal guards) — different seam, bigger setup, separate plan.
