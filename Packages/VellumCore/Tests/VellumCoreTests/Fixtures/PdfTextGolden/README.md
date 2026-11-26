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
string. The engines resolve some glyph-midpoint ties differently. The Linux check
reports those cases only after confirming the target is at the midpoint
and the selected ranges differ by one adjacent caret stop.

`BeforeApplePinnedEdgeFix/rotated-drag-results.json` contains the untouched
PDFKit resize points and results from before the Apple anchor correction,
captured on macOS 27.0.1. The previous implementation used the horizontal
display edges even when the reading axis was rotated. The current harness
checks the opposite endpoint in native page coordinates at all four
rotations and probes on both sides of the midpoint.
