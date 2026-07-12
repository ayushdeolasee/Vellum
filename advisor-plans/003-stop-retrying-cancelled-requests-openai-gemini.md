# Plan 003: Stop OpenAIClient and GeminiClient from retrying user-cancelled requests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 314cf9f..HEAD -- Vellum/Services/Ai/OpenAIClient.swift Vellum/Services/Ai/GeminiClient.swift Vellum/Services/Ai/ChatGPTClient.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: advisor-plans/001-land-ai-pipeline-helpers-fix-test-target.md (001 edits the same two files; land it first to avoid merge conflicts)
- **Category**: bug
- **Planned at**: commit `314cf9f`, 2026-07-12

## Why this matters

All five AI provider clients contain a copy-pasted `openStream(_:)` helper that retries a failed request once. The three newer clients (ChatGPT, OpenRouter, OpenCodeZen) were fixed to rethrow `CancellationError` / `URLError.cancelled` immediately — a user-initiated abort (clearing the conversation, switching tabs, cancelling a send) must never be retried. `OpenAIClient` and `GeminiClient` never received that fix: their generic `catch` treats cancellation like a transient network failure and **fires the request a second time** after the user cancelled it. Consequences: a phantom in-flight request the user believes is dead, wasted paid tokens, and (because the guarded event sink drops events for a changed tab) work whose output is discarded. This is confirmed copy-paste drift, not intent — the fix is to port the exact pattern the other three clients already use.

## Current state

`Vellum/Services/Ai/OpenAIClient.swift:121–144` (GeminiClient.swift:122–145 is byte-for-byte identical apart from the "OpenAI"/"Gemini" strings):

```swift
private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
    var lastError: Error?
    for attempt in 0...1 {
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw AiClientError.message("OpenAI returned an invalid HTTP response.")
            }
            if (200..<300).contains(http.statusCode) { return bytes }
            let data = try await Self.drain(bytes)
            let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
            let error = AiClientError.message(message.isEmpty ? "OpenAI request failed with status \(http.statusCode)." : message)
            if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
                lastError = error
                continue
            }
            throw error
        } catch {
            lastError = error            // ← CancellationError lands here and is retried
            if attempt == 1 { throw error }
        }
    }
    throw lastError ?? AiClientError.message("OpenAI request failed.")
}
```

The bug: the outer `do/catch` wraps the whole body, so BOTH transport errors AND the deliberately-thrown status errors funnel through the generic `catch`, and a `CancellationError` from the `URLSession.shared.bytes(for:)` await is swallowed into `lastError` and retried on attempt 0.

The reference implementation — `Vellum/Services/Ai/ChatGPTClient.swift:147–178` — restructures so only the transport call is caught, with cancellation rethrown:

```swift
private func openStream(_ request: URLRequest) async throws -> URLSession.AsyncBytes {
    var lastError: Error?
    for attempt in 0...1 {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError() // user-initiated abort: never retry
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError() // URLSession task cancelled: never retry
        } catch {
            lastError = error
            if attempt == 1 { throw error }
            continue // transient network failure: retry once
        }

        guard let http = response as? HTTPURLResponse else {
            throw AiClientError.message("ChatGPT returned an invalid HTTP response.")
        }
        if (200..<300).contains(http.statusCode) { return bytes }
        let data = try await Self.drain(bytes)
        let message = Self.providerMessage((try? Self.jsonObject(data)) ?? [:], fallback: String(decoding: data, as: UTF8.self))
        let error = AiClientError.message(message.isEmpty ? "ChatGPT request failed with status \(http.statusCode)." : message)
        if attempt == 0, http.statusCode == 408 || http.statusCode == 429 || http.statusCode >= 500 {
            lastError = error
            continue // transient status: retry once
        }
        throw error // non-retryable status: escapes immediately
    }
    throw lastError ?? AiClientError.message("ChatGPT request failed.")
}
```

Note the second behavioral difference this restructure also fixes: in the old shape, a NON-retryable HTTP status error (e.g. 401 bad key) thrown on attempt 0 is caught by the generic `catch` and retried anyway; the reference shape lets it escape immediately. Port the whole shape, not just the two catch clauses.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `Vellum/Services/Ai/OpenAIClient.swift` — only the `openStream(_:)` method body.
- `Vellum/Services/Ai/GeminiClient.swift` — only the `openStream(_:)` method body.

**Out of scope**:
- `ChatGPTClient.swift`, `OpenRouterClient.swift`, `OpenCodeZenClient.swift` — already correct; read-only reference.
- Any broader deduplication of the five clients (a known, separately-tracked tech-debt item — do not start it here).
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/003-never-retry-cancelled`.
- Commit message: e.g. "Never retry user-cancelled requests in OpenAI/Gemini clients".
- Stage only the two files; never `*.pbxproj`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Restructure `OpenAIClient.openStream`

Rewrite the method to the reference shape above, keeping the "OpenAI"-specific error strings exactly as they are ("OpenAI returned an invalid HTTP response.", "OpenAI request failed with status …", "OpenAI request failed."). The comments (`// user-initiated abort: never retry`, etc.) should be carried over verbatim — they document the contract.

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → BUILD SUCCEEDED

### Step 2: Restructure `GeminiClient.openStream`

Same transformation, keeping the "Gemini" error strings.

**Verify**: build succeeds, and:
`grep -c "never retry" Vellum/Services/Ai/OpenAIClient.swift Vellum/Services/Ai/GeminiClient.swift` → `2` for each file.

### Step 3: Full test run

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` → TEST SUCCEEDED.

## Test plan

`openStream` is `private` and network-bound in all five clients, so there is no existing unit-test seam — the three already-fixed clients have none either. Do not widen access or add a URLProtocol harness in this plan (that's part of the deferred client-dedup work). Verification is: build + full suite green + the grep in step 2 proving both files carry the cancellation guards.

## Done criteria

- [ ] Build and full test suite pass
- [ ] Both files contain `catch is CancellationError` and `catch let error as URLError where error.code == .cancelled` inside `openStream`
- [ ] `git diff --stat` touches only the two in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

- The `openStream` bodies don't match the excerpt (drift — possibly a shared streaming layer landed; if so this plan is obsolete, report that).
- Fixing the method seems to require changes outside the two method bodies.

## Maintenance notes

- This is the fourth and fifth copy of the same function receiving the same fix — direct evidence for the deferred "extract a shared streaming/request layer for the five clients" tech-debt item recorded in `advisor-plans/README.md`. When that lands, this logic should exist exactly once.
- Reviewer scrutiny: diff each rewritten method against its ChatGPT counterpart — the only differences should be the provider name in the three strings.
