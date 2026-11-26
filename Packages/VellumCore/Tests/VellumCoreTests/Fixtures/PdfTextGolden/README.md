# PDFKit text goldens

The macOS `PdfTextComparisonHarnessTests` generates these files from private
PDFKit documents loaded from the bundled, synthetic `Pdf` corpus. The JSON
retains exact extracted text, UTF-16 ranges, PDFKit selection strings, zoom-1
rectangles, and resize points and outcomes. Each entry includes the SHA-256 of
its source PDF. Linux extracts from its own copy of those bytes with PDFium and
uses the JSON only as expected data.

To regenerate on macOS, use an empty output directory and isolated Debug
derived data:

```sh
output=$(mktemp -d)
derived=$(mktemp -d)
TEST_RUNNER_VELLUM_PDF_TEXT_GOLDEN_OUTPUT="$output" \
  xcodebuild -project Vellum.xcodeproj -scheme 'Vellum Mac' -configuration Debug \
  -derivedDataPath "$derived" -only-testing:VellumMacTests/PdfTextComparisonHarnessTests test
```

The generator writes the reproducible `text-selection-edge-cases.pdf` to
that directory too. Its source is in the harness and is dedicated to the
public domain (CC0). Copy that PDF into `Fixtures/Pdf` and the JSON files into
this directory, then rerun without the environment variable to verify the
bundled references. Runtime PDFKit changes can affect reference results, so
review the JSON differences before replacing them.

```sh
DOCKER_CONTEXT=colima-vellum VELLUM_BUILD_VOLUME=vellum-p2-local \
  Linux/scripts/dev-shell.sh swift test --package-path Linux --scratch-path /build/p2 \
  -c debug -j 2 --filter comparesPdfKitGoldens
```

The comparison reports verbatim page and selection strings, UTF-16 ranges,
text-order similarity ignoring only whitespace, and direct rectangle overlap
(IoU) and largest edge delta. The reference is expected to match exactly in
crop and rotation. The known different results are asserted separately:
PDFKit uses spaces at some column boundaries and can include a trailing
separator in its reported range without including it in the selection
string. The Linux check reports selection-box midpoint differences after
confirming the target and the one-caret separation of the results.

`BeforeApplePinnedEdgeFix/rotated-drag-results.json` contains the untouched
PDFKit resize points and results from before the Apple anchor correction,
captured on macOS 27.0.1. The previous implementation used the horizontal
display edges even when the reading axis was rotated. The current harness
checks the opposite endpoint in native page coordinates at all four
rotations and probes on both sides of the midpoint.


## Caret boundaries

A PDFKit sweep in native coordinates used both dragged edges, same-line
and wrapped selections, and all four display rotations. Immediately before
the hit boundary PDFKit chose the leading caret, and at and immediately
after it chose the higher native-x caret. For the probes where PDFKit
exposed the corresponding character ink bounds, the switch was at their
midpoint. A synthetic Hebrew line also chose higher native x at the ink
midpoint from both sides. Subtracting and adding the crop origin in a
rotated transform could round a nominal tie to the leading side.

PDFium's reconstructed caret stops use advance bounds. An exact tie or
one Double ULP of reconstructed coordinate round-off now resolves toward
the following caret in the portable reader's native left-to-right order.
The four rotated `e` probes fall between cutoffs about 0.05355–0.05356 pt
apart, and the wrapped `e` falls between cutoffs 0.16294 pt apart.
For those five glyphs, PDFium's ink and advance midpoints coincide.

For a precision counterexample, put the following streams into separate
otherwise identical PDFs. Use a 612 × 792 page and Base-14 Helvetica with
WinAnsiEncoding for `F1`.

```pdf
BT /F1 14 Tf 499.999985 700 Td (ABeCD) Tj ET
BT /F1 14 Tf 500.000015 700 Td (ABeCD) Tj ET
```

PDFium 8179 returned identical text, tight and loose boxes, origins,
matrices, and the same glyph hit for both. PDFKit on macOS 27.0.1 moved
the ink cutoff from x=522.553110 to x=522.553140. At x=522.553125 on the
glyph's vertical centre, Apple end drags selected `ABe` and `AB`,
respectively, and start drags selected `CD` and `eCD`. The PDFium geometry
cannot distinguish the Apple outcomes anywhere in the 0.000030 pt
interval between those cutoffs.
