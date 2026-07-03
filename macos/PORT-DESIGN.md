# Vellum SwiftUI Port — Design

Goal: 1:1 functional port of the Tauri (React + Rust) app to a native SwiftUI macOS app.
No UI redesign — reproduce current layout/behavior. Persistence must stay compatible:
the Swift app must read/write the same PDFs (embedded annotations), the same
`.vellumweb` archives, and the same app-data files the Rust side wrote.

## Stack mapping

| Tauri app | SwiftUI port |
|---|---|
| Tauri window/shell | SwiftUI `WindowGroup` (1280×800 default, 800×600 min) |
| React components | SwiftUI views (1:1 mapping, same names where sensible) |
| Zustand stores | `@Observable` classes in `Stores/` (same state fields/actions) |
| Rust `pdf_annotations.rs` (embedded PDF annots) | `PdfAnnotationService` on PDFKit (`PDFAnnotation`, `/NM`, QuadPoints) |
| Rust `web_page.rs` / `web_archive.rs` | `WebArchiveService` + `WKWebView`-based viewer |
| `tauri-commands.ts` IPC | direct Swift service calls (`DocumentSessionManager`) |
| react-pdf / PDF.js | PDFKit `PDFView` |
| Vercel AI SDK / @google/genai | native URLSession streaming clients (`AiService`) |
| `run_codex_ai` (spawns codex CLI) | `Process` wrapper for `codex exec` |
| localStorage persistence | `UserDefaults` (same JSON payloads, keys documented below) |
| Tauri updater | GitHub releases check (deferred; documented gap) |
| Web Speech API voice | `SFSpeechRecognizer` (STT) + `AVSpeechSynthesizer` (TTS) |

## Project layout (`macos/`)

XcodeGen project (`project.yml`); after adding files run `xcodegen generate` — the
pbxproj is never hand-edited, sources are globbed from `Vellum/`.

```
macos/Vellum/
  App/         VellumApp.swift, ContentView.swift (shell layout, shortcuts)
  Models/      Annotation.swift, DocumentInfo.swift, PdfTab.swift, ... (Codable, snake_case keys preserved)
  Stores/      AppStore.swift (tabs+viewport = pdf-store), AnnotationStore.swift, AiStore.swift, ThemeStore.swift
  Services/    DocumentSessionManager.swift, PdfAnnotationService.swift, WebArchiveService.swift,
               RecentFilesService.swift, AiService/ (GeminiClient, OpenAIClient, CodexClient), SpeechService.swift
  Views/
    Welcome/   WelcomeScreen.swift
    PDF/       PdfViewerView.swift (PDFView wrapper), ToolbarView.swift, TabBarView.swift
    Annotations/ AnnotationSidebar.swift, SelectionPopover.swift, StickyNoteOverlay.swift
    Web/       WebViewerView.swift, WebNotePopovers.swift
    AI/        AiPanel.swift, MarkdownMessage.swift, settings views
    Shared/    Theme.swift, IconButton.swift, buttons, Wordmark
  Resources/   Info.plist, AppIcon.icns, prompts/*.md (copied from src/prompts)
```

## Shell layout (from App.tsx)

Vertical stack: TabBar / Toolbar / content row. Content row = document viewer
(PdfViewer or WebViewer by `document.kind`) + optional right sidebar (width 320,
border-left) with a segmented control: "Annotations" | "AI" (icons MessageSquare/
Sparkles size 13). No document → TabBar + Toolbar + WelcomeScreen.
Auto-save active session every 30 s (`saveFile`, errors swallowed).
On document identity change (path or active tab): clear annotations + AI doc
context, reload annotations, load per-document conversation.

### Keyboard shortcuts (global)
- Cmd+O open file dialog (multi-select; filters: Documents pdf+vellumweb / PDF / Vellum Web Archive)
- Cmd+L "add webpage" (focus URL input / open web sheet)
- Cmd+S save active session (silent failure)
- Cmd+W close active tab
- Cmd+1..9 activate tab by index
- Cmd+= zoom in, Cmd+- zoom out (0.25–4.0, step 0.1)
- Cmd+B toggle bookmark (when doc open)
- Escape: deselect annotation, mode → view
- N (not in text field): toggle note mode

## Stores

### AppStore (= pdf-store + App.tsx local state)
State: `tabs: [PdfTab]`, `activeTabId`, active mirror (document, currentPage, numPages,
zoom, visiblePages, webVisibleRange, webVisibleBookmarks, mode), isLoading, error,
sidebarOpen (default true), sidebarTab (.annotations default).
Actions mirror pdf-store exactly: openFile(s) (dedupe by pdf_path → activate existing,
closing the freshly opened session), openUrl, webNavigated (reuses session id),
updateDocumentTitle, closeTab (persist last_page metadata first; activate neighbor at
min(closingIndex, count-1)), activateTab (persists last_page of outgoing tab),
setCurrentPage/NumPages (persists page_count metadata)/setZoom(clamped)/zoomIn/out,
setVisiblePages, setWebVisibleRange, setWebVisibleBookmarks, goToPage (clamped; no-op
when numPages<1), setMode. Tab dedup key: `document.pdf_path`.

### Theme (index.css "Scriptorium" system)
Class-toggled light/dark, persisted (theme-store). Colors (light / dark):
background #fbfaf7/#1b1a17, surface #ffffff/#232220, surfaceMuted #f4f1ea/#1f1e1b,
well #ece8df/#121110, foreground #211d18/#ece6da, muted #efebe2/#2c2a26,
mutedForeground #786f62/#a39a8a, border #e6e0d4/#353229, borderStrong #d6cdbb/#45413a,
primary #45418f/#7c79df, primaryFg #ffffff/#15140f, primaryHover #3a3680/#8b88e6,
accent #efebe2/#2c2a26, destructive #b23a30/#e5645c, gold #a9791b/#d6a93b,
highlights yellow #fde68a/#7a5a0e80 green #b9efc8/#14583080 blue #bcd9fb/#1f3f9180
pink #f6c7de/#8a2a5680 purple #d8d0fb/#4b3fb380.
Radii 5/7/10/14/20. Selection highlight colors (types/index.ts HIGHLIGHT_COLORS):
yellow #fef08a, green #bbf7d0, blue #bfdbfe, pink #fbcfe8, purple #ddd6fe (dark variants 80-alpha).
Implement as `Theme` environment object exposing semantic Color properties.

## Data models (exact JSON compatibility — snake_case)

`Annotation { id, type: highlight|note|bookmark, page_number, color?, content?,
position_data?, created_at, updated_at }`
`PositionData { rects: [{x,y,width,height}], page_width, page_height, selected_text?,
start_offset?, end_offset?, prefix?, suffix?, viewport_offset? }`
`DocumentInfo { kind: pdf|web, pdf_path, title?, page_count?, last_page? }`
`WebLibraryEntry { url, title?, page_count?, saved_at?, has_snapshot }`
`VellumwebExportSummary { path, bytes, asset_count, assets_skipped }`

## Session API (replaces Tauri IPC; same semantics)

DocumentSessionManager keyed by session UUID string:
open_file, open_web_document, open_vellumweb_file, archive_webpage_default,
export_vellumweb, set/get_webpage_saved, list/remove_saved_webpages, save_file,
close_file, read_pdf_bytes (not needed — PDFKit opens path directly, keep for parity
where used), get/create/update/delete_annotation(s), set_document_metadata,
run_codex_ai. Exact behaviors per subsystem specs (SPECS-*.md).

## localStorage → UserDefaults (same keys, same JSON payloads)

- `vellum.recent-pdfs`: JSON array of `{pdf_path, kind ("pdf"|"web", default "pdf" when
  absent), title, page_count, opened_at (ISO8601)}`; max 8, newest first, dedupe by
  pdf_path; write failures silently ignored. Display name: filename for PDFs,
  `hostname+path` (no trailing slash, empty path for "/") for web.
- `vellum.theme`: `"light"` | `"dark"`; first launch follows OS appearance.
- (AI keys/settings: see SPECS-ai.md — same pattern.)

## Persistence compatibility contracts

(filled from subsystem specs — see SPECS-annotations.md for the PDF dictionary
format written by pdf_annotations.rs, SPECS-web.md for the .vellumweb container
format and web library layout, SPECS-app-shell.md for recent-files/localStorage keys
→ UserDefaults mapping, SPECS-ai.md for provider wire protocols and BYOK storage.)

Key rule: the Swift app must round-trip files written by the Rust app and vice versa.
PDFKit annotation writes must preserve `/NM` ids, QuadPoints, colors, dates, and any
custom keys the Rust side uses.

## Module map (implementation ownership)

Foundation (done, frozen for module agents): Models/Models.swift, Views/Shared/Theme.swift,
Views/Shared/Controls.swift, Stores/AppStore.swift, Stores/AnnotationStore.swift,
Services/SessionService.swift, Services/DocumentSessionManager.swift,
Services/RecentFilesService.swift, App/VellumApp.swift, project.yml.

| Module | Owns (create/replace) | Spec |
|---|---|---|
| pdf-persistence | Services/Pdf/* | SPECS-annotations.md (persistence half) |
| pdf-ui | Views/PDF/PdfViewerView.swift + new Views/PDF/Pdf* files, Views/Annotations/{HighlightLayer,StickyNoteOverlay,SelectionPopover}.swift | SPECS-pdf-viewing.md + SPECS-annotations.md (UI half) |
| chrome | Views/PDF/{ToolbarView,TabBarView}.swift, Views/Annotations/AnnotationSidebar.swift | SPECS-pdf-viewing.md (toolbar/tabs) + SPECS-annotations.md (sidebar) |
| shell | App/ContentView.swift, Views/Welcome/WelcomeScreen.swift | SPECS-app-shell.md |
| ai | Stores/AiStore.swift (public API frozen), Services/Ai/*, Views/AI/* | SPECS-ai.md |
| web | Services/Web/*, Views/Web/* | SPECS-web.md |

Rules for module agents: never edit files outside your module; never run xcodegen or
edit the pbxproj; build with your own DerivedData (`-derivedDataPath .dd/<module>`);
view stub signatures are frozen (environment-driven, no required init params).

## Concurrency/architecture notes

- Swift 6 language mode with minimal strict concurrency to keep the port mechanical;
  stores are `@MainActor @Observable`.
- Services are actors or `@MainActor` classes; file I/O off main thread where easy.
- Streaming AI via `URLSession.bytes(for:)` SSE parsing.
- No third-party dependencies unless unavoidable (markdown: use AttributedString
  markdown or a small custom renderer; KaTeX: render math via WKWebView only inside
  AI messages if needed — decide in SPECS-ai implementation).
