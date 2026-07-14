# Plan 005: Stop re-serializing every document's conversation on the main thread on every AI turn

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `advisor-plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 314cf9f..HEAD -- Vellum/Services/Ai/AiPersistence.swift Vellum/Stores/AiStore.swift Vellum/App/VellumApp.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: advisor-plans/001-land-ai-pipeline-helpers-fix-test-target.md (001 touches `AiPersistence.sanitizeMessage` and `AiStore`; land it first)
- **Category**: perf
- **Planned at**: commit `314cf9f`, 2026-07-12

## Why this matters

Every AI turn calls `AiPersistence.saveConversation` up to three times (before the request, on success, on error — `AiStore.swift:429,596,618`). Each call: reads the single UserDefaults JSON blob holding **all** documents' conversations, re-parses it with `JSONSerialization` plus a custom byte-level key-order scan (`topLevelObjectKeys`), sanitizes every message of every document, mutates one entry, then re-encodes and re-writes **everything** — synchronously, on the main actor (`AiStore` is `@MainActor` and none of `AiPersistence` is async). Bounds: up to 25 documents × 120 messages × 12,000 chars ≈ tens of MB of JSON parse+encode per turn in the worst case. Even moderate multi-document usage pays a full cross-document serialization cost per message, as UI-thread hitches unrelated to the conversation being updated.

The fix has two independent halves, both preserving the on-disk format (no migration):
1. **Cache the decoded entries in memory** — parse the blob once at first access, then mutate the cache; eliminates the per-save read+decode+sanitize entirely.
2. **Write behind** — encode and write the blob on a detached task, coalescing bursts, with a synchronous flush at quit (the app already has exactly this pattern and a quit hook for `PageTextPersister`).

## Current state

- `Vellum/Services/Ai/AiPersistence.swift` — an enum of static funcs. Key pieces:

```swift
static func loadConversation(for document: DocumentInfo?) -> [AiMessage] {
    guard let key = documentKey(document) else { return [] }
    return readConversations().first(where: { $0.key == key })?.messages ?? []
}

static func saveConversation(for document: DocumentInfo?, messages: [AiMessage]) {
    guard let key = documentKey(document) else { return }
    var entries = readConversations()                 // ← full blob parse, every save
    let bounded = limit(messages)
    if let index = entries.firstIndex(where: { $0.key == key }) {
        if bounded.isEmpty {
            entries.remove(at: index)
        } else {
            // Replacing a JS object property does not change insertion order.
            entries[index].messages = bounded
        }
    } else if !bounded.isEmpty {
        entries.append(ConversationEntry(key: key, messages: bounded))
    }
    if entries.count > maxDocuments {
        entries.removeFirst(entries.count - maxDocuments)
    }
    writeConversations(entries)                       // ← full blob encode+write, every save
}
```

- `readConversations()` (~line 157) parses the raw string with `JSONSerialization`, recovers key order via `topLevelObjectKeys` (a hand-rolled byte scanner), sanitizes and bounds every message list, caps at `maxDocuments`. `writeConversations(_:)` (~line 197) hand-assembles the JSON object string pair-by-pair to preserve insertion order (JS-compatible eviction order).
- Call sites (all `@MainActor`, all synchronous): `AiStore.swift:247, 258, 327, 429, 596, 618` (`saveConversation`) and `AiStore.swift:302` (`loadConversation`, via `loadConversationForDocument`, also called from `PaneView.swift:99`).
- The quit-flush convention already exists: `Vellum/App/VellumApp.swift:9` implements `applicationShouldTerminate` and at line 33 awaits `PageTextPersister.awaitInFlightFlushes()` before replying — follow that pattern.
- The file already uses `nonisolated(unsafe)` statics (e.g. `ISO8601DateFormatter.aiTimestamp`, line ~245); the project builds with `SWIFT_STRICT_CONCURRENCY: minimal`, so statics won't trip strict checking — but write the new state safely anyway (main-actor confinement, below) rather than adding another unsafe static.
- Crash-safety contract to preserve (documented at the `saveConversation(messagesWithUser)` call, `AiStore.swift:~420`): the user message is persisted *before* the request so a mid-stream crash leaves no empty assistant bubble but keeps the user's question. Write-behind coalescing must therefore still flush reasonably promptly (sub-second), and the quit path must flush synchronously.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build` | `** BUILD SUCCEEDED **` |
| Tests | `xcodebuild -project Vellum.xcodeproj -scheme Vellum -destination 'platform=macOS' test` | `** TEST SUCCEEDED **` |

## Scope

**In scope**:
- `Vellum/Services/Ai/AiPersistence.swift`
- `Vellum/App/VellumApp.swift` (quit hook: one added await, mirroring the `PageTextPersister` line)
- `Tests/AiPipelineTests.swift` (append tests only)

**Out of scope**:
- The on-disk format: the UserDefaults key, the order-preserving JSON object encoding, `limit()` bounds, `sanitizeMessage` semantics — all unchanged (no migration).
- `AiStore.swift` call sites — the public API of `AiPersistence` stays synchronous and identical, so no call-site changes should be needed. If you find yourself editing `AiStore`, stop (see STOP conditions).
- `PageTextPersister.swift` — reference only.
- `Vellum.xcodeproj/project.pbxproj` — never stage or commit.

## Git workflow

- Branch off `ai-ondemand-retrieval`: `advisor/005-conversation-write-behind`.
- Commit message: e.g. "Cache conversations in memory and write the blob behind a coalescing flush".
- Stage only your own files; never `*.pbxproj`.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a main-actor entries cache

In `AiPersistence`, add:

```swift
/// Decoded conversation entries, parsed from the UserDefaults blob once and
/// kept authoritative in memory afterwards. Confined to the main actor —
/// every caller (AiStore, PaneView) already is.
@MainActor private static var cachedEntries: [ConversationEntry]?

@MainActor private static func entries() -> [ConversationEntry] {
    if let cachedEntries { return cachedEntries }
    let loaded = readConversations()
    cachedEntries = loaded
    return loaded
}
```

Mark `loadConversation` and `saveConversation` `@MainActor` (their callers all are; if some caller isn't, the compiler will say so — that would be a STOP condition worth reporting). Replace their `readConversations()` calls with `entries()`, and in `saveConversation` write the mutated array back to `cachedEntries` before scheduling the flush (step 2).

If a `clearAllConversations`/settings-reset path exists in this file (search for other writers of the conversations key), it must also update `cachedEntries` — audit and handle.

**Verify**: build succeeds.

### Step 2: Write behind with coalescing, flush at quit

Replace the direct `writeConversations(entries)` call in `saveConversation` with a coalesced background flush, modeled on `PageTextPersister`'s flush/await pattern:

```swift
@MainActor private static var pendingFlush: Task<Void, Never>?

/// Encode + write off the main actor, coalescing bursts (a turn saves up to
/// three times). ConversationEntry is Codable value data, safe to move.
@MainActor private static func scheduleFlush() {
    guard pendingFlush == nil else { return }   // a scheduled flush will pick up the latest cache
    pendingFlush = Task { @MainActor in
        // Let same-turn saves coalesce, but stay well under a second so the
        // "user message persisted before the request" crash contract holds.
        try? await Task.sleep(for: .milliseconds(200))
        let snapshot = entries()
        await Task.detached(priority: .utility) {
            writeConversations(snapshot)
        }.value
        pendingFlush = nil
    }
}

/// Await any scheduled write — called from applicationShouldTerminate.
@MainActor static func awaitPendingFlush() async {
    while let flush = pendingFlush {
        await flush.value
    }
}
```

Notes for correctness:
- `pendingFlush = nil` is set AFTER the detached write completes, so `awaitPendingFlush` cannot return while a write is still in flight; a save arriving mid-write is coalesced into the next scheduled flush instead of racing the in-progress one. The `while` in `awaitPendingFlush` handles a flush scheduled while awaiting the previous one. (Note: the shipped implementation also serializes saves that arrive mid-flush rather than racing them, though it may do so via a different mechanism than the exact snippet above — check `AiPersistence.swift` for the current code.)
- `writeConversations` only touches `UserDefaults` (thread-safe) and `JSONEncoder` — if reading it reveals any other shared state, STOP.
- `ConversationEntry` must be `Sendable` (it's Codable structs of `String`/`[AiMessage]`, and `AiMessage` is `Sendable`); add the conformance if the compiler asks.

In `Vellum/App/VellumApp.swift`, inside `applicationShouldTerminate` next to the existing `await PageTextPersister.awaitInFlightFlushes()` (line ~33), add:

```swift
await AiPersistence.awaitPendingFlush()
```

**Verify**: build succeeds.

### Step 3: Tests

Append to `Tests/AiPipelineTests.swift` (it's `@MainActor`, matching the new annotations):

```swift
// MARK: - Conversation persistence write-behind

/// A save is visible to an immediate load (via the in-memory cache) even
/// before the coalesced disk flush has run.
func testSaveIsImmediatelyVisibleToLoad() {
    let document = DocumentInfo(/* construct the minimal DocumentInfo the way
        existing tests or previews do — check how documentKey() derives the
        key (likely the file path) and set that field */)
    let message = AiPersistence.makeMessage(role: .user, content: "hello persistence")
    AiPersistence.saveConversation(for: document, messages: [message])
    let loaded = AiPersistence.loadConversation(for: document)
    XCTAssertEqual(loaded.map(\.content), ["hello persistence"])
    // Cleanup so repeated test runs don't accumulate:
    AiPersistence.saveConversation(for: document, messages: [])
}

/// awaitPendingFlush drains the coalesced write.
func testAwaitPendingFlushCompletes() async {
    let document = DocumentInfo(/* as above, different path */)
    AiPersistence.saveConversation(
        for: document,
        messages: [AiPersistence.makeMessage(role: .user, content: "flush me")]
    )
    await AiPersistence.awaitPendingFlush()
    AiPersistence.saveConversation(for: document, messages: [])
    await AiPersistence.awaitPendingFlush()
}
```

Look at how `DocumentInfo` is constructed elsewhere in `Tests/` or `Vellum/` previews before writing these; if `documentKey` requires fields that make construction awkward in tests, adapt (the goal is: save→load round-trip through the cache, and a drainable flush). Beware: these tests write to the real `UserDefaults.standard` conversations key on the test host — the cleanup saves (`messages: []`) remove the entries (that's the documented `saveConversation` behavior for empty lists).

**Verify**: full suite → TEST SUCCEEDED including the two new tests.

### Step 4: Manual smoke (if you can run the app)

Open two PDFs, chat in both, quit the app, relaunch: both conversations restore. This exercises cache + flush + quit path end-to-end.

## Test plan

Covered in step 3: cache-visible save→load round-trip; flush drain. Existing behavior nets: `AiPipelineTests`' persistence-adjacent tests (message sanitize round-trips) and the manual restore smoke.

## Done criteria

- [ ] Build and full test suite pass
- [ ] `saveConversation` no longer calls `readConversations()` (grep: `readConversations` has exactly one caller — `entries()`)
- [ ] `writeConversations` is called only from the detached flush (grep confirms)
- [ ] `applicationShouldTerminate` awaits `AiPersistence.awaitPendingFlush()`
- [ ] `git diff --stat` touches only the three in-scope files
- [ ] `advisor-plans/README.md` status row updated

## STOP conditions

- The `AiPersistence` excerpts don't match the live code.
- Marking `loadConversation`/`saveConversation` `@MainActor` produces caller errors anywhere other than `AiStore`/`PaneView` — some caller runs off-main; report it (that caller was racing the old code too).
- `writeConversations` or `readConversations` touches shared mutable state beyond UserDefaults.
- You find yourself modifying `AiStore.swift` or changing the on-disk format.

## Maintenance notes

- The deeper fix — per-document storage files instead of one blob — was considered and deferred: it requires a migration and changes the JS-compatible eviction-order semantics (`topLevelObjectKeys`). If conversations grow past the current bounds, revisit.
- The 200ms coalesce window is a judgment call: long enough to merge a turn's 2–3 saves, short enough that the pre-request user-message save is on disk long before any plausible crash window. If crash reports ever show lost user messages, shrink it or flush the pre-request save eagerly.
- Reviewer scrutiny: the flush/reschedule race (save arriving mid-write) and the quit path (both `awaitInFlightFlushes` and `awaitPendingFlush` must complete before `.terminateNow`).
