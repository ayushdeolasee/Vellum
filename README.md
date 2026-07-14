# Vellum

Vellum is an AI-powered PDF reader for macOS, built with SwiftUI.

It supports:

- Smooth PDF viewing (scroll, zoom, navigation) via PDFKit
- Highlights, sticky notes, and an annotation sidebar — embedded as standard PDF annotation objects, no sidecar database
- Web reading mode
- AI chat panel with document-aware context and tool calling

## Requirements

- macOS 26.0+ (pre-release; the project's deployment target — see `project.yml`)
- A current Xcode beta with the macOS 26 SDK (Swift 6)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Development

```bash
# Regenerate the Xcode project after adding/removing files
xcodegen generate

# Build
xcodebuild -project Vellum.xcodeproj -scheme Vellum -configuration Debug build

# Test
xcodebuild -project Vellum.xcodeproj -scheme Vellum test
```

Or open `Vellum.xcodeproj` in Xcode and run the `Vellum` scheme.

## Layout

- `Vellum/` — app sources (App, Models, Services, Views, Resources)
- `Tests/` — unit tests
- `specs/` — feature specs
- `project.yml` — XcodeGen project definition
