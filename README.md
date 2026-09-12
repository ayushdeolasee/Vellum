# Vellum

Vellum is a SwiftUI reader for PDFs and web articles. It combines PDFKit reading and annotation, offline web archives, a per-document Scratchpad, and optional document-aware AI.

## Targets

- **iPhone and iPad:** this branch generates one universal iOS 26 app plus its Safari share extension.
- **macOS:** `main` generates the separate macOS app from the shared source tree.

The phone layout has a search-first Home, a full-screen reader, a pull-up inspector, and a card switcher for open documents. Continue Reading stores the last position for handoff, and read-later integrations can prefetch offline copies with retention rules.

Safari sharing writes a small capture record to the App Group. The app later creates the durable web archive; DOM payloads over the conservative 1 MiB limit fall back to fetching the shared URL.

## Chrome extension

The extension in `VellumChrome/` opens the current HTTP or HTTPS page in the macOS app. To install it locally, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select the `VellumChrome` folder. Pin **Open in Vellum** for one-click access.

## Current limits

- Local and custom-folder storage work in this build. The coordinated iCloud path is implemented, but its entitlement stays intentionally unwired until the production cutover in #149.
- Scratchpad notes and images use the same coordinated per-document storage as the rest of the reading data. They sync when the iCloud path and entitlement are enabled; local and custom modes keep them private on this device.
- This repository does not claim an App Store or production iCloud release yet.

## Requirements

- Xcode 27 with Swift 6; the universal app targets iOS 26
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Development

`project.yml` owns the generated Xcode project. Regenerate it after adding or removing files; do not edit `Vellum.xcodeproj` by hand.

```bash
xcodegen generate

# Universal iOS matrix
xcodebuild -project Vellum.xcodeproj -scheme Vellum \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project Vellum.xcodeproj -scheme Vellum \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' test
```

The same generated `Vellum` scheme and destinations work with Xcode build/test automation. Open `Vellum.xcodeproj` for interactive development. To build macOS, use a `main` worktree and regenerate its platform-specific project there.

## Layout

- `Vellum/` — shared app sources and platform adapters
- `VellumShare/` — iOS Safari share extension
- `VellumChrome/` — Chrome extension for the macOS app
- `Tests/` — unit tests
- `specs/` — feature specifications
- `project.yml` — XcodeGen source of truth for this branch
