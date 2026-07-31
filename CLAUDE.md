# Things to look out for

## Main-thread hygiene 
- Never run blocking work on `@MainActor` before the first `await`. Hop off first (`Task.detached` or a non-main actor), then come back for state updates. A slow or unmounted volume must never freeze the UI.
- UI state changes the user asked for apply immediately. Slow persistence runs behind them in a background task.
- Every fire-and-forget `Task` doing persistence must be joinable: keep the handle, register it somewhere quit paths and tests can drain (`await`) it. Never `Task.detached { ... }` and drop the handle.
- Moving work off the critical path creates race windows. Before starting a new operation on a resource, await any pending background work on that same resource. 
- Any `isLoading`-style flag that gates UI must be released on every exit path, and use a generation token if attempts can overlap. A wedged flag is a silent lockout.

## SwiftUI hit targets and interaction 
- To make a `.plain`-style `Button` clickable beyond its glyph, `.frame(...)` + `.contentShape(Rectangle())` must go inside the label closure (frame first). Applied outside the button they change layout only, not the hit region.
- Same trap: `Spacer`/transparent padding inside a tappable area needs `.contentShape(Rectangle())` or clicks fall through.
