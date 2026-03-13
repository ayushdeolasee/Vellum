# AGENTS.md

## Project Overview

Research Reader is a Tauri 2.0 desktop app for AI-powered PDF annotation.
Stack: Tauri 2 (Rust backend) + React 19 + TypeScript 5.9 + Vite 7 + Tailwind CSS v4 + Zustand 5 + react-pdf 10.
Custom `.rr` file format: ZIP container bundling `document.pdf` + `data.sqlite` + `manifest.json`.

## Build & Dev Commands

```bash
# Run the full desktop app (kills old instances first)
pkill -f "research-reader"; npm run tauri dev

# TypeScript type check (no emit)
npx tsc --noEmit

# Rust type check
cargo check                  # run from src-tauri/

# Lint (ESLint flat config)
npm run lint

# Production build
npm run build                # tsc -b && vite build
npm run tauri build          # full Tauri production bundle
```

There are no test suites configured yet (no vitest/jest, no `#[cfg(test)]` blocks in Rust).

## Project Structure

```
src/                          # React frontend
  main.tsx                    #   App entry (StrictMode + top-level ErrorBoundary)
  App.tsx                     #   Root layout, keyboard shortcuts, pinch-to-zoom
  index.css                   #   Tailwind v4 theme (@theme directive, light/dark)
  types/index.ts              #   Shared types (mirrors Rust models, snake_case fields)
  types/gesture.d.ts          #   WebKit GestureEvent ambient type declaration
  stores/pdf-store.ts         #   Zustand: document, viewport, zoom, mode
  stores/annotation-store.ts  #   Zustand: annotations CRUD, selection, optimistic updates
  lib/tauri-commands.ts       #   Tauri IPC bridge (typed invoke wrappers)
  lib/utils.ts                #   cn() utility (clsx + tailwind-merge)
  hooks/useTextSelection.ts   #   Text selection -> highlight coords
  components/                 #   React components (see conventions below)

src-tauri/src/                # Rust backend
  lib.rs                      #   Tauri builder, plugin registration, command list
  commands.rs                 #   9 IPC commands + DocumentInfo struct
  models.rs                   #   Data models (Annotation, PositionData, Rect, etc.)
  database.rs                 #   SQLite CRUD (rusqlite)
  rr_file.rs                  #   .rr ZIP container ops (open, save, import, cleanup)
```

## Code Style — TypeScript / React

### Formatting
- **Double quotes**, **semicolons**, **2-space indent**
- No Prettier/Biome configured — maintain consistency manually

### Imports (order matters)
1. React imports (`import { useState } from "react"`)
2. Third-party (`react-pdf`, `@tauri-apps/*`, `lucide-react`)
3. Internal absolute (`@/stores/...`, `@/components/...`, `@/lib/...`, `@/types/...`)
4. Relative (`./StickyNoteOverlay`)
5. Type-only imports use `import type { ... }` — enforced by `verbatimModuleSyntax`

### Naming
- **Components**: PascalCase file + function (`PdfViewer.tsx` → `export function PdfViewer()`)
- **Hooks**: `use` prefix, camelCase (`useTextSelection.ts`)
- **Stores**: kebab-case file, camelCase hook (`pdf-store.ts` → `usePdfStore`)
- **Utils/commands**: kebab-case file (`tauri-commands.ts`)
- **Types/interfaces**: PascalCase (`Annotation`, `DocumentInfo`)
- **Constants**: UPPER_SNAKE_CASE (`PAGE_BUFFER`, `MIN_ZOOM`, `HIGHLIGHT_COLORS`)
- **Fields**: snake_case to match Rust serde (`page_number`, `position_data`)

### TypeScript Strictness
`strict: true`, `noUnusedLocals`, `noUnusedParameters`, `noFallthroughCasesInSwitch`.
Path alias: `@/*` → `./src/*`. Target: ES2022.

### React Patterns
- All function components; **never class components** except `ErrorBoundary`
- `React.memo` on perf-critical overlay components (`HighlightLayer`, `StickyNoteOverlay`)
- `forwardRef` when parent needs ref access
- Named exports everywhere except `App` (default export)
- **All hooks must be called before any early returns** — this is critical

### Zustand Stores
- Interface defines state + actions together
- State fields listed first, then actions
- `create<StoreInterface>((set, get) => ({ ... }))`
- **Individual selectors** in components: `usePdfStore((s) => s.zoom)` — never destructure entire store
- **`getState()`** for non-reactive access (event handlers, keyboard shortcuts)
- Async actions: try/catch, return `null` on failure
- **Optimistic updates** with rollback: update state first, call backend, revert on error

### Tauri IPC
- Frontend: `src/lib/tauri-commands.ts` — typed async wrappers around `invoke<T>()`
- Import as namespace: `import * as commands from "@/lib/tauri-commands"`
- Function names: camelCase in TS, snake_case in Rust

### Styling
- Tailwind CSS v4 with `@theme` directive in `index.css`
- Semantic tokens: `background`, `foreground`, `muted`, `primary`, `accent`, `destructive`
- `cn()` from `@/lib/utils` for conditional class merging
- All styling via `className` — no CSS modules, no styled-components

## Code Style — Rust

### Formatting
- Standard rustfmt defaults (4-space indent, no custom config)
- Doc comments (`///`) on every public command

### Naming
- Modules: snake_case (`rr_file`, `database`)
- Structs/Enums: PascalCase (`RrSession`, `AnnotationType`)
- Functions: snake_case (`open_file`, `create_annotation`)

### Tauri Commands
- `#[tauri::command]` annotation, `pub fn`, in `commands.rs`
- Last param: `state: State<AppState>`
- Lock mutex, check session exists, return `Result<T, String>`
- Errors: `.map_err(|e| format!("Description: {}", e))`
- Register in `lib.rs` via `tauri::generate_handler![...]`

### Serde
- `#[derive(Debug, Clone, Serialize, Deserialize)]` on all data structs
- `#[serde(rename = "type")]` for reserved-word fields
- `#[serde(rename_all = "lowercase")]` on enums
- `position_data` stored as JSON string in SQLite, deserialized with `serde_json::from_str`

### AppState
- `Mutex<Option<RrSession>>` — `None` when no file open
- Previous session cleaned up when opening new file

## Error Handling

| Layer | Pattern |
|-------|---------|
| React render | `ErrorBoundary` wraps entire app (top-level) and `<Document>` (inner) |
| Zustand actions | try/catch, `console.error("[module] message", err)`, return `null` |
| Fire-and-forget | `.catch(() => {})` for auto-save, metadata persistence |
| Tauri bridge | Errors bubble as rejected promises from `invoke()` |
| Rust commands | `Result<T, String>`, `.map_err()` with descriptive messages |

Console log prefix convention: `[ComponentName]` or `[module-name]` (e.g., `[PdfViewer]`, `[annotation-store]`).

## Key Architecture Notes

- Coordinates in `position_data` are normalized to zoom=1.0, scaled on render
- Page virtualization: only renders pages within `PAGE_BUFFER` (2) of viewport
- `useDeferredValue(zoom)` batches expensive `<Page>` canvas re-renders during rapid zoom
- `window.__scrollToPage` exposes scroll function for cross-component use
- Keyboard shortcuts centralized in `App.tsx`, use `getState()` to avoid stale closures
- Pinch-to-zoom handled at document level in `App.tsx` (WebKit GestureEvent + wheel+ctrlKey fallback)
- `.rr` file extracted to temp dir on open; SQLite writes are instant; re-packed to ZIP on save

## Cursor Cloud specific instructions

### Environment prerequisites (already installed by the VM snapshot)
- **Rust toolchain**: Must be ≥ 1.85 (edition2024 support required by transitive dep `dlopen2`). The snapshot installs latest stable via `rustup update stable && rustup default stable`.
- **Tauri Linux system libs**: `libwebkit2gtk-4.1-dev`, `libgtk-3-dev`, `libjavascriptcoregtk-4.1-dev`, `libsoup-3.0-dev`, `libappindicator3-dev`, `librsvg2-dev`, `patchelf`.
- **Xvfb**: Needed for headless GUI testing; start with `Xvfb :99 -screen 0 1280x800x24 -ac &` and `export DISPLAY=:99`.

### Running the app in the cloud VM
- Start a virtual display before launching the Tauri app: `Xvfb :99 -screen 0 1280x800x24 -ac &` then `export DISPLAY=:99`.
- Launch with `DISPLAY=:99 npm run tauri dev` from the workspace root. The `beforeDevCommand` in `tauri.conf.json` auto-starts Vite on port 5173 and regenerates icons.
- First Rust build takes ~60s; subsequent incremental builds are fast.
- The GTK file dialog may have trouble with `/tmp` permissions; copy test files to `/home/ubuntu/` if needed.

### Checks (no test suites exist)
- **Lint**: `npm run lint`
- **TypeScript**: `npx tsc --noEmit`
- **Rust**: `cargo check` (from `src-tauri/`)
- There are no automated test suites (no vitest/jest, no `#[cfg(test)]`).
