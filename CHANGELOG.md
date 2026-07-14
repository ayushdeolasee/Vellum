# Changelog

All notable changes to Vellum are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

Adds a user-chosen storage location for the web library (iCloud Drive, a
custom folder, or this Mac), and restores the AI-experience features that
were lost in the scratchpad merge (which also committed literal conflict
markers, leaving `main` uncompilable), landing the final `ai-experience`
review commit that had never been merged.

### Added

- **Choose where your web library lives.** A one-time choice at launch (and
  in Settings ▸ Storage): iCloud Drive — everything (offline copies,
  highlights, notes, reading positions) lives in `iCloud Drive ▸ Vellum` and
  syncs across Macs — a custom folder (offline copies only; reading state
  stays local and does not sync, stated in the UI), or this Mac (the previous
  layout). Existing libraries migrate in the background, and interrupted
  moves resume at the next launch.
- Offline copies are now human-navigable: one `<Page Title>.vellumweb` per
  page in a visible `Web Pages` folder instead of SHA-256 filenames.
- **Automatically save every page for offline use** (Settings ▸ Storage, off
  by default): restores the old open-means-keep behavior as an opt-in; pages
  saved this way are exempt from the six-month cleanup.
- The web toolbar's two actions are now one **Save for Offline Use / Remove
  Offline Copy** toggle — saving also (re)writes the offline copy if it is
  missing, removing deletes the copy but never highlights, notes, or reading
  position. Exporting a portable archive elsewhere lives on as
  "Export a Copy…".
- **Screenshots into the AI chat.** The AI panel's "+" attach menu offers
  "Attach current page" (full-page snapshot) and "Snapshot region…"
  (drag-to-crop a marquee over the PDF); both attach the image as a composer
  reference sent with the next message. The one `.snapshotRegion` mode is now
  shared with the scratchpad via `AppStore.regionCaptureTarget`, so each
  panel's crop lands in the panel that armed it.
- **Reference reading-material text in the AI chat.** Selecting text in a PDF
  shows an "Ask AI about this" (sparkles) button in the selection popover; the
  selected text attaches as a quoted reference chip in the AI composer.
- **`getAnnotations` AI tool** — the model can list your notes and highlights
  across the whole document (or one page), so cross-page annotation questions
  work again now that the context block only carries the current page.
- Scratchpad is per-pane in split view: each pane keeps its own note, scoped
  to the document that pane is showing.

### Fixed

- **Add-note-from-selection works again**: repaired the scratchpad merge so
  the selection popover (highlight swatches, note input, Ask AI) is wired up
  in the shipped ContentView; `main` now compiles.
- AI replies no longer clip silently: output caps raised (2048 → 8192 base)
  on every provider, and token-limit cutoffs surface as a visible truncation
  note (or an error when nothing streamed).
- Gemini in-band stream errors and safety blocks now surface instead of
  producing an empty reply.
- User-attached reference snapshots are forwarded to OpenCode Zen/Go (they
  previously only received the automatic page image).
- ChatGPT "Auto" thinking mode lets the backend apply its default reasoning
  effort; OpenRouter/OpenCode downgrade the OpenAI-only "minimal" effort to
  "low" for non-OpenAI models.
- `searchDocument` regexes match across line breaks and support `^`/`$`
  anchors; extracted page text preserves line structure.
- Settings no longer performs five synchronous Keychain writes per keystroke
  in the API-key fields — only the account that changed is written.
- Streaming no longer re-parses every visible message's markdown on each
  token (was O(n²) on the main thread).

## [0.1.0] — 2026-07-14

First versioned release, covering the `ai-ondemand-retrieval` branch
(30 commits, 78 files, +8,802/−476 vs `main`).

### Added

- **On-demand document retrieval for the AI agent.** Two read tools scoped to
  the current document: `searchDocument` (case-insensitive literal or regex
  search over extracted page text — capped at 8 hits, ~200 chars of context,
  100k-char per-page scan limit) and `getPageText` (bounded single-page reads
  with the page's annotations appended). The model retrieves the pages it
  needs instead of receiving the whole document up front.
- **User-selectable thinking mode** (reasoning effort) across all AI
  providers.
- **Persistent page-text cache.** Extracted text is stored per document —
  path-keyed, hash-validated against file content, and resumable across
  launches (`PageTextCache`, `PageTextPersister`).
- **Storage tab in Settings** with cache size display and launch-time TTL
  eviction.
- **AI benchmarking suite** (`Benchmarks/`). A reproducible Python harness
  that runs models through Vellum's actual document prompt and tool loop
  against curated questions with hidden gold pages. `doctor` validates the
  corpus (PDFKit extraction, Poppler fallback off-macOS), `model` runs a
  provider under a `--cost-stop-usd` budget guard, `compare` diffs two runs.
  Reports capture retrieval hit rate, MRR, answer-claim accuracy, tool
  selection/ordering, tokens, cache usage, latency, and cost.
- **Markdown and LaTeX rendering** for both AI chat and notes through one
  shared pipeline, with math typeset via SwiftMath.
- **Compiling unit-test target** with 87 tests across six suites: AI
  pipeline, markdown parser, page-text cache, PDF persistence, selectable
  messages, and web proxy URLs.
- Implementation-plan archive (`advisor-plans/`) recording two audit rounds
  and the execution log for the 11 hardening plans included in this release.

### Changed

- **Prompt caching.** System prompts are split stable-first/volatile-last so
  provider prompt caches hit; Anthropic requests set `cache_control`
  breakpoints at the boundary and OpenAI requests send a per-conversation
  `prompt_cache_key`.
- **Truthful proxy URLs.** The web viewer shows the page's real URL while a
  custom scheme handler serves archived content behind the scenes.
- Same-page `#fragment` links (e.g. table-of-contents anchors) scroll in
  place instead of reloading the reader.
- Automatic page screenshots are attached only when the visible page falls
  below the low-text threshold (scanned/graphical pages), not on every
  message.
- Conversation persistence rewritten as an in-memory cache with a coalescing
  write-behind flush, guaranteed to flush on quit — no more full-blob disk
  write per streamed token.

### Fixed

- App crash triggered by the model selector: the macOS Passwords-autofill
  helper aborts the app when a stock `SecureField` meets a popover. API-key
  entry now uses a purpose-built autofill-free `RevealableSecureField`.
- OpenAI and Gemini clients no longer retry requests the user cancelled.
- Correct thinking-budget mapping for Gemini 2.5 Pro.
- `plainPreview` no longer swallows currency amounts (`$5`) by treating them
  as inline math; math stripping now routes through `MathRenderer.segments`.
- Unclosed display math renders as a code block while streaming instead of
  half-typeset output; the math render cache is bounded.
- Page-text cache races found in review: cross-tab contamination, missing
  flush barriers, and delete races.

### Performance

- Streaming markdown re-render is skipped when message content and palette
  are unchanged, taking per-token rendering from O(n²) to O(n); the same fix
  eliminated stale math attachments.
- Document search is cancellable and text extraction yields periodically, so
  long operations never block the chat UI.

### Security

- The web bridge's `open-external` message is narrowed to validated YouTube
  video ids; it can no longer open arbitrary URLs.
- Proxy-URL round-trip hardened: stray `%` encoding, userinfo
  canonicalization, and an adversarial test table covering hostile URLs.
- Archive-asset route accepts hex-only keys and rejects path traversal.

### Internal

- `.benchmark-cache/` untracked and gitignored (regenerable via
  `Benchmarks/vellum_bench.py doctor`).
- SwiftMath pinned to an exact version; generated Xcode project re-baselined
  (`xcodegen generate` is idempotent).
- Port-era specs bannered as historical; README requirements corrected.
