> **HISTORICAL — describes the pre-port Tauri app, not the current SwiftUI app.**
> Written as reference material for the Tauri→SwiftUI port (2025–2026). The current
> app has diverged (e.g. 5 streaming AI providers and 5 tools vs. the 3 non-streaming
> providers / 3 tools described here; no Codex CLI provider; repo-root layout, not
> `macos/`). Do not treat file paths, behavior, or UI specs here as current.

# SPEC: app-shell

## Overview
The app shell is the outermost layer of Vellum: a single Tauri window ("Vellum", 1280x800) hosting a React SPA. It composes the whole UI as a vertical stack — TabBar, Toolbar, then either the WelcomeScreen (no open document) or the document area (PDF viewer or Web viewer) with an optional 320px right side panel that segments between "Annotations" and "AI". It owns global keyboard shortcuts, the light/dark "Scriptorium" theme system, the welcome screen (recent files + saved webpages + URL entry), recent-files persistence in localStorage, a crash-catching error boundary, the toolbar-hosted auto-updater flow, a 30-second autosave loop, and the Rust command registry (18 Tauri commands) plus a custom `vellum-web://` URI scheme protocol.

## Features

### Window & application bootstrap

**Behavior:** Tauri config (`src-tauri/tauri.conf.json`): productName `Vellum`, version `0.1.0`, identifier `com.vellum.app`. Single window: title `Vellum`, width 1280, height 800, minWidth 800, minHeight 600, resizable true, fullscreen false. CSP is `null` (disabled). Bundle: `createUpdaterArtifacts: true`, targets `all`, icons 32x32.png/128x128.png/128x128@2x.png/icon.icns/icon.ico. Dev URL http://localhost:5173. There is NO custom application menu (Tauri default macOS menu only), NO file-association registration, NO tray icon, and NO frontend drag-and-drop file handling (nothing listens for drop events — dropping a file onto the window does nothing). `main.rs` just calls `app_lib::run()` (with `windows_subsystem = "windows"` in release on Windows). `lib.rs` `run()` builds the Tauri app with plugins: dialog, fs, process (desktop only), log (debug builds only, level Info), updater (desktop only, registered in setup). It `.manage()`s `AppState { sessions: Mutex<HashMap<String, Session>> }` and registers the asynchronous URI scheme protocol `vellum-web` (see externalAPIs). Frontend bootstrap (`src/main.tsx`): calls `initTheme()` before first paint (applies stored theme to <html> to avoid flash), then renders `<StrictMode><ErrorBoundary fallback=…><App/></ErrorBoundary></StrictMode>` into `#root`. Imports `index.css` and `katex/dist/katex.min.css`.

**UI:** html/body/#root: 100% width/height, overflow hidden, background `var(--color-background)`, color `var(--color-foreground)`, antialiased font smoothing, font-family sans stack. Custom scrollbars everywhere: `scrollbar-width: thin`, webkit scrollbar 10px wide/high, thumb `var(--color-border-strong)` fully-rounded with 3px transparent border (content-box clip), thumb hover `var(--color-muted-foreground)`, corner transparent. Shared `.focus-ring` class: no outline; on :focus-visible box-shadow `0 0 0 2px var(--color-background), 0 0 0 4px var(--color-primary)`.

### Layout composition & routing (App.tsx)

**Behavior:** Routing is purely conditional on `document` in the pdf-store (no router). If no document open: renders column `TabBar` → `Toolbar` (without sidebar props) → `WelcomeScreen`. If a document is open: column `TabBar` → `Toolbar sidebarOpen onToggleSidebar` → row containing the viewer (`WebViewer key={activeTabId}` when `doc.kind === "web"`, else `PdfViewer key={activeTabId}`; keying on tab id forces full remount on tab switch) and, when `sidebarOpen` (default true, local component state, resets on app restart, shared across tabs), the right side panel. Side panel has a segmented control with two tabs, local state `sidebarTab` defaulting to `"annotations"`: "Annotations" (MessageSquare icon, 13px) and "AI" (Sparkles icon, 13px); body renders `AnnotationSidebar` or `AiPanel`. Document-change effect: keyed on `[activeTabId, docPath]` where docPath = `doc?.pdf_path ?? null` — when either changes: `clearAnnotations()`, `clearDocumentContext()` (AI store), then if docPath non-null `loadAnnotations()` and `loadConversationForDocument(current document)`. Deliberately keyed on path, not the document object, so a webpage reporting its title doesn't wipe AI context/annotations. Autosave: while a doc + activeTabId exist, `setInterval` every 30000 ms calls `commands.saveFile(activeTabId)` swallowing errors; cleared on tab/doc change. Also listens for window CustomEvent `vellum:annotations-updated` → reloads annotations if a document is open (fired after .vellumweb import merges annotations into an already-open tab).

**UI:** Root: `flex h-screen w-screen flex-col overflow-hidden`. Content row: `flex min-h-0 flex-1 overflow-hidden`. Side panel: `flex min-h-0 w-80 (320px) flex-shrink-0 flex-col overflow-hidden border-l bg-background`. Segmented control container: padding 8px (`p-2`), inner `flex gap-1 rounded-lg bg-muted p-1`. Each segment button: `focus-ring flex flex-1 items-center justify-center gap-1.5 rounded-md px-3 py-1.5 text-xs font-medium transition-colors`; selected: `bg-surface text-foreground shadow-soft`; unselected: `text-muted-foreground hover:text-foreground`. Panel body: `min-h-0 flex-1 overflow-hidden overscroll-contain border-t`.

**Shortcuts:** All registered on window keydown in App.tsx; `isCtrl` = ctrlKey OR metaKey (so Cmd on macOS, Ctrl elsewhere). Cmd/Ctrl+O: preventDefault, open multi-select file dialog with filters [Documents: pdf,vellumweb | PDF: pdf | Vellum Web Archive: vellumweb], then `openFiles(selection)`. Cmd/Ctrl+L: preventDefault, dispatch window CustomEvent `vellum:add-webpage` (Toolbar opens its URL prompt popover). Cmd/Ctrl+S: preventDefault, `saveFile(activeTabId)` if a tab is active (errors swallowed). Cmd/Ctrl+W (key lowercased): preventDefault, `closeFile()` (closes active tab). Cmd/Ctrl+1..9: activates tab at index key-1 if it exists (preventDefault only when tab exists). Cmd/Ctrl+= : preventDefault, `zoomIn()`. Cmd/Ctrl+- : preventDefault, `zoomOut()`. Cmd/Ctrl+B: preventDefault, `toggleBookmark()` only if a document is open. Escape: `selectAnnotation(null)` and `setMode("view")` (no preventDefault). Plain `n` (no ctrl/meta, target not an input or textarea): if a document is open, preventDefault and toggle mode between "note" and "view".

### Theme system (Scriptorium light/dark)

**Behavior:** Zustand store `useThemeStore` with `theme: "light" | "dark"`. Initial theme: localStorage key `vellum.theme` if it equals "light" or "dark"; otherwise follows OS `prefers-color-scheme: dark`. `setTheme` applies immediately (toggles class `dark` on `document.documentElement` and sets `style.colorScheme = theme`), persists to localStorage, updates store. `toggleTheme` flips. `initTheme()` applies the stored theme before React renders. Dark mode is class-based (`.dark` on <html>). The only UI control is the ThemeToggle IconButton in the Toolbar (right cluster): shows Sun icon (16px) when dark, Moon when light; title/aria-label `Switch to light theme` / `Switch to dark theme`.

**UI:** Exact CSS variables (index.css). LIGHT: background #fbfaf7, surface #ffffff, surface-muted #f4f1ea, well #ece8df, foreground #211d18, muted #efebe2, muted-foreground #786f62, border #e6e0d4, border-strong #d6cdbb, primary #45418f, primary-foreground #ffffff, primary-hover #3a3680, accent #efebe2, accent-foreground #211d18, destructive #b23a30, destructive-foreground #ffffff, gold #a9791b, highlight-yellow #fde68a, highlight-green #b9efc8, highlight-blue #bcd9fb, highlight-pink #f6c7de, highlight-purple #d8d0fb. DARK: background #1b1a17, surface #232220, surface-muted #1f1e1b, well #121110, foreground #ece6da, muted #2c2a26, muted-foreground #a39a8a, border #353229, border-strong #45413a, primary #7c79df, primary-foreground #15140f, primary-hover #8b88e6, accent #2c2a26, accent-foreground #ece6da, destructive #e5645c, destructive-foreground #15140f, gold #d6a93b, highlight-yellow #7a5a0e80, highlight-green #14583080, highlight-blue #1f3f9180, highlight-pink #8a2a5680, highlight-purple #4b3fb380. Radii: sm 5px, md 7px, lg 10px, xl 14px, 2xl 20px. Shadows LIGHT: soft `0 1px 2px rgba(33,29,24,.05), 0 1px 1px rgba(33,29,24,.04)`; panel `0 4px 16px -4px rgba(33,29,24,.12), 0 2px 6px -2px rgba(33,29,24,.08)`; page `0 2px 8px rgba(33,29,24,.1), 0 1px 2px rgba(33,29,24,.06)`. Shadows DARK: soft `0 1px 2px rgba(0,0,0,.4)`; panel `0 8px 28px -6px rgba(0,0,0,.6), 0 2px 8px -2px rgba(0,0,0,.4)`; page `0 2px 12px rgba(0,0,0,.5)`. Fonts: sans = ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif; serif = "Iowan Old Style", "Palatino Linotype", "Book Antiqua", Palatino, Georgia, "Times New Roman", serif; mono = ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace. All elements default `border-color: var(--color-border)`.

### Welcome screen

**Behavior:** Shown whenever no document is open. On mount fetches `list_saved_webpages` (errors swallowed; result ignored if unmounted). Reads recent files synchronously from localStorage via `getRecentPdfs()`. Sections top-to-bottom: (1) Hero: FileText icon (30px, stroke 1.5, primary color) in a 64x64 rounded-2xl bordered tile; heading `Vellum` + primary-colored period, serif 4xl semibold tracking-tight; tagline `A quiet place to read, annotate, and think alongside your documents.` (2) Primary button (size lg) with FolderOpen 18px icon, label `Open a PDF` (or `Opening…` while isLoading, button disabled); next to it text `or press` + kbd showing `⌘O` on macOS / `Ctrl+O` elsewhere. Clicking opens the same multi-file dialog as Cmd+O and calls `openFiles`. (3) URL row (max-w-md): Globe 15px icon + text input placeholder `Or read a webpage — paste an article URL`; Enter or the adjacent `Open` button (disabled when loading or input blank/whitespace) trims, clears the input, and calls `openUrl(value)`. (4) If store `error` non-null: error paragraph in a destructive-tinted rounded box. (5) `Saved pages` section (only if listSavedWebpages returned non-empty): header `Saved pages` with Archive 13px icon, uppercase tracking-wide xs. Each row: Globe icon (17px, stroke 1.75) in 36x36 rounded-lg tile; title = `page.title.trim() || getWebpageDisplayName(url)`; subtitle = displayName plus ` · available offline` when `has_snapshot`. Row button title attr = full URL; click → `openUrl(page.url)`; disabled while loading. Hover-revealed X button (opacity 0 → 100 on group hover or focus-visible), title `Remove from saved pages`, aria-label `Remove {displayTitle} from saved pages`; click optimistically removes from local list then calls `remove_saved_webpage(url)` (errors swallowed). (6) `Recently opened` section (only if recents non-empty): header with Clock 13px icon. Each entry: icon Globe (web) or FileText (pdf); title = `entry.title.trim() || fileName` where fileName = last path segment for PDFs or `getWebpageDisplayName` for web; subtitle concatenates: if displayTitle !== fileName → `{fileName} · `; if pdf and page_count → `{n} page`/`{n} pages` + ` · `; then formatted opened date (Intl.DateTimeFormat default locale, dateStyle "medium"; invalid date → literal `Recently opened`). Click → `openUrl(entry.pdf_path)` for web entries else `openFile(entry.pdf_path)`. X button title/aria-label `Remove {fileName} from recent files`; removes from localStorage and re-renders. getWebpageDisplayName(url): parse URL → `hostname + pathname` with root path shown as bare hostname and trailing slash stripped; unparseable → raw string.

**UI:** Container: `flex h-full min-h-0 flex-col items-center overflow-auto bg-well px-6 py-16`; inner column max-w-2xl. Hero tile: `h-16 w-16 rounded-2xl border border-border-strong bg-surface shadow-soft`, margin-bottom 12px. kbd: `rounded border border-border-strong bg-surface px-1.5 py-0.5 font-mono text-[11px] shadow-soft`. URL input row: `h-10 rounded-lg border border-border bg-surface px-3 shadow-soft`. Error box: `border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-destructive rounded-md`, margin-top 20px, max-w-md, centered text. List cards: `overflow-hidden rounded-xl border border-border bg-surface shadow-soft`; rows separated by `border-b border-border` (none on last), hover `bg-accent`; row button `px-4 py-3 gap-3`; icon tile `h-9 w-9 rounded-lg border border-border bg-muted text-muted-foreground`, on row hover border-strong + primary icon tint; title `text-sm font-medium truncate`, subtitle `text-xs text-muted-foreground truncate`. Remove button: `h-8 w-8 rounded-md mr-2`, hover `bg-muted text-destructive`. Sections spaced `mt-12`, headers `mb-2 px-1 text-xs font-medium uppercase tracking-wide text-muted-foreground` with 13px icon and gap-1.5.

### Recent files persistence

**Behavior:** localStorage key `vellum.recent-pdfs`, JSON array, max 8 entries, newest first. `recordRecentPdf(doc)` is called on every successful open (openFile/openVellumwebFile/openWebDocument, including in-tab web navigation): builds `{pdf_path, kind: doc.kind ?? "pdf", title, page_count, opened_at: new Date().toISOString()}`, prepends, dedupes by `pdf_path` (removes earlier entry with same path), slices to 8, writes back (write errors silently ignored). `getRecentPdfs()`: parse; non-array or throw → []; filters invalid entries via type guard (pdf_path string, title string|null, page_count number|null, opened_at string; missing `kind` mutated to "pdf" for pre-webpage entries; otherwise kind must be "pdf" or "web"); slices to 8. `removeRecentPdf(path)` filters by pdf_path, writes, returns the new list. Note: for web entries `pdf_path` holds the normalized URL.

### Error boundary

**Behavior:** React class component catching render errors. `componentDidCatch` logs `"[ErrorBoundary] Caught render error:"` + error + info to console.error. With a fallback prop (function form gets the Error): renders it. The root-level fallback (main.tsx) renders a full-screen centered panel on bg-background: text `Application crashed` (lg, semibold, destructive), the error message (sm, muted, max-w-md), a `<pre>` with the stack trace (max-h-48 max-w-lg overflow-auto rounded bg-muted p-3 text-left text-xs), and a button `Reload app` (`rounded-md border bg-background px-4 py-2 text-sm hover:bg-accent`) that calls `window.location.reload()`. Default (no fallback) rendering: `Something went wrong`, error message or `An unexpected error occurred.`, and a `Try again` button that resets boundary state to re-render children.

### App updater flow (lives in Toolbar)

**Behavior:** Uses tauri-plugin-updater. `checkForAppUpdate()` = plugin `check()`; `relaunchForUpdate()` = plugin-process `relaunch()`. Updater config: pubkey (minisign, see tauri.conf.json) and single endpoint `https://github.com/ayushdeolasee/Vellum/releases/latest/download/latest.json`. On Toolbar mount: silent check (`handleCheckForUpdates(true)`); on unmount pending update object is `.close()`d. State machine `updateStatus`: idle | checking | available | downloading | restarting | error, plus `updateMessage` (initial `Check for updates`). Check flow: set status checking (message `Checking for updates...` unless silent); on result null → status idle, message `You are up to date`; on update → store Update object in a ref, status available, message `Update {version} is ready to install`, keep version + release notes (`update.body`). On check error: console.error `[Toolbar] Failed to check for updates:`; silent → back to idle/`Check for updates`; non-silent → status error, message = error.message or `Failed to check for updates`. Install flow (clicking the green chip while available): if no pending update, re-check instead. Otherwise status downloading, message `Downloading {version}...`, progress starts at 0; `downloadAndInstall` progress events: Started → contentLength captured, progress 0; Progress → accumulate chunkLength, progress = min(100, round(downloaded/contentLength*100)) only when contentLength > 0; Finished → 100. Then status restarting, message `Restarting to finish the update...`, close update, `relaunch()`. Install error: console.error `[Toolbar] Failed to install update:`, status error, message = error.message or `Failed to install update`.

**UI:** Right toolbar cluster. Status chip (rendered only when status is available/downloading/restarting/error): pill button `h-7 rounded-full border px-2.5 text-xs font-medium gap-1.5`; available: `border-emerald-500/30 bg-emerald-500/10 text-emerald-700 hover:bg-emerald-500/15 dark:text-emerald-300` with Download 12px icon and label `Update {version}`; downloading/restarting: `border-primary/20 bg-primary/10 text-foreground` with spinning LoaderCircle 12px and label `Downloading update` (progress null) / `Downloading {n}%` / `Restarting...`; error: `border-destructive/30 bg-destructive/10 text-destructive`, label `Update failed`, click re-checks. Chip disabled unless status is available or error. Separate check IconButton: RefreshCw 16px (spinning LoaderCircle 16px while checking), disabled during checking/downloading/restarting; title on both chip and button = updateMessage, with release notes appended as `\n\n{notes}` when present.

### Tab/session management (store level)

**Behavior:** Zustand pdf-store holds `tabs: PdfTab[]` and mirrors the active tab's fields at top level (activeTabId, document, currentPage, numPages, zoom, visiblePages, webVisibleRange, webVisibleBookmarks, mode). Session ids are `crypto.randomUUID()` generated per open. Opening a file: `.vellumweb` (case-insensitive extension check) → `open_vellumweb_file`, else → `open_file`; then `adoptOpenedDocument`: records recent, and if a tab with the same `document.pdf_path` already exists, closes the just-created backend session (errors swallowed) and activates the existing tab instead of duplicating; otherwise appends a new tab initialized with currentPage = last_page ?? 1, numPages = page_count ?? 0, zoom 1.0, mode "view" and makes it active. After a .vellumweb open, dispatches `vellum:annotations-updated`. `openFile`/`openUrl` set isLoading/error (error = `String(e)`); `openFiles` opens sequentially, collecting failures as `{path}: {error}` joined with newline into `error`. `closeTab`: persists `last_page` = currentPage via set_document_metadata (swallowed), calls close_file (swallowed), removes the tab; if it was active, activates the tab at min(closingIndex, tabs.length-1) or empties active state. `activateTab`: persists outgoing tab's last_page first, then swaps active state wholesale from the tab snapshot. Zoom clamped 0.25–4.0, step 0.1; zoomIn/zoomOut prefer the viewer-installed `window.__zoomPdfTo(target)` hook, else setZoom. `goToPage` ignores calls while numPages < 1, clamps to [1, numPages], and calls optional `window.__scrollToPage(page)`. `webNavigated(tabId, url)` re-invokes open_web_document with the SAME session id (backend rebinds the tab), records recent, resets page state from the new DocumentInfo. `updateDocumentTitle` trims and updates tab + active document title if changed.

## Data models

## TypeScript (`src/types/index.ts`) — all serialized snake_case

```ts
type DocumentKind = "pdf" | "web";

interface DocumentInfo {
  kind: DocumentKind;          // Rust defaults to "pdf" when absent
  pdf_path: string;            // fs path for PDFs, normalized URL for webpages (name kept for compat)
  title: string | null;
  page_count: number | null;
  last_page: number | null;
}

interface PdfTab {             // frontend-only, camelCase
  id: string;                  // UUID, doubles as backend session id
  document: DocumentInfo;
  currentPage: number;
  numPages: number;
  zoom: number;                // 0.25..4.0
  visiblePages: number[];
  webVisibleRange: { start: number; end: number } | null;
  webVisibleBookmarks: string[];
  mode: "view" | "note";
}

interface RecentPdf {          // localStorage, snake_case
  pdf_path: string;
  kind: DocumentKind;
  title: string | null;
  page_count: number | null;
  opened_at: string;           // ISO 8601
}

interface WebLibraryEntry {
  url: string;
  title: string | null;
  page_count: number | null;
  saved_at: string | null;
  has_snapshot: boolean;
}

interface VellumwebExportSummary { path: string; bytes: number; asset_count: number; assets_skipped: number; }

type AnnotationType = "highlight" | "note" | "bookmark";
interface Rect { x: number; y: number; width: number; height: number; }
interface PositionData {
  rects: Rect[]; page_width: number; page_height: number;
  selected_text: string | null; start_offset: number | null; end_offset: number | null;
  prefix?: string | null; suffix?: string | null; viewport_offset?: number | null; // web-only, omitted when None
}
interface Annotation {
  id: string; type: AnnotationType; page_number: number;
  color: string | null; content: string | null; position_data: PositionData | null;
  created_at: string; updated_at: string;
}
interface CreateAnnotationInput { type: AnnotationType; page_number: number; color?: string; content?: string; position_data?: PositionData; }
interface UpdateAnnotationInput { id: string; color?: string; content?: string; position_data?: PositionData; }

const HIGHLIGHT_COLORS = [
  { name: "Yellow", value: "#fef08a", dark: "#854d0e80" },
  { name: "Green",  value: "#bbf7d0", dark: "#16653480" },
  { name: "Blue",   value: "#bfdbfe", dark: "#1e40af80" },
  { name: "Pink",   value: "#fbcfe8", dark: "#9d174d80" },
  { name: "Purple", value: "#ddd6fe", dark: "#5b21b680" },
];
```

## Rust (`src-tauri/src/models.rs`, `commands.rs`) — serde snake_case by default

```rust
pub struct DocumentInfo {                        // commands.rs
    #[serde(default = "default_document_kind")]  // -> "pdf"
    pub kind: String,
    pub pdf_path: String,
    pub title: Option<String>,
    pub page_count: Option<u32>,
    pub last_page: Option<u32>,
}

pub struct Annotation {
    pub id: String,
    #[serde(rename = "type")] pub annotation_type: AnnotationType, // lowercase: highlight|note|bookmark
    pub page_number: u32,
    pub color: Option<String>,
    pub content: Option<String>,
    pub position_data: Option<PositionData>,
    pub created_at: String,
    pub updated_at: String,
}
pub struct PositionData {
    pub rects: Vec<Rect>, pub page_width: f64, pub page_height: f64,
    pub selected_text: Option<String>, pub start_offset: Option<u32>, pub end_offset: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub prefix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub suffix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub viewport_offset: Option<f64>,
}
pub struct Rect { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }
pub struct CreateAnnotationInput { #[serde(rename="type")] annotation_type, page_number: u32, color, content, position_data }
pub struct UpdateAnnotationInput { id: String, color, content, position_data }
pub struct DocumentMetadata { title: Option<String>, page_count: Option<u32>, last_page: Option<u32> }
pub struct CodexAiImageInput { base64_data: String, media_type: String }

pub enum Session { Pdf(PdfSession), Web(WebSession) }
pub struct AppState { pub sessions: Mutex<HashMap<String, Session>> }  // keyed by frontend tab UUID
```

Theme store: `{ theme: "light" | "dark" }`. Interaction mode: `"view" | "note"`. Zoom constants: MIN 0.25, MAX 4.0, STEP 0.1. Recents cap: 8.

## Persistence

## localStorage (WebView-scoped)

**`vellum.theme`** — the literal string `light` or `dark`. Absent on first launch (falls back to OS preference; note: the OS-derived theme is applied but NOT written until the user toggles).

**`vellum.recent-pdfs`** — JSON array, max 8, newest first. Example:
```json
[
  {
    "pdf_path": "/Users/me/Documents/paper.pdf",
    "kind": "pdf",
    "title": "Attention Is All You Need",
    "page_count": 15,
    "opened_at": "2026-07-03T09:12:33.123Z"
  },
  {
    "pdf_path": "https://example.com/post",
    "kind": "web",
    "title": "A Blog Post",
    "page_count": 4,
    "opened_at": "2026-07-02T18:00:00.000Z"
  }
]
```
Legacy entries without `kind` are read as `"pdf"`. Corrupt/invalid entries are dropped on read. Write failures ignored.

(Other localStorage keys — AI conversations etc. — belong to other subsystems.)

## App data directory (Tauri `app_data_dir`, i.e. `~/Library/Application Support/com.vellum.app/` on macOS)

Owned by the web subsystem but addressed by app-shell code paths:
- `web/` store dir (`web_page::store_dir`): per-page sidecars keyed by `page_key(url)` = sha256 hex — `<key>.json` (record: saved, saved_at, title, page_count, last_page, loading_policy, annotations) and `<key>.snapshot.html` (plain snapshot, written atomically).
- `web/archives/<key>/` installed archive dir: `snapshot.html` with asset placeholders + `assets/<name>` files, served through `vellum-web://…/asset/<key>/<name>`.
- Managed `.vellumweb` archives at `web_page::managed_archive_path(data_dir, key)`.

## PDF annotations
Stored INSIDE the PDF file itself by the `pdf_annotations` module (open_file derives title/page_count/last_page from it; save_file persists) — the exact PDF dictionary format is the pdf-annotations subsystem's contract, not repeated here.

## Session state (not persisted)
`AppState.sessions: Mutex<HashMap<String, Session>>` — in-memory only; open tabs are NOT restored across launches. Per-tab `last_page` is persisted into the document (via `set_document_metadata`) on tab switch and tab close, and page_count on `setNumPages`; `save_file` autosaves every 30 s and on Cmd/Ctrl+S.

Window size/position: not persisted (fixed 1280x800 default each launch).

## IPC commands

All 18 commands registered in `lib.rs` `invoke_handler`, implemented in `commands.rs` (delegating to `pdf_session`/`pdf_annotations`/`web_page`/`web_archive`). Invoke arg names from the frontend are camelCase (`sessionId`, `pageNumber`, `destPath`, `expectedUrl`); Tauri maps them to Rust snake_case. All errors are `String`. Common error: `No session found for tab {session_id}`.

| Command | Args (frontend) | Returns | Behavior |
|---|---|---|---|
| `open_file` | `path, sessionId` | `DocumentInfo` | Extension must be `pdf` (lowercased) else `Unsupported file type: .{ext}`. Opens PdfSession, reads title/page_count/last_page from PDF annotations layer, replaces any existing session under sessionId (saving the old one first). kind="pdf". |
| `open_web_document` | `url, sessionId` | `DocumentInfo` | Opens/rebinds a WebSession for the normalized URL under sessionId (in-tab navigation reuses the id). kind="web", pdf_path=normalized URL. Handled by web_page module. |
| `save_file` | `sessionId` | `()` | Pdf → `pdf_session::save_session`; Web → no-op Ok (webpage mutations write to the sidecar immediately). |
| `close_file` | `sessionId` | `()` | Removes session; saves PDF session on close; missing session is Ok. |
| `read_pdf_bytes` | `sessionId` | binary `ArrayBuffer` (tauri::ipc::Response) | Raw PDF file bytes; Web session → `This tab is a webpage, not a PDF`; read failure → `Failed to read PDF at {path}: {e}`. |
| `get_annotations` | `sessionId, pageNumber?` (null allowed) | `Annotation[]` | Dispatches to pdf_annotations or web_page by session kind. |
| `create_annotation` | `sessionId, input: CreateAnnotationInput` | `Annotation` | Same dispatch. |
| `update_annotation` | `sessionId, input: UpdateAnnotationInput` | `bool` | Same dispatch. |
| `delete_annotation` | `sessionId, id` | `bool` | Same dispatch. |
| `set_document_metadata` | `sessionId, key, value` (strings; keys used: `last_page`, `page_count`, title) | `()` | Same dispatch. |
| `set_webpage_saved` | `sessionId, saved: bool` | `()` | Web only; PDF → `This tab is a PDF, not a webpage`. |
| `get_webpage_saved` | `sessionId` | `bool` | Web → saved flag; PDF → `false` (no error). |
| `list_saved_webpages` | — | `WebLibraryEntry[]` | Scans app-data web store. |
| `remove_saved_webpage` | `url` | `()` | Unsaves; annotations kept. |
| `export_vellumweb` | `sessionId, destPath, pages: [{number, text}]` | `VellumwebExportSummary` | Web tabs only (PDF → `PDFs are already portable — archiving applies to webpage tabs`). Snapshot preference: live fetch > installed archive dir > plain saved snapshot; no source → `The page could not be fetched and no local snapshot exists yet`. Builds manifest with loading_policy "live-first", refreshes the installed archive dir, writes the archive atomically off-thread. |
| `open_vellumweb_file` | `path, sessionId` | `DocumentInfo` | Reads archive, opens web session for manifest.url, installs snapshot+assets locally, merges manifest metadata only into missing record fields, propagates `snapshot-only` policy, sets record.saved=true (saved_at = now RFC3339 if absent), merges annotations, saves record. |
| `archive_webpage_default` | `sessionId, pages, expectedUrl` | `bool` | Auto-archive on open. If normalized expectedUrl != session URL (tab navigated meanwhile) → `Ok(false)` skip. Writes archive to the managed library path, then `mark_saved_if_absent`. Returns true. |
| `run_codex_ai` | `prompt, model, image: {base64_data, media_type} \| null` | `String` | See externalAPIs #3. Runs on a blocking thread; join failure → `Codex task failed: {e}`. |

Plugins used from the frontend: `@tauri-apps/plugin-dialog` `open()` (multi-select; filters Documents pdf+vellumweb / PDF / Vellum Web Archive) and `save()` (vellumweb export; defaultPath `{slug}.vellumweb` where slug = lowercased title, non-alphanumerics→`-`, trimmed of leading/trailing `-`, max 60 chars, fallback `article`); `@tauri-apps/plugin-updater` `check()`/`Update.downloadAndInstall()`/`Update.close()`; `@tauri-apps/plugin-process` `relaunch()`.

Capabilities (`capabilities/default.json`, window `main`): core:default, dialog:default + allow-open + allow-save, fs:default, process:default, updater:default, fs read-file & write-file scoped to `$HOME/**`, `$DOWNLOAD/**`, `$DOCUMENT/**`, `$DESKTOP/**`, `$TEMP/**`, `/var/folders/**`, `/tmp/**`, plus fs:allow-exists and fs:allow-mkdir.

## External APIs

1. **Updater endpoint**: GET `https://github.com/ayushdeolasee/Vellum/releases/latest/download/latest.json` (tauri-plugin-updater format), signature-verified with the minisign pubkey embedded in tauri.conf.json (`dW50cnVzdGVkIGNvbW1lbnQ6IG1pbmlzaWduIHB1YmxpYyBrZXk6IDlEODYzQTQ5QkZGNjFFMjIKUldRaUh2YS9TVHFHblFaaDNYNXJDelRZcVlHcUZEL3dnL1pSU2k3dFFjdFJ0WUIyUXZlNjIrSncK%` — note the trailing `%`). Download progress streamed via events Started(contentLength)/Progress(chunkLength)/Finished.

2. **Custom URI scheme `vellum-web://`** (registered as an asynchronous scheme protocol in lib.rs; the web viewer iframe loads pages through it):
   - Route `/asset/<key>/<name>` → serves `<app_data>/web/archives/<key>/assets/<name>` with Content-Type from `web_archive::content_type_for_name`, `Cache-Control: public, max-age=604800`. Validation: key must be non-empty all-ASCII-hexdigit; name non-empty, no `..`, no `/`, no `\\`, not starting with `.`; anything else → 404 `<h1>Asset not found</h1>`.
   - Route `/?url=<encoded-url>`: missing param → 404 `<h1>Missing url parameter</h1>`. URL normalized via `web_page::normalize_url`; failure → 400 error page. If sidecar record has `loading_policy == "snapshot-only"` and an installed snapshot exists → serve it (assets rewritten to `<scheme>://<authority>/asset/<key>` or fallback base `vellum-web://localhost`). Otherwise fetch live: HTML result → if redirected, effective identity = normalized final_url; refresh the saved snapshot atomically (under the effective key) when that record is `saved`; respond 200 with `web_page::prepare_html(html, effective_url, false)`. Non-HTML → 200 raw body with its content type, `Cache-Control: no-store`. Fetch error → installed snapshot, else plain saved snapshot (200, prepared with snapshot flag true), else 502 error page. All HTML responses: `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store`.

3. **Codex CLI** (local subprocess, not network from the app's perspective): `run_codex_ai` spawns `codex exec --model <model> --sandbox read-only --skip-git-repo-check --ephemeral --cd <tempdir> --output-schema <schema.json> --output-last-message <out.json> [--image <tempdir>/current-page.<ext>] -` with prompt on stdin. Model defaults to `gpt-5.5` if blank. Image extension: image/png→png, image/webp→webp, else jpg. Output: reads the output-last-message file, falling back to stdout; empty → error `Codex returned an empty response.`. Non-zero exit → `Codex CLI exited with status {status}: {stderr-or-stdout truncated to 1200 chars + "..."}`. Spawn failure → `Failed to start Codex CLI. Is `codex` installed? {e}`. Output schema (written as JSON file): object requiring `reply` (string) and `actions` (array of `{tool: "goToPage"|"addNote"|"addHighlight", args: {pageNumber: number, text: string|null, color: string|null, x: number|null, y: number|null}}`), additionalProperties false throughout.

Frontend network calls: none directly (all via Tauri IPC / plugins).

## Porting notes

- **Layout**: NavigationSplitView is a poor fit — the side panel is on the RIGHT and fixed at 320 pt. Use an HStack: viewer + conditional 320 pt panel with leading divider; wrap in VStack under a custom tab bar and 44 pt (h-11) toolbar row. `sidebarOpen` and `sidebarTab` are ephemeral UI state (default true / "annotations"), shared across tabs, reset on relaunch.
- **Routing**: no router — a simple `if activeDocument == nil { WelcomeScreen } else { viewer }`. Force viewer state reset on tab switch (React does this by keying on tab id — in SwiftUI use `.id(activeTabId)`).
- **Theme**: don't rely solely on system appearance — the app has its own toggle persisted under `vellum.theme` (UserDefaults key). First launch follows the system; after any toggle the explicit choice wins. Port the CSS variables as semantic Color assets with the exact hex values (note the dark highlight colors carry 50% alpha as trailing `80`). `colorScheme` should be forced app-wide via `.preferredColorScheme`.
- **Keyboard shortcuts**: use ⌘ equivalents (isCtrl means ⌘ on macOS). ⌘W must close the TAB, not the window — you'll need to override the default Close menu item. ⌘1–⌘9 select tabs by index. Plain `n` toggles note mode only when focus isn't in a text field — replicate with a local event monitor checking the first responder. `⌘=` is zoom in (the key without shift), `⌘-` zoom out.
- **Session ids**: the frontend mints `UUID()` per open and the backend keys everything on it; in Swift the tab model can own its UUID and pass it to whatever replaces the Rust session layer. Preserve the "reopen same path → activate existing tab, discard new session" dedupe, keyed on `pdf_path`.
- **Recents**: Vellum keeps its own recents (localStorage, cap 8) rather than NSDocumentController's recent-documents; to stay data-compatible mirror the exact JSON under a UserDefaults string key `vellum.recent-pdfs`. Also note `pdf_path` is a URL string for web entries.
- **Autosave**: a 30 s timer calling save on the active tab only, plus save-on-close/switch of `last_page`. With PDFKit you may save in-place; keep the cadence and the swallow-all-errors behavior.
- **Updater**: Tauri updater ≈ Sparkle. The GitHub `latest.json` + minisign signature format is Tauri-specific; for a native port you'd switch to Sparkle appcast — but if 1:1 data compatibility of the feed matters, you'd have to reimplement the check (GET latest.json, compare version, download, verify minisign). The whole flow lives in the toolbar with a status chip; exact copy strings are in the updater feature above.
- **Error boundary**: no direct SwiftUI equivalent (Swift crashes crash). The closest analog is catching and presenting recoverable errors; the "Application crashed / Reload app" full-screen fallback with stack trace has no native mapping — document-level try/catch presentation is the practical substitute.
- **`vellum-web://` protocol**: maps to a custom `WKURLSchemeHandler` on the WKWebView — same routes (`/?url=` and `/asset/<key>/<name>`), same fallback ladder (snapshot-only → live → installed snapshot → plain snapshot → 502 error page), same path-traversal guard on asset names.
- **run_codex_ai**: `Process` launching `codex` with identical args; write prompt to stdin, temp dir for schema/output/image files. Sandboxed Mac apps can't spawn arbitrary binaries — the app must be non-sandboxed or use a helper.
- **No-ops to NOT invent**: there is no drag-and-drop file opening, no custom menu bar items, no file-type association handling, no window-state restoration, and no multi-window support in the current app. `.focus-ring` (2px background + 4px primary double ring on focus-visible) applies to every interactive control — approximate with `.focusEffect`/custom focus ring if keyboard navigation parity matters.
- **Dialog filters**: file-open panel allows `pdf` and `vellumweb` (grouped "Documents" plus individual filter entries); multi-select is enabled everywhere the dialog appears (welcome button, toolbar button, ⌘O). Errors from multi-open are concatenated one per line as `{path}: {error}` and shown on the welcome screen error box.

