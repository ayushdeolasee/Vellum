# Vellum for iPad — Port Plan

Goal: a touch-first iPad edition of Vellum with **all** macOS functionality (PDF
reading + embedded highlight/note/bookmark annotations, web reading mode, AI chat
panel with tool calling, tabs, settings, theming) **plus** the headline
differentiator — **Apple Pencil handwritten annotations**. Same "Scriptorium"
design identity as macOS, heavy use of Liquid Glass, redesigned for touch.

## Architecture decision

- This worktree/branch (`ipad-app`) is the **iPad app**. The macOS app lives on
  `main`. The Xcode project here targets **iOS 26.0** (built with the iOS 27 SDK,
  so full Liquid Glass). No macOS app target in this project.
- **Maximize reuse.** The shared layer — `Models/`, `Stores/`, `Services/`,
  `Views/Shared/Theme.swift`, `Views/Shared/Controls.swift` — is made
  cross-platform and reused verbatim. It was already ~99% portable; the only
  AppKit coupling was `PdfAnnotationCodec.swift` (NSColor) and `ThemeStore`
  (NSApp appearance).
- **Existing macOS UI files stay in the tree, wrapped in `#if os(macOS)`.** They
  compile to nothing on iOS but remain as living reference for behavior parity
  and keep a future multiplatform merge clean. New iOS UI lives alongside,
  gated `#if os(iOS)` where it declares representables/app-entry that would
  otherwise collide with the macOS symbols.
- Platform shims live in `Views/Shared/Platform.swift` (PlatformColor,
  PlatformImage, pasteboard, etc.).

## Shared layer (cross-platform, reused as-is)

`Models/Models.swift`, all `Stores/*`, all `Services/*` (Pdf persistence, Web,
AI, Speech, RecentFiles, DocumentSessionManager, SessionService).
Made cross-platform: `Services/Pdf/PdfAnnotationCodec.swift` (NSColor→
PlatformColor / CGColor), `Stores`/`ThemeStore` appearance observation
(NSApp→UITraitCollection on iOS).

## iOS UI (new, touch-first)

| Concern | macOS (reference) | iPad |
|---|---|---|
| App entry | `App/VellumApp.swift` (Window, NSAppDelegate) | `Platform/iOS/VellumApp_iOS.swift` (WindowGroup, ScenePhase autosave) |
| Shell | `App/ContentView.swift` (inspector + NSEvent monitors) | `Platform/iOS/ContentView_iOS.swift` (adaptive sidebar, no key monitors — hardware-keyboard shortcuts via `.keyboardShortcut`/`commands`) |
| Commands | `App/VellumCommands.swift` | iOS `.commands` (hardware keyboard) + touch controls |
| PDF viewer | `Views/PDF/PdfKitView.swift` (NSViewRepresentable + NSEvent) | `Platform/iOS/PdfKitView_iOS.swift` (UIViewRepresentable PDFView + UIGestureRecognizers) |
| Selection/highlight/note | mouse monitors + overlays | long-press selection, touch popovers, tap-to-place note |
| **Pencil ink** | — | `Platform/iOS/InkCanvas.swift` (PKCanvasView per page) + ink→PDF annotation persistence |
| Toolbar | `Views/PDF/ToolbarView.swift` (NSToolbar) | iOS `.toolbar` with Liquid Glass pods, big tap targets |
| Tabs | `Views/PDF/TabBarView.swift` | touch tab strip |
| Sidebar | `.inspector` | adaptive: inspector on wide, sheet on compact |
| Web | `Views/Web/WebViewerView.swift` (NSViewRepresentable) | UIViewRepresentable WKWebView |
| AI panel / Settings / Welcome / Annotations sidebar | mostly SwiftUI | reuse with touch tweaks + `#if` for pasteboard/image |

## Apple Pencil annotations — design (the differentiator)

- **Per-page `PKCanvasView` overlay** aligned to each visible `PDFPage` inside
  the `PDFView`. Transform tracks page position/zoom so ink stays pinned.
- **Tool palette** (custom, Liquid Glass — not the stock `PKToolPicker`, to match
  Scriptorium): pen / highlighter / eraser, Scriptorium color set, width steps.
  Pencil double-tap toggles eraser/last tool.
- **Input policy:** `drawingPolicy = .pencilOnly` by default (finger pans/zooms
  the PDF; pencil draws) with a toggle to allow finger drawing. Palm rejection is
  automatic with PencilKit.
- **Persistence — embed in the PDF** to match the app's "annotations live in the
  PDF" philosophy: convert each page's `PKDrawing` strokes into PDF **ink
  annotations** (`/Subtype /Ink`, `/InkList`, color, border width) written via
  the existing `PdfAtomicWriter` path, and reload them back into `PKDrawing` on
  open. This keeps files round-trippable and interoperable. (Fallback if fidelity
  loss is unacceptable: store the raw `PKDrawing` data in a custom annotation key
  alongside a rendered ink appearance stream — decide during Phase 4.)
- New annotation type surfaced in the annotations sidebar (jump-to-page).

## Phases (tracked in the task list)

0. iOS target + shims + minimal launch (in progress)
1. Touch-first PDF viewer
2. iPad chrome (toolbar/tabs/sidebar, Liquid Glass)
3. Web + AI + Settings
4. Apple Pencil annotations
5. Liquid Glass polish + touch ergonomics
6. Verify on iPad simulator (codex computer-use QA)

## Build / verify

```bash
xcodegen generate
xcodebuild -scheme Vellum -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPad Pro 13-inch (M5)' \
  -derivedDataPath .dd/ios build
```
Verify behavior on the iPad simulator (codex computer-use / xcode MCP), per
CLAUDE.md.
