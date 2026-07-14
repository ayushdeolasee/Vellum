> **HISTORICAL — describes the pre-port Tauri app, not the current SwiftUI app.**
> Written as reference material for the Tauri→SwiftUI port (2025–2026). The current
> app has diverged (e.g. 5 streaming AI providers and 5 tools vs. the 3 non-streaming
> providers / 3 tools described here; no Codex CLI provider; repo-root layout, not
> `macos/`). Do not treat file paths, behavior, or UI specs here as current.

# SPEC: pdf-viewing

## Overview
The PDF viewing subsystem renders on-disk PDFs inside a scrollable, virtualized, continuous-vertical viewer (react-pdf/pdf.js in the web app; PDFKit in the Swift port). It comprises: the viewer itself (`src/components/pdf/PdfViewer.tsx`) with anchored zoom, pinch-to-zoom preview, page virtualization, text selection, and note placement; the toolbar (`src/components/pdf/Toolbar.tsx`) with file/zoom/page/bookmark/note/update controls; the tab bar (`src/components/pdf/TabBar.tsx`) supporting multiple simultaneously open documents; the Zustand store (`src/stores/pdf-store.ts`) holding per-tab viewport state; and the Rust session layer (`src-tauri/src/pdf_session.rs`, `src-tauri/src/commands.rs`, `src-tauri/src/pdf_annotations.rs`) that opens/validates PDFs, streams bytes to the frontend, and persists reading position directly inside the PDF's Info dictionary.

## Features

### Document loading (bytes via Tauri command)

**Behavior:** Opening: user picks file(s) via native dialog (Toolbar folder button, TabBar + button, Cmd+O, or WelcomeScreen). For each path, frontend generates `crypto.randomUUID()` as the session/tab id, then calls `open_file(path, sessionId)` (or `open_vellumweb_file` if the path ends with `.vellumweb`, case-insensitive). Rust `open_file`: lowercases the extension; only `"pdf"` is accepted, otherwise error `"Unsupported file type: .{ext}"`. It canonicalizes the path (error: `"Failed to resolve PDF path {path}: {err}"`), verifies it is a file (error: `"PDF path is not a file: {path}"`), and parses it with lopdf to validate (error: `"Failed to parse PDF: {err}"`). It returns `DocumentInfo { kind: "pdf", pdf_path: <canonical path>, title, page_count, last_page }` where title = PDF Info `/Title` (decoded) falling back to the file stem, page_count = lopdf page count, last_page = Info `/VellumLastPage` (integer or numeric string). The session is stored in a `Mutex<HashMap<String, Session>>`; re-inserting an existing session id first closes the previous session.

Dedup: after opening, the store checks `tabs` for an existing tab with the same `document.pdf_path`; if found, it calls `close_file(sessionId)` for the just-created session (errors swallowed) and activates the existing tab instead of adding a new one. Otherwise a new `PdfTab` is appended with `currentPage = doc.last_page ?? 1`, `numPages = doc.page_count ?? 0`, `zoom = 1.0`, `visiblePages = []`, `mode = "view"`, and becomes active. Every successful open also records the document into localStorage recents (see persistence).

Bytes: PdfViewer does NOT get a file path; whenever `activeTabId`/`document` changes it resets local state (pdfData=null, pdfError=null, pageDimensions={}, dimensionsReady=false, clears AI document context — resets are done in a queued microtask, cancellable) and calls `read_pdf_bytes(sessionId)` which reads the whole file from disk and returns raw bytes via Tauri's binary `Response` (errors: `"No session found for tab {id}"`, `"This tab is a webpage, not a PDF"`, `"Failed to read PDF at {path}: {err}"`). The bytes are wrapped as `{ data: Uint8Array }` and fed to pdf.js. On failure, error is logged as `[PdfViewer] readPdfBytes FAILED:` and stored.

On document load success (pdf.js): `setNumPages(numPages)` (which also fire-and-forgets `set_document_metadata(tabId, "page_count", String(n))`); the pdf.js document is registered with the highlight-locator; then two sequential async passes run, guarded by a run-id so tab switches cancel them: (1) dimension pass — for each page 1..N read `getViewport({scale:1}).width/height` into a dimensions record, yielding to the event loop every 32 pages (setTimeout 0), then commit all dimensions at once and set `dimensionsReady=true`; failures per page log `[PdfViewer] Failed dimension read for page {n}:` and are skipped; (2) text pass — for each page, wait for browser idle (requestIdleCallback with 500ms timeout, else 16ms setTimeout), read `getTextContent()`, join item strings with " ", collapse whitespace (`replace(/\s+/g," ").trim()`), and store via AI store `setPageText(pageNum, text)`; per-page failures log `[PdfViewer] Failed text extraction for page {n}:`.

**UI:** While `pdfData` is null (and no error): centered `Loading PDF...` in muted-foreground text on `bg-muted`, filling the flex area. If `read_pdf_bytes` failed: centered `Failed to read PDF: {error}` in destructive color. pdf.js's own loading state shows the same centered `Loading PDF...`; its error state shows `Failed to load PDF` in destructive color. If no document is open the viewer renders nothing (App shows WelcomeScreen). Open-file dialog filters: `Documents (pdf, vellumweb)`, `PDF (pdf)`, `Vellum Web Archive (vellumweb)`; multiple selection allowed. (TabBar's + button dialog filters only `PDF (pdf)`.)

### Page layout, rendering & virtualization

**Behavior:** All pages are laid out in one vertical column inside a scrollable container (`overflow-auto`, `overscroll-contain`, `overflowAnchor:"none"`). Each page slot always exists (preserving scroll height) sized `width = (dims?.width ?? 612) * zoom`, `height = (dims?.height ?? 792) * zoom` (defaults are US Letter points, constants DEFAULT_PAGE_WIDTH=612 / DEFAULT_PAGE_HEIGHT=792). Only pages within `PAGE_BUFFER = 2` pages above/below the visible range are actually rendered (center = visiblePages, or [currentPage] if empty; range = max(1, first-2) .. min(numPages, last+2)); other slots render a plain white placeholder div. Rendered pages use `devicePixelRatio = min(window.devicePixelRatio, 1.5)` (memoized once). The text layer is rendered only for pages that are currently visible or equal to currentPage; the pdf.js annotation layer is always disabled (`renderAnnotationLayer={false}`). Page onLoadSuccess reports unscaled `originalWidth/originalHeight` back into pageDimensions (no-op if unchanged). A `HighlightLayer` overlay is rendered on a page only when that page has annotations (annotations are pre-indexed into a Map keyed by `page_number`). The whole Document is wrapped in an ErrorBoundary.

**UI:** Container: fills remaining space (`relative min-h-0 min-w-0 flex-1`), background `bg-well` (light `#ece8df`, dark `#121110`); cursor becomes crosshair in note mode. Pages wrapper: `mx-auto flex w-max min-w-full flex-col items-center gap-3 py-4` — i.e. pages horizontally centered, 12px vertical gap between pages, 16px top/bottom padding. Each page slot: `relative w-fit rounded-sm shadow-page ring-1 ring-border/50` with `data-page-number={n}` attribute; shadow-page = `0 2px 8px rgba(33,29,24,0.1), 0 1px 2px rgba(33,29,24,0.06)` light / `0 2px 12px rgba(0,0,0,0.5)` dark. Placeholder: `h-full w-full bg-white`.

### Scroll tracking / current page detection

**Behavior:** On container scroll (and after zoom/page-count changes), a requestAnimationFrame-throttled handler runs (skipped entirely while a zoom is settling): it computes scroll delta vs the last known position; if a real scroll event moved >1px in either axis while a text selection popover is open, the selection is cleared. It then walks all mounted page elements, computing each page's top/bottom (wrapper offsetTop + element offsetTop / +offsetHeight) against the viewport (scrollTop .. scrollTop+clientHeight). Pages overlapping the viewport form `visiblePages` (sorted ascending). The "dominant" page — the one with the largest pixel overlap, ties broken by lower page number — becomes `currentPage` via setCurrentPage. If numPages < 1, visiblePages is set to []. If no page overlaps, neither value changes. setVisiblePages/setCurrentPage are no-ops when the value is unchanged (array compared element-wise).

Initial scroll: exactly once per document, after pdfData is set AND numPages >= 1 AND dimensionsReady, two nested requestAnimationFrames fire, then `scrollToPage(min(numPages, initialPage))` where initialPage was captured from the store at document-change time (i.e. the tab's restored `last_page`), followed by a scroll-tracking pass. scrollToPage uses `scrollIntoView({behavior:"auto", block:"start"})` on the page element. `scrollToPage` is exposed globally as `window.__scrollToPage` for the toolbar/sidebar/shortcuts (deleted on unmount).

### Zoom (buttons, keyboard, anchored zoom, pinch/wheel)

**Behavior:** Zoom range MIN_ZOOM=0.25 to MAX_ZOOM=4.0, always clamped. Store `setZoom` clamps; `zoomIn`/`zoomOut` step by ZOOM_STEP=0.1 (additive) and prefer the viewer's global `window.__zoomPdfTo(target)` (anchored zoom, anchor = viewport center) when the viewer is mounted, falling back to plain setZoom. There is NO fit-width/fit-page mode — only the numeric scale. The toolbar % button resets to 1.0 via the same anchored path.

Anchored zoom mechanics (must be replicated): before changing zoom, capture a snapshot: anchor point in container coords (pointer position, or container center if none), the content-space coordinates of that point, the page whose vertical span contains the pointer (or nearest page by center distance), and the pointer's relative position within that page (relX/relY, clamped 0..1). After the zoom state updates (layout effect), restore scroll so that `pageOrigin + rel * newPageSize - anchor` becomes the new scrollLeft/scrollTop (falling back to scaling raw content coords if the page element is gone); this is applied immediately and again one animation frame later, then the settling flag clears and scroll tracking re-runs. Zoom changes smaller than 0.0001 are ignored.

Pinch-to-zoom: two input paths on the scroll container, active only while a PDF is loaded. (a) WebKit GestureEvents: gesturestart captures a pinch state (baseZoom, anchor snapshot at gesture clientX/clientY if present) and sets a CSS `transform-origin` at the content point; gesturechange applies a damped preview `scale = 1 + (ge.scale - 1) * 0.55` (GESTURE_SCALE_DAMPING=0.55) as a CSS `transform: scale()` on the pages wrapper (no re-render), and schedules an idle-commit; gestureend commits. (b) Chromium-style ctrl+wheel: preventDefault; begins a pinch preview at the cursor if not active; per event, deltaY clamped to ±8 (MAX_WHEEL_DELTA), `zoomFactor = exp(-clampedDelta * 0.035)` (WHEEL_ZOOM_SENSITIVITY=0.035), the preview scale multiplies by it (clamped so baseZoom*scale stays within 0.25..4). Commit happens 90ms after the last gesture/wheel event (idle timer), or immediately on gestureend, on a non-ctrl wheel event, or on any scroll during the pinch. Commit removes the CSS transform and performs an anchored zoom to `clamp(baseZoom * scale)` using the captured snapshot. Keyboard: Cmd/Ctrl+= zoomIn, Cmd/Ctrl+- zoomOut (global, preventDefault).

**UI:** During pinch preview the wrapper gets `will-change: transform` and `transform-origin` at max(0, contentX/Y) px; the scale transform visually previews without reflowing pages.

**Shortcuts:** Cmd/Ctrl + `=` → zoom in one step (+0.1). Cmd/Ctrl + `-` → zoom out one step (−0.1). Trackpad pinch and Ctrl+scroll-wheel → continuous anchored zoom.

### Page navigation (toolbar input, prev/next, goToPage)

**Behavior:** Store `goToPage(page)`: ignored while numPages < 1; clamps to 1..numPages, calls setCurrentPage(clamped), then calls `window.__scrollToPage(clamped)` if the viewer is mounted. Toolbar has prev/next chevron buttons calling goToPage(currentPage±1), disabled at bounds (currentPage<=1 / >=numPages). The page-number field is a local-state controlled `<input type="number" min=1 max=numPages>`; it resyncs to currentPage whenever currentPage changes; commit happens on blur (Enter just blurs, so commit runs once): `parseInt(value,10)`; if NaN or out of [1, numPages] the input reverts to the current page, otherwise goToPage(value). There are no thumbnails and no in-document text search anywhere in this subsystem.

**UI:** Between the chevrons: the input (`h-7 w-11` = 28×44px, rounded-md, border, bg-surface, centered text, text-sm, native number spinners hidden) followed by ` / {numPages}` in muted-foreground, all `text-sm tabular-nums`. Prev button title `Previous page` (ChevronLeft 16px), next `Next page` (ChevronRight 16px).

### Text selection & selection popover

**Behavior:** Selection is native browser text selection over the pdf.js text layer. On container mouseUp, after a 10ms delay (letting the browser finalize the selection): if the window selection is non-collapsed with non-empty trimmed text, take range.getClientRects(); find the ancestor with `[data-page-number]` from the mouseup target (abort if none); convert every client rect to page-relative coordinates divided by the current store zoom (normalized to zoom=1): `{x:(r.left-pageRect.left)/zoom, y:(r.top-pageRect.top)/zoom, width:r.width/zoom, height:r.height/zoom}`; build PositionData `{rects, page_width: pageEl.clientWidth/zoom, page_height: pageEl.clientHeight/zoom, selected_text: text, start_offset: null, end_offset: null}`; set popover position at the horizontal center of the LAST client rect, 10px above its top (screen coords); store `{text, positionData, pageNumber}`. The SelectionPopover component (annotation subsystem) is rendered at that position. Dismissal: (1) mousedown anywhere outside the popover → after 10ms, if the window selection is collapsed, clear; (2) any meaningful (>1px) real scroll of the container clears the selection; (3) explicit onClose. clearSelection also calls `window.getSelection().removeAllRanges()`.

### Sticky-note mode, click handling & right-click context menu

**Behavior:** Interaction mode is `"view" | "note"` (per-tab). Toolbar StickyNote button and the `n` key (only when a document is open and focus is not in an input/textarea; without Cmd/Ctrl) toggle between them; Escape returns to view mode and deselects any annotation. In view mode, clicking a page (or the gray container background itself) deselects the selected annotation. In note mode, clicking a page reads `data-page-number`, converts the click point to zoom-normalized page coords (`(clientX-rect.left)/zoom` etc.), and creates a note annotation via the annotation store: `{type:"note", page_number, position_data:{rects:[{x,y,width:0,height:0}], page_width, page_height, selected_text:null, start_offset:null, end_offset:null}}`; on success the new annotation is selected; failures log `[PdfViewer] Failed to add note:`; the mode then always returns to "view".

Right-click on a page: preventDefault; store a context-menu state with screen x/y plus the zoom-normalized click coords and page size. The menu shows a single item, `Add note here`, which creates the identical note annotation at the stored point (error log: `[PdfViewer] Failed to add note via context menu:`) and closes the menu. The menu dismisses on any window click or any scroll (capture phase). Clicks inside the menu stopPropagation.

**UI:** Context menu: fixed-position at click point, z-50, `min-w-[160px]`, rounded-lg, border, bg-background, `py-1`, shadow-lg. Item: full-width row, `gap-2 px-3 py-1.5 text-sm text-left hover:bg-accent`, StickyNote icon 14px in `text-amber-500`, label `Add note here`. Note-mode cursor over the viewer: crosshair.

**Shortcuts:** `n` (no modifier, focus not in a text field) → toggle note mode. `Escape` → deselect annotation + force view mode.

### Toolbar (every control)

**Behavior:** Order left→right (11px-high bar; PDF tabs — web-only controls noted): 1) Open file — FolderOpen 16, title `Open file (⌘O)` (non-mac `Ctrl+O`), opens multi-select dialog with filters Documents(pdf,vellumweb)/PDF/Vellum Web Archive, then `openFiles`. 2) Add webpage — Globe 16, title `Add webpage (⌘L)`, toggles a URL prompt popover (also opened by the global `vellum:add-webpage` event fired by Cmd/Ctrl+L); when opened the input clears and focuses next frame; Enter or the `Open` button submits (trim; empty → just close; else `openUrl(value)`), Escape closes. 3) Save (PDF tabs only) — Save 16, title `Save (⌘S)`, calls `save_file(activeTabId)`, errors silently swallowed. (Web tabs instead get Back/Forward ArrowLeft/ArrowRight buttons titled `Back`/`Forward` calling `window.__webHistory(±1)`.) Then, only when a document is open: divider; Previous/page-input/`/ N`/Next (see page navigation); divider; Zoom out (ZoomOut 16, title `Zoom out`), zoom % reset button showing `Math.round(zoom*100)%` with title `Reset zoom to 100%` (anchored zoom to 1.0, fallback setZoom(1)), Zoom in (ZoomIn 16, title `Zoom in`); divider; Bookmark — Bookmark 16, filled with currentColor and tinted `text-gold` when the current page has a bookmark (computed via `findCurrentBookmark(annotations, doc.kind, currentPage, webVisibleBookmarks)`), title `Remove bookmark` when bookmarked else `Bookmark this page` (PDF) / `Bookmark this spot` (web); click → annotation store `toggleBookmark()`. Sticky note tool — StickyNote 16, variant "active" when mode=="note", title (PDF) `Sticky note tool (N) — click on the page to place a note` / (web) `Sticky note tool (N) — click in the page to attach a note to the text there`; toggles mode. Web-only after a divider: Archive save-to-library button (Archive 16, tinted text-primary when saved, titles `Saved to library — click to remove` / `Save page to library (keeps an offline snapshot)`, optimistic toggle calling `set_webpage_saved`, reverting on error; saved state initialized from `get_webpage_saved` per tab); Export .vellumweb button (Share 16, LoaderCircle spinning while exporting, disabled then; green `text-emerald-600` on done, destructive on error; idle title `Export as .vellumweb (portable archive with snapshot + annotations)`, otherwise the status detail — success detail format `Exported {mb} MB ({n} assets{, k skipped})`; exports via a save dialog defaulting to a slugified title `{slug}.vellumweb`, slug = lowercased title, non-alphanumeric runs → `-`, trimmed of `-`, max 60 chars, fallback `article`); and a truncated URL label (max-w-64, xs, muted, scheme stripped via `replace(/^https?:\/\//,"")`, full URL in title).

Right cluster (ml-auto): update status chip (shown only when status is available/downloading/restarting/error): pill button labeled `Update {version}` (with Download 12 icon) / `Downloading update` or `Downloading {n}%` (spinner) / `Restarting...` (spinner) / `Update failed`; clicking installs when available or re-checks on error; disabled otherwise. Check-for-updates IconButton — RefreshCw 16 (spinner while checking), disabled while checking/downloading/restarting, title = current update message (`Check for updates` initially; `Checking for updates...`; `You are up to date`; `Update {v} is ready to install` (+ `\n\n{release notes}` appended when present); error message text). A silent check runs on mount. Install flow drives Tauri updater downloadAndInstall with Started/Progress/Finished events computing percent, then `Restarting to finish the update...` and relaunch. ThemeToggle button. Finally, when a doc is open and the App provides the handler: divider + side-panel toggle — PanelRight 16, variant "active" when open, title/aria `Hide side panel` / `Show side panel` (App defaults sidebar open, width 320px, containing Annotations/AI segmented control).

**UI:** Bar: `relative flex h-11 items-center gap-0.5 border-b bg-background px-2` (44px tall). Dividers: `mx-1.5 h-5 w-px bg-border`. IconButtons: 28×28 (`h-7 w-7`), rounded-md, ghost variant = muted-foreground, hover bg-accent + foreground, disabled opacity-30; active variant = bg-primary text-primary-foreground. URL prompt popover: absolute at left-2 top-11 (below bar), z-50, mt-1, w-96 (384px), flex gap-1.5, rounded-lg border bg-background p-2 shadow-lg; input h-8 flex-1 rounded-md border bg-surface px-2 text-sm, placeholder `Paste an article URL…`; Open button h-8 bg-primary px-3 text-xs font-medium. Update chip: h-7 rounded-full border px-2.5 text-xs font-medium; available = emerald tint (`border-emerald-500/30 bg-emerald-500/10 text-emerald-700`, dark `text-emerald-300`); downloading/restarting = `border-primary/20 bg-primary/10`; error = destructive tint. Gold bookmark tint: `#a9791b` light / `#d6a93b` dark. Zoom % button: h-7 min-w-[3.25rem] rounded-md text-sm tabular-nums muted-foreground, hover bg-accent.

**Shortcuts:** Global (window keydown, Cmd on mac == Ctrl elsewhere): ⌘O open files; ⌘L open add-webpage prompt; ⌘S save active tab; ⌘W (case-insensitive) close active tab; ⌘1–⌘9 activate tab by index (only if it exists); ⌘= zoom in; ⌘- zoom out; ⌘B toggle bookmark (only when a doc is open); Escape deselect+view mode; `n` toggle note mode. Tooltip strings use `⌘X` on macOS and `Ctrl+X` elsewhere.

### Tab bar (multiple open documents)

**Behavior:** Horizontal tab strip above the toolbar; always visible (even with zero tabs, showing just the wordmark and + button). One tab per open document (PDF or web); tab id == backend session id. Label: `document.title` if non-blank after trim, else the last path segment with a trailing `.pdf` stripped case-insensitively, else `Untitled`; full `pdf_path` as the hover title. Clicking a tab's main area activates it — store `activateTab`: no-op if already active; first persists the OUTGOING tab's reading position via `set_document_metadata(prevTabId, "last_page", String(prevTab.currentPage))` (fire-and-forget), then swaps all active viewport fields (document, currentPage, numPages, zoom, visiblePages, webVisibleRange, webVisibleBookmarks, mode) from the target tab's saved copy — every per-tab field survives switching, including zoom and mode. Middle-click (button 1) anywhere on a tab closes it (preventDefault). The X button (visible on hover/focus) closes it (stopPropagation so it doesn't activate). Close (`closeTab`): persists `last_page` = tab.currentPage via set_document_metadata (errors swallowed), calls `close_file(tabId)` (errors swallowed), removes the tab; if it was active, the next active tab is `tabs[min(closingIndex, tabs.length-1)]` (i.e. the tab that slid into its slot, else the new last tab), or the empty state (welcome screen) if none remain. `closeFile` (⌘W) closes the active tab. The + button opens the file dialog (filter: PDF only) and opens selections as new tabs. ⌘1–⌘9 activate tabs by index. The PdfViewer/WebViewer is keyed by activeTabId, so switching tabs fully remounts the viewer and re-fetches bytes.

**UI:** Bar: `flex h-10 items-center gap-2 border-b bg-background pl-3 pr-2` (40px). Leftmost: Vellum wordmark — serif, 15px, font-semibold, tracking-tight, `Vellum` + primary-colored `.`; a 20px×1px divider follows when tabs exist. Tab list scrolls horizontally (`overflow-x-auto py-1`, flex gap-1). Tab: `h-7 min-w-32 max-w-56` (28px tall, 128–224px wide), rounded-md, text-xs; active = `bg-surface text-foreground shadow-soft ring-1 ring-border-strong`; inactive = muted-foreground, hover bg-accent + foreground. Contents: FileText icon 13px (text-primary when active, muted otherwise), truncating label, then close X (12px) in a 20×20 rounded button, opacity 0 until group hover or focus-visible, mr-1, aria-label `Close {label}`. + button: standard 28×28 IconButton, Plus 16, title/aria `Open PDF in new tab`.

**Shortcuts:** ⌘/Ctrl+1…9 → activate nth tab. ⌘/Ctrl+W → close active tab. Middle-click tab → close.

### Reading-session persistence & auto-save

**Behavior:** Reading position (`last_page`) is written into the PDF itself at three moments: (1) when a tab is deactivated (switching away), (2) when a tab is closed, both via `set_document_metadata(sessionId, "last_page", String(currentPage))` with errors ignored; (3) `page_count` is written every time pdf.js reports numPages — but the Rust side explicitly ignores the `page_count` key (returns Ok without touching the file), since the real count is always recomputed. On next open, `open_file` returns `last_page` from the Info dictionary and the tab starts at that page (initial scroll targets `min(numPages, last_page)`). Zoom, mode, visiblePages are NOT persisted across app restarts — they live only in the in-memory tab and reset to 1.0/"view"/[] on reopen. App-level auto-save: while a document is open, `save_file(activeTabId)` is invoked every 30000ms (and by ⌘S / the Save button); for PDFs this is a no-op sync point (`save_session` returns Ok(())) because every annotation/metadata mutation already rewrites the file immediately. Recents: every successful open (including re-opens and web navigations) prepends an entry to localStorage (see persistence section).

### AI text extraction feed (viewer responsibility)

**Behavior:** The viewer owns feeding the AI store: after document load it extracts each page's text (see loading feature) into `useAiStore.setPageText(pageNum, text)`, and clears the context (`clearDocumentContext`) whenever the document/tab changes or closes. It also registers/unregisters the live pdf.js document with `registerPdfDocument`/`unregisterPdfDocument` (highlight-locator) on load success and on unmount/doc change, so AI actions can resolve text→geometry on unrendered pages. Extraction runs are cancelled by incrementing a run counter on unmount or new document.

## Data models

## TypeScript (frontend)

```ts
// src/stores/pdf-store.ts
export type InteractionMode = "view" | "note";
const MIN_ZOOM = 0.25; const MAX_ZOOM = 4.0; const ZOOM_STEP = 0.1;

interface PdfState {
  // Tab state
  tabs: PdfTab[];
  activeTabId: string | null;          // == backend session id (crypto.randomUUID())
  // Active document state (mirrors the active tab)
  document: DocumentInfo | null;
  isLoading: boolean;
  error: string | null;                // openFiles joins per-file errors: "{path}: {err}\n..."
  // Active viewport state
  currentPage: number;                 // 1-based; default 1
  numPages: number;                    // default 0
  zoom: number;                        // default 1.0, clamped 0.25..4.0
  visiblePages: number[];              // sorted ascending
  webVisibleRange: { start: number; end: number } | null;  // web docs only
  webVisibleBookmarks: string[];       // web docs only
  mode: InteractionMode;               // default "view"
  // Actions
  openFile(path): Promise<void>; openFiles(paths): Promise<void>; openUrl(url): Promise<void>;
  webNavigated(tabId, url): Promise<DocumentInfo | null>;
  updateDocumentTitle(tabId, title): void;
  closeFile(): Promise<void>; closeTab(tabId): Promise<void>; activateTab(tabId): void;
  setCurrentPage(page): void; setNumPages(num): void;
  setZoom(zoom): void; zoomIn(): void; zoomOut(): void;
  setVisiblePages(pages): void; setWebVisibleRange(range): void; setWebVisibleBookmarks(ids): void;
  goToPage(page): void; setMode(mode): void;
}
// Every set*/mode/zoom/page mutator also writes the same field into the active
// tab object (updateActiveTab), so tab switches restore the full viewport.
```

```ts
// src/types/index.ts (serialization: snake_case, matching Rust)
export type DocumentKind = "pdf" | "web";
export interface DocumentInfo {
  kind: DocumentKind;          // Rust defaults missing kind to "pdf"
  pdf_path: string;            // canonical file path for PDFs; normalized URL for web
  title: string | null;
  page_count: number | null;
  last_page: number | null;
}
export interface PdfTab {      // frontend-only, camelCase
  id: string;                  // session id
  document: DocumentInfo;
  currentPage: number; numPages: number; zoom: number;
  visiblePages: number[];
  webVisibleRange: { start: number; end: number } | null;
  webVisibleBookmarks: string[];
  mode: "view" | "note";
}
export type AnnotationType = "highlight" | "note" | "bookmark";
export interface Rect { x: number; y: number; width: number; height: number; }
export interface PositionData {
  rects: Rect[];
  page_width: number; page_height: number;   // zoom=1 CSS-pixel page size
  selected_text: string | null;
  start_offset: number | null; end_offset: number | null;
  prefix?: string | null; suffix?: string | null;      // web only
  viewport_offset?: number | null;                     // web only
}
export interface Annotation {
  id: string; type: AnnotationType; page_number: number;
  color: string | null; content: string | null;
  position_data: PositionData | null;
  created_at: string; updated_at: string;    // RFC3339
}
export interface VellumwebExportSummary { path: string; bytes: number; asset_count: number; assets_skipped: number; }
```

```ts
// src/lib/recent-pdfs.ts
export interface RecentPdf {
  pdf_path: string;            // path or normalized URL
  kind: DocumentKind;          // missing kind in stored data => "pdf"
  title: string | null;
  page_count: number | null;
  opened_at: string;           // new Date().toISOString()
}
```

```ts
// src/hooks/useTextSelection.ts (internal)
interface TextSelection { text: string; positionData: PositionData; pageNumber: number; }
interface PopoverPosition { x: number; y: number; }   // screen/client coords
```

## Rust (backend)

```rust
// commands.rs — serde default snake_case field names (matches TS exactly)
pub struct DocumentInfo {
  #[serde(default = "default_document_kind")]  // -> "pdf"
  pub kind: String,
  pub pdf_path: String,
  pub title: Option<String>,
  pub page_count: Option<u32>,
  pub last_page: Option<u32>,
}
pub enum Session { Pdf(PdfSession), Web(WebSession) }
pub struct AppState { pub sessions: Mutex<HashMap<String, Session>> }  // key = session/tab id

// pdf_session.rs
pub struct PdfSession { pub pdf_path: PathBuf }   // canonicalized

// models.rs
pub struct Annotation {
  pub id: String,
  #[serde(rename = "type")] pub annotation_type: AnnotationType,
  pub page_number: u32,
  pub color: Option<String>, pub content: Option<String>,
  pub position_data: Option<PositionData>,
  pub created_at: String, pub updated_at: String,
}
#[serde(rename_all = "lowercase")]
pub enum AnnotationType { Highlight, Note, Bookmark }
pub struct PositionData {
  pub rects: Vec<Rect>, pub page_width: f64, pub page_height: f64,
  pub selected_text: Option<String>,
  pub start_offset: Option<u32>, pub end_offset: Option<u32>,
  #[serde(default, skip_serializing_if = "Option::is_none")] pub prefix: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")] pub suffix: Option<String>,
  #[serde(default, skip_serializing_if = "Option::is_none")] pub viewport_offset: Option<f64>,
}
pub struct Rect { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }
```

Tauri IPC args are camelCase on the wire (`sessionId`, `pageNumber`, `destPath`) and map to Rust snake_case parameters; payload structs (DocumentInfo, Annotation, PositionData) stay snake_case.

## Persistence

## 1. Reading state INSIDE the PDF file (compatibility contract)

All document metadata is embedded in the PDF's **Info dictionary** (trailer `/Info`; created as an indirect object if missing) by `pdf_annotations::set_metadata`:

| frontend key | PDF Info key | value type | notes |
|---|---|---|---|
| `last_page` | `/VellumLastPage` | integer (also readable as numeric text string) | parsed as u32; write error `"Invalid last_page value: {e}"` on non-numeric |
| `title` | `/Title` | text string | standard key |
| `page_count` | — | — | **silently ignored** (no write) |
| any other `foo_bar` | `/VellumFooBar` | text string | snake_case → `Vellum` + UpperCamelCase suffix |

`document_info(path)` reads back: title = `/Title` decoded (fallback: file stem), page_count = live lopdf page count, last_page = `/VellumLastPage` (Integer→u32, or String parsed).

**Atomicity:** every PDF mutation rewrites the whole file: save to sibling temp file `.{filename}.vellum-{uuid}.tmp`, copy the original file's permission bits onto it, remove `/Prev` and `/XRefStm` from the trailer (full rewrite invalidates old xref offsets), then atomically `rename` over the original (Unix; Windows uses a `.{filename}.vellum-{uuid}.bak` two-step rename with rollback). Errors: `"Failed to write annotated PDF: {e}"`, `"Failed to preserve PDF permissions: {e}"`, `"Failed to replace PDF with annotated copy: {e}"`.

**Corrupt-file recovery:** if lopdf fails to load a PDF, and the raw bytes contain the marker `VellumCreatedAt` (i.e. we wrote it before), the loader blanks any `/Prev <digits>` / `/XRefStm <digits>` entries in the last trailer (or last XRef stream dictionary) with spaces and retries from memory; otherwise error `"Failed to parse PDF: {original}"` (or `"...; recovery also failed: {recovery}"`).

## 2. Annotations INSIDE the PDF (keys the viewer relies on; full detail is the annotations subsystem)

Standard PDF annotations in each page's `/Annots` array. Shared dictionary keys written on create: `/Type /Annot`, `/NM` (UUID string id), `/M` (PDF date `D:YYYYMMDDHHMMSSZ`), `/F 4`, `/T (Vellum)`, `/C` [r g b floats from hex, default #fef08a], `/VellumCreatedAt` + `/VellumUpdatedAt` (RFC3339 strings), `/P` page ref, optional `/Contents`, optional `/VellumSelectedText`. Highlights: `/Subtype /Highlight`, `/CA 0.4`, `/QuadPoints` (8 numbers per rect, order TL TR BL BR in PDF user space, converted via CropBox/MediaBox + /Rotate + /UserUnit geometry), `/Rect` bounding box. Notes: `/Subtype /Text`, `/Name /Note`, `/Rect` = 18pt (NOTE_SIZE=18.0) square at the anchor. Bookmarks are **outline items** (not annots): child of the catalog's `/Outlines` root, keys `/Title (Bookmark - page {n})`, `/Parent`, `/Dest [pageRef /Fit]`, `/VellumType /Bookmark`, `/VellumNM` (UUID), `/VellumCreatedAt`, `/VellumUpdatedAt`, linked via `/Prev`/`/Next`/`/First`/`/Last` with `/Count` maintained. Default colors: highlight `#fef08a`, note `#fde68a`. IDs for foreign annots without `/NM`: `pdf-{obj}-{gen}` or `pdf-direct-{page}-{index}`.

## 3. localStorage (frontend)

Key `vellum.recent-pdfs`: JSON array, max 8 entries (MAX_RECENT_PDFS), newest first, deduped by `pdf_path`. Example payload:
```json
[{"pdf_path":"/Users/me/paper.pdf","kind":"pdf","title":"Attention Is All You Need","page_count":15,"opened_at":"2026-07-03T10:12:00.000Z"}]
```
Read validation: entries must have string `pdf_path`, title string|null, page_count number|null, string `opened_at`; missing `kind` is coerced to `"pdf"`; kind must be `"pdf"`|`"web"`. Read/write failures are swallowed (recents are best-effort).

## 4. What is NOT persisted

Zoom level, interaction mode, visible pages, sidebar open state, and the tab set itself all reset on app restart. Only `last_page` (per PDF, in-file) and recents survive.

## 5. Web-tab persistence pointers (other subsystem)

Web tabs persist to a JSON sidecar + snapshot under the Tauri `app_data_dir` (`web_page.rs`), and `.vellumweb` ZIP archives under a managed library path — the toolbar buttons above call into these but the formats belong to the web-viewing spec.

## IPC commands

All invoked via `invoke(name, args)`; arg names below are the exact wire (camelCase) keys. Errors are plain strings.

| Command | Args | Returns | Behavior / errors |
|---|---|---|---|
| `open_file` | `path: string`, `sessionId: string` | `DocumentInfo` | Validate extension == pdf (`"Unsupported file type: .{ext}"`), canonicalize (`"Failed to resolve PDF path {p}: {e}"`), require file (`"PDF path is not a file: {p}"`), lopdf parse (`"Failed to parse PDF: {e}"`). Reads title/page_count/`VellumLastPage`. Stores session (closing any previous session under the same id). |
| `read_pdf_bytes` | `sessionId` | binary `ArrayBuffer` (tauri::ipc::Response) | Reads the whole file from disk each call. Errors: `"No session found for tab {id}"`, `"This tab is a webpage, not a PDF"`, `"Failed to read PDF at {path}: {e}"`. |
| `save_file` | `sessionId` | `void` | Sync point; for PDFs a no-op Ok (mutations already saved). Error: `"No session found for tab {id}"`. Called by ⌘S, Save button, 30s auto-save timer. |
| `close_file` | `sessionId` | `void` | Removes session from the map (no-op if absent), runs the same sync. |
| `set_document_metadata` | `sessionId`, `key: string`, `value: string` | `void` | Writes Info-dictionary metadata (see persistence table). `page_count` ignored. `last_page` must parse as u32. Fired on tab switch (outgoing tab) and tab close with `key="last_page"`, and after numPages is known with `key="page_count"`. |
| `get_annotations` | `sessionId`, `pageNumber: number \| null` | `Annotation[]` | All embedded annots + outline bookmarks, sorted by (page_number, created_at). Used by annotation store on doc change. |
| `create_annotation` | `sessionId`, `input: CreateAnnotationInput` | `Annotation` | Embeds a standard PDF annotation / outline bookmark; `"Page {n} does not exist"` if bad page. Used by viewer note placement (via annotation store). |
| `update_annotation` | `sessionId`, `input: UpdateAnnotationInput` | `boolean` | false if id not found. |
| `delete_annotation` | `sessionId`, `id: string` | `boolean` | Bookmarks first, then page annots. |
| `open_web_document` | `url`, `sessionId` | `DocumentInfo` (kind "web") | Toolbar URL prompt / web tab in-place navigation (reusing the tab's session id rebinds it). |
| `open_vellumweb_file` | `path`, `sessionId` | `DocumentInfo` (kind "web") | Chosen automatically when an opened path ends in `.vellumweb`; imports archive, merges annotations, then dispatches window event `vellum:annotations-updated`. |
| `get_webpage_saved` | `sessionId` | `boolean` | PDFs return false. Toolbar Archive-button init. |
| `set_webpage_saved` | `sessionId`, `saved: boolean` | `void` | PDF tabs error `"This tab is a PDF, not a webpage"`. |
| `export_vellumweb` | `sessionId`, `destPath`, `pages: {number,text}[]` | `VellumwebExportSummary {path,bytes,asset_count,assets_skipped}` | PDF tabs error `"PDFs are already portable — archiving applies to webpage tabs"`. Toolbar Share button. |

Cross-component window globals (viewer ↔ store/toolbar, not IPC): `window.__scrollToPage(page)` (viewer registers; goToPage calls), `window.__zoomPdfTo(target)` (viewer registers; zoomIn/zoomOut/reset call for anchored zoom), `window.__webHistory(delta)` (web viewer). Window CustomEvents: `vellum:add-webpage` (⌘L → toolbar prompt), `vellum:annotations-updated` (archive import → annotation reload).

Plugin calls: `@tauri-apps/plugin-dialog` `open({multiple:true, filters})` and `save({defaultPath, filters})`; Tauri updater plugin via `app-updates` wrapper.

## External APIs

This subsystem makes no direct HTTP calls. Two indirect network surfaces appear in the Toolbar:

1. **App updater** (`@/lib/app-updates` wrapping the Tauri updater plugin, `checkForAppUpdate()` / `AppUpdate.downloadAndInstall(cb)` / `relaunchForUpdate()`): checks the configured Tauri update endpoint. Download callback events: `{event:"Started", data:{contentLength?}}`, `{event:"Progress", data:{chunkLength}}`, `{event:"Finished"}`. Progress % = round(downloadedBytes/contentLength*100), capped 100. Swift equivalent would be Sparkle or a custom appcast — behavior contract is only the toolbar UI states described in the toolbar feature.

2. **Webpage opening / .vellumweb export** (`open_web_document`, `export_vellumweb`) fetch web content server-side in Rust — that belongs to the web-viewing subsystem; the toolbar only invokes the IPC commands.

PDF bytes never cross the network: they are read from local disk by Rust and passed over Tauri IPC as a binary `Response` (ArrayBuffer on the JS side).

## Porting notes

**PDFKit mapping.** `PDFView` with `displayMode = .singlePageContinuous` and `autoScales = false` reproduces the vertical continuous layout; `scaleFactor` maps to `zoom` (clamp 0.25–4.0, step 0.1). PDFKit gives pinch-to-zoom, text selection, and page virtualization for free — you do NOT need to port the CSS-transform pinch preview, the ZoomAnchorSnapshot machinery, the 2-page render buffer, the ≤1.5 devicePixelRatio cap, or the white placeholder divs; those exist only because DOM re-rendering is slow. What you MUST preserve: the zoom clamp/step values, zoom anchoring at the cursor/viewport-center (PDFKit anchors pinch at the gesture location natively; for the toolbar ± buttons anchor at the visible-rect center), and the *current page* rule — PDFKit's `currentPage` is not "largest visible overlap, ties to lower page number"; if you want identical toolbar behavior, compute dominant page from `visibleRect` overlap per page like `handleScroll` does. Track `visiblePages` similarly (pages intersecting the visible rect) since the annotation sidebar and page-buffer semantics depend on it.

**Load by path, not bytes.** `read_pdf_bytes` exists only because the WebView cannot read disk. In Swift, open `PDFDocument(url:)` directly from the canonicalized path. Keep the validation/error strings from `open_file` if you want identical error surfaces. Note the file is re-read from disk on every tab activation (viewer remounts keyed by tab id) — external edits appear on tab switch; decide whether to keep that.

**Persistence contract is the PDF itself.** Use PDFKit/CoreGraphics or a small PDF library to write `/VellumLastPage` into the Info dictionary on tab switch/close and read it on open. Beware: PDFKit's `PDFDocument.write(to:)` rewrites the file and may drop the custom Info keys or annotations' custom entries (`/VellumCreatedAt`, `/VellumSelectedText`, `/VellumNM` on outline items) — verify round-tripping, or keep the lopdf-style full-rewrite in a Rust/C helper. The temp-file + permission-preserving atomic rename must be kept (users' PDFs are the database). Also keep the `page_count` write being a no-op.

**Coordinate systems.** All frontend PositionData is top-left-origin, y-down, in CSS pixels at zoom=1, relative to the *displayed* (rotation-applied) page box; the Rust layer converts to PDF user space handling CropBox-else-MediaBox origin offsets, /Rotate (90/180/270), and /UserUnit. PDFKit works in bottom-left-origin page space with rotation handled by the view — if you keep the on-disk format (QuadPoints etc., which are standard), you can let PDFKit map geometry, but any code reading/writing PositionData JSON (web tabs, .vellumweb archives) must keep the top-left convention.

**Text selection popover.** Use `PDFViewSelectionChanged` / mouse-up detection; compute selection rects per line via `selection.selectionsByLine()` and convert with `PDFView.convert(_:from:)`, dividing by scaleFactor to normalize to zoom=1. Popover position = centered above the *last* line rect, 10px up. Preserve the dismissal rules: click-outside clears only if no new selection formed; a meaningful scroll (>1px) clears it.

**No search, no thumbnails, no fit modes.** Do not add PDFKit's `PDFThumbnailView`, `autoScales`, or find UI — the app has none of these; zoom is purely numeric with a 100% reset.

**Tabs.** No native equivalent needed — a custom SwiftUI tab strip. Key behaviors: dedupe by canonical path (activate existing tab, discard new session), middle-click close (macOS: `otherMouseUp`), close-selection rule `tabs[min(closingIndex, count-1)]`, per-tab retained state (page, zoom, mode, visiblePages), persist last_page on switch-away and close, ⌘1–9/⌘W shortcuts. The viewer is remounted per tab in React; in Swift you can instead keep one PDFView and swap documents, but you must then manually restore page+zoom from the tab record and reset selection/mode.

**Keyboard shortcuts** map to NSMenu items / `.keyboardShortcut`: ⌘O, ⌘L, ⌘S, ⌘W, ⌘1–9, ⌘=, ⌘-, ⌘B, plain `n` (guard: no text field focused), Escape. The `n` and Escape handlers need first-responder-aware handling (NSEvent local monitor) since they're bare keys.

**Global window hacks** (`__scrollToPage`, `__zoomPdfTo`, CustomEvents) become direct method calls/notifications — they exist only to bridge React component boundaries.

**Text extraction for AI**: PDFKit `page.string` replaces the pdf.js getTextContent pass; keep the whitespace collapsing (`\\s+`→single space, trimmed) and per-page keying, run it off the main thread with cancellation on tab switch, and keep dimension reads (page bounds for `.cropBox` display size) feeding placeholder sizing if you virtualize manually.

**Updater**: Tauri updater has no Swift equivalent; Sparkle is the natural replacement. The toolbar chip states (available/downloading %/restarting/error) and tooltip strings are the spec if parity is desired.

**Colors/typography** come from CSS custom properties (light/dark): well `#ece8df`/`#121110`, surface `#ffffff`/`#232220`, gold `#a9791b`/`#d6a93b`, page shadow `0 2px 8px rgba(33,29,24,0.1), 0 1px 2px rgba(33,29,24,0.06)` light / `0 2px 12px rgba(0,0,0,0.5)` dark. Icons are lucide (FolderOpen, Globe, Save, ChevronLeft/Right, ZoomIn/Out, Bookmark, StickyNote, Archive, Share, Download, LoaderCircle, RefreshCw, PanelRight, FileText, Plus, X, ArrowLeft/Right) at 16px in the toolbar, 13px in tabs — use SF Symbols equivalents at matching point sizes.

