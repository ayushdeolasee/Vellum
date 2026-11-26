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
- Agents consulted while charting: Gemini 4 Neon and GPT 6.2 Astra (research round 1, review round 2).
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

- **N1 Licence** — What licence will Vellum have when public? Blocks the PDF engine choice (`02-pdf-engine.md`).
- **N2 Library location** — Which folder-sync tool carries the shared library (`01-shared-library.md`).
- **N3 Container runtime** — OrbStack, Docker Desktop, colima or Apple `container` (`03-core-and-shell.md`).
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

## Not yet specified (fog)

- How the agent verifies Linux UI (headless Wayland + screenshots, or an AT-SPI driver).
- API keys per device via libsecret, or synced.
- Single-instance `vellum://` hand-off on Linux (D-Bus activation).
- Look and feel: libadwaita vs plain GTK4 next to Omarchy/Hyprland tiling (needs the GTK spike first).
- How Vellum's web-reader scripts (highlight anchoring, offline asset serving, page-to-app messages) map onto WebKitGTK 6, and whether web capture is in v1.

## Out of scope

- Distribution and updates (D9) · iCloud on Linux · widgets, Shortcuts, Quick Look, Live Text,
  dictation, dictionary lookup · Windows · web-UI shells (D2).
