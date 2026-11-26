# iPad ink fixtures

The five PDFs here and the two JSON files in [Web](../Web/) were produced by Vellum Debug 0.1.1 (2) at commit `4909b48690a378d88fcd595f69544a1868f4570a`, with Xcode 27.2 (27B52) on an iPad Pro 13-inch (M5) simulator running iPadOS 26.5 (23F77). The source page, paths, masks and HTML are self-authored test data, dedicated to the public domain under [CC0](https://creativecommons.org/publicdomain/zero/1.0/).

The temporary export harness adds two tests to that app revision. The files below were exported on November 26, 2026 and copied unchanged from simulator test storage. [PDF generator](https://github.com/ayushdeolasee/Vellum/blob/c1cd313fb48b7529eb4da100be6ddffb9e60256b/Tests/InkPersistenceTests.swift#L573) · [Web generator](https://github.com/ayushdeolasee/Vellum/blob/c1cd313fb48b7529eb4da100be6ddffb9e60256b/Tests/WebInkAnchorTests.swift#L542)

## PDF source and save path

A hosted XCTest created a 320 × 240 pt white PDF with three gray vertical bars at x = 80, 140 and 200 (8 pt wide, from y = 32 to 182 in UIKit coordinates). These bars make overlap and page orientation visible. The harness supplied PencilKit control points to Vellum's regular pen and highlighter tools from `InkToolState.pkTool`. For each stroke, the nine x coordinates were `48 + 24i`, with time offsets `i / 100` seconds, unit force and opacity, zero azimuth, and altitude π/2. Each point's width and height were twice the tool width. The first y coordinate supplied the stroke's creation time in seconds after the Unix epoch and its random seed.

The harness called Vellum’s iPad `PdfInk.apply(_:to:)` on page 1, serialized the document with `PDFDocument.dataRepresentation()`, then reopened the file and decoded the embedded drawing with `PdfInk.drawing(on:)`. Each erasure began by saving two visible strokes. The harness reopened that PDF and applied a second drawing with a mask on the indigo stroke.

The fixtures capture the PDFKit serialization stage of the app’s save path. A separate run through the full `InkDiskWriter` on this OS also appended an empty xref subsection during metadata restoration. qpdf’s strict reader rejected that later revision. All five committed exports pass qpdf syntax checks with recovery disabled.

| File | Input in drawing coordinates | Native ink to expect after reopening |
| --- | --- | --- |
| `ipad-vellum-ink.pdf` | Indigo pen at y = 80 + 2i and red pen at y = 155 − 2i, following an existing black PDFKit ink mark. | Three annotations in page order. The black mark has no Vellum key. The indigo annotation carries the drawing for both visible strokes. The red annotation carries the string `"1"`. This is also P7's basic pen fixture. |
| `pdf-ink-marker.pdf` | Two strokes from the default highlighter palette, one at y = 90 and one at y = 70 + 5i. | Two 12 pt yellow annotations, each with a normal appearance stream (`/AP /N`) and no `/CA`. At 72 dpi Poppler renders the stroke as RGB (254, 240, 138) over both white and gray. The strokes are opaque at the crossing. |
| `pdf-ink-erased-full.pdf` | Indigo path at y = 90 masked to a 5 × 5 rectangle at (500, 500). Red control at y = 155 − 2i. | The embedded drawing retains both strokes. The indigo stroke has zero visible ranges. Only the red control emits a native annotation, which carries the drawing. |
| `pdf-ink-erased-partial.pdf` | Same indigo and red paths. The indigo mask retains x = 0…110 and 185…320 across the page height. | The embedded drawing retains two visible strokes. PencilKit reports indigo parameter ranges 0…2.5833 and 5.7083…8. Its native `/InkList` still runs continuously from x = 48 to 240, crossing the erased gap. Red carries the `"1"` marker. |
| `pdf-ink-rotated.pdf` | One indigo pen at y = 80 + 2i on a page rotated 90° before saving. | The unrotated PDF path runs from (48, 160) to (240, 144). On the rotated 240 × 320 display it runs almost vertically from (160, 48) to (144, 240) through horizontal gray bars. |

PDFKit emitted `/AP /N` on every ink annotation in these files, including the foreign mark. Its appearance streams and `/InkList` geometry are both available to readers.

## Web source and save path

The page is the local HTML from `WebInkAnchorScriptTests.loadFixture()` in `Tests/WebInkAnchorTests.swift` at the source commit above. Its base URL is `https://fixture.test/article`. The harness loaded the HTML directly into an 800 × 1000 pt WKWebView and used Vellum's injected content script to measure paragraph 2 and capture an `anchor-at-point` quote. It placed a black nine-point underline at x = paragraph left + 8…104, y = paragraph top + 18. The stroke has 4 × 4 pt input points, a creation time of 200 seconds after the Unix epoch and random seed 200.

`WebInkPersister.drawingChanged` took the drawing, anchor and measured layout, then `flushPendingInkAndWait()` drained the sidecar write and the first-stroke promotion of the page to the saved library. `WebLibrary.storeDirOverride` pointed to temporary hosted-test storage. The two files are unchanged copies of the resulting `<pageKey>.ink.json` and `<pageKey>.json`, renamed for fixture lookup. Both records use the same URL. The saved layout is 800 × 1000 CSS px. Its one v3 cluster carries a base64 PencilKit drawing in cluster-local coordinates and a paragraph-2 anchor at offsets 210…370. `validatedMergedDrawing()` restores the underline to (29, 175) in document coordinates.

## Scope

These fixtures exercise PencilKit masking and serialization, app persistence, WebKit text anchoring and PDF reader behavior with scripted input. Physical Apple Pencil sampling, brush dynamics, eraser gesture recognition and on-device placement require separate hardware testing.
