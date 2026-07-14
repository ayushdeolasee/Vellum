> **HISTORICAL — describes the pre-port Tauri app, not the current SwiftUI app.**
> Written as reference material for the Tauri→SwiftUI port (2025–2026). The current
> app has diverged (e.g. 6 streaming AI providers and 5 tools vs. the 3 non-streaming
> providers / 3 tools described here; no Codex CLI provider; repo-root layout, not
> `macos/`). Do not treat file paths, behavior, or UI specs here as current.

## Coverage gap analysis

Overall verdict: coverage is **very close to complete**. All 18 Tauri commands registered in `src-tauri/src/lib.rs` are accounted for across the five digests (`open_file`, `open_web_document`, `save_file`, `close_file`, `read_pdf_bytes`, `get_annotations`, `create_annotation`, `update_annotation`, `delete_annotation`, `set_document_metadata`, `set_webpage_saved`, `get_webpage_saved`, `list_saved_webpages`, `remove_saved_webpage`, `export_vellumweb`, `open_vellumweb_file`, `archive_webpage_default`, `run_codex_ai`). No drag-drop, no deep links, no Tauri event listeners, no custom native menu exist in the code. The gaps below are small but real.

### 1. Source files not covered by any reader

- `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/components/ui/Button.tsx` — shared text-button primitive. Variants `primary | secondary | ghost`, sizes `sm` (h-7, px-2.5, text-xs, gap-1.5) / `md` (h-9, px-3.5, text-sm, gap-2) / `lg` (h-11, px-5, text-sm); rounded-md, `shadow-soft` on primary, `disabled:opacity-50`, default `type="button"`. Used across Welcome/Toolbar/panels — a Swift engineer needs these exact metrics once, not per-subsystem.
- `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/components/ui/IconButton.tsx` — square icon button, variants `ghost | primary | active`, sizes `sm` 28×28pt (h-7 w-7) / `md` 32×32pt (h-8 w-8), rounded-md; ghost is `disabled:opacity-30` (note: different from Button's 0.5), `active` = filled primary background.
- `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/components/ui/Wordmark.tsx` — "Vellum" in serif face, 15px, font-semibold, tracking-tight, followed by a primary-colored period (`Vellum` + accent `.`), select-none.
- `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/lib/utils.ts` — `cn()` (styling only), plus platform helpers used in visible copy: `isMac` (regex `/mac/i` on `navigator.platform||userAgent`), `modKey` = `"⌘"` on macOS else `"Ctrl"`, `shortcut(key)` = `"⌘O"` (no separator) on macOS vs `"Ctrl+O"` elsewhere. Every shortcut label in tooltips/welcome screen goes through this.
- `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/main.tsx` — top-level crash fallback UI distinct from ErrorBoundary's default: "Application crashed" (destructive color, lg semibold), the `error.message`, a scrollable `error.stack` `<pre>` (max-h-48), and a "Reload app" button calling `window.location.reload()`. Also loads `katex.min.css` globally and calls `initTheme()` before first paint. Only worth porting if app-shell's "Error boundary" section didn't capture this exact fallback markup.
- `/Users/ayushdeolasee/Developer/Vellum-worktree-cc/swiftUI-port/src/types/gesture.d.ts`, `speech.d.ts`, `markdown.d.ts` — type shims only (Safari GestureEvent, webkitSpeechRecognition, markdown module decls). No behavior; safe to skip.
- Non-app directories, intentionally out of scope: `website/` (marketing site), `install.sh`, `macos/` (the SwiftUI port target itself, contains `PORT-DESIGN.md` and `specs/`), `PLAN.md`, `PLAN-WEBPAGES.md`, `AGENTS.md`.

### 2. Tauri commands missed

None. All 18 registered commands appear in at least one digest. Also confirmed there are no other `#[tauri::command]` functions outside the registered list.

### 3. Features visible in code but absent/uncertain in digests

- **Config-level window & platform facts** (verify app-shell captured the numbers): `tauri.conf.json` — window title "Vellum", 1280×800 default, min 800×600, resizable, not fullscreen; updater endpoint `https://github.com/ayushdeolasee/Vellum/releases/latest/download/latest.json` with a minisign pubkey; `csp: null`.
- **Filesystem permission scopes** (`src-tauri/capabilities/default.json`): read/write allowed under `$HOME/**`, `$DOWNLOAD/**`, `$DOCUMENT/**`, `$DESKTOP/**`, `$TEMP/**`, `/var/folders/**`, `/tmp/**`. Matters for the macOS sandbox/entitlements design of the port.
- **⌘O opens a multi-select dialog with three filters** — `{name:"Documents", extensions:["pdf","vellumweb"]}`, `{name:"PDF", extensions:["pdf"]}`, `{name:"Vellum Web Archive", extensions:["vellumweb"]}` — and routes each selection by extension: `.vellumweb` (case-insensitive suffix) → `open_vellumweb_file`, everything else → `open_file`. `openFiles` opens sequentially, collects per-file errors as `"{path}: {error}"` joined with `"\n"` into the store's single `error` field. This routing sits between app-shell (App.tsx handler) and web (import command); confirm one spec owns it.
- **Full global shortcut list in App.tsx** (confirm each is in a spec): ⌘/Ctrl+O open dialog; ⌘/Ctrl+L dispatch `vellum:add-webpage`; ⌘/Ctrl+S save; ⌘/Ctrl+W close tab (key compared lowercased); ⌘/Ctrl+1–9 activate tab by index (only preventDefault if tab exists); ⌘/Ctrl+= zoom in; ⌘/Ctrl+- zoom out; ⌘/Ctrl+B toggle bookmark (only if a document is open); Escape deselects annotation AND resets mode to "view"; bare `n` (no ctrl/meta, target not input/textarea, document open) toggles note mode. Note ⌘B/N/Escape overlap three subsystem specs — one of them must own the exact guard conditions.
- **No native menu bar customization, no drag-drop file opening, no deep-link/URL-scheme app activation, no `tauri://` event listeners** — the app relies on Tauri's default macOS menu. Explicitly worth stating in the port spec so the Swift engineer doesn't invent File > Open behavior beyond ⌘O.
- **Dev-only logging plugin** (`tauri_plugin_log`, Info level, debug builds only) and Windows `windows_subsystem` attribute in `main.rs` — no user-visible behavior on macOS.

### 4. Cross-cutting behaviors falling between subsystems

- **In-app event bus (exactly two custom window events):**
  - `vellum:add-webpage` — dispatched by App.tsx on ⌘L; listened to by `Toolbar.tsx` (opens the URL prompt). Spans app-shell ↔ pdf-viewing(toolbar)/web.
  - `vellum:annotations-updated` — dispatched by `pdf-store.ts` after a `.vellumweb` import (`openOneFile`, because an import can merge annotations into an already-active tab without a document identity change) and listened to in App.tsx, which calls `loadAnnotations()` if a document is open. Spans web(import) ↔ app-shell ↔ annotations. If no digest names this event pair, the merged-import-into-active-tab refresh will silently break.
- **App.tsx annotation/AI reload keying**: annotations + AI context clear-and-reload is keyed on `(activeTabId, doc.pdf_path)` — deliberately NOT on the document object, so a webpage retitling itself does not wipe AI context/annotations. This is a subtle contract between app-shell, annotations, and ai.
- **AI tool calls mutate annotations through the annotation store**, and `addHighlight` depends on `highlight-locator.ts` (annotations reader) while the tool guard/dispatch lives in `ai-store.ts` (ai reader). Both digests mention their half; verify the handoff (exact arg mapping from the JSON `actions[].args` to `CreateAnnotationInput`, and what happens when the locator fails) is specified once end-to-end.
- **`vellum-web://` protocol snapshot-freshening on redirects** (lib.rs lines 136–167): on a redirect the page is served under the *effective* URL and the snapshot is refreshed under the effective key only if *that* record is saved. The web digest covers the proxy generally; this redirect/rebind + selective snapshot-write rule is easy to lose and lives in lib.rs, not web_page.rs.
- **30s auto-save timer** lives in App.tsx but is described in the pdf-viewing digest — fine, just ensure the web spec notes `save_file` is a no-op for web tabs so the timer's existence doesn't imply web-side behavior.
