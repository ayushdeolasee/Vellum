> **HISTORICAL — describes the pre-port Tauri app, not the current SwiftUI app.**
> Written as reference material for the Tauri→SwiftUI port (2025–2026). The current
> app has diverged (e.g. 5 streaming AI providers and 5 tools vs. the 3 non-streaming
> providers / 3 tools described here; no Codex CLI provider; repo-root layout, not
> `macos/`). Do not treat file paths, behavior, or UI specs here as current.

# SPEC: ai

## Overview
The AI subsystem is a per-document chat assistant living in the right sidebar of Vellum. It supports three providers — Gemini (via Vercel AI SDK `@ai-sdk/google`), OpenAI (via `@ai-sdk/openai` Responses API), and a local Codex CLI (via a Tauri command that shells out to `codex exec`) — all BYOK/local-auth, all **non-streaming** (`generateText`, single awaited response; there is NO token streaming anywhere). The assistant receives the full extracted document text, annotations, and a JPEG snapshot of the current page, and can call three tools (`goToPage`, `addNote`, `addHighlight`) that mutate the reader UI. Conversations and settings persist in `localStorage`, keyed per document. Voice features are push-to-talk speech-to-text (Web Speech API) into the input box and optional TTS speaking of assistant replies (SpeechSynthesis). There is NO Gemini Live session — two prompt files for that exist but are dead code.

## Features

### Side panel host / open-close behavior

**Behavior:** The AI panel is NOT independently openable — it lives inside the single right sidebar defined in `src/App.tsx`. App state: `sidebarOpen` (default `true`), `sidebarTab: "annotations" | "ai"` (default `"annotations"`). The Toolbar has a toggle button that flips `sidebarOpen`. When open, a segmented control at the top switches between the Annotations sidebar and the AiPanel. The panel is only rendered when a document is open (no doc → WelcomeScreen, no sidebar). There is NO resize behavior — fixed width. There are no keyboard shortcuts for the AI panel itself (app-level shortcuts Cmd/Ctrl+O/L/S/W/1-9/=/-/B, Escape, N exist but none touch AI). Switching documents/tabs (keyed on `activeTabId` + `doc.pdf_path`) triggers: `clearAnnotations()`, `clearDocumentContext()` (wipes `pageTexts`, `messages`, `isThinking`, `error`), `loadAnnotations()`, `loadConversationForDocument(document)` (restores that document's persisted chat).

**UI:** Sidebar container: `w-80` (320px), `flex-shrink-0`, `border-l`, `bg-background`, full height, `overflow-hidden`. Segmented control: wrapper `p-2`, inner `flex gap-1 rounded-lg bg-muted p-1`; each button `flex-1 items-center justify-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors`; active tab `bg-surface text-foreground shadow-soft`, inactive `text-muted-foreground hover:text-foreground`. Annotations tab icon: lucide `MessageSquare` size 13 + label "Annotations"; AI tab icon: lucide `Sparkles` size 13 + label "AI". Content area below control: `min-h-0 flex-1 overflow-hidden overscroll-contain border-t`.

### Panel header

**Behavior:** Header row with title and two icon buttons. Settings button toggles the inline settings panel (`settingsOpen` local state, default false). Trash button calls `clearConversation()` which saves an empty message list for the current document (deleting its localStorage entry) and sets `messages: []`, `error: null`.

**UI:** Row: `flex items-center justify-between border-b px-3 py-2`. Left: `Sparkles` icon size 15 with class `text-primary` + text "AI Assistant" (`text-sm font-medium`, `gap-2`). Right (`gap-0.5`): IconButton (28×28px, `h-7 w-7`, rounded-md) with `Settings` size 15, tooltip/title "AI settings", variant `active` (bg-primary) while settings open else `ghost`; IconButton with `Trash2` size 15, title "Clear conversation".

### Settings panel (BYOK)

**Behavior:** Inline collapsible section under the header. Fields, in order: (1) **Provider** select with options `gemini` → "Gemini", `openai` → "OpenAI API", `codex` → "Codex CLI". (2) **API key** password input — hidden entirely when provider is `codex`; label "OpenAI API key" or "Gemini API key"; placeholder `sk-...` (OpenAI) or `AIza...` (Gemini); writes `settings.openaiApiKey` or `settings.apiKey` on every keystroke. (3) **Model** select — options depend on provider: Gemini: `gemini-3.1-flash-lite-preview`, `gemini-3-pro-preview`, `gemini-3-flash-preview`, `gemini-2.5-pro`, `gemini-2.5-flash`, `gemini-2.5-flash-lite`, `gemini-2.0-flash`, `gemini-2.0-flash-lite`, `gemini-1.5-pro`, `gemini-1.5-flash`. OpenAI: `gpt-5.5`, `gpt-5.5-2026-04-23`, `gpt-5.4-mini`, `gpt-5.4`, `gpt-5`, `gpt-5-mini`, `gpt-4.1`, `gpt-4.1-mini`. Codex: `gpt-5.5`, `gpt-5.4-mini`, `gpt-5.3-codex-spark`. Writes `codexModel` / `openaiModel` / `model` per provider (each provider keeps its own model selection). (4) **Voice mode** select: `off` → "Off", `push-to-talk` → "Push-to-talk"; switching away from push-to-talk stops any active recognition. (5) **TTS** checkbox labeled "Speak assistant responses (TTS)" bound to `settings.ttsEnabled`. Every `setSettings` call immediately persists the full settings object to localStorage. Defaults: provider `gemini`, model `gemini-3.1-flash-lite-preview`, apiKey `""`, openaiModel `gpt-5.5`, openaiApiKey `""`, codexModel `gpt-5.5`, voiceMode `off`, ttsEnabled `false`.

**UI:** Section: `space-y-2.5 border-b bg-surface-muted p-3 text-xs`. Each label: block with `mb-1 block text-muted-foreground` caption. Selects/inputs: `w-full rounded border bg-background px-2 py-1 outline-none focus:ring-1 focus:ring-primary`. TTS row: `flex items-center gap-2 text-muted-foreground` with a native checkbox.

### Message list

**Behavior:** Scrollable list of the conversation. Auto-scrolls to bottom (`scrollTop = scrollHeight`) whenever `messages` or `isThinking` changes. **Empty state** (0 messages): centered Sparkles-in-circle icon and the exact copy: "Ask anything about this document. The assistant can read the page, jump around, and create notes and highlights for you." **Thinking indicator**: while `isThinking`, an inline pill with a pulsing Sparkles icon (size 12, `animate-pulse text-primary`) and text "Thinking…" (with U+2026 ellipsis). **Error banner**: when `error` is non-null, rendered after the messages as a red box containing the raw error string. Message content renders through MarkdownMessage (markdown+GFM+KaTeX).

**UI:** List container: `min-h-0 flex-1 space-y-3 overflow-auto overscroll-contain px-3 py-3`. Empty state: `flex flex-col items-center gap-3 px-4 py-8 text-center`; icon circle `h-12 w-12 rounded-full border border-border bg-muted text-primary` with `Sparkles` size 20 strokeWidth 1.75; copy `text-xs leading-relaxed text-muted-foreground`. Each message: column, `gap-1`, user messages `items-end` (right-aligned), assistant `items-start`. Role label row: `flex items-center gap-1 px-1 text-[11px] font-medium text-muted-foreground`, icon `User` size 11 + "You" or `Sparkles` size 11 + "Assistant". Bubble: `max-w-[92%] rounded-xl px-3 py-2 text-sm`; user: `rounded-tr-sm bg-primary text-primary-foreground`; assistant: `rounded-tl-sm border border-border bg-surface text-foreground`. Thinking pill: `inline-flex items-center gap-2 rounded-xl border border-border bg-surface px-3 py-2 text-xs text-muted-foreground`. Error: `rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive`.

### Markdown + KaTeX rendering (MarkdownMessage)

**Behavior:** Renders `react-markdown` (v10) with plugins `remark-gfm` (tables, strikethrough…), `remark-math`, and `rehype-katex` (KaTeX v0.16 CSS imported globally in main.tsx). Applied to BOTH user and assistant bubbles. Links open in new tab (`target=_blank rel=noreferrer`). Code with a language class renders as a block `<pre>`; inline code otherwise. There is no syntax highlighting and no copy button.

**UI:** Wrapper: `min-w-0 break-words`, KaTeX display blocks get `my-2` and `overflow-x-auto`, `.katex` inherits text color. Element styles: h1 `mb-2 mt-3 text-base font-semibold`; h2 `mb-2 mt-3 text-sm font-semibold`; h3 `mb-1.5 mt-2 text-sm font-semibold`; p `mb-2 leading-relaxed last:mb-0`; ul `mb-2 list-disc space-y-1 pl-5`; ol `mb-2 list-decimal space-y-1 pl-5`; li `leading-relaxed`; blockquote `mb-2 border-l-2 border-border/60 pl-3 italic`; code block `mb-2 overflow-x-auto rounded border border-border/60 bg-black/15 p-2 text-[12px]`; inline code `rounded bg-black/15 px-1 py-0.5 font-mono text-[12px]`; a `underline underline-offset-2`.

### Input composer

**Behavior:** Textarea + optional push-to-talk button + send button, inside a form. Submit paths: form submit (send button click) or Enter key without Shift (Shift+Enter inserts newline). Submission is ignored when input trims to empty or `isThinking` is true. On submit: clears the input, then calls `sendMessage(trimmed, contextSnapshot)` where the snapshot is `{ title: doc?.title ?? null, numPages, currentPage, visiblePages, annotations, currentPageImage: captureCurrentPageImage() }` taken from pdf-store/annotation-store at send time. Send button is `disabled` when `!input.trim() || isThinking` (renders at 40% opacity).

**UI:** Footer: `border-t p-3`. Form: `flex items-end gap-2 rounded-xl border border-border bg-surface p-1.5 transition-colors focus-within:border-primary/60`. Textarea: `rows=2`, `min-h-[2.5rem] min-w-0 flex-1 resize-none bg-transparent px-2 py-1.5 text-sm outline-none`, placeholder "Ask about this document…" (U+2026). Send button: `h-9 w-9 rounded-lg bg-primary text-primary-foreground hover:bg-primary-hover disabled:opacity-40`, lucide `Send` size 15, title "Send message".

**Shortcuts:** Enter (no Shift) in the textarea: send message. Shift+Enter: newline. No other shortcuts.

### Current-page image snapshot

**Behavior:** On every send, the panel captures the rendered canvas of the current page: queries DOM for `[data-page-number="{currentPage}"]`, finds its `<canvas>`; returns null if missing or canvas is under 2px in either dimension. If the larger canvas dimension exceeds 1280 (`SNAPSHOT_MAX_DIMENSION`), draws into an offscreen canvas scaled so max dimension = 1280 (`Math.max(1, Math.round(dim*scale))` per axis). Encodes `toDataURL("image/jpeg", 0.72)` and splits the data URL with regex `/^data:(.+);base64,(.+)$/`. Result shape: `{ pageNumber, mediaType ("image/jpeg"), base64Data, width, height }`. Any exception → null (silently no image). For Gemini/OpenAI the image is attached as a second content part of the user message (`{ type: "image", image: base64Data, mediaType }`). For Codex it is written to a temp file and passed via `--image`. The context block always mentions it: `Current page image: attached (WxH, image/jpeg)` or `Current page image: none`. Note: for web documents there is no PDF canvas so capture typically returns null.

### sendMessage pipeline (ai-store)

**Behavior:** 1) Trim input; bail if empty. 2) Read `activeTabId` and `document` from pdf-store; bail silently if either missing. 3) Key check: if provider is `gemini` or `openai` and the corresponding key trims to empty, set `error` to exactly "Set your OpenAI API key in AI settings." or "Set your Gemini API key in AI settings." and return (no message appended). Codex requires no key. 4) Append user message `{id: uuid, role:"user", content, createdAt: ISO}`, set `isThinking: true`, `error: null`, persist conversation. 5) Build `conversation` = last 10 messages (including the new user message) formatted `"USER: ..."`/`"ASSISTANT: ..."` joined by newlines, or `"(start of conversation)"` if empty. 6) Build the context block (see Document context injection). 7) Dispatch to provider with three prompts: `systemPrompt` = native tool system prompt, `userPrompt` = native user prompt, `jsonPrompt` = JSON-contract prompt (only Codex uses jsonPrompt; the SDK providers use system+user). Model name fallback: a whitespace-only configured model falls back to the default (`gemini-3.1-flash-lite-preview` / `gpt-5.5` / `gpt-5.5`). 8) On success, assistant content = `reply` alone, or if any tool actions ran: reply + "\n\nActions:\n" + one "- {result}" line per action result. Persist `[...messagesWithUser, assistantMessage]`; only update in-memory state (`messages`, `isThinking:false`) if `activeTabId` still equals the id captured at start (tab-switch safety). 9) On thrown error: assistant message with content `I couldn't complete that request: {String(err)}` is appended and persisted; `error` state set to `String(err)`; again only applied to UI if the tab is unchanged. The thinking flag stays true forever on the abandoned tab path only in memory of the *new* tab? No — state is simply not touched when tab changed (the doc-change effect resets it via clearDocumentContext).

### Provider: Gemini (Vercel AI SDK)

**Behavior:** `createGoogleGenerativeAI({ apiKey })` then `generateText({ model: google(modelName), system: nativeSystemPrompt, messages: [{ role: "user", content: [text part, optional image part] }], tools: {goToPage, addNote, addHighlight}, stopWhen: stepCountIs(6), temperature: 0.2, maxRetries: 1 })`. Multi-step native tool calling: the SDK executes each tool's `execute` locally (mutating the reader) and loops model↔tools up to 6 steps. NOT streaming — the UI shows "Thinking…" until the whole call resolves. Final reply = trimmed `text`; if empty and actions ran → "Done."; if empty and no actions → "I couldn't produce a response."

### Provider: OpenAI (Vercel AI SDK, Responses API)

**Behavior:** `createOpenAI({ apiKey })` then `generateText({ model: openai.responses(modelName), system, messages: [user text + optional image], tools: same three, stopWhen: stepCountIs(6), maxRetries: 1, providerOptions: { openai: { store: false } } })`. No temperature set (SDK/provider default). Non-streaming. Same finalizeReply fallback strings as Gemini.

### Provider: Codex CLI (JSON tool contract)

**Behavior:** Frontend calls the Tauri command `run_codex_ai(prompt=jsonPrompt, model, image?)`. The jsonPrompt is the fully-rendered tool-mode-system template (conversation+context+request baked in) instructing the model to return one strict JSON object `{"reply": string, "actions": [{"tool": ..., "args": {...}}]}`. Response parsing (`parseModelResponse`): extract substring from first `{` to last `}` (fallback: whole text), `JSON.parse`; `reply` = parsed.reply trimmed if non-empty string else the raw text trimmed; `actions` kept only if `tool` is one of `goToPage|addNote|addHighlight` and `args` is a non-null object (unknown tools silently dropped); parse failure → `{reply: rawText.trim(), actions: []}`. Empty raw text → reply "I couldn't produce a response." Actions then execute sequentially via the same guarded runner (max 5, tab-change abort). Rust side: spawn_blocking; creates a tempdir; writes `codex-output-schema.json` (see externalAPIs for exact schema) and decodes the optional image (base64, `.trim()`ed) to `current-page.{png|webp|jpg}` (extension from media_type: image/png→png, image/webp→webp, else jpg). Runs `codex exec --model {model||"gpt-5.5"} --sandbox read-only --skip-git-repo-check --ephemeral --cd {tempdir} --output-schema {schema} --output-last-message {out.json} [--image {img}] -` with the prompt piped to stdin. Errors (exact strings): "Failed to create temp dir: {e}", "Failed to serialize Codex schema: {e}", "Failed to write Codex schema: {e}", "Failed to decode page image: {e}", "Failed to write page image: {e}", "Failed to start Codex CLI. Is `codex` installed? {e}", "Failed to open Codex stdin", "Failed to write prompt to Codex: {e}", "Failed to read Codex output: {e}", non-zero exit → "Codex CLI exited with status {status}: {stderr-or-stdout truncated to 1200 chars + '...'}", "Failed to read Codex final response: {e}", empty response → "Codex returned an empty response.", join failure → "Codex task failed: {e}". Success value: contents of the --output-last-message file, falling back to stdout, trimmed.

### Tool execution engine

**Behavior:** Three tools, shared by native (SDK) and JSON (Codex) paths through `runToolAction(action, sessionIdAtStart, actionResults)`. Guards, in order: (a) if `actionResults.length >= 5` → push+return "Skipped: action limit reached for this response."; (b) if pdf-store `activeTabId !== sessionIdAtStart` → "Skipped: the active document changed before this action ran."; (c) execute, catching errors as "Action failed: {String(err)}". Every result string is both returned to the model (as the tool result in SDK mode) and appended to the visible "Actions:" list. **goToPage**: clamp page (non-finite → current page or 1; else round then clamp to [1, numPages]; numPages<=0 → 1); calls pdf-store `goToPage(page)`; result "Navigated to page {N}." **addNote**: clamp page; trim text, empty → "Skipped addNote: empty text."; creates annotation `{type:"note", page_number, content: text, position_data: { rects:[{x: sanitize(x, default 72), y: sanitize(y, default 96), width:0, height:0}], page_width:612, page_height:792, selected_text:null, start_offset:null, end_offset:null }}` (sanitize: non-finite/non-number → default, else max(0, v)); result "Added note on page {N}." **addHighlight**: clamp page; trim text, empty → "Skipped addHighlight: no text provided to locate."; sanitize color against regex `/^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$|^(?:rgb|rgba|hsl|hsla)\([^)]*\)$|^[a-z]+$/i` (trimmed; fail → "#fef08a"). For web documents (`document.kind === "web"`): call global `window.__locateWebText(page, text)` (installed by WebViewer content-script bridge) → `{positionData, pageNumber}`; on hit, `selected_text` is set to the query and the annotation is filed under the located (clamped) page, which may differ from the model's guess. For PDFs: `locateTextOnPage(page, text)` — resolves geometry from pdf.js text content without DOM (see below). If no positionData (or, for PDFs, zero rects) → "Skipped addHighlight: couldn't find \"{text}\" on page {N}."; else create `{type:"highlight", page_number: resolvedPage, color, position_data}` and return "Highlighted \"{text}\" on page {N}." Defensive default for an unhandled variant: "Skipped unknown tool: {name}."

### PDF highlight locator (locateTextOnPage)

**Behavior:** Module-level `currentDocument` pdf.js proxy registered/unregistered by PdfViewer. Algorithm: strip ALL whitespace from query, lowercase → needle (empty → null). `doc.getPage(pageNumber)` (throw → null). Get viewport at scale 1 and `getTextContent()`. Build a whitespace-free lowercase haystack across all text items, tracking which item owns each character. `indexOf(needle)`; miss → null. Collect the set of matched item indices; project each item to a rect via `pdfjs.Util.transform(viewport.transform, item.transform)`: x = tx[4], y = tx[5] − fontHeight where fontHeight = hypot(tx[2], tx[3]), width = item.width, height = fontHeight (fallback item.height); skip non-positive. Merge rects on the same visual line (sorted by y then x; same line when |Δy| ≤ 0.6 × min(heights); merged to the spanning bbox). Returns `PositionData { rects: mergedRects, page_width: viewport.width, page_height: viewport.height, selected_text: query, start_offset: null, end_offset: null }` — coordinates in zoom=1 PDF points, origin top-left, y down. Granularity is whole-text-item: a phrase starting/ending mid-item can highlight slightly more than the exact words but always the right line(s).

### Document context injection

**Behavior:** `pageTexts: Record<number, string>` in the ai-store is populated outside the panel: **PDFs** — PdfViewer, after load, iterates pages 1..N (waiting for browser idle between pages), extracts `getTextContent()` items joined with spaces, collapses whitespace, calls `setPageText(page, text)`. **Web** — WebViewer receives virtual "pages" (article sections) `{number, text}` from its content script init message and calls `setPageText` per page. `setPageText` normalizes `\s+`→single space and trims; no-op if unchanged. Cleared on document/tab change via `clearDocumentContext`. The context block string sent to the model is built as (exact lines, joined with \n):

```
Document title: {title ?? "Untitled"}
Total pages: {numPages}
Current page: {currentPage}
Visible pages: {comma+space-joined list, or "none"}
Current page image: {"attached (WxH, mediaType)" | "none"}

Visible page text:
{for each visible page: "[Page N] {text or empty}" per line, or "(none)"}

Current page annotations:
{last 50 annotations on current page: "- ({type}) color={color ?? "none"} text=\"{selected_text ?? ""}\" note=\"{content ?? ""}\"", or "(none)"}

Annotations:
{last 200 annotations overall: "- ({type}) p.{page_number} color={...} text=\"...\" note=\"...\"", or "(none)"}

Full PDF text:
{all pages sorted ascending, "[Page N] {text}" per line; if total length > 120000 chars, hard-truncated at 120000 then "\n[truncated]"; empty → "(text extraction pending)"}
```

There is no tokenizer-based limit — only the 120,000-character cap (`MAX_CONTEXT_CHARS`) on the full-text section. The whole document is sent every turn.

### Push-to-talk voice input

**Behavior:** Only active when `settings.voiceMode === "push-to-talk"`; a mic button then appears between the textarea and send button. Hold-to-record: `onMouseDown`/`onTouchStart` (touch preventDefaults) start; `onMouseUp`/`onMouseLeave`/`onTouchEnd` stop. Uses `window.SpeechRecognition ?? window.webkitSpeechRecognition`; if neither exists, sets the store error to exactly "Speech recognition is not available in this environment." Recognition config: `continuous = false`, `interimResults = false`, `lang = "en-US"`. A single recognition instance is created lazily and reused (ref). `onresult`: joins `results[i][0].transcript` with spaces, trims; if non-empty, appends to the input textarea as `prev ? prev + " " + transcript : transcript` (it does NOT auto-send). `onerror`/`onend`: clear the listening flag and, if still in push-to-talk mode, `isListening=false`. Start clears any store error and sets `isListening=true` before `recognition.start()` (start() throwing resets flags). Stop is idempotent (guarded by a ref) and swallows `stop()` errors. On unmount: stop recognition and `speechSynthesis.cancel()`.

**UI:** Button `h-9 w-9 rounded-lg`, title "Push to talk". Idle: `text-muted-foreground hover:bg-accent hover:text-foreground` with lucide `Mic` size 15. Listening: `bg-destructive text-destructive-foreground` with lucide `Square` size 15 (stop-square).

### TTS output

**Behavior:** Effect in AiPanel: when `settings.ttsEnabled` is true, `isThinking` is false, a latest assistant message exists whose id differs from the last-spoken id (ref), and `speechSynthesis` is available: record the id, `synth.cancel()` (interrupt any current speech), create `SpeechSynthesisUtterance(message.content)` with `rate = 1`, `pitch = 1` (default system voice), and `synth.speak(...)`. Speaks the raw markdown content (no stripping). Cancelled on component unmount. Persisted messages restored on load are not re-spoken until a new assistant message id appears (actually: on remount the ref is null, so the latest restored assistant message WOULD be spoken once if TTS is enabled — the guard is only the ref within a mount).

### Conversation persistence & lifecycle

**Behavior:** Per-document chat history in localStorage (see persistence section for exact format). Saved after: adding the user message, receiving the assistant reply, the error-fallback assistant message, `addLocalMessage`/`updateLocalMessage` (store API, currently unused by the panel), and `clearConversation` (saves empty → deletes the key). Loaded by `loadConversationForDocument(document)` on tab/document change; also resets `isThinking:false, error:null`. Limits applied on both read and write: last 120 messages per document; each message content over 12,000 chars truncated to 12,000 + "\n[truncated]"; max 25 documents (when exceeded, keys are removed in `Object.keys` order — effectively oldest-inserted first). Malformed stored entries are sanitized: role must be "user"/"assistant", content must be a string, missing/blank id → new uuid, missing/blank createdAt → now ISO; invalid entries dropped; docs with zero valid messages omitted. All storage read/write errors are silently swallowed (read falls back to defaults).

### Dead code / not implemented (important negatives)

**Behavior:** (1) `src/prompts/conversation-mode-system.md` and `src/prompts/live-session-system.md` are NOT imported anywhere — there is no live/voice-conversation mode, no Gemini Live session. (2) `@google/genai` is in package.json but never imported. (3) No streaming display: `generateText` (not `streamText`) is used, so replies appear all at once. (4) No message editing, regeneration, copy buttons, or per-message timestamps in the UI (createdAt is stored but never displayed). (5) Voice mode has no "continuous"/live option — only off and push-to-talk.

## Data models

## TypeScript (src/stores/ai-store.ts — all in-memory + localStorage; camelCase)

```ts
type AiRole = "user" | "assistant";
type AiProvider = "gemini" | "openai" | "codex";
type VoiceMode = "off" | "push-to-talk";

interface AiMessage {
  id: string;          // crypto.randomUUID(), fallback `msg_${Date.now()}_${rand36(6)}`
  role: AiRole;
  content: string;
  createdAt: string;   // ISO 8601 (new Date().toISOString())
}

interface AiSettings {
  provider: AiProvider;   // default "gemini"
  model: string;          // Gemini model, default "gemini-3.1-flash-lite-preview"
  apiKey: string;         // Gemini key, default ""
  openaiModel: string;    // default "gpt-5.5"
  openaiApiKey: string;   // default ""
  codexModel: string;     // default "gpt-5.5"
  voiceMode: VoiceMode;   // default "off"
  ttsEnabled: boolean;    // default false
}

interface AiPageImageSnapshot {
  pageNumber: number;
  base64Data: string;   // raw base64, no data: prefix
  mediaType: string;    // "image/jpeg"
  width: number;
  height: number;
}

interface AiContextSnapshot {
  title: string | null;
  numPages: number;
  currentPage: number;
  visiblePages: number[];
  annotations: Annotation[];
  currentPageImage?: AiPageImageSnapshot | null;
}

type ToolAction =
  | { tool: "goToPage";     args: { pageNumber: number } }
  | { tool: "addNote";      args: { pageNumber: number; text: string; x?: number; y?: number } }
  | { tool: "addHighlight"; args: { pageNumber: number; text: string; color?: string } };

interface AiState {
  messages: AiMessage[];
  isThinking: boolean;
  error: string | null;
  pageTexts: Record<number, string>;   // 1-indexed page -> whitespace-normalized text
  settings: AiSettings;
  // actions: setSettings(patch), addLocalMessage(role, content, id?) -> id,
  // updateLocalMessage(id, content), setThinkingState(b), setErrorState(s|null),
  // loadConversationForDocument(doc|null), clearConversation(),
  // clearDocumentContext(), setPageText(page, text),
  // sendMessage(input, context) -> Promise<void>
}
```

Constants: `SETTINGS_STORAGE_KEY = "research-reader-ai-settings-v1"`, `CONVERSATIONS_STORAGE_KEY = "research-reader-ai-conversations-v1"`, `MAX_CONTEXT_CHARS = 120_000`, `DEFAULT_PAGE_WIDTH = 612`, `DEFAULT_PAGE_HEIGHT = 792`, `MAX_STORED_MESSAGES_PER_DOCUMENT = 120`, `MAX_STORED_MESSAGE_CHARS = 12_000`, `MAX_STORED_DOCUMENTS = 25`, `MAX_TOOL_ACTIONS = 5`, `SNAPSHOT_MAX_DIMENSION = 1280`, `SNAPSHOT_JPEG_QUALITY = 0.72`, default highlight color `"#fef08a"`, note default anchor `(x=72, y=96)`.

## Shared annotation types (src/types/index.ts — snake_case, mirror Rust)

```ts
interface Rect { x: number; y: number; width: number; height: number; }
interface PositionData {
  rects: Rect[];
  page_width: number;
  page_height: number;
  selected_text: string | null;
  start_offset: number | null;
  end_offset: number | null;
  prefix?: string | null;          // web-only text-quote context (~32 chars)
  suffix?: string | null;
  viewport_offset?: number | null; // web point bookmarks only
}
interface Annotation {
  id: string;
  type: "highlight" | "note" | "bookmark";
  page_number: number;
  color: string | null;
  content: string | null;
  position_data: PositionData | null;
  created_at: string;
  updated_at: string;
}
interface DocumentInfo {
  kind: "pdf" | "web";
  pdf_path: string;   // generic URI: fs path for PDFs, normalized URL for web
  title: string | null;
  page_count: number | null;
  last_page: number | null;
}
```

## Rust (src-tauri/src/commands.rs; serde snake_case)

```rust
#[derive(Debug, Deserialize)]
pub struct CodexAiImageInput {
    pub base64_data: String,
    pub media_type: String,
}
// run_codex_ai(prompt: String, model: String, image: Option<CodexAiImageInput>) -> Result<String, String>
```

## AI SDK tool input schemas (JSON Schema handed to the model)

```json
// goToPage — required: ["pageNumber"], additionalProperties: false
{ "pageNumber": { "type": "number", "description": "1-indexed page number to navigate to. Out-of-range values are clamped." } }

// addNote — required: ["pageNumber","text"], additionalProperties: false
{ "pageNumber": {"type":"number","description":"1-indexed page number for the note."},
  "text": {"type":"string","description":"Note body. Must be non-empty."},
  "x": {"type":"number","description":"Optional top-left x in PDF points (default 72)."},
  "y": {"type":"number","description":"Optional top-left y in PDF points (default 96)."} }

// addHighlight — required: ["pageNumber","text"], additionalProperties: false
{ "pageNumber": {"type":"number","description":"1-indexed page number for the highlight."},
  "text": {"type":"string","description":"Exact phrase to highlight, quoted verbatim from the page text. The app locates it; do not supply coordinates."},
  "color": {"type":"string","description":"Optional CSS color (e.g. #fef08a). Invalid values fall back to yellow."} }
```

Tool descriptions given to the SDK: goToPage — "Navigate the document viewport to a specific 1-indexed page."; addNote — "Create a sticky-note annotation with visible text on a page."; addHighlight — "Highlight an exact phrase on a page. Provide the verbatim text; the app locates and draws it."

## Persistence

All AI-subsystem persistence is **browser localStorage** (WebView-scoped). Nothing AI-related is written to the SQLite/annotation store beyond annotations the tools create (those go through the normal annotation persistence, owned by the annotations subsystem).

## Key 1: `research-reader-ai-settings-v1`

The full `AiSettings` object, JSON:

```json
{
  "provider": "gemini",
  "model": "gemini-3.1-flash-lite-preview",
  "apiKey": "AIza...user's key in PLAINTEXT...",
  "openaiModel": "gpt-5.5",
  "openaiApiKey": "sk-...plaintext...",
  "codexModel": "gpt-5.5",
  "voiceMode": "off",
  "ttsEnabled": false
}
```

Written on every `setSettings` call (each keystroke in the key field). Read once at store creation, spread over defaults; `provider` normalized ("codex"→codex, "openai"→openai, anything else→"gemini"); `voiceMode` normalized ("push-to-talk" or "off"). Parse errors → defaults. API keys are stored in plaintext.

## Key 2: `research-reader-ai-conversations-v1`

A single JSON object mapping **document key → message array**. Document key = `document.pdf_path.trim()` (filesystem path for PDFs, normalized URL for web pages); documents without a path are not persisted.

```json
{
  "/Users/me/papers/attention.pdf": [
    { "id": "3f0e...uuid", "role": "user", "content": "Summarize page 3", "createdAt": "2026-07-03T10:15:00.000Z" },
    { "id": "9a1b...uuid", "role": "assistant", "content": "Page 3 covers...\n\nActions:\n- Navigated to page 3.", "createdAt": "2026-07-03T10:15:08.412Z" }
  ],
  "https://example.com/article": [ ... ]
}
```

Write-time bounding (also applied on read): per document keep only the **last 120** messages; any content longer than **12,000** chars becomes `content.slice(0, 12000) + "\n[truncated]"`; saving an empty list **deletes** the document key; after insert, while more than **25** document keys exist, delete keys in `Object.keys()` iteration order (oldest-inserted first). Read-time sanitizing: entries must be objects with role "user"/"assistant" and string content; blank/missing id → fresh uuid; blank/missing createdAt → current ISO time; invalid entries dropped; empty docs omitted. All localStorage exceptions are swallowed (writes silently fail, reads fall back to `{}`/defaults).

## Ephemeral files (Codex path, Rust)

Per call, a `tempfile::tempdir()` containing: `codex-output-schema.json` (pretty-printed schema, see externalAPIs), optionally `current-page.jpg|png|webp` (decoded snapshot), and `codex-response.json` (written by codex via `--output-last-message`). The tempdir is dropped (deleted) when the call returns.

## Compatibility contract for the Swift port

The Swift app must key conversations by the exact same document URI string (`pdf_path`) if it wants to migrate/share history, and preserve the message JSON field names `id`, `role`, `content`, `createdAt` (camelCase) and settings field names as above. Since localStorage lives inside the Tauri WebView profile, a native port cannot read it in place — migration would require exporting from the WebView; otherwise reimplement the same schema in UserDefaults/files.

## IPC commands

One Tauri command is owned by this subsystem:

## `run_codex_ai`

- **JS wrapper** (`src/lib/tauri-commands.ts`): `runCodexAi(prompt: string, model: string, image?: CodexAiImageInput | null): Promise<string>` → `invoke("run_codex_ai", { prompt, model, image: image ?? null })`. Image arg shape (snake_case): `{ base64_data: string, media_type: string }`.
- **Behavior** (Rust, `commands.rs::run_codex_ai` → `spawn_blocking(run_codex_ai_blocking)`):
  1. Create temp dir; write `codex-output-schema.json` (pretty JSON):
  ```json
  {
    "type": "object", "additionalProperties": false,
    "properties": {
      "reply": { "type": "string" },
      "actions": { "type": "array", "items": {
        "type": "object", "additionalProperties": false,
        "properties": {
          "tool": { "type": "string", "enum": ["goToPage", "addNote", "addHighlight"] },
          "args": { "type": "object", "additionalProperties": false,
            "properties": {
              "pageNumber": { "type": "number" },
              "text":  { "type": ["string", "null"] },
              "color": { "type": ["string", "null"] },
              "x": { "type": ["number", "null"] },
              "y": { "type": ["number", "null"] }
            },
            "required": ["pageNumber", "text", "color", "x", "y"] }
        },
        "required": ["tool", "args"] } }
    },
    "required": ["reply", "actions"]
  }
  ```
  2. If image present: base64-decode (`STANDARD` engine, input trimmed) into `current-page.{ext}` where ext = png for `image/png`, webp for `image/webp`, else jpg.
  3. Model = trimmed input, empty → `"gpt-5.5"`.
  4. Spawn: `codex exec --model {model} --sandbox read-only --skip-git-repo-check --ephemeral --cd {tempdir} --output-schema {schema_path} --output-last-message {output_path} [--image {image_path}] -` with stdin/stdout/stderr piped; write the entire prompt to stdin then close it; wait for exit.
  5. Non-zero exit → Err `"Codex CLI exited with status {status}: {details}"` where details = stderr (or stdout if stderr blank) truncated to 1,200 chars with `...` appended.
  6. Read the `--output-last-message` file; fallback to captured stdout; trim; empty → Err `"Codex returned an empty response."`; else Ok(response).
- **Returns**: the model's final message — expected to be the JSON object matching the schema (parsed leniently on the JS side).
- **Errors**: all `Err(String)` (surfaced to JS as rejected promise; the store stringifies into the chat error message). Exact strings listed in the Codex feature entry.

No other IPC: Gemini/OpenAI calls go straight from the WebView to the provider HTTPS APIs via the Vercel AI SDK (fetch). Annotation creation from tools uses the annotation store's existing commands (`create_annotation` etc., owned by the annotations subsystem) via `useAnnotationStore.getState().addNote/addHighlight`; navigation uses the pdf-store's `goToPage` (pure frontend).

## External APIs

## Google Gemini — via `@ai-sdk/google` ^3.0.29 + `ai` ^6.0.86 (Vercel AI SDK)

- `createGoogleGenerativeAI({ apiKey })` — key from settings, sent as the `x-goog-api-key` header to `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` (the SDK's default endpoint; NOT the streaming variant — `generateText` is used, so a single non-streamed request per step).
- Call: `generateText({ model: google(modelName), system, messages: [{role:"user", content:[{type:"text",text}, {type:"image", image: base64, mediaType:"image/jpeg"}?]}], tools, stopWhen: stepCountIs(6), temperature: 0.2, maxRetries: 1 })`.
- Native function-calling: the SDK converts the three tool JSON schemas to Gemini functionDeclarations; tool `execute` callbacks run client-side and their string results are fed back; loop caps at 6 steps (≤5 tool actions honored app-side).
- Models offered in UI: gemini-3.1-flash-lite-preview (default), gemini-3-pro-preview, gemini-3-flash-preview, gemini-2.5-pro, gemini-2.5-flash, gemini-2.5-flash-lite, gemini-2.0-flash, gemini-2.0-flash-lite, gemini-1.5-pro, gemini-1.5-flash.

## OpenAI — via `@ai-sdk/openai` ^3.0.72

- `createOpenAI({ apiKey })`, model via `openai.responses(modelName)` → the **Responses API** (`POST https://api.openai.com/v1/responses`, `Authorization: Bearer {key}`), non-streaming.
- `providerOptions: { openai: { store: false } }` → request body `store: false` (no server-side conversation retention). No temperature param. `maxRetries: 1`, `stopWhen: stepCountIs(6)`, same tools/messages/image part.
- Models offered: gpt-5.5 (default), gpt-5.5-2026-04-23, gpt-5.4-mini, gpt-5.4, gpt-5, gpt-5-mini, gpt-4.1, gpt-4.1-mini.

## Codex CLI — local subprocess, no network from the app

- Uses the user's existing `codex` login; app passes `--sandbox read-only --skip-git-repo-check --ephemeral`, an output JSON schema, and optionally the page image. Models offered: gpt-5.5 (default), gpt-5.4-mini, gpt-5.3-codex-spark. Structured output enforced by `--output-schema`; final message read from `--output-last-message` file.

## Prompts (quoted verbatim)

Prompt templating (`src/lib/ai-prompts.ts`): templates are `.md` files imported raw, `.trim()`ed; `{{KEY}}` placeholders replaced with `String.replaceAll`; result trimmed. `tool-mode-system.md` has `{{TOOL_DESCRIPTIONS}}` pre-substituted with the trimmed contents of `tool-descriptions.md` at module load.

### System prompt for Gemini/OpenAI native tool path — `src/prompts/tool-mode-native.md` (used as-is, no substitutions):

```markdown
# Skill: PDF Assistant With Tool Calling

## Role
You are an AI research assistant embedded in a PDF reader.
You may receive a screenshot image of the current page for visual reasoning.
Use that image for charts, diagrams, layout cues, and tables when relevant.

## Objective
Answer the latest user request and take concrete UI actions when appropriate by
calling the tools provided to you. Use tools only when they materially help.

## Tool Selection Policy
- Use no tools when the user only needs explanation or analysis.
- Use `goToPage` for navigation intent.
- Use `addNote` for durable comments/reminders.
- Use `addHighlight` to mark important text/regions.
- Keep actions minimal and relevant (0 to 5 tool calls maximum).
- Never invent unsupported tools; only call the tools provided to you.

## Coordinate System (used by `addNote`)
- Coordinates are in PDF points with the origin at the **top-left** of the page.
- `x` increases to the right; `y` increases **downward**.
- A typical US Letter page is 612 wide x 792 tall.
- Omit any coordinate you are unsure about and a sensible default is used.

## `addHighlight` Guidance
- Provide the exact phrase to highlight, quoted verbatim from the page text. The
  app locates that phrase and draws the highlight over its real position, so you
  do NOT supply coordinates.
- Keep it to the specific phrase of interest; if the phrase does not appear on
  the page verbatim, the highlight is skipped.

## Response
After taking any actions, write a concise reply summarizing your reasoning and
what you did. If information is insufficient, explain the uncertainty in your
reply and take no actions.
```

### User message for the native path (`buildNativeToolUserPrompt`), exact join:

```
### Recent Conversation
{conversation}

### Document Context
{context}

### Latest User Request
{latestUserRequest}
```

### Codex/JSON path prompt — `src/prompts/tool-mode-system.md` with `{{CONVERSATION}}`, `{{CONTEXT}}`, `{{LATEST_USER_REQUEST}}` substituted:

```markdown
# Skill: Document Assistant With Tool Calling

## Role
You are an AI research assistant embedded in a document reader. The open
document is either a PDF or a webpage (blog post, research article).
You may receive a screenshot image of the current page for visual reasoning.
Use that image for charts, diagrams, layout cues, and tables when relevant.
For webpages, "pages" are virtual sections of the article split in reading
order; page numbers, navigation, and highlighting work the same way.

## Objective
Answer the latest user request and propose concrete UI actions when appropriate.
Use tools only when they materially help complete the request.

## Inputs You Receive
### Recent Conversation
{{CONVERSATION}}

### Document Context
{{CONTEXT}}

### Latest User Request
{{LATEST_USER_REQUEST}}

## Available Tools
{{TOOL_DESCRIPTIONS}}

## Tool Selection Policy
- Use no tools when the user only needs explanation or analysis.
- Use `goToPage` for navigation intent.
- Use `addNote` for durable comments/reminders.
- Use `addHighlight` to mark important text/regions.
- Keep actions minimal and relevant (0 to 5 actions maximum).
- Never invent unsupported tools.

## Output Contract (Strict)
Return exactly one JSON object with this shape:
```json
{
  "reply": "string",
  "actions": [
    {
      "tool": "goToPage | addNote | addHighlight",
      "args": {}
    }
  ]
}
```

## Output Rules
- Output must be valid JSON.
- Do not use markdown fences.
- Do not include commentary outside the JSON object.
- `reply` should summarize reasoning and what actions (if any) were chosen.
- If information is insufficient, explain uncertainty in `reply` and return an empty `actions` array.
```

### `{{TOOL_DESCRIPTIONS}}` — `src/prompts/tool-descriptions.md`:

```markdown
# Tool Skills Reference

These are the ONLY tools you may call. Never invent other tool names — any
unrecognized tool is discarded. A maximum of 5 actions run per response.

## Coordinate System (used by `addNote`)
- Coordinates are in PDF points with the origin at the **top-left** of the page.
- `x` increases to the right; `y` increases **downward**.
- A typical US Letter page is 612 wide x 792 tall. If you don't know the page
  size, assume those dimensions.
- All coordinates and sizes must be finite and non-negative. Omit any field you
  are unsure about and a sensible default is used instead.

## Tool: `goToPage`
### Purpose
Navigate the document viewport to a specific page.

### Use When
- The user asks to jump, move, navigate, or inspect a specific page.
- You need to guide the user to evidence located on another page.

### Input Schema
```json
{ "pageNumber": number }
```

### Notes
- `pageNumber` is 1-indexed (the first page is 1).
- Out-of-range values are clamped to the valid page range.
- Prefer exact page numbers when the request is explicit. If the request is
  vague, choose the most likely page and explain your choice in `reply`.

## Tool: `addNote`
### Purpose
Create a sticky-note annotation on a page with user-visible text.

### Use When
- The user asks to add a note, reminder, summary, TODO, or comment.
- You want to save an interpretation or action item into the document.

### Input Schema
```json
{
  "pageNumber": number,
  "text": string,
  "x"?: number,
  "y"?: number
}
```

### Notes
- `pageNumber` is 1-indexed; `text` is required and must be non-empty
  (empty-text notes are skipped). Keep it concise and useful.
- `x` / `y` place the note's top-left anchor (see Coordinate System). Omit them
  if placement is unclear; they default to (72, 96).
- Do not add empty or redundant notes.

## Tool: `addHighlight`
### Purpose
Create a highlight annotation over a specific run of text on a page.

### Use When
- The user asks to highlight text or visually mark important content.
- You identify a critical statement, value, or phrase worth emphasizing.

### Input Schema
```json
{
  "pageNumber": number,
  "text": string,
  "color"?: string
}
```

### Notes
- `pageNumber` is 1-indexed.
- `text` is REQUIRED: it is the exact phrase to highlight. The app locates that
  phrase in the page's text and draws the highlight over its real position — you
  do NOT supply any coordinates. Quote the phrase verbatim from the document
  (whitespace differences are tolerated, but spelling/words must match).
- Keep `text` to the specific phrase of interest. Highlighting an entire
  paragraph is rarely useful; pick the key sentence or term.
- If the phrase does not appear verbatim on that page, the highlight is skipped,
  so prefer text you can see in the provided page text.
- `color` must be a valid CSS color (hex like `#fef08a` preferred). Invalid
  values fall back to the default yellow.
```

### UNUSED prompt files (exist but never imported — do not wire up): `src/prompts/conversation-mode-system.md` ("Skill: PDF Live Conversation (No Tool Calls)") and `src/prompts/live-session-system.md` ("Skill: Gemini Live Turn Prompt"). Also `@google/genai` ^1.42.0 is an unused dependency.

## Porting notes

- **No streaming**: resist the urge to add token streaming. The current app shows "Thinking…" until the entire multi-step tool loop finishes, then the full reply appears at once. Match that. In Swift, one async call per send.
- **Providers**: Gemini and OpenAI are plain HTTPS from the client with the user's key — replicate with URLSession. For Gemini, POST `models/{model}:generateContent` with `x-goog-api-key`, functionDeclarations for the 3 tools, temperature 0.2, and run the tool loop yourself (send functionResponse parts back, max 6 model turns / 5 executed actions). For OpenAI use the **Responses API** (`/v1/responses`) with `store: false` and its function-tool format — not Chat Completions, since some listed models may be Responses-only. maxRetries 1 → at most one retry on transient failure. The Codex path is a subprocess (`Process` in Swift) — identical CLI flags work; note `--cd` pointing at the temp dir and prompt piped via stdin with `-`.
- **Tool results feed back to the model** in SDK mode: the strings like "Navigated to page 3." / "Skipped addHighlight: couldn't find \"x\" on page 2." are the tool-call results the model sees, AND they're appended to the visible chat as an "Actions:" bullet list. Keep both.
- **Highlight geometry**: `locateTextOnPage` maps to PDFKit almost directly — use `PDFDocument.findString` or `PDFPage.string` search on whitespace-stripped, case-insensitive text, then `PDFSelection.selectionsByLine()` to get per-line rects. Beware coordinate flip: the web app stores rects with **origin top-left, y down, PDF points at zoom 1** (`page_height − y − height` converts from PDFKit's bottom-left space). The stored `PositionData` must stay in the top-left space for compatibility with existing annotations. PDFKit's line-level selection is actually *more* precise than the web version's whole-text-item granularity; that difference is acceptable but note the web version can over-highlight slightly.
- **Note default anchor** (72, 96) is in top-left-origin PDF points; page_width/page_height are hardcoded 612×792 for tool-created notes regardless of the real page size — replicate exactly for data compatibility.
- **Web documents**: `addHighlight` on web docs delegates to a `window.__locateWebText(page, text)` bridge installed by the WebViewer content script, which may return a different virtual page than requested — the annotation is filed under the returned page and `selected_text` is overwritten with the query. In the Swift port this becomes a WKWebView `evaluateJavaScript`/message-handler round trip.
- **Snapshot capture**: replaces canvas-scraping with PDFKit's `PDFPage.thumbnail(of:for:)` or drawing into a CGContext — cap max dimension at 1280 px, JPEG quality 0.72, and pass base64 to the model (Gemini inline_data / OpenAI input_image). For web docs the current app effectively sends no image (no canvas); match that or take a WKWebView snapshot only if you accept a behavior difference (recommend matching: none).
- **Voice**: Web Speech API → SFSpeechRecognizer + AVAudioEngine (request mic + speech permissions; locale en-US; single-shot, no partials needed since interimResults=false). Transcript is appended to the input field, never auto-sent. TTS → AVSpeechSynthesizer with default voice, rate/pitch defaults; cancel current speech before speaking; track last-spoken message id so a message is spoken once. Note the quirk: TTS speaks raw markdown (asterisks etc. are in the string; the web utterance gets the raw content) — decide consciously; exact parity means passing the raw content string.
- **Persistence**: localStorage → UserDefaults or JSON files. Keep the exact JSON schemas and limits (120 msgs/doc, 12k chars/msg + "\n[truncated]", 25 docs) if you want importability. The 25-doc eviction relies on JS object key insertion order — in Swift use an ordered structure (array of entries) to replicate oldest-first eviction; a plain Dictionary loses order.
- **Tab-switch safety**: every send captures the active tab/session id; tool actions and final state updates are skipped/dropped if the active tab changed mid-flight (but the conversation is still *persisted* for the originating document — only the in-memory UI update is skipped). Replicate with a captured session token compared at each step.
- **API keys in plaintext**: the web app stores keys in localStorage. On macOS prefer Keychain, but that's a deliberate deviation; flag it.
- **KaTeX/markdown**: no native equivalent renders react-markdown+KaTeX out of the box. Options: swift-markdown-ui for GFM plus SwiftMath/iosMath for LaTeX spans (remark-math syntax: `$...$`, `$$...$$`), or a WKWebView-based message renderer to guarantee identical output. Match the style overrides (12px code font on black/15 background, 92% max bubble width, etc.) rather than library defaults.
- **Do NOT port**: Gemini Live / conversation-mode prompts (dead files), `@google/genai` (unused), any streaming, message timestamps in UI.
- Key sources: `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/stores/ai-store.ts`, `src/components/ai/AiPanel.tsx`, `src/components/ai/MarkdownMessage.tsx`, `src/lib/ai-prompts.ts`, `src/lib/highlight-locator.ts`, `src/prompts/*.md`, `src/lib/tauri-commands.ts` (runCodexAi), `src-tauri/src/commands.rs` (run_codex_ai, codex_output_schema), `src/App.tsx` (panel host + document-change lifecycle), `src/components/pdf/PdfViewer.tsx` + `src/components/web/WebViewer.tsx` (pageTexts feeding).

