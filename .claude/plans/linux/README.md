# Vellum for Linux — planning map

This folder is the planning stack for the Linux port. Each file is owned by one
layer of the stacked planning PRs; this README is the index (wayfinder-style:
it gists decisions and points at the file that holds the detail).

| Layer | File | Decides |
|---|---|---|
| 1 | `README.md` | Destination, decisions so far, open questions, scope |
| 2 | `01-shared-library.md` | Where the shared library lives, how Mac + Linux sync it, the on-disk format contract |
| 3 | `02-pdf-engine.md` | Which PDF engine replaces PDFKit on Linux, and the licence it implies |
| 4 | `03-core-and-shell.md` | `VellumCore` SwiftPM extraction, `Linux/` shell layout, GTK + `@MainActor`, container dev loop |
| 5 | `04-ink.md` | How ink reaches Linux, step by step |

## Destination

An **implementation-ready spec** for a personal-use Linux Vellum: a native GTK
app on a shared Swift core, reading and writing the **same library** as the Mac,
developed and tested in a Linux container on the Mac. Designed so a later public
release does not need a rewrite.

The map is done when nothing is left to decide before someone starts building.

## Notes

- Domain: macOS app on `main` (this repo). iPhone/iPad code is not ported.
- Agents consulted while charting: Gemini 4 Neon and GPT 6.2 Astra (round 1 research, round 2 review, round 3 work items).
- Standing preferences: native feel over convenience; personal use first, public later;
  every step must keep the Mac app building and behaving the same.
- `project.yml` stays the source of truth for Apple targets. Linux builds with SwiftPM.

## Decisions so far

- **D1 Destination** — Personal use first; public release later.
- **D2 Why Tauri was dropped** — For a more native experience. Tauri, pdf.js-in-a-webview and other web-UI shells are ruled out.
- **D3 Shared library** — Mac and Linux read and write the same library files.
- **D4 UI stack** — Shared Swift core + native GTK4 shell, living in a `Linux/` folder in this repo.
- **D5 Test environment** — A Linux container on the Mac (arm64). The two VMs are not used for this.
- **D7 Ink** — Ink must show up on Linux eventually; not in the first build; added step by step (`04-ink.md`).
- **D9 Distribution** — Deferred; out of scope for this map.

## Facts that shape the map

- **About half the Mac app is portable logic.** 113 non-iOS files (~37K lines) import no UI, PDF, web or ink framework. Roughly the same amount is tied to SwiftUI/AppKit/PDFKit/WebKit/PencilKit and must be rebuilt for Linux.
- **Vellum started as Tauri** (React + Rust) and moved to Swift in July 2026 (`cd95f534`). Several Swift files still say "port of `src-tauri/…rs`"; `.vellumweb` is a format born in Rust and is already portable.
- **PDF ink is mostly portable.** iPad ink on PDFs is saved as standard `/Ink` annotations (`/InkList` geometry, no appearance stream), plus an Apple-only `PKDrawing` copy in `/VellumInk`. A Linux engine can draw the geometry, not the brush look.
- **Web-page ink is not portable.** `<key>.ink.json` wraps opaque `PKDrawing` blobs (`WebInkStore.swift:92`).
- **Only iPad writes ink.** The Mac displays ink read-only, so ink-format changes start on iPad.
- **Page annotations are written by PDFKit, not by Vellum's own code.** Vellum's pure-Swift PDF code writes document metadata and bookmarks and patches PDFKit's output. Linux needs a new annotation writer (`02-pdf-engine.md`).
- **Custom-folder storage doesn't share notes or positions today.** Only iCloud mode keeps them in the library folder (`01-shared-library.md`).
- **The repo is public with no licence.** The PDF engine's licence constrains Vellum's eventual licence.
- **No container runtime is installed on the Mac yet.**

## Open questions (frontier)

- **N1 Licence** — What licence will Vellum have when public? The work items assume PDFium (fits any licence); only switching to MuPDF depends on this (`02-pdf-engine.md`).
- **N2 Library location** — The work items assume Syncthing. Blocks M3, not M0–M2 (`01-shared-library.md`).
- **N3 Container runtime** — the work items assume **colima** (Astra's scripts use `docker --context colima`); OrbStack also works with a one-line change (`03-core-and-shell.md`). Blocks C0.
- **N7 v1 feature list** — Proposed below; tabs/panes, read-later integrations and capture are undecided.

### Proposed v1 feature list (N7)

In: library + home search · PDF reading, highlights, notes, *viewing* PDF ink ·
offline web reader · scratchpad · AI chat · continue-reading positions.

Undecided: tabs and split panes · Raindrop/Readwise integrations · Chrome-extension capture via `vellum://`.

## Build order (agreed after review)

Read first, write later: (1) shared formats move into `VellumCore` → (2) a **read-only** Linux
reader on a disposable copy of the library, verified to write nothing → (3) shared-folder storage
mode and conflict handling → (4) Linux PDF annotation writer → (5) ink. Two machines writing to one
library is only allowed after a two-machine offline-edit conflict test passes.

## Milestones (round 3: every work item, rolled up)

Every layer now has numbered work items with files, code sketches, tests, acceptance criteria and sizes.
IDs: `C*` core + Linux app (`03-core-and-shell.md`), `S*` shared library (`01`), `P*` PDF (`02`), `I*` ink (`04`).
Effort is in **agent-days** (one agent session ≈ S 0.5 · M 1 · L 2.5). It's a rough planning number,
not a promise.

| # | Milestone | Items | Effort | Done when |
|---|---|---|---|---|
| M0 | Foundations | C0, C1, P7, I0 | ~2 | Container builds; `VellumCore` exists and the Mac + iOS Debug builds pass; fixtures committed |
| M1 | Shared formats in `VellumCore` | C2, C3, C4 | ~6 | Same hashes, positions and `.vellumweb` bytes read identically on Mac and Linux |
| M2 | **Read-only Linux reader** | C5a, P1, C5b, I1, C5c, I2 | ~6.5 | GTK window shows library, PDF pages (with iPad ink) and an offline article; library checksum unchanged |
| M3 | Shared library sync | S1–S9 | ~10.5 | Mac and Linux share one Syncthing folder; two-peer offline conflict test recovers everything |
| M4 | Linux edits PDFs | P4/C6, P3/C7a, P2, P5/C7b, P6 | ~10.5 | Linux highlights and notes read back identically on the Mac, including on xref-stream PDFs |
| M5 | Portable ink | I3–I8 | ~5.5 | iPad writes portable strokes; Linux shows web ink |
| M6 | Linux draws ink | I9–I12 | ~5 | Mixed-version iPad + Mac + Linux round trip loses nothing |
| — | Network seams | C8 | ~2 | Streaming AI and libsecret credentials work on Linux |
| — | Linux app screens (not itemized yet, see fog) | — | ~10 (guess) | Library/search UI, highlight + note UI, scratchpad, AI chat, settings |

**Personal-use v1 = M0–M4 + C8 + the app screens + I1/I2 ≈ 48 agent-days.** M5–M6 follow.
P6 (xref streams) stays in v1 because many modern PDFs use them; without it Linux could annotate only some files.

**Critical path:** C0 → C1 → C2 → C3/C4 → C5b → C6 → C7a → C7b. Track S (shared library) runs in parallel from
C1, and must finish before Linux may write to a library that the Mac also writes.

**Parallel tracks after M0:**
- Track A: C2 → C3/C4 → C5a/C5b/C5c (Linux reader)
- Track B: S2, S3, then S1 → S4/S5 → S6/S7 → S8 → S9 (mostly Mac-side work)
- Track C: I3 → I4 → I5/I6 → I7 (iPad-side ink work, independent of Linux)

## Not yet specified (fog)

- **Linux app screens beyond the reader**, to be itemized after C5b shows what the thin C adapter costs
  per screen: library + home search UI (reusing `HomeSearchRanker`), highlight/note creation UI, scratchpad editor,
  AI chat panel (needs C8), settings (storage folder, API keys), and continue-reading writes.

- How the agent verifies Linux UI (headless Wayland + screenshots, or an AT-SPI driver).
- API keys per device via libsecret, or synced.
- Single-instance `vellum://` hand-off on Linux (D-Bus activation).
- Look and feel: libadwaita vs plain GTK4 next to Omarchy/Hyprland tiling (needs the GTK spike first).
- How Vellum's web-reader scripts (highlight anchoring, offline asset serving, page-to-app messages) map onto WebKitGTK 6, and whether web capture is in v1.

## Out of scope

- Distribution and updates (D9) · iCloud on Linux · widgets, Shortcuts, Quick Look, Live Text,
  dictation, dictionary lookup · Windows · web-UI shells (D2).
