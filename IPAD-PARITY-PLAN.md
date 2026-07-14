# iPad ↔ main parity plan (2026-07-15)

Goal: bring `ipad-app` to full feature/behavior parity with `main` (everything merged
since fork point `8f02bff`: PRs #41 AI experience, #44 scratchpad, #45 highlight resize
✅ done, #46 on-demand retrieval, #48 hardening, #50 storage, + direct commits).
**No git merge of main into ipad-app** — file-by-file ports, 3-way `git merge-file`
vs `8f02bff` where useful. Each phase: build + tests green on
`platform=iOS Simulator,name=iPad Pro 13-inch (M5)`, then commit.
`xcodegen generate` after any project.yml/file-list change — never hand-edit pbxproj.

## Design decisions (made for the port)

1. **PdfSessionBackend: KEEP iPad's `PdfFileGate`** (global actor) rather than adopting
   main's per-document `PdfDocumentIO`. Rationale: PdfFileGate was QA'd on iPad with
   Apple Pencil ink writes sharing the same gate (lost-update protection spans
   annotations + ink); swapping actors risks regressing ink persistence. Cost: writes
   to *different* PDFs serialize unnecessarily (perf nit, not functionality). DO add
   main's `PageTextCache.shared.refreshHash(...)` calls into every write path.
2. **Voice/TTS: REMOVE on iPad** (SpeechService, push-to-talk in AiPanel_iOS, mic/speech
   plist keys) — mirrors main's deliberate removal (4f4c700). Do this as part of the
   AiPanel_iOS rewrite.
3. **ChatGPT OAuth on iOS**: port `ChatGPTAuth` using `ASWebAuthenticationSession`
   presenting the authorize URL while the loopback `NWListener` runs (app stays
   foreground inside the auth session, so the listener stays alive). If unworkable in
   practice, ship the provider with sign-in marked "available on macOS" — never block
   the rest of the AI stack on this.
4. **SelectableMessageText / ImageDrop: REBUILD iOS-native** (UITextView selection;
   UIDropInteraction + PhotosPicker + file importer), don't port AppKit internals.
5. **WebStorage `.icloud` on iOS**: use `FileManager.url(forUbiquityContainerIdentifier:)`
   with graceful fallback to local when nil (no entitlement/signed-out). Don't hard-code
   `~/Library/Mobile Documents`. Custom folder = UIDocumentPicker + security-scoped
   bookmarks (`startAccessingSecurityScopedResource` around each access).
6. **Keep iPad-only features**: touch-selection reporting (`selectionchange` path in
   WebContentScript), pointer-events resize (RESIZE_KNOB=14/PAD=30), iOS Copy button in
   SelectionPopover, `vellumOpenFile` notification, drag watchdog (`noteDragActivity`),
   14pt divider, Pencil/Gestures settings sections, `CreateAnnotationInput.createdAt`.

## Phases

### Phase 1 — AI backend + codex removal (unblocks everything AI)
- project.yml: add main's `packages:` block (SwiftMath **1.7.3 exact**) → xcodegen.
- New files (verbatim-safe): `AiStreaming.swift`, `AiUsage.swift`, `ChatGPTClient.swift`,
  `OAuth/PKCE.swift`, `OAuth/OAuthLoopbackServer.swift`, `OpenCodeZenClient.swift`,
  `OpenRouterCatalog.swift`, `OpenRouterClient.swift`, `KeychainStore.swift`,
  `PageTextCache.swift`, `PageTextPersister.swift`.
- New files (adapt): `AiImageAttachment.swift` (NSColor→UIColor),
  `OAuth/ChatGPTAuth.swift` (NSWorkspace→UIApplication/ASWebAuthenticationSession),
  `MathRenderer.swift` (NSColor/NSImage→UIColor/UIImage).
- Clean adopts: `GeminiClient.swift`, `OpenAIClient.swift`, `AiPrompts.swift`,
  `AiPersistence.swift`, `AiToolEngine.swift` (take main's wholesale — ipad's only edit
  is byte-identical inside main's diff), `Resources/prompts/tool-mode-native.md`,
  `MarkdownMessage.swift` (after MathRenderer).
- Codex removal (coordinated): delete `CodexAiClient.swift`; strip codex from
  `DocumentSessionManager.swift`, `SessionService.swift` (KEEP ipad's `vellumOpenFile`
  notification), `AiStore.swift`.
- `AiStore.swift` big merge: main's +469/-104 (AiThinkingMode replaces VoiceMode,
  AiActivity, composerReferences, usage, streaming, ensureExtracted, receipts); keep
  ipad's `.vellumAiSettingsChanged` observer (byte-identical to main's).
- `Models.swift`: add `InteractionMode.snapshotRegion`; keep `createdAt`.
- `AppStore.swift`: add `pendingNoteContent`/`beginNoteWithContent`/
  `consumePendingNoteContent`, `RegionCaptureTarget` + `beginRegionCapture`,
  `flushPageTextCacheHandler`.
- `WorkspaceStore.swift`: add `.scratchpad` SidebarTab case, `openRouterCatalog`,
  `chatgptAuth`; keep drag watchdog.
- `PdfSessionBackend.swift`: keep PdfFileGate; add PageTextCache.refreshHash hooks.
- `PdfViewerView_iOS.swift`: adopt `PreparedPdf`/`cachedPreparedPdf` fast-path (code
  already sits verbatim in frozen `PdfViewerView.swift` on this branch).
- Tests: `PageTextCacheTests.swift`, `MarkdownParserTests.swift`, `AiPipelineTests.swift`
  (adapt AppKit bits). AiPanel_iOS: minimal compile fixes only this phase (full rewrite
  is Phase 2) — may need temporary shims for renamed AiStore API (e.g. activity enum).
  NOTE: AiPanel_iOS references `SpeechService`; if AiStore drops VoiceMode this phase,
  strip the mic UI here too (decision #2) or shim until Phase 2.
- `AnnotationStore.swift`: add `selectionRequestCount` (bumped on every non-nil
  `selectAnnotation`); fix `WebViewerView_iOS.swift:133` onChange to observe it
  (re-clicking same sidebar highlight must re-scroll).

### Phase 2 — AI UI (AiPanel_iOS rewrite + settings)
- Adapt: `ModelSelector.swift` (NSApp.makeFirstResponder→@FocusState),
  `RevealableSecureField.swift` (UITextField), `ComposerReferences.swift` (UIImage).
- Rebuild iOS-native: SelectableMessageText equivalent (UITextView), ImageDrop
  equivalent (UIDropInteraction anywhere on panel + dashed indicator + "Attach image…"
  via PhotosPicker/fileImporter; parse off-main; gate on model vision capability;
  re-check active tab after awaits).
- `AiPanel_iOS.swift` rewrite: streaming UI, AiActivity pill (incl. `.indexing`),
  selectable messages + Quote→reference, composer references, image attachments,
  usage display, remove push-to-talk/TTS.
- `AiSettingsPanel.swift` merge (provider list, ChatGPT sign-in, RevealableSecureField,
  ModelSelector field, capability warnings, reasoning/thinking picker).
- `SettingsView.swift` AI tab merge (preserve iPad Gestures/Pencil sections).
- Remove mic/speech usage keys from Info-iOS.plist (+Info.plist), remove SpeechService.
- Port `Tests/SelectableMessageTests.swift` ideas to iOS equivalent if cheap; else skip.

### Phase 3 — Web stack
- `WebContentScript.swift` (hardest): adopt main's isolated `WKContentWorld`
  ("VellumBridge") split + page-world script (`data-vellum-page-url`/`data-vellum-offline`
  attrs), soft-nav URL tracking, YouTube embed fallback + validated open-external,
  `window.open` relay, scroll-settle rewrite (400ms+1200ms re-correct), fragment-link
  in-page hash navigation. PRESERVE ipad's pointer-events resize block and
  `selectionchange` touch-selection reporting. Keep `set-selected-highlight` (already
  byte-identical). Cross-check `highlight-resized` payload shape consumed by
  WebViewerView_iOS.
- `WebPageExtractor.swift` (must land WITH content-script world split + WebStorage).
- `WebSessionBackend.swift`: adopt main's `WebDocumentIO` actor + per-call `recordPath`;
  CARRY FORWARD ipad's `pageNumber` persistence in updateAnnotation (main regressed it)
  and optimistic id/createdAt echo.
- `WebLibrary.swift`: storage-location feature (activeLayout, loadRecordForServing —
  NON-BLOCKING on serve path, evictStaleUnsavedSnapshots, listSnapshotStorage); keep
  ipad's appDataDir iOS fallback.
- `WebStorage.swift` new (decision #5). `WebNotePopovers.swift` (AskAiButton closures;
  update WebViewerView_iOS call sites). `WebViewerView_iOS.swift`: bridge-world eval,
  beginSelectionNote/askAiAboutSelection/pushSelectedHighlight, captureRegion/
  capturePageImage via UIImage/WKSnapshotConfiguration, note-field selection pinning
  (WebKit clears DOM selection on responder resign — pin on note-open, release on real
  dismissal).
- Tests: `WebProxyUrlTests.swift`, `WebLibraryStorageTests.swift`,
  `WebStorageLocationTests.swift`.

### Phase 4 — Storage UI + app lifecycle
- `StorageLocationChoiceSheet.swift` (NSOpenPanel→existing DocumentPicker_iOS pattern;
  houses `WebStorageRelocator` — load-bearing for launch sweep).
- `SettingsView.swift` Storage tab (cache size/breakdown, downloaded pages rows,
  remove/remove-all, auto-save toggle, storage mode controls).
- `VellumApp_iOS.swift`: launch TTL eviction (PageTextCache.evictStale,
  WebLibrary.evictStaleUnsavedSnapshots, WebStorageRelocator.sweepAtLaunch — serialize
  vs manual location change), first-launch storage sheet, scenePhase-background flush
  (PageTextPersister.awaitInFlightFlushes, AiPersistence.awaitPendingFlush, per-pane
  scratchpad flush once Phase 5 lands), `.environment` catalog/auth.
- Web toolbar save toggle in `PdfChrome_iOS.swift`: "Save for Offline Use"/"Remove
  Offline Copy" + generation-counter race fix; annotating auto-promotes saved.

### Phase 5 — Scratchpad
- Verbatim: `ScratchpadStore.swift`, `ScratchpadPersistence.swift`,
  `Resources/katex/*` (25 files incl. editor.bundle.js, DOMPurify), `tools/scratchpad-editor/*`.
- Adapt: `ScratchpadPanel.swift` (UIViewRepresentable WKWebView, UIPasteboard, UIColor).
- Wire: `PaneTree.swift` scratchpad field, `PaneView_iOS`, `ContentView_iOS` sidebar tab
  (+ suppress bare-key shortcuts while editor WKWebView focused — responder walk),
  AppStore `.scratchpad` capture target.
- Tests: `ScratchpadImportTests.swift` (de-AppKit).
- Invariants: DOMPurify fail-closed (missing sanitizer → escaped plain text); GC delay
  (600ms) strictly > persist debounce (400ms), referencedIds computed inside detached task;
  LRU updates move entry to end.

### Phase 6 — Region capture + AI references (touch design)
- Touch `RegionCaptureOverlay` equivalent on PDF + web (SwiftUI DragGesture minDistance 0,
  cancel on tap/tiny-drag, no dangling scrim; 1280px render cap; encode off-main).
- `AiReference` system end-to-end: SelectionPopover "Ask AI about this", composer "+"
  menu (attach page/snapshot region, not PDF-gated), `pendingContent` AI-note-reply
  wiring in PdfViewerController_iOS (placeNote content).
- Web region capture: WKSnapshotConfiguration.rect straight from overlay coords.

### Phase 7 — Cleanup + final QA
- Delete: `PORT-DESIGN.md`, `specs/` bundle, `plans/VELLUM_UI_UX_AUDIT.md`+assets
  (mirrors main). Adopt `.gitignore` additions, `CHANGELOG.md`. Skip Benchmarks/ +
  UITests/ (no target on either branch) unless trivial.
- Full suite + on-sim QA sweep (xcode MCP synthesized touches / simctl screenshots;
  computer-use only via codex/opus/sonnet).

## Do-not-reintroduce list (from PR reviews on main)
1. Optimistic-create race: queue update/delete behind pending create, retarget to
   persisted id (ipad already has the superior version — preserve it in all merges).
2. Cancellation must RETHROW immediately in AI clients — never retry user cancels;
   beware `throw` inside `do` caught by own `catch` (broken retry guard).
3. Keychain migration: only clear plaintext after keychain write CONFIRMED; check
   OSStatus; PKCE must check SecRandomCopyBytes status.
4. Fail-closed sanitization in any WKWebView with bridge/scheme-handler access.
5. `searchDocument` regex: 3s deadline, off-main; regexes match across line breaks;
   extraction preserves line structure.
6. Auto page image gated on low-text threshold (don't attach screenshots when page has
   plenty of text).
7. Markdown re-render: skip when content+palette unchanged; unclosed `$$` renders as
   code while streaming; math cache bounded (300); content-aware (not placeholder)
   equation diff; `plainPreview` math-stripping via MathRenderer.segments ("$5 and $10"
   must survive).
8. Conversation blob: in-memory cache + coalesced 200ms background flush; clear
   `pendingFlush` only AFTER write completes (quit-flush race).
9. iCloud materialization (up to 10s) NEVER on the page-serve path; TOCTOU rmdir in
   migration cleanup (exclude shared store dir); save-toggle generation counter;
   launch sweep serialized vs manual location change.
10. CORS on asset host: no `*` — echo/validate requesting origin.
11. Embedded UIKit views swallow drops (UIDropInteraction analog of AppKit drag
    hit-testing) — register/forward explicitly on any UIViewRepresentable surface.
12. Proxy URLs: stray `%`→`%25`, userinfo canonicalized, no silent empty-snapshot
    fallback (assert in debug).
13. Gemini: thoughtSignature parts replay verbatim; Gemini 3 thinkingLevel vs 2.5
    thinkingBudget. OpenAI: maxOutputTokens scales with effort.
14. OpenRouter: ≤2 cache breakpoints, sticky session_id, accept multiple images.
15. Web resize: empty/whitespace-only quote → bail (highlight would vanish on
    round-trip); persist virtual pageNumber on cross-page resize; clear resize preview
    on selection change.

## Status
- [x] Phase 0: highlight-resize port committed (899b23f)
- [ ] Phase 1 — AI backend
- [ ] Phase 2 — AI UI
- [ ] Phase 3 — Web stack
- [ ] Phase 4 — Storage UI/lifecycle
- [ ] Phase 5 — Scratchpad
- [ ] Phase 6 — Region capture + AI references
- [ ] Phase 7 — Cleanup + QA
