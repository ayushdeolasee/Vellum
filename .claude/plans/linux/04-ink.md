# Layer 5 — Ink on Linux, step by step

Decides: how handwriting made on iPad shows up on Linux, and when Linux can draw,
without ever losing or resurrecting anyone's ink.

Depends on: D7 (ink shows up eventually, not in the first build), layer 2 (format contract,
especially "never drop unknown fields"), layer 3 (PDF engine and ink-page rules).
Reviewed by Gemini 4 Neon and GPT 6.2 Astra (round 2).

## Question

Ink exists in two places with different portability, and only iPad writes it. In what order
do we make it visible, then editable, on Linux, with every Apple version still safe?

## What exists today

| | Stored as | Who writes | Portable? |
|---|---|---|---|
| Ink on **PDFs** | Standard `/Ink` annotations: `/InkList`, `/C`, `/BS`, **no `/CA`**, **no `/AP`**. The whole page's `PKDrawing` sits in `/VellumInk` on the **first** ink annotation; the others carry `"1"` markers (`Platform/iOS/PdfInk.swift`) | **iPad only** (`#if os(iOS)`) | Geometry yes; the brush look, pressure and erasures live only in `/VellumInk` |
| Ink on **web pages** | `<key>.ink.json`: JSON wrapper (version, url, layout, clusters with bounds and text anchors); each cluster's required `drawing` field is a base64 **`PKDrawing`** (`WebInkStore.swift:92-118`) | **iPad only**; the Mac shows saved ink read-only (`WebSavedInk_macOS.swift`) | No |

Merge rules today (must be preserved by any new format):
- Live saves merge against a **baseline**, so an erasure stays erased (`WebInkStore` live merge).
- Archive import merges additively by stable **stroke identity** using the **record** timestamp
  (`additivelyMerged`). Stroke identity = creation date + points + time offsets.
- Strokes have **masked ranges** (`maskedPathRanges`): partially erased strokes keep their points
  but hide parts of them.

`ScratchOutRecognizer` is not PencilKit-bound (CoreGraphics + Foundation on point arrays);
only its iOS adapter touches `PKStroke`.

## Steps

### Step 1: v1, view PDF ink on Linux (no ink-format change)
PDFium draws `/Ink` from `/InkList` at render time (layer 3). Read-only.
- Uniform-width strokes: `/InkList` has no pressure. Marker strokes have no `/CA`, so they may
  render opaque. The layer-3 spike checks how they look.
- Never save a PDFium document after rendering. All saves go through the Swift writer on the
  original bytes.
- Web-page ink is **not** shown in v1. Linux shows a quiet "has handwriting (view on iPad/Mac)" badge.

### Step 2: Apple apps learn to *read* portable strokes (iPad + Mac, no writes yet)
Before any device writes the new format, every Apple app must tolerate it:
- **Unknown-field preservation** on `WebInkRecord` and the PDF ink path (layer 2, contract rule 1).
- A cluster may carry `strokes`, and `drawing` becomes **optional**. When `drawing` is absent,
  build a `PKDrawing` from `strokes`.
- Without this, a strokes-only file makes `loadRecord` return nil. iPad's next save then treats
  the page as empty and **overwrites it, deleting the other device's ink**.

### Step 3: iPad dual-writes portable strokes
iPad keeps writing `drawing` (Apple source of truth) and **also** writes `strokes`:

```json
"strokes": [{
  "id": "<stable stroke identity>",
  "ink": "pen",                          // PKInk.InkType raw value
  "color": [r, g, b, a],                 // sRGB
  "transform": [a, b, c, d, tx, ty],
  "created_at": "RFC3339",
  "visible_ranges": [[0.0, 12.5]],       // maskedPathRanges: keeps erasures erased
  "points": [{"x":0,"y":0,"t":0.0,"size":[w,h],"opacity":1,"force":1,"azimuth":0,"altitude":1.57}]
}]
```

- PDFs: a portable sibling of `/VellumInk` on the same first-annotation rule, plus iPad starts
  writing `/CA` on marker strokes (so any engine draws them translucent).
- **Backfill** is an explicit operation, not "open once". The Mac never writes ink, so backfill runs
  on iPad when a page is saved, or as a one-off migration command. Pages never re-saved stay
  non-portable and show the badge.
- File size roughly doubles for heavily inked pages. Measure before shipping.

### Step 4: Linux shows web ink (read-only)
Linux reads `strokes`, honours `visible_ranges`, and draws them with Cairo/GSK over the
WebKitGTK page in the same zoom-1 CSS-pixel space, reusing the existing anchors for reflow.

### Step 5: Linux draws
Gate: steps 2–3 shipped on every Apple device you use, and a **mixed-version round trip** passes.
iPad + Mac + Linux edit the same page (including an erasure), and nothing is lost or resurrected.
- Input: GTK4 `GtkGestureStylus` (pressure, tilt) on Wayland.
- Web pages: Linux writes `strokes` only. Merge by stable stroke id, with deletions expressed as
  tombstones or baseline diffs (the rule must be written down before this step starts).
- PDFs: new `/Ink` annotations through the Swift writer (layer 3). Linux must not move, delete or
  reorder the annotation holding `/VellumInk`. Apple apps must reconcile Linux-added `/Ink`
  annotations with the page's `PKDrawing`, and leave unrelated third-party ink alone.
- Eraser and scratch-out on Linux: decided at this step (`ScratchOutRecognizer` is reusable).

## Risks

- **Two sources of truth** (`drawing` vs `strokes`) once Linux writes. Hence the strict gate on step 5.
- **Fidelity**: Linux strokes won't match PencilKit's brush rendering. Fine for viewing.
- **Old Apple builds** still installed somewhere can drop `strokes`. Contract rule 1 must ship
  everywhere before step 3.

## Open questions

- **N10**: Start steps 2–3 soon (iPad work, independent of Linux) so less non-portable ink piles up?
  Recommendation: step 2 soon, step 3 right after.
- Is drawing on Linux a real use case (do you have a pen tablet there), or is view-only the
  long-term goal? If view-only, step 5 moves out of scope.
