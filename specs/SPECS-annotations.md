> **HISTORICAL — describes the pre-port Tauri app, not the current SwiftUI app.**
> Written as reference material for the Tauri→SwiftUI port (2025–2026). The current
> app has diverged (e.g. 5 streaming AI providers and 5 tools vs. the 3 non-streaming
> providers / 3 tools described here; no Codex CLI provider; repo-root layout, not
> `macos/`). Do not treat file paths, behavior, or UI specs here as current.

# SPEC: annotations

## Overview
The annotations subsystem lets users create, view, edit, move, and delete three annotation types — text highlights, sticky notes, and bookmarks — on PDF pages (a parallel web-page path exists but is a separate subsystem). Frontend state lives in a Zustand store with optimistic updates; all persistence goes through Tauri IPC to Rust code (`pdf_annotations.rs`) that embeds annotations directly in the PDF file as standard PDF annotation dictionaries (highlights = `/Highlight`, notes = `/Text`) and bookmarks as standard `/Outlines` entries, augmented with custom `Vellum*` keys. Files are rewritten atomically (temp file + rename) so annotations survive file moves and are readable by third-party PDF viewers. A text locator (`highlight-locator.ts`) resolves a text query to page geometry via pdf.js so the AI assistant can create highlights on unmounted pages.

## Features

### Text selection capture (useTextSelection hook)

**Behavior:** Bound to `onMouseUp` of the PDF scroll container. On mouseup: capture `e.target`, then after a **10 ms setTimeout** (lets the browser finalize selection): read `window.getSelection()`; bail if null, collapsed, or `rangeCount === 0`. `text = sel.toString().trim()`; bail if empty. Take `range.getClientRects()`; bail if 0 rects. Find ancestor of the mouseup target matching `[data-page-number]` (each page wrapper div carries this attribute); bail if none. `pageNumber = parseInt(attr ?? "1", 10)`. Convert every client rect to page-relative coordinates normalized to zoom = 1 using the store zoom value (NOT CSS measurement): `x = (r.left - pageRect.left)/zoom`, `y = (r.top - pageRect.top)/zoom`, `width = r.width/zoom`, `height = r.height/zoom`. Build `PositionData { rects, page_width: pageEl.clientWidth/zoom, page_height: pageEl.clientHeight/zoom, selected_text: text, start_offset: null, end_offset: null }`. Popover position (viewport/fixed coords): above the LAST client rect — `x = lastRect.left + lastRect.width/2`, `y = lastRect.top - 10`. Dismissal: while a selection is active, a `mousedown` anywhere outside the popover element starts a **10 ms** timer; if the browser selection is then null/collapsed, clear selection + popover. `clearSelection()` also calls `window.getSelection()?.removeAllRanges()`.

**UI:** No UI itself; provides `selection`, `popoverPosition`, `popoverRef`, `clearSelection`, `handleMouseUp` to PdfViewer.

### Selection popover (SelectionPopover)

**Behavior:** Rendered when both `selection` and `popoverPosition` exist. Clicking a color swatch: calls `onClose()` (clears selection) then `addHighlight({ type: "highlight", page_number: selection.pageNumber, color, position_data: selection.positionData })`. Clicking the note button toggles an inline note-input row. Note input: Enter or the "Add" button submits — no-op if `noteText.trim()` empty; otherwise closes popover and calls `addNote({ type: "note", page_number, content: noteText.trim(), position_data: selection.positionData })` (note anchors at the selection's first rect and carries the quoted `selected_text`). Escape in the input calls `onClose()`.

**UI:** Outer div: `position: fixed; z-index: 50`, `left/top` = popover position, `transform: translate(-50%, -100%)` (so it hangs above and centered), column layout with 4px gap, items centered. Main bar: horizontal flex, gap 4px, `rounded-lg border bg-background p-1.5 shadow-lg`. Contains 5 color buttons — one per HIGHLIGHT_COLORS entry — each 24×24px (`h-6 w-6`), `rounded-full border border-border`, `backgroundColor: color.value`, hover scales to 1.10, tooltip `Highlight {Name}` (e.g. "Highlight Yellow"). Then a vertical divider (`mx-1 h-5 w-px bg-border`), then a note button: 24×24 round, `MessageSquarePlus` icon at 14px, muted-foreground, hover bg-accent. Note input row (when toggled): width 256px (`w-64`), `rounded-lg border bg-background p-2 shadow-lg`, contains a text input (flex-1, `rounded border bg-muted px-2 py-1 text-sm`, focus ring-1 ring-primary, placeholder "Add a note...", autoFocus) and an "Add" button (`rounded bg-primary px-2 py-1 text-xs text-primary-foreground`, hover bg-primary/90).

**Shortcuts:** Within note input: Enter = add note; Escape = close popover.

### Highlight rendering + highlight edit popover (HighlightLayer)

**Behavior:** One HighlightLayer per rendered page, receives `zoom` (render scale) and that page's annotations. Filters: highlights = type "highlight" with position_data; notes = type "note" with position_data; renders nothing if both empty. Each highlight renders one absolutely-positioned div PER rect. `mousedown` on a rect: preventDefault + stopPropagation, then `selectAnnotation(id)` (preventDefault stops a new text selection from starting). `click` is stopPropagation only. When the selected annotation is a highlight on this page, an edit popover appears above its FIRST rect. Color button click: `updateAnnotation({ id, color: color.value })`. "Unhighlight" click: `deleteAnnotation(id)`. Deselection happens when clicking page background (view mode), container background, or pressing Escape (global).

**UI:** Layer: `absolute inset-0 pointer-events-none` over the page. Highlight rect div: `pointer-events-auto absolute z-20 cursor-pointer rounded-sm`, `left = rect.x*zoom`, `top = rect.y*zoom`, `width = rect.width*zoom`, `height = rect.height*zoom`, `backgroundColor = annotation.color ?? "#fef08a"`, opacity 0.40, hover opacity 0.60, when selected: `ring-2 ring-primary` and opacity 0.60. Tooltip = `annotation.content ?? position_data.selected_text ?? none`. Edit popover: `pointer-events-auto absolute z-30 rounded-md border bg-background px-2 py-1.5 shadow-md`, positioned at `left = (rect0.x + rect0.width/2)*zoom`, `top = rect0.y*zoom - 8`, `transform: translate(-50%, -100%)`. Row 1 (margin-bottom 4px): the 5 HIGHLIGHT_COLORS swatches, 20×20px (`h-5 w-5`) round, `border border-border`, hover scale 1.10, current color marked with `ring-2 ring-primary ring-offset-1`, tooltip `Set highlight color: {Name}`. Row 2: full-width button `rounded border px-2 py-1 text-xs`, hover bg-accent, `Trash2` icon 12px + label "Unhighlight", tooltip "Remove highlight".

### Sticky notes (StickyNoteOverlay)

**Behavior:** One overlay per note annotation, anchored at `position_data.rects[0]` (zero-size point rect). Two visual states: collapsed pill and expanded card; expanded when `isSelected || isEditing`. **Auto-edit on creation**: a ref `wasJustCreated = !annotation.content` at mount; when the note becomes selected and that flag is set, a requestAnimationFrame later it enters editing mode (so a freshly placed note opens straight into the textarea). Editing focuses the textarea via effect. **Dragging**: mousedown on the collapsed pill or on the expanded card's header starts drag tracking (window mousemove/mouseup listeners). Movement below a **3 px threshold** in both axes counts as a click, not a drag. During drag, offset = `(clientDx/zoom, clientDy/zoom)`, applied visually via rAF-throttled state. On mouseup after a real drag with nonzero offset: `updateAnnotation({ id, position_data: { ...position, rects: rects.map((r,i) => i===0 ? {x: r.x+dx, y: r.y+dy, ...} : r) } })` — only rects[0] moves. Click fallback on collapsed pill: if not selected → select; else if not editing → start editing. **Editing/saving**: textarea; save persists ONLY if `editText.trim() !== (annotation.content ?? "")`, via `updateAnnotation({ id, content: trimmed })`. Save triggers: textarea blur; Escape (also deselects). Close button (X): persists edit if changed, exits editing, deselects. Delete button: `deleteAnnotation(id)`. Clicking the non-editing content paragraph starts editing. Notes with invalid position_data (missing/empty rects) render nothing.

**UI:** Wrapper: `pointer-events-auto absolute z-10`, `left = (anchor.x + dragOffset.x)*zoom`, `top = (anchor.y + dragOffset.y)*zoom`. COLLAPSED pill: button, flex row gap 4px, `rounded-md border px-1.5 py-1 shadow-md`, cursor grab (grabbing while active), hover scale 1.05 + shadow-lg; light: border amber-300 (#fcd34d) bg amber-100 (#fef3c7); dark: border amber-600 (#d97706) bg amber-900/80 (#78350f @ 80%). `StickyNote` icon 14px amber-600 (dark amber-400). Text: if content, truncated span max-width 120px, text-xs, amber-900 (dark amber-200); else italic "Empty" in amber-500. Tooltip: content, or "Empty note - click to edit, drag to move". EXPANDED card: width 224px (`w-56`), `rounded-lg shadow-xl`; light: border amber-300 bg amber-50 (#fffbeb); dark: border amber-600 bg amber-950/90. Header (drag handle): flex justify-between, `border-b px-2 py-1`, border amber-200 (dark amber-700), cursor grab/grabbing; left cluster: `GripHorizontal` 12px amber-400 (dark amber-600), `StickyNote` 12px amber-600 (dark amber-400), label `Note - p.{page_number}` text-xs font-medium amber-700 (dark amber-300); right cluster: delete button (`Trash2` 12px, amber-500, hover bg amber-200 + text red-600, tooltip "Delete note") and close button (`X` 12px, amber-500, hover bg amber-200 + text amber-800, tooltip "Close") — both stopPropagation on mousedown so they don't start a drag. Body padding 8px: editing → textarea full-width, non-resizable, `rounded border p-1.5 text-sm`, 4 rows, placeholder "Type your note...", light: border amber-200 bg amber-50 text amber-900 placeholder amber-400, focus border amber-400; dark: border amber-700 bg amber-950 text amber-100 placeholder amber-600. Not editing → `<p>` min-height 3rem, cursor text, whitespace-pre-wrap, text-sm amber-900 (dark amber-100); empty shows italic amber-400 "Click to add note...". Footer (only when `position_data.selected_text` present): `border-t px-2 py-1` (amber-200/amber-700), quote `“{selected_text}”` line-clamped to 2, text-xs italic amber-600 (dark amber-500).

**Shortcuts:** In textarea: Escape = save (if changed) + deselect. Blur = save.

### Note placement mode + context menu (PdfViewer)

**Behavior:** Pressing **N** (no Cmd/Ctrl, focus not in an input/textarea, a document open) toggles pdf-store `mode` between "view" and "note"; the toolbar StickyNote button does the same (active styling when in note mode; tooltip for PDFs: "Sticky note tool (N) — click on the page to place a note"). In note mode the PDF container gets `cursor-crosshair`. Clicking a page in note mode: compute `clickX/(renderZoom)`, `clickY/renderZoom`, `pageWidth = rect.width/renderZoom`, `pageHeight = rect.height/renderZoom`; call `addNote({ type: "note", page_number, position_data: { rects: [{x: clickX, y: clickY, width: 0, height: 0}], page_width, page_height, selected_text: null, start_offset: null, end_offset: null } })`; on success `selectAnnotation(annotation.id)` (which triggers the auto-edit-on-create behavior); ALWAYS `setMode("view")` afterwards. Failure logs `[PdfViewer] Failed to add note:`. Clicking a page in view mode just deselects (`selectAnnotation(null)`); clicking the gray container background (target === container) also deselects. **Right-click** on a page: preventDefault, open a context menu at the cursor with a single item "Add note here" which creates a note at the right-click point exactly like note-mode click (then selects it and closes the menu; failure logs `[PdfViewer] Failed to add note via context menu:`). The menu dismisses on any window click or scroll (capture). **Escape** (global): `selectAnnotation(null)` and `setMode("view")`.

**UI:** Context menu: `fixed z-50 min-w-[160px] rounded-lg border bg-background py-1 shadow-lg` at (clientX, clientY). Item: full-width row `px-3 py-1.5 text-sm` hover bg-accent, `StickyNote` icon 14px in amber-500, label "Add note here".

**Shortcuts:** N = toggle note mode; Escape = deselect + exit note mode.

### Annotation sidebar (AnnotationSidebar)

**Behavior:** Shows all annotations for the current document in store order (backend returns them sorted by page_number, then created_at). **Empty state** when zero annotations. **Filter bar**: "All · {total}" pill plus one pill per type in order highlight, note, bookmark — each showing the type icon and its count, and HIDDEN when its count is 0; clicking a pill filters the list; "all" is default. **Row click**: `selectAnnotation(id)`; then, if a web document text-anchored annotation (has `position_data.start_offset != null`, type !== "highlight") and the global `__scrollToWebPosition(position_data, page_number)` returns true, stop; otherwise `goToPage(page_number)` then call global `__scrollToPage(page_number)` if present. **Inline content edit**: double-clicking the content paragraph swaps it for a text input pre-filled with content; Enter saves via `updateAnnotation({ id, content: editText })` then exits editing; Escape cancels; clicks on the input don't bubble to row navigation. **Delete**: trash button per row (visible on row hover), stopPropagation, `deleteAnnotation(id)`.

**UI:** Empty state: centered column, gap 12px, padding 32px; a 48×48 circle (`rounded-full border border-border bg-muted text-muted-foreground`) holding a `Highlighter` icon 20px strokeWidth 1.75; "No annotations yet" (text-sm font-medium); below (text-xs muted): "Select text on the page to highlight it, or press N to drop a note." where N is a `<kbd>` styled `rounded border border-border-strong bg-surface px-1 py-0.5 font-mono` at 10px. Filter bar: `flex flex-wrap gap-1.5 border-b p-2.5`, leading `Filter` icon 13px muted. Pills: `rounded-full px-2.5 py-1 text-xs font-medium`; active = `bg-primary text-primary-foreground`; inactive = `bg-muted text-muted-foreground`, hover bg-accent + text-foreground. Type pills contain icon at 12px + count; tooltip = type label (Highlights/Notes/Bookmarks). Type icons: highlight = Highlighter, note = MessageSquare, bookmark = Bookmark (lucide). List: scrollable (`overflow-auto overscroll-contain p-1.5`). Row: `rounded-lg border border-transparent p-2.5 cursor-pointer`, hover bg-accent; selected = `border-border-strong bg-accent`. Row layout: flex, gap 10px. Leading marker (mt 2px): highlights with a color show a 16×16 color dot (`rounded-full ring-1 ring-border-strong`, backgroundColor = annotation.color); otherwise the type icon 16px muted. Header line: `{TYPE_LABEL} · p.{page_number}` at 11px, font-medium, uppercase tracking-wide, muted (page part normal case). If `position_data.selected_text`: quoted text `“…”` italic text-sm muted, clamped 2 lines, margin-top 4px. Content paragraph: text-sm clamped 3 lines. Edit input: flex-1 `rounded border bg-muted px-2 py-0.5 text-sm`, focus ring-1 ring-primary, autoFocus. Delete button: `Trash2` 14px, `rounded p-1 text-muted-foreground`, opacity 0 → 1 on group hover, hover bg-destructive/10 text-destructive, tooltip "Delete annotation".

**Shortcuts:** In edit input: Enter = save, Escape = cancel.

### Bookmark toggle

**Behavior:** **Cmd/Ctrl+B** (global, when a document is open, preventDefault) and the toolbar bookmark button both call `toggleBookmark()`. `findCurrentBookmark`: first annotation with type "bookmark" matching — for web docs with `start_offset != null`, id must be in `webVisibleBookmarks`; otherwise `page_number === currentPage`. If found → `deleteAnnotation(id)`. If not found: for web docs try the global `__captureWebPosition()` first; for PDFs (or when capture fails) → `addBookmark(currentPage)` which calls create_annotation with `{ type: "bookmark", page_number }` (no position_data, no color, no content). Bookmarks are per-page for PDFs; the returned annotation has null color/content/position_data.

**Shortcuts:** Cmd+B (macOS) / Ctrl+B = toggle bookmark on current page.

### Annotation store (Zustand) semantics

**Behavior:** State: `annotations: Annotation[]`, `isLoading`, `selectedAnnotationId: string | null`. `loadAnnotations()`: uses `usePdfStore.activeTabId` as session id; if none, resets to empty. Sets isLoading, calls IPC `get_annotations`; ONLY applies the result if activeTabId is still the same session (tab-switch race guard, used identically in all mutations); resets `selectedAnnotationId` to null on load. Errors log `[annotation-store] Failed to load annotations:` and clear isLoading. `addHighlight`/`addNote`: IPC create with type forced to "highlight"/"note"; on success append to array and return the annotation (null on failure/tab-switch; errors log `Failed to create highlight:` / `Failed to create note:`). `addBookmark(pageNumber, positionData?)`: create with type "bookmark" (`Failed to create bookmark:` on error). `updateAnnotation(input)`: OPTIMISTIC — immediately maps the matching annotation merging provided color/content/position_data and setting `updated_at = new Date().toISOString()`; then IPC; if IPC returns false, throws `Annotation {id} was not found`; any failure logs `Failed to update annotation:` and calls `loadAnnotations()` to revert. `deleteAnnotation(id)`: OPTIMISTIC — removes from array (and nulls selectedAnnotationId if it pointed at it), then IPC; false → throw `Annotation {id} was not found`; failure logs `Failed to delete annotation:` and restores the previous array. `clearAnnotations()` empties both. `getAnnotationsForPage(n)` filters by page_number. Annotations reload on document open (App effect) and on the window event `vellum:annotations-updated`.

### AI highlight locator (highlight-locator.ts)

**Behavior:** Used by the AI store's `addHighlight` tool to highlight text on any page WITHOUT that page being mounted (pages are virtualized). The viewer registers the live pdf.js document proxy via `registerPdfDocument(doc)` / `unregisterPdfDocument(doc)` (module-level singleton, cleared only if it matches). `locateTextOnPage(pageNumber, query)`: returns null if no document registered; needle = query with ALL whitespace stripped (`/\s+/g` → "") and lowercased; null if empty; `doc.getPage(pageNumber)` (null on throw); viewport at scale 1; `page.getTextContent()`. Build a whitespace-free lowercase haystack across all text items, recording for every character which item index produced it. First `indexOf(needle)` match wins; null if none. Collect the set of item indices the match spans, convert EACH WHOLE ITEM to a rect (whole-text-item granularity — a match starting/ending mid-item highlights slightly more than the exact words, but always the right lines). Item→rect: `tx = pdfjs.Util.transform(viewport.transform, item.transform)` (composes page flip with the text matrix, yielding top-left-origin coords at scale 1); `fontHeight = hypot(tx[2], tx[3])`; rect = `{ x: tx[4], y: tx[5] - fontHeight, width: max(0, item.width ?? 0), height: fontHeight > 0 ? fontHeight : max(0, item.height ?? 0) }`; null if width or height <= 0 or transform missing/short. Then `mergeLineRects`: sort by y then x; walk merging a rect into the previous line band when `|rect.y - last.y| <= min(rect.height, last.height) * 0.6` (union of the two boxes), else start a new band — so multi-item phrases render one band per visual line. Returns `PositionData { rects: mergedRects, page_width: viewport.width, page_height: viewport.height, selected_text: originalQuery, start_offset: null, end_offset: null }`, or null if no item produced a rect. AI failure copy: `Skipped addHighlight: couldn't find "{query}" on page {pageNumber}.`; success: `Highlighted "{query}" on page {resolvedPage}.`

## Data models

## TypeScript (`src/types/index.ts`) — wire format is snake_case except noted

```ts
export type AnnotationType = "highlight" | "note" | "bookmark";

export interface Rect { x: number; y: number; width: number; height: number; }

export interface PositionData {
  rects: Rect[];
  page_width: number;          // page display width at zoom=1, PDF points
  page_height: number;         // page display height at zoom=1, PDF points
  selected_text: string | null;
  start_offset: number | null; // web-doc text offsets; always null for PDFs
  end_offset: number | null;
  prefix?: string | null;      // web text-quote anchors; absent for PDFs
  suffix?: string | null;
  viewport_offset?: number | null; // web point bookmarks; absent for PDFs
}

export interface Annotation {
  id: string;                  // UUID v4 (or derived id for foreign annotations)
  type: AnnotationType;        // JSON key is literally "type"
  page_number: number;         // 1-based
  color: string | null;        // "#rrggbb" lowercase
  content: string | null;
  position_data: PositionData | null;
  created_at: string;          // RFC3339, e.g. "2026-07-03T12:34:56.789012+00:00"
  updated_at: string;
}

export interface CreateAnnotationInput {
  type: AnnotationType; page_number: number;
  color?: string; content?: string; position_data?: PositionData;
}
export interface UpdateAnnotationInput {
  id: string; color?: string; content?: string; position_data?: PositionData;
}

export const HIGHLIGHT_COLORS = [
  { name: "Yellow", value: "#fef08a", dark: "#854d0e80" },
  { name: "Green",  value: "#bbf7d0", dark: "#16653480" },
  { name: "Blue",   value: "#bfdbfe", dark: "#1e40af80" },
  { name: "Pink",   value: "#fbcfe8", dark: "#9d174d80" },
  { name: "Purple", value: "#ddd6fe", dark: "#5b21b680" },
] as const;   // `dark` variants exist but this subsystem's UI only uses `value`
```

## Rust (`src-tauri/src/models.rs`) — serde, default field names = snake_case

```rust
pub struct Annotation {
    pub id: String,
    #[serde(rename = "type")] pub annotation_type: AnnotationType,
    pub page_number: u32,
    pub color: Option<String>,
    pub content: Option<String>,
    pub position_data: Option<PositionData>,
    pub created_at: String,
    pub updated_at: String,
}
#[serde(rename_all = "lowercase")]
pub enum AnnotationType { Highlight, Note, Bookmark } // "highlight"|"note"|"bookmark"

pub struct PositionData {
    pub rects: Vec<Rect>,
    pub page_width: f64,
    pub page_height: f64,
    pub selected_text: Option<String>,
    pub start_offset: Option<u32>,
    pub end_offset: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub prefix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub suffix: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")] pub viewport_offset: Option<f64>,
}
pub struct Rect { pub x: f64, pub y: f64, pub width: f64, pub height: f64 }

pub struct CreateAnnotationInput { #[serde(rename="type")] annotation_type, page_number: u32,
    color: Option<String>, content: Option<String>, position_data: Option<PositionData> }
pub struct UpdateAnnotationInput { id: String, color: Option<String>,
    content: Option<String>, position_data: Option<PositionData> }
```

Note: PDF-backed annotations always serialize `start_offset`/`end_offset` as null and omit prefix/suffix/viewport_offset. `prefix`/`suffix`/`viewport_offset` are only populated by the web-page subsystem.

## Frontend-only shapes
- `TextSelection` (useTextSelection): `{ text: string; positionData: PositionData; pageNumber: number }` (camelCase, in-memory only).
- `PopoverPosition`: `{ x, y }` viewport (fixed) coordinates.
- Constants: `DEFAULT_HIGHLIGHT_COLOR = "#fef08a"`, `DEFAULT_NOTE_COLOR = "#fde68a"`, `NOTE_SIZE = 18.0` (PDF points, Rust side).

## Persistence

## Persistence model

Annotations are embedded IN the PDF file itself (no sidecar database). The dispatcher (`commands.rs`) resolves `session_id` → the open tab's PDF path and calls `pdf_annotations.rs`. Web sessions route to `web_page.rs` (separate subsystem). Everything below is the PDF compatibility contract — a Swift/PDFKit port must read AND write files that round-trip with this code.

## Coordinate systems

- **UI space** (what `PositionData.rects` are in): top-left origin, y increases DOWNWARD, units = PDF points at zoom 1 (matching pdf.js viewport at scale 1). `page_width`/`page_height` are the page's DISPLAY dimensions (rotation-aware, ×UserUnit).
- **PDF space**: bottom-left origin, y increases upward, page-box units.
- **PageGeometry** per page: box = inherited `/CropBox`, falling back to inherited `/MediaBox` (walks `/Parent` chain); `left,bottom` = box[0],box[1]; `width = |box[2]-box[0]|`, `height = |box[3]-box[1]|`; defaults if entries unreadable: left 0, bottom 0, right 612, top 792. `rotation` = inherited `/Rotate` `.rem_euclid(360)` (so 0/90/180/270). `user_unit` = inherited `/UserUnit` if > 0 else 1.0. Display dims: rotation 90/270 → `(height*user_unit, width*user_unit)`, else `(width*user_unit, height*user_unit)`. Errors: `"PDF page has no MediaBox"`, `"PDF page has an invalid MediaBox"` (<4 entries or non-array).
- **ui_to_pdf(x, y, page_width, page_height)** (page_width/height from the stored PositionData — rects are first rescaled in case the caller's notion of page size differs): `display_x = x * display_width / max(page_width, ε)`; same for y; divide by user_unit → units; then by rotation: `0: (left + xu, top - yu)`; `90: (left + yu, bottom + xu)`; `180: (right - xu, bottom + yu)`; `270: (right - yu, top - xu)`.
- **pdf_to_ui(x, y)**: `0: ((x-left)*uu, (top-y)*uu)`; `90: ((y-bottom)*uu, (x-left)*uu)`; `180: ((right-x)*uu, (y-bottom)*uu)`; `270: ((top-y)*uu, (right-x)*uu)`.

## Highlight annotation dictionary (written on create)

| Key | Value |
|---|---|
| `/Type` | `/Annot` |
| `/Subtype` | `/Highlight` |
| `/NM` | text string, UUID v4 (e.g. `"3f2a…-…"`) — THE annotation id |
| `/M` | text string `D:YYYYMMDDHHMMSSZ` (UTC now, e.g. `D:20260703120000Z`) |
| `/F` | integer 4 (Print flag) |
| `/T` | text string `Vellum` |
| `/C` | array `[r g b]`, each = channel/255.0 as real (from hex color; fallback rgb(254,240,138) if unparsable) |
| `/CA` | real 0.4 |
| `/Contents` | text string, only if input.content present |
| `/QuadPoints` | see below |
| `/Rect` | `[minX minY maxX maxY]` bounding box of ALL quad points |
| `/P` | reference to the page object |
| `/VellumCreatedAt` | text string, RFC3339 UTC (chrono `to_rfc3339()`) |
| `/VellumUpdatedAt` | same value at creation |
| `/VellumSelectedText` | text string, only if position.selected_text present |

**QuadPoints computation**: for each UI rect, convert 4 corners via ui_to_pdf and emit 8 numbers in the order **top-left, top-right, bottom-left, bottom-right** (x,y pairs) — i.e. for an unrotated page: `[x1 y2 x2 y2 x1 y1 x2 y1]` with y2 = top. This is the standard PDF quad order (TL TR BL BR in PDF coords). One quad (8 numbers) per rect, concatenated.

Default colors when input.color is absent: highlight `#fef08a`, note/other `#fde68a`; the default is also returned in the Annotation response.

## Sticky note dictionary

Same common keys (`/Type /Annot`, `/NM`, `/M`, `/F 4`, `/T Vellum`, `/C`, `/P`, Vellum timestamps) plus:
- `/Subtype` = `/Text`, `/Name` = `/Note` (icon name).
- `/Contents` = note text if present.
- `/Rect` = bounding box of ui_to_pdf(anchor.x, anchor.y) and ui_to_pdf(anchor.x + 18, anchor.y + 18) — an 18×18-point square anchored at the note point (NOTE_SIZE = 18.0). No QuadPoints.
- If create is called without position_data, a default anchor is used: `{x: 0, y: 0, w: 0, h: 0}` with page dims = display dims (bookmark-type would use `x = display_width - 18`, but bookmarks never reach this path — see below).

Error strings from `apply_position`: `"Highlight has no rectangles"` (empty rects), `"Note has no position"`.

## Bookmarks — standard PDF outlines, NOT annotations

`create_annotation` with type bookmark short-circuits to outline creation:
1. Ensure catalog `/Outlines` root exists (create `<< /Type /Outlines /Count 0 >>` if missing; if the catalog holds a DIRECT outline dictionary, promote it to an indirect object and repoint the catalog). Errors: `"PDF has no catalog"`, `"Failed to update PDF catalog: {e}"`.
2. New outline item dictionary: `/Title` = text string `Bookmark - page {n}`; `/Parent` = outlines root ref; `/Dest` = `[pageRef /Fit]`; `/VellumType` = NAME `/Bookmark`; `/VellumNM` = text string UUID v4 (the id); `/VellumCreatedAt`, `/VellumUpdatedAt` = RFC3339.
3. Linked into the sibling list at the END: previous `/Last` gets `/Next` → new item, new item gets `/Prev`; root `/Last` (and `/First` if list was empty) updated; root `/Count` adjusted by +1 (rule: if current Count < 0 do `count - delta`, else `max(count + delta, 0)`).

Returned Annotation: color/content/position_data all null.

**Reading bookmarks** (`read_bookmarks`, appended after page annotations in get_annotations): scan ALL document objects for dictionaries where: no `/Subtype`, `/VellumType` name == `Bookmark`, has `/VellumNM`, has `/Title` (`is_vellum_outline`). Page = deref `/Dest` array, first element as page reference, mapped to page number; skipped if unresolvable. Timestamps from Vellum keys, defaulting to now.

**Deleting a bookmark** (tried FIRST in delete_annotation, matched by `/VellumNM` == id): unlink from the Prev/Next chain (fixing parent `/First`/`/Last` when at an end), decrement parent `/Count` via the same rule, remove the object. Errors: `"Failed to read PDF bookmark: {e}"`, `"PDF bookmark has no outline parent: {e}"`, `"Failed to update previous/next PDF bookmark: {e}"`, `"Failed to update PDF outline root: {e}"`, `"Failed to update PDF outline count: {e}"`.

**Legacy/read-only bookmark-as-annotation form**: `dictionary_to_annotation` treats a `/Text` or `/FreeText` annotation carrying `/VellumType /Bookmark` as a bookmark (and drops a `/Contents` equal to the literal string `"Bookmark"`). `create_dictionary` contains a bookmark branch writing `/Subtype /Text`, `/Name /Key`, `/VellumType /Bookmark`, `/Contents "Bookmark"`, but it is unreachable from create (bookmarks divert to outlines) — implement the READ side for compatibility.

## Reading annotations (get_annotations)

For every page (optionally filtered by page_number): read `/Annots` (direct array or reference; anything else → none). Each entry may be a reference or an inline dictionary. Then:
- **Type mapping**: `/Subtype` `Highlight` → highlight; `Text`/`FreeText` → note (or bookmark if `/VellumType /Bookmark`); ANY other subtype is ignored (Squiggly, Underline, Link, etc. do not surface).
- **id**: decoded `/NM` if present; else `pdf-{objNum}-{gen}` for referenced entries; else `pdf-direct-{page}-{index}` for inline entries. (So third-party annotations without /NM still get stable-ish ids.)
- **color**: `/C` with ≥3 numeric entries → `#{:02x}{:02x}{:02x}` from `round(clamp(c,0,1)*255)`; else default (`#fef08a` highlight / `#fde68a` note).
- **content**: decoded `/Contents` (bookmark drops literal "Bookmark").
- **position**: highlights — `/QuadPoints` chunked by 8; each chunk's points map through pdf_to_ui and reduce to a UI bounding rect (one rect per quad); if QuadPoints absent/empty, fall back to `/Rect` → single bounding rect. Notes/bookmarks — `/Rect` → UI bounding rect, then emit a single POINT rect `{x, y, width: 0, height: 0}` at its top-left UI corner. `page_width`/`page_height` = display dims. `selected_text` = decoded `/VellumSelectedText`. start/end offsets null.
- **timestamps**: `/VellumCreatedAt` / `/VellumUpdatedAt` decoded, defaulting to now when missing (third-party annotations).
- Final sort: `page_number` ascending, then `created_at` (string compare) ascending. Bookmarks (outlines) are merged into the same list before sorting.

## Updating (update_annotation)

Find by id: iterate pages/entries, compare `annotation_id(page, entry)` — this matches /NM OR the derived `pdf-…` ids, so third-party annotations are editable. Returns Ok(false) if not found. Then on the dictionary: set `/NM` = id (stamps un-NM'd third-party annotations with their derived id), `/M` = fresh PDF date, `/VellumUpdatedAt` = fresh RFC3339. If input.color → `/C`. If input.content → `/Contents`. If input.position_data → recompute `/QuadPoints`+`/Rect` (highlight) or `/Rect` (other) via apply_position, and set `/VellumSelectedText` if position.selected_text present. Save. Note `/VellumCreatedAt` is NOT added on update.

## Deleting

Bookmark path first; else find entry, remove index from the `/Annots` array (direct or referenced), remove the indirect annotation object if there was one, save. Ok(false) if id unknown.

## Metadata in the Info dictionary (set_metadata / document_info)

- key `page_count` → no-op.
- key `title` → Info `/Title` = text string.
- key `last_page` → Info `/VellumLastPage` = INTEGER (parse error → `"Invalid last_page value: {e}"`).
- any other key → Info `/Vellum{PascalCase}` text string, where PascalCase = split key on `_`, uppercase each segment's first char, concatenate (e.g. `reading_theme` → `/VellumReadingTheme`).
- `ensure_info_dictionary`: if trailer `/Info` is a reference use it; if it's a direct dictionary, promote to indirect; else create empty.
- `document_info(path)` returns `(title, page_count, last_page)`: title = Info `/Title` decoded, else file stem; last_page = `/VellumLastPage` accepted as integer OR numeric string.

## Atomic write strategy (save_document)

1. Temp file in the SAME directory: `.{original_filename}.vellum-{uuid4}.tmp`.
2. Read the original file's permissions first (`"Failed to read PDF permissions: {e}"`).
3. Remove `/Prev` and `/XRefStm` from the trailer before saving — the save is a FULL rewrite, so stale incremental-xref pointers must not survive.
4. `document.save(temp)`; on failure delete temp, error `"Failed to write annotated PDF: {e}"`.
5. Apply original permissions to temp (`"Failed to preserve PDF permissions: {e}"`, temp removed on failure).
6. Unix: `rename(temp, original)` (atomic); failure removes temp, error `"Failed to replace PDF with annotated copy: {e}"`. Windows: rename original → `.{name}.vellum-{uuid}.bak`, rename temp → original (restoring the .bak on failure), then delete the .bak.

Every mutation (create/update/delete/set_metadata) does load-modify-save of the whole file.

## Corrupt-file recovery (load_document)

If `Document::load` fails: read the raw bytes; ONLY if they contain the marker `VellumCreatedAt` (i.e. we wrote this file) attempt repair via `strip_stale_xref_links`: locate the last `trailer` keyword and the following `startxref` (or, for xref streams, the last `/Type/XRef` dict from `<<` to `stream`), and within that span blank out (overwrite with spaces) every `/Prev <digits>` and `/XRefStm <digits>` occurrence. If anything changed, retry `Document::load_mem`. Errors: `"Failed to read PDF for recovery: {e}"`, `"Failed to parse PDF: {original}"`, `"Failed to parse PDF: {original}; recovery also failed: {recovery}"`.

## Text-string encoding

All text values are written with lopdf `text_string(...)` (PDFDocEncoding when possible, else UTF-16BE with BOM) and read with `decode_text_string` (handles both plus UTF-8). PDFKit's `PDFAnnotation` string properties handle this natively; custom `/Vellum*` keys must be read/written with proper PDF text-string decoding.

## Example round-trip payloads

Create highlight IPC input → `{"type":"highlight","page_number":1,"color":"#fef08a","position_data":{"rects":[{"x":72,"y":100,"width":180,"height":16}],"page_width":612,"page_height":792,"selected_text":"selected text","start_offset":null,"end_offset":null}}`. Resulting dictionary on a 612×792 unrotated page: `/QuadPoints [72 692 252 692 72 676 252 676]`, `/Rect [72 676 252 692]`, `/C [0.996078 0.941176 0.541176]` (approx), `/CA 0.4`.

## IPC commands

All commands take `sessionId` (camelCase in the JS invoke args; Tauri maps to snake_case Rust params). A session is an open tab; the backend resolves it to the PDF path. Missing session error: `No session found for tab {session_id}`. Web sessions dispatch to the web_page module instead (separate subsystem, same wire types).

| Command | JS args | Returns | Behavior / errors |
|---|---|---|---|
| `get_annotations` | `{ sessionId, pageNumber: number \| null }` | `Annotation[]` | All embedded annotations + outline bookmarks, optionally filtered to one page; sorted by page_number then created_at. Errors: PDF parse/geometry errors listed in persistence. |
| `create_annotation` | `{ sessionId, input: CreateAnnotationInput }` | `Annotation` | Embeds the annotation (or outline bookmark) and saves the file; returns the full record with fresh UUID id and RFC3339 timestamps. Error `Page {n} does not exist` for bad page_number; `Highlight has no rectangles` / `Note has no position` for bad position_data. |
| `update_annotation` | `{ sessionId, input: UpdateAnnotationInput }` | `boolean` | true if found+updated (matches /NM or derived ids; works on third-party annotations), false if id unknown. Only provided fields change; `/M` + `/VellumUpdatedAt` always refreshed. Bookmarks are NOT updatable (update never matches outlines — returns false). |
| `delete_annotation` | `{ sessionId, id: string }` | `boolean` | Tries outline bookmarks first, then page annotations; false if unknown. |
| `set_document_metadata` | `{ sessionId, key, value }` (strings) | `void` | Used elsewhere for `last_page`/`title`; documented here because it shares the Info-dictionary contract. |

Frontend wrappers in `src/lib/tauri-commands.ts`: `getAnnotations(sessionId, pageNumber?)` (passes `pageNumber ?? null`), `createAnnotation`, `updateAnnotation`, `deleteAnnotation`, `setDocumentMetadata`.

Frontend-global hooks this subsystem calls (window properties, all optional): `__scrollToPage(page)` (sidebar navigation), `__scrollToWebPosition(positionData, page?) => boolean` and `__captureWebPosition() => Promise<{pageNumber, positionData} | null>` (web docs only). Window event `vellum:annotations-updated` triggers a store reload.

## External APIs

None. This subsystem makes no network calls. All I/O is local: Tauri IPC to the Rust backend and direct PDF file reads/writes via the `lopdf` crate. (The AI store consumes `locateTextOnPage` but its network calls belong to the AI subsystem.)

## Porting notes

**PDFKit mapping — the good news**: the persistence format is deliberately standard, so PDFKit can largely round-trip it natively. `PDFAnnotation` with `.highlight` subtype maps to `/Subtype /Highlight`; use `annotation.setValue(_:forAnnotationKey:)` / `value(forAnnotationKey:)` with custom keys `PDFAnnotationKey(rawValue: "NM")`, `"VellumCreatedAt"`, `"VellumUpdatedAt"`, `"VellumSelectedText"`, `"VellumType"` etc. Sticky notes = `.text` subtype with `/Name /Note` (PDFKit `iconType = .note`). Set `/CA 0.4` via `annotation.setValue(0.4, forAnnotationKey: .init(rawValue: "CA"))` or draw at 40% alpha yourself; `/F 4` = `annotation.shouldPrint = true`; `/T "Vellum"` via userName.

**Coordinate system**: PDFKit already works in PDF-space points (bottom-left origin) per page, so most of `PageGeometry` disappears — but the FRONTEND rect format (`PositionData.rects`) is top-left-origin display space at zoom 1 with rotation and UserUnit folded in. If the Swift app keeps the same wire format (recommended, so .vellumweb exports / any stored JSON stay compatible), reimplement `pdf_to_ui`/`ui_to_pdf` exactly as specced, including the CropBox-before-MediaBox preference, `/Rotate` handling, and the rescale-by-stored-page-size step in ui_to_pdf (it makes old annotations survive page-box changes). PDFKit's `PDFPage.bounds(for: .cropBox)` and `page.rotation` give you the inputs.

**QuadPoints order**: TL, TR, BL, BR per quad — the same order PDFKit's `PDFAnnotation.quadrilateralPoints` expects (pairs of NSValue CGPoints RELATIVE TO the annotation bounds origin in PDFKit — convert carefully: the file stores absolute page coords, PDFKit's API wants bounds-relative points).

**Atomic saves**: PDFKit's `PDFDocument.write(to:)` also does a full rewrite; replicate the temp-file + rename dance and permission preservation. Do NOT use incremental saves. The `/Prev`-stripping recovery path exists because earlier Vellum builds produced broken incremental xrefs — PDFKit tolerates more than lopdf, but keep the marker-gated repair idea only if you keep lopdf-written files around; CGPDFDocument/PDFKit will usually just open them.

**Sorting/id contract**: created_at is compared as a STRING — keep RFC3339 with a fixed offset format so ordering stays chronological. Ids for foreign annotations without `/NM` are derived (`pdf-{obj}-{gen}` / `pdf-direct-{page}-{idx}`); PDFKit doesn't expose object numbers, so either stamp `/NM` on first read (acceptable divergence: the Rust code stamps `/NM` only on first UPDATE) or derive ids from page index + annotation index — but note derived ids must be stable across a session for select/update/delete to work.

**Update never touches bookmarks** — outline items are only created and deleted, never edited; the sidebar has no edit affordance for bookmarks (they have no content). Don't add one.

**UI mapping**: HighlightLayer/StickyNoteOverlay/SelectionPopover become overlay views in the PDF view coordinate space (PDFView `convert(_:to:)` for page↔view). PDFKit draws `/Highlight` annotations itself — you must SUPPRESS PDFKit's native rendering (e.g. keep annotations out of the displayed PDFDocument copy, or set them hidden and draw custom overlays) or you'll double-draw at the wrong opacity; the app's rendering (flat rect at 40% opacity, hover 60%, rounded 2px corners, ring when selected) plus click-to-select behavior does not match PDFKit's default multiply-blend highlight drawing. Sticky note drag threshold is 3 px in screen coords; offsets are divided by zoom before persisting. Note anchor rect is a zero-size point; the pill/card hangs down-right from it.

**Selection popover**: PDFKit gives you `PDFView.currentSelection` + `selectionsByLine()` — use per-line selection bounds as the rects (matches `range.getClientRects()` granularity closely). Popover anchors above the LAST line's rect, offset y −10 (and the highlight edit popover above the FIRST rect, offset −8). The 10 ms selection-settle timers are DOM workarounds — in AppKit, hook `PDFViewSelectionChanged` / mouseUp instead.

**highlight-locator equivalent**: use `PDFDocument.findString(_:withOptions: .caseInsensitive)` or per-page `PDFPage.string` search. The whitespace-stripping match (needle and haystack both stripped of ALL whitespace, lowercased, first match wins) is load-bearing: pdf.js splits lines into items without spaces. PDFPage.string doesn't have that problem, but keep whitespace-insensitive matching so AI-generated queries with different spacing still hit. Whole-text-item granularity means the Rust/TS version can overshoot the exact words; using PDFKit's `PDFSelection.bounds(for:)` per line will be MORE precise — that's a visible behavioral difference; acceptable only if you accept slightly tighter highlights (flag to the team; a 1:1 port would need pdf.js-item-equivalent chunks, which PDFKit doesn't expose).

**No native equivalent / must hand-roll**: Vellum custom keys round-tripping through PDFKit annotation copies (PDFKit sometimes drops unknown keys when annotations are mutated — verify with a round-trip test like `annotations_are_embedded_editable_and_path_independent`); outline `Count` bookkeeping (PDFOutline handles child insertion but check it maintains counts); the `/Prev`-stripping byte-level repair; deriving ids from object numbers.

**Colors**: store lowercase `#rrggbb`. Reading `/C` uses round(clamp(c,0,1)*255) per channel — match that exactly or re-saved highlights will drift a color step and stop matching `HIGHLIGHT_COLORS` equality checks (the edit popover marks the active swatch by string equality `annotation.color === color.value`).

**Tailwind color tokens used** (hex for the amber sticky-note theme, light/dark): amber-50 #fffbeb, amber-100 #fef3c7, amber-200 #fde68a, amber-300 #fcd34d, amber-400 #fbbf24, amber-500 #f59e0b, amber-600 #d97706, amber-700 #b45309, amber-800 #92400e, amber-900 #78350f, amber-950 #451a03; red-600 #dc2626. Semantic tokens (bg-background, border, primary, accent, muted, destructive, border-strong, surface, well) come from the app theme — take them from the design-system spec, not this module.

