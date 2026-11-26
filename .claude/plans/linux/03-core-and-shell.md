# Layer 4 — Shared core, Linux shell, and the dev loop

Decides: how code is shared (`VellumCore`), what the `Linux/` shell is built on, how
Swift concurrency runs inside GTK, and how we build and test in a container.

Depends on: D4 (Swift core + GTK shell in `Linux/`), D5 (container on the Mac).
Research: GPT 6.2 Astra, round 1, audited `4909b486` against Swift 6.4.3. Reviewed by Astra and
Gemini 4 Neon (round 2). Items marked **unverified** have not been built or run yet.

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
| Darwin `rename`/`errno`/`strerror` | `PdfAtomicWriter` and others | `#if canImport(Glibc)` imports |
| `CryptoKit` | 10 | swift-crypto. **Hashes must be byte-identical**: they are document and web-record identities |
| `Compression` | 1 (`WebArchive`) | zlib raw DEFLATE (`windowBits = -15`) |
| `NSFileCoordinator` / `NSFilePresenter` / `NSMetadataQuery` | 1 (`ICloudSyncedContainer`) | Not needed: Linux uses a direct-folder `SyncedContainer` (layer 2) |
| `UniformTypeIdentifiers` | 17 non-iOS | MIME types at the core boundary; GIO content-type guessing in the shell |
| `Security` / `SecItem` | 1 (`KeychainStore`) | libsecret backend behind the existing `KeychainStore.Backend` |
| `AttributedString(markdown:)` | 1–2 (`InlineMarkdown`) | Missing on Linux. Share a parsed Markdown tree (swift-markdown); render with Pango/WebKitGTK |
| `CGColor`, `CGVector`, `CGPDF*` | few | Numeric geometry in core; colours/PDF in the shell |
| `Observation` | 21 non-iOS | Available; GTK needs an explicit `withObservationTracking` → widget-update bridge |
| `UserDefaults` | 16 non-iOS | Available; stays device-local behind `AppDefaults` |

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

- 8 ms is a prototype value (about 125 idle wakeups/second, up to 8 ms added to every main-actor hop).
- **Reviewers disagree on the primary design; the spike decides.** Astra: start with the timer
  because it uses only public API. Neon: make the event-driven version primary (a GLib watch on
  libdispatch's main-queue eventfd via `g_unix_fd_add_full`: zero idle wakeups, no added latency).
  It relies on a private SPI (`_dispatch_get_main_queue_handle_4CF`). The spike builds both and measures
  idle CPU and hop latency. Plan of record: **event-driven primary, timer as automatic fallback**
  if the SPI is missing.
- Drive the CF turn **from Swift** (`RunLoop.main.run(mode: .default, before: .distantPast)`), not
  from C, so the C adapter doesn't depend on CoreFoundation headers, which on Linux ship inside
  swift-corelibs-foundation.
- Custom executors can't replace `MainActor` in Swift 6.4.3 (SE-0392 lists it as future work).
- Never call `dispatchMain()` alongside this, and never drain the main queue from a worker.
  libdispatch traps on both.
- CLAUDE.md's main-thread rules apply unchanged: one pump turn can run several jobs, so
  blocking work on the main actor still freezes GTK.

**Acceptance probe:** GTK signal → detached task → `await` → `MainActor.run` updates a
label; also a `DispatchQueue.main.async` update. Assert `MainActor.preconditionIsolated()`,
the same pthread as GTK startup, both updates visible before a watchdog deadline, at idle
and under input.

## Extraction sequence (read first, write later)

Revised after review round 2. Both reviewers flagged that the earlier "move the PDF writer" step
rested on a wrong premise (page annotations are written by PDFKit, see layer 3), and that the
read-only Linux reader must come before any write work.

0. **Concurrency mode.** `project.yml` builds with Swift 6, `SWIFT_STRICT_CONCURRENCY: minimal`
   and warnings as errors. A Swift 6 SwiftPM package defaults to complete checking, which fails on
   `nonisolated(unsafe)` test seams. Decision: `VellumCore` starts with `.swiftLanguageMode(.v5)`
   plus minimal checking to match the app, then tightens per module. Manifests use
   `swift-tools-version: 6.0` so the Mac's installed Swift 6.4.2 can build them.
1. **Prove the package.** Create `Packages/VellumCore`, move `PdfZoomPolicy`, wire it in
   `project.yml`. Round 3 audit: none of the four extensions compiles a file this plan moves, so
   only the two app targets depend on `VellumCore`.
2. **Identity and wire models.** `Annotation`, `DocumentInfo`, `RecentDocument`, URL normalisation,
   `DocumentIdentity` (+ swift-crypto, byte-identical hashes). **Also consolidate
   `WebLibrary.pageKey` and `PageTextCache.pathKey` into `DocumentIdentity`.** Positions depend on them.
3. **Reading positions.** First inject the root (`WebLibrary.appDataDir`) and defaults
   (`AppDefaults.current`) that `PositionModels`/`PositionStorage` reach for. Then move the wire types,
   merge, clock, storage protocol and direct-file store. Give Linux its own platform label and
   device ID (today non-macOS records say `ipados`/`iPad`).
4. **Archive codec.** `MiniZip`, raw DEFLATE, manifest, hashes, byte limits. **`ink.json` is opaque
   `Data` in the core codec.** `WebArchive` currently calls `WebInkStore.additivelyMerged` (PencilKit),
   which stays in the Apple app. Cross-read Mac- and Linux-written fixtures.
5. **Read-only Linux reader.** `Linux/Package.swift`, the main-loop bridge, PDFium rendering, one
   GTK window showing a library on a **disposable copy**. Read-only is enforced at the
   **filesystem boundary**, because ordinary "open" paths write: opening a `.vellumweb` through the
   Apple import path installs assets, mutates the record and merges ink, and `FilePositionStorage.loadAll`
   moves malformed records into quarantine. Acceptance: a checksum of the library before and after
   a session is unchanged. Also spike WebKitGTK here: custom URI scheme, injected scripts,
   page-to-app messages, offline assets.
6. **PDF primitives.** Split `PdfAtomicWriter`'s byte primitives from `SessionServiceError` (translate
   at the app boundary), and split the pure `/Info` and outline increments from their CGPDF readers.
   The Mac mutation path stays unchanged.
7. **Linux annotation writer** (layer 3 design), gated on the semantic round trip and the existing
   rotated-page and foreign-annotation fixtures, including iOS-targeted persistence tests.

Every PR: `xcodegen generate`, Debug `Vellum Mac` build with worktree-local derived data, the
iOS/extension targets touched by the move, and Linux `swift test`.

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
- **N8 (resolved, both reviewers agree):** share formats and operations, not Stores, for now.
- **N9:** look and feel (libadwaita vs plain GTK4) waits until the step-5 window exists.
- Stable path for unstamped PDFs across machines: resolved in layer 2 (stamp on import, root-relative fallback).

## Work items (C0–C8), manifests, container, scripts, and the main-loop probe

Round 3: drafted by GPT 6.2 Astra against `linux/plan-05-ink`, cross-checked against Gemini 4 Neon's S/P
items. These are **proposed implementation**: nothing here has been built yet. Verified facts: the
PDFium tarball and checksum, the arm64 Swift image digest, and the upstream bridge interfaces.

| ID | Item | Size | Depends on |
|---|---|---|---|
| C0 | Compiler + container baseline (Dockerfile, `dev-shell.sh`, `test-core.sh`) | S | N3 (runtime installed) |
| C1 | `VellumCore` package proof with `PdfZoomPolicy` | S | C0 |
| C2 | Identity, URL normalisation, wire models (+ swift-crypto) | M | C1 |
| C3 | Reading positions with injected roots and device identity | L | C2 |
| C4 | Bounded `.vellumweb` codec (`MiniZip` + raw DEFLATE via zlib) | L | C2 |
| C5a | GTK + main-loop bridge probe | M | C0, C1 |
| C5b | Read-only library + PDF reader (checksum-verified, writes nothing) | L | C2, C3, C4, C5a, P1 |
| C5c | Offline WebKitGTK proof (URI scheme, injected script, messages) | M | C4, C5b |
| C6 (= P4) | PDF byte primitives + `/Info` and outline increments into Core | L | C5b |
| C7a (= P3) | Edit eligibility from original bytes | M | C6, P3 design |
| C7b (= P5) | Linux page-annotation writer + cross-platform qualification | L + M | C7a, P5 design, P7 |
| C8 | Streaming transport (SSE) + credential store seams | M + M | C2 |

Round 3 resolved the main-loop disagreement procedurally: C5a's probe runs **auto, timer, missing-SPI and
strict-eventfd** modes under idle and busy load, records idle CPU, wakes and p50/p95/max hop latency, and
eventfd becomes the default only if it wins without starving input.

Three findings affect the implementation order.

- **Only the two application targets need `VellumCore`.** None of the four extensions individually compiles a file moved in this plan. In particular, none lists `DocumentIdentity.swift`.
- **The first reader needs a separate read path.** Even the Apple *direct* file store understands iCloud placeholders and can initiate materialization. `FilePositionStorage.loadAll()` can move files. Reusing either as the Linux read-only adapter would give “open” the wrong behavior.
- **The annotation writer needs an eligibility parser before it needs an encoder.** `ClassicPdfFile` can successfully parse inputs for which it has already discarded information needed to decide whether editing is safe. Successful construction of that type must never enable Save.

Path notation below is exact. `Core/` expands to `Packages/VellumCore/Sources/VellumCore/`, `CoreTests/` to `Packages/VellumCore/Tests/VellumCoreTests/`, and `L/` to `Linux/Sources/`. Paths on the destination side of a move, all `Linux/` paths, and test names labeled **new** are proposed.

## Common acceptance gate

Run from the worktree root during implementation. `IOS_SIM_ID` identifies an available iOS Simulator by UUID. Use the two named schemes because their build actions explicitly include their share and widget targets.

```bash
set -euo pipefail
: "${IOS_SIM_ID:?set to an available iOS Simulator UUID}"
dd="$PWD/.derived-data/linux-port"

xcodegen generate
xcodebuild -project Vellum.xcodeproj -scheme 'Vellum Mac' \
  -configuration Debug -derivedDataPath "$dd/mac" build
xcodebuild -project Vellum.xcodeproj -scheme Vellum \
  -configuration Debug -destination "platform=iOS Simulator,id=$IOS_SIM_ID" \
  -derivedDataPath "$dd/ios" build-for-testing

# From C1 onward
bash Linux/scripts/test-core.sh
```

For each item below, **G** means this gate plus its named tests. Run the Apple tests with these commands, adding `-only-testing:` filters when working on one item. Run the full relevant suites before merging. Mac tests have an explicit file list in `project.yml`. Most PDF persistence tests belong to the iOS scheme.

```bash
xcodebuild -project Vellum.xcodeproj -scheme 'Vellum Mac' \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath "$dd/mac" -parallel-testing-enabled NO test

xcodebuild -project Vellum.xcodeproj -scheme Vellum \
  -configuration Debug -destination "platform=iOS Simulator,id=$IOS_SIM_ID" \
  -derivedDataPath "$dd/ios" -parallel-testing-enabled NO test
```

Use isolated defaults, document roots, and fake credentials in every hosted test. Any manual Apple UI check uses the Debug product, `--disable-sync`, and `aero-open`. A successful Xcode build establishes compilation only.

## Work items

### C0 — Establish the compiler and container baseline

**Goal.** Give each extraction a reproducible Apple and Linux compiler gate. **Size S. Depends on none.**

**Files.** Inspect `project.yml`. Add `Linux/Dockerfile`, `Linux/scripts/dev-shell.sh`, and `Linux/scripts/test-core.sh` as specified below. Introduce the Core manifest setting in C1, its first buildable commit.

```swift
// On each new Swift target, including its tests
swiftSettings: [.swiftLanguageMode(.v5)]
```

`project.yml` declares `SWIFT_VERSION: "6.0"` and `SWIFT_STRICT_CONCURRENCY: minimal`. This is **not equivalent** to Swift 5 language mode. Swift 6 language mode enforces complete data-race checking. Swift 5 mode gives the extracted package the intended incremental adoption boundary. Minimal checking is the Swift 5 default. Use `-Xswiftc -strict-concurrency=minimal` in the explicit package acceptance command and avoid `.unsafeFlags` in a library product consumed by Xcode. Warnings-as-errors are explicit on the iOS app, both test targets, and the iOS share/widget targets. They are not a global setting in this branch.

**Tests and acceptance.** No existing tests move. Build the image using the commands below. `uname -m` must print `aarch64`, `swift --version` must report 6.4.3, and all specified `pkg-config` lookups must succeed. Run both Apple build commands against the baseline. The Linux package test gate starts at C1.

**Gotcha.** A `swift-tools-version:6.4.3` manifest would exclude the installed Mac compiler. Use tools version **6.0** for these manifests. Neither the extraction nor the container depends on a distribution licence decision.

### C1 — Prove a local package with the PDF zoom policy

**Goal.** Compile one real implementation once per platform, through the normal app and package entry points. **Size S. Depends on C0.**

**Files.**

| Existing | Change |
|---|---|
| `Vellum/Services/Pdf/PdfZoomPolicy.swift` | Move to `Core/Pdf/PdfZoomPolicy.swift`. |
| `Vellum/Views/PDF/PdfViewerTypes.swift`, `Vellum/Platform/iOS/PdfKitView_iOS.swift` | Consume the package types. These are the two production files outside the definition that name them. |
| `Tests/PdfZoomPolicyTests.swift` | Move arithmetic suites to `CoreTests/PdfZoomPolicyTests.swift`. Keep `freeMatchesTheStoresZoomRange()` in the existing hosted file with its `AppStore` assertions. |
| `Tests/PdfKitZoomModeTests.swift` | Reuse in the iOS host. |
| `project.yml` | Add the local package and the two app dependencies shown below. |
| `Packages/VellumCore/Package.swift` | Start with `VellumCore` and `VellumCoreTests` alone. Add Crypto at C2 and `CZlib` at C4. |

Make `PdfZoomMode`, `PdfZoomPolicy`, their caller-visible properties, `scaleTolerance`, `free`, `fitWidth`, `resolve`, `clamped`, `openingScale`, and `adjustedScale` public. The policy's memberwise initializer can remain internal. For the wider extraction use narrowly named **app-internal typealiases** in the existing Apple source files where the types used to live. That preserves names visible through `@testable import Vellum` without re-exporting an entire package or adding imports to hundreds of views. For these two first aliases use `Vellum/Views/PDF/PdfViewerTypes.swift` only if its compilation guards cover both apps. Otherwise put them in `Vellum/Models/Models.swift`, inside the shared app glob.

```swift
import VellumCore

typealias PdfZoomMode = VellumCore.PdfZoomMode
typealias PdfZoomPolicy = VellumCore.PdfZoomPolicy
```

**Exact XcodeGen additions**, merged into the existing mappings and dependency lists. Keep the existing entries in those lists.

```yaml
packages:
  VellumCore:
    path: Packages/VellumCore

targetTemplates:
  MacApp:
    dependencies:
      - package: VellumCore
        product: VellumCore

targets:
  Vellum:
    dependencies:
      - package: VellumCore
        product: VellumCore
```

`VellumMac` inherits `MacApp`. Both app source lists start at `Vellum/`. `Packages/` is already outside both. The actual individual-source audit is:

| Target | Individually named app sources in `project.yml` | Change |
|---|---|---|
| `VellumMacShare` | `Vellum/Services/Web/VellumExternalWebLink.swift`, `Vellum/App/RuntimeProfile.swift` | None |
| `VellumShare` | `Vellum/Services/Capture/{CaptureRecord,CaptureRecordBuilder,CaptureInboxLayout,CaptureInboxWriter,CaptureBackgroundSession}.swift`, `Vellum/App/RuntimeProfile.swift` | None |
| `VellumWidgets`, `VellumMacWidgets` | `Vellum/Services/Widgets/{VellumWidgetSnapshot,VellumWidgetSnapshotStore,VellumDeepLink}.swift`, `Vellum/App/RuntimeProfile.swift` | None |
| `VellumTests`, `VellumMacTests` | Hosted tests depend on their app. iOS globs `Tests/`. Mac explicitly lists its files. | Hosted tests keep importing `Vellum`. Package tests import `VellumCore`. |

**Acceptance.** G. Linux runs the zoom arithmetic, iOS runs the `AppStore` range assertion and viewer tests, and the Debug schemes build all four extensions. Inspect the generated project once for exactly one implementation of the policy per app.

**Gotcha.** Moving the entire test file unchanged pulls `AppStore` into the package proof.

### C2 — Extract identity, URL normalization, and wire models

**Goal.** Apple and Linux must derive the same keys from the same bytes and decode the same legacy records. **Size M. Depends on C1.**

**Files and declarations.**

| Existing | Destination or change |
|---|---|
| `Vellum/Models/Models.swift` | `Core/Models/Annotation.swift` for `AnnotationType`, `AnnotationRect`, `PositionData`, `Annotation`, `CreateAnnotationInput`, `UpdateAnnotationInput`. `Core/Models/DocumentInfo.swift` for `DocumentKind`, `DocumentInfo`, `RecentDocument`. Leave UI/tab types in the app. |
| `Vellum/Services/DocumentIdentity.swift` | `Core/Identity/DocumentIdentity.swift`. Keep the Apple name available through an internal alias. |
| `Vellum/Services/Web/WebPageExtractor.swift` | Split out **only** `WebUrl` and its parsing helpers into `Core/Identity/WebURLNormalizer.swift`. Keep the app's `WebUrl.normalize(_:)` entry point as the policy/error adapter. |
| `Vellum/Services/Web/WebLibrary.swift` | Move `WebPageRecord` to `Core/Models/WebPageRecord.swift`. Forward `pageKey` to `DocumentIdentity.sha256Hex`. |
| `Vellum/Services/Ai/PageTextCache.swift` | Forward `pathKey` to that same operation. Keep `contentHash(of:)` local. It hashes size and byte windows. |
| `Packages/VellumCore/Package.swift` | Add the conditional Crypto dependency in the manifest below. |

```swift
public enum DocumentIdentity {
    public static func storageKey(for document: DocumentInfo) -> String
    public static func byteHash(_ data: Data) -> String
    public static func isCanonicalKey(_ key: String) -> Bool
    public static func sha256Hex(_ string: String) -> String
}

public enum WebURLNormalizer {
    public static func normalize(_ raw: String, httpsOnly: Bool) throws -> String
}
public enum WebURLNormalizationError: Error {
    case invalidDocument(String)
}
```

The declarations above are signatures. Retain the implementation's lowercase hex, raw UTF-8, IDNA/punycode, tracking-parameter filtering, form encoding, and error strings. The Apple wrapper passes `httpsOnly: true` on iOS and `false` on macOS, translating the error to `SessionServiceError.invalidDocument`. Linux uses the Mac normalization policy. Use `CryptoKit` where available and `Crypto` on Linux. Do not normalize a filesystem path before hashing an existing path-key input.

Make all moved model types public, including their mutable fields, custom `Codable` witnesses, `Annotation.pinned`, and `Annotation.sortedForDisplay`. Write explicit public initializers with today's argument labels, ordering, and defaulted optionals. A synthesized memberwise initializer on a public Swift struct is internal. For example:

```swift
public init(
    kind: DocumentKind, pdfPath: String, title: String? = nil,
    pageCount: Int? = nil, lastPage: Int? = nil, docId: String? = nil,
    bookmarkData: Data? = nil, titleIsUserDefined: Bool? = nil
)
```

**Tests.** Reuse `Tests/DocumentIdentityTests.swift`, `Tests/PageTextCacheTests.swift`, and `Tests/WebProxyUrlTests.swift` in Apple targets. New `CoreTests/IdentityVectorTests.swift` freezes literal input bytes and expected hashes, including empty data, decomposed Unicode, a percent-encoded URL, a normalized international hostname, and a path with spaces. New `CoreTests/LegacyWireModelTests.swift` covers missing recent `kind` → `.pdf`, missing `is_pinned`, opaque `bookmark_data`, and `WebPageRecord` title defaults.

**Acceptance.** G. Run the same fixed expected values on Mac and Linux. Verify the iOS plain-HTTP rejection separately. `storageKey(for:)` still returns an existing `docId` verbatim. Canonical-key filtering remains at the existing trust boundaries.

**Gotcha.** The proposed shared-folder *root-relative* fallback is an S-layer migration. Changing today's path hash during extraction strands existing data. Similarly, decoding/re-encoding `WebPageRecord` is not yet a general unknown-field-preserving write path.

### C3 — Extract reading positions with injected storage and identity

**Goal.** Read and merge the same position files on each platform without consulting Apple application globals from Core. **Size L. Depends on C2.**

| Existing | Destination or change |
|---|---|
| `Vellum/Services/Position/PositionModels.swift` | `Core/Position/PositionModels.swift` for wire types, `DocumentKey`, identity values, coding, and timestamps. Apple identity overrides/current-device composition stay in the existing app file. |
| `Vellum/Services/Position/PositionMerge.swift` | `Core/Position/PositionMerge.swift`. |
| `Vellum/Services/Position/PositionClock.swift` | `Core/Position/PositionClock.swift` for protocols and production clocks/timers. Keep manual test helpers accessible to the hosted tests that use them. |
| `Vellum/Services/Position/PositionStorage.swift` | `Core/Position/PositionStorage.swift` for the protocol, filename/version grammar, error, and explicitly rooted `FilePositionStorage`. Keep `CoordinatedPositionStorage`, Apple root overrides, and app/test composition in the original file. |
| `Vellum/Services/Web/WebLibrary.swift` | Share its three-stage RFC3339 parser with `PositionTimestamp` in `Core/Position/PositionTimestamp.swift`. Keep compatible forwarding methods. |
| `Vellum/Services/Position/{PositionStore,DocumentPositionService}.swift` | Update construction to supply root and identity. Keep coalescing, hydration, flush handles, and app-facing APIs in place. |
| `Vellum/Services/AppDefaults.swift`, `Vellum/Platform/iOS/VellumApp_iOS.swift` | Use `AppDefaults.current` at Apple composition time and retain phone/pad name and idiom installation. |
| New `L/LinuxReader/LinuxEnvironment.swift` | Supply Linux platform `"linux"`, display fallback `"Linux"`, and device-local settings when identity is needed. |

```swift
public struct PositionRoots: Sendable {
    public let positions: URL
    public init(positions: URL) { self.positions = positions }
}

// One atomic get-or-create operation. Two callers must receive the same UUID.
public protocol DeviceIDDefaults: Sendable {
    func loadOrCreateID(forKey key: String) throws -> String
}
public struct DeviceIdentityProvider: Sendable {
    public let defaults: any DeviceIDDefaults
    public let name: String
    public let platform: String
    public init(defaults: any DeviceIDDefaults, name: String, platform: String)
    public func current() throws -> DeviceIdentity
}

public protocol PositionStorage: Sendable {
    func loadAll() async -> [PositionDeviceRecord]
    func write(_ record: PositionDeviceRecord) async throws
}
public struct FilePositionStorage: PositionStorage {
    public init(root: URL)
    public func loadAll() async -> [PositionDeviceRecord]
    public func write(_ record: PositionDeviceRecord) async throws
}
```

- Apple resolves `PositionLayout.rootOverride ?? WebLibrary.appDataDir.appendingPathComponent("positions")` at the app boundary for existing direct modes. Coordinated mode continues to use `layout.positionsDir`. S-layer shared mode must supply its own `layout.positionsDir`.
- Apple keeps the exact defaults key `vellum.device-id` and existing IDs. Serialize local get-or-create. An Apple adapter must obtain the current task's `AppDefaults.current` before crossing into detached work. On Linux, use `$XDG_STATE_HOME/vellum/device-id` with the usual `~/.local/state` fallback, a local lock, and an atomic write. The read-only reader needs no identity mint to list peer positions.
- `DocumentKey.web`, `.pdf(stableIdentifier:)`, and `.pdfPath` call Core's hash implementation. Promote `DeviceID`, `DeviceIdentity`, `DeviceIdentityStub`, `ReadingPosition`, `Stamped`, `OpenState`, `PositionEvent`, `PositionDeviceRecord.DocumentEntry`, `PositionJSON`, `MergedField`, `MergedDocumentPosition`, `ResumeEntry`, and the app-consumed clock/coding/merge APIs. Supply public initializers and public protocol witnesses. Keep parsing helpers private.
- `FilePositionStorage` retains existing writable quarantine semantics for its existing callers. Reject an invalid generated filename component before writing. Read-only display instead decodes enumerated bytes, sets `fileNameVersion`, and passes them to `PositionMerge`. It never calls quarantine.

**Tests.** Move `Tests/PositionMergeTests.swift` to `CoreTests/PositionMergeTests.swift`. Split `Tests/PositionWireFormatTests.swift`: move the deterministic bytes, unknown fields, large numbers, merge, trim, and version tests to `CoreTests/PositionWireFormatTests.swift`. Keep `defaultDeviceNameIsDisplayText()` and the assertions involving `WebLibrary` in the Apple host. Reuse `Tests/TestSupport/PositionTestSupport.swift` in both suites, e.g. give the package fixture helpers their own test-local source and retain the hosted helpers needed by other tests. Keep `Tests/{PositionWiringTests,PositionResumeTests,PositionSidecarIsolationTests,PositionCoalescingTests,CoordinatedPositionStorageTests}.swift` hosted. New `CoreTests/DeviceIdentityProviderTests.swift` and Linux `Linux/Tests/LinuxReaderTests/LinuxDeviceIdentityTests.swift` verify concurrent initialization, persistence across launches, and the platform label.

**Acceptance.** G. `bytesMatchTheDocumentedExample()` passes on both platforms. A writable corrupt fixture still quarantines as currently tested. A newer-version peer stays untouched. Linux records do not say `ipados` or `iPad`.

**Gotcha.** `PositionDeviceRecord` **and its document entries** already retain unknown fields via `PositionJSON`. Preserve those tests. This does not establish unknown-field retention in every nested value or unknown document-key namespace. `ContinueReading.swift` also reaches `HomeSearchItem`; moving it is unnecessary for position merge.

### C4 — Extract the bounded `.vellumweb` byte codec

**Goal.** Cross-read complete archives in memory while preserving Apple ink validation and merge behavior. **Size L. Depends on C2.**

| Existing | Destination or change |
|---|---|
| `Vellum/Services/Web/WebArchive.swift` | `Core/Archive/MiniZip.swift` for ZIP framing, CRC and bounded reads, including its private `Data` helpers. `Core/Archive/ArchiveCodec.swift` for manifest types, captured asset values, encode/decode, hash checks, and limits. |
| `Vellum/Services/Web/WebArchive.swift` | Keep capture/networking, app generator/version and timestamp composition, file installation, merge, and `ImportedArchive` with its typed `WebInkRecord?` in the Apple adapter. |
| `Vellum/Services/Web/WebInkStore.swift` | Reuse `validatedMergedDrawing()` and `WebInkStore.additivelyMerged` at the existing Apple validation/merge boundaries. |
| `Vellum/Services/Web/WebPageExtractor.swift` | Reuse the codec's 25 MiB snapshot cap as the existing `WebFetch.maxResponseBytes` value. |
| `Vellum/Services/VellumBundle.swift` | Consume the package's bounded `MiniZip` API. This is a second production ZIP caller. |
| New `Packages/VellumCore/Sources/CZlib/{module.modulemap,shim.h}` | zlib system target. |

```swift
public struct DecodedWebArchive: Sendable {
    public let manifest: ArchiveManifest
    public let snapshotHtml: String
    public let assets: [(String, Data)]
    public let annotations: [Annotation]
    public let inkJSON: Data?
}
public enum ArchiveCodec {
    public static func readManifest(data: Data) throws -> ArchiveManifest
    public static func decode(_ bytes: Data) throws -> DecodedWebArchive
    public static func encode(
        manifest: ArchiveManifest, snapshotHtml: String, assets: [CapturedAsset],
        pagesJson: Data, annotations: [Annotation], inkJson: Data? = nil
    ) throws -> Data
}
```

Make `ArchiveManifest`, `ManifestHashes`, `ManifestAsset`, `CapturedAsset`, their fields, constructors, and custom decoding witnesses public. Publish only the `MiniZip` constructors, entry constructor, accessors, and bounded operations used by the app and bundle. Translate codec errors to `SessionServiceError` at Apple entry points, including direct `MiniZip` errors from the bundle path.

Use raw DEFLATE method 8 with `deflateInit2_`/`inflateInit2_`, **`windowBits = -15`**, and method 0 for stored entries. Enforce input size before reading a whole file, declared entry count and cumulative sizes before allocation, and the actual output cap during inflation. Check stream termination and always end the zlib stream. Preserve `sha256:` on manifest hashes and bare hex on identity hashes. The current maxima are 80 assets, 8 MiB per asset, 64 MiB total assets, 4 MiB manifest, 32 MiB each annotations and ink, `maxAssets + 5` entries, and the existing aggregate formula. Keep path-based bounded ZIP initialization for sparse-file callers.

**Tests.** Reuse `Tests/VellumBundleTests.swift`, especially `testWebArchiveRejectsOversizedSparseFileBeforeParsing()` and `testMiniZipRejectsDeclaredInflationAndDuplicateNames()`. Reuse `Tests/WebInkPersistenceTests.swift`, including maximum assets, invalid declared ink, absent ink, and additive merge. New `CoreTests/ArchiveCompatibilityTests.swift` with fixtures for stored/deflated entries, split limits, opaque ink, missing declared ink, bad hash, and retained non-ASCII bytes.

**Acceptance.** G. Exchange actual files in both directions: pre-extraction Apple encoder → Linux decoder, Linux encoder → Apple hosted importer. Compare manifest semantics and each uncompressed member's bytes, including `ink.json`. ZIP timestamps and compressed bytes can differ. The hosted importer must still reject hash-valid bytes that cannot be decoded as a valid Apple drawing.

**Gotcha.** Existing `readArchive` verifies snapshot, annotation, ink, and listed asset hashes. It does not currently read and verify `text/pages.json` on that path. Test the page-text hash on the cross-platform export fixture. Tightening acceptance of legacy archives is a separate compatibility decision.

### C5a — Integrate GTK and prove the main-loop bridge

**Goal.** Establish that Swift main-actor and Dispatch work executes on the GTK startup thread. **Size M. Depends on C0, C1.**

**Files.** Add `Linux/Package.swift`, the Linux system-module shims below, `L/CShell/{include/CShell.h,loop.c,probe.c}`, `L/VellumLinux/{App.swift,LoopProbe.swift}`, and `Linux/scripts/screenshot.sh`. No Apple source moves. Start with the GTK dependencies needed for the probe; the manifest below also shows the later targets.

**Tests.** New Linux subprocess acceptance probe `--probe`, shown below. Run forced timer, automatic selection, strict eventfd, and simulated missing SPI. Test quiet and busy GTK. Use a subprocess because the actual startup pthread is part of the contract.

**Acceptance.** G plus `bash Linux/scripts/screenshot.sh probe` **inside the prepared container session**. Both labels must update, both isolation/thread checks must pass, and an external timeout must be able to kill a wedged process. Record selected mode, bridge wakes, process CPU at idle, and p50/p95/max enqueue-to-execution latency for both modes before making eventfd the default.

**Gotcha.** The fd is borrowed. Reading or closing it in C consumes or destroys libdispatch's own wake mechanism. Link-time reference to the private SPI would also defeat automatic fallback. Discover it at runtime.

### C5b — Build the read-only library and PDF reader

**Goal.** Open a real disposable library, select a document, and render pages without any library mutation. **Size L. Depends on C2, C3, C4, C5a, P1.** `P1` means the PDF layer's pinned arm64 rendering spike.

| Source | Destination or change |
|---|---|
| `Vellum/Services/Sync/LibraryFileStore.swift` | Move the **protocol**, `LibraryFileEntry`, and `LibraryFileError` to `Core/Storage/LibraryFileStore.swift`. Keep `DirectLibraryFileStore`, `CoordinatedLibraryFileStore`, and the `StorageCoordinator.StorageContext` extension Apple-side. |
| `Vellum/Services/Sync/SyncedContainerModels.swift` | Move only `ItemReadiness`, including `isReady`, to `Core/Storage/LibraryFileStore.swift`. Leave the iCloud identifiers and container models in the app. |
| New `L/LinuxReader/{ReadOnlyLibraryFileStore,LibraryCatalog,PDFRenderer}.swift` | Root-confined reads, catalog assembly, and serial PDF work. |
| New `L/CShell/{library_io.c,pdf_render.c,reader_window.c}` | Implement root-relative Linux reads, synchronous PDFium bitmap adapter, and GTK ownership/callbacks. |
| New `L/VellumLinux/ReaderController.swift` | Selection, page changes, cancellation, UI lifecycle, acceptance controls. |
| New `Linux/scripts/accept-readonly.sh` | Copy, hash, mount, run, close, and compare. |

Make the protocol methods, entry fields, entry initializer, error enum, and readiness cases public. A Linux-local write-denial error avoids changing exhaustive switches over the shared error enum.

```swift
enum ReaderFileError: Error { case readOnly }

struct ReadOnlyLibraryFileStore: LibraryFileStore {
    let isCoordinated = false
    let root: RootDirectory       // proposed owned, read-only directory fd

    func read(_ url: URL) async throws -> Data? {
        try await root.readRegularFile(url)
    }
    func list(_ directory: URL, suffix: String?) async throws -> [LibraryFileEntry] {
        try await root.listDirectory(directory, suffix: suffix)
    }
    func replace(_ url: URL, with data: Data) async throws {
        throw ReaderFileError.readOnly
    }
    func remove(_ url: URL) async throws {
        throw ReaderFileError.readOnly
    }
}
```

`RootDirectory` opens `/library` once with `O_DIRECTORY | O_RDONLY | O_CLOEXEC`. Convert a file URL to components relative to that root, reject absolute escapes, `.` and `..`, then walk with `openat` and `O_NOFOLLOW`, using `O_DIRECTORY` on intermediates. `fstat` the final fd and accept regular files only; use nonblocking open before the type check so a FIFO cannot hang the reader. Enumerate directories through directory fds. Perform I/O off the GTK thread. Check size on that same fd and cap incremental reads, including for archives. Use a bounded PDF-specific limit or file-backed read handling before allocating a whole PDF. A lexical prefix check followed by `Data(contentsOf:)` is insufficient.

**Window and read contract.**

```text
GtkApplicationWindow
└── vertical GtkBox
    ├── GtkHeaderBar — document title, previous page, page number, next page
    ├── GtkPaned
    │   ├── GtkScrolledWindow → GtkListBox — local library entries
    │   └── GtkStack
    │       ├── empty/error state
    │       ├── GtkScrolledWindow → GtkPicture — PDF texture
    │       └── WebKitWebView — offline archive in C5c
    └── GtkLabel — selection/render status updated after the main-actor hop
```

The fixture layout uses `PDFs/`, `Web Pages/`, `.vellum/records/`, and `.vellum/positions/`. `PDFs/` is the **provisional fixture convention** from layer 2. Supply at least one genuine Mac PDF explicitly in that directory when preparing a fixture from today's library. Current Mac library metadata can point outside the root. Never follow `lastKnownPath`, absolute recents, or Apple bookmarks out of the mounted copy. Skip Syncthing conflict names in the ordinary list; leave their bytes untouched. Unreadable/newer archives get a visible row state. Decode web records, archives, and positions directly from the read-only store. Opening a row must never install an archive, update recents, stamp a PDF, save position, merge ink, create an index, or quarantine malformed bytes.

**PDF code path.** Give PDFium one serial queue for initialization, document/page handles, rendering, text calls when added, destruction, and shutdown. The queue may change pthreads between jobs, but no two PDFium calls may overlap. A simple first implementation can load and close the document within one synchronous job, keeping its input `Data` borrowed for the entire job.

```c
/* Inside the serial PDFium job. doc and page are valid, w/h are bounded,
   positive, and computed at displayed aspect ratio. Use opaque white. */
FPDF_BITMAP bitmap = FPDFBitmap_Create(w, h, 0);
if (!bitmap) return false;
FPDFBitmap_FillRect(bitmap, 0, 0, w, h, 0xffffffff);
FPDF_RenderPageBitmap(bitmap, page, 0, 0, w, h, 0, FPDF_ANNOT);
int stride = FPDFBitmap_GetStride(bitmap);
if (stride < w * 4 || (size_t)h > SIZE_MAX / (size_t)stride) {
    FPDFBitmap_Destroy(bitmap);
    return false;
}
GBytes *pixels = g_bytes_new(FPDFBitmap_GetBuffer(bitmap), (size_t)stride * h);
FPDFBitmap_Destroy(bitmap);
/* Return owned pixels, dimensions, stride. Close page and doc on this queue. */
```

```c
/* GTK thread, after selection-generation validation. Opaque BGRx pixels
   from PDFium: choose the explicit BGRx format available in Noble GTK,
   or convert byte 3 to 0xff and use this BGRA format. */
GdkTexture *texture = gdk_memory_texture_new(
    w, h, GDK_MEMORY_B8G8R8A8, opaque_bgra_bytes, stride);
gtk_picture_set_paintable(picture, GDK_PAINTABLE(texture));
g_object_unref(texture);
```

Make the alpha conversion explicit in the first implementation; do not interpret unspecified padding as alpha. Check dimensions and a pixel budget **before** creating the bitmap, so `w * 4` and allocation size are bounded. `g_bytes_new` copies; balance the returned reference on success, cancellation, stale selection, and error. `FPDF_LoadMemDocument64` borrows its input until `FPDF_CloseDocument`. Do not let a borrowed Swift pointer escape `withUnsafeBytes`. A new selection increments a generation; apply only its latest render. The first page is index 0 in PDFium and page 1 in the UI.

**Tests.** Reuse `Tests/LibraryFileStoreTests.swift` on Apple. New `Linux/Tests/LinuxReaderTests/{ReadOnlyLibraryFileStoreTests,LibraryCatalogTests,PDFRendererTests}.swift`. Exercise denied replace/remove, component-prefix collisions, symlinks, malformed positions, missing PDFs, rapid selection, a rotated PDF, opaque colors, and `/Ink` with no `/AP`. Use a fixture with malformed JSON whose writable Apple adapter would quarantine. Include a known PDF with distinguishable marks on two pages.

**Acceptance.** G, Linux shell tests, and `accept-readonly.sh` below. Show two different pages; display a main-actor-updated label; quit through the normal close path; produce one PNG and identical before/after manifests. The PDF bitmap test must assert actual fixture pixels or landmarks. A nonempty PNG alone cannot detect a blank `GtkPicture`.

### C5c — Prove offline WebKitGTK behavior

**Goal.** Show that Vellum's offline web architecture works through GTK's actual WebKit integration. **Size M. Depends on C4, C5b.**

**Files.** Add `L/CShell/web_reader.c`, `L/LinuxReader/ArchiveResourceMap.swift`, and web handling in `L/VellumLinux/ReaderController.swift`. Use `Vellum/Services/Web/WebPageExtractor.swift` and `Vellum/Views/Web/WebContentScript.swift` as the reference for scheme routing and page-to-host messages. Keep the Apple implementations in place.

```swift
struct ArchiveResourceMap {
    init(archive: DecodedWebArchive, documentToken: UUID)
    func response(for uri: URL) throws -> (mime: String, bytes: Data)
}
```

Register the URI scheme with `webkit_web_context_register_uri_scheme`, install a `WebKitUserScript` with the content manager, and register a named script-message handler. Feed snapshot HTML and validated, bounded assets from memory. Reject unknown authority, wrong document token, traversal, and external loads. Start with a nonpersistent WebKit session. On navigation, release the old resource map after its outstanding requests finish or cancel.

**Tests.** New `Linux/Tests/LinuxReaderTests/ArchiveResourceMapTests.swift` and a `--web-probe` subprocess. Use an offline article with an image with known natural dimensions. Inject a script that reports those dimensions and a known text anchor through `window.webkit.messageHandlers`. Validate the document token and assert the **received values** in Swift.

**Acceptance.** G plus run `screenshot.sh web` under `--network none`. A response from the injected script, a successfully decoded offline image, and rejection of a stale URI are required. Exercise selecting the web row during the checksum session too. Display the layer-5 handwriting badge when opaque ink exists.

**Gotcha.** Loading HTML successfully proves none of the asset, script, or messaging contracts. WebKit's subprocess sandbox also needs to work as a non-root user in the actual colima VM. That capability remains **unverified**. Record a sandbox failure separately from a scheme-handler failure.

### C6 — Extract PDF primitives and increments · same item as P4 (layer 3)

**Goal.** Reuse byte-level operations while preserving Apple's PDFKit mutation and error behavior. **Size L. Depends on C5b for the read-first milestone; technically C2 suffices to compile the byte code.**

| Existing | Destination or change |
|---|---|
| `Vellum/Services/Pdf/PdfAtomicWriter.swift` | `Core/Pdf/PdfBytes.swift` for `PdfBytes`, `PdfBytePatch`, `PdfXrefRepair`, `PdfDictSource`, `PdfArraySource`, `ClassicPdfFile`, `PdfIncrement`, `PdfTextString`. `Core/Pdf/PdfAtomicFile.swift` for the atomic replacement implementation. Keep the Apple `PdfAtomicWriter.save` adapter. |
| `Vellum/Services/Pdf/PdfMetadata.swift` | `Core/Pdf/PdfInfoIncrement.swift` for both `setMetadataIncrement` overloads, `parseLastPage`, and `metadataKeySuffix`. Keep CGPDF reading and `stampDocumentId(atPath:id:)` in the app. |
| `Vellum/Services/Pdf/PdfBookmarks.swift` | `Core/Pdf/PdfOutlineIncrement.swift` for create/update/delete increments, traversal and byte-edit helpers. Keep CGPDF outline enumeration in Apple. |
| `Vellum/Services/Pdf/PdfSessionBackend.swift` | Continue calling the existing normalization, metadata rehydration, stale-xref repair and byte-patch paths. Import/alias the Core primitives it directly uses. |
| `Vellum/Services/SessionService.swift` | Map Core errors to the existing cases and messages at app entry points. |

```swift
public enum PdfCoreError: Error, Equatable {
    case invalidDocument(String)
    case io(String)
}
public enum PdfAtomicFile {
    public static func save(_ data: Data, toPath path: String) throws
}
public enum PdfInfoIncrement {
    public static func setMetadataIncrement(
        normalizedData: Data, entries: [(key: String, value: String)]
    ) throws -> Data
}
public enum PdfOutlineIncrement {
    public static func createBookmarkIncrement(
        normalizedData: Data, pageNumber: Int, id: String,
        content: String? = nil, now: String
    ) throws -> Data
    public static func updateBookmarkIncrement(
        normalizedData: Data, id: String, content: String,
        defaultTitle: String, now: String
    ) throws -> Data?
    public static func updateBookmarkIncrement(
        normalizedData: Data, id: String, isPinned: Bool, now: String
    ) throws -> Data?
    public static func deleteBookmarkIncrement(normalizedData: Data, id: String) throws -> Data?
}
```

Expose the primitive methods called by `PdfSessionBackend`, including `ClassicPdfFile` initialization/object lookup, dictionary inspection/mutation, array references/removal, increment creation/object updates, patch application, and xref repair. Internal parser scans stay internal. Preserve source permissions, same-directory temp name, POSIX replacement, cleanup on failure, and the original error message. Import `Darwin` or `Glibc` conditionally and capture `errno` immediately on failure.

**Tests.** Reuse `Tests/{PdfPersistenceTests,DocumentIdentityTests,InkPersistenceTests}.swift` on iOS. New `CoreTests/PdfIncrementTests.swift` covers direct and indirect `/Info`, two successive increments, outline links/counts, Unicode strings, and unchanged unrelated objects. New `CoreTests/PdfAtomicFileTests.swift` checks permissions and preservation of the original on failed replacement.

**Acceptance.** G plus the actual iOS persistence tests. Apple callers still see `SessionServiceError`; Debug mutations still use PDFKit for ordinary page annotations. The Linux read-only executable has no UI path to `PdfAtomicFile.save`.

**Gotcha.** `PdfSessionBackend` itself uses `ClassicPdfFile`, `PdfIncrement`, and `PdfDictSource` to rehydrate annotations and bookmarks. Exposing just `PdfInfoIncrement` and `PdfOutlineIncrement` would break the app.

### C7a — Determine whether Linux may edit a specific PDF · same item as P3 (layer 3)

**Goal.** Derive a conservative write decision from original bytes before exposing any mutation. **Size M. Depends on C6, P3.**

**Files.** New `Core/Pdf/PdfEditEligibility.swift`. Extend the parser moved from `Vellum/Services/Pdf/PdfAtomicWriter.swift` in `Core/Pdf/PdfBytes.swift` to retain object numbers, generations, free/in-use entries, and trailer-chain information needed for eligibility.

```swift
public enum PdfReadOnlyReason: Equatable, Sendable {
    case unsupportedXref, encrypted, signed, nonzeroGeneration
    case malformed, ambiguousAnnotation, unsupportedGeometry
}
public enum PdfEditEligibility: Equatable, Sendable {
    case editable
    case readOnly(PdfReadOnlyReason)
}
```

Check all relevant revisions, including hybrid `/XRefStm`, inherited `/Encrypt`, signature fields/dictionaries and certification permissions, and references that this edit will touch. Reject unresolved structure. Use checked arithmetic and iteration budgets on object counts, offsets, nesting, and `/Prev` chains. An authorization decision cannot depend on searching raw PDF text for `/Sig`. A conservative v1 may reject all live nonzero generations to simplify the first proof.

**Tests.** New `CoreTests/PdfEditEligibilityTests.swift`. Positive classic fixture; xref stream, hybrid, encrypted, signed/certified, nonzero generation, malformed previous revision, cycle, and unsupported geometry negative fixtures.

**Acceptance.** G. Each negative fixture opens where PDFium can render it, reports its read-only reason, and remains byte-identical after a rejected edit. No PDFium save API is linked into this workflow.

**Gotcha.** The existing parser's generation-0 reconstruction and permissive traversal are adequate for some PDFKit-normalized inputs. They are insufficient evidence about arbitrary originals.

### C7b — Implement and qualify the Linux page-annotation writer · same item as P5 (layer 3)

**Goal.** Create, update, and delete supported annotations on disposable original bytes, with matching readback on Apple. **Size L for the writer; M for the cross-platform qualification pass. Depends on C7a, P5, P7.** Enabling shared writes additionally depends on **S3, S1/S2, S5–S7 and the two-peer offline test**.

**Files.** Add `Core/Pdf/PdfAnnotationIncrement.swift`, `Core/Pdf/PdfPageGeometry.swift`, and `L/LinuxReader/PdfEditSession.swift`. Split the numeric portion of `PageGeometry` from `Vellum/Services/Pdf/PdfGeometry.swift`, retaining `init(pageDictionary:)` and `CgPdf` in Apple. Use `Vellum/Services/Pdf/PdfAnnotationCodec.swift`, `Vellum/Services/Pdf/PdfSessionBackend.swift`, and `Vellum/Platform/iOS/PdfInk.swift` as the behavioral references.

```swift
public enum PdfAnnotationEdit: Sendable {
    case create(CreateAnnotationInput)
    case update(UpdateAnnotationInput)
    case delete(id: String)
}
public enum PdfAnnotationIncrement {
    public static func applying(
        _ edit: PdfAnnotationEdit, to original: Data, now: String
    ) throws -> Data
}
```

Append changes to the original bytes. Support inline and indirect `/Annots`; preserve the order and contents of untouched slots. Port the Apple crop/rotation/`UserUnit` mapping and `/QuadPoints` ordering. Match `/NM`, `/M`, `/T`, `/F`, colors, annotation subtypes, `/CA` as a real, `/Name` as a PDF name, and all applicable `/Vellum*` keys. Preserve Apple `pdf-direct-{page}-{index}` behavior where an existing unnamed foreign annotation can be identified unambiguously. Refuse ambiguous edits. Never reorder the first `/Ink` carrier, touch `/VellumInk`, or promote `"1"` markers to a drawing. Bookmarks use C6's outline writer. V1 does no automatic compaction.

**Tests.** New `CoreTests/PdfAnnotationIncrementTests.swift` plus fixture exchange. Reuse the actual iOS `Tests/PdfPersistenceTests.swift` cases `testRotatedPagesRoundTrip`, `testForeignAnnotationDerivedIdAndUpdate`, `testForeignAnnotationDerivedIdSkipsNonDictionarySlots`, and `testUnrelatedCreateDoesNotClaimForeignAnnotation`. Reuse `Tests/InkPersistenceTests.swift`, including `testInkSurvivesWriteAndReload` and `testInkWritePreservesVellumAnnotationMetadata`. Add a hosted test that actually **opens the Linux-produced bytes**; running existing tests on their own fixtures does not establish interoperability.

**Acceptance.** G. Mac/iPad-generated fixture → Linux edit → Apple semantic readback; Apple edit → Linux readback. Compare subtype/key types, coordinates, selected text, annotation IDs, pin state, unrelated annotations, and original ink payload bytes. Exercise stale-file detection before committing, joined persistence on close, and failed writes on a disposable writable fixture. Keep C5's production reader mount read-only through qualification. Opening a two-writer library requires the S-layer conflict gate, including recoverability of scratchpad attachments.

**Gotcha.** Serializing PDFium calls protects the renderer only. It does not serialize Swift file writers or Syncthing replacement of a file. The local edit session must coordinate edits per document and detect a changed source before replacing it. External conflicts still require the S-layer recovery policy.

### C8 — Add streaming and credential seams when the first network feature needs them

**Goal.** Define the cross-platform boundaries without making AI, credentials, or networking prerequisites for offline reading. **Size M for transport, M for credentials. Depends on C2. Independent of C3–C7.**

**Files.** Add `Core/Network/StreamingTransport.swift`, `Core/Network/SSEDecoder.swift`, `Core/Credentials/CredentialStore.swift`, `L/LinuxServices/{AHCTransport,SecretServiceStore}.swift`. Adapt `Vellum/Services/Ai/{AiStreaming,OpenAIClient,OpenRouterClient,OpenCodeZenClient,GeminiClient}.swift` and the capped fetch in `Vellum/Services/Web/WebPageExtractor.swift` when migrating consumers. `Vellum/Services/Integrations/IntegrationDownloadClient.swift` is the existing bounded-download reference. Keep the Apple `Security` implementation in `Vellum/Services/KeychainStore.swift`.

```swift
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct StreamingHead: Sendable {
    public let status: Int
    public let headers: [String: [String]]
    public init(status: Int, headers: [String: [String]])
}
public protocol StreamingTransport: Sendable {
    func execute(
        _ request: URLRequest,
        onHead: @escaping @Sendable (StreamingHead) async throws -> Void,
        onChunk: @escaping @Sendable (Data) async throws -> Void
    ) async throws
}

public enum CredentialRead: Equatable, Sendable {
    case value(String), missing, unavailable
}
public enum CredentialWrite: Equatable, Sendable {
    case saved, failed, needsReview
}
public protocol CredentialStore: Sendable {
    func read(_ account: String, service: String) async -> CredentialRead
    func write(_ value: String, account: String, service: String) async -> CredentialWrite
    func delete(_ account: String, service: String) async -> Bool
}
```

Deliver headers first, await each chunk for backpressure, propagate cancellation to the underlying task, bound error bodies, and abort as soon as a cap is crossed. Decode SSE by buffering **bytes** until line boundaries; handle split scalars, split CRLF, EOF, empty `data:` lines, `[DONE]`, and the current providers' line filtering. Preserve the existing clients' status/retry behavior. Use AsyncHTTPClient only in `LinuxServices`; use an Apple `URLSession` adapter in the shell.

`KeychainStore.Backend` already exists. Its actual shape includes vault reads, probing modification dates, whole-vault writes/deletes, legacy enumeration/read/delete, commit-lock acquire/release, and three integration callbacks. Keep that type, `.live`, `withBackend`, migration, and locking intact. Bridge the high-level Apple adapter to `KeychainStore.read`, `writeCredential`, and `delete`; preserve `.unavailable` and `.needsReview`. The Linux implementation uses libsecret with per-device service/account attributes off the UI thread. A locked/unavailable Secret Service must not be interpreted as a missing key. If the high-level facade moves the result enums, retain `KeychainStore.CredentialRead`/`.CredentialWrite` as typealiases.

**Tests.** Reuse `Tests/KeychainStoreTests.swift` with the existing fake backend and `Tests/Integrations/IntegrationDownloadClientTests.swift`. New `CoreTests/SSEDecoderTests.swift` and Linux `Linux/Tests/LinuxServicesTests/{AHCTransportTests,SecretServiceStoreTests}.swift`. Use a loopback streaming fixture and a fake credential backend or isolated test D-Bus service. Never use the login keychain.

**Acceptance.** G plus `swift test --package-path Linux --scratch-path /build/linux` in the container. Assert receipt of an early chunk before EOF, cancellation at the size cap, complete UTF-8 text, and distinct missing/unavailable credential results. The reader can build and run offline without starting either service.

## Package manifests

**`Packages/VellumCore/Package.swift`**, as of C4:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VellumCore",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "VellumCore", targets: ["VellumCore"])],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "4.0.0")
    ],
    targets: [
        .systemLibrary(name: "CZlib", pkgConfig: "zlib",
                       providers: [.apt(["zlib1g-dev"])]),
        .target(
            name: "VellumCore",
            dependencies: [
                "CZlib",
                .product(name: "Crypto", package: "swift-crypto",
                         condition: .when(platforms: [.linux]))
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "VellumCoreTests", dependencies: ["VellumCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
```

**`Linux/Package.swift`**, final target graph. Add `LinuxServices`, its tests, `CSecret`, and the AsyncHTTPClient dependency at C8, when their first consumers exist. Add test targets only with their first source file.

```swift
// swift-tools-version: 6.0
import PackageDescription

let mode: [SwiftSetting] = [.swiftLanguageMode(.v5)]
let package = Package(
    name: "VellumLinux",
    products: [.executable(name: "vellum-linux", targets: ["VellumLinux"])],
    dependencies: [
        .package(path: "../Packages/VellumCore"),
        .package(url: "https://github.com/swift-server/async-http-client.git",
                 exact: "1.37.1")
    ],
    targets: [
        .systemLibrary(name: "CGtk", pkgConfig: "gtk4",
                       providers: [.apt(["libgtk-4-dev"])]),
        .systemLibrary(name: "CAdwaita", pkgConfig: "libadwaita-1",
                       providers: [.apt(["libadwaita-1-dev"])]),
        .systemLibrary(name: "CWebKit", pkgConfig: "webkitgtk-6.0",
                       providers: [.apt(["libwebkitgtk-6.0-dev"])]),
        .systemLibrary(name: "CPdfium", pkgConfig: "pdfium"),
        .systemLibrary(name: "CSecret", pkgConfig: "libsecret-1",
                       providers: [.apt(["libsecret-1-dev"])]),
        .target(name: "CShell",
                dependencies: ["CGtk", "CAdwaita", "CWebKit", "CPdfium"],
                publicHeadersPath: "include",
                linkerSettings: [.linkedLibrary("dl")]),
        .target(name: "LinuxReader",
                dependencies: ["CShell", .product(name: "VellumCore", package: "VellumCore")],
                swiftSettings: mode),
        .target(name: "LinuxServices",
                dependencies: [
                    "CSecret", .product(name: "VellumCore", package: "VellumCore"),
                    .product(name: "AsyncHTTPClient", package: "async-http-client")
                ], swiftSettings: mode),
        .executableTarget(name: "VellumLinux",
                          dependencies: ["CShell", "LinuxReader"], swiftSettings: mode),
        .testTarget(name: "LinuxReaderTests", dependencies: ["LinuxReader"],
                    swiftSettings: mode),
        .testTarget(name: "LinuxServicesTests", dependencies: ["LinuxServices"],
                    swiftSettings: mode)
    ]
)
```

Each system target has `Sources/<target>/module.modulemap` and `shim.h` in its own package. Expand this template with the exact rows below. Keep GTK/WebKit structs out of `CShell.h` where an opaque handle suffices.

```c
module CZlib [system] {
    header "shim.h"
    link "z"
    export *
}
/* Corresponding shim.h */
#include <zlib.h>
```

| Module | `link` | `shim.h` include |
|---|---|---|
| `CZlib` | `z` | `<zlib.h>` |
| `CGtk` | `gtk-4` | `<gtk/gtk.h>` |
| `CAdwaita` | `adwaita-1` | `<adwaita.h>` |
| `CWebKit` | `webkitgtk-6.0` | `<webkit/webkit.h>` |
| `CPdfium` | `pdfium` | `<fpdfview.h>`; also `<fpdf_text.h>` for P1 |
| `CSecret` | `secret-1` | `<libsecret/secret.h>` |

Commit the resolved dependency graphs for the consuming projects at the implementation stage. An exact direct dependency does not pin all transitive dependencies. Core tests should run without GTK, WebKit, PDFium, or a display.

## Container and scripts

**`Linux/Dockerfile`**. The requested checksum placeholder can be replaced immediately: I streamed the actual non-V8 tarball, calculated the digest below, matched it to the release metadata, and found `include/fpdfview.h` and `lib/libpdfium.so` inside. The archive does not supply `pdfium.pc`. The Docker image manifest lists `linux/arm64/v8` under the pinned index digest. I did not build the image. [PDFium release](https://github.com/bblanchon/pdfium-binaries/releases/tag/chromium%2F8179)

```dockerfile
FROM --platform=linux/arm64 swift:6.4.3-noble@sha256:4ed5e0210b244aab174450e0b79014c17db60c63c6daf0709347fe50c767293a

ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential pkg-config ca-certificates curl git python3 time \
    libgtk-4-dev libadwaita-1-dev libwebkitgtk-6.0-dev \
    libsecret-1-dev zlib1g-dev weston dbus dbus-daemon \
    fonts-dejavu-core libgl1-mesa-dri \
 && rm -rf /var/lib/apt/lists/*

ARG PDFIUM_TAG=chromium/8179
# PDFIUM_SHA256 is the checksum slot for a future deliberately updated pin.
ARG PDFIUM_SHA256=18bb6d568257b28d14f6c3b8bfb48caf73d4615b319ca4d43b424c2a03431d9f
RUN set -eu; \
    curl -fL --retry 3 \
      "https://github.com/bblanchon/pdfium-binaries/releases/download/${PDFIUM_TAG}/pdfium-linux-arm64.tgz" \
      -o /tmp/pdfium.tgz; \
    echo "${PDFIUM_SHA256}  /tmp/pdfium.tgz" | sha256sum -c -; \
    mkdir -p /opt/pdfium /usr/local/lib/pkgconfig; \
    tar -xzf /tmp/pdfium.tgz -C /opt/pdfium; \
    rm /tmp/pdfium.tgz; \
    test -r /opt/pdfium/include/fpdfview.h; \
    test -r /opt/pdfium/lib/libpdfium.so; \
    printf '%s\n' 'prefix=/opt/pdfium' 'libdir=${prefix}/lib' \
      'includedir=${prefix}/include' 'Name: pdfium' \
      'Description: pinned PDFium C API' 'Version: 8179' \
      'Libs: -L${libdir} -lpdfium' 'Cflags: -I${includedir}' \
      > /usr/local/lib/pkgconfig/pdfium.pc; \
    echo /opt/pdfium/lib > /etc/ld.so.conf.d/pdfium.conf; \
    ldconfig; \
    pkg-config --exists gtk4 libadwaita-1 webkitgtk-6.0 libsecret-1 zlib pdfium

RUN useradd -m -u 20001 -s /bin/bash reader \
 && install -d -o reader -g reader /work /build
USER reader
WORKDIR /work
CMD ["/bin/bash"]
```

Provisioning commands for the implementation operator:

```bash
colima start --arch aarch64 --cpu 4 --memory 8
docker --context colima build --platform linux/arm64 \
  -f Linux/Dockerfile -t vellum-linux-dev:6.4.3 Linux
bash Linux/scripts/dev-shell.sh bash -c \
  'uname -m && swift --version && pkg-config --modversion gtk4 webkitgtk-6.0 pdfium'
```

The following are the **four scripts**. Host-side scripts use Bash. The preview and probe script runs inside the image.

**`Linux/scripts/dev-shell.sh`** mounts the checkout read-only. It stages the two package trees into a fresh container-private work directory because SwiftPM can update lockfiles even with an external scratch path. The build cache is scoped to the worktree. Use independent volumes for concurrent runs of the same checkout.

```bash
#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/../.." && pwd -P)
key=$(printf '%s' "$repo" | shasum -a 256 | cut -c1-16)
args=(--rm -i --platform linux/arm64
      --mount "type=bind,src=$repo,dst=/repo,readonly"
      --mount "type=volume,src=vellum-build-$key,dst=/build")
if [[ -t 0 && -t 1 ]]; then args+=(-t); fi
if [[ -n ${VELLUM_FIXTURE_COPY:-} ]]; then
  args+=(--mount "type=bind,src=$VELLUM_FIXTURE_COPY,dst=/library,readonly")
fi
if [[ ${VELLUM_OFFLINE:-0} == 1 ]]; then args+=(--network none); fi
if [[ $# == 0 ]]; then set -- bash; fi

exec docker --context colima run "${args[@]}" vellum-linux-dev:6.4.3 \
  bash -eu -o pipefail -c '
    cd /work
    items=(Linux)
    if [[ -d /repo/Packages/VellumCore ]]; then items+=(Packages/VellumCore); fi
    tar -C /repo --exclude=.build --exclude=.swiftpm -cf - "${items[@]}" |
      tar -C /work -xf -
    exec "$@"
  ' dev-shell "$@"
```

**`Linux/scripts/test-core.sh`**:

```bash
#!/usr/bin/env bash
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd -P)
exec bash "$here/dev-shell.sh" swift test -c debug \
  --package-path /work/Packages/VellumCore --scratch-path /build/core \
  -Xswiftc -strict-concurrency=minimal "$@"
```

**`Linux/scripts/screenshot.sh`**. `probe`, `web`, and `reader` are separate modes. `reader` writes only PNG bytes to stdout. Its proposed Debug acceptance flags select fixtures through the normal controller and close the normal window. Publish `--ready-file` **after** the final PDF selection, both page checks, the web-row check when available, a label update, and a painted GTK frame. `--close-file` triggers normal close and teardown. Both control files live outside `/library`.

```bash
#!/usr/bin/env bash
set -euo pipefail
mode=${1:-reader}
if [[ ${VELLUM_PRIVATE_BUS:-0} == 0 ]]; then
  exec dbus-run-session -- env VELLUM_PRIVATE_BUS=1 bash "$0" "$mode"
fi
tmp=$(mktemp -d)
export XDG_RUNTIME_DIR="$tmp/run" XDG_CACHE_HOME="$tmp/cache"
export XDG_STATE_HOME="$tmp/state" XDG_CONFIG_HOME="$tmp/config"
export XDG_DATA_HOME="$tmp/data" XDG_PICTURES_DIR="$tmp/pictures"
export WAYLAND_DISPLAY=vellum-test GDK_BACKEND=wayland GSK_RENDERER=cairo
mkdir -m 700 -p "$XDG_RUNTIME_DIR" "$XDG_PICTURES_DIR"
app=/build/bin/vellum-linux
wpid= apid=
cleanup() {
  if [[ -n $apid ]]; then kill "$apid" 2>/dev/null || true; fi
  if [[ -n $wpid ]]; then kill "$wpid" 2>/dev/null || true; fi
  wait 2>/dev/null || true
  rm -rf "$tmp"
}
trap cleanup EXIT
weston --no-config --backend=headless --renderer=pixman --shell=kiosk-shell.so \
  --socket="$WAYLAND_DISPLAY" --width=1100 --height=760 --idle-time=0 \
  --debug >"$tmp/weston.log" 2>&1 &
wpid=$!
for ((i=0; i<200; i++)); do
  [[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]] && break
  kill -0 "$wpid" || { cat "$tmp/weston.log" >&2; exit 1; }
  sleep .05
done
[[ -S $XDG_RUNTIME_DIR/$WAYLAND_DISPLAY ]]

case "$mode" in
  probe)
    for pump in auto timer missing eventfd; do
      for load in idle busy; do
        timeout 12 "$app" --probe "$pump" "$load" >&2
      done
    done ;;
  web)
    timeout 20 "$app" --web-probe --library /library >&2 ;;
  reader)
    "$app" --library /library --acceptance \
      --ready-file "$tmp/ready" --close-file "$tmp/close" >&2 &
    apid=$!
    for ((i=0; i<400; i++)); do
      [[ -f $tmp/ready ]] && break
      kill -0 "$apid" || exit 1
      sleep .05
    done
    [[ -f $tmp/ready ]]
    (cd "$XDG_PICTURES_DIR" && timeout 8 weston-screenshooter >&2)
    shopt -s nullglob
    png=("$XDG_PICTURES_DIR"/*.png)
    [[ ${#png[@]} == 1 && -s ${png[0]} ]]
    touch "$tmp/close"
    for ((i=0; i<100; i++)); do
      kill -0 "$apid" 2>/dev/null || break
      sleep .05
    done
    if kill -0 "$apid" 2>/dev/null; then exit 1; fi
    wait "$apid"
    apid=
    cat "${png[0]}" ;;
  *) exit 64 ;;
esac
```

Noble publishes Weston 13. Its screenshooter uses a dated filename. Weston normally authorizes the compositor-launched screenshooter; `--debug` enables the standalone client's capture inside this **private headless compositor**. Keep that option confined to the test script. [Weston screenshot authorization](https://github.com/wayland-mirror/weston/blob/13.0.0/compositor/main.c) · [Screenshot output naming](https://github.com/wayland-mirror/weston/blob/13.0.0/clients/screenshot.c)

**`Linux/scripts/accept-readonly.sh`** takes a prepared fixture root and output PNG path. It rejects symlinks and special files during copying, then compares paths, entry types, modes, and content digests. New or removed empty directories count as changes. It compares even when the UI session fails.

```bash
#!/usr/bin/env bash
set -euo pipefail
: "${1:?usage: accept-readonly.sh FIXTURE_DIR OUTPUT.png}"
: "${2:?usage: accept-readonly.sh FIXTURE_DIR OUTPUT.png}"
here=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d "$HOME/.vellum-reader-test.XXXXXXXX")
trap 'rm -rf "$tmp"' EXIT
copy="$tmp/library"

python3 - "$1" "$copy" <<'PY'
import os, pathlib, shutil, stat, sys
src, dst = map(pathlib.Path, sys.argv[1:])
if src.is_symlink() or not src.is_dir():
    raise SystemExit("fixture must be a directory")
if dst.resolve().is_relative_to(src.resolve()):
    raise SystemExit("fixture must not contain the temporary destination")
def copy_tree(a, b):
    b.mkdir(mode=0o755)
    b.chmod(0o755)
    for p in a.iterdir():
        q = b / p.name
        mode = p.lstat().st_mode
        if stat.S_ISDIR(mode):
            copy_tree(p, q)
        elif stat.S_ISREG(mode):
            shutil.copyfile(p, q)
            q.chmod(0o644)
        else:
            raise SystemExit(f"unsupported fixture entry: {p}")
copy_tree(src, dst)
PY

manifest() {
  python3 - "$copy" <<'PY'
import hashlib, json, pathlib, stat, sys
root = pathlib.Path(sys.argv[1])
for p in [root, *sorted(root.rglob("*"))]:
    m = p.lstat().st_mode
    digest = None
    if stat.S_ISREG(m):
        h = hashlib.sha256()
        with p.open("rb") as f:
            for block in iter(lambda: f.read(1024*1024), b""):
                h.update(block)
        digest = h.hexdigest()
    elif not stat.S_ISDIR(m):
        raise SystemExit(f"unexpected entry: {p}")
    print(json.dumps([str(p.relative_to(root)), m, digest], ensure_ascii=True))
PY
}

# Build online before attaching the copy. The UI run itself has no network.
bash "$here/dev-shell.sh" bash -eu -c '
  swift build -c debug --package-path Linux --scratch-path /build/linux --product vellum-linux
  bin=$(swift build -c debug --package-path Linux --scratch-path /build/linux --show-bin-path)
  install -D -m755 "$bin/vellum-linux" /build/bin/vellum-linux
'
manifest > "$tmp/before"
result=0
VELLUM_FIXTURE_COPY="$copy" VELLUM_OFFLINE=1 \
  bash "$here/dev-shell.sh" bash /work/Linux/scripts/screenshot.sh reader \
  > "$tmp/reader.png" || result=$?
manifest > "$tmp/after"
diff -u "$tmp/before" "$tmp/after"
[[ $result == 0 ]]
python3 - "$tmp/reader.png" <<'PY'
import sys
with open(sys.argv[1], "rb") as f:
    assert f.read(8) == b"\x89PNG\r\n\x1a\n"
PY
cp "$tmp/reader.png" "$2"
```

Use a dedicated fixture, outside an active Syncthing folder, containing the two-page PDF, offline article and asset, corrupt position record, and an empty directory. For C5a before the reader exists, build/install the probe executable using the same `swift build` and `install` commands, then run:

```bash
VELLUM_OFFLINE=1 bash Linux/scripts/dev-shell.sh \
  bash /work/Linux/scripts/screenshot.sh probe
bash Linux/scripts/dev-shell.sh swift test -c debug \
  --package-path /work/Linux --scratch-path /build/linux
bash Linux/scripts/accept-readonly.sh "$FIXTURE_DIR" "$ARTIFACT_DIR/reader.png"
```

## Main-loop spike code

The C bridge owns one GLib source. Swift owns the nonblocking Foundation turn. Initialize and tear down on the GTK startup pthread, outside any async `main`. The Linux dispatch header defines the SPI result as `int`; Foundation's `RunLoop.run(mode:before:)` passes its interval to CoreFoundation. Their combined behavior under the target GTK loop is the question the test measures. [Dispatch 6.4.3 SPI](https://github.com/swiftlang/swift-corelibs-libdispatch/blob/swift-6.4.3-RELEASE/private/private.h) · [Foundation 6.4.3 RunLoop](https://github.com/swiftlang/swift-corelibs-foundation/blob/swift-6.4.3-RELEASE/Sources/Foundation/RunLoop.swift)

**`L/CShell/include/CShell.h`**, probe portion:

```c
#pragma once
#include <stdbool.h>
#include <stdint.h>

typedef void (*ShellCallback)(void);
enum { SHELL_AUTO, SHELL_TIMER, SHELL_MISSING, SHELL_EVENTFD };
int shell_install_pump(int mode, ShellCallback turn); /* 1 fd, 0 timer, -1 failure */
void shell_remove_pump(void);
bool shell_on_gtk_thread(void);
uint64_t shell_pump_wakes(void);

int shell_probe_run(bool busy, ShellCallback pressed);
void shell_probe_mark(int slot);
```

**`L/CShell/loop.c`**:

```c
#include "CShell.h"
#include <dlfcn.h>
#include <fcntl.h>
#include <glib.h>
#include <glib-unix.h>
#include <pthread.h>

static pthread_t owner;
static guint source;
static ShellCallback run_turn;
static uint64_t wakes;
static bool strict_fd;

bool shell_on_gtk_thread(void) {
    return pthread_equal(owner, pthread_self()) != 0;
}
uint64_t shell_pump_wakes(void) { return wakes; }

static gboolean timer_ready(gpointer unused) {
    g_assert(shell_on_gtk_thread());
    ++wakes;
    run_turn();
    return G_SOURCE_CONTINUE;
}
static guint start_timer(void) {
    return g_timeout_add_full(G_PRIORITY_DEFAULT, 8, timer_ready, NULL, NULL);
}
static gboolean fd_ready(gint fd, GIOCondition condition, gpointer unused) {
    g_assert(shell_on_gtk_thread());
    if (condition & (G_IO_NVAL | G_IO_HUP | G_IO_ERR)) {
        if (strict_fd) g_error("dispatch wake fd failed in strict eventfd mode");
        source = start_timer();
        return G_SOURCE_REMOVE;   /* removes this fd source, not the new timer */
    }
    ++wakes;
    run_turn();                   /* libdispatch/CF consumes its own wake */
    return G_SOURCE_CONTINUE;
}

int shell_install_pump(int mode, ShellCallback turn) {
    g_assert(source == 0 && turn != NULL);
    owner = pthread_self();
    run_turn = turn;
    wakes = 0;
    strict_fd = mode == SHELL_EVENTFD;
    if (mode != SHELL_TIMER && mode != SHELL_MISSING) {
        typedef int (*GetHandle)(void);
        GetHandle get = (GetHandle)dlsym(
            RTLD_DEFAULT, "_dispatch_get_main_queue_handle_4CF");
        int fd = get ? get() : -1;
        if (fd >= 0 && fcntl(fd, F_GETFD) != -1) {
            source = g_unix_fd_add_full(G_PRIORITY_DEFAULT, fd,
                G_IO_IN | G_IO_NVAL | G_IO_HUP | G_IO_ERR, fd_ready, NULL, NULL);
            if (source) return 1;
        }
    }
    if (strict_fd) return -1;
    source = start_timer();
    return source ? 0 : -1;
}
void shell_remove_pump(void) {
    g_assert(shell_on_gtk_thread());
    if (source) g_source_remove(source);
    source = 0;
    run_turn = NULL;
}
```

**`L/VellumLinux/LoopProbe.swift`**. Use the same `swiftTurn` in the real app. `MainActor.preconditionIsolated()` and the pthread assertion test different properties; retain both.

```swift
import CShell
import Dispatch
import Foundation

let swiftTurn: @convention(c) () -> Void = {
    precondition(shell_on_gtk_thread())
    _ = RunLoop.main.run(mode: .default, before: .distantPast)
}

private let pressed: @convention(c) () -> Void = {
    precondition(shell_on_gtk_thread())
    Task.detached {
        await Task.yield()
        await MainActor.run {
            MainActor.preconditionIsolated()
            precondition(shell_on_gtk_thread())
            shell_probe_mark(0)
        }
    }
    DispatchQueue.main.async {
        MainActor.preconditionIsolated()
        precondition(shell_on_gtk_thread())
        shell_probe_mark(1)
    }
}

// Invoke from synchronous App.main() for "--probe <mode> <idle|busy>".
func runLoopProbe(mode: String, busy: Bool) -> Int32 {
    let modes = ["auto": SHELL_AUTO, "timer": SHELL_TIMER,
                 "missing": SHELL_MISSING, "eventfd": SHELL_EVENTFD]
    guard let requested = modes[mode] else { return 64 }
    let selected = shell_install_pump(Int32(requested), swiftTurn)
    defer { shell_remove_pump() }
    guard selected >= 0 else { return 77 }  // missing forced fd: report explicitly
    if mode == "timer" || mode == "missing" { precondition(selected == 0) }
    if mode == "eventfd" { precondition(selected == 1) }
    print("pump=\(selected == 1 ? "eventfd" : "timer") load=\(busy ? "busy" : "idle")")
    return shell_probe_run(busy, pressed)
}
```

**`L/CShell/probe.c`**. A GTK signal starts each sample. The process measures two paths, waits through an idle baseline, then verifies the actual mapped label state. The busy variant adds recurring GTK signals while the hops are outstanding. This is synthetic GTK load; exercise real selection and page input in C5b as well.

```c
#include "CShell.h"
#include <gtk/gtk.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { N = 64 };
static GtkApplication *app;
static GtkWidget *labels[2], *trigger, *load_button;
static ShellCallback submit;
static gboolean under_load;
static int completed, marks, result = 1;
static gint64 start_us, sample[2][N], idle_start;
static uint64_t idle_wakes;
static clock_t idle_cpu;

static int compare_us(const void *a, const void *b) {
    gint64 x = *(const gint64 *)a, y = *(const gint64 *)b;
    return (x > y) - (x < y);
}
static void clicked(GtkButton *b, gpointer data) {
    start_us = g_get_monotonic_time();
    marks = 0;
    submit();
}
static gboolean emit_sample(gpointer data) {
    g_signal_emit_by_name(trigger, "clicked");
    return G_SOURCE_REMOVE;
}
static void load_click(GtkButton *b, gpointer data) {
    gtk_widget_queue_draw(GTK_WIDGET(b));
}
static gboolean busy_tick(gpointer data) {
    g_signal_emit_by_name(load_button, "clicked");
    return G_SOURCE_CONTINUE;
}
static gboolean begin_samples(gpointer data) {
    g_print("idle_wall_us=%" G_GINT64_FORMAT " idle_cpu_ms=%.2f idle_wakes=%lu\n",
        g_get_monotonic_time() - idle_start,
        1000.0 * (clock() - idle_cpu) / CLOCKS_PER_SEC,
        (unsigned long)(shell_pump_wakes() - idle_wakes));
    if (under_load) g_timeout_add(2, busy_tick, NULL);
    return emit_sample(NULL);
}
static gboolean baseline(gpointer data) {
    idle_cpu = clock();
    idle_start = g_get_monotonic_time();
    idle_wakes = shell_pump_wakes();
    g_timeout_add(1000, begin_samples, NULL);
    return G_SOURCE_REMOVE;
}
static gboolean finish(gpointer data) {
    result = 0;
    for (int i = 0; i < 2; ++i) {
        const char *want = i == 0 ? "MainActor OK" : "Dispatch OK";
        if (!gtk_widget_get_mapped(labels[i]) ||
            strcmp(gtk_label_get_text(GTK_LABEL(labels[i])), want) != 0)
            result = 1;
        qsort(sample[i], N, sizeof(gint64), compare_us);
        g_print("path=%d p50=%ld p95=%ld max=%ld us\n", i,
            (long)sample[i][31], (long)sample[i][60], (long)sample[i][63]);
    }
    g_application_quit(G_APPLICATION(app));
    return G_SOURCE_REMOVE;
}
void shell_probe_mark(int i) {
    g_assert(shell_on_gtk_thread() && (i == 0 || i == 1));
    g_assert(completed < N && !(marks & (1 << i)));
    sample[i][completed] = g_get_monotonic_time() - start_us;
    gtk_label_set_text(GTK_LABEL(labels[i]), i == 0 ? "MainActor OK" : "Dispatch OK");
    marks |= 1 << i;
    if (marks == 3) {
        ++completed;
        g_timeout_add(completed == N ? 40 : 5,
                      completed == N ? finish : emit_sample, NULL);
    }
}
static void activated(GtkApplication *application, gpointer data) {
    GtkWidget *window = gtk_application_window_new(application);
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_window_set_child(GTK_WINDOW(window), box);
    for (int i = 0; i < 2; ++i) {
        labels[i] = gtk_label_new("pending");
        gtk_box_append(GTK_BOX(box), labels[i]);
    }
    trigger = gtk_button_new_with_label("Probe");
    load_button = gtk_button_new_with_label("Input");
    gtk_box_append(GTK_BOX(box), trigger);
    gtk_box_append(GTK_BOX(box), load_button);
    g_signal_connect(trigger, "clicked", G_CALLBACK(clicked), NULL);
    g_signal_connect(load_button, "clicked", G_CALLBACK(load_click), NULL);
    gtk_window_present(GTK_WINDOW(window));
    g_timeout_add(150, baseline, NULL);
}
int shell_probe_run(bool busy, ShellCallback pressed) {
    under_load = busy;
    submit = pressed;
    app = gtk_application_new("org.vellum.LoopProbe", G_APPLICATION_NON_UNIQUE);
    g_signal_connect(app, "activate", G_CALLBACK(activated), NULL);
    int status = g_application_run(G_APPLICATION(app), 0, NULL);
    g_object_unref(app);
    return status ? status : result;
}
```

A probe is one process invocation. The external `timeout` is the independent watchdog. `77` means **eventfd unverified/unavailable**, not a passing eventfd test. The production `auto` branch still falls back to the timer. On an image that exports the symbol, require strict eventfd to pass and show substantially fewer idle bridge wakes than the timer, without input starvation. If the fd repeatedly wakes while no jobs complete, investigate CF draining before enabling it. Do not call `dispatchMain()` or drain the queue from a worker.

## Dependency graph and release gates

```text
C0 container/compiler baseline
└─ C1 package proof
   ├─ C2 identity and wire models
   │  ├─ C3 positions and device identity
   │  ├─ C4 bounded archive codec
   │  └─ C8 streaming and credentials (independent feature work)
   └─ C5a GTK/main-loop bridge

C2 + C3 + C4 + C5a + P1
  → C5b disposable read-only PDF reader
C4 + C5b
  → C5c offline WebKit proof
C5b
  → C6 PDF byte primitives and metadata/outline increments
C6 + P3
  → C7a eligibility parser
C7a + P5 + P7
  → C7b writer on disposable files

C5b + P1 → I1 (read-only PDF ink)
C5c + I4 + I5 → later portable web-ink display
C7b + S3 + S1/S2 + S5–S7 + passing two-peer offline recovery
  → eligible shared-folder writes
```

The `S-*`, `P-*`, and `I-*` labels identify required deliverables from the other layers; the five checked-in documents have not assigned those issue IDs. The first usable Linux milestone is **C5b**. Its evidence is a rendered real PDF, a proven main-actor hop, a successful normal close, and a byte-identical library copy. C5c adds offline web evidence. Neither milestone needs a writable Syncthing library, AI credentials, or a licence choice.
