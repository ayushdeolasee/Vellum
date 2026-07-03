# SPEC: web

## Overview
Vellum opens webpages as first-class tabs alongside PDFs. A URL (entered on the Welcome screen or via a toolbar prompt / Cmd+L) is fetched by a Rust proxy behind the `vellum-web://` Tauri custom protocol, which strips CSP/meta-refresh, injects `<base href>` and a ~1170-line "content script", and serves the page into a sandboxed iframe. The content script extracts text into "virtual pages" (~3600 chars each), reports selections/scroll/clicks via postMessage, renders highlight overlays and sticky-note markers, and re-anchors annotations with W3C-style text-quote anchors (exact text + prefix/suffix + offset hint). Annotations persist in a per-URL JSON sidecar (`<appData>/web/<sha256(url)>.json`); every opened page is also auto-archived into a portable `.vellumweb` ZIP in the managed library, with an installed snapshot directory used as offline fallback.

## Features

### Opening a URL (address inputs)

**Behavior:** Three entry points, all calling `usePdfStore.openUrl(url)`:
1. **Welcome screen**: a text input under the "Open a PDF" button, placeholder `"Or read a webpage — paste an article URL"`, with a Globe icon (size 15) inside the field and an "Open" button to the right (disabled while loading or when input is empty/whitespace). Enter key submits. On submit the input is cleared BEFORE the open completes.
2. **Toolbar**: a Globe icon button (size 16), title `Add webpage (⌘L)` (via `shortcut("L")`). Clicking toggles a dropdown popover; it also opens when the window receives the custom DOM event `vellum:add-webpage`.
3. **Keyboard**: Cmd/Ctrl+L anywhere dispatches `new CustomEvent("vellum:add-webpage")` (handled in App.tsx keydown; `e.preventDefault()`).

Toolbar prompt behavior: when opened, input is reset to "" and focused on next animation frame. Enter submits (closes prompt first, then `openUrl(trimmed)` if non-empty); Escape closes. Submitting empty just closes.

`openUrl` flow: sets `isLoading:true, error:null`; generates `crypto.randomUUID()` as sessionId; invokes `open_web_document`; on success records the doc into recents (localStorage key `vellum.recent-pdfs`, max 8 entries, entry shape `{pdf_path, kind, title, page_count, opened_at}`); if a tab with the same `document.pdf_path` already exists, closes the new backend session and activates the existing tab; otherwise appends a new tab with `currentPage = doc.last_page ?? 1`, `numPages = doc.page_count ?? 0`, `zoom: 1.0`, `mode: "view"`, empty `visiblePages`/`webVisibleRange:null`/`webVisibleBookmarks:[]`. Errors set `error: String(e)` shown on Welcome screen in a destructive-styled box.

URL normalization (Rust `normalize_url`): trim; empty → error "Empty URL"; if no `://`, prefix `https://`; parse (error `Invalid URL: {parse error}`); scheme must be http/https else `Unsupported URL scheme: {scheme}`; must have host else "URL has no host"; fragment stripped; query params with key starting `utm_` or exactly one of `fbclid|gclid|igshid|mc_cid|mc_eid|ref_src|twclid` removed (query removed entirely if none remain). The normalized URL is the document identity (`DocumentInfo.pdf_path`).

**UI:** Welcome URL row: `mt-4 flex w-full max-w-md items-center gap-2`; field container `h-10 flex-1 rounded-lg border border-border bg-surface px-3 shadow-soft`. Toolbar prompt: `absolute left-2 top-11 z-50 mt-1 flex w-96 gap-1.5 rounded-lg border bg-background p-2 shadow-lg`; input `h-8 flex-1 rounded-md border border-border bg-surface px-2 text-sm`, placeholder `"Paste an article URL…"`; Open button `h-8 rounded-md bg-primary px-3 text-xs font-medium text-primary-foreground hover:bg-primary/90`. Globe toolbar button shows `variant="active"` while prompt open.

**Shortcuts:** Cmd/Ctrl+L opens the Add-webpage prompt; Enter submits; Escape closes.

### vellum-web proxy protocol (page serving)

**Behavior:** Registered as asynchronous URI scheme protocol `vellum-web`. Frontend iframe src: macOS/Linux `vellum-web://localhost/?url=<encodeURIComponent(url)>`; Windows `http://vellum-web.localhost/?url=...` (detected by `navigator.userAgent.includes("Windows")`). A test hook `window.__VELLUM_DEV_PROXY__` (string) substitutes the base.

Routes:
- `/asset/<key>/<name>` → serves `<appData>/web/archives/<key>/assets/<name>` with Content-Type from extension and `Cache-Control: public, max-age=604800`. Rejects (404 `<h1>Asset not found</h1>`) when key is empty/not all-ASCII-hexdigits, or name empty/contains `..`/`/`/`\`/starts with `.`.
- `/?url=...`: missing url param → 404 `<h1>Missing url parameter</h1>`. Invalid URL → 400 with `error_page` run through `prepare_html(raw_url, offline=false)`.

Page load order: (1) if sidecar record `loading_policy == "snapshot-only"` and an installed snapshot dir exists, serve it (offline=true) without touching the network. (2) else fetch live: GET with User-Agent `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 Vellum/0.1`, 30s timeout, redirects followed (reqwest default), body cap 25 MiB enforced while streaming (Content-Length check first; error string "Response is too large to load"). Non-2xx → error `The server responded with HTTP {status}`. HTML detection: Content-Type contains `text/html` or `application/xhtml` (default `text/html` when header absent). HTML is decoded honoring the `charset=` from Content-Type (fallback UTF-8, via encoding_rs). Non-HTML responses are passed through verbatim with their Content-Type and `Cache-Control: no-store`.
(3) On HTML success: `effective_url = normalize_url(final_url_after_redirects)` (fallback: requested). If effective==requested and the record is `saved`, atomically refresh `<key>.snapshot.html` (write tmp `.<ext>tmp-<uuid>`, rename). If effective differs, refresh the snapshot under the effective URL's key instead (only if THAT record is saved). Serve `prepare_html(html, effective_url, offline=false)` with status 200, `Content-Type: text/html; charset=utf-8`, `Cache-Control: no-store`.
(4) On fetch failure: fallback chain — installed snapshot dir (`archives/<key>/snapshot.html` with `__VELLUM_ASSET__/` placeholders rewritten to `<asset_base>/asset/<key>/`, served offline=true), then plain `<key>.snapshot.html` (offline=true), else 502 error page. `asset_base` is `{scheme}://{authority}` from the request URI, default `vellum-web://localhost`.

`prepare_html(html, page_url, offline)`: case-insensitively removes all `<meta http-equiv="content-security-policy">` tags and all `<meta http-equiv="refresh">` tags; builds injection `<base href="{url with \" → %22}"><script>window.__VELLUM_PAGE_URL__={json-encoded url};window.__VELLUM_OFFLINE__={true|false};\n{CONTENT_SCRIPT}</script>`; inserted immediately after the first `<head...>` tag, else wrapped in `<head>...</head>` after first `<html...>`, else prepended to the document.

`error_page(url, message)` (also run through prepare_html so the content script still reports init): `<!doctype html>` page, title "Couldn't load page", body style `font-family: -apple-system, system-ui, sans-serif; max-width: 34rem; margin: 4rem auto; padding: 0 1.5rem; color: #333;`, h1 `font-size:1.25rem` text "Couldn't load this page", then the HTML-escaped URL in `color:#666; word-break: break-all`, the escaped message, and "Check the URL and your network connection, then reload the tab." in `color:#666`.

### Content script — text extraction & virtual pages

**Behavior:** IIFE; exits if `window.top === window` (not framed) or `window.__vellumLoaded` already set. Constants: `PAGE_TARGET_CHARS = 3600`, `MAX_PAGES = 200`.

**Text map**: TreeWalker over `document.body || documentElement` accepting text nodes; rejects elements whose tag is in {SCRIPT, STYLE, NOSCRIPT, TEMPLATE, IFRAME, OBJECT, TEXTAREA, SELECT, HEAD, TITLE, svg, SVG}, elements with `hidden` attribute or `aria-hidden="true"`, elements with inline `style.display=="none"` or `style.visibility=="hidden"` (inline-only check for speed), and the overlay root. `rawText` = concatenation of accepted text node values, with per-node `{node, start, end}` entries. `normText` = whitespace-collapsed view (runs of space chars → single " ", leading whitespace dropped) with `normMap[i]` = raw offset of normText[i]. Space detection `isSpaceCode`: code <= 32, 160 (nbsp), 0x1680, 0x2000–0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff.

**Virtual pages**: chunk normText into pages of up to 3600 chars. If a chunk would end mid-document, prefer breaking at the last `. ` (sentence, +1) inside the final 40% of the slice (i.e. index > floor(len*0.6)), else last space > that threshold, else hard cut. Page 200 absorbs the remainder. Each page: `{number (1-based), start (raw offset), end (raw offset of last char +1), normStart, normEnd, text: normText.slice(...).trim()}`. Empty document → single page `{number:1, text:""}`.

**Init lifecycle**: `start()` runs at `document.readyState === "complete"`, on window `load`, or a 4000 ms fallback timeout. It builds the map/pages and sends `init`; hooks scroll (passive) and resize listeners; ResizeObserver on body → debounced 250ms relayout; `document.fonts.ready` → relayout; MutationObserver on documentElement (childList+subtree+characterData, ignoring overlay-root mutations) → 600ms-debounced re-extraction that re-sends `init` only when |rawText length change| > 15% of previous; plus a one-shot re-extraction at 2000 ms after start (for client-side hydration).

**init message** `{vellum:true, type:"init", url: __VELLUM_PAGE_URL__, title: document.title||null, offline: !!__VELLUM_OFFLINE__, positionAnchors: true, pageCount, pages:[{number,text}]}` followed by a forced scroll report.

### Content script — scroll reporting & virtual-page positions

**Behavior:** `computePageTops()` caches document-Y of each page's first character (Range.getBoundingClientRect().top + scrollY), forced monotonically non-decreasing. `reportScroll(force)`: `current` = highest page whose top <= scrollY + innerHeight*0.35; `visible` = pages whose [top, nextTop) intersects the viewport (fallback `[current]`). Also computes `visibleBookmarks`: for each re-anchored bookmark, gets the 1-char range rect and includes its id when `rect.bottom > 0 && rect.top < innerHeight`. Dedupes against last report (current + joined visible + joined bookmark ids) unless forced. Posts `{type:"scroll", currentPage, visiblePages, visibleStart: firstVisiblePage.start, visibleEnd: lastVisiblePage.end, visibleBookmarks:[ids]}`. Scroll events are rAF-throttled and ALWAYS post `{type:"viewport-scrolled"}` before the deduped scroll report (parent uses it to dismiss viewport-anchored popovers). `scrollToVirtualPage(n)` scrolls to `pageTops[n-1] - 12` (clamped ≥0), behavior "auto".

App-shell side: `scroll` updates pdf-store `setCurrentPage`, `setVisiblePages`, `setWebVisibleRange({start,end})`, `setWebVisibleBookmarks(string ids only)` — all no-op when unchanged, and mirrored into the active tab object.

### Text selection → SelectionPopover (highlights & selection notes)

**Behavior:** On `mouseup` (+30 ms delay) the script reads `window.getSelection()`; collapsed/empty → posts `selection-cleared` (also posted via 200ms-debounced `selectionchange` when collapsed). Otherwise: text = selection string with whitespace collapsed+trimmed; start/end raw offsets from `rawOffsetOfBoundary` (text-node containers matched against entries; element boundaries resolved via a collapsed probe Range and `comparePoint` — first entry at/after the boundary; fallback rawText.length); up to 60 client rects mapped to `{x,y,width,height}` (viewport coords); prefix/suffix from `quoteContext` (up to 200 raw chars each side, whitespace-collapsed, trimmed to last/first 32 chars; case preserved). Posts `{type:"selection", text, start, end, pageNumber: pageForRaw(start), rects, prefix, suffix}`.

WebViewer receives it and (requiring non-empty text and ≥1 rect) positions the shared `SelectionPopover` at app-shell coords: `x = frameRect.left + (last.x + last.width/2)*zoom`, `y = frameRect.top + last.y*zoom - 10` (last rect = final line of selection). It builds `positionData = {rects:[], page_width:1, page_height:1, selected_text:text, start_offset, end_offset, prefix, suffix}`. SelectionPopover (shared with PDF): fixed, `translate(-50%,-100%)`, row of the 5 HIGHLIGHT_COLORS swatch buttons (`#fef08a` Yellow, `#bbf7d0` Green, `#bfdbfe` Blue, `#fbcfe8` Pink, `#ddd6fe` Purple; 24px circles, hover scale-110), divider, MessageSquarePlus note toggle revealing a w-64 input ("Add a note..."; Enter adds, Escape closes). Highlight click → `addHighlight({type:"highlight", page_number: selection.pageNumber, color, position_data})`; note → `addNote` with content. Closing clears selection and posts `clear-selection` (script does `sel.removeAllRanges()`).

**UI:** Popover hidden immediately when the page scrolls under it (`viewport-scrolled` → clear selection + post clear-selection).

### Content script — highlight overlays & re-anchoring

**Behavior:** WebViewer pushes annotations after every init and on every annotation-list change (effect keyed on `annotations` + `initCount`): posts `apply-annotations` with `highlights` (type highlight AND has selected_text), `notes` (type note AND selected_text AND start_offset != null; includes `content`), `bookmarks` (type bookmark AND selected_text AND start_offset != null). Anchor payload per item: `{id, color: a.color ?? "#fef08a", start, end, text: selected_text ?? "", prefix, suffix}`.

**resolveHighlight(h)** (the re-anchoring algorithm): (1) if stored raw offsets are valid (end>start, end<=rawText.length) and the normalized (lowercased, ws-collapsed, trimmed) text at those offsets equals the normalized stored text — or the stored text is empty — use offsets verbatim. (2) else text-quote search: needle = ws-collapsed trimmed stored text; case-insensitive fold only if lowercasing preserves both haystack and needle lengths (guards against Unicode expansion like U+0130 desyncing normMap). Scan ALL occurrences in normText; score = |rawStart − storedStart| (or norm index if no stored start), minus 100000 per matching context side (stored prefix compared to the text immediately before the occurrence — suffix-of-prefix match; stored suffix compared to prefix-of-following-text). Lowest score wins; no occurrence → null (annotation silently not rendered).

**Rendering**: overlay root div `#__vellum-highlights` appended to documentElement, `position:absolute;left:0;top:0;width:0;height:0;overflow:visible;pointer-events:none;z-index:2147483646;` aria-hidden. Cleared and rebuilt each render. For each resolved highlight, a div per client rect (skipping rects <1px): `position:absolute;pointer-events:none;border-radius:2px;mix-blend-mode:multiply;opacity:0.55;` positioned at rect + scroll offsets, backgroundColor = annotation color (fallback `#fef08a`).

**Note markers**: 18×18px clickable badge per note, `border-radius:4px 4px 4px 1px;background:#fbbf24;border:1px solid #b4530999;box-shadow:0 1px 3px rgba(0,0,0,0.25);font-size:11px;` content "✎" (pencil), cursor:pointer, pointer-events:auto. Placed 24px left of the anchor's first char, vertically centered on the line; if that puts it at left<2px, it instead floats 20px above the line start (or 2px below the line if above would clip). Notes sharing an anchor fan out downward +22px each. Tooltip = first 200 chars of content. mousedown is prevented/stopped; click posts `{type:"annotation-click", id, x: markerCenterX, y: markerTop}` (viewport coords). Re-rendered on debounced relayout (resize/mutation/fonts).

Bookmarks are not drawn; they are re-resolved (`resolvedBookmarks = [{id, start}]`) and drive `visibleBookmarks` in scroll reports. After apply-annotations the script forces a scroll report so bookmark visibility updates immediately.

### Sticky notes on webpages (note mode, context menu, popovers)

**Behavior:** **Note mode**: toolbar StickyNote button or `N` key toggles pdf-store `mode` between "view"/"note"; WebViewer forwards via `set-mode` message; script sets `documentElement.style.cursor = "crosshair"` in note mode. In note mode a capture-phase click handler preventDefaults/stopImmediatePropagations, computes a text anchor at the click point and posts `note-placed`; if no anchorable text is nearby it stays in note mode silently.

**Anchor-at-point** (`noteAnchorAtPoint`): caret from `caretRangeFromPoint`/`caretPositionFromPoint` probed at the point and 4 offsets (±40px x, ±20px y); rejects carets inside position:fixed/sticky ancestors (pinned chrome). Start offset skips leading whitespace then snaps BACK to the start of the word; end = start+80 extended to finish the trailing word capped at start+100. Snippet = collapsed/trimmed slice; prefix/suffix via quoteContext. Payload: `{start,end,text,prefix,suffix,pageNumber, x:clientX, y:clientY}`.

**WebViewer on note-placed**: validates anchor (`parseNoteAnchor`: start/end numbers, non-empty text; prefix/suffix strings or null; pageNumber ≥1 else 1), maps frame coords to shell coords (`frameRect.left/top + coord*zoom`), closes other popovers, opens **WebNoteComposer** at that point, and sets mode back to "view" (mirrors PDF).

**Right-click**: capture-phase `contextmenu` handler always preventDefaults; posts `{type:"context-menu", x, y, found: !!anchor, ...anchor}`. WebViewer opens **WebContextMenu** at the mapped point with `canAddNote = anchor !== null`; menu has a single item "Add note here" with StickyNote icon (14, text-amber-500), disabled with tooltip `"No text near this spot to attach a note to"` when no anchor; clicking it swaps to the composer at the same x/y.

**WebNoteComposer**: fixed z-50 w-72 (288px) `rounded-lg border bg-background p-2 shadow-lg`; header row "New note" with StickyNote 13 text-amber-500; autofocused textarea h-20 `resize-none rounded border bg-muted px-2 py-1.5 text-sm`, placeholder "Write a note…"; Enter (without Shift) submits, Escape closes; buttons "Cancel" (ghost) and "Add note" (primary, disabled when trimmed text empty). Submit calls `addNote({type:"note", page_number: anchor.pageNumber, content, position_data:{rects:[], page_width:1, page_height:1, selected_text: anchor.text, start_offset, end_offset, prefix, suffix}})` then selects the created annotation.

**WebNoteViewer** (opened when the shell receives `annotation-click` for a note annotation; also selects the annotation in the sidebar): fixed z-50 w-72 popover keyed by annotation id. Header: "Note" label + trash button (Trash2 13, hover text-destructive) that deletes and closes. If the note has no content it opens directly in edit mode. View mode: content in `max-h-40 overflow-auto whitespace-pre-wrap break-words text-sm`; anchored quote below in `truncate border-l-2 border-amber-300 pl-2 text-xs italic text-muted-foreground`; "Edit" button. Edit mode: same textarea; Enter saves (updateAnnotation only if trimmed content changed), Escape closes; Cancel/Save buttons.

**Positioning** (`useAnchoredPosition`): measured after render (rendered invisibly at anchor first frame); placements: "below" (composer) centers horizontally, sits 10px below the point, flips above when bottom-clipped; "above" (viewer) 10px above, flips below when top < 8px margin; "menu" (context menu) hangs from the point. All clamped to window with 8px margins; re-clamped on ResizeObserver + window resize.

**Dismissal**: WebContextMenu closes on any app-shell click or Escape. Because parent-window clicks can't observe iframe clicks, a plain click inside the page (which triggers `selection-cleared`) also dismisses the context menu, note viewer, and composer — but only if they've been open > 400 ms (grace period so the opening click doesn't self-dismiss). `viewport-scrolled` closes the context menu and viewer immediately, clears any selection popover, and closes the composer only if it opened <400 ms ago (so typing continues through minor scroll nudges).

### Point bookmarks & visibility tracking

**Behavior:** Toolbar Bookmark button / Cmd+B → `toggleBookmark()`. `findCurrentBookmark(annotations, docKind, currentPage, webVisibleBookmarks)`: for web docs, a bookmark with `start_offset != null` counts as "current" iff its id is in `webVisibleBookmarks` (the content-script-reported on-screen set); legacy web bookmarks without offsets, and all PDF bookmarks, match by `page_number === currentPage`. If a current bookmark exists, toggling deletes it. Otherwise for web docs it calls `window.__captureWebPosition()` (resolves null if the handshake flag `positionAnchors` wasn't set, i.e. older embedded script): posts `capture-position` with a UUID requestId, 1500 ms timeout → null.

Script-side `captureViewportAnchor()`: probes caret positions scanning down the viewport (y from 8 in +16 steps up to innerHeight*0.9; x at center, 24, innerWidth−24), skipping pinned (fixed/sticky) nodes and any offset whose rendered docTop < scrollY − 4 (stale/above viewport). If all probes fail, falls back to the start of the current virtual page (last pageTop <= scrollY+16). Start skips whitespace; end = start+160; text = collapsed/trimmed slice (null if empty → not found). `offset` = current viewport Y of the anchor's first char clamped to [0, innerHeight], default 16. Response `position-result {requestId, found, start, end, text, prefix, suffix, offset, pageNumber}`.

On success `addBookmark(pageNumber, positionData)` where positionData = `{rects:[], page_width:1, page_height:1, selected_text:text, start_offset, end_offset, prefix, suffix, viewport_offset: offset}`. On failure falls back to a plain page bookmark. Bookmark button turns gold (`text-gold`, filled icon) when current; titles: web "Bookmark this spot" / "Remove bookmark", PDF "Bookmark this page".

Jumping to a bookmark: selecting it in the sidebar calls `__scrollToWebPosition(position_data, page_number)` (used for annotations with start_offset and type ≠ highlight); WebViewer also reacts to `selectedAnnotationId` changes by posting `scroll-to-annotation {id}` for highlights/notes with selected_text, or `scroll-to-position {start,end,text,prefix,suffix,offset:viewport_offset,page}` for bookmarks with offsets. Script `scroll-to-position`: resolves via resolveHighlight; scrolls so the anchor sits `offset` px (default 16) below the viewport top; if unresolvable, falls back to `scrollToVirtualPage(page)`. After the jump it re-corrects at 400 ms and 1200 ms (lazy-image layout shifts) but only while the user hasn't scrolled >150 px away, and only re-scrolls if drift >24 px. `scroll-to-annotation` scrolls the resolved range to 30% from viewport top.

**Shortcuts:** Cmd/Ctrl+B toggles bookmark; N toggles note mode; Escape exits note mode and deselects.

### In-tab link navigation & history

**Behavior:** Capture-phase click handler (skipped in note mode or when defaultPrevented): finds `a[href]` via closest; href starting `#` is left alone (same-document scroll). SVG `<a>` href objects (`SVGAnimatedString`) unwrapped via `new URL(href.baseVal, document.baseURI)`. http(s) links: preventDefault/stopPropagation, post `{type:"navigate", url}`. `mailto:`/`tel:` links are preventDefaulted and dropped. GET form submissions with http(s) action are intercepted: form data appended as query params, posted as navigate. `window.open(u)` is overridden: resolves against PAGE_URL, posts navigate for http(s), returns null.

WebViewer `navigate` handling: cancels any pending auto-archive timer, clears selection, closes note popovers, then `store.webNavigated(tabId, url)` — this re-invokes `open_web_document` with the SAME session id (Rust rebinds the session so annotation commands keep working), records recents, resets the tab's currentPage to `doc.last_page ?? 1`, numPages, clears visible state. On success the viewer sets `pendingNavUrlRef = rebound.pdf_path`, resets initCount to 0, and swaps the iframe src to the new proxy URL. While a navigation is pending, `init` messages whose reported url ≠ pending target are ignored (late re-extraction from the outgoing document must not rebind backwards). `webNavigated` returns null (no-op) if the tab isn't a web tab; errors set store.error.

**Redirect rebinding**: if an `init` reports a url different from the current document's pdf_path (back/forward or server redirect changed the effective URL — the proxy serves the page under its post-redirect normalized URL), the viewer cancels pending archive, closes popovers, calls `webNavigated(tabId, reportedUrl)`, and then posts `request-init` so the page re-reports under the new binding.

**History**: toolbar Back/Forward arrows (web tabs only, titles "Back"/"Forward") call `window.__webHistory(delta)` → posts `history {delta}` → script runs `history.go(delta)` inside the iframe. The resulting document load re-injects the content script via the proxy and its init triggers the rebinding path above.

### Scroll position persistence (reading position)

**Behavior:** The current virtual page is the persisted reading position. Content-script scroll reports keep `tab.currentPage` up to date. On tab close and on tab switch the store calls `set_document_metadata(sessionId, "last_page", String(currentPage))` (best-effort). `set_document_metadata` for web sessions writes into the sidecar (`last_page` parsed as u32; `page_count` likewise; `title` trimmed, ignored when empty; unknown keys ignored). `setNumPages` also persists `page_count` on every change. App auto-saves every 30 s via `save_file` (no-op for web sessions — sidecar writes are immediate).

On (re)open, `open_web_document` returns `last_page` from the sidecar; the tab starts at that page. When the viewer receives the first `init` for a URL (tracked per mount by `restoredUrlRef`), if `store.currentPage > 1` it posts `scroll-to-page {page}` once; later inits from SPA re-extraction do NOT re-scroll.

### Auto-archiving on open (default persistence path)

**Behavior:** On each qualifying `init` (not offline, and this URL not already archived this mount): the viewer filters `pages` to well-formed `{number:number,text:string}` entries, cancels any pending timer, and starts a 1500 ms debounce timer (so a later, fuller re-extraction wins). When it fires it calls `archive_webpage_default(sessionId, pages, expectedUrl = doc.pdf_path)` and marks the URL as archived for this mount; on rejection the mark is cleared so the next init can retry. Timer cancelled on navigate, redirect-rebind, and unmount.

Rust `archive_webpage_default`: looks up the web session (errors: PDF tab → "PDFs are already portable — archiving applies to webpage tabs"; missing → "No session found for tab {id}"); normalizes expectedUrl and returns Ok(false) if it no longer matches the session's URL (tab navigated during the debounce). Otherwise runs the shared `write_web_archive` with dest = `<appData>/web/<key>.vellumweb`, then `mark_saved_if_absent` (sets `saved=true`, sets `saved_at` only if absent) so every opened page lands in the library. Returns Ok(true).

`write_web_archive` (shared with explicit export): best-available snapshot = live fetch (capture_snapshot against the normalized post-redirect URL) → else installed `archives/<key>/` dir contents (skipped=0, asset content-types inferred from names, urls empty) → else plain `<key>.snapshot.html` re-captured → else error "The page could not be fetched and no local snapshot exists yet". Serializes pages to JSON; takes title/page_count/last_page from the sidecar record (page_count overridden by `pages.len()` when pages non-empty); annotations from the record; builds manifest with loading_policy "live-first"; installs/refreshes `archives/<key>/` (snapshot.html + assets/ + manifest.json) via staged-dir + rename-aside swap; writes the .vellumweb ZIP atomically on a blocking task; returns `ExportSummary {path, bytes, asset_count, assets_skipped}`.

### Snapshot capture (sanitize + asset embedding)

**Behavior:** `capture_snapshot(page_url, raw_html)`:
1. **Sanitize** (regex, case-insensitive, dot-matches-newline): remove `<script ...>...</script>` and self-closed `<script/>`; remove `<link rel=preload|prefetch|modulepreload|dns-prefetch|preconnect ...>`; strip `srcset|sizes|integrity|crossorigin` attributes.
2. **Collect asset URLs** in document order, deduped by raw attribute value: `<img src="...">` values first, then `<link ... rel=stylesheet>` href values. Skips empty/`data:`/`#`-prefixed refs; resolves against the page URL; only http/https kept.
3. **Fetch each** with the shared client; caps: max 80 assets, 8 MiB per asset (streamed cap), 64 MiB total; over-cap or failed fetches increment `skipped` and their refs keep the original URL (resolved by `<base>` when live). CSS assets (`text/css` or .css) get their `url(...)` and `@import "..."` refs rewritten to absolute URLs against the stylesheet's own URL (data:/# left alone; non-http dropped to original; nested CSS assets are NOT embedded).
4. **Name** each asset `a{index}.{ext}` where ext comes from Content-Type (`text/css`→css, image/png→png, image/jpeg|jpg→jpg, gif, webp, avif, `image/svg+xml`→svg, `image/x-icon|vnd.microsoft.icon`→ico, font/woff2, font/woff|application/font-woff→woff, ttf, otf), else the URL path extension from the same list, else `bin`.
5. **Rewrite** the HTML: every `"<rawref>"` and `'<rawref>'` occurrence replaced with quoted `__VELLUM_ASSET__/a{i}.{ext}`.

### .vellumweb archive format (export/import)

**Behavior:** Portable versioned ZIP; `FORMAT_NAME="vellumweb"`, `FORMAT_VERSION=1`. Entries:
- `manifest.json` (pretty JSON)
- `snapshot/index.html` (sanitized HTML with `__VELLUM_ASSET__/<name>` refs)
- `snapshot/assets/<name>` per captured asset
- `text/pages.json` (compact JSON array of `{number, text}`)
- `annotations.json` (compact JSON array of Annotation)

Compression: text entries Deflate — Zopfli level 15 when ≤ 384 KiB (zip crate levels 10–264 = Zopfli), else flate2 level 9; assets with extension png/jpg/jpeg/gif/webp/avif/woff/woff2 are Stored, others Deflate level 9. `manifest.hashes.annotations` is filled at write time. Written atomically: temp file `.{filename}.tmp-{pid}-{uuid}` next to dest, zip finished, `sync_all`, rename; temp removed on failure.

**Explicit export**: toolbar Share icon (web tabs only). Filename slug: title lowercased, non-alphanumeric runs → `-`, trimmed of leading/trailing `-`, capped 60 chars, fallback "article"; save dialog filter `Vellum Web Archive (vellumweb)`, defaultPath `{slug}.vellumweb`. Pages passed from `useAiStore.pageTexts` (numeric keys sorted ascending). Button shows a spinner while exporting, turns emerald-600 on success with tooltip `Exported {MB} MB ({n} assets{, k skipped})`, destructive-red on error with the error string; state resets when the tab or URL changes. Idle tooltip: "Export as .vellumweb (portable archive with snapshot + annotations)".

**Import** (`open_vellumweb_file`, triggered when an opened file path ends `.vellumweb` — via Open dialogs whose filters include `Documents (pdf, vellumweb)`): `read_archive` on a blocking task — errors: "Failed to open archive: {e}", "Not a valid .vellumweb archive: {e}", missing entries "Archive is missing {name}", wrong format marker "Not a .vellumweb archive (wrong format marker)", newer version "This archive uses format version {v} — please update Vellum". Entry reads are size-capped DURING decompression (manifest 4 MiB, snapshot 25 MiB, annotations 32 MiB, each asset 8 MiB, assets total 64 MiB — "Archive entry {name} exceeds its size limit" / "Archive assets exceed the total size limit"). SHA-256 integrity: snapshot hash must match ("Archive snapshot failed its integrity check (corrupted file?)"); annotations hash verified when present in manifest; per-asset hashes verified when present ("Archive asset {name} failed its integrity check"). Asset names must be bare (no `..`, `/`, `\`, leading `.` — silently skipped otherwise).
Then: opens a session for `manifest.url`; installs the snapshot into `archives/<key>/`; merges metadata into the sidecar WITHOUT clobbering local state (title/page_count/last_page only when locally None; `loading_policy="snapshot-only"` copied only when the manifest says so); sets saved=true (saved_at only if absent); merges annotations (same-id conflicts keep newer `updated_at`, RFC3339-parsed with lexical fallback); returns DocumentInfo kind "web". Frontend dispatches `vellum:annotations-updated` after import so an already-open active tab reloads annotations.

### Saved-pages library & save toggle

**Behavior:** Toolbar Archive icon (web tabs only): reflects `get_webpage_saved(sessionId)` (fetched on tab/URL change; default false). Click optimistically flips, calls `set_webpage_saved(sessionId, next)`, reverts on error. Tint `text-primary` when saved. Titles: "Saved to library — click to remove" / "Save page to library (keeps an offline snapshot)".

Rust `set_saved(true)` sets saved + saved_at=now. `set_saved(false)` clears both AND deletes all local snapshot artifacts: `<key>.snapshot.html`, `<key>.vellumweb`, `archives/<key>/` dir. (Annotations remain in the sidecar.)

`list_saved_webpages` scans `<appData>/web/*.json`, keeps records with saved=true, returns `WebLibraryEntry {url, title, page_count, saved_at, has_snapshot}` sorted by saved_at descending; has_snapshot = any of the three artifact forms exists (`<key>.snapshot.html` file, `<key>.vellumweb` file, or `archives/<key>/snapshot.html`).

`remove_saved_webpage(url)` normalizes, un-saves the record (annotations kept), removes all snapshot artifacts.

Welcome screen "Saved pages" section (shown when non-empty, above "Recently opened"): header with Archive icon 13; each row is a Globe-icon card showing `title (trimmed) || display name` and a subtitle `hostname+path` (via `getWebpageDisplayName`: hostname + pathname with trailing slash stripped, "/" → empty) plus `" · available offline"` when has_snapshot; click opens the URL; hover-revealed X button removes (optimistic list filter + `remove_saved_webpage`, errors swallowed). Recents list shows web entries with a Globe icon (PDFs get FileText) and opens them via `openUrl`.

### WebViewer shell (iframe, zoom, offline badge, tab integration)

**Behavior:** Rendered by App.tsx when `doc.kind === "web"`, keyed by activeTabId (full remount per tab switch; PdfViewer likewise for PDFs). Returns null without doc/activeTabId. Container: `relative min-h-0 min-w-0 flex-1 overflow-hidden bg-well`.

**iframe**: src set once per mount (`webProxyUrl(doc.pdf_path)`, or "about:blank" with no doc); explicit navigation swaps it. `sandbox="allow-scripts allow-same-origin allow-forms"`; `aria-label = doc.title ?? doc.pdf_path` (deliberately not `title=` — that would tooltip the whole surface); class `border-0 bg-white`.

**Zoom**: applied by CSS-scaling the iframe itself so the page reflows like browser text zoom: `width/height = (100/zoom)%`, `transform: scale(zoom)`, `transformOrigin: 0 0`. Zoom range 0.25–4.0, step 0.1 (store); content script is zoom-agnostic — the shell multiplies incoming frame coords by zoom (`frameToParent`) when positioning popovers. Cmd+= / Cmd+- work through store zoomIn/zoomOut (the `__zoomPdfTo` hook is absent for web tabs so plain setZoom applies).

**Message hygiene**: only accepts messages whose `event.source === iframe.contentWindow`, `data.vellum === true`, string `type`; drops any message when `store.activeTabId !== mountTabIdRef` (messages queued across a tab switch must not corrupt the new tab). Outbound commands posted as `{vellumCmd, ...payload}` with targetOrigin "*".

**init handling** (beyond archive/restore described elsewhere): sets `isOffline` from `data.offline` → shows a floating badge `absolute right-3 top-3 z-40 flex items-center gap-1.5 rounded-full border border-border bg-background/95 px-2.5 py-1 text-xs text-muted-foreground shadow-soft` with WifiOff icon (12) and text "Offline snapshot". Records `positionAnchors` capability. Increments `initCount` (a counter, not boolean, so annotation/mode effects re-fire after in-tab navigation). Sets numPages from pageCount (>0 only). Feeds each `{number,text}` page into `useAiStore.setPageText` (which whitespace-normalizes and dedupes). Non-empty title → `updateDocumentTitle(tabId, title)` (store + tab, trimmed, no-op when equal) and best-effort `set_document_metadata(tabId, "title", title)`.

**Global hooks registered while mounted** (removed on unmount): `__scrollToPage(page)` → posts scroll-to-page (used by toolbar page nav / goToPage / sidebar); `__webHistory(delta)`; `__locateWebText(page, text)` → Promise, posts `locate-text {requestId, page, text}`, 4000 ms timeout → null; `__captureWebPosition()` → Promise (null if no positionAnchors), posts `capture-position`, 1500 ms timeout; `__scrollToWebPosition(pd, page?)` → returns false if no positionAnchors else posts scroll-to-position and returns true. On unmount all in-flight locate/capture promises resolve null and the archive timer is cleared.

**locate-result** resolves `{pageNumber (0 if absent), positionData {rects:[], page_width:1, page_height:1, selected_text:null, start_offset, end_offset, prefix, suffix}}` when found (script searches the requested virtual page's normStart first, falls back to whole document, returns actual pageNumber); otherwise null.

Toolbar for web tabs: hides the PDF Save button; adds Back/Forward, keeps page nav (virtual pages, `n / numPages` input), zoom cluster, bookmark, sticky-note tool, then a divider + Archive save-toggle + Share export + a truncated URL label (`max-w-[16rem] truncate text-xs text-muted-foreground`, scheme stripped via `replace(/^https?:\/\//,"")`, full URL in tooltip). Cmd+W closes tab; Cmd+1..9 switch tabs; Cmd+S save (web no-op); Cmd+O open dialog.

### AI integration for web tabs

**Behavior:** Virtual page texts populate `useAiStore.pageTexts` (from init messages); the AI context block is built identically to PDFs: pages sorted ascending, joined as `[Page N] {text}`, truncated at 120000 chars with `\n[truncated]`. Conversations are keyed by `doc.pdf_path` (the normalized URL), so per-URL persistence needs no special casing; navigation to a new URL loads that URL's conversation (App effect keyed on docPath clears annotations + AI context and reloads both). `currentPageImage` is naturally null for web tabs (capture looks for `[data-page-number] canvas`, which only PDF pages render).

AI tool execution: `goToPage` → store.goToPage → `__scrollToPage` (virtual page scroll). `addHighlight` on web docs resolves the anchor via `__locateWebText(page, text)` instead of PDF geometry; on success the stored position_data is the locate result with `selected_text` set to the query, and the annotation is filed under the ACTUAL located pageNumber (clamped ≥1) rather than the model's guess; failure → result string `Skipped addHighlight: couldn't find "{text}" on page {n}.`; success → `Highlighted "{text}" on page {n}.`. `addNote` is page-anchored (no selected_text/offsets) and works unchanged — such notes render in the sidebar but get no in-page marker (markers require selected_text + start_offset).

## Data models

## TypeScript (frontend, `src/types/index.ts`) — all snake_case fields cross IPC verbatim

```ts
type AnnotationType = "highlight" | "note" | "bookmark";
interface Rect { x: number; y: number; width: number; height: number; }

interface PositionData {
  rects: Rect[];                       // always [] for web annotations
  page_width: number;                  // always 1 for web
  page_height: number;                 // always 1 for web
  selected_text: string | null;        // the exact quote (ws-collapsed, trimmed)
  start_offset: number | null;         // raw text-map offset
  end_offset: number | null;
  prefix?: string | null;              // ≤32 chars ws-collapsed context (web only)
  suffix?: string | null;
  viewport_offset?: number | null;     // CSS px below viewport top (web point bookmarks only)
}

interface Annotation {
  id: string;                          // UUID v4
  type: AnnotationType;                // serde rename of annotation_type
  page_number: number;                 // virtual page for web
  color: string | null;                // default "#fef08a" highlight, "#fde68a" note, null bookmark
  content: string | null;
  position_data: PositionData | null;
  created_at: string;                  // RFC3339 (chrono Utc::now().to_rfc3339())
  updated_at: string;
}

interface CreateAnnotationInput { type; page_number; color?; content?; position_data?; }
interface UpdateAnnotationInput { id; color?; content?; position_data?; }

type DocumentKind = "pdf" | "web";
interface DocumentInfo {
  kind: DocumentKind;                  // serde default "pdf"
  pdf_path: string;                    // normalized URL for web docs (legacy field name)
  title: string | null;
  page_count: number | null;
  last_page: number | null;
}

interface VellumwebExportSummary { path: string; bytes: number; asset_count: number; assets_skipped: number; }
interface WebLibraryEntry { url: string; title: string | null; page_count: number | null; saved_at: string | null; has_snapshot: boolean; }

interface PdfTab {                     // in-memory tab state (both kinds)
  id: string;                          // == backend session id (UUID)
  document: DocumentInfo;
  currentPage: number; numPages: number; zoom: number;
  visiblePages: number[];
  webVisibleRange: { start: number; end: number } | null;
  webVisibleBookmarks: string[];
  mode: "view" | "note";
}

interface RecentPdf { pdf_path: string; kind: DocumentKind; title: string|null; page_count: number|null; opened_at: string; }
```

## Rust (`models.rs`, `web_page.rs`, `web_archive.rs`)

```rust
pub struct Annotation { id: String, #[serde(rename="type")] annotation_type: AnnotationType,
  page_number: u32, color: Option<String>, content: Option<String>,
  position_data: Option<PositionData>, created_at: String, updated_at: String }
#[serde(rename_all="lowercase")] pub enum AnnotationType { Highlight, Note, Bookmark }
pub struct PositionData { rects: Vec<Rect>, page_width: f64, page_height: f64,
  selected_text: Option<String>, start_offset: Option<u32>, end_offset: Option<u32>,
  #[serde(default, skip_serializing_if=Option::is_none)] prefix: Option<String>,
  #[serde(default, skip_serializing_if=Option::is_none)] suffix: Option<String>,
  #[serde(default, skip_serializing_if=Option::is_none)] viewport_offset: Option<f64> }

pub struct WebSession { url: String, record_path: PathBuf, snapshot_path: PathBuf }

pub struct WebPageRecord {                       // sidecar JSON, all fields #[serde(default)] except url
  url: String, title: Option<String>, page_count: Option<u32>, last_page: Option<u32>,
  saved: bool, saved_at: Option<String>, opened_at: Option<String>,
  loading_policy: Option<String>,                // None/"live-first" | "snapshot-only"
  annotations: Vec<Annotation> }

pub struct WebLibraryEntry { url, title: Option<String>, page_count: Option<u32>, saved_at: Option<String>, has_snapshot: bool }

pub struct ArchiveManifest { format: String /*"vellumweb"*/, version: u32 /*1*/,
  url: String, canonical_url: String /* == url */, title: Option<String>,
  captured_at: String /*RFC3339*/, generator: String /* "Vellum {CARGO_PKG_VERSION}" */,
  loading_policy: String, page_count: Option<u32>, last_page: Option<u32>,
  hashes: ManifestHashes, #[serde(default)] assets: Vec<ManifestAsset>, #[serde(default)] assets_skipped: u32 }
pub struct ManifestHashes { snapshot_html: String /*"sha256:<hex>"*/, page_text: String,
  #[serde(default, skip_serializing_if=Option::is_none)] annotations: Option<String> }
pub struct ManifestAsset { path: String /*"snapshot/assets/a0.png"*/, url: String,
  content_type: String, bytes: u64, #[serde(default, skip_serializing_if=Option::is_none)] sha256: Option<String> }
pub struct PageText { number: u32, text: String }
pub struct ExportSummary { path: String, bytes: u64, asset_count: u32, assets_skipped: u32 }
```

## postMessage protocol (iframe ↔ app shell)
Inbound (script→shell), all `{vellum:true, type, ...}`:
| type | fields |
|---|---|
| `init` | url, title, offline:bool, positionAnchors:true, pageCount, pages:[{number,text}] |
| `scroll` | currentPage, visiblePages:[n], visibleStart, visibleEnd (raw offsets), visibleBookmarks:[id] |
| `viewport-scrolled` | — |
| `selection` | text, start, end, pageNumber, rects:[{x,y,width,height}] (≤60, viewport css px), prefix, suffix |
| `selection-cleared` | — |
| `note-placed` | start, end, text, prefix, suffix, pageNumber, x, y (client coords) |
| `context-menu` | x, y, found:bool, + anchor fields when found |
| `annotation-click` | id, x, y (marker center-x / top) |
| `navigate` | url |
| `locate-result` | requestId, found, start, end, prefix, suffix, pageNumber |
| `position-result` | requestId, found, start, end, text, prefix, suffix, offset, pageNumber |

Outbound (shell→script), `{vellumCmd, ...}`: `scroll-to-page {page}`, `apply-annotations {highlights, notes, bookmarks}` (anchor `{id,color,start,end,text,prefix,suffix}`, notes +content), `set-mode {mode}`, `scroll-to-annotation {id}`, `locate-text {requestId,page,text}`, `capture-position {requestId}`, `scroll-to-position {start,end,text,prefix,suffix,offset,page}`, `clear-selection`, `history {delta}`, `request-init`.

## Persistence

All under the OS app-data dir (`tauri app_data_dir()`; on macOS `~/Library/Application Support/<bundle-id>/`), subdirectory `web/`.

## 1. Per-URL sidecar: `<appData>/web/<key>.json`
`key = lowercase hex sha256(normalized_url)` (64 chars). Written atomically (write `<key>.json.tmp`, rename; note `with_extension` yields literally `<key>.json.tmp`). Pretty-printed JSON of `WebPageRecord`. This is the LIVE source of truth for annotations + metadata; every annotation mutation rewrites the whole file immediately (read-modify-write; corrupt/missing file silently replaced by a fresh record). Example:

```json
{
  "url": "https://example.com/post?id=7",
  "title": "Post Title",
  "page_count": 4,
  "last_page": 2,
  "saved": true,
  "saved_at": "2026-07-03T10:00:00.123456+00:00",
  "opened_at": "2026-07-03T10:00:00.123456+00:00",
  "loading_policy": null,
  "annotations": [
    {
      "id": "3f6c…-uuid",
      "type": "highlight",
      "page_number": 1,
      "color": "#fef08a",
      "content": null,
      "position_data": {
        "rects": [], "page_width": 1.0, "page_height": 1.0,
        "selected_text": "hello world",
        "start_offset": 10, "end_offset": 21,
        "prefix": "before ", "suffix": " after"
      },
      "created_at": "2026-07-01T00:00:00+00:00",
      "updated_at": "2026-07-01T00:00:00+00:00"
    }
  ]
}
```
`viewport_offset` appears inside position_data only for point bookmarks; prefix/suffix/viewport_offset are omitted from JSON when None (skip_serializing_if). `opened_at` is refreshed on every open. Note asymmetry: bookmarks created without position_data have `"position_data": null`.

## 2. Plain snapshot: `<appData>/web/<key>.snapshot.html`
Raw fetched HTML (pre-injection), refreshed atomically on every successful live load of a SAVED page (temp name `<key>.snapshot.tmp-<uuid>` — via with_extension — then rename). Served as offline fallback (after prepare_html with offline=true). Deleted on unsave/remove.

## 3. Managed archive: `<appData>/web/<key>.vellumweb`
The auto-archive destination; a full `.vellumweb` ZIP (see below). Deleted on unsave/remove.

## 4. Installed snapshot dir: `<appData>/web/archives/<key>/`
```
snapshot.html      — sanitized HTML with __VELLUM_ASSET__/<name> placeholder refs
assets/a0.png …    — captured subresources (flat generated names a{i}.{ext})
manifest.json      — pretty ArchiveManifest (optional)
```
Installed on every export/auto-archive and on .vellumweb import. Atomic swap: stage into sibling `<key>.staging-<uuid>`, move current dir aside to `<key>.old-<uuid>`, rename staging in, delete aside (restore aside on failure). Preferred offline source; served with placeholders rewritten to `<asset_base>/asset/<key>/<name>` and prepare_html(offline=true). Deleted on unsave/remove.

## 5. `.vellumweb` ZIP (portable, import/export format)
Entries and exact compression:
| entry | content | compression |
|---|---|---|
| `manifest.json` | pretty JSON ArchiveManifest | Deflate: Zopfli level 15 if ≤ 393216 bytes else flate2 level 9 |
| `snapshot/index.html` | sanitized snapshot HTML | same rule |
| `snapshot/assets/<name>` | asset bytes | Stored if ext ∈ {png,jpg,jpeg,gif,webp,avif,woff,woff2}; else Deflate level 9 |
| `text/pages.json` | compact `[{"number":1,"text":"…"}]` | text rule |
| `annotations.json` | compact `[Annotation…]` | text rule |

Manifest example:
```json
{
  "format": "vellumweb", "version": 1,
  "url": "https://example.com/post", "canonical_url": "https://example.com/post",
  "title": "Post", "captured_at": "2026-07-03T10:00:01+00:00",
  "generator": "Vellum 0.1.0", "loading_policy": "live-first",
  "page_count": 1, "last_page": 1,
  "hashes": { "snapshot_html": "sha256:…", "page_text": "sha256:…", "annotations": "sha256:…" },
  "assets": [ { "path": "snapshot/assets/a0.png", "url": "https://example.com/pic.png",
                "content_type": "image/png", "bytes": 7, "sha256": "sha256:…" } ],
  "assets_skipped": 0
}
```
Atomic write: temp `.{name}.tmp-{pid}-{uuid}` in dest dir, fsync, rename. Import verifies format marker, version ≤ 1, all hashes present, size caps (manifest 4 MiB, snapshot 25 MiB, annotations 32 MiB, asset 8 MiB each / 64 MiB total, enforced during decompression), and zip-slip-safe asset names.

## 6. Frontend localStorage
- `vellum.recent-pdfs`: JSON array of RecentPdf (max 8, newest first; entries without `kind` treated as pdf).
- AI conversations keyed by document URI (normalized URL for web) — handled by ai-store (out of scope here but the key IS `pdf_path`).

Compatibility contract for the Swift port: same directory layout under the app's Application Support dir, same sha256-hex keys over identically normalized URLs, same JSON field names (snake_case), same `.vellumweb` entry names + sha256 hash strings (`"sha256:" + lowercase hex`).

## IPC commands

All Tauri commands take camelCase JS arg names auto-mapped to snake_case Rust params. Errors are plain strings.

| command | args | returns | behavior / errors |
|---|---|---|---|
| `open_web_document` | `url: string, sessionId: string` | `DocumentInfo` | Normalize URL (errors above), load-or-create sidecar, set `opened_at`, save; register `Session::Web` under sessionId (closing/replacing any previous session with that id — rebind used for in-tab navigation). Returns `{kind:"web", pdf_path: normalizedUrl, title, page_count, last_page}`. |
| `open_vellumweb_file` | `path, sessionId` | `DocumentInfo` | Read+verify archive (blocking task), open session for manifest.url, install `archives/<key>/`, merge metadata (only fill locally-absent title/page_count/last_page; copy snapshot-only policy), set saved(+saved_at if absent), merge annotations by id preferring newer updated_at, save record, register session. Errors: see import feature. |
| `archive_webpage_default` | `sessionId, pages: [{number,text}], expectedUrl: string \| null` | `boolean` | False when expectedUrl (normalized) ≠ session URL. Else capture best snapshot, install archive dir, write `<key>.vellumweb`, mark saved-if-absent, true. Errors: session lookup, "PDFs are already portable — archiving applies to webpage tabs", fetch/snapshot errors, "The page could not be fetched and no local snapshot exists yet". |
| `export_vellumweb` | `sessionId, destPath, pages` | `ExportSummary {path, bytes, asset_count, assets_skipped}` | Same pipeline, dest = user path. |
| `set_webpage_saved` | `sessionId, saved: bool` | void | Web sessions only ("This tab is a PDF, not a webpage"). saved=false also deletes snapshot/archive artifacts. |
| `get_webpage_saved` | `sessionId` | bool | PDFs → false; web → record.saved (missing record → false). |
| `list_saved_webpages` | — | `WebLibraryEntry[]` | saved records, saved_at desc. |
| `remove_saved_webpage` | `url` | void | Normalize, un-save, delete artifacts, keep annotations. |
| `get_annotations` | `sessionId, pageNumber: number \| null` | `Annotation[]` | Web: from sidecar, optional page filter. |
| `create_annotation` | `sessionId, input: CreateAnnotationInput` | `Annotation` | UUID v4 id, now() timestamps, default colors highlight `#fef08a` / note `#fde68a` / bookmark null; appended to sidecar. |
| `update_annotation` | `sessionId, input` | bool (found) | Patches color/content/position_data when Some; bumps updated_at. |
| `delete_annotation` | `sessionId, id` | bool (removed) | retain by id. |
| `set_document_metadata` | `sessionId, key, value` | void | Web: "title" (trimmed, ignore empty), "page_count"/"last_page" (parse u32, unparseable → None), others ignored. |
| `save_file` | `sessionId` | void | No-op for web ("mutations are written to the sidecar immediately"); errors only on missing session. |
| `close_file` | `sessionId` | void | Removes session (web close is a no-op flush). |
| `read_pdf_bytes` | `sessionId` | bytes | Web → Err "This tab is a webpage, not a PDF". |

Non-IPC surface: the `vellum-web` custom protocol (documented under features) and the `window.__scrollToPage / __webHistory / __locateWebText / __captureWebPosition / __scrollToWebPosition` globals plus DOM events `vellum:add-webpage`, `vellum:annotations-updated`.

## External APIs

Only direct HTTP fetching of user-supplied web content via reqwest (no third-party API):
- Client: User-Agent `Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15 Vellum/0.1`; 30 s total timeout; redirects followed (reqwest default policy, max 10); **no cookies** sent or stored; no custom headers otherwise.
- Page fetch: plain GET of the normalized URL; success = 2xx; body cap 25 MiB (26214400 bytes) enforced while streaming chunks (also rejects up-front when Content-Length > cap) with error "Response is too large to load"; HTML iff Content-Type contains `text/html` or `application/xhtml` (missing header → treated as text/html); charset honored from `Content-Type: …; charset=X` via encoding_rs (fallback UTF-8); `response.url()` after redirects is the page's effective identity.
- Asset fetches during snapshot capture: same client; per-asset cap 8 MiB streamed; ≤80 assets; ≤64 MiB total; failures/oversizes are skipped (counted), never fatal.
- No streaming protocols, no auth. (AI providers are a separate subsystem; the web subsystem only contributes `pageTexts` to the AI context block `[Page N] …` truncated at 120,000 chars.)

## Porting notes

**Rendering strategy is the crux.** The Tauri app cannot host a second native webview under its React UI, so it proxies pages into a sandboxed iframe. In SwiftUI you can embed WKWebView directly under NSHostingView overlays, which removes the need for the iframe/postMessage boundary — but to stay 1:1 you must preserve: (a) the injected content script's exact behavior (port `assets/vellum-content-script.js` verbatim as a `WKUserScript` at `.atDocumentStart`, main frame only; replace `window.parent.postMessage` with `webkit.messageHandlers.vellum.postMessage` and shell→page commands with `evaluateJavaScript`), (b) the proxy semantics: CSP stripping + `<base href>` + meta-refresh removal + offline snapshot fallback. With WKWebView you may load live pages directly (X-Frame-Options no longer matters without an iframe), but then CSP would block nothing needed and `window.__VELLUM_PAGE_URL__/__VELLUM_OFFLINE__` must still be injected; offline snapshots can be served via `WKURLSchemeHandler` for a `vellum-web://` scheme replicating the `/asset/<key>/<name>` route and the snapshot-fallback chain, or via `loadHTMLString(_:baseURL:)`.
- **Fetch parity**: use URLSession with the exact UA string, 30 s timeout, no cookie storage (`.ephemeral` config), streamed 25 MiB cap. Redirect-driven URL rebinding (final URL becomes the tab identity, and the shell re-opens the session under it) must be reproduced — WKNavigationDelegate gives you the final URL naturally.
- **Zoom**: the iframe CSS-scale trick (`width:(100/zoom)%; transform:scale(zoom)`) maps to `WKWebView.pageZoom` (Safari-style text/page zoom that reflows) — closest native equivalent; selection rects then arrive pre-scaled so drop the `*zoom` coordinate math.
- **Popovers**: WebNoteComposer/Viewer/ContextMenu are plain app-shell views positioned at converted page coordinates; in Swift use NSPopover-like custom views in an overlay ZStack with the same clamp-to-window (8px margin), flip logic, 400 ms open-grace dismissal, and dismiss-on-page-scroll rules.
- **Text anchors are the compatibility contract**: raw-offset text map, whitespace collapse table (`isSpaceCode` set incl. U+00A0, U+1680, U+2000–200A, U+2028/29, U+202F, U+205F, U+3000, U+FEFF), the 3600-char page chunking with sentence-break heuristic, the resolveHighlight scoring (offset-distance minus 100000 per matching context side, length-preserving case fold guard), and 32-char quote contexts must match exactly or existing sidecar/.vellumweb annotations will anchor differently. Since this all lives in the injected JS, porting the script unmodified is the safest path.
- **Persistence**: reuse the exact paths/keys (`web/<sha256-hex>.json` etc.) under the app's Application Support dir if data migration matters; sha256 must be over the identically normalized URL (Rust `url` crate serialization — beware Swift URLComponents differences in trailing-slash/percent-encoding; e.g. `Url::to_string` keeps the path as-parsed and re-encodes query pairs via form-urlencoding when tracking params were stripped).
- **ZIP**: Swift needs Deflate zip writing (Compression framework / third-party); Zopfli is an optimization only — any Deflate is format-compatible; Stored-vs-Deflated per extension should be kept for size parity but readers don't care. Hash strings are `"sha256:" + lowercase hex`.
- **No native equivalent needed**: the `__VELLUM_DEV_PROXY__` test hook, Windows `http://vellum-web.localhost` scheme form, and the Tauri capability sandboxing notes are Tauri-specific and can be dropped.
- **Gotchas**: (1) mount-tab guard — content messages arriving after a tab switch must be ignored (per-tab WKWebView instances make this automatic if you keep one webview per tab instead of remounting). (2) `initCount` semantics: annotation/mode pushes must re-fire after in-tab navigation. (3) The auto-archive debounce (1500 ms) + Rust-side expectedUrl re-check together prevent archiving mismatched content mid-navigation — keep both. (4) `selection-cleared` doubling as click-outside for popovers only exists because parent can't see iframe clicks; with a native overlay you could use real hit-testing, but keep the 400 ms grace behavior for identical feel. (5) `history.go()` runs inside the page; WKWebView `goBack()/goForward()` is the analogue and will retrigger init via the injected user script. (6) The `pdf_path` field name carries the URL everywhere (recents, conversations, tab identity) — keep the name in serialized data even if the Swift property is nicer.

