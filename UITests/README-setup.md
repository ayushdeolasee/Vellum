# Scratchpad UI test — one-time target setup

`ScratchpadSnapshotUITests.swift` drives the region-snapshot crop with a real
drag event. A UI test **must** live in its own UI-testing bundle target — it
can't run in `VellumTests` (that's an in-process unit-test bundle). The target
isn't checked in because adding it means editing the hand-maintained
`Vellum.xcodeproj`, which is safest done through Xcode's generator rather than
by hand. It's a ~20-second step:

1. **File → New → Target… → macOS → UI Testing Bundle.**
2. Name it `VellumUITests`; set **Target to be Tested = Vellum**. Finish.
3. Xcode creates a `VellumUITests/` group with a sample file. **Delete the
   sample**, then drag `UITests/ScratchpadSnapshotUITests.swift` into the new
   target (check "VellumUITests" in the file inspector's Target Membership).
4. In the file, set:
   - `VELLUM_TEST_PDF` (env var, or edit the fallback path) → a small real PDF.
   - `appBundleID` → the Vellum target's `PRODUCT_BUNDLE_IDENTIFIER`
     (Build Settings; the code defaults to `com.vellum.app`).

## Run

```
xcodebuild test -project Vellum.xcodeproj -scheme Vellum \
  -destination 'platform=macOS' \
  -only-testing:VellumUITests/ScratchpadSnapshotUITests
```

(Add `VellumUITests` to the Vellum scheme's Test action if it isn't picked up.)

## What it asserts

Opens the PDF → Scratchpad tab → arms `scratchpad.snapshotRegion` → drags a
rectangle over the page → asserts a new file appears in the app's
`scratchpad-attachments` directory (i.e. the crop was captured and the note now
references it). The filesystem assertion is robust; the open-panel drive can be
flaky on macOS (cross-process panel) — if so, swap in your preferred way to get
a document open.

The crop also works on **web documents** (the button is shown for both PDF and
web now); the web path snapshots the WKWebView region via `takeSnapshot`. This
test opens a PDF, but the same flow applies to a web tab.

## Not covered

External image **drag-and-drop** — XCUITest can't originate a Finder-style file
drop. That path stays a manual check (drag an image file onto the Scratchpad
panel; it should appear inline). The encoding it relies on is unit-tested in
`VellumTests/ScratchpadImportTests` (`testCapture*`).
