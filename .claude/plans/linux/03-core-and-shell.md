# Layer 4 — Shared core, Linux shell, and the dev loop

Decides: how code is shared (`VellumCore`), what the `Linux/` shell is built on, how
Swift concurrency runs inside GTK, and how we build and test in a container.

Depends on: D4 (Swift core + GTK shell in `Linux/`), D5 (container on the Mac).
Research: GPT 6.2 Astra, round 1, audited `4909b486` against Swift 6.4.3. Items marked
**unverified** have not been built or run yet.

## Question

What is the smallest sequence of steps that gets a Linux window reading a real
Vellum library, while the Mac app keeps building and behaving the same at every step?

## Repo layout

```
Packages/VellumCore/     SwiftPM package: shared formats + operations (Mac, iOS, Linux)
  Package.swift
  Sources/VellumCore/
  Tests/VellumCoreTests/
Linux/                   SwiftPM package: GTK shell, depends on ../Packages/VellumCore
  Package.swift
  Sources/CGtk/          system-library targets (gtk4, libadwaita-1, webkitgtk-6.0)
  Sources/CShell/        small C adapter: signal trampolines, main-loop pump
  Sources/VellumLinux/   Swift app
  Dockerfile             dev image (swift:6.4.3-noble, linux/arm64)
```

- `project.yml` adds `packages.VellumCore.path: Packages/VellumCore` and the product on the
  Mac and iOS targets. The package sits **outside** the `Vellum/` source glob, so files are
  never compiled twice.
- `project.yml` lists extension sources one by one (share and widget extensions). Moving such a
  file can break an extension even when the Mac app builds, so each PR also builds those targets.

## What can be shared (Astra's classification)

The split covers 107 service files, 7 stores and 4 model files:
- **Portable now (A):** position merge/clock/store, `ContinueReading`, home search ranking,
  read-later planner/prefetcher/retention, `PdfZoomPolicy`, `PdfDocIdRegistry`, capture records, AI usage.
- **Needs a small seam (B):** AI clients (streaming, see below), `DocumentIdentity`
  (CryptoKit → swift-crypto), `LibraryFileStore`/`SyncedContainer` protocols,
  `PositionStorage`, scratchpad persistence, `ScratchOutRecognizer`.
- **Stays in the shell for now (C):** all PDF services (PDFKit), web services
  (`WebArchive` mixes the ZIP codec with networking and PencilKit validation),
  `KeychainStore`, `StorageCoordinator`, `ICloudSyncedContainer`, and 6 of the 7 stores.

**Decision:** share **formats and the operations that define their meaning** (identity,
records, archive codec, merge rules, session contracts). Do **not** share the Stores yet.
They own types that Services need (`AiMessage` and others live in `AiStore.swift`), and
`WorkspaceStore` reaches into Views. Lift those value types out first, then revisit.

## Swift-on-Linux gaps that hit Vellum

| API | Files | Linux replacement |
|---|---|---|
| `URLSession.bytes(for:)` / `AsyncBytes` | 5 (+`AiStreaming` `.lines`) | **Missing on Linux.** Streaming AI and the web extractor's size cap both need it. Chunked delegate (Vellum already has one in `IntegrationDownloadClient`) or AsyncHTTPClient; an SSE line splitter that handles split UTF-8/CRLF |
| `OSAllocatedUnfairLock` | 2 | `Synchronization.Mutex` |
| `CryptoKit` | 10 | swift-crypto. **Hashes must be byte-identical**: they are document and web-record identities |
| `Compression` | 1 (`WebArchive`) | zlib raw DEFLATE (`windowBits = -15`) |
| `NSFileCoordinator` / `NSFilePresenter` / `NSMetadataQuery` | 1 (`ICloudSyncedContainer`) | Not needed: Linux uses a direct-folder `SyncedContainer` (layer 2) |
| `UniformTypeIdentifiers` | 17 | MIME types at the core boundary; GIO content-type guessing in the shell |
| `Security` / `SecItem` | 1 (`KeychainStore`) | libsecret backend behind the existing `KeychainStore.Backend` |
| `AttributedString(markdown:)` | 3 | Missing on Linux. Share a parsed Markdown tree (swift-markdown); render with Pango/WebKitGTK |
| `CGColor`, `CGVector`, `CGPDF*` | few | Numeric geometry in core; colours/PDF in the shell |
| `Observation` | 17 | Available; GTK needs an explicit `withObservationTracking` → widget-update bridge |
| `UserDefaults` | 5 | Available; stays device-local behind `AppDefaults` |

## GTK from Swift: decision

| Option | Status (Nov 2026) | Verdict |
|---|---|---|
| adwaita-swift (Aparoksha) | Active, MIT, declarative; branch-tracked deps; WebKitGTK embedding and main-actor delivery unverified | Revisit when the shell grows |
| rhx/SwiftGtk (`gtk4` branch) | BSD-2, GIR-generated, broad; CI only on older Swift/Ubuntu, not arm64 6.4 | Not first |
| **Thin C adapter + SwiftPM module maps** | GTK4, libadwaita and WebKitGTK 6 C APIs; arm64 headers in Ubuntu Noble | **Start here** |

Recommendation: begin with the thin adapter. The first window needs only an app, a library
list, a PDF surface and a `WebKitWebView`, so it doesn't need a large binding. All widget pointers and
callback lifetimes stay inside `Linux/`. A web view that loads an article proves only basic
embedding. Vellum also needs custom URI schemes, injected scripts, page-to-host
messages and offline asset serving, so the spike must exercise those.

## `@MainActor` inside GTK (the critical risk)

On Linux, Swift's `@MainActor` runs jobs on the Dispatch main queue. GTK runs a GLib main
loop. A thread sitting in `g_application_run()` **does not** drain Dispatch, so every
`await MainActor.run { … }` would stall. 68 files use `@MainActor`.

Fix (public APIs): on the GTK thread, a repeating GLib source gives CoreFoundation's run
loop one non-blocking turn, which drains the Dispatch main queue.

```c
static gboolean service_swift_main(gpointer _) {
    CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0, true);
    return G_SOURCE_CONTINUE;
}
// before g_application_run:
g_timeout_add_full(G_PRIORITY_DEFAULT, 8, service_swift_main, NULL, NULL);
```

- 8 ms is a prototype value (about 125 idle wakeups/second). Refinement: watch libdispatch's
  main-queue eventfd with `g_unix_fd_add_full` so it wakes only when work exists. That uses a
  private SPI (`_dispatch_get_main_queue_handle_4CF`), so keep the timer as fallback.
- Custom executors can't replace `MainActor` in Swift 6.4.3 (SE-0392 lists it as future work).
- Never call `dispatchMain()` alongside this, and never drain the main queue from a worker.
  libdispatch traps on both.
- CLAUDE.md's main-thread rules apply unchanged: one pump turn can run several jobs, so
  blocking work on the main actor still freezes GTK.

**Acceptance probe:** GTK signal → detached task → `await` → `MainActor.run` updates a
label; also a `DispatchQueue.main.async` update. Assert `MainActor.preconditionIsolated()`,
the same pthread as GTK startup, both updates visible before a watchdog deadline, at idle
and under input.

## Extraction sequence (each PR keeps the Mac building)

Astra proposed five steps; step 4 (PDF writer) was added after Neon found that Vellum's
PDF writer is already pure Swift.

1. **Prove the package.** Create `Packages/VellumCore`, move `PdfZoomPolicy`, wire it in
   `project.yml`. Gate: `xcodegen generate` + Debug `Vellum Mac` build + `swift test` on Linux.
2. **Identity and wire models.** `Annotation`, `DocumentInfo`, `RecentDocument`, URL
   normalisation, `DocumentIdentity` (+ swift-crypto on Linux). Keep coding keys and the
   exact path-hash fallback.
3. **Reading positions.** Wire types, merge, clock, storage protocol, direct-file store.
   Give Linux its own platform label and device ID (today non-macOS records say `ipados`/`iPad`).
4. **PDF writer.** Move the Foundation-only `PdfAtomicWriter` family (`ClassicPdfFile`,
   `PdfIncrement`, `PdfBytePatch`, `PdfXrefRepair`) plus the dictionary codecs it needs.
   This is how Linux writes annotations (layer 3), so it comes before the reader.
5. **Archive codec.** `MiniZip`, raw DEFLATE, manifest, hashes, byte limits. Cross-read
   Mac- and Linux-written fixtures. Network capture and PencilKit validation stay in the app.
6. **First Linux reader.** `Linux/Package.swift`, the main-loop pump, one GTK window that
   opens a local library record **read-only**.

Every PR: `xcodegen generate`, Debug `Vellum Mac` build with worktree-local derived data,
the iOS/extension targets touched by the move, and Linux `swift test`.

## Container dev loop

- **Image:** `swift:6.4.3-noble`, `linux/arm64`, digest pinned once the first build passes.
  Ubuntu over Arch: official Swift images, arm64 packages for GTK4, libadwaita,
  WebKitGTK 6 and Weston.
- **Packages:** `build-essential pkg-config libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev
  zlib1g-dev weston dbus fonts-dejavu-core libgl1-mesa-dri` (+ `libsecret-1-dev` later).
  PDFium: pinned non-V8 `pdfium-linux-arm64.tgz` from bblanchon/pdfium-binaries (layer 3).
- **Core tests:** `swift test --package-path Packages/VellumCore --scratch-path /build/core`
  with no GTK or display needed. Repo mounted read-only, build output in a volume, a
  **disposable copy** of the library at a stable path.
- **UI screenshots for agents:** Weston headless (`--backend=headless --renderer=pixman`)
  inside `dbus-run-session`, then `weston-screenshooter`. The first acceptance artifact is one
  PNG showing a rendered PDF page **and** a label updated after a main-actor hop. That proves
  rendering, storage and the event loop together.

### Runtime on the Mac (N3)

| Runtime | Note |
|---|---|
| **colima** (Astra's pick) | Open source, Lima VM, Docker-compatible CLI. Fits a CLI/agent workflow |
| OrbStack (my earlier pick) | Fast, Mac UI, free for personal use; Docker-compatible |
| Docker Desktop | Standard, heavier |
| Apple `container` | Native on macOS 26, different CLI |

Either colima or OrbStack works; the commands are identical (`docker …`). **Your call.**

## Open questions

- **N3:** colima or OrbStack?
- **N8 (resolved here, pending review):** share formats and operations, not Stores, for now.
- **N9:** look and feel (libadwaita vs plain GTK4) waits until the step-5 window exists.
- Stable path for unstamped PDFs across machines (see layer 2: identity risk).
