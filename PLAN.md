# Research Reader — Project Plan

## Vision

An AI-powered PDF reader and annotation tool. Load any PDF, annotate it (highlights,
notes, bookmarks), and get help from an AI that can see what you're reading, create
annotations on your behalf, and converse via chat or voice.

---

## Tech Stack

| Layer              | Technology                    | Notes                                            |
|--------------------|-------------------------------|--------------------------------------------------|
| Desktop shell      | Tauri 2.0 (Rust)             | Light (~10MB), native OS integration, emerging iOS support |
| Frontend           | React + TypeScript            | Shares code with future React Native iPad app    |
| Build tool         | Vite                          | Fast dev server, first-class Tauri integration    |
| PDF rendering      | react-pdf (PDF.js)            | Industry standard browser-based PDF rendering     |
| State management   | Zustand                       | Lightweight, good for complex annotation state    |
| Styling            | Tailwind CSS v4               | Fast to build, dark mode, consistent design       |
| AI abstraction     | Vercel AI SDK                 | Model-agnostic: Gemini, OpenAI, Anthropic, local  |
| Voice (default)    | Web Speech API / Whisper      | Push-to-talk STT, TTS for AI responses            |
| Voice (advanced)   | Gemini Live / OpenAI Realtime | Full conversation mode, toggled in settings        |
| AI key management  | BYOK (Bring Your Own Key)     | User provides API keys in settings panel           |

---

## Embedded PDF Persistence

Vellum opens and edits standard PDF files directly. Highlights, sticky notes,
bookmarks, and reading metadata are embedded in the PDF, so the document carries
its annotations when it is renamed, moved, or shared.

### Storage Layout

```
document.pdf
  ├── /Highlight annotations with /QuadPoints
  ├── /Text annotations for notes
  ├── /Outlines entries for bookmarks
  ├── /NM stable annotation identifiers
  └── PDF information dictionary reading metadata
```

### Key Properties

- **Standard annotations**: Other PDF applications can display Vellum highlights and notes
- **Portable**: Annotation state follows the PDF rather than its filesystem path
- **Immediately durable**: Every create, update, and delete writes an atomic replacement
- **Round-trip editing**: Vellum reads supported annotations from the PDF on every open

### Data Flow

1. **Open PDF**: Validate the PDF -> read embedded annotations -> load PDF via PDF.js
2. **Annotate**: Zustand updates optimistically -> write a standard PDF annotation object
3. **Edit/Delete**: Locate the object by `/NM` -> update or remove it -> atomically replace the PDF
4. **Reopen/Share**: Read annotations from the PDF regardless of its current path

### Annotation Position Data

Dual-anchored for resilience:
- **Rects** (x, y, width, height) — for fast rendering at any zoom
- **Text + character offsets** — for re-anchoring if rendering differs
- All coordinates normalized to zoom=1.0, scaled on render

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                    Tauri Shell                       │
│  ┌───────────────────────────────────────────────┐  │
│  │              React Frontend (Vite)             │  │
│  │                                                │  │
│  │  ┌──────────┐ ┌────────────┐ ┌─────────────┐ │  │
│  │  │ PDF View │ │ Annotation │ │  AI Panel    │ │  │
│  │  │ (PDF.js) │ │   Layer    │ │ (Chat+Voice) │ │  │
│  │  └──────────┘ └────────────┘ └─────────────┘ │  │
│  │                                                │  │
│  │  ┌────────────────────────────────────────┐   │  │
│  │  │         Zustand Stores                 │   │  │
│  │  │  pdf-store: pages, zoom, viewport      │   │  │
│  │  │  annotation-store: highlights, notes   │   │  │
│  │  │  ai-store: conversations, context      │   │  │
│  │  └────────────────────────────────────────┘   │  │
│  │                                                │  │
│  │  ┌──────────────────┐ ┌────────────────────┐  │  │
│  │  │ AI Provider      │ │ PDF Annotation I/O │  │  │
│  │  │ (Vercel AI SDK)  │ │ (lopdf)            │  │  │
│  │  └──────────────────┘ └────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
│                    Rust Backend                       │
│            (PDF mutation, IPC, native file dialog)   │
└─────────────────────────────────────────────────────┘
```

Store actions (addHighlight, addNote, etc.) are the shared API surface — called
by both UI event handlers and AI tool invocations. Same code path, same persistence.

---

## Implementation Phases

### Phase 1: Foundation — PDF Viewer + Annotations ✅ COMPLETE

All core functionality is implemented and working.

| # | Task | Status |
|---|------|--------|
| 1 | Scaffold Tauri 2.0 + Vite + React + TypeScript + Tailwind | ✅ Done |
| 2 | Implement direct PDF sessions with embedded standard annotations | ✅ Done |
| 3 | PDF viewer: render pages, scroll, zoom, page navigation, viewport tracking | ✅ Done |
| 4 | Toolbar: open PDFs directly, page number, zoom controls | ✅ Done |
| 5 | Text selection -> highlight creation with color picker | ✅ Done |
| 6 | Sticky notes: click-to-place, drag-to-reposition, expand/collapse, edit | ✅ Done |
| 7 | Annotation sidebar: list all annotations, click to navigate, filter by type | ✅ Done |
| 8 | Highlight + note overlay rendering on PDF pages | ✅ Done |
| 9 | Immediate embedded annotation writes + PDF reading-position metadata | ✅ Done |

**Phase 1 details — what was built:**

- **Rust backend** (9 Tauri IPC commands): `open_file`, `save_file`, `close_file`, `read_pdf_bytes`, `get_annotations`, `create_annotation`, `update_annotation`, `delete_annotation`, `set_document_metadata`
- **PDF viewer**: Page virtualization (PAGE_BUFFER=2), `useDeferredValue(zoom)` for smooth zoom, RAF-throttled scroll handler, `window.__scrollToPage` for cross-component navigation
- **Pinch-to-zoom**: Document-level WebKit GestureEvent handlers + wheel+ctrlKey fallback, continuous multiplicative scaling (0.25x–4.0x)
- **Keyboard shortcuts** (centralized in App.tsx): Ctrl+O open, Ctrl+S save, Ctrl+=/- zoom, Ctrl+B toggle bookmark, N toggle note mode, Escape deselect/exit mode
- **Annotations**: Standard `/Highlight`, `/Text`, and `/Outlines` objects, optimistic create/update/delete with rollback, pre-indexed by page via `Map<number, Annotation[]>` useMemo
- **Sticky notes**: Shared drag handler with 3px threshold (click vs drag), RAF-batched positioning, collapsed (icon) and expanded (card) states
- **Error handling**: Top-level ErrorBoundary (shows error + stack trace + reload), inner ErrorBoundary around `<Document>`, console.error with `[module]` prefixes
- **Context menu**: Right-click on PDF pages → "Add note here"

**Bugs fixed during Phase 1:**
1. Click outside expanded sticky note now collapses it (deselect on page/container click)
2. Collapsed sticky notes are draggable (shared `startDrag()` with click fallback)
3. Slow zoom fixed with `useDeferredValue(zoom)` for deferred canvas re-renders
4. Crash prevention: ErrorBoundary + try/catch around note creation + defensive guards
5. Blank screen on load: `useCallback` was placed after early returns (hooks ordering violation)

### Phase 2: AI Integration ✅ COMPLETE

| # | Task | Status |
|---|------|--------|
| 1 | AI chat side panel with Vercel AI SDK + Gemini (BYOK) | ✅ Done |
| 2 | Context system: full PDF text + current viewport focus + annotations | ✅ Done |
| 3 | AI tools: addHighlight(), addNote(), goToPage() — calls store actions | ✅ Done |
| 4 | Push-to-talk voice input (Web Speech API / Whisper) | ✅ Done |
| 5 | TTS for AI responses | ✅ Done |
| 6 | Settings: model selection, API keys, voice mode toggle | ✅ Done |

**Design notes:**
- AI shares the same store actions as UI (addHighlight, addNote, goToPage) — no separate code paths
- BYOK: user provides their own API keys (Gemini, OpenAI, Anthropic) via a settings panel
- Context window: extract full PDF text + serialize visible page range + current annotations as structured context for the AI
- AI tools are function-calling based — the AI SDK invokes store actions, results appear in the UI instantly via optimistic updates

### Phase 3: Advanced Voice ✅ COMPLETE

| # | Task | Status |
|---|------|--------|
| 1 | Full conversation mode (Gemini Live / OpenAI Realtime API) | ✅ Done |
| 2 | Streaming bidirectional audio | ✅ Done |
| 3 | Settings toggle between push-to-talk and conversation mode | ✅ Done |

### Phase 4: Platform Expansion ⬜ FUTURE

| # | Task | Status |
|---|------|--------|
| 1 | Web page ingestion (readability parsing -> PDF or library entry) | ⬜ Not started |
| 2 | iPad app (Tauri mobile or React Native with shared logic) | ⬜ Not started |
| 3 | Multi-document library view | ⬜ Not started |
| 4 | Export annotations (Markdown, annotated PDF copy) | ⬜ Not started |
| 5 | iCloud/Dropbox sync of annotated PDFs | ⬜ Not started |

### Additionals

- Add OCR for document extraction

---

## Key Design Decisions

1. **Standard PDF workflow**: Open PDFs directly and keep original files readable in any viewer
2. **Optimistic UI**: Zustand updates instantly, PDF persistence runs async, rollback on failure
3. **Normalized coordinates**: Annotation positions stored at zoom=1.0, scaled on render
4. **Dual anchoring**: Rects for fast render + text offsets for re-anchoring resilience
5. **Store actions as API**: UI and AI share the same mutation interface
6. **Embedded annotations**: Standard PDF objects are the source of truth and travel with the file
7. **BYOK for AI**: No backend costs, user brings their own API keys
