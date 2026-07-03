# Webpage Support — Plan

## Goal

Let the user add a webpage (blog post, research article, docs page) to Vellum as a
first-class tab, with the same tools a PDF gets: highlights, sticky notes, bookmarks,
and the AI panel (context, chat, `goToPage` / `addNote` / `addHighlight` actions).
The page is **not** converted to a PDF — it stays a live, interactive webpage
(embedded videos, code toggles, footnote popovers, etc. keep working). Saved
webpages appear in a library so they can be reopened later.

---

## Architecture Decision: How to Render the Page

Three options were considered:

| Option | Fidelity / interactivity | Tool integration | Complexity |
|---|---|---|---|
| **A. Proxied iframe** (recommended) | High — real HTML/JS runs | Good — injected content script + `postMessage` | Medium |
| B. Tauri child webview | Highest | Poor — native webview sits *above* the React UI; no overlays, IPC from remote pages needs `dangerousRemoteDomainIpcAccess`; multiwebview is behind an unstable flag | High |
| C. Reader-mode extraction (Readability → React DOM) | None — static article only | Best | Low |

**Recommendation: Option A — a sandboxed iframe fed by a Rust proxy over a Tauri
custom protocol.** Option C fails the interactivity requirement outright (though it
makes a nice future "Reader view" toggle). Option B renders pixels perfectly but
breaks the entire annotation/AI overlay model: Vellum's popovers, highlight layers,
and sidebar interactions cannot be composited over a separate native webview.

### How Option A works

1. User enters a URL. The iframe's `src` is `vellum-web://<encoded-url>`.
2. A Rust custom-protocol handler (`register_uri_scheme_protocol("vellum-web", …)`)
   fetches the URL with `reqwest`, then:
   - strips `X-Frame-Options` and `Content-Security-Policy` response headers that
     would block framing;
   - injects `<base href="<original-url>">` so relative subresources resolve
     against the real origin (images, CSS, scripts load directly from the web);
   - injects the **Vellum content script** as the first `<script>` in `<head>`.
3. The page runs inside the iframe as normal HTML/JS — fully interactive.
4. The content script is Vellum's agent inside the page. It talks to the React app
   exclusively via `window.parent.postMessage` (the iframe is cross-origin to the
   app shell, so neither side can touch the other's DOM — which is also the
   security boundary we want).

**Content script responsibilities** (single bundled file, `src/webpage/content-script.ts`,
built as an extra Vite entry and embedded into the proxied HTML by Rust):

- Report metadata: `<title>`, canonical URL, favicon, byline/og tags.
- Extract readable text and chunk it into **virtual pages** (see below).
- Report text selections: selected string, prefix/suffix context, viewport rects
  → drives the existing `SelectionPopover` (rendered by React in the app shell,
  positioned using forwarded rects + the iframe's offset).
- Apply/remove highlights using the **CSS Custom Highlight API** (no DOM
  mutation, so page scripts don't break), re-anchoring by text quote on load.
- Scroll to a virtual page / anchored text on command.
- Intercept link clicks: same-document anchors scroll normally; other links
  navigate the tab through the proxy (with simple back/forward); a modifier-click
  opens in the system browser.
- Report scroll position (for restoring reading position later).

### Virtual pages

Webpages have no pages, but Vellum's tab state, annotation schema
(`page_number`), AI context format (`[Page N] …`), and the `goToPage` tool are all
page-indexed. Rather than rework all of that, the content script chunks the
extracted text into virtual pages (split on `h1/h2/h3` boundaries, merged/split to
roughly 3–4k chars each) and remembers a scroll anchor for each chunk. Then:

- `goToPage(n)` → scroll to virtual page *n*'s anchor.
- `currentPage` / `visiblePages` → derived from scroll position via the chunk anchors.
- `setPageText(n, text)` → populated once at load; the AI context block and
  `MAX_CONTEXT_CHARS` bounding work unchanged.
- `addHighlight(page, text)` → content script text-search within chunk *n* (same
  philosophy as `locateTextOnPage`: geometry is resolved from real text, never
  trusted from the model).

### Annotation anchoring & persistence

PDF annotations are embedded in the file itself; there is no equivalent for a
webpage we don't own. Instead:

- **Anchor model:** W3C-style text-quote anchors — `{ exact, prefix, suffix }` plus
  a character-offset hint. Robust to minor page edits; if re-anchoring fails on a
  later visit, the annotation is listed as "orphaned" in the sidebar instead of
  silently dropped. Reuses the existing `Annotation` shape: `position_data.selected_text`,
  `start_offset`/`end_offset`, `page_number` = virtual page; `rects` are computed
  live by the content script rather than stored as gospel.
- **Store:** JSON sidecar per page in the app data dir —
  `app_data_dir/web/<sha256(normalized-url)>.json` containing metadata +
  annotations. New Rust module `web_session.rs` with commands mirroring the PDF
  ones (`open_web_document`, `create/update/delete_annotation`, `set_document_metadata`)
  so `annotation-store.ts` needs only a dispatch on document kind.
- **URL normalization:** strip fragments and tracking params (`utm_*`, `fbclid`, …),
  prefer `<link rel="canonical">` when present, so the same article maps to one record.

### Saving & the library

- "Save" (bookmark icon in the toolbar / auto-save on first annotation) records the
  page in the library: URL, title, favicon, excerpt, saved-at, last scroll position.
- **Offline snapshot:** on save, the Rust side stores the proxied HTML (post-injection,
  pre-render) to `app_data_dir/web/<hash>/snapshot.html`. Reopening loads **live
  first, snapshot as fallback** when offline or the page 404s/link-rots. A per-page
  "pin snapshot" toggle can force the frozen copy (useful for citing).
- `WelcomeScreen` gains a second list ("Saved pages") next to recent PDFs; recents
  logic generalizes from `recent-pdfs.ts` to `recent-documents.ts`.

### Data model changes (frontend)

```ts
type DocumentKind = "pdf" | "web";

interface DocumentInfo {
  kind: DocumentKind;        // new
  uri: string;               // pdf_path or normalized URL (pdf_path kept as alias during migration)
  title: string | null;
  page_count: number | null; // virtual page count for web
  last_page: number | null;
}
```

`PdfTab` → `DocumentTab { kind, … }`. `pdf-store.ts` becomes `document-store.ts`
(or gains `openUrl(url)` alongside `openFile(path)`); zoom for web tabs maps to
iframe CSS `zoom`/text scale. Conversation storage in `ai-store.ts` already keys by
`pdf_path` — keying by normalized URL works with zero changes beyond the rename.

### AI integration

- Context block: identical format; virtual page texts feed `pageTexts`.
- Tools: `goToPage`, `addNote`, `addHighlight` all work via the mappings above.
- `currentPageImage`: **not available for web tabs initially** (an app-shell webview
  cannot screenshot a cross-origin iframe). Ship without it — the extracted text is
  strong context for articles — and later optionally add a Rust-side headless
  capture or `Window::screenshot` if it proves needed. The system prompt gets a
  line telling the model when it's reading a webpage vs a PDF.

### Security notes

- The proxied page's JS runs inside a cross-origin iframe: it cannot reach the app
  shell's DOM, localStorage, or Tauri IPC (Tauri 2 capabilities are webview/origin
  scoped and no remote capability is granted). `postMessage` handlers in the app
  validate origin + message schema.
- The proxy sends **no cookies** and a plain browser User-Agent; it follows
  redirects with a cap and enforces a response-size limit. Auth-walled/paywalled
  pages therefore won't load — acceptable for the blog/article use case.
- CSP stripping happens only inside the sandboxed iframe origin, never for the app
  shell. `tauri.conf.json` CSP gains `frame-src vellum-web:`.

---

## Phases

**Phase 1 — Live web tabs.** URL entry (Welcome screen "Add webpage" + Cmd+L),
Rust proxy protocol, iframe viewer component, `DocumentTab.kind`, tab bar/toolbar
adaptation (hide PDF-only controls for web tabs), title via content script.

**Phase 2 — Tools parity.** Content script bridge (selection → popover, highlights
via Custom Highlight API, notes, bookmarks), text-quote anchoring, JSON sidecar
persistence in Rust, annotation sidebar working for web tabs.

**Phase 3 — AI parity.** Virtual paging → `pageTexts`, `goToPage`/`addHighlight`/
`addNote` execution for web tabs, prompt updates, per-URL conversations.

**Phase 4 — Library.** Save action, saved-pages list on Welcome screen, offline
snapshots with live-first/snapshot-fallback, scroll-position restore.

---

## Open questions

1. **Link navigation default** — navigate in-tab through the proxy (proposed) vs
   always opening external links in the system browser.
2. **Snapshot policy** — snapshot on save (proposed) vs snapshot on every visit
   (keeps annotations anchorable even as pages change, costs disk).
3. **Reader-mode toggle** — worth adding later as an alternate view for hostile
   pages (heavy ads/layout) where the proxy renders poorly?
4. **Page image context for AI** — skip for web (proposed) or invest in a capture
   path early?
