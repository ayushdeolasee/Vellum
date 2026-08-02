# Packet 5 — AI delta (parity phase 5, issue #134)

Source of truth: macOS worktree `/Users/ayushdeolasee/Developer/Vellum/main`, range
`a42705d1~1..7742a895` (i.e. `5f4c3b07..7742a895` — `a42705d1~1` resolves to `5f4c3b07`).
Target: `/Users/ayushdeolasee/Developer/Vellum/ipad-app`, branch `ipad-app`.

To read any diff yourself:

```
git -C /Users/ayushdeolasee/Developer/Vellum/main diff 5f4c3b07..7742a895 -- <path>
```

To see exactly what is still missing on iPad for a given file (both worktrees share one
object DB, so refs resolve from either side):

```
git -C /Users/ayushdeolasee/Developer/Vellum/ipad-app diff HEAD 7742a895 -- <path>
```

**Important context discovered while writing this packet.** The iPad branch already
absorbed a chunk of this range during earlier phases (commits `3ec11e25`, `75ed4c01`,
`e8e80e61`). Specifically, `AiStore`/`AiPersistence`/`AiPrompts`/`ComposerReferences`
already contain: `VoiceMode`/`ttsEnabled` removal, the `AiReference.Kind.image` case,
`AiStore.maxImageReferences` + `canAttachMoreImages`, `AiPageImageSnapshot.pageNumber:
Int?`, `AiModelCatalog.supportsVision(provider:model:catalog:)`,
`AiStore.activeModelName` / `activeModelSupportsImages`, and a full UIKit/ImageIO
`aiImageSnapshot(from:maxSide:)`. Do **not** re-port those. Every instruction below is
written against the *current* iPad tree, not against main's pre-delta tree.

---

## 1. Delta files claimed

One line per file taken from `.claude/plans/parity-129/delta-files.txt`.

### Services / models

| File | Tag |
|---|---|
| `Vellum/Stores/AiStore.swift` | **[MERGE]** |
| `Vellum/Services/Ai/AiPersistence.swift` | **[MERGE]** |
| `Vellum/Services/Ai/AiPrompts.swift` | **[MERGE]** (one line) |
| `Vellum/Services/Ai/AiToolEngine.swift` | **[VERBATIM]** |
| `Vellum/Services/Ai/AiFileAttachment.swift` (A) | **[VERBATIM]** |
| `Vellum/Services/Ai/AiImageAttachment.swift` (A) | **[SKIP: iPad already ships a UIKit/ImageIO `aiImageSnapshot(from:maxSide:)` with identical signature, defaults, alpha→PNG / opaque→JPEG policy, 4 MB re-encode and `pageNumber: nil` output. Main's file is AppKit-only. No work.]** |
| `Vellum/Services/Ai/ChatGPTClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Ai/GeminiClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Ai/OpenAIClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Ai/OpenCodeZenClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Ai/OpenRouterClient.swift` | **[VERBATIM]** |
| `Vellum/Services/Ai/SpeechService.swift` (D) | **[SKIP: already deleted on iPad (commit `3ec11e25`); voice/TTS stays removed per standing decision.]** |
| `Vellum/Models/AiToolSummary.swift` (A) | **[VERBATIM]** |
| `Vellum/Resources/prompts/tool-mode-native.md` | **[VERBATIM]** |

### Views

| File | Tag |
|---|---|
| `Vellum/Views/AI/AiPanel.swift` | **[VERBATIM]** — macOS-gated dead reference file on iPad; copy main's content and re-apply the `#if os(macOS)` / `#endif` wrapper. |
| `Vellum/Platform/iOS/AiPanel_iOS.swift` (iPad-only counterpart; not in delta-files.txt) | **[REBUILD]** — this is where the real work is. **Packet 5 owns both `AiPanel.swift` and the structure of `AiPanel_iOS.swift`** (packet 10 §2.2). Packet 6 contributes only the clear-conversation / undo / redo slice, `[MERGE into AiPanel_iOS.swift, after packet 5]` — it must not restructure the file. |
| `Vellum/Views/AI/SentReferenceChips.swift` (A) | **[REBUILD]** (AppKit `NSImage`/`onHover`) |
| `Vellum/Views/AI/AttachmentDrop.swift` (A) | **[REBUILD]** (AppKit `NSDraggingInfo`/`NSPasteboard`) |
| `Vellum/Views/AI/AiToolSummaryView.swift` (A) | **[VERBATIM]** |
| `Vellum/Views/AI/AiToolSourceRow.swift` (A) | **[VERBATIM]** |
| `Vellum/Views/AI/ComposerReferences.swift` | **[MERGE]** |
| `Vellum/Views/AI/AiSettingsPanel.swift` | **[MERGE]** |
| `Vellum/Views/AI/RevealableSecureField.swift` | **[MERGE]** |
| `Vellum/Views/Settings/SettingsView.swift` | **[MERGE]** — AI tab + `AiConnectionValidator` only. |
| `Vellum/Views/AI/InlineMarkdown.swift` (A) | **[VERBATIM]** — folded in from the phantom "markdown/math/text-selection packet" (packet 10 §1.1/§3.2). Pure Foundation + `AttributedString`, zero AppKit. See §I.1. |
| `Vellum/Views/AI/MarkdownMessage.swift` | **[MERGE, list model change]** — folded in per packet 10 §1.1. `case unordered([String])`/`case ordered([String])` → `case list([MarkdownListItem])` + the nested-depth `MarkdownListItem` struct. Compile-breaking dependency for packet 9's `MarkdownParserTests` and packet 7's 11 `#127` cases. See §I.2. |
| `Vellum/Views/AI/SelectableMessageText.swift` | **[REBUILD into the existing UIKit rewrite]** — folded in per packet 10 §1.1. Port `AttachmentText`, `fittedAttachments(in:width:)`, `measureSize`, the `mathMaxWidth` plumbing and the new `attributedString(for:…)` signature into iPad's existing `import SwiftUI`/`import UIKit` file. Do **not** copy main's `NSTextView`/`NSDraggingInfo`/`NSTextAttachment` body. See §I.3. |
| `Vellum/Views/PDF/PdfOverlays.swift` | **[MERGE → `Vellum/Platform/iOS/RegionCaptureOverlay_iOS.swift`]** — folded in per packet 10 §1.1. The macOS file is `#if os(macOS)` and stays dead; the 2-line change is a call-site adaptation to this packet's own `PdfPageSnapshot.pageNumber: Int?` model change. See §I.4. |

### Tests

| File | Tag |
|---|---|
| `Tests/AiPipelineTests.swift` (M) | **[MERGE]** |
| `Tests/AiToolSummaryTests.swift` (A) | **[VERBATIM]** |
| `Tests/AiTranscriptFollowTests.swift` (A) | **[MERGE]** (retarget `AiPanel.*` → `AiPanel_iOS.*`) |
| `Tests/AiReferencePersistenceTests.swift` (A) | **[MERGE]** (needs `DocumentDataStore` from packet 1) |
| `Tests/AiConversationStoreTests.swift` (A) | **[MERGE]** (needs `DocumentDataStore` from packet 1) |
| `Tests/AttachmentDropTests.swift` (A) | **[REBUILD]** |
| `Tests/AiAddAsNoteTests.swift` (A) | **[MERGE]** (web half needs packet 4) |

### Claimed but explicitly not ported here

| File | Tag |
|---|---|
| `Vellum/Views/AI/MathRenderer.swift` | **[SKIP: packet 7 §2.5 owns the inline-code-immunity splitter change.]** |
| `Tests/AiMarkdownRenderingTests.swift`, `Tests/SelectableMessageTests.swift`, `Tests/MarkdownParserTests.swift` | **[SKIP as edits — packet 9 is the only packet that writes into `Tests/`.]** The *content* for `AiMarkdownRenderingTests` and `SelectableMessageTests` is specified by §I of this packet; packet 9 applies it, and must not start `AiMarkdownRenderingTests` until §I.1 (`InlineMarkdown.swift`) has landed. `MarkdownParserTests` content comes from §I.2 here plus packet 7 §4.2's 11 `#127` cases. |
| `Vellum/Services/Ai/PageTextCache.swift`, `PageTextExtractionGate.swift` (A), `PageTextPersister.swift` | **[SKIP: PDF page-text extraction / Live Text ANE serialization (#121). Lives in Services/Ai by directory only; belongs to packet 7.]** |
| `Tests/PageTextCacheTests.swift`, `Tests/PageTextExtractionGateTests.swift` | **[SKIP: packet 7.]** |
| `Vellum/Views/Shared/FloatingNotice.swift` (A), `SidebarDropCatcher.swift` (A), `Tests/SidebarDropRoutingTests.swift`, `Tests/ScratchpadDropRegistrationTests.swift` | **[SKIP — no owner needed.** `FloatingNotice.swift` is packet 8; the drag/drop harness files have **no owner by standing decision** (packet 10 §1.2): the iPad panel stack has no AppKit drag catcher, and the AI panel keeps its own `.onDrop` per the "iOS-native drop rebuild stays" decision that packets 4, 5 and 9 all agree on.**]** |
| `Vellum/Views/Settings/StorageSettingsTab.swift`, `StorageInventory.swift`, `StorageLocationChoiceSheet.swift`, `StorageRelocationInventoryReloadPolicy.swift`, `ConnectServiceSheet.swift`, `DisconnectServiceSheet.swift`, `IntegrationsSettingsTab.swift` | **[SKIP: packets 1 and 8. I only touch `SettingsView.swift`'s `AiSettingsTab`.]** |

---

## 2. Port order & instructions

Recommended order: **A → B → C → D → E → F → G → H → I**. A–C are self-contained and can
land immediately. D depends on packet 1. **§I** (markdown / math / text-selection, folded
in from the phantom packet per packet 10 §1.1/§3.2) lands after §F so the `AiPanel_iOS`
call sites exist, and must land before packet 9 writes `MarkdownParserTests` /
`AiMarkdownRenderingTests` / `SelectableMessageTests`.

---

### A. `Vellum/Resources/prompts/tool-mode-native.md` — [VERBATIM]

`cp main/Vellum/Resources/prompts/tool-mode-native.md → ipad-app/…` (same path).

What changed: the "Response" section is rewritten (report actions inline, not as a
trailing paragraph), a new **"Response Length (IMPORTANT)"** section caps replies at
~150 words with explicit anti-padding rules, and "Response Formatting" is softened from
"use Markdown to structure every reply" to "reach for Markdown when it earns its place"
(headings only for ≥2 real sections). No code depends on the text.

---

### B. Provider clients — [VERBATIM ×5]

The iPad copies of all five clients are **byte-identical to main's pre-delta versions**
(verified: `git -C ipad-app diff HEAD 7742a895 -- <file>` line counts match the main
delta exactly). All five are pure `Foundation`. Straight `cp`, no import or availability
changes.

```
cp main/Vellum/Services/Ai/OpenAIClient.swift      ipad-app/Vellum/Services/Ai/
cp main/Vellum/Services/Ai/ChatGPTClient.swift     ipad-app/Vellum/Services/Ai/
cp main/Vellum/Services/Ai/GeminiClient.swift      ipad-app/Vellum/Services/Ai/
cp main/Vellum/Services/Ai/OpenCodeZenClient.swift ipad-app/Vellum/Services/Ai/
cp main/Vellum/Services/Ai/OpenRouterClient.swift  ipad-app/Vellum/Services/Ai/
```

What you are getting (summarised so you can review the copy, and because §8 asserts on
it):

**`OpenAIClient.swift`** — the biggest one.
- New `struct StreamedTurn { text; calls; hitTokenLimit }` and
  `static func consumeTurn<Bytes: AsyncSequence>(_:provider:throwsOnUnexpectedIncomplete:onEvent:)`,
  a generic SSE consumer extracted from the old inline `for try await payload in
  SSE.dataPayloads(bytes)` loop. Generic over the byte source so tests can drive it from
  a fixture.
- The old duplicated `case "response.incomplete":` (the second arm was dead code) is
  merged into one: `max_output_tokens` sets `hitTokenLimit`; any other reason throws
  `incompleteMessage(reason:)` **only when `throwsOnUnexpectedIncomplete` is true** (the
  direct client passes `true`, ChatGPT/Codex passes `false`).
- New `enum TurnOutcome { case finish(reply:); case runTools([[String: Any]]) }` and
  `static func turnOutcome(_:provider:hasPriorActions:)` — the single gate between a
  streamed turn and the tool loop (#107/#118). Rules: no cutoff → run calls if any, else
  finish; cutoff with text → finish with `text + "\n\n_(reply truncated at the
  output-token limit)_"` and **drop the queued calls unrun**; cutoff with no text but
  prior actions → finish with `"_(stopped at the output-token limit before answering —
  try a lower thinking mode)_"` (keeps the earlier turns' `actionResults`); cutoff with
  no text and no prior actions → throw.
- `supportedReasoningEffort(model:requested:)` now takes `String?` (nil = Auto = omit the
  field) and is backed by a **positive** per-family table `supportedEfforts(model:)`
  plus a nearest-rung fallback over `effortLadder = ["none","minimal","low","medium",
  "high","xhigh"]` (ties resolve *downward*). New `isReasoningModel(_:)` covers gpt-5*
  and o1/o3/o4. Rows: o-series → low/medium/high (o1-mini → none); `*-pro` checked
  first (gpt-5-pro & gpt-5.1-pro → high; gpt-5.4-pro → medium/high/xhigh; unknown -pro →
  empty); gpt-5.5/5.4/5.2 → none/low/medium/high/xhigh; gpt-5.1 → none/low/medium/high;
  `*codex*` → low/medium/high; classic gpt-5/-mini/-nano → minimal/low/medium/high;
  anything else → `[]` (omit). This is the #94/#95 fix.
- `maxOutputTokens(forEffort:reasoning:)` now takes `String?` + a `reasoning` flag:
  non-reasoning → flat 4096; none/minimal → 4096; low → 8192; high → 32768; xhigh →
  65536; default (medium **and Auto**) → 16384.

**`ChatGPTClient.swift`** — the inline stream loop and its private request body are
replaced by calls to `OpenAIClient.consumeTurn(..., throwsOnUnexpectedIncomplete: false)`
and `OpenAIClient.turnOutcome(...)`, plus a new
`static func requestBody(model:systemPrompt:input:thinkingMode:sessionIdAtStart:)`.
The body now resolves effort through `OpenAIClient.supportedReasoningEffort` and sizes
`max_output_tokens` as `max(previousFlatOutputCap /* 8192 */,
OpenAIClient.maxOutputTokens(forEffort:reasoning:))` — floored so the fix can only raise
a budget.

**`GeminiClient.swift`** — the inline `generationConfig` construction moves into three
new statics: `requestBody(systemPrompt:contents:generationConfig:)`,
`generationConfig(for:model:)`, `resolvedThinkingConfig(for:model:)`. New
`unconfiguredThinking(model:)` describes what the *server* does when no thinkingConfig
is sent (gemini-3 flash-lite → minimal, gemini-3.5-flash → medium, other gemini-3 →
high, 2.5 → `thinkingBudget: -1`, 1.5/2.0/unknown → nil), and `maxOutputTokens(for:
model:)` reserves headroom for it — the #96 fix. `highThinkingReserve = 24576` named.
New `supportedThinkingLevels(model:)` + `resolvedThinkingLevel(model:requested:)` with
`thinkingLevelLadder = ["minimal","low","medium","high"]`, ties rounding **up** (opposite
of OpenAI, because Gemini has no "off" rung). Rows: `-image` → minimal/high;
3-flash / 3.1-flash / 3.5-flash → full ladder; gemini-3.1-pro → low/medium/high;
gemini-3-pro → low/high; other gemini-3 → low/high.

**`OpenCodeZenClient.swift`** — for `gpt*` models, `reasoning_effort` now goes through
`OpenAIClient.supportedReasoningEffort(model:requested:)` (omitted when it returns nil);
non-GPT families keep the `minimal → low` downgrade.

**`OpenRouterClient.swift`** — same, on the bare id behind the `openai/` prefix; other
vendors keep `minimal → low`.

---

### C. Tool summaries — [VERBATIM ×4]

```
cp main/Vellum/Models/AiToolSummary.swift        ipad-app/Vellum/Models/
cp main/Vellum/Views/AI/AiToolSummaryView.swift  ipad-app/Vellum/Views/AI/
cp main/Vellum/Views/AI/AiToolSourceRow.swift    ipad-app/Vellum/Views/AI/
cp main/Vellum/Services/Ai/AiToolEngine.swift    ipad-app/Vellum/Services/Ai/
cp main/Vellum/Services/Ai/AiFileAttachment.swift ipad-app/Vellum/Services/Ai/
```

- `AiToolSummary.swift` — `import Foundation` only. Defines
  `struct AiToolSummary: Codable, Equatable, Identifiable, Sendable` with
  `id/title/detail/sources/destinationPage` and nested `Source { id, page: Int?, excerpt }`,
  `static make(action:result:)`, `parseLegacyActions`, and an `extension AiMessage`
  giving `displayContent`, `displayToolSummaries` and `promptContent` (the legacy
  `"\n\nActions:\n"` receipt is parsed off the end of old assistant messages and
  upgraded at presentation time, without rewriting disk).
- `AiToolSummaryView.swift` / `AiToolSourceRow.swift` — plain SwiftUI (`DisclosureGroup`,
  `Label`, `Button(_:systemImage:)`, `.textSelection(.enabled)`, `Radius.md/.sm`). All
  available on iOS 26. No changes. **Hit-target note:** the "Page N" / "Jump to page N"
  buttons are `.buttonStyle(.plain)` with no explicit frame; if you want the repo's
  44pt-ish touch rule you may add `.frame(minHeight: 30).contentShape(Rectangle())`
  *inside* the label — but do it as a follow-up, not as part of the verbatim copy.
- `AiToolEngine.swift` — `displayActions` changes type from `[String]` to
  `[AiToolSummary]`; the `readSummary(_:)` helper is deleted and both read and write
  tools now append `AiToolSummary.make(action:result:)`. Pure Foundation; the iPad copy
  is identical pre-delta, so a straight `cp` is safe.
- `AiFileAttachment.swift` (new) — `Foundation` + `UniformTypeIdentifiers` only.
  `enum AiFileAttachment { case image(AiPageImageSnapshot, name: String); case
  rejected(name: String) }` and `func aiFileAttachment(from url: URL) -> AiFileAttachment?`
  (nil = folder/unreachable). Works unchanged on iOS **provided the caller holds
  security-scoped access around it** — see the `attachFiles` note in §D.

---

### D. `Vellum/Stores/AiStore.swift` — [MERGE]

**Depends on packet 1** for the `syncDocumentId` / `docId` hunk only (see D.16). Every
other hunk can land now.

Reference: `git -C main diff 5f4c3b07..7742a895 -- Vellum/Stores/AiStore.swift`.

**What the iPad file already has** (do not re-apply): `VoiceMode` removed;
`AiReference.Kind.image(image:name:)`; `AiPageImageSnapshot.pageNumber: Int?`;
`maxImageReferences = 8`; `canAttachMoreImages`; the image guard in `addReference`; the
three `AiModelCatalog.supportsVision(provider:model:catalog:)` call sites in
`sendMessage`. **The iPad file contains no iPad-only code** — the only divergence from
main's pre-delta version is the set above, all of which is a subset of this delta. So
this is a straightforward "apply the remaining hunks" merge.

Apply, in file order:

1. **Imports** — add `import UniformTypeIdentifiers` after `import Observation`.

2. **`AiMessage`** — add two stored properties after `usage`:
   ```swift
   var references: [AiReference] = []
   var toolSummaries: [AiToolSummary]? = nil
   private enum CodingKeys: String, CodingKey {
       case id, role, content, createdAt, usage, references, toolSummaries
   }
   ```
   **Byte-compat: these key names are the on-disk names. Do not rename.**
   Then add the `extension AiMessage { init(from decoder:) }` and the
   `private struct LossyAiReference: Decodable` exactly as in main (lines 56–100 of the
   diff). The hand-written init must stay in an *extension* so the memberwise
   initializer survives — several call sites build `AiMessage` field-by-field.

3. **`AiConversationClearTransaction`** — add the struct verbatim
   (`document: DocumentInfo`, `sessionId: String`, `removedMessages: [AiMessage]`).

4. **`AiReference`** — add `Codable` to the conformance list. Replace the `image`
   computed property's `default: return nil` with the exhaustive
   `case .selection, .highlight, .quote: return nil` (this is load-bearing: it is what
   makes a future image-carrying kind a compile error rather than a silent
   base64-to-disk leak). Add `text`, `page`, `strippingImageData`,
   `truncatingText(to:)` verbatim.

5. **`extension AiReference.Kind: Codable`** — add verbatim. **The `Tag` raw values
   (`selection`, `highlight`, `region`, `pageSnapshot`, `quote`, `image`) and the
   `CodingKeys` (`tag`, `text`, `page`, `image`, `messageId`, `name`) are the persisted
   format. Do not touch.**

6. **`AiPageImageSnapshot`** — add `Codable` conformance and
   `var strippingPixels: AiPageImageSnapshot` in the existing `extension
   AiPageImageSnapshot: Equatable` block.

7. **`AiSettings`** — add `func isConfigured(chatGPTSignedIn: Bool) -> Bool` and the
   private `hasValue(_:)` helper verbatim. (Consumed by the panel's "Configure AI"
   banner in §F.)

8. **`AiReferenceTarget`** — add the struct verbatim (`sessionId`, `kind`, `path`,
   `documentId`). `documentId` stays `String?` even before packet 1 lands; it will just
   always be nil until then.

9. **Attachment notice state** — add `private(set) var attachmentNotice: String?`,
   `@ObservationIgnored private var attachmentNoticeTask: Task<Void, Never>?`, and the
   `showAttachmentNotice(_:)` / `dismissAttachmentNotice()` pair verbatim (15 s window,
   re-show resets the timer). This mirrors the existing `ScratchpadStore.dropWarning` /
   `showWarning` in the iPad tree, so the two panels stay consistent.

10. **`composerFocusRequest`** — add `private(set) var composerFocusRequest: String?`
    and `func consumeComposerFocusRequest(_ request: String)`. Main's doc comment talks
    about an AppKit first-responder token; on iPad the consumer is a SwiftUI
    `@FocusState` in `AiPanel_iOS` (§F.12). **Keep the one-shot-token shape**: it is what
    `AiPipelineTests` asserts on, and the "counter replays after the panel is torn down
    and remounted" failure is just as real with `@FocusState`. Rewrite the comment's
    "AppKit composer / `updateNSView`" wording to "the SwiftUI composer / a late
    `onChange` from a torn-down panel"; keep the reasoning.

11. **Reference image cache** — add `referenceImageCache`,
    `referenceImageCacheOrder`, `static let maxCachedReferenceImages = 16`,
    `rememberReferenceImages(_:)` and `referencePreviewData(for:) -> Data?` verbatim.
    `referencePreviewData` deliberately returns `Data`, not an image type — that is what
    keeps it testable headlessly and platform-neutral, so **do not** change it to
    `UIImage`. The `UIImage(data:)` conversion happens in `SentReferenceChips` (§E).

12. **`addReference`** — add the `maxReferencesPerMessage` guard *above* the existing
    image guard, and add `composerFocusRequest = UUID().uuidString.lowercased()` as the
    last statement:
    ```swift
    if composerReferences.count >= AiPersistence.maxReferencesPerMessage {
        error = "You can attach at most "
            + "\(AiPersistence.maxReferencesPerMessage) references to one message."
        return
    }
    ```

13. **`currentReferenceTarget()` / `addCapturedReference(_:target:)`** — add verbatim.
    Before packet 1, `document.docId` does not exist; if you are landing this packet
    first, temporarily use `documentId: nil` and leave a `// TODO(packet-2): use
    document.docId` marker. Call sites: §F.11 (attach-current-page) and the iPad region
    capture path (`RegionCaptureOverlay_iOS` / wherever `beginRegionCapture(target: .ai)`
    delivers its bytes) — audit both.

14. **Attachment drops on the store** — add `handleDrop(_:)`, `attachFiles(at:)`,
    `static nameList(_:)`, `attachImage(data:name:)`, `attachIfCurrent(_:session:)`.
    **This is the panel-wide images-only policy and the mixed-drop notice copy; keep the
    strings byte-for-byte** — `AttachmentDropTests` pins them:
    - rejected non-images: `"Only image files can be attached. \(nameList(rejected)) \(verb) added."`
      with `verb = count == 1 ? "wasn't" : "weren't"`
    - folders/unreadable: `"Couldn't attach \(nameList(unreadable)). \(tail)"` with
      `tail = count == 1 ? "It's a folder or unreadable." : "They're folders or unreadable."`
    - `nameList`: `"photo.png"` or `"photo.png and 2 more"`
    - rejected takes precedence over unreadable.

    **iOS deviation — required.** Main's comment says "App sandbox is off (project.yml),
    so the URL needs no security-scoped bookmark". That is false on iOS: URLs from
    `.fileImporter` and from a Files drag are security-scoped. Change the detached
    classification block to:
    ```swift
    let results = await Task.detached(priority: .userInitiated) {
        urls.map { url -> (name: String, attachment: AiFileAttachment?) in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return (name: url.lastPathComponent, attachment: aiFileAttachment(from: url))
        }
    }.value
    ```
    and replace main's sandbox comment with an iOS one explaining the scope. Everything
    downstream (classification, notices, `attachIfCurrent`) is unchanged.

    This supersedes `AiPanel_iOS.attachImages(at:)`, which currently does the
    security-scoped read in the *view* and silently swallows non-images. Delete that
    method in §F and route `.fileImporter` through `aiStore.attachFiles(at:)`.

15. **`clearConversation`** — replace with main's `@discardableResult func
    clearConversation() -> AiConversationClearTransaction?`. Note the two behaviour
    changes: it now **no-ops when `messages.isEmpty` / no document / no active tab**, and
    it **no longer clears `composerReferences`** (attachments belong to the next message,
    not to the transcript being cleared). Then add `undoClear(_:)`, `redoClear(_:)`,
    `currentDocument(for:)`, `isShowing(_:document:)`, `isSameDocument(_:_:)` verbatim.
    `currentDocument(for:)` reads `app?.tabs.first(where: { $0.id == transaction.sessionId })?.document`
    — `AppStore.tabs: [PdfTab]` already exists on iPad.

16. **`sendMessage`** — five edits:
    - `var context = context` → `let context = context`.
    - Before `let userMessage`, insert `rememberReferenceImages(context.references)` with
      main's comment, and change the message construction to
      `AiPersistence.makeMessage(role: .user, content: trimmed,
      references: context.references.map(\.strippingImageData))`.
    - **[packet-2-gated]** After `error = nil`, insert the lazy `/VellumDocId` stamp
      block (`if documentAtStart.kind == .pdf, documentAtStart.docId?.isEmpty ?? true {
      await app.syncDocumentId(sessionId:) … }`) and
      `let documentForPersist = app.document ?? documentAtStart`.
      **If packet 1 has not landed**, write `let documentForPersist = documentAtStart`
      and leave a `// TODO(packet-2): stamp identity before the first persist` marker.
      The ordering requirement — stamp *after* the optimistic UI append but *before* the
      first `saveConversation` so every save this turn targets the stamped key — is the
      "stamp identity before first persist" item in this packet's brief; do not reorder it.
    - Replace all three `saveConversation(for: documentAtStart, …)` call sites with
      `documentForPersist`.
    - Success path: replace `composeAssistantContent` with
      ```swift
      var assistantMessage = AiPersistence.makeMessage(
          role: .assistant, content: Self.assistantAnswerText(reply: result.reply), id: assistantId)
      assistantMessage.toolSummaries = engine.displayActions.isEmpty
          ? nil : AiPersistence.sanitizeToolSummaries(engine.displayActions)
      let completed = AiPersistence.limitedMessages(messagesWithUser + [assistantMessage])
      ```

17. **`composeAssistantContent` → `assistantAnswerText`** — replace the function with
    main's `nonisolated static func assistantAnswerText(reply: String) -> String`
    (trim only). Grep the iPad tree for `composeAssistantContent` and fix every caller
    (`Tests/AiPipelineTests.swift` has one).

---

### E. `Vellum/Services/Ai/AiPersistence.swift` — [MERGE] — **blocked on packet 1**

Reference: `git -C main diff 5f4c3b07..7742a895 -- Vellum/Services/Ai/AiPersistence.swift`.

Main rewrote this file from "one path-keyed UserDefaults blob" to "one
`documents/<storageKey>/conversations.json` per document, fronted by a write-behind
cache". That retarget is packet 1's `DocumentDataStore` + `DocumentIdentity`. **Do not
attempt this file before those two types exist on iPad** — the iPad tree has no
`DocumentDataStore`, `DocumentIdentity`, `DocumentInfo.docId` at all today.

**What the iPad file has that main does not — MUST BE PRESERVED.** The iPad
`loadConversation(for:)` has an iPad-only recovery for the sandbox data-container UUID
changing across reinstall/OS update, which invalidates every absolute path key:

```swift
// An app reinstall or OS update changes the sandbox container UUID,
// invalidating absolute paths persisted by an earlier installation.
// Imported PDFs have unique filenames in Vellum's library, so recover
// the conversation by filename and migrate the entry to the current
// canonical path. Web document keys are URLs and must stay exact.
let filename = (key as NSString).lastPathComponent
guard document?.kind == .pdf,
      filename.lowercased().hasSuffix(".pdf"),
      let legacyIndex = loaded.firstIndex(where: {
          ($0.key as NSString).lastPathComponent == filename
      }) else { return [] }
```

It is covered by two iPad-only tests in `Tests/AiPipelineTests.swift`
(`testConversationSurvivesContainerPathChange`,
`testWebPdfUrlDoesNotMigrateLocalConversation`) — keep both (§H).

**Merge recipe.**

1. Take main's file wholesale as the base.
2. Re-home the container recovery into the **legacy-blob migration** step, which is where
   the path-keyed data now lives. In `migrateLegacyIfNeeded(document:key:)`, change the
   entry lookup from exact-match-only to exact-then-filename, PDF only:
   ```swift
   let legacyKey = document.pdfPath.trimmingCharacters(in: .whitespacesAndNewlines)
   guard !legacyKey.isEmpty else { return }
   var entries = readConversations()
   var index = entries.firstIndex(where: { $0.key == legacyKey })
   if index == nil, document.kind == .pdf {
       // iPad-only: a reinstall/OS update changes the data-container UUID, so
       // every absolute path key written by the previous installation is dead.
       // Imported PDFs have unique filenames in Vellum's library, so recover by
       // filename. Web keys are URLs and must stay exact — a web URL whose path
       // happens to end in .pdf must never claim a local PDF's conversation.
       let filename = (legacyKey as NSString).lastPathComponent
       if filename.lowercased().hasSuffix(".pdf") {
           index = entries.firstIndex {
               ($0.key as NSString).lastPathComponent == filename
           }
       }
   }
   guard let index else { return }
   ```
   The rest of `migrateLegacyIfNeeded` (encode → `DocumentDataStore.saveConversationsData`
   → remove the blob entry → `writeConversations`) is unchanged, so a recovered
   conversation is folded into the new folder under the *current* storage key on first
   load, which is exactly the old behaviour's effect.
3. **Also apply it to the folder layer**, because after the first migration the key is a
   sha256 of the (now-dead) absolute path. In `loadConversation(for:)`, after the
   `migrateLegacyIfNeeded` call and before `readConversationsFile`, if the document is a
   PDF with no `docId` and `DocumentDataStore.conversationsExist(forKey: key) == false`,
   ask packet 1's store for a folder whose stored `meta.json` records the same filename
   and `DocumentDataStore.rekey(from:to:)` it across. **Coordinate this with packet 1** —
   if `meta.json` already records a filename/title, this is a five-line lookup; if not,
   raise it with the packet-2 owner rather than inventing a parallel index here. If
   packet 1 lands `/VellumDocId` stamping (it does), stamped PDFs are immune to this
   problem entirely and only unstamped/read-only PDFs need the fallback.
4. Everything else is main verbatim, and it is the part this packet is actually
   responsible for:
   - New caps: `maxReferenceCharacters = 4_000`, `maxReferencesPerMessage = 16`,
     `maxToolSummariesPerMessage = 24`, `maxToolSourcesPerSummary = 8`,
     `maxToolSummaryTitleCharacters = 240`, `maxToolSummaryDetailCharacters = 160`,
     `maxToolSourceExcerptCharacters = 280`, `maxToolIdentifierCharacters = 128`,
     `maxToolPageNumber = 1_000_000`. `maxDocuments` is **deleted**.
   - `limit(_:)` renamed to `static func limitedMessages(_:)` (now internal — `AiStore`
     and `VellumBundle` call it). It additionally applies `capReferences` and
     `sanitizeToolSummaries`.
   - New `static func capReferences(_:)` — `prefix(maxReferencesPerMessage)` then
     `truncatingText(to: maxReferenceCharacters).strippingImageData` per element. Keeps
     the **first** N (a message's attachment list in build order), unlike messages which
     keep the last N.
   - New `static func sanitizeToolSummaries(_:)` + `uniqueIdentifier`, `bounded`,
     `boundedPage` helpers.
   - New `static func decodeMessages(_ data: Data) -> (messages: [AiMessage], dropped: Int)?`
     — **the per-message lossy decode**. Returns nil when the top level isn't an array of
     objects, or when it held records and not one decoded. A payload that legitimately
     stores `[]` comes back non-nil and empty.
   - New `private struct LossyAiMessage: Decodable` at file scope (bottom of the file).
   - New `private enum ConversationRead { case messages([AiMessage]); case undecodable }`
     and `readConversationsFile(forKey:)`. **A file that exists but wouldn't open counts
     as `.undecodable`, not as an absent chat.**
   - New `@MainActor private static var undecodableKeys: Set<String>` — **the
     "undecodable file is never overwritten" guard (#90)**. `saveConversation` returns
     early (no cache write, no dirty flag) when `limited.isEmpty &&
     undecodableKeys.contains(key)`, logging
     `"[Vellum] Skipping empty AI conversation write for \(key): its stored chat could not be decoded, so the file is left on disk"`.
     Cleared on a successful read, on `invalidateCachedConversation(forKey:)`, and moved
     with the key in `migrateCachedConversation(from:to:)` (note the else-branch: when
     the source had no verdict, any verdict on the *destination* is dropped).
   - `makeMessage` gains `references: [AiReference] = []`.
   - `readConversations()` no longer caps at `maxDocuments` (lazy migration must be able
     to find any document).
   - The `sanitizeMessage` legacy-blob reader deliberately does **not** look for
     `references`.
   - `awaitPendingFlush()` gains a second drain for keys parked by
     `maxFlushFailureRetries`.
5. **Already applied on iPad, keep as-is:** the `voiceMode`/`ttsEnabled` reads are
   already gone from `decodeSettings`. Do not reintroduce them (main deletes them in the
   same hunk).

**Byte-compat checklist for this file:** `settingsKey = "research-reader-ai-settings-v1"`,
`conversationsKey = "research-reader-ai-conversations-v1"`, `conversations.json` is a
plain top-level JSON *array* of `AiMessage` encoded with `JSONEncoder()` defaults
(camelCase keys, no date strategy — `createdAt` is a pre-formatted ISO8601 `String`).
Reference tags as listed in D.5.

---

### F. `Vellum/Platform/iOS/AiPanel_iOS.swift` — [REBUILD] (+ `Vellum/Views/AI/AiPanel.swift` [VERBATIM])

**`Vellum/Views/AI/AiPanel.swift`** first, and trivially: the iPad copy is main's *old*
panel wrapped in `#if os(macOS)` … `#endif` as a dead reference (it still mentions
`SpeechService`, `VoiceMode`, `ttsEnabled`, none of which exist on iPad — it only
compiles because it's gated out). Replace its contents with main's current
`Vellum/Views/AI/AiPanel.swift` and re-add the wrapper:

```swift
#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers
… main's file …
#endif  // os(macOS) — iPad reference; see Platform/iOS/AiPanel_iOS.swift
```

Also update the trailing comment to point at `AiPanel_iOS.swift`.

---

Now the real work. `AiPanel_iOS.swift` today (657 lines) is a touch-first port of main's
*pre-delta* panel. It already has: streaming, the activity pill + `AnimatedDots`,
`SelectableMessageText` with Quote, composer reference chips, image attachment via
`.onDrop` / PhotosPicker / `.fileImporter`, the per-message usage line, `strandedImagesNotice`,
`canSend` (references-only send with the "Help me with the attached reference." default),
`registerSendTask`, the `shouldAutoAttachPageImage` + `ensureExtracted` pre-flight, and
`touchIconButton` 36pt targets.

**Preserve all of the above.** Add the following, in this order.

**F.1 — Configure-AI banner.** Add after `header`, replacing nothing:
```swift
if !aiStore.settings.isConfigured(chatGPTSignedIn: workspace.chatgptAuth.isSignedIn) {
    configureAiBanner
}
```
`@Environment(WorkspaceStore.self) private var workspace` — `WorkspaceStore.chatgptAuth`
already exists on iPad (`Vellum/Stores/WorkspaceStore.swift:37`). Main's banner button
calls `openSettings()` (a macOS-only environment action) after setting
`workspace.settingsSection = .ai`. **iOS rebuild:** `WorkspaceStore.settingsSection` does
not exist on iPad and belongs to packet 3; make the button set the panel's existing
`settingsOpen = true` instead, so the inline `AiSettingsPanel` reveals. Keep the copy
("Configure AI to start chatting." / "Configure AI in Settings") and the
`accessibilityIdentifier("aiPanel.configureAi")`. Style: `palette.surfaceMuted`
background with a bottom `Divider()` (both exist on iPad).

**F.2 — Clear button + undo/redo.** Change the trash `touchIconButton` to be disabled
when `aiStore.messages.isEmpty`, relabel it "Clear AI conversation", and route it
through:
```swift
@Environment(\.undoManager) private var undoManager

private func clearConversation() {
    guard let transaction = aiStore.clearConversation() else { return }
    guard let undoManager else { return }
    registerConversationUndo(transaction, store: aiStore, undoManager: undoManager)
}
```
Copy main's two file-scope `@MainActor private func registerConversationUndo/Redo`
helpers verbatim from the bottom of `AiPanel.swift` into `AiPanel_iOS.swift` — they are
pure `UndoManager` and work on iOS. Action name: `"Clear AI Conversation"`.

**F.3 — Transcript width tracking + bubble scaling (PR #64).** Add:
```swift
@State private var transcriptWidth: CGFloat = 0
private let transcriptPadding: CGFloat = 12

private func bubbleMaxWidth(for role: AiRole) -> CGFloat {
    Self.bubbleMaxWidth(for: role, contentWidth: transcriptWidth - transcriptPadding * 2)
}

static func bubbleMaxWidth(for role: AiRole, contentWidth: CGFloat) -> CGFloat {
    let column = contentWidth.isFinite && contentWidth > 0 ? max(contentWidth, 160) : 272
    guard role == .user else { return column }
    return max(column * 0.82, min(column, 200))
}
```
and on the `ScrollView`:
`.onGeometryChange(for: CGFloat.self) { $0.size.width } action: { transcriptWidth = $0 }`.
Replace `messageBubble`'s hard-coded `.frame(maxWidth: 300, alignment: .leading)` with
main's `BubbleWidthCap(maxWidth: textWidth) { … }`, where
`let bubbleWidth = bubbleMaxWidth(for: message.role)` and
`let textWidth = max(bubbleWidth - 24, 80)`.
Copy `struct BubbleWidthCap: Layout` verbatim (pure SwiftUI `Layout`; put it in
`AiPanel_iOS.swift`, or in a new `Vellum/Views/AI/BubbleWidthCap.swift` if the markdown
packet also wants it — coordinate). Keep it **internal, not `private`**, so tests can
measure it. `.frame(maxWidth:)` cannot substitute: a flexible frame takes the whole
clamped proposal, which paints every message across the full column.

**F.4 — Stick-to-bottom scroll follow (PR #69 / issue #57).** Copy verbatim from main's
`AiPanel`, retargeted onto `AiPanel_iOS`:
- `static let bottomSlack: CGFloat = 24`
- `struct ScrollMetrics: Equatable { offsetY; contentHeight; viewportHeight;
  var distanceFromBottom: CGFloat { max(0, contentHeight - viewportHeight - offsetY) } }`
- `static func follows(was:from:to:) -> Bool` — **copy the body and the whole doc comment
  exactly**; the three-cases reasoning (content grew / viewport shrank / reader scrolled)
  is the spec and `AiTranscriptFollowTests` tests it directly.
- `@State private var followsTail = true`
- `.onScrollGeometryChange(for: ScrollMetrics.self) { … } action: { old, new in … }`
  including the viewport-shrank-under-a-followed-transcript catch-up `scrollToBottom`.
- Replace every existing `scrollToBottom(proxy)` call in `.onChange` with
  `followTail(proxy)`; add the `aiStore.messages.isEmpty → followsTail = true` re-arm in
  the message-count handler; add a new
  `.onChange(of: appStore.activeTabId) { _, _ in followsTail = true; followTail(proxy) }`.
- `private func followTail(_ proxy:) { guard followsTail else { return }; scrollToBottom(proxy) }`
- Set `followsTail = true` at the top of `submit()`.
- Jump-to-latest pill (`showsJumpToLatest = !followsTail && !aiStore.messages.isEmpty`),
  `accessibilityIdentifier("aiPanel.jumpToLatest")`. iOS deviation: drop `.help(...)` (or
  keep — it is a no-op) and give the button a ≥36pt tappable height.

`onScrollGeometryChange` and `onGeometryChange` are both available on iOS 18+/26, so no
availability gating is needed at the iOS 26 deployment target.

**F.5 — Floating overlays (jump pill + attachment notice).** Add main's
`.overlay(alignment: .bottom) { VStack(spacing: 8) { jump pill; attachment notice } .padding(12) }`
on the `ScrollViewReader`, with the two `.animation(.easeInOut(duration: 0.2), value:)`
modifiers. **Both must float over the transcript, not push it** — an inline banner would
move the composer and (via F.4) unstick a reader who never scrolled.
Port `attachmentNoticeBanner(_:)` with an iOS rebuild: replace `IconButton(help:action:)`
with the panel's `touchIconButton`-style dismiss (frame + `contentShape` **inside** the
label), keep `.regularMaterial` + `Radius.md` + `palette.destructive.opacity(0.35)`
stroke, keep `accessibilityIdentifier("aiPanel.attachmentNotice")` and
`"aiPanel.attachmentNotice.dismiss"`, keep `.fixedSize(horizontal: false, vertical: true)`
so multi-line notices wrap.

**F.6 — Sent-reference chips.** In `messageRow`, between the role label and
`messageBubble(message)`:
```swift
if !message.references.isEmpty {
    SentReferenceChips(
        references: message.references,
        onGoToPage: { appStore.goToPage($0) },
        previewData: { aiStore.referencePreviewData(for: $0) },
        maxWidth: bubbleMaxWidth(for: message.role)
    )
}
```
Above the bubble, not inside it — the referenced text is not part of the message body.

**F.7 — Tool-summary trace.** In `messageRow`, in the assistant branch, before
`messageActions(message)`:
```swift
let summaries = message.displayToolSummaries
if summaries.isEmpty == false { toolSummaries(summaries) }
```
Port main's `toolSummaries(_:)` verbatim ("Sources & actions" caption + `ForEach` of
`AiToolSummaryView(summary:onJumpToPage: appStore.goToPage)`), **not** wrapped in
`BubbleWidthCap` — it is a sibling of the bubble and wants the whole column.

**F.8 — `displayContent` everywhere the answer is consumed.** In `messageBubble`, pass
`message.displayContent` to `SelectableMessageText` (not `message.content`). In
`messageActions`, all three actions take `message.displayContent`:
`UIPasteboard.general.string = message.displayContent`, the Quote reference text, and
`appStore.beginNoteWithContent(message.displayContent)`. Relabel Copy → "Copy answer".
This is what stops a legacy `"Actions:"` receipt from being copied into the clipboard or
onto a page note.

**F.9 — Attachment drops through the store.** Replace `handleImageDrop(_:)`'s
attach-directly logic with payload classification + `aiStore.handleDrop(_:)`, so mixed
drops get the images-only / folder notices (§D.14). Concretely:
- keep the SwiftUI `.onDrop` on the panel root and on the composer `TextField` (the
  iPad's "drop anywhere" rebuild — keep both registrations),
- **remove the `aiStore.activeModelSupportsImages` gate on the accepted types.** Main no
  longer gates the drop; a stranded image is explained by `strandedImagesNotice` instead.
  Register `[.image, .fileURL]` unconditionally so a non-image drop produces a notice
  rather than silently springing back,
- classify providers via the new `AttachmentDrop` helper (§G) and call
  `aiStore.handleDrop(payload)` per payload,
- keep `dropTargeted` and the dashed outline overlay,
- keep the `SelectableMessageText.onImageDrop` forwarding (the transcript's `UITextView`
  eats drops over itself) but point it at the same handler; **rename it to
  `onAttachmentDrop` only if the packet 5 renames it** — see §5.
- **Delete** `attachImages(at:)` from the view; route `.fileImporter` to
  `aiStore.attachFiles(at: urls)`.
- Keep `attachPhotoItems(_:)` in the view (PhotosPicker gives `Data`, not a URL) but
  change its landing call to `aiStore.attachImage(data: data, name: "Photo \(index + 1)")`
  so the session preview cache and the image cap are applied in one place.
- Keep `attachIfCurrent` only if still needed after the above; otherwise delete it (the
  store now owns that guard).

**F.10 — Attach menu.** Keep the iPad's Photos + Files entries. Two changes from main:
gate the two document entries on `appStore.document != nil` (already done on iPad ✓) and
change `.disabled(appStore.document == nil && !aiStore.activeModelSupportsImages)` —
already done ✓. Nothing else. Do **not** replace the two-source iPad menu with main's
single "Attach image…" `fileImporter` entry; the Photos entry is an iPad-only affordance
worth keeping.

**F.11 — Tab-safe page capture.** Replace `attachCurrentPage()`'s
`guard appStore.activeTabId == sessionId` with main's target pinning:
```swift
guard let target = aiStore.currentReferenceTarget(),
      let capturePage = aiStore.capturePageImageHandler else { return }
Task {
    guard let image = await capturePage(page) else { return }
    aiStore.addCapturedReference(
        AiReference(kind: .pageSnapshot(image: image, page: page)), target: target)
}
```
Audit the iPad region-capture path (`appStore.beginRegionCapture(target: .ai)` →
`RegionCaptureOverlay_iOS`) and route its `.region(...)` reference through
`addCapturedReference` with a target captured *before* the await, for the same reason.

**F.12 — Composer focus request.** Add `@FocusState private var composerFocused: Bool`,
`.focused($composerFocused)` on the `TextField`, and:
```swift
.onChange(of: aiStore.composerFocusRequest) { _, request in
    guard let request else { return }
    composerFocused = true
    aiStore.consumeComposerFocusRequest(request)
}
```
Attaching context is always the prelude to typing about it; without this, an
"Add to AI Chat" action on iPad leaves the keyboard down.

**Things NOT to port from main's panel:** the `isVisibleTab` drop-registration gate (that
exists because AppKit routes drags to hidden `NSTextView`s; SwiftUI `.onDrop` on a hidden
panel does not have that problem), `ComposerTextView`/`ComposerTextViewRep`/
`SubmitTextView`/`ComposerDropScrollView` (all `NSViewRepresentable` — the iPad composer
is a native `TextField(axis: .vertical)` and stays that way), `openSettings()`, and
`registerForDraggedTypes`.

---

### G. `Vellum/Views/AI/AttachmentDrop.swift` — [REBUILD]

Main's file is `import AppKit` + `NSPasteboard`/`NSDraggingInfo`. Rebuild for iOS,
keeping the two pieces that are platform-neutral.

**Keep verbatim:**
```swift
enum AttachmentDropPayload {
    case files([URL])
    case imageData(Data, name: String)
}

func fileURL(fromDropItem item: NSSecureCoding?) -> URL? {
    switch item {
    case let url as URL: url
    case let url as NSURL: url as URL
    case let data as Data: URL(dataRepresentation: data, relativeTo: nil)
    default: nil
    }
}
```
`fileURL(fromDropItem:)` currently lives at the bottom of `AiPanel_iOS.swift` and is
byte-identical to main's — **move it here and delete it from the panel** so both files
have one home.

**Replace the AppKit `enum AttachmentDrop`** with an `NSItemProvider` classifier:

```swift
import Foundation
import UniformTypeIdentifiers

enum AttachmentDrop {
    /// What the panel registers with SwiftUI's `.onDrop(of:)`. Files hands over a
    /// file URL and NOT an image, so `.image` alone never matches it; Photos and
    /// browsers hand over the bytes, which `.image` matches.
    static let draggedTypes: [UTType] = [.image, .fileURL]

    /// True when this provider carries something we can classify. Cheap — never
    /// touches the file.
    static func carriesAttachment(_ provider: NSItemProvider) -> Bool {
        provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            || provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
    }

    /// Resolve one provider into a payload. File URLs are only *named* here — the
    /// bytes are read, classified and decoded off the main actor by
    /// `AiStore.attachFiles(at:)`, so a 60 MB TIFF or an iCloud Drive file never
    /// stalls the drop.
    static func payload(for provider: NSItemProvider) async -> AttachmentDropPayload? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let item = try? await provider.loadItem(
                forTypeIdentifier: UTType.fileURL.identifier)
            guard let url = fileURL(fromDropItem: item as? NSSecureCoding) else { return nil }
            return .files([url])
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            let name = provider.suggestedName ?? "Dropped image"
            guard let data = try? await provider.loadDataRepresentation(
                for: .image) else { return nil }
            return .imageData(data, name: name)
        }
        return nil
    }
}
```

Notes for the implementer:
- `NSItemProvider.loadItem(forTypeIdentifier:options:)` has an async overload; if the
  concurrency checker objects, keep the completion-handler form and wrap it in
  `withCheckedContinuation`, matching the existing shape in `AiPanel_iOS.handleImageDrop`.
- **Batch the whole gesture**: the panel should collect `[AttachmentDropPayload]` across
  all providers and coalesce the `.files` cases into a single
  `aiStore.handleDrop(.files(allURLs))` call, so a mixed drop of three PDFs and one PNG
  produces **one** notice naming the three, not three notices. This matches main, where
  `NSPasteboard.readObjects` returns all URLs in one payload. This is the single most
  important behavioural detail of the rebuild.
- `.onDrop(of:isTargeted:perform:)` must return `true` synchronously when it accepted the
  gesture, so kick the async classification off in a `Task` and return
  `providers.contains(where: AttachmentDrop.carriesAttachment)`.

---

### H. Views: chips, composer chips, settings

**H.1 `Vellum/Views/AI/SentReferenceChips.swift` — [REBUILD]** (new file on iPad).

Copy main's 411-line file, then:
- `import SwiftUI` only (main has no AppKit import; it uses `NSImage` via the ambient
  AppKit re-export). Add `import UIKit`.
- **Keep the `extension AiReference` (chipIcon / chipLabel / chipKindName /
  `static collapse(_:)`) verbatim** — it is the shared vocabulary and `ComposerReferences`
  is about to depend on it (H.2).
- `SentReferenceChips` — verbatim.
- `SentReferenceChip` — remove `@State private var hovering` and `.onHover { hovering = $0 }`;
  replace the hover-varying background with the resting
  `.quaternary.opacity(0.35)`. `.help(...)` is a no-op on iOS; keep or drop, your call.
  Change `preview: previewData(reference).flatMap(NSImage.init(data:))` to
  `.flatMap(UIImage.init(data:))`. Add `.presentationCompactAdaptation(.popover)` to the
  `.popover` so it stays a popover in a compact split-view width instead of becoming a
  sheet. Bump the chip's vertical padding so the tap target is ≥30pt tall (main's 3pt
  vertical padding around 10pt text is a mouse target, not a finger one) — keep the
  visual size by adding the extra height as `.contentShape` padding if you want the
  original look.
- `SentReferenceDetail` — `let preview: UIImage?`, `Image(uiImage: preview)`. Everything
  else (excerpt `ScrollView` capped at 220pt, `.textSelection(.enabled)`, the
  "Preview unavailable — images aren't kept once the app restarts." branch, the
  `imageDescriptor`, `Go to page N`, `.frame(width: 300)`) is verbatim. Keep the
  accessibility identifiers: `aiMessage.references`, `aiMessage.reference`,
  `aiMessage.reference.goToPage`, `aiMessage.reference.preview`,
  `aiMessage.reference.previewUnavailable`.
- `ChipFlowLayout` — verbatim (pure `Layout`).
- `#Preview` — change `AiPanel.bubbleMaxWidth(...)` to `AiPanel_iOS.bubbleMaxWidth(...)`
  (twice), or delete the preview.

**H.2 `Vellum/Views/AI/ComposerReferences.swift` — [MERGE]**

The iPad file is already UIKit (`Image(uiImage:)`, `UIImage(data:)`, no `.onHover`, 18pt
× button) and already handles the `.image` kind in its private `icon`/`label`. Main's
delta **deletes** that private `icon`/`label`/`collapse` trio and switches the chip to
`reference.chipIcon` / `reference.chipLabel` from `SentReferenceChips.swift`.

Apply exactly that:
- `Text(label)` → `Text(reference.chipLabel)`
- `Image(systemName: icon)` → `Image(systemName: reference.chipIcon)`
- delete the private `icon`, `label` and `collapse(_:)` members
- add main's header comment pointing at `SentReferenceChips`
- **keep every iPad-only change**: `import UIKit`, no `hovering` state, the 18pt
  `.frame` + `.contentShape(Circle())` on the remove button, and the `UIImage` decode.

The labels are already identical strings, so this is a pure de-duplication.

**H.3 `Vellum/Views/AI/AiSettingsPanel.swift` — [MERGE]**

Main **deletes** `struct AiSettingsPanel` outright (AI settings moved to the Settings
window). **The iPad keeps it** — `AiPanel_iOS` reveals it inline via `settingsOpen`, which
is the iPad's only in-context path to the model picker, and F.1's banner button depends
on it. So:

- **Keep** `struct AiSettingsPanel` as it is on iPad today (`onStopRecognition` and the
  Voice/TTS rows are already gone ✓).
- **Keep** `AiModelSelectorField`, `AiCapabilityWarning`, `AiProviderOption`,
  `ChatGPTSignInControl` — main only narrows their doc comments from "shared by both
  hosts" to "used by global Settings". Take main's *code* where it differs, but restore
  the "shared by both AI settings hosts" wording, because on iPad it is still true.
- **Already present on iPad, do not re-apply:** `AiModelCatalog.supportsVision(provider:
  model:catalog:)`, `AiStore.activeModelName`, `AiStore.activeModelSupportsImages`, and
  the removal of `voiceBinding`/`ttsBinding`.
- Net remaining work on this file: **essentially none**. Verify with
  `git -C ipad-app diff HEAD 7742a895 -- Vellum/Views/AI/AiSettingsPanel.swift` and
  confirm every remaining hunk is either the `AiSettingsPanel` deletion (skip) or a
  doc-comment narrowing (skip). Note the deviation in the PR description.

**H.4 `Vellum/Views/AI/RevealableSecureField.swift` — [MERGE]**

iPad's version is a UIKit rebuild (`SecureTextFieldRep` over one `UITextField` whose
`isSecureTextEntry` flips). Main's delta (PR #84) adds accessibility plumbing. Port the
API surface only:

```swift
struct RevealableSecureField: View {
    let accessibilityLabel: String        // NEW — first parameter, no default
    let placeholder: String
    var credentialName = "API key"        // NEW
    @Binding var text: String
```
- eye button: `.accessibilityLabel(isRevealed ? "Hide \(credentialName)" : "Show \(credentialName)")`
- add `.accessibilityElement(children: .contain)` on the outer `HStack`
- pass `accessibilityLabel` through to the `SecureTextFieldRep` and set it on the
  `UITextField` (`field.accessibilityLabel = accessibilityLabel` in both `makeUIView`
  and `updateUIView`) — the iOS equivalent of main's `field.setAccessibilityLabel(...)`.
- **Do not** port the AppKit `NoAutofillTextField`/`NoAutofillSecureTextField` classes or
  the `.id(isRevealed)` rebuild dance; the iPad's single-field design has neither the
  autofill crash nor the caret-loss problem those exist for. Keep the iPad's per-instance
  `isRevealed` + `.id(provider)` call-site contract.
- Update both existing call sites (`AiSettingsPanel`, `SettingsView.AiSettingsTab`) to
  pass `accessibilityLabel: aiStore.keyFieldLabel`.

**H.5 `Vellum/Views/Settings/SettingsView.swift` — [MERGE, AI tab only]**

I claim only `AiSettingsTab` and the two new top-level types. Everything else in this
file (the `TabView` restructure to `$workspace.settingsSection`, the extracted
`StorageSettingsTab`/`IntegrationsSettingsTab`) belongs to packets 3, 1 and 8 — **do not
touch it here, and expect a conflict if you edit the same file concurrently.**

From `git -C main show 7f1dd572 -- Vellum/Views/Settings/SettingsView.swift`:

1. Append at file scope, verbatim (pure Foundation + URLSession):
   ```swift
   enum AiConnectionValidationState: Equatable { case idle, checking, valid, invalid(String) }
   enum AiConnectionValidator {
       static func request(settings: AiSettings) -> URLRequest?
       static func validate(settings:chatGPTSignedIn:session:) async -> AiConnectionValidationState
   }
   ```
   Endpoints: Gemini `…/v1beta/models?pageSize=1` with `x-goog-api-key`; OpenAI
   `https://api.openai.com/v1/models`; OpenRouter `https://openrouter.ai/api/v1/auth/key`;
   OpenCode `https://opencode.ai/zen/v1/models`; OpenCode-Go `https://opencode.ai/zen/go/v1/models`;
   all `Bearer`, 15 s timeout; ChatGPT returns nil (handled by the signed-in short-circuit).
   Status mapping: 2xx → valid; 401/403 → "Credential was rejected"; 429 → "Provider is
   reachable but rate limited"; else → "Provider returned HTTP \(code)"; throw →
   "Couldn't reach the provider" (note the curly apostrophe — the test pins the string).
   The injectable `session:` parameter is what `StorageManagementTests` uses; keep it.

2. In the iPad's `AiSettingsTab` (line 205), add
   `@Environment(ChatGPTAuth.self) private var chatGPTAuth` and
   `@State private var validationState: AiConnectionValidationState = .idle`; add the
   `LabeledContent("Configuration") { Text(configurationSummary) … }` row
   (`accessibilityIdentifier("ai.configurationSummary")`), the
   `Button("Validate Connection")` + `validationLabel` row
   (`accessibilityIdentifier("ai.validateConnection")`), the four
   `.onChange(…) { validationState = .idle }` resets, and `canValidate` /
   `configurationSummary` / `validationLabel` verbatim. Keep the stale-result guard
   inside the `Task` (re-check provider/model/credential/signed-in before assigning).
3. Pass `accessibilityLabel: aiStore.keyFieldLabel` to `RevealableSecureField`.
4. iOS deviation: `.controlSize(.small)` and `ProgressView("Checking…").controlSize(.small)`
   are fine on iOS; no change. Give the Validate button no explicit frame — `Form` rows
   are already touch-sized on iOS.

**H.6 `Vellum/Services/Ai/AiPrompts.swift` — [MERGE, one line]**

The `.image` case in `referenceLine` is already on iPad ✓. The only remaining hunk:
```swift
-        messages.suffix(10).map { "\($0.role.rawValue.uppercased()): \($0.content)" }
+        messages.suffix(10).map { "\($0.role.rawValue.uppercased()): \($0.promptContent)" }
```
in `buildConversationBlock`. `promptContent` comes from `AiToolSummary.swift` (§C), so
land that first.

---

### I. Markdown / math / text-selection — folded in from the phantom packet

**Why this is here.** Packets 5 and 7 both deferred `InlineMarkdown.swift`,
`MarkdownMessage.swift` and `SelectableMessageText.swift` to a "markdown / math /
text-selection packet" that was never cut (packet 10 §3.2 — ~730 delta lines with no
owner). Packet 10's orchestration decision: **fold all of it into packet 5.** Without §I.1
and §I.2, packet 9 cannot compile `MarkdownParserTests` and has no production type for
`AiMarkdownRenderingTests`; packet 7 §4.2's 11 `#127` cases have nothing to assert against.

Land §I **after §F** (so `AiPanel_iOS`'s call sites exist) and **before** packet 9 touches
`MarkdownParserTests` / `AiMarkdownRenderingTests` / `SelectableMessageTests`.

**I.1 `Vellum/Views/AI/InlineMarkdown.swift` — [VERBATIM]** (+104, new file)

`git -C main show 7742a895 -- Vellum/Views/AI/InlineMarkdown.swift`. Pure Foundation +
`AttributedString`; **zero AppKit**, so it copies across unchanged. Add nothing, wrap
nothing. This is the file packet 9's `Tests/AiMarkdownRenderingTests.swift` is blocked on
(packet 10 §2.1) — tell packet 9 the moment it lands.

**I.2 `Vellum/Views/AI/MarkdownMessage.swift` — [MERGE, list model change]** (+211/−56)

Live on iPad (not `#if os(macOS)`), and it is where `MarkdownParser` / `MarkdownBlock`
live. The substantive change:

* Replace `case unordered([String])` and `case ordered([String])` on `MarkdownBlock` with
  a single `case list([MarkdownListItem])`.
* Add the nested-depth `MarkdownListItem` struct (`depth` / `marker` / `text`) exactly as
  main declares it — packet 9's `testLists` constructs
  `MarkdownListItem(depth:marker:text:)` positionally and will not compile against a
  reshaped initializer.
* Take the rest of the diff (renderer changes for nested lists, `mathMaxWidth:` and
  `fillsAvailableWidth:` parameters) as-is. The body is SwiftUI-only.
* Update every `case .unordered` / `case .ordered` switch arm in the iPad tree in the same
  commit — grep before you start; `AiPanel_iOS` and the annotation-row renderer both
  switch on `MarkdownBlock`.

**Compile-breaking for two other packets.** Packet 9 tags `Tests/MarkdownParserTests.swift`
on the assumption that iPad's copy is byte-identical to base; main's new `testLists`
asserts the new model. Packet 7 §4.2 merges 11 `#127` cases into the same file. Both are
downstream of this step.

**I.3 `Vellum/Views/AI/SelectableMessageText.swift` — [REBUILD into the existing UIKit rewrite]** (+417/−58)

Main's file is AppKit (`NSTextView`, `NSDraggingInfo`, `NSTextAttachment`). **iPad already
ships a UIKit rewrite** (`import SwiftUI` / `import UIKit`) — do not overwrite it. Port
only the layout substance out of main's diff into the existing iPad file:

* `AttachmentText` — the attachment-bearing text model.
* `fittedAttachments(in:width:)` — the fit pass that sizes attachments to the available
  width.
* `measureSize` — the measurement helper the fit pass calls.
* The `mathMaxWidth` plumbing, threaded from the caller down to the attachment sizing.
* The **new `attributedString(for:…)` signature** — this is a source-breaking change; fix
  every call site in the same commit (`AiPanel_iOS`, `MarkdownMessage`, and the annotation
  row if it renders selectable text).

Map AppKit → UIKit as you go: `NSTextAttachment` → `NSTextAttachment` (same class,
UIKit-backed image), `NSSize` → `CGSize`, `NSTextView` metrics → the iPad file's existing
`UITextView`/`TextKit 2` path. Drop main's drag-and-drop handling entirely (standing
"iOS-native drop rebuild stays" decision).

Packet 9's `Tests/SelectableMessageTests.swift` now has a production owner: this step.
Specify its content here; packet 9 writes the file.

**I.4 `Vellum/Views/PDF/PdfOverlays.swift` — [MERGE → `Vellum/Platform/iOS/RegionCaptureOverlay_iOS.swift`]** (+5/−3)

The macOS file is `#if os(macOS)` on iPad and stays dead — **do not edit it**. The change
is a call-site adaptation to *this packet's own* model change: `PdfPageSnapshot.pageNumber`
became `Int?`, so the region-capture overlay must unwrap it before building the reference.
In `RegionCaptureOverlay_iOS.swift`, at the `AiReference(kind: .region(image:page:))`
construction site:

```swift
let page = snapshot.pageNumber          // now Int?
… AiReference(kind: .region(image: image, page: page))
```

Two lines. Packet 7 SKIPs this file explicitly ("region-capture/AI-references — packet 5"),
so nobody else will do it.

---

## 3. project.yml / Info-iOS.plist / entitlements

**`project.yml` — no changes required.** The `Vellum` target globs `- path: Vellum`
(whole tree) and `VellumTests` globs `- path: Tests`, so every new file
(`AiToolSummary.swift`, `AiToolSummaryView.swift`, `AiToolSourceRow.swift`,
`AiFileAttachment.swift`, `SentReferenceChips.swift`, `AttachmentDrop.swift`, and the six
new test files) is picked up automatically. Just re-run:

```
cd /Users/ayushdeolasee/Developer/Vellum/ipad-app && xcodegen generate
```

Contrast with main, which lists files in `Vellum.xcodeproj/project.pbxproj` — ignore
every `project.pbxproj` hunk in the delta.

**`Vellum/Resources/Info-iOS.plist` — no changes required for this packet.**
- Main's Info.plist delta removes `NSMicrophoneUsageDescription` and
  `NSSpeechRecognitionUsageDescription`; the iPad plist never had them ✓ (voice/TTS was
  removed at port time). Nothing to delete.
- Main's other Info.plist additions (`CFBundleDocumentTypes` for `com.vellum.bundle`,
  `UTExportedTypeDeclarations` for `com.vellum.webarchive`/`com.vellum.bundle`) are the
  packet 1's `.vellum` bundle work — **not mine**. Note for that packet's owner:
  the iPad plist currently exports `com.vellum.vellumweb`, main exports
  `com.vellum.webarchive`; those UTI strings differ and one of them will have to give.
- **No `NSPhotoLibraryUsageDescription` is needed.** `PhotosPicker` runs out of process
  (`PHPickerViewController`) and requires no usage description. Do not add one.

**Entitlements — no changes.** Nothing in this packet needs a capability. `project.yml`
deliberately leaves `CODE_SIGN_ENTITLEMENTS` unset (free signing team can't provision
iCloud); do not touch that.

---

## 4. Tests to port

> **Ownership rule (packet 10 §2.1).** **Packet 9 is the only packet that writes into
> `Tests/`; every other packet's test claim is a specification, not an edit.** Everything
> in this section is the adaptation list packet 9 applies — do not create or modify these
> files yourself.

All six new files land in `Tests/` and are auto-globbed. The bundle is XCTest-based with
one swift-testing file, and both run in the same target.

Additional suites this packet now specifies, via §I: `Tests/AiMarkdownRenderingTests.swift`
(content per §I.1 — **blocked until `InlineMarkdown.swift` lands**),
`Tests/SelectableMessageTests.swift` (content per §I.3), and the list-model half of
`Tests/MarkdownParserTests.swift` (content per §I.2; packet 7 §4.2 supplies the other 11
`#127` cases).

| File | Action |
|---|---|
| **`Tests/AiToolSummaryTests.swift`** | **VERBATIM.** `import Foundation` + `import Testing` only; asserts on `AiToolSummary.make`, `parseLegacyActions`, `displayToolSummaries`, `displayContent`, `promptContent`, and the `AiPersistence.sanitizeToolSummaries` caps. Nothing platform-specific. |
| **`Tests/AiTranscriptFollowTests.swift`** | **MERGE.** `import XCTest` + `import SwiftUI`, pure — it only calls `AiPanel.follows(was:from:to:)`, `AiPanel.ScrollMetrics` and `AiPanel.bottomSlack`. Since those move to `AiPanel_iOS` (§F.4), do a mechanical `AiPanel.` → `AiPanel_iOS.` rename across the file. No other change. |
| **`Tests/AttachmentDropTests.swift`** | **REBUILD.** Main's file is `import AppKit` and builds a fake `NSDraggingInfo` over a scratch `NSPasteboard` to drive `SubmitTextView`/`ComposerDropScrollView` dragging overrides — none of which exist on iPad. Keep the half that is portable and re-derive the rest: (a) `AiFileAttachment` classification via `aiFileAttachment(from:)` over real temp files (image, non-image, directory, corrupt-bytes-with-image-extension, extensionless-but-typed) — these transfer almost unchanged; (b) `AiStore.nameList` string cases; (c) the four notice-copy assertions from `AiStore.attachFiles` (mixed drop attaches the images *and* names the rejects; images-only precedence over folder/unreadable; singular vs plural verb; `dismissAttachmentNotice` cancels the timer) — drive them by calling `aiStore.attachFiles(at:)` directly with temp URLs, no drop harness needed; (d) new: `AttachmentDrop.payload(for:)` over `NSItemProvider(contentsOf:)` for a file URL and `NSItemProvider(item: data as NSData, typeIdentifier: UTType.png.identifier)` for raw bytes, plus `carriesAttachment` on a plain-text provider. Drop the `NSDraggingInfo` fake entirely. |
| **`Tests/AiReferencePersistenceTests.swift`** | **MERGE — after packet 1.** XCTest, `@MainActor`. Covers the `AiMessage.references` round-trip through `documents/<storageKey>/conversations.json`, back-compat with transcripts written before the field, forward-compat with an unknown `kind` tag (the `LossyAiReference` drop), the **stable on-disk kind tags**, and the two caps. It isolates on-disk state via `DocumentDataStore.rootDirectoryOverride`, so it cannot compile until packet 1 lands. No AppKit. Port verbatim once unblocked. |
| **`Tests/AiConversationStoreTests.swift`** | **MERGE — after packet 1.** XCTest, `@MainActor`. Covers the write-behind cache + coalesced flush, empty-save hard-delete, path-hash→docId rekey, lazy migration out of the legacy blob, and the caps. Same `rootDirectoryOverride` dependency. **Add one iPad-only case** here or in `AiPipelineTests`: an undecodable `conversations.json` (write garbage bytes) followed by `saveConversation(…, messages: [])` must leave the file on disk (the #90 guard), and a *non-empty* save over the same key must still write. |
| **`Tests/AiAddAsNoteTests.swift`** | **MERGE — this packet supplies the content; packet 9 writes the file.** Three-way conflict resolved in packet 10 §2.1: packet 9 creates `Tests/AiAddAsNoteTests.swift` from **packet 5's** content; packet 7's 14 web-dismissal cases go to a **new `Tests/WebNoteDraftTests.swift`** instead (not in `delta-files.txt`, so it needs no claim). Nobody ports this file twice. **Coordinate with packet 4.** Covers `AppStore.beginNoteWithContent` arming note mode and the viewer consuming the payload. The PDF half (`PdfSelectionBridge.placeNote`) is portable; the web half asserts the web viewer's `"note-placed"` handler consumes rather than discards, which is packet 4's `WebViewerView_iOS` bridge. Port the `AppStore` half now; gate the web half on packet 4. |
| **`Tests/AiPipelineTests.swift`** | **MERGE — this one needs care.** See below. |

### `Tests/AiPipelineTests.swift` merge detail

The iPad file diverges from main's pre-delta version by **+123 lines**: `import UIKit` at
the top, two iPad-only container-migration tests, the §6 image-attachment tests, and a
UIKit `private static func bitmap(width:height:alpha:)` built on
`UIGraphicsImageRenderer`.

- **Keep, do not overwrite:** `import UIKit`;
  `testConversationSurvivesContainerPathChange`; `testWebPdfUrlDoesNotMigrateLocalConversation`;
  the iPad `bitmap(width:height:alpha:)` helper.
- **Drop from main's side:** `import AppKit` (line 1) and main's own
  `bitmap(width:height:alpha:)` built on `NSBitmapImageRep` (≈line 1299) — the iPad one
  has the same name and signature, so keeping both is a redefinition error.
- **Also already on iPad, do not double-add:** `testAttachedImageIsDownscaledAndTranscoded`,
  `testAttachedImageWithAlphaStaysPng`, `testAttachedImageRejectsNonImageBytes`,
  `testReferenceLineForAttachedImageHasNoPage`, `testSupportsVisionResolution`.
- **Take from main** (all pure Foundation/XCTest):
  - `testAssistantAnswerIsTheTrimmedReplyAndNothingElse` — replaces the old
    `composeAssistantContent` assertions.
  - the OpenAI effort/budget block: `testOpenAIOutputBudgetIsFlatForNonReasoningModels`,
    `testOpenAIAutoGetsAMidRangeBudgetNotTheMinimalOne`, `testAutoOmitsTheEffortFieldEntirely`,
    `testGpt55RejectsMinimalAndOffersNoneAndXhigh`, `testInstantResolvesDownwardOnGpt55`,
    `testUnknownGpt5VariantOmitsRatherThanGuessing`, `testKnownFamiliesKeepTheirEffortVocabularies`,
    `testEveryShippedGpt5ModelHonoursAnExplicitMode`,
    `testProVariantsDoNotInheritTheirFamilysVocabulary`,
    `testCodexAndOSeriesResolveToValuesTheyAccept`, `testExplicitSupportedEffortsArePreserved`.
  - `testOpenRouterResolvesOpenAIEffortsThroughTheSharedTable`.
  - the token-cutoff block, driven by the new `private struct FixtureBytes: AsyncSequence`
    SSE fixture harness (≈line 464) and `toolCallFixture(truncated:text:)`:
    `testTokenLimitDropsQueuedFunctionCallsInsteadOfRunningThem`,
    `testQueuedFunctionCallsStillRunWhenTheResponseWasNotTruncated`,
    `testTokenLimitWithNoTextAndNoPriorWorkErrorsRatherThanRunningTools`,
    `testTokenLimitKeepsWorkDoneByEarlierTurnsInsteadOfThrowing`,
    `testNonTokenIncompleteReasonSurfacesOnlyWhereTheClientAsksForIt`.
  - the composer-focus + capture-target block: `testAddingReferenceOpensAiAndRequestsComposerFocus`,
    `testConsumingAStaleFocusRequestLeavesTheCurrentOnePending`,
    `testComposerFocusRequestsAreScopedToTheirSplitPane`,
    `testPdfPageCaptureAfterAwaitIsRejectedAfterTabSwitch`,
    `testWebRegionCaptureAfterAwaitIsRejectedAfterTabSwitch`,
    `testCaptureIsAttachedWhenTheTabIsStillTheSameOne`, and the
    `private static func tab(id:document:) -> PdfTab` helper (≈line 845 — `PdfTab` exists
    on iPad at `Vellum/Models/Models.swift:166`; check the initializer signature matches
    and adapt if the iPad `PdfTab` has extra fields).
  - the Gemini block: `geminiBody/geminiConfig/geminiCap/geminiLevel/geminiBudget` helpers
    plus `testGeminiAutoBudgetsForTheThinkingTheServerWillDo`,
    `testGeminiAutoKeepsTheBaseWhereTheServerDefaultsToMinimal`,
    `testGeminiUnknownFamiliesKeepTheBaseBudget`,
    `testGeminiAutoIsNeverBudgetedAboveAnExplicitMode`,
    `testGeminiAutoKeepsTheBaseBudgetWhereThinkingIsDisabled`,
    `testGeminiNonThinkingFamiliesNeverExceedTheirOutputLimit`,
    `testGeminiThinkingLevelRowsMatchTheDocumentedFamilies`,
    `testGeminiDocumentedDefaultsDriveTheAutoReserve`,
    `testNoShippedGeminiModelIsSentAnUnsupportedLevel`, `testGeminiLevelTiesRoundUp`,
    `testGeminiExplicitModeBudgetsTrackTheResolvedLevel`,
    `testGeminiCapsStayInsideDocumentedOutputLimits`,
    `testGeminiRequestBodyKeepsItsTurnPayload`.
  - the ChatGPT block: `chatGPTBody` helper plus `testChatGPTOutputBudgetScalesWithThinkingMode`,
    `testChatGPTNoModeLosesAnswerRoom`, `testChatGPTBudgetFollowsTheResolvedEffort`,
    `testChatGPTRequestBodyKeepsItsTurnPayload`.
  - the `AiFileAttachment` classification tests `testFileAttachmentClassification` and
    `testBinaryFileIsRejectedByName` (these overlap `AttachmentDropTests`; keep both —
    main does).

---

## 5. Risks & cross-packet dependencies

**Hard blockers (this packet cannot fully land without them):**

1. **Packet 1 (storage / `DocumentDataStore` + `DocumentIdentity` + `DocumentInfo.docId` +
   `AppStore.syncDocumentId`).** Blocks: §E (`AiPersistence` entirely), §D.16's
   stamp-before-first-persist hunk, `AiConversationStoreTests`,
   `AiReferencePersistenceTests`. **Mitigation:** land §A–§D (minus D.16's stamp block)
   and §F–§H first with the `documentForPersist = documentAtStart` stub; come back for
   §E. The rest of the AI delta does not touch the storage key at all.
   `AiPersistence.limitedMessages` is also called by packet 2's `VellumBundle` (main
   deleted `VellumBundle.capConversation` in favour of it) — whoever lands second must
   not reintroduce a parallel cap.

2. ~~**Markdown / text-selection packet**~~ — **no longer a dependency: this is now §I of
   this packet.** Packet 10 §3.2 found that the "markdown / math / text-selection packet"
   was never cut, leaving ~730 delta lines unowned; the orchestration decision folds
   `InlineMarkdown.swift`, `MarkdownMessage.swift` and `SelectableMessageText.swift`
   (plus the `PdfOverlays.swift` call-site adaptation) into packet 5. Main's `AiPanel`
   passes `maxWidth: textWidth` to `SelectableMessageText`, renames its drop hook
   `onImageDrop` → `onAttachmentDrop` (payload type changes from `[NSItemProvider]` to
   `AttachmentDropPayload`), and passes `mathMaxWidth:` + `fillsAvailableWidth: false` to
   `MarkdownMessage`. `AiPanel_iOS` calls both. **Because §F and §I are now in the same
   packet, land §F's call sites first with the current iPad signatures, then update them
   in §I** — no cross-packet `// TODO` marker is needed any more. `MathRenderer.swift`
   remains packet 7's (§2.5, inline-code immunity).

   Downstream consumers to notify when §I lands: packet 9
   (`AiMarkdownRenderingTests` is blocked on §I.1; `SelectableMessageTests` on §I.3;
   `MarkdownParserTests` on §I.2) and packet 7 (§4.2's 11 `#127` cases).

**Softer risks / things to watch:**

3. **`AiPanel.follows` / `ScrollMetrics` / `bottomSlack` live on the panel type.** Moving
   them to `AiPanel_iOS` means `Tests/AiTranscriptFollowTests.swift` diverges from main
   by a symbol rename forever. Acceptable (it is the iOS-native rebuild), but flag it in
   the PR body so the next parity pass doesn't "fix" it back.

4. **`clearConversation()` semantics changed twice over.** It now (a) returns a
   transaction, (b) no-ops on an empty transcript, and (c) **stops clearing
   `composerReferences`**. (c) is a user-visible behaviour change on iPad: clearing the
   chat no longer discards attached chips. That is intentional upstream. Also grep the
   iPad tree for other callers — `VellumCommands_iOS` / `ShortcutRouter_iOS` may invoke
   it and will now silently no-op on an empty transcript; make sure any menu/shortcut
   item is disabled when `messages.isEmpty` rather than appearing to do nothing.

5. **Undo/Redo needs a real `UndoManager` in the environment.** On iPad, SwiftUI supplies
   `\.undoManager` only where the responder chain provides one. If it comes back nil in
   the sidebar, the clear still works (main's `clearConversation()` deliberately does the
   work *before* checking for an undo manager) but Undo is unavailable. Verify on device;
   if nil, the fallback is to hang an `UndoManager` off `WorkspaceStore` and inject it —
   but do not gate the clear on it.

6. **Composer-drop registration is no longer vision-gated (§F.9).** Users on a text-only
   model will now be able to start a drag onto the panel and get a notice instead of the
   drag springing back. That is main's behaviour and the point of the images-only-policy
   notices, but it is a visible change from today's iPad build — call it out in the PR.

7. **Batching the drop payload (§G).** If the implementer classifies providers one at a
   time and calls `handleDrop` per provider, a four-file mixed drop produces four toasts
   instead of one. This is the easiest thing to get wrong in the whole packet.

8. **Security-scoped URLs (§D.14).** Main's `attachFiles` comment explicitly says no
   scoping is needed. Copying it verbatim onto iOS produces a silent
   `.rejected(name:)`/`nil` for every Files-sourced drop and pick — the failure looks like
   "Vellum says my PNG is a folder". This is the single highest-probability regression in
   the packet.

9. **`AiSettingsPanel` deliberately survives on iPad** while main deletes it (§H.3).
   Anyone diffing iPad against main later will see it as unported drift. Document it.

10. **`RevealableSecureField`'s new first parameter has no default**, so every call site
    must be updated in the same commit or the build breaks. There are two
    (`AiSettingsPanel`, `SettingsView.AiSettingsTab`).

11. **`AiToolEngine.displayActions` changes type** from `[String]` to `[AiToolSummary]`.
    Grep the iPad tree for `displayActions` before copying — anything that formatted it
    as strings (including `AiStore.sendMessage`'s old `composeAssistantContent` call and
    any activity-pill `case .tool(let summary)` plumbing) must be updated in the same
    commit.

12. **`Vellum/Views/Settings/SettingsView.swift` is a four-packet file.** Packets 3, 1, 5
    and 8 all edit it; each hunk is <10 lines in the `TabView`. **Land in the order
    3 → 1 → 5 → 8** (packet 10 §2.3) or accept a mechanical conflict: packet 3
    restructures the `TabView` to `$workspace.settingsSection`, packet 1 adds the storage
    tab, this packet's §H.5 adds the AI tab, packet 8 adds the integrations tab. The
    AI-tab additions here are a self-contained append — land §H.5 in its slot, not
    earlier.
