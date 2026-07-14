# Plan 001: Land the AI-pipeline helpers that `Tests/AiPipelineTests.swift` specifies, restoring a compiling test target

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 314cf9f..HEAD -- Tests/AiPipelineTests.swift Vellum/Stores/AiStore.swift Vellum/Services/Ai/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: L
- **Risk**: MED
- **Depends on**: none (do this plan FIRST — every other plan's verification relies on `xcodebuild test` working)
- **Category**: bug / tests
- **Planned at**: commit `314cf9f`, 2026-07-12

## Why this matters

Commit `314cf9f` ("Add AI benchmarking suite and on-demand retrieval groundwork") added `Tests/AiPipelineTests.swift`, a 411-line deterministic test suite written during the review of GitHub issue #37 (on-demand document retrieval). The tests reference ~14 helper symbols that were **never implemented** — the test target does not compile at HEAD, so `xcodebuild test` fails outright and all 5 test files (~1.6k lines) provide zero protection. The tests are not garbage: they are the maintainer's committed spec for the retrieval pipeline, and several pin **real fixes to current behavior** (the latest user request is currently sent twice per prompt; OpenRouter currently attaches an Anthropic cache breakpoint to every image, which exceeds Anthropic's 4-breakpoint limit with 3+ images; OpenAI responses are hard-capped at 2048 output tokens regardless of thinking mode; Gemini tool-loop replay drops `thoughtSignature`s that Gemini 3 requires on signed turns). This plan implements the helpers exactly as the tests specify. When it lands, the repo has a working one-command verification gate again.

**The tests are the source of truth.** Read `Tests/AiPipelineTests.swift` in full before starting. Do not modify the test file except where a step below explicitly says so (there are no such steps — if a test seems wrong, that is a STOP condition).

## Current state

Files and their roles:

- `Tests/AiPipelineTests.swift` — the spec. References missing symbols; do not edit.
- `Vellum/Stores/AiStore.swift` — `@MainActor` chat store. `AiMessage` struct at line 59; the send pipeline at ~420–630. Missing: `composeAssistantContent`, `promptHistory`, `AiMessage.usage`.
- `Vellum/Services/Ai/AiToolEngine.swift` — tool dispatch for `getPageText`/`searchDocument`/`goToPage`/`addNote`/`addHighlight`. Missing: `boundedPageRead`, `annotationsSection`, `maxPageReadCharacters`, `maxAnnotationReadCharacters`, `maxAnnotationsPerRead`.
- `Vellum/Services/Ai/GeminiClient.swift` — Gemini SSE client. Missing: `accumulateReplayPart`, `thinkingConfig(for:model:)` (a narrower `geminiThinkingBudget` helper exists at ~line 190).
- `Vellum/Services/Ai/OpenAIClient.swift` — OpenAI Responses API client. Missing: `maxOutputTokens(forEffort:)`, `incompleteMessage(reason:)`.
- `Vellum/Services/Ai/OpenRouterClient.swift` — OpenRouter Chat Completions client. Missing: `initialMessages(systemPrompt:prompt:images:)`, `requestBody(model:messages:thinkingMode:allowTools:sessionId:)`.
- `Vellum/Services/Ai/AiUsage.swift` — already has `AiUsage` with `accumulate`, `fromChatCompletions`, `fromResponses`, `fromGemini`. No changes needed here.
- `Vellum/Services/Ai/AiPersistence.swift` — conversation persistence; `sanitizeMessage` at ~line 183 rebuilds messages field-by-field and will silently drop the new `usage` field unless extended (step 3).

Key current-state excerpts (verify these match before editing):

`AiStore.swift:59` — AiMessage has no usage field:
```swift
struct AiMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: AiRole
    var content: String
    var createdAt: String
}
```

`AiStore.swift:428–429` and `464` — the conversation block is built from `messagesWithUser`, which still CONTAINS the latest user message; the same text is also sent as `latestUserRequest`, so it appears twice in every prompt:
```swift
let messagesWithUser = Array(messages.dropLast())   // drops the assistant placeholder only
...
let conversation = AiPrompts.buildConversationBlock(messagesWithUser)
```

`AiStore.swift:~584–592` — assistant content composition is inline:
```swift
let assistantContent: String
if displayActions.isEmpty {
    assistantContent = result.reply
} else {
    assistantContent = result.reply + "\n\nActions:\n"
        + displayActions.map { "- \($0)" }.joined(separator: "\n")
}
let finalContent = assistantContent.trimmingCharacters(in: .whitespacesAndNewlines)
```

`AiToolEngine.swift` — `getPageText` returns UNBOUNDED text and no annotations:
```swift
private func getPageText(pageNumber: Double?) async -> String {
    let page = clampPage(pageNumber)
    if store.pageTexts[page] == nil {
        store.setActivity(.indexing)
        _ = await store.ensureExtracted(pages: [page])
    }
    let text = store.pageTexts[page] ?? ""
    guard !text.isEmpty else {
        return "Page \(page) has no extractable text (it may be a scanned image). Request a page image to read it visually."
    }
    return "Page \(page):\n\(text)"
}
```
The engine holds `private unowned let annotations: AnnotationStore` (line 36); `AnnotationStore.annotationsForPage(_:)` exists at `AnnotationStore.swift:202`.

`GeminiClient.swift:~95–98` — tool-turn replay rebuilds parts, losing `thoughtSignature` and merging everything:
```swift
var modelParts: [[String: Any]] = []
if !text.isEmpty { modelParts.append(["text": text]) }
for call in calls { modelParts.append(["functionCall": call]) }
contents.append(["role": "model", "parts": modelParts])
```

`GeminiClient.swift:~41–53` — thinking config caller; `geminiThinkingBudget(for:model:)` (private, ~line 190) returns `Int?` only — no `thinkingLevel` support for Gemini 3:
```swift
} else if let budget = Self.geminiThinkingBudget(for: thinkingMode, model: model) {
    generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
}
```

`GeminiClient.swift:12` — stale comment says the tool loop runs "up to 6 iterations"; the loop is `for _ in 0..<8` (line 55).

`OpenAIClient.swift:~36–55` — output tokens hardcoded; effort computed only for gpt-5 family:
```swift
"max_output_tokens": 2048,
...
if model.lowercased().hasPrefix("gpt-5") {
    let effort = thinkingMode.openAIEffort ?? "minimal"
    body["reasoning"] = ["effort": effort]
}
```

`OpenRouterClient.swift:~37–62` — message construction is inline; every image gets a `cache_control` breakpoint (breaks Anthropic's 4-breakpoint limit with 3+ images); there is no `session_id` in the body:
```swift
var userContent: [[String: Any]] = [[
    "type": "text", "text": prompt.stable,
    "cache_control": ["type": "ephemeral"],          // breakpoint 2: + document context
]]
for image in images where !image.base64Data.isEmpty {
    userContent.append([
        "type": "image_url",
        "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64Data)"],
        "cache_control": ["type": "ephemeral"],      // breakpoint 3: + page image
    ])
}
userContent.append(["type": "text", "text": prompt.volatile])
var messages: [[String: Any]] = [
    ["role": "system", "content": [[
        "type": "text", "text": systemPrompt,
        "cache_control": ["type": "ephemeral"],      // breakpoint 1: tools + system
    ]]],
    ["role": "user", "content": userContent],
]
```
Reasoning mapping already exists at ~line 81: `if thinkingMode != .auto, let effort = thinkingMode.openAIEffort { body["reasoning"] = ["effort": effort] }`.

Repo conventions: doc comments (`///`) on public helpers explaining *why*; guard-early style; `Self.` for static calls from instance methods. Match the tone of existing comments in these files (they explain provider quirks inline).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build app | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Run tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` (currently FAILS at HEAD — that is the bug) |
| Run one test class | append `-only-testing:VellumTests/AiPipelineTests` to the test command | that class passes |

No `xcodegen generate` needed — no files are added or removed.

## Scope

**In scope** (the only files you should modify):
- `Vellum/Stores/AiStore.swift`
- `Vellum/Services/Ai/AiToolEngine.swift`
- `Vellum/Services/Ai/GeminiClient.swift`
- `Vellum/Services/Ai/OpenAIClient.swift`
- `Vellum/Services/Ai/OpenRouterClient.swift`
- `Vellum/Services/Ai/AiPersistence.swift` (step 3 only: `sanitizeMessage`)

**Out of scope** (do NOT touch):
- `Tests/AiPipelineTests.swift` — it is the spec.
- `Vellum/Services/Ai/ChatGPTClient.swift`, `OpenCodeZenClient.swift` — they have no failing test references; leave them alone (Plan 003 touches OpenAI/Gemini's `openStream`; do not do that work here).
- `Vellum/Services/Ai/AiUsage.swift`, `AiPrompts.swift`, `AiStreaming.swift` — already satisfy their tests.
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit this file.

## Git workflow

- Branch off the current branch (`ai-ondemand-retrieval`): `advisor/001-ai-pipeline-helpers`.
- Commit style: short imperative subject, matching `git log` (e.g. "Add AI pipeline helpers specified by AiPipelineTests"). One commit per step or one for the whole plan — either is fine.
- Other agent sessions may share this worktree: stage only the files you changed, never `*.pbxproj`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add `AiStore.composeAssistantContent(reply:receipts:)` and use it at the call site

In `Vellum/Stores/AiStore.swift`, add to `AiStore`:

```swift
/// Persisted assistant content = reply + compact per-action receipts.
/// Raw tool payloads (full page text / search results) must never reach
/// the persisted message — only these one-line receipts do.
static func composeAssistantContent(reply: String, receipts: [String]) -> String {
    guard !receipts.isEmpty else {
        return reply.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return (reply + "\n\nActions:\n" + receipts.map { "- \($0)" }.joined(separator: "\n"))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}
```

Replace the inline block at ~584–592 (excerpt above) with:

```swift
let finalContent = Self.composeAssistantContent(reply: result.reply, receipts: displayActions)
```

(Deleting the now-unused `assistantContent` local.)

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → `** BUILD SUCCEEDED **`

### Step 2: Add `AiStore.promptHistory(from:)` and stop double-sending the latest user request

Add to `AiStore`:

```swift
/// The conversation-block slice: everything BEFORE the newest user message.
/// The newest request is sent separately under "### Latest User Request",
/// so including it here would duplicate it in every prompt.
static func promptHistory(from messages: [AiMessage]) -> [AiMessage] {
    guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
        return messages
    }
    return Array(messages[..<lastUserIndex])
}
```

At `AiStore.swift:464`, change:

```swift
let conversation = AiPrompts.buildConversationBlock(messagesWithUser)
```
to
```swift
let conversation = AiPrompts.buildConversationBlock(Self.promptHistory(from: messagesWithUser))
```

This is a deliberate behavior change: the latest request currently appears twice in every prompt (once in the conversation block, once as `latestUserRequest`). `testLatestUserRequestAppearsExactlyOnce` pins the fix.

**Verify**: build succeeds.

### Step 3: Add `AiMessage.usage` and preserve it through persistence

In `AiStore.swift:59`, add a trailing optional field:

```swift
struct AiMessage: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var role: AiRole
    var content: String
    var createdAt: String
    /// Per-response token/cost telemetry; absent on messages persisted
    /// before telemetry existed and on user messages.
    var usage: AiUsage? = nil
}
```

Synthesized Codable uses `encodeIfPresent`/`decodeIfPresent` for optionals, which is exactly what `testUsageSurvivesMessageEncodingRoundTrip` requires (legacy JSON without a `usage` key must decode with `usage == nil`).

In `Vellum/Services/Ai/AiPersistence.swift`, `sanitizeMessage` rebuilds messages field-by-field and would silently drop `usage` on every app relaunch. Extend it: after the existing field extraction, add

```swift
var usage: AiUsage? = nil
if let usageValue = value["usage"] as? [String: Any],
   let usageData = try? JSONSerialization.data(withJSONObject: usageValue) {
    usage = try? JSONDecoder().decode(AiUsage.self, from: usageData)
}
```
and set `usage: usage` in the returned `AiMessage`.

Also check `AiPersistence.makeMessage` (~line 131): it constructs `AiMessage(id:role:content:createdAt:)` — the new field's default means no change is required there; confirm it still compiles.

**Verify**: build succeeds.

### Step 4: Add the bounded-read helpers to `AiToolEngine` and wire them into `getPageText`

Add to `AiToolEngine` (as `static` members — the tests call them on the type):

```swift
/// Caps for what a single getPageText call may return: a page read is
/// bounded so one dense page can't blow the prompt budget, and annotation
/// echoes are clipped per entry and capped in count (newest kept).
static let maxPageReadCharacters = 12_000
static let maxAnnotationReadCharacters = 300
static let maxAnnotationsPerRead = 20

static func boundedPageRead(page: Int, text: String) -> String {
    let header = "Page \(page):\n"
    guard text.count > maxPageReadCharacters else { return header + text }
    let clipped = String(text.prefix(maxPageReadCharacters))
    return header + clipped + "\n[truncated — page text continues beyond \(maxPageReadCharacters) characters]"
}
```

And the annotations section. The exact output format is pinned character-for-character by `testAnnotationsSectionFormatsHighlightsAndNotes` — read that test (lines 59–123 of the test file) before writing this:

```swift
/// getPageText appends the page's highlights and notes so the model sees
/// what the user marked. Highlights quote their selected text (plus any
/// user comment), notes list their content; bookmarks and empty entries
/// are skipped; long text is clipped; at most maxAnnotationsPerRead
/// entries are listed, keeping the NEWEST (input is creation-ordered).
static func annotationsSection(page: Int, annotations: [Annotation]) -> String? {
    func clip(_ string: String) -> String {
        string.count > maxAnnotationReadCharacters
            ? String(string.prefix(maxAnnotationReadCharacters)) + "…"
            : string
    }
    var lines: [String] = []
    for annotation in annotations {
        let comment = (annotation.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch annotation.type {
        case .highlight:
            let selected = (annotation.positionData?.selectedText ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !selected.isEmpty, !comment.isEmpty {
                lines.append("- Highlight: \"\(clip(selected))\" — user comment: \(clip(comment))")
            } else if !selected.isEmpty {
                lines.append("- Highlight: \"\(clip(selected))\"")
            } else if !comment.isEmpty {
                lines.append("- Highlight comment: \(clip(comment))")
            }
        case .note:
            if !comment.isEmpty { lines.append("- Note: \(clip(comment))") }
        default:
            continue
        }
    }
    guard !lines.isEmpty else { return nil }
    var hidden = 0
    if lines.count > maxAnnotationsPerRead {
        hidden = lines.count - maxAnnotationsPerRead
        lines = Array(lines.suffix(maxAnnotationsPerRead))
    }
    var output = ["User highlights and notes on page \(page):"] + lines
    if hidden > 0 {
        output.append("…and \(hidden) earlier annotations on this page (not shown).")
    }
    return output.joined(separator: "\n")
}
```

Note the em-dash `—` (U+2014) and ellipsis `…` (U+2026) — copy them from the test's expected strings, not ASCII lookalikes.

Wire into `getPageText`: replace the final `return "Page \(page):\n\(text)"` with:

```swift
var output = Self.boundedPageRead(page: page, text: text)
if let section = Self.annotationsSection(page: page, annotations: annotations.annotationsForPage(page)) {
    output += "\n\n" + section
}
return output
```

(`annotations` here is the engine's existing `AnnotationStore` property at line 36; `annotationsForPage` exists at `AnnotationStore.swift:202`. If `Annotation.type` cases are named differently than `.highlight`/`.note`, check `Tests/AiPipelineTests.swift:60–78` which constructs them — it uses `AnnotationType` values `.highlight`, `.note`, `.bookmark`.)

**Verify**: build succeeds.

### Step 5: Add `GeminiClient.accumulateReplayPart` and replay streamed parts verbatim

Add to `GeminiClient`:

```swift
/// Accumulates a streamed model part for verbatim replay in the next tool
/// turn. Plain unsigned visible text merges into a preceding part of the
/// same kind; functionCall parts, thoughtSignature-carrying parts, and
/// thought parts are kept as-is — Gemini 3 rejects tool turns whose signed
/// parts were merged or dropped.
static func accumulateReplayPart(_ part: [String: Any], into parts: inout [[String: Any]]) {
    func isPlainUnsignedText(_ candidate: [String: Any]) -> Bool {
        candidate["functionCall"] == nil
            && candidate["thoughtSignature"] == nil
            && (candidate["thought"] as? Bool) != true
            && candidate["text"] is String
    }
    if isPlainUnsignedText(part),
       let lastIndex = parts.indices.last,
       isPlainUnsignedText(parts[lastIndex]),
       let previous = parts[lastIndex]["text"] as? String,
       let chunk = part["text"] as? String {
        parts[lastIndex]["text"] = previous + chunk
        return
    }
    parts.append(part)
}
```

In `send(...)`, inside the SSE loop (excerpt in Current state): declare `var replayParts: [[String: Any]] = []` next to `var text = ""` / `var calls...`, and inside the `for part in parts` loop add `Self.accumulateReplayPart(part, into: &replayParts)` (keep the existing `text += chunk` / `calls.append` bookkeeping — `text` still drives the UI stream and `finalize`). Additionally, guard the visible-text emission so thought text is not streamed to the UI: change `if let chunk = part["text"] as? String, !chunk.isEmpty` to also require `(part["thought"] as? Bool) != true`.

Then replace the replay rebuild (~lines 95–98, excerpt above) with:

```swift
contents.append(["role": "model", "parts": replayParts])
```

While in this file, fix the stale comment at line 12: "up to 6 iterations" → "up to 8 iterations".

**Verify**: build succeeds.

### Step 6: Replace `geminiThinkingBudget` with `thinkingConfig(for:model:)`

The behavior matrix is pinned by `testGeminiThinkingConfigMatchesModelFamily` (test file lines 221–253). Add to `GeminiClient`:

```swift
/// thinkingConfig payload for the given effort, or nil to omit it.
/// Gemini 3 families take a discrete thinkingLevel — numeric budgets are a
/// request error there. 2.x keeps numeric budgets (Pro floors at 128, its
/// minimum). 1.5 and unknown families send nothing. `.auto` is the
/// caller's branch and must never be routed here.
static func thinkingConfig(for mode: AiThinkingMode, model: String) -> [String: Any]? {
    guard mode != .auto else { return nil }
    let lowered = model.lowercased()
    if lowered.contains("1.5") { return nil }
    if lowered.contains("gemini-3") {
        // gemini-3-pro (not 3.1) supports only low/high; round toward them.
        let onlyLowHigh = lowered.contains("gemini-3-pro")
        switch mode {
        case .instant: return ["thinkingLevel": onlyLowHigh ? "low" : "minimal"]
        case .low:     return ["thinkingLevel": "low"]
        case .medium:  return ["thinkingLevel": onlyLowHigh ? "high" : "medium"]
        case .high:    return ["thinkingLevel": "high"]
        case .auto:    return nil
        }
    }
    guard lowered.contains("2.5") || lowered.contains("2.0") else { return nil }
    let isPro = lowered.contains("pro")
    switch mode {
    case .instant: return ["thinkingBudget": isPro ? 128 : 0]
    case .low:     return ["thinkingBudget": isPro ? 128 : 512]
    case .medium:  return ["thinkingBudget": -1]  // dynamic: model decides
    case .high:    return ["thinkingBudget": 24576]
    case .auto:    return nil
    }
}
```

Update the caller (~line 52): replace

```swift
} else if let budget = Self.geminiThinkingBudget(for: thinkingMode, model: model) {
    generationConfig["thinkingConfig"] = ["thinkingBudget": budget]
}
```
with
```swift
} else if let config = Self.thinkingConfig(for: thinkingMode, model: model) {
    generationConfig["thinkingConfig"] = config
}
```

Keep the `.auto` branch above it (2.5-Flash-family `thinkingBudget: 0`) exactly as it is. Delete the now-unused `geminiThinkingBudget` (keep its explanatory comment content by folding anything still-relevant into the new helper's doc comment).

**Verify**: build succeeds, and `grep -n "geminiThinkingBudget" Vellum/Services/Ai/GeminiClient.swift` → no matches.

### Step 7: Add `OpenAIClient.maxOutputTokens(forEffort:)` and `incompleteMessage(reason:)`, and wire them

Add to `OpenAIClient`:

```swift
/// Output budget scaled to the user's thinking mode: reasoning models burn
/// output tokens on thinking, so a flat cap starves high-effort answers.
static func maxOutputTokens(forEffort effort: String) -> Int {
    switch effort {
    case "low": return 8192
    case "medium": return 16384
    case "high": return 32768
    default: return 4096   // "minimal" and anything unrecognized
    }
}

/// User-facing note when the Responses API reports an incomplete response.
static func incompleteMessage(reason: String) -> String {
    if reason == "max_output_tokens" {
        return "The response hit the output token limit before finishing. Try a higher thinking mode or a more specific request."
    }
    return "The response ended early (reason: \(reason))."
}
```

Wire the budget: in `send(...)`, compute the effort string once before the body is built (it is currently computed inside the gpt-5 branch — hoist it):

```swift
let effort = model.lowercased().hasPrefix("gpt-5") ? (thinkingMode.openAIEffort ?? "minimal") : "minimal"
```
and replace `"max_output_tokens": 2048` with `"max_output_tokens": Self.maxOutputTokens(forEffort: effort)`, keeping the existing `body["reasoning"] = ["effort": effort]` inside the gpt-5 guard.

Wire the incomplete note: find the SSE `switch type` case that handles `"response.completed"` in this file. The completed event's `object["response"]` dictionary carries `"status"` and, when incomplete, `"incomplete_details": ["reason": ...]`. Where the response completes, add:

```swift
if let response = object["response"] as? [String: Any],
   response["status"] as? String == "incomplete" {
    let reason = ((response["incomplete_details"] as? [String: Any])?["reason"] as? String) ?? "unknown"
    let note = Self.incompleteMessage(reason: reason)
    text += (text.isEmpty ? "" : "\n\n") + note
    onEvent(.textDelta((text == note ? "" : "\n\n") + note))
}
```

If the `"response.completed"` case does not exist or the surrounding code doesn't match this description, implement only the two static helpers (the tests only exercise the helpers) and record the wiring as skipped in your report — do not invent a different event shape.

**Verify**: build succeeds.

### Step 8: Extract `OpenRouterClient.initialMessages` and `requestBody`, capping cache breakpoints and adding the sticky session key

Add to `OpenRouterClient`:

```swift
/// Initial message list with exactly two cache_control breakpoints —
/// system (tools + system prompt) and document context — regardless of how
/// many images are attached. Anthropic rejects requests with more than
/// four breakpoints, and volatile page screenshots are poor cache material.
static func initialMessages(
    systemPrompt: String,
    prompt: AiUserPrompt,
    images: [AiPageImageSnapshot]
) -> [[String: Any]] {
    var userContent: [[String: Any]] = [[
        "type": "text", "text": prompt.stable,
        "cache_control": ["type": "ephemeral"],   // breakpoint 2: + document context
    ]]
    for image in images where !image.base64Data.isEmpty {
        userContent.append([
            "type": "image_url",
            "image_url": ["url": "data:\(image.mediaType);base64,\(image.base64Data)"],
        ])
    }
    userContent.append(["type": "text", "text": prompt.volatile])
    return [
        ["role": "system", "content": [[
            "type": "text", "text": systemPrompt,
            "cache_control": ["type": "ephemeral"],   // breakpoint 1: tools + system
        ]]],
        ["role": "user", "content": userContent],
    ]
}

/// Request body for one tool-loop turn. `session_id` pins OpenRouter's
/// provider routing per tab so cache hits land on the same upstream.
static func requestBody(
    model: String,
    messages: [[String: Any]],
    thinkingMode: AiThinkingMode,
    allowTools: Bool,
    sessionId: String
) -> [String: Any] {
    var body: [String: Any] = [
        "model": model,
        "messages": messages,
        "stream": true,
        "max_tokens": 2048,                       // cost guard: cap the visible output
        "usage": ["include": true],
        "session_id": "vellum-\(sessionId)",
    ]
    if thinkingMode != .auto, let effort = thinkingMode.openAIEffort {
        body["reasoning"] = ["effort": effort]
    }
    if allowTools {
        body["tools"] = Self.functionTools
    }
    return body
}
```

In `send(...)`: replace the inline `userContent`/`messages` construction (excerpt in Current state) with `var messages = Self.initialMessages(systemPrompt: systemPrompt, prompt: prompt, images: images)`, and replace the inline `body` construction + reasoning + tools blocks inside the loop with `let body = Self.requestBody(model: model, messages: messages, thinkingMode: thinkingMode, allowTools: allowTools, sessionId: sessionIdAtStart)`. The loop's subsequent `messages.append(...)` calls for tool turns stay as they are. Preserve the existing explanatory comments by moving them onto the new helpers (as in the snippets above). Two deliberate behavior changes, both pinned by `testOpenRouterBodyHasSessionIdAndBoundedBreakpoints`: images no longer carry `cache_control`, and the body gains `session_id`.

**Verify**: build succeeds.

### Step 9: Run the full test suite

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` → `** TEST SUCCEEDED **`, with `AiPipelineTests` listed as executed (17 tests) and the four pre-existing test classes (PdfPersistenceTests, PageTextCacheTests, SelectableMessageTests, PaneTreeTests) all passing.

## Test plan

No new tests to write — this plan exists to make the committed spec suite (`Tests/AiPipelineTests.swift`, 17 test methods) compile and pass. The full-suite run in step 9 is the test plan.

## Done criteria

- [ ] `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` → BUILD SUCCEEDED
- [ ] `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` → TEST SUCCEEDED (all 5 test classes)
- [ ] `git diff --stat` touches only the six in-scope files
- [ ] `Tests/AiPipelineTests.swift` is unmodified (`git diff Tests/ | wc -l` → 0)
- [ ] `grep -n "geminiThinkingBudget" Vellum/` → no matches
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt doesn't match the live code (drift since `314cf9f`).
- A test in `AiPipelineTests` fails in a way that seems to require CHANGING the test — the tests are the spec; a conflict means the spec needs a maintainer decision.
- One of the four pre-existing test classes fails after your changes (you may have broken behavior they pin — report which assertion).
- The `"response.completed"` handling in `OpenAIClient.swift` doesn't match step 7's description (implement helpers only, note the skipped wiring, continue).
- `AiThinkingMode` lacks the cases (`.auto/.instant/.low/.medium/.high`) or `openAIEffort` property this plan assumes.

## Maintenance notes

- The prompt-duplication fix (step 2) and breakpoint capping (step 8) change what providers receive; watch cache-hit-ratio telemetry (`AiUsage.cacheHitRatio`) after landing — both changes should *improve* it.
- The OpenAI output budget rises from 2048 to 4096–32768 depending on thinking mode — visible cost increase for high-effort chats; it's the intended trade (2048 was truncating reasoning-model answers).
- `maxPageReadCharacters = 12_000` (~3k tokens) is a judgment call not pinned by tests (tests only require consistency with the constant); tune freely later.
- Plan 003 (cancellation-retry fix) touches `openStream` in these same two client files — land this plan first to avoid conflicts.
- Reviewer scrutiny: step 5's replay change is the riskiest (Gemini tool turns now replay thought/signature parts verbatim); manually exercise a Gemini tool-calling chat if a key is available.

---

## Addendum (2026-07-14, verified at commit `c874e13`) — one more compile blocker this plan must clear

Re-audit at `c874e13` confirmed all six in-scope files are byte-identical to `314cf9f` (no drift; the excerpts above remain exact), and a fresh `build-for-testing` run reproduced the same missing-symbol list — **plus one failure this plan did not originally account for**:

- `Tests/AiPipelineTests.swift:338` feeds a test fixture (`FixtureBytes`, a custom `AsyncSequence` of bytes) to `SSE.dataPayloads(...)`, but the live signature in `Vellum/Services/Ai/AiStreaming.swift:27-29` is hard-typed to the concrete network type:

```swift
enum SSE {
    static func dataPayloads(
        _ bytes: URLSession.AsyncBytes
    ) -> AsyncCompactMapSequence<AsyncLineSequence<URLSession.AsyncBytes>, String> {
```

  Compiler error: `cannot convert value of type 'FixtureBytes' to expected argument type 'URLSession.AsyncBytes'`. This contradicts the "Current state" line above claiming `AiStreaming.swift` "already satisfies its tests" — it does not; disregard that line.

**Additional step (do together with the other helper work; scope grows by one file — `Vellum/Services/Ai/AiStreaming.swift`):** widen `dataPayloads` to any async byte sequence, keeping the body unchanged:

```swift
static func dataPayloads<Bytes: AsyncSequence>(
    _ bytes: Bytes
) -> AsyncCompactMapSequence<AsyncLineSequence<Bytes>, String> where Bytes.Element == UInt8 {
```

`URLSession.AsyncBytes` satisfies `AsyncSequence where Element == UInt8`, and `.lines` is available on any such sequence via `AsyncLineSequence`, so all five provider clients compile unchanged — do not edit them for this. (If the compiler disagrees about `.lines` availability on the generic, STOP and report; do not restructure the providers.)

**Verify**: `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' build-for-testing` → `** TEST BUILD SUCCEEDED **` with `Tests/AiPipelineTests.swift` compiling; then the plan's existing step-9 full-suite gate.

**Done-criteria delta**: the "six in-scope files" bullet becomes seven (`+ Vellum/Services/Ai/AiStreaming.swift`); everything else stands.
