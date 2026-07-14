# Changelog

All notable changes to Vellum are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

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
