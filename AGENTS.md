# Things to look out for

## Project shape and build ownership
- This worktree is the macOS app on `main`. Do not port iPad/iPhone code or change their product decisions unless the task explicitly targets those branches.
- `project.yml` is the source of truth for Xcode targets, files, build settings, and entitlements. After adding, removing, or retargeting Swift files, run `xcodegen generate`; never hand-edit `Vellum.xcodeproj/project.pbxproj`.
- Keep derived data isolated per worktree. A successful build is not a launch or UI verification; state which level was actually exercised.
- Before touching iCloud signing or entitlements, check GitHub issue #149. The current free Personal Team deliberately has no iCloud entitlement; do not add one speculatively.

## Test isolation and persistent state
- Tests must never write the user's real preferences, Keychain, document library, or attachment storage. Use `AppDefaults`/`TestEnvironment`, `KeychainStore.withBackend`, and `DocumentDataStore.rootDirectoryOverride` (or the established seam for that subsystem), then restore them in `defer`/teardown on every path.
- Do not introduce new `UserDefaults.standard` access in app services. It makes tests and UI-test reset state leak into the live app; route app defaults through `AppDefaults`.
- Treat global overrides and singleton backends as serialized test resources. Do not run tests that mutate the same override in parallel, and do not leave background work outstanding after a test.

## Document lifecycle and destructive operations
- A document's stable `docId` is its storage identity. On rename, import, or path-to-docId promotion, preserve and rekey all associated state together: metadata, conversations, scratchpad, and attachments. Do not create another path-keyed side store.
- Before closing, replacing, renaming, importing, or deleting a document, drain the resource's registered teardown/persistence tasks. Re-check that the document is still current after awaiting; these paths have previously raced with imports and background saves.
- Make destructive actions recoverable or explicitly confirmed, and preserve drafts across incidental sheet/window dismissal. Do not silently clear user content just because a transient view was dismissed.

## PDFKit and AI extraction
- Every `PDFPage.string`/page-text extraction must go through `PageTextExtractionGate`, including background indexing, on-demand AI tools, and search. The gate serializes access and gives interactive work priority; bypassing it can crash Live Text/ANE.
- Keep extraction and file I/O off the main actor. The UI must receive only the final state update, and stale/cancelled results must not be persisted or applied to a newly selected document.

## Main-thread hygiene
- Never run blocking work on `@MainActor` before the first `await`. Hop off first (`Task.detached` or a non-main actor), then come back for state updates. A slow or unmounted volume must never freeze the UI.
- UI state changes the user asked for apply immediately. Slow persistence runs behind them in a background task.
- Every fire-and-forget `Task` doing persistence must be joinable: keep the handle, register it somewhere quit paths and tests can drain (`await`) it. Never `Task.detached { ... }` and drop the handle.
- Moving work off the critical path creates race windows. Before starting a new operation on a resource, await any pending background work on that same resource.
- Any `isLoading`-style flag that gates UI must be released on every exit path, and use a generation token if attempts can overlap. A wedged flag is a silent lockout.

## SwiftUI hit targets and interaction
- To make a `.plain`-style `Button` clickable beyond its glyph, `.frame(...)` + `.contentShape(Rectangle())` must go inside the label closure (frame first). Applied outside the button they change layout only, not the hit region.
- Same trap: `Spacer`/transparent padding inside a tappable area needs `.contentShape(Rectangle())` or clicks fall through.
