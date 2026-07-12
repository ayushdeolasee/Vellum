> **HISTORICAL — all findings below are RESOLVED as of commit `314cf9f` (verified 2026-07-12).**
> Shift-shortcuts: fixed in `Vellum/App/ContentView.swift`. Open-file handling: fixed via
> `VellumAppDelegate` in `Vellum/App/VellumApp.swift`. Gemini `additionalProperties` and
> OpenAI `strict`: removed from the current clients. SpeechService 0-Hz tap: guarded.
> Codex-CLI findings: obsolete (provider no longer exists). Paths below use the old
> `macos/` prefix; the app now lives at the repo root.

# Confirmed review findings (adversarially verified) — fix list

## Finding 1
FINDING [minor] Shifted command shortcuts trigger in the port but not in the original (⌘⇧B, ⌘⇧S, ⌘⇧O, ⌘⇧L, shift+N)
File: macos/Vellum/App/ContentView.swift:152
Claim: The original matches `e.key` case-sensitively for most shortcuts — with Shift held, e.key is 'B'/'S'/'O'/'L'/'N' so ⌘⇧B does NOT toggle the bookmark, ⌘⇧S does not save, and shift+N does not toggle note mode (only ⌘W is explicitly lowercased). The Swift port lowercases charactersIgnoringModifiers for every shortcut and never excludes .shift, so all shift-modified variants fire and are swallowed (return true), e.g. ⌘⇧B toggles the bookmark and shift+N enters note mode where the original does nothing.
Evidence: Original (src/App.tsx): `if (isCtrl && e.key === "b")`, `if (isCtrl && e.key === "s")`, `if (e.key === "n" && !isCtrl ...)` — but `if (isCtrl && e.key.toLowerCase() === "w")` shows lowercasing was deliberate for W only.
Port (ContentView.swift:150-201):
```swift
let key = (event.charactersIgnoringModifiers ?? "").lowercased()
...
if command && key == "b" { ... return true }
if !command && !modifiers.contains(.control) && key == "n" { ... }
```
charactersIgnoringModifiers for shift+B is "B", lowercased to "b" — matches; shift is never checked.

**Verifier reasoning:** The difference is real and unsanctioned. Original src/App.tsx matches e.key case-sensitively for o/l/s/b/n/=/-/digits (with Shift held e.key is the uppercase letter, so shifted variants do nothing); only W is deliberately lowercased (e.key.toLowerCase() === "w"). The port (macos/Vellum/App/ContentView.swift:152) lowercases charactersIgnoringModifiers for all shortcuts and never excludes .shift — charactersIgnoringModifiers preserves shift-case ("B" for ⌘⇧B), so lowercasing makes ⌘⇧B/⌘⇧S/⌘⇧O/⌘⇧L and shift+N fire and get swallowed (return true). The specs confirm the original contract rather tha

**Fix hint:** In ContentView.swift handleKeyDown, stop blanket-lowercasing: use `let key = event.charactersIgnoringModifiers ?? ""` (preserves shift-case, mirroring e.key) and match "o"/"l"/"s"/"b"/"n"/"="/"-"/digits against that, keeping only the ⌘W check case-insensitive (`key.lowercased() == "w"`). Equivalently, add `!modifiers.contains(.shift)` as a guard on every shortcut except ⌘W.

## Finding 2
FINDING [major] Registered document types are not handled when opened by macOS
File: macos/Vellum/Resources/Info.plist
Claim: The bundle advertises itself as an editor for PDFs and the owner of .vellumweb files, but the SwiftUI app has no open-file application delegate or onOpenURL handler. Finder/Open With launches Vellum without opening the selected document.
Evidence: Info.plist:38-64 registers both document types. VellumApp.swift:24-38 only constructs ContentView and defines no external file-opening handler.

**Verifier reasoning:** The claimed behavior is verified: Info.plist (macos/Vellum/Resources/Info.plist:38-84) registers com.adobe.pdf (Alternate) and declares/claims Owner of com.vellum.vellumweb, while the app (macos/Vellum/App/VellumApp.swift) has no NSApplicationDelegateAdaptor, no .onOpenURL, no DocumentGroup, and no application(_:open:) anywhere in the Swift sources — so Finder double-click/Open With launches Vellum to the welcome screen without opening the document. This cannot be refuted as 'original behaves the same': the original Tauri app registers no fileAssociations (src-tauri/tauri.conf.json has none) a

**Fix hint:** Minimal spec-conformant fix: delete the CFBundleDocumentTypes and UTExportedTypeDeclarations entries from macos/Vellum/Resources/Info.plist (SPECS-app-shell.md:260 says no file-type association handling exists in the app). Alternatively, if file associations are wanted as an intentional enhancement, keep the plist and add handling in VellumApp.swift — e.g. an @NSApplicationDelegateAdaptor whose application(_:open:) forwards URLs to appStore.openFiles(paths: urls.map(\.path)), which already routes .vellumweb vs .pdf correctly.

## Finding 3
FINDING [minor] Annotation sidebar highlight swatch is theme-mapped in dark mode; original always shows the stored light color
File: macos/Vellum/Views/Annotations/AnnotationSidebar.swift:295
Claim: The original sidebar renders the highlight color dot with the raw persisted hex (`style={{ backgroundColor: annotation.color }}`) in both themes — in dark mode the dot stays the bright light-theme pastel (e.g. #fef08a). The Swift row passes the color through `themeStore.highlightRenderColor(for:)`, which in dark mode substitutes the 50%-alpha dark variant (e.g. #854d0e80), so the swatch looks visibly different (darker, translucent) from the Tauri app in dark mode. No deviation comment marks this as intentional for the sidebar.
Evidence: Original (src/components/annotations/AnnotationSidebar.tsx):
```tsx
<div className="h-4 w-4 rounded-full ring-1 ring-border-strong"
     style={{ backgroundColor: annotation.color }} />
```
Port (AnnotationSidebar.swift:293-299):
```swift
if annotation.type == .highlight, annotation.color != nil {
    Circle().fill(themeStore.highlightRenderColor(for: annotation.color))
```
Theme.swift:153-162: `if theme == .dark, let match = HIGHLIGHT_COLORS.first(...) { return Color(hex: match.dark) }`.

**Verifier reasoning:** The claimed difference is real and confirmed on both sides. Original (src/components/annotations/AnnotationSidebar.tsx:171-174) renders the sidebar dot with the raw persisted hex (`backgroundColor: annotation.color`) in both themes; a repo-wide search shows the `dark` field of HIGHLIGHT_COLORS is never consumed anywhere in the original app (src/, src-tauri/, CSS, content script). The spec explicitly documents this: SPECS-annotations.md line 112 says "`dark` variants exist but this subsystem's UI only uses `value`", and its sidebar UI spec (line 48) says the 16x16 dot uses backgroundColor = ann

**Fix hint:** In AnnotationSidebar.swift's marker view, fill the circle with the raw stored hex instead of the theme-mapped color: replace `.fill(themeStore.highlightRenderColor(for: annotation.color))` with `.fill(Color(hex: annotation.color ?? "#fef08a"))` (the nil-guard on annotation.color already exists in the enclosing `if`). If highlightRenderColor then has no remaining callers, remove it from Theme.swift.

## Finding 4
FINDING [critical] Gemini requests include `additionalProperties` in functionDeclarations parameters, which the Gemini API rejects — default provider broken
File: macos/Vellum/Services/Ai/GeminiClient.swift:136
Claim: The port sends `"additionalProperties": false` inside each function declaration's `parameters` object on every generateContent call. Gemini's `FunctionDeclaration.parameters` is a proto `Schema` (OpenAPI subset) that has NO `additionalProperties` field (the current @google/genai Schema type lists anyOf/default/description/enum/example/format/items/min*/max*/nullable/pattern/properties/propertyOrdering/required/title/type only; full JSON Schema including `additionalProperties` is only accepted via the separate `parametersJsonSchema` field). Google's API frontend rejects unknown fields with 400 "Invalid JSON payload received. Unknown name 'additionalProperties'... Cannot find field." The original never sends it: @ai-sdk/google's convertJSONSchemaToOpenAPISchema copies only a whitelist of fields (type, description, required, properties, items, allOf/anyOf/oneOf, format, const, minLength, enum) and drops `additionalProperties`. Since tools are attached to every request and Gemini is the default provider, every AI message with Gemini fails with an error banner instead of getting a reply.
Evidence: Swift (GeminiClient.swift:132-137, repeated at 151 and 165): "parameters": [ "type": "object", "properties": [...], "required": ["pageNumber"], "additionalProperties": false ]. Original path (@ai-sdk/google@3.0.29 dist/index.mjs:811-814): functionDeclarations.push({ ..., parameters: convertJSONSchemaToOpenAPISchema(tool.inputSchema) }) where convertJSONSchemaToOpenAPISchema (line 254) destructures only { type, description, required, properties, items, allOf, anyOf, oneOf, format, const, minLength, enum } — `additionalProperties` from ai-store.ts's jsonSchema definitions (ai-store.ts:481 `additionalProperties: false`) is stripped before the request. @google/genai genai.d.ts Schema interface (line 11190) contains no additionalProperties field; it is only documented for `parametersJsonSchema` (line 4434).

**Verifier reasoning:** The finding is CONFIRMED empirically, not just by reading types. (1) Port side: /Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/macos/Vellum/Services/Ai/GeminiClient.swift lines 136, 151, 165 include "additionalProperties": false inside each function declaration's parameters, and line 35 attaches these tools to every generateContent request, so every Gemini message hits this. (2) Original side: verified in the actually-installed @ai-sdk/google@3.0.29 (~/Developer/Vellum/main/node_modules/@ai-sdk/google/dist/index.mjs, convertJSONSchemaToOpenAPISchema at line 254) — it destructur

**Fix hint:** Remove the three "additionalProperties": false entries from the parameters dictionaries in GeminiClient.functionDeclarations (macos/Vellum/Services/Ai/GeminiClient.swift lines 136, 151, 165). Gemini's Schema proto accepts the remaining fields (type/properties/required/description). Do NOT touch OpenAIClient — the OpenAI Responses API accepts (and with strict mode expects) additionalProperties.

## Finding 5
FINDING [major] WindowGroup creates unsupported shared-state multi-window sessions
File: macos/Vellum/App/VellumApp.swift
Claim: The original is single-window, but WindowGroup permits additional windows while all windows share the same app-level stores and session manager. Multiple windows therefore control the same tabs, viewport, and annotations and install competing keyboard monitors.
Evidence: Lines 5-21 create one shared set of stores; lines 24-37 expose them through WindowGroup. ContentView.swift:68 and 133-137 install a local key monitor per window. SPECS-app-shell.md specifies a single window.

**Verifier reasoning:** The original app is provably single-window: src-tauri/tauri.conf.json defines exactly one window and SPECS-app-shell.md line 260 explicitly lists "no multi-window support in the current app" under "No-ops to NOT invent" — the spec forbids rather than sanctions this deviation. The port's VellumApp.swift uses WindowGroup with no Window scene, no .commands removal of the New Window item, and no AppDelegate restriction, so macOS automatically exposes File > New Window (Cmd+N). ContentView's local key monitor does not intercept Cmd+N (it handles only Cmd+O/L/S/W/1-9/=/-/B, Escape, plain n, and retu

**Fix hint:** In macos/Vellum/App/VellumApp.swift, replace `WindowGroup { ... }` with the single-instance `Window("Vellum", id: "main") { ... }` scene (macOS 13+), which removes the File > New Window command automatically; alternatively keep WindowGroup and add `.commands { CommandGroup(replacing: .newItem) {} }` to strip the New Window menu item.

## Finding 6
FINDING [minor] Gemini candidate with empty/missing parts (safety block, MAX_TOKENS) throws an error instead of the graceful fallback reply
File: macos/Vellum/Services/Ai/GeminiClient.swift:45
Claim: When a 200 response contains a candidate whose `content` lacks `parts` (Gemini returns this for safety-blocked or zero-token responses: content = {"role": "model"} with a finishReason), the port throws "Gemini returned an invalid response.", so the user sees the error banner plus an "I couldn't complete that request: ..." assistant message. The original AI SDK path tolerates missing parts and yields empty text, so finalizeReply produces the calm "I couldn't produce a response." assistant reply with no error state.
Evidence: Swift (GeminiClient.swift:45-50): guard let candidates ..., let content = candidate["content"] as? [String: Any], let parts = content["parts"] as? [[String: Any]] else { throw AiClientError.message(..."Gemini returned an invalid response.") }. Original: generateText returns text "" for a parts-less candidate (no throw), then ai-store.ts:653-659 finalizeReply: `if (trimmed) return trimmed; return actionResults.length > 0 ? "Done." : "I couldn't produce a response.";` — rendered as a normal assistant message, error stays null.

**Verifier reasoning:** The port (GeminiClient.swift:45-50) throws AiClientError("Gemini returned an invalid response.") whenever candidates[0].content.parts is absent, which surfaces as an error banner plus an "I couldn't complete that request: ..." message via AiStore.swift:254-266. The original uses @ai-sdk/google; I inspected the exact lockfile-pinned version 3.0.29 (package-lock.json) — its response schema declares content as `getContentSchema().nullish().or(z.object({}).strict())` with `parts` nullish, and its doGenerate mapper does `candidate.content?.parts ?? []`, so a safety-blocked or zero-token candidate (

**Fix hint:** In GeminiClient.swift, only require a non-empty candidates array in the guard; treat missing content/parts as empty instead of throwing: `let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []`. With empty parts, text is "" and calls is empty, so the existing path returns finalize("", actions) — "I couldn't produce a response." / "Done." — matching the original.

## Finding 7
FINDING [major] Web selection highlight and note actions always no-op
File: macos/Vellum/Views/Web/WebNotePopovers.swift
Claim: The popover clears the controller selection before invoking the highlight or note callback. Both callbacks then require that now-cleared selection, so web selections cannot create annotations.
Evidence: Lines 419-422 and 481-485 call onClose() before onHighlight/onNote. WebViewerView.swift:327-351 makes onClose clear selection, while addHighlight/addSelectionNote immediately guard on that selection.

**Verifier reasoning:** Confirmed by reading both sides. In WebNotePopovers.swift the swatch action executes onClose() before onHighlight(color.value), and submitNote() executes onClose() before onNote(trimmed). In WebViewerView.swift:76-81 onClose is controller.clearSelection(), which synchronously sets controller.selection = nil; onHighlight/onNote invoke controller.addHighlight/addSelectionNote (WebViewerView.swift ~lines 330-355), which both begin with `guard let selection ... else { return }` re-reading the now-nil controller.selection, so they no-op on every invocation — there is no async gap or state restorati

**Fix hint:** In WebNotePopovers.swift, invoke the action before closing: in the swatch button call `onHighlight(color.value)` then `onClose()`, and in submitNote() call `onNote(trimmed)` then `onClose()`. (Equivalent alternative: pass the captured WebSelection into WebSelectionPopover / the callbacks so addHighlight/addSelectionNote don't re-read controller.selection after clearing.)

## Finding 8
FINDING [critical] Creating a highlight or note from a web text selection silently does nothing (selection cleared before it is read)
File: macos/Vellum/Views/Web/WebNotePopovers.swift:420
Claim: In the original React SelectionPopover, clicking a color swatch calls onClose() first, but the annotation is created from the `selection` PROP the component already captured, so the highlight is still saved. The Swift port replicated the call order (onClose() then onHighlight/onNote) but NOT the data capture: onClose -> controller.clearSelection() sets controller.selection = nil, and then controller.addHighlight/addSelectionNote begin with `guard let selection ... else { return }` and read that same (now nil) property. Result: on webpage tabs, clicking any highlight color in the selection popover, and submitting a note from the popover's note input, both dismiss the popover and create nothing — no annotation is written to the sidecar, no error is shown. The manual selection-highlight and selection-note features on web pages are completely broken (AI-driven highlights via locateWebText are unaffected).
Evidence: Swift WebNotePopovers.swift SwatchButton wiring (lines 418-423):
    ForEach(HIGHLIGHT_COLORS) { color in
        SwatchButton(color: color) {
            onClose()
            onHighlight(color.value)
        }
    }
and submitNote (lines 481-486): `onClose(); onNote(trimmed)`.
WebViewerView.swift passes `onClose: { controller.clearSelection() }` and `onHighlight: { color in controller.addHighlight(color: color) }` (lines 75-81); controller (lines 327-341):
    func clearSelection() {
        selection = nil
        popoverPosition = nil
        post("clear-selection")
    }
    func addHighlight(color: String) {
        guard let selection, let annotationStore else { return }   // selection is already nil here
Original src/components/annotations/SelectionPopover.tsx (lines 27-35) captures the data before closing:
    const handleHighlight = (color: string) => {
      onClose();
      void addHighlight({ ... position_data: selection.positionData });  // `selection` is a prop captured at render
    };

**Verifier reasoning:** Confirmed, not refuted. In macos/Vellum/Views/Web/WebNotePopovers.swift the WebSelectionPopover swatch action runs `onClose(); onHighlight(color.value)` (lines 419-422) and submitNote runs `onClose(); onNote(trimmed)` (lines 484-485), all synchronously. WebViewerView.swift wires onClose to controller.clearSelection(), which sets controller.selection = nil (line 328) before controller.addHighlight/addSelectionNote run; both begin with `guard let selection, let annotationStore else { return }` (lines 334, 345), so the guard always fails and no annotation is ever created — silent no-op on every w

**Fix hint:** In WebNotePopovers.swift (WebSelectionPopover), invoke the action before closing: change the swatch callback to `onHighlight(color.value); onClose()` and submitNote to `onNote(trimmed); onClose()`. (Equivalently, have the controller snapshot `selection` into a local before clearing, mirroring the PDF-side SelectionPopover which builds the input from the captured selection before onClose.)

## Finding 9
FINDING [minor] SpeechService.installTap crashes with an NSException when the input node has a 0 Hz format (no input device / mic denied)
File: macos/Vellum/Services/Ai/SpeechService.swift:41
Claim: startRecognition checks SFSpeechRecognizer authorization but never checks microphone availability/authorization or the tap format. On a Mac with no input device, or when microphone access is denied/the format is invalid, inputNode.outputFormat(forBus: 0) returns a 0 Hz / 0-channel format, and AVAudioEngine's installTap(onBus:bufferSize:format:) raises an Objective-C exception ('required condition is false: format.sampleRate > 0' / IsFormatSampleRateAndChannelCountValid) that Swift cannot catch — the app crashes as soon as the user presses the push-to-talk mic button in that environment. The subsequent audioEngine.start() throw is handled, but the tap installation two lines earlier is not guardable and needs a format.sampleRate > 0 / channelCount > 0 pre-check.
Evidence: SpeechService.swift:38-44 `let inputNode = audioEngine.inputNode
let format = inputNode.outputFormat(forBus: 0)
inputNode.removeTap(onBus: 0)
inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { … }
audioEngine.prepare()
do { try audioEngine.start() } catch { … }` — only start() is wrapped in do/catch; installTap with an invalid format traps via NSException before start() is reached. Reached from AiPanel.swift:229-241 startListening() on the push-to-talk gesture.

**Verifier reasoning:** Confirmed real. SpeechService.startRecognition (macos/Vellum/Services/Ai/SpeechService.swift:38-43) takes inputNode.outputFormat(forBus: 0) and passes it unchecked to installTap; only audioEngine.start() two lines later is in a do/catch. On macOS with no input device, the input node's format is 0 Hz/0 channels and installTap raises the uncatchable NSException 'required condition is false: IsFormatSampleRateAndChannelCountValid(format)', crashing the app. Neither of the existing guards (recognizer.isAvailable, SFSpeechRecognizer authorization) depends on mic hardware, and no AVCaptureDevice/mic

**Fix hint:** In startRecognition, after `let format = inputNode.outputFormat(forBus: 0)`, add: `guard format.sampleRate > 0, format.channelCount > 0 else { throw SpeechServiceError.unavailable }` — this surfaces the existing "Speech recognition is not available in this environment." error (matching the web app's graceful no-mic behavior) instead of crashing. Optionally also request AVCaptureDevice.requestAccess(for: .audio) before engine setup, per SPECS-ai.md:577.

## Finding 10
FINDING [critical] OpenAI function tools sent with `strict: true` but schemas have optional keys missing from `required` — every OpenAI request rejected with 400
File: macos/Vellum/Services/Ai/OpenAIClient.swift:146
Claim: The port adds `"strict": true` to all three function tools (lines 146, 161, 175), but the addNote schema declares optional `x`/`y` not listed in `required` (only pageNumber, text) and addHighlight declares optional `color` not in `required`. OpenAI strict mode requires `required` to include every key in `properties`, and validates this at request time, returning 400 "Invalid schema for function 'addNote': ... 'required' is required to be supplied and to include every key in properties". The original omits `strict` entirely: @ai-sdk/openai's prepareFunctionTool only emits strict when explicitly set (`...tool.strict != null ? { strict: tool.strict } : {}`), and the store never sets it, so the API treats the schema non-strictly and accepts it. Result: every OpenAI-provider message in the port fails on the first request, before any model output.
Evidence: Swift (OpenAIClient.swift:148-162): addNote tool — "properties": [pageNumber, text, x, y], "required": ["pageNumber", "text"], "strict": true (same pattern for addHighlight with optional color, line 163-176). Original (@ai-sdk/openai@3.0.72 dist/index.mjs:4829-4842): prepareFunctionTool returns { type: "function", name, description, parameters: tool.inputSchema, ...tool.strict != null ? { strict: tool.strict } : {} } — strict omitted since ai-store.ts's tool()/jsonSchema definitions (ai-store.ts:472-518) never set strict. OpenAI openapi.yaml FunctionTool.strict: "Whether to enforce strict parameter validation" (nullable; omitted ⇒ non-strict validation, which is why the original's optional x/y/color schemas work).

**Verifier reasoning:** Verified on both sides. Port: macos/Vellum/Services/Ai/OpenAIClient.swift sends "strict": true on all three function tools (lines 146, 161, 175) while addNote declares optional x/y (required only ["pageNumber","text"], lines 148-162) and addHighlight declares optional color (required only ["pageNumber","text"], lines 163-176). OpenAI strict mode requires `required` to list every key in `properties` (optionality must be expressed via a null union type) and validates this server-side at request time, returning 400 before any model output. The tools array is included in every request (line 32) an

**Fix hint:** Remove the three `"strict": true` entries from `Self.functionTools` in macos/Vellum/Services/Ai/OpenAIClient.swift (lines 146, 161, 175), matching the original which omits strict. (Alternative, if strict mode is desired: list every property in `required` and change optional fields x/y/color to nullable types, e.g. "type": ["number", "null"] — but omitting strict is the minimal parity-preserving fix.)

## Finding 11
FINDING [major] PdfViewerView.teardown unconditionally nils the shared handler slots, killing the replacement web viewer's scroll/locate handlers on PDF→web tab switch
File: macos/Vellum/Views/PDF/PdfViewerView.swift:116
Claim: The handler slots on AppStore/AiStore (scrollToPageHandler, zoomToHandler, locate/capture handlers) are shared between the PDF and web viewers. When switching from a PDF tab to a web tab, SwiftUI inserts the new WebViewerView (onAppear → controller.attach registers app.scrollToPageHandler et al. synchronously) and then fires the removed PdfViewerView's onDisappear → teardown() → unregisterHandlers(), which sets app.scrollToPageHandler = nil, app.zoomToHandler = nil, aiStore.locatePdfTextHandler = nil, aiStore.capturePageImageHandler = nil with no ownership check — clobbering the registration the web viewer just made. Result: in the web tab, goToPage/scroll-to-page (toolbar page field, sidebar 'jump to annotation', AI goToPage tool) silently do nothing until the tab is remounted. WebViewerController.detach explicitly guards against this exact race ('Only clear the shared handler slots when no replacement viewer has taken over'), proving the hazard is real; PdfViewerView has no such guard. teardown() also calls aiStore.clearDocumentContext() unconditionally, which can wipe context belonging to the incoming document.
Evidence: PdfViewerView.swift:116-121 `private func unregisterHandlers() {
    app.zoomToHandler = nil
    app.scrollToPageHandler = nil
    aiStore.locatePdfTextHandler = nil
    aiStore.capturePageImageHandler = nil
}` called from teardown() (line 123-128) in `.onDisappear { teardown() }` (line 33), with no tab-ownership check. Contrast WebViewerView.swift:294-300 (detach): `// Only clear the shared handler slots when no replacement viewer has taken over…
if let app, app.activeTabId == mountTabId || app.document == nil {
    app.scrollToPageHandler = nil
    …
}`. WebViewerController.attach registers synchronously in onAppear (WebViewerView.swift:135-137, 266-277).

**Verifier reasoning:** CONFIRMED. (1) ContentView.swift:72-81 swaps PdfViewerView/WebViewerView in an if/else keyed by document kind. (2) I empirically verified SwiftUI's ordering by compiling and running a minimal repro of this exact pattern on this machine: the incoming view's onAppear fires BEFORE the outgoing view's onDisappear ("WebV onAppear" then "PdfV onDisappear"). (3) WebViewerController.attach runs synchronously in onAppear (WebViewerView.swift:135-136) and registers app.scrollToPageHandler (line 266); attach is guarded by an `attached` flag so it never re-registers. (4) PdfViewerView.teardown() → unregis

**Fix hint:** Mirror WebViewerController.detach's ownership guard in PdfViewerView: record the tabId the handlers were registered for (e.g. store mountTabId when registerHandlers() runs in load()), and in teardown() only call unregisterHandlers()/clearDocumentContext() when `app.activeTabId == mountTabId || app.document == nil`. Keep the unconditional unregisterHandlers() at the top of load() (safe, since it immediately re-registers for the new document).

## Finding 12
FINDING [major] URL normalization diverges from rust-url: empty path segments are collapsed and IDN hosts are not punycoded, changing the sha256 storage key / document identity
File: macos/Vellum/Services/Web/WebPageExtractor.swift:176
Claim: The spec makes normalized-URL output a hard compatibility contract ("sha256 must be over the identically normalized URL"). Two confirmed divergences from the Rust `url` crate: (1) WebUrl.normalizePath drops empty path segments (`if segment.isEmpty { endsWithSlash = true; continue }`), so `https://example.com/a//b` normalizes to `https://example.com/a/b`, while rust-url (WHATWG) preserves `/a//b`. (2) Non-ASCII hostnames are only lowercased, while rust-url applies IDNA/punycode: `https://münchen.de/path` -> Swift `https://münchen.de/path` vs Rust `https://xn--mnchen-3ya.de/path`. Consequences: for any affected URL the sidecar key (`web/<sha256>.json`), snapshot, managed .vellumweb, archives/<key>/ dir, recents entry and AI-conversation key all differ from what the Tauri app wrote, so migrated annotations/library entries are unreachable (and vice versa); distinct URLs `/a//b` and `/a/b` also collapse into one record in the port, cross-contaminating annotations; live fetch and .vellumweb import of Tauri-written archives for IDN URLs bind to a different identity. (Host validation/IPv4 normalization gaps exist too but are rarer.)
Evidence: Swift (verified by compiling WebUrl and running it):
  https://example.com//foo/bar -> https://example.com/foo/bar
  https://münchen.de/path      -> https://münchen.de/path
rust-url 2.x (verified with cargo):
  https://example.com//foo/bar -> https://example.com//foo/bar
  https://münchen.de/path      -> https://xn--mnchen-3ya.de/path
Swift WebPageExtractor.swift normalizePath (lines 176-180):
    if segment.isEmpty {
        endsWithSlash = true
        continue
    }
and host handling (line 105): `host = host.lowercased()` (no IDNA).
Rust web_page.rs normalize_url (line 117) delegates to `Url::parse`, which implements WHATWG parsing incl. IDNA and empty-segment preservation; page_key (line 142) hashes that exact string.

**Verifier reasoning:** Both claimed divergences are real and I reproduced them empirically on both sides. Swift: extracted the WebUrl enum from macos/Vellum/Services/Web/WebPageExtractor.swift, compiled it with swiftc, and ran it — `https://example.com/a//b` -> `https://example.com/a/b` (empty segments dropped by the `if segment.isEmpty { endsWithSlash = true; continue }` branch at lines 176-180) and `https://münchen.de/path` -> `https://münchen.de/path` (line 105 only does `host.lowercased()`, no IDNA). Rust: built a scratch cargo project with `url = "2"` (same dep spec as src-tauri/Cargo.toml line 32, default feat

**Fix hint:** In WebUrl.normalizePath (WebPageExtractor.swift ~line 176), preserve empty segments instead of skipping them: append the empty string to `segments` (percent-encoding of "" is "") so `/a//b` serializes as `/a//b`, keeping dot-segment handling as-is (WHATWG keeps empty segments; only "." and ".." are elided). For the host (line 105), apply IDNA/punycode after lowercasing: if a label contains non-ASCII, NFC-normalize + UTS#46-map it and encode with an RFC 3492 punycode encoder to `xn--...` (and reject hosts whose labels fail encoding), so `münchen.de` becomes `xn--mnchen-3ya.de` to match rust-url's serialization. Add parity tests against the Rust outputs for `https://example.com/a//b` and `https://münchen.de/path`.

## Finding 13
FINDING [minor] Export success message rounds to 1 decimal instead of 2, and the filename slug accepts non-ASCII characters
File: macos/Vellum/Views/PDF/ToolbarView.swift:379
Claim: Two copy-level differences in the .vellumweb export flow. (1) Size string: original formats bytes with toFixed(2) ('Exported 1.25 MB (...)'); Swift uses %.1f ('Exported 1.2 MB (...)'). (2) Default filename slug: original strips everything outside ASCII [a-z0-9] ('Café résumé' -> 'caf-r-sum.vellumweb'); Swift uses CharacterSet.alphanumerics which keeps Unicode letters ('café-résumé.vellumweb'), so default export filenames differ for non-ASCII titles.
Evidence: Original (src/components/pdf/Toolbar.tsx):
```ts
const sizeMb = (summary.bytes / (1024 * 1024)).toFixed(2);
...
const slug = (doc.title ?? "").toLowerCase().replace(/[^a-z0-9]+/g, "-")...
```
Port (ToolbarView.swift:379, 394-396):
```swift
let mb = String(format: "%.1f", Double(summary.bytes) / (1024 * 1024))
...
if CharacterSet.alphanumerics.contains(scalar) { slug.unicodeScalars.append(scalar) ... }
```

**Verifier reasoning:** Verified both sides. (1) Original Toolbar.tsx:158 formats export size with toFixed(2); ToolbarView.swift:379 uses "%.1f" — e.g. 1,310,720 bytes shows "1.25 MB" in the original vs "1.2 MB" in the port. (2) Original slug (Toolbar.tsx:136-141) uses /[^a-z0-9]+/g, which is ASCII-only, so "Café résumé" → "caf-r-sum"; the Swift slugifiedTitle() (ToolbarView.swift:394-401) uses CharacterSet.alphanumerics, which includes Unicode letters and digits, yielding "café-résumé" — default export filenames differ for any non-ASCII title. Neither deviation is sanctioned: SPECS-pdf-viewing.md:66 describes the fo

**Fix hint:** In macos/Vellum/Views/PDF/ToolbarView.swift: at line 379 change String(format: "%.1f", ...) to String(format: "%.2f", ...); in slugifiedTitle() (line 395) replace CharacterSet.alphanumerics.contains(scalar) with an ASCII-only check, e.g. `(scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57)` (lowercase a-z or 0-9), matching the original /[^a-z0-9]+/ semantics.

## Finding 14
FINDING [major] URL normalization is incompatible with the Rust app
File: macos/Vellum/Services/Web/WebPageExtractor.swift
Claim: The handwritten normalizer does not match the Rust url crate. It emits the lowercased raw host without IDNA conversion and collapses empty path segments, producing different URLs, storage hashes, and sometimes different requested resources.
Evidence: Lines 105-141 serialize the raw host, while lines 163-179 discard empty path segments. Rust web_page.rs:117-138 parses and serializes with url::Url, which canonicalizes internationalized hosts and preserves URL path semantics. Existing Tauri sidecars for such URLs will not be found.

**Verifier reasoning:** The finding is real. Rust normalize_url (src-tauri/src/web_page.rs) delegates to the url crate's Url::parse/to_string, which per the WHATWG URL Standard (a) runs http/https hosts through UTS-46 domain_to_ascii (IDNA/punycode, with percent-decoding first) and (b) preserves empty path segments ("https://example.com/a//b" stays "/a//b"). The Swift port (macos/Vellum/Services/Web/WebPageExtractor.swift) only lowercases the raw host (line 105) and drops empty path segments via `if segment.isEmpty { endsWithSlash = true; continue }` (lines 176-179), collapsing "/a//b" to "/a/b" and "/a//" to "/a/". 

**Fix hint:** In WebUrl.normalize (macos/Vellum/Services/Web/WebPageExtractor.swift): (1) in normalizePath, stop skipping empty segments — only resolve "." and ".." dot segments (keeping the %2e handling) and serialize empty segments as-is so "/a//b" round-trips, matching WHATWG; (2) after lowercasing, run the host through UTS-46 ToASCII to match the url crate's domain_to_ascii: percent-decode the host bytes, then punycode-encode (RFC 3492, "xn--" prefix) each non-ASCII label — Foundation has no public IDNA API, so vendor a small UTS-46/punycode encoder (or bridge one) rather than serializing the raw Unicode host. Add tests pinning Rust url-crate fixtures, e.g. normalize("https://MÜNCHEN.de/a//b#f") == "https://xn--mnchen-3ya.de/a//b".

## Finding 15
FINDING [major] AI messages can be sent to the wrong tab during snapshot capture
File: macos/Vellum/Views/AI/AiPanel.swift
Claim: Submission captures document context, then starts a task and awaits image capture before sendMessage captures the active session. Switching tabs during that await sends the typed message to the new document with context from the old document.
Evidence: Lines 206-225 capture document/page/annotations outside the Task, await capturePageImageHandler, then call sendMessage. AiStore.swift:163-166 reads activeTabId and document only after that await.

**Verifier reasoning:** The finding is confirmed. In the port, AiPanel.submit() (macos/Vellum/Views/AI/AiPanel.swift:206-226) captures the document context synchronously, then starts a Task that awaits capturePageImageHandler — a nonisolated async closure with real suspension points (Task scheduling plus actor hops into and out of the main-actor PdfSelectionBridge.capturePageImage) — before calling sendMessage. AiStore.sendMessage (macos/Vellum/Stores/AiStore.swift:163-166) reads app.activeTabId and app.document only after that await, so a tab switch processed during the window makes sessionIdAtStart/documentAtStart 

**Fix hint:** In AiPanel.submit(), capture the session id alongside the rest of the context — `let sessionId = appStore.activeTabId` — and inside the Task, after `await aiStore.capturePageImageHandler?(currentPage)`, add `guard appStore.activeTabId == sessionId else { return }` before calling sendMessage (or pass sessionId/document captured at submit time into sendMessage and use them as sessionIdAtStart/documentAtStart instead of re-reading app state). This restores the original's atomic capture of context and session.

## Finding 16
FINDING [major] Web tab saved-to-library state and export status are not reset on in-tab navigation
File: macos/Vellum/Views/PDF/ToolbarView.swift:292
Claim: The original re-fetches the page's saved state and resets the export status whenever the document PATH changes, not just the tab id: the effects are keyed on [isWeb, activeTabId, doc?.pdf_path] and [activeTabId, doc?.pdf_path]. The Swift port keys both resets on `.task(id: appStore.activeTabId)` only. When the user clicks a link inside a web tab, `webNavigated` rebinds the SAME tab id to a new URL (WebViewerView.swift:692/788 -> AppStore.webNavigated), so the task never re-runs: the Archive button keeps showing the previous URL's saved tint, and a stale 'Exported ... MB' / error status survives onto the new page. Worse, clicking the Archive button then computes `next = !pageSaved` from the stale value, so on a fresh page that was auto-saved it can silently call setWebpageSaved(false) for the new URL when the user believed they were toggling the old page's state.
Evidence: Original (src/components/pdf/Toolbar.tsx):
```tsx
useEffect(() => {
  setPageSaved(false);
  if (!isWeb || !activeTabId) return;
  ...commands.getWebpageSaved(activeTabId)...
}, [isWeb, activeTabId, doc?.pdf_path]);
...
useEffect(() => {
  setExportState({ status: "idle", detail: "" });
}, [activeTabId, doc?.pdf_path]);
```
Port (ToolbarView.swift:292-295):
```swift
.task(id: appStore.activeTabId) {
    exportState = .idle
    await loadSavedState()
}
```
`appStore.activeTabId` is unchanged across in-tab navigation (AppStore.swift:105 `webNavigated(tabId:url:)` reuses the session id), so neither reset fires when only pdfPath changes.

**Verifier reasoning:** The finding is confirmed. The original (src/components/pdf/Toolbar.tsx:83-96, 129-131) keys the saved-state fetch on [isWeb, activeTabId, doc?.pdf_path] and the export-status reset on [activeTabId, doc?.pdf_path], and the specs explicitly require this: SPECS-web.md line 160 ("fetched on tab/URL change") and line 153 ("state resets when the tab or URL changes"). The port (macos/Vellum/Views/PDF/ToolbarView.swift:292) keys both resets on .task(id: appStore.activeTabId) only, and grep confirms no other code path resets pageSaved or exportState. AppStore.webNavigated (AppStore.swift:105-133) delib

**Fix hint:** In ToolbarView.swift, change `.task(id: appStore.activeTabId)` to key on a composite of tab id and document path, mirroring ContentView's DocumentIdentity: e.g. add `private struct ToolbarDocIdentity: Hashable { var tabId: String?; var path: String? }` and use `.task(id: ToolbarDocIdentity(tabId: appStore.activeTabId, path: appStore.document?.pdfPath)) { exportState = .idle; await loadSavedState() }` so both resets re-fire on in-tab navigation (pdfPath change) as well as tab switches.

## Finding 17
FINDING [critical] CodexAiClient blocks the main thread for the whole CLI run and can deadlock permanently on pipe back-pressure
File: macos/Vellum/Services/Ai/CodexAiClient.swift:82
Claim: CodexAiClient is @MainActor and run() is async but contains no suspension points around the subprocess: it synchronously writes the prompt to stdin, then calls readDataToEndOfFile() on stdout, then on stderr, then waitUntilExit() — all on the main thread. AiStore.sendMessage (also @MainActor) awaits app.sessions.runCodexAi, which is a MainActor-to-MainActor call, so no executor hop ever happens. Consequences: (1) the entire UI beachballs for the full duration of a `codex exec` run (tens of seconds to minutes) every time the Codex provider is used; (2) hard deadlock: stdout is drained to EOF before stderr is touched, so if codex writes more than the ~64 KiB pipe buffer to stderr (it logs progress there) while stdout is still open, the child blocks writing stderr, never exits or closes stdout, and readDataToEndOfFile(stdout) never returns — the app hangs forever and must be force-quit; (3) the synchronous stdin write of the prompt (which routinely exceeds 64 KiB — AiPrompts.buildContextBlock embeds up to 120,000 chars of full document text) can itself block the main thread if the child is slow to drain stdin. The subprocess work needs to run off the main actor with concurrent readability-handler draining of stdout/stderr.
Evidence: CodexAiClient.swift:3-5 `@MainActor
final class CodexAiClient {
    func run(prompt: String, ...) async throws -> String {` … lines 74-84: `try stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8)) … let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
 let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
 process.waitUntilExit()`. Caller side, AiStore.swift:224 (`@MainActor` class AiStore): `let raw = try await app.sessions.runCodexAi(...)` → DocumentSessionManager.swift:158-160 (`@MainActor`): `func runCodexAi(...) { try await codex.run(...) }` — same actor, so the 'await' never leaves the main thread. Prompt size: AiPrompts.swift:10 `static let maxContextCharacters = 120_000` feeding buildToolModePrompt used at AiStore.swift:225.

**Verifier reasoning:** Confirmed on both sides. Port: CodexAiClient.swift is @MainActor (line 3) and run() has no suspension points — synchronous stdin write (line 75), readDataToEndOfFile on stdout then stderr (lines 82-83), waitUntilExit (line 84). Entire caller chain (AiStore.swift:67-69/224 → DocumentSessionManager.swift:27/158-160) is @MainActor, so the awaits are same-actor and the whole codex exec run executes on the main thread — unconditional UI freeze whenever the Codex provider is used. The sequential stdout-to-EOF-then-stderr drain is a genuine deadlock: a child blocked writing >64 KiB to stderr can neve

**Fix hint:** Take CodexAiClient off the main actor (make the class non-isolated, or mark run() nonisolated) and restructure the subprocess I/O so nothing blocks and pipes are drained concurrently: install readabilityHandler accumulators on both stdout and stderr (or two concurrent reads) before/immediately after process.run(), write the prompt to stdin from a background context (e.g. DispatchQueue/Task.detached), and await process exit via a terminationHandler bridged with withCheckedContinuation instead of waitUntilExit(). This mirrors the original's spawn_blocking + wait_with_output semantics (off-UI-thread, concurrent stdout/stderr draining).

## Finding 18
FINDING [major] Selection popover never appears when the mouse is released over an annotation overlay
File: macos/Vellum/Views/PDF/PdfKitView.swift:165
Claim: In the Tauri app, the selection-capture handler is `onMouseUp` on the scroll container, so a text-selection drag that ends on top of an existing highlight rect or sticky-note pill still fires it (the overlays stop propagation only for mousedown/click, never mouseup), and the popover appears. In the Swift port the leftMouseUp monitor bails out unless the hit-tested view at the release point is a descendant of the PDFView; the SwiftUI overlay stack (highlight rects with contentShape+gesture, sticky-note pills) hit-tests above the PDFView, so releasing a selection drag over any existing annotation silently drops the capture — no popover, no way to highlight/annotate that selection. This is the common flow of re-selecting text that overlaps an existing highlight (e.g. to extend it or attach a note).
Evidence: Swift (PdfKitView.swift:163-171): `NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp, handler: { [weak self] event in ... guard let self, let point = self.pdfPoint(for: event) else { return } self.controller.handleMouseUp(atNative: point) ... })` where pdfPoint (lines 204-211) requires `hit.isDescendant(of: view)` — SwiftUI overlays fail this and return nil. Original (PdfViewer.tsx:1017-1019): `<div ref={containerRef} ... onScroll={handleContainerScroll} onMouseUp={handleMouseUp} onClick={handleContainerClick}>` — handleMouseUp fires for any mouseup bubbling in the container; HighlightLayer.tsx:63-70 only intercepts `onMouseDown`/`onClick` (`e.stopPropagation()`), not mouseup, and useTextSelection.ts:70-76 resolves the page via `target.closest("[data-page-number]")`, which succeeds for overlay children.

**Verifier reasoning:** The behavior difference is real and triggerable. Original: the container's onMouseUp (PdfViewer.tsx:1018) fires for mouseups bubbling from highlight rects because HighlightLayer.tsx:63-70 stops propagation only for mousedown/click, and useTextSelection.ts:70 resolves the page via target.closest("[data-page-number]"), which succeeds since HighlightLayer renders inside the page wrapper (PdfViewer.tsx:1046-1079) — so the selection popover appears when a drag ends over an annotation. Swift port: the leftMouseUp monitor (PdfKitView.swift:163-171) only calls controller.handleMouseUp when pdfPoint re

**Fix hint:** In PdfKitView.swift's leftMouseUp monitor, don't use pdfPoint (hit-test gate); instead mirror the original's container-level mouseup: guard event.window === view.window, compute point = view.convert(event.locationInWindow, from: nil), and call controller.handleMouseUp(atNative: point) whenever view.bounds.contains(point). captureSelection already handles releases over page gaps via pdfView.page(for:point, nearest: false), and suppressNextMouseUp still covers note placement.

## Finding 19
FINDING [major] OpenAI tool schemas are invalid in strict mode
File: macos/Vellum/Services/Ai/OpenAIClient.swift
Claim: The Responses API tools enable strict schema validation but declare x, y, and color as optional by omitting them from required. Strict OpenAI function schemas require every property to be required, with optional values represented as nullable, so requests can be rejected before generation.
Evidence: Lines 137-176 set "strict": true. addNote requires only pageNumber/text despite defining x/y, and addHighlight omits color from required.

**Verifier reasoning:** The finding is real. The port (OpenAIClient.swift lines 148-176) sends "strict": true on addNote and addHighlight while their required arrays omit declared properties (x/y and color respectively). OpenAI's documented strict-mode contract requires every key in properties to appear in required (optionals must be expressed as nullable types); a schema violating this with explicit strict:true is rejected with a 400 at request time, before generation. Since the tools array is attached to every request (line 32) and sendWithRetry does not retry 4xx, every OpenAI chat turn fails. The original app doe

**Fix hint:** In macos/Vellum/Services/Ai/OpenAIClient.swift, remove the "strict": true entries from the addNote and addHighlight tool definitions (matching the original app, which omits strict and lets the Responses API normalize the schema). Alternatively, keep strict and make the schemas strict-compliant: list every property in required and declare optionals as nullable, e.g. for addNote required: ["pageNumber","text","x","y"] with x/y "type": ["number","null"], and for addHighlight required: ["pageNumber","text","color"] with color "type": ["string","null"] — toolArguments already tolerates JSON nulls since its as? NSNumber / as? String casts return nil for NSNull.

## Finding 20
FINDING [major] Codex execution can freeze the UI and deadlock on full pipes
File: macos/Vellum/Services/Ai/CodexAiClient.swift
Claim: Codex runs synchronously on the main actor. It also drains stdout completely before stderr, allowing the child to block on a full stderr pipe while the parent waits for stdout EOF.
Evidence: The class is @MainActor at line 3; lines 82-84 perform blocking readDataToEndOfFile calls and waitUntilExit. The original runs this path in spawn_blocking and uses wait_with_output, which drains both pipes.

**Verifier reasoning:** Verified in code. CodexAiClient is @MainActor (line 3) and run() performs blocking readDataToEndOfFile on stdout, then stderr, then waitUntilExit (lines 82-84) — all on the main thread, since the entire call chain (AiStore → DocumentSessionManager.runCodexAi, both @MainActor) stays main-actor-isolated. Every codex request therefore freezes the UI for the full CLI run time. Additionally, draining stdout to EOF before reading stderr can deadlock if the child fills the ~64KB stderr pipe buffer before closing stdout. The original (src-tauri/src/commands.rs:537, 609) runs in spawn_blocking off the 

**Fix hint:** Move process execution off the main actor and drain both pipes concurrently: make run's blocking section nonisolated (e.g., remove @MainActor from CodexAiClient or wrap the spawn/read/wait in a detached continuation on a background queue), and read stdout and stderr in parallel — e.g., install readabilityHandler accumulators on both file handles (or read each in its own Task) before process.run(), then await termination via terminationHandler, so neither pipe can fill while the other is being drained.

## Finding 21
FINDING [minor] Page navigation resets horizontal scroll when zoomed in
File: macos/Vellum/Views/PDF/PdfSelectionBridge.swift:252
Claim: The original scrolls to a page with `scrollIntoView({behavior:"auto", block:"start"})`, which aligns only vertically (inline defaults to "nearest"), so at a zoom where the page is wider than the viewport, using next/previous page, the page input, or sidebar navigation preserves the user's horizontal pan. The Swift port builds a PDFDestination at the page's displayed top-LEFT corner and calls `go(to:)`, which positions both axes — every page navigation while zoomed-in snaps the view back to the page's left edge.
Evidence: Swift (PdfSelectionBridge.swift:237-252): `let point: CGPoint; switch rotation { ... default: point = CGPoint(x: bounds.minX, y: bounds.maxY) }; pdfView.go(to: PDFDestination(page: page, at: point))` — the destination x (page left edge) resets horizontal scroll. Original (PdfViewer.tsx:486-491): `const scrollToPage = useCallback((pageNum: number) => { const pageElement = pageElementsRef.current.get(pageNum); if (pageElement) { pageElement.scrollIntoView({ behavior: "auto", block: "start" }); } }, []);` — `block:"start"` is vertical-only; horizontal position is untouched for an element already spanning the scrollport.

**Verifier reasoning:** The behavior difference is real and can trigger. Original: PdfViewer.tsx:489 uses scrollIntoView({behavior:"auto", block:"start"}) whose omitted inline option defaults to "nearest", which leaves horizontal scroll untouched for a page element already spanning the scrollport; horizontal scroll exists because the container is overflow-auto with a w-max pages wrapper, so zoomed-in pans are preserved across page navigation. Port: PdfSelectionBridge.swift:237-252 builds PDFDestination at the page's displayed top-LEFT corner (all four rotation branches pick the displayed top-left) and calls pdfView.g

**Fix hint:** In scrollToPage (macos/Vellum/Views/PDF/PdfSelectionBridge.swift:237-252), preserve the horizontal axis: instead of pdfView.go(to:), convert the page's displayed-top point into document-view coordinates (same pattern zoomTo uses at lines 269-281) and scroll the NSClipView to CGPoint(x: clip.bounds.origin.x, y: constrained vertical target), i.e. keep the current clip-view x and only set y; fall back to go(to:) if the clip view is unavailable. (Using kPDFDestinationUnspecifiedValue for x is an alternative but does not map cleanly for 90/270-degree rotated pages, where page y drives view horizontal.)

## Finding 22
FINDING [minor] Charset decoding of non-UTF-8 pages: strict decode falls back to whole-page UTF-8 mojibake, and iso-8859-1 is not mapped to windows-1252
File: macos/Vellum/Services/Web/WebPageExtractor.swift:382
Claim: Rust decodes HTML with encoding_rs: `Encoding::for_label` uses WHATWG label mapping (so `iso-8859-1`/`latin1` decode as windows-1252, matching browsers) and `encoding.decode()` is lossy — invalid byte sequences become U+FFFD but the rest of the page decodes correctly. Swift uses CFStringConvertIANACharSetNameToEncoding + String(data:encoding:), which (a) maps iso-8859-1 to true ISO Latin-1, so 0x80-0x9F bytes (curly quotes, em-dashes on mislabeled windows-1252 pages, which are common) decode to C1 control characters instead of punctuation, and (b) String(data:encoding:) returns nil if ANY byte sequence is invalid for the declared charset, after which the whole body is re-decoded as UTF-8 — a single stray byte on a Shift_JIS/EUC/legacy page garbles the entire document. Because extracted text feeds the raw-offset text map, annotations created on such a page also anchor against different text than the Tauri app would produce.
Evidence: Swift WebPageExtractor.swift decodeHtml (lines 382-389):
    let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
    if cfEncoding != kCFStringEncodingInvalidId {
        ...
        if let decoded = String(data: body, encoding: String.Encoding(rawValue: nsEncoding)) {
            return decoded
        }
    }
    return String(decoding: body, as: UTF8.self)   // whole-page UTF-8 fallback on any invalid byte
Rust web_page.rs decode_html (lines 479-482):
    let encoding = encoding_rs::Encoding::for_label(charset.as_bytes()).unwrap_or(encoding_rs::UTF_8);
    let (text, _, _) = encoding.decode(body);      // WHATWG labels (latin1 -> windows-1252), lossy per-sequence replacement

**Verifier reasoning:** Both halves of the finding are confirmed against the actual code and by empirical test. (1) Code match: Swift decodeHtml (macos/Vellum/Services/Web/WebPageExtractor.swift:382-389) uses CFStringConvertIANACharSetNameToEncoding + strict String(data:encoding:), falling back to whole-page UTF-8 (String(decoding:as: UTF8.self)); Rust decode_html (src-tauri/src/web_page.rs:479-482) uses encoding_rs::Encoding::for_label + lossy encoding.decode. (2) Empirical verification (swift script run on this machine): CFStringConvertIANACharSetNameToEncoding("iso-8859-1") returns 513 (ISOLatin1), not 1280 (windo

**Fix hint:** In WebPageExtractor.decodeHtml, replicate encoding_rs behavior: (1) resolve the charset label via the WHATWG Encoding Standard label table before CF conversion — at minimum map the windows-1252 alias family (iso-8859-1, iso8859-1, latin1, l1, us-ascii, ascii, cp1252, x-cp1252, ansi_x3.4-1968, iso-ir-100, ibm819, csisolatin1) to windows-1252; (2) make the decode lossy per invalid sequence instead of falling back to whole-page UTF-8: single-byte encodings never fail, so on strict-decode failure for multibyte encodings, decode incrementally (find the longest decodable prefix, emit U+FFFD, skip one byte, continue) with the declared encoding rather than re-decoding the whole body as UTF-8. Only use the UTF-8 path when the label is unknown (matching Rust's unwrap_or(UTF_8)).

## Finding 23
FINDING [minor] Untitled web tabs show a different fallback label and icon than the original
File: macos/Vellum/Views/PDF/TabBarView.swift:76
Claim: Original tab label fallback for ANY document kind is the last path segment of pdf_path with a trailing .pdf stripped ('https://example.com/post' -> 'post'), and every tab uses the FileText glyph. The Swift port uses webpageDisplayName for web tabs ('example.com/post') and a globe icon for web tabs. Visible for any webpage before its title is reported (or that never reports one): the tab reads 'example.com/post' with a globe instead of 'post' with a document icon.
Evidence: Original (src/components/pdf/TabBar.tsx):
```ts
function tabLabel(title, pdfPath) {
  if (title?.trim()) return title;
  return pdfPath.split(/[\/]/).pop()?.replace(/\.pdf$/i, "") ?? "Untitled";
}
...
<FileText size={13} ... />
```
Port (TabBarView.swift:76-78, 89):
```swift
let fallback = tab.document.kind == .web
    ? RecentFilesService.webpageDisplayName(for: tab.document.pdfPath)
    : RecentFilesService.fileName(for: tab.document.pdfPath)
...
Image(systemName: tab.document.kind == .web ? "globe" : "doc.text")
```

**Verifier reasoning:** The claimed difference is real, can trigger, and is not sanctioned anywhere. (1) Original: src/components/pdf/TabBar.tsx lines 8-11 define tabLabel(title, pdfPath) with a single fallback for ALL document kinds — last path segment of pdf_path with trailing .pdf stripped case-insensitively — and lines 63-69 render FileText 13px for every tab unconditionally. For a web doc, pdf_path is the URL (commands.rs:98 sets pdf_path = session.url), so 'https://example.com/post' yields 'post'. (2) The fallback genuinely triggers for web tabs in the original: web_page.rs:70 initializes sidecar title to None 

**Fix hint:** In TabBarView.swift's label computation, drop the kind branch: for all kinds use the last path segment of tab.document.pdfPath (split on "/" and "\"), strip a trailing ".pdf" case-insensitively regardless of kind, falling back to "Untitled" when empty. In the icon on line 89, always use Image(systemName: "doc.text") instead of branching to "globe" for web tabs.

## Finding 24
FINDING [minor] Middle-click to close a tab is not implemented
File: macos/Vellum/Views/PDF/TabBarView.swift:85
Claim: The original closes a tab on middle-click (mouse button 1) anywhere on the tab, with preventDefault; the spec calls this out explicitly ('Middle-click (button 1) anywhere on a tab closes it'). The Swift TabItem only supports the hover X button and left-click activation — there is no otherMouseDown/middle-button handling anywhere in the port's tab bar, so middle-clicking a tab does nothing.
Evidence: Original (src/components/pdf/TabBar.tsx):
```tsx
onMouseDown={(event) => {
  if (event.button === 1) {
    event.preventDefault();
    void closeTab(tab.id);
  }
}}
```
Port (TabBarView.swift TabItem body, lines 85-129): only `Button(action: onActivate)` and `Button(action: onClose)`; no NSEvent/otherMouseDown middle-click path exists (grep for otherMouse/middle in macos/Vellum returns nothing).

**Verifier reasoning:** The finding is accurate. The original (src/components/pdf/TabBar.tsx:52) closes a tab on onMouseDown with event.button === 1 plus preventDefault. The spec requires it in three places: SPECS-pdf-viewing.md:76 ("Middle-click (button 1) anywhere on a tab closes it (preventDefault)"), :80 ("Middle-click tab → close"), and the porting notes at :314 explicitly list "middle-click close (macOS: `otherMouseUp`)" as a key behavior to preserve — so far from sanctioning the omission, the porting notes prescribe the implementation. The port's TabItem (macos/Vellum/Views/PDF/TabBarView.swift:85-130) has onl

**Fix hint:** Add middle-click handling to TabItem in macos/Vellum/Views/PDF/TabBarView.swift, e.g. overlay the tab with a transparent NSViewRepresentable whose NSView overrides otherMouseUp(with:) and, when event.buttonNumber == 2 and the point is inside the view, calls onClose (matching the spec's suggested otherMouseUp approach). Ensure the overlay passes through left-clicks (hitTest returns nil for non-middle events) so activation and the X button keep working.

## Finding 25
FINDING [major] Tab bar disappears entirely when no tabs are open (original always shows wordmark + '+' button)
File: macos/Vellum/Views/PDF/TabBarView.swift:10
Claim: The original TabBar renders unconditionally: with zero tabs the 40px strip still shows the Vellum wordmark and the '+' (Open PDF in new tab) IconButton (only the divider is conditional on tabs.length > 0), and App.tsx renders <TabBar /> above the WelcomeScreen. SPECS-pdf-viewing.md states: 'Horizontal tab strip above the toolbar; always visible (even with zero tabs, showing just the wordmark and + button).' The Swift port collapses the whole bar to zero height when tabs are empty, so on the welcome screen the wordmark and the '+' open button are gone. No deviation comment sanctions this.
Evidence: Original (src/components/pdf/TabBar.tsx):
```tsx
return (
  <div className="flex h-10 ...">
    <Wordmark className="flex-shrink-0" />
    {tabs.length > 0 && (<div className="h-5 w-px ... bg-border" />)}
    <div className="flex min-w-0 flex-1 ...">{tabs.map(...)}</div>
    <IconButton onClick={handleOpen} title="Open PDF in new tab">...
```
Port (TabBarView.swift:10-12):
```swift
if appStore.tabs.isEmpty {
    Color.clear.frame(height: 0)
} else { HStack(spacing: 8) { Wordmark() ... } }
```

**Verifier reasoning:** The claimed difference is real and spec-violating. The original TabBar (src/components/pdf/TabBar.tsx) returns the 40px bar unconditionally: Wordmark and the '+' IconButton always render, with only the divider gated on tabs.length > 0, and App.tsx renders <TabBar /> above WelcomeScreen when no document is open. SPECS-pdf-viewing.md line 76 explicitly states the tab strip is "always visible (even with zero tabs, showing just the wordmark and + button)". The Swift port (macos/Vellum/Views/PDF/TabBarView.swift:10-12) instead renders Color.clear.frame(height: 0) when appStore.tabs.isEmpty, collaps

**Fix hint:** In TabBarView.swift, remove the `if appStore.tabs.isEmpty` collapse: always render the HStack bar (wordmark, tab scroll area, '+' button) with its 40px frame and bottom border, and instead gate only the 1x20 divider Rectangle on `!appStore.tabs.isEmpty`, matching the original's `tabs.length > 0` divider condition.

## Finding 26
FINDING [minor] Derived ids for /NM-less annotations use two different index domains, so update/delete can miss or hit the wrong third-party annotation
File: macos/Vellum/Services/Pdf/PdfSessionBackend.swift:299
Claim: The sanctioned deviation is deriving `pdf-direct-{page}-{index}` ids instead of Rust's `pdf-{obj}-{gen}`. But the port computes that index in two different domains: reads index the RAW /Annots array via CGPDF (index advances past entries that fail `dictionaryAt`, e.g. null or non-dictionary array slots), while find-for-update/delete indexes PDFKit's `page.annotations` array, which omits entries PDFKit cannot instantiate. In Rust both read and find go through the same `annotation_entries` function, so ids always resolve consistently. In the port, a document whose /Annots contains an entry PDFKit drops shifts every subsequent /NM-less annotation by one: updating/deleting it either returns false (annotation appears immutable) or, if another /NM-less annotation lands on the shifted index, edits/deletes the WRONG annotation and persists that to the user's PDF.
Evidence: Swift read (PdfAnnotationCodec.swift:103-119): `for index in 0..<CgPdf.count(entries) { guard let dictionary = CgPdf.dictionaryAt(entries, index) else { continue } ... }` and `annotationId(...) { CgPdf.string(dictionary, "NM") ?? "pdf-direct-\(pageNumber)-\(index)" }` — index is the raw array slot. Swift find (PdfSessionBackend.swift:295-307): `for (index, annotation) in page.annotations.enumerated() { let annotationId = (annotation.value(forAnnotationKey: PdfAnnotationWriter.nmKey) as? String) ?? "pdf-direct-\(pageIndex + 1)-\(index)" ... }` — index is PDFKit's filtered-array position. Rust (pdf_annotations.rs:1080-1152): both `find_annotation` and the reader call the same `annotation_entries(document, page_id)` and `annotation_id(page_number, &entry)`, so index/object-id derivation is identical on both paths.

**Verifier reasoning:** The finding is confirmed empirically. Swift read path (macos/Vellum/Services/Pdf/PdfAnnotationCodec.swift:103-119) derives pdf-direct-{page}-{index} from the RAW /Annots slot via CGPDF (the loop index advances past entries where CgPdf.dictionaryAt fails), while the find path used by update/delete (macos/Vellum/Services/Pdf/PdfSessionBackend.swift:295-307) derives the same id form from the entry's position in PDFKit's page.annotations array. A PDFKit-vs-CGPDF experiment with a /Annots array of [null|broken-ref|integer, TextAnnot(no /NM), HighlightAnnot(no /NM)] shows CGPDF counts 3 raw slots (s

**Fix hint:** Make findAnnotation use the same index domain as the reader: give it the raw CGPDFDocument (updateAnnotation/deleteAnnotation already load it via loadForMutation), enumerate each page's raw /Annots slots exactly like PdfAnnotationReader (deriving the id from /NM or pdf-direct-{page}-{rawSlot}), and keep a separate cursor into page.annotations that advances only when CgPdf.dictionaryAt succeeds for a raw slot; when the derived id matches, return page.annotations[cursor]. This keeps read-path ids unchanged while resolving update/delete against the raw-slot domain.
