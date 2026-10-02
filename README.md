# Vellum

Vellum is a SwiftUI reader for PDFs and web articles. It combines PDFKit reading and annotation, offline web archives, a per-document Scratchpad, and optional document-aware AI.

## Targets

- **iPhone and iPad:** the universal iOS 26 app includes Safari sharing and widgets.
- **macOS:** the same project generates separate direct-distribution and sandboxed Mac App Store targets for macOS 26.

The phone layout has a search-first Home, a full-screen reader, a pull-up inspector, and a card switcher for open documents. Continue Reading stores the last position for handoff, and read-later integrations can prefetch offline copies with retention rules.

Safari sharing writes a small capture record to the App Group. The app later creates the durable web archive; DOM payloads over the conservative 1 MiB limit fall back to fetching the shared URL.

## Chrome extension

The extension in `VellumChrome/` opens the current HTTP or HTTPS page in the macOS app. To install it locally, open `chrome://extensions`, enable Developer mode, choose **Load unpacked**, and select the `VellumChrome` folder. Pin **Open in Vellum** for one-click access. The distributed extension targets the production app (`vellum://`); Debug builds register only `vellum-dev://`.

## Current limits

- Local, custom-folder, and coordinated iCloud storage are implemented. `project.yml` wires iCloud entitlements for both main apps and App Groups for the mobile app/extensions. Portal profiles and signed cross-device behavior remain release gates in #149; source wiring alone does not verify them.
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

The generated `Vellum`, `Vellum Mac`, and `Vellum Mac App Store` schemes share this source tree. Use Debug configuration and an isolated derived-data directory per worktree and Mac distribution target. Launch development builds with `--disable-sync` for UI-only work.

## Release artifacts

[Store operations](Distribution/store-operations.html) documents the separate archive, local verification, Apple validation, and upload commands. Each artifact records its commit, explicit version/build, signed bundle identities, entitlements, architectures, privacy manifests, and matching symbols. Validation and upload reuse the exported package; no command pushes a version commit or releases the app. Signed device acceptance and App Store metadata remain separate gates.

## Layout

- `Vellum/` — shared app sources and platform adapters
- `VellumShare/` — iOS Safari share extension
- `VellumChrome/` — Chrome extension for the macOS app
- `Tests/` — unit tests
- `specs/` — feature specifications
- `project.yml` — XcodeGen source of truth for this branch
