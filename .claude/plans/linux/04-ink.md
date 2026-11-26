# Layer 5 — Ink on Linux, step by step

Decides: how handwriting made on iPad/Mac shows up on Linux, and when Linux can draw.

Depends on: D7 (ink must show up eventually, not in the first build), layer 2
(format contract), layer 3 (PDF engine).

## Question

Ink exists in two places with very different portability. What order do we make it
visible, then editable, on Linux, without risking existing ink?

## What exists today

| Where | Stored as | Portable? |
|---|---|---|
| Ink on **PDFs** | Standard PDF `/Ink` annotations (`/InkList`, `/C`, `/CA`, `/BS`) with **no `/AP` appearance stream**, plus the full `PKDrawing` in a custom `/VellumInk` key (`Platform/iOS/PdfInk.swift`) | **Mostly.** The `/InkList` geometry is standard; `/VellumInk` is Apple-only and must survive Linux saves untouched |
| Ink on **web pages** | `<key>.ink.json` sidecar: JSON wrapper (version, url, layout, clusters with bounds and text anchors), but each cluster's `drawing` field is a base64 **`PKDrawing`** blob (`WebInkStore.swift:92-107`) | **No.** `PKDrawing` is Apple's private binary format |

Other ink-adjacent Apple dependencies: `ScratchOutRecognizer` (gesture recognition on
`PKStroke`) and `WebInkClustering` (groups strokes into clusters with PencilKit types).

## Steps

### Step 1: v1, view PDF ink (no new work beyond the PDF engine)
Linux renders `/Ink` annotations through PDFium (layer 3). Read-only.
Vellum writes no `/AP` stream, so PDFium synthesises one from `/InkList` at render time.
Caveat: that synthesis strips `/C`/`/IC` from PDFium's in-memory copy. Read the colour
before rendering, and never save a PDFium document after rendering (all saves go through
the Swift writer on the original bytes). `/InkList` has no pressure, so Linux shows
uniform-width strokes; PencilKit's brush look is lost until step 3 below.
The layer-3 spike checks colour and placement on a real iPad-inked PDF.

### Step 2: the Mac starts writing portable stroke data (Mac/iPad change)
Applies to both web ink (`ink.json` clusters) and PDF ink (a portable sibling of `/VellumInk`).
Add a `strokes` array next to `drawing` in each cluster. These are plain stroke records
`PKStroke` already exposes (`WebInkStore.strokeSignature`):

```json
"strokes": [{
  "ink": "pen",               // PKInk.InkType raw value
  "color": [r, g, b, a],      // sRGB components
  "transform": [a, b, c, d, tx, ty],
  "created_at": "RFC3339",
  "points": [{"x":0,"y":0,"t":0.0,"size":[w,h],"opacity":1,"force":1,"azimuth":0,"altitude":1.57}]
}]
```

- The Mac keeps `drawing` as the source of truth for Apple devices and **dual-writes** `strokes`.
- Format version stays additive; readers that don't know `strokes` ignore it.
  Layer 2's rule 1 (never drop unknown fields) protects it.
- Starting this early is the point: every page inked from now on is already portable.
- Back-fill: when the Mac opens an old ink file, it fills in `strokes` on the next save.

### Step 3: Linux shows web ink (read-only)
Linux reads `strokes`, draws them with Cairo/GSK over the WebKitGTK page in the same
zoom-1 CSS-pixel document space, and reuses the existing anchors for reflow.
Files without `strokes` show a quiet "ink from an older version: open once on Mac" badge.

### Step 4: draw on Linux
- Input: GTK4 `GtkGestureStylus` gives pressure and tilt from Wacom-style tablets on Wayland.
- PDFs: write new `/Ink` annotations (plus portable strokes) through the shared Swift writer.
  The Mac must accept PDF ink that has no `/VellumInk` and rebuild a `PKDrawing` from it.
- Web pages: write `strokes` only. The Mac must then accept clusters that have
  `strokes` but no `drawing` and build a `PKDrawing` from them. This is the step that
  makes `strokes` a second source of truth, so it needs a merge rule
  (proposed: newest-wins per stable stroke id, as `additivelyMerged` does today).
- Eraser and scratch-out on Linux: decide at this step; not needed earlier.

## Risks

- **Fidelity.** A Linux-rendered pen stroke will not look identical to PencilKit's
  brush rendering. Acceptable for viewing; decide how close is "close enough" at step 3.
- **Two sources of truth** after step 4 (`drawing` vs `strokes`). The merge rule must be
  specified before Linux writes anything.
- **File size.** Point arrays roughly double `ink.json`. Probably fine; measure on a
  heavily inked page.

## Open questions

- **N10** — Start step 2 now (before Linux exists), or after the first Linux build?
  Recommendation: now. It is a small Mac-only change, and it stops non-portable ink accumulating.
- Is pen input on Linux a real use case for you (do you have a tablet on the Linux machine),
  or is "view only" the long-term goal?
