# SwiftUI port — end-to-end verification checklist

Drive the built Vellum.app (macos/) and verify each behavior matches the Tauri app.
Test PDF: /private/tmp/claude-501/.../scratchpad/sample.pdf (multi-page, real text).

## Welcome + shell
- [ ] Launch: welcome screen with wordmark, open button, URL field, recent files (empty first run)
- [ ] Cmd+O → multi-select dialog (pdf + vellumweb) → PDF opens in a tab
- [ ] Recent files list populates after open; remove button works; clicking reopens
- [ ] Theme toggle flips light/dark; persists across relaunch
- [ ] Window: 1280×800 default, min 800×600

## PDF viewing
- [ ] Continuous scroll; page number/total in toolbar tracks scroll
- [ ] Zoom in/out buttons + Cmd+= / Cmd+- (0.25–4.0, step 0.1); percentage display
- [ ] Page navigation input jumps to page; prev/next buttons
- [ ] Reopen: restores last page (last_page metadata persisted on close/tab-switch)
- [ ] Tabs: second PDF opens second tab; Cmd+1/2 switch; Cmd+W closes; opening same file activates existing tab

## Annotations (persistence = embedded in the PDF file)
- [ ] Select text → popover appears above selection; 5 color swatches + note button
- [ ] Click swatch → highlight rendered at 40% opacity; click highlight → edit popover (recolor, Unhighlight)
- [ ] Note button in popover → note input → Add → sticky note with quoted text
- [ ] N key toggles note mode (crosshair); click places note; auto-opens editor; Esc/blur saves
- [ ] Right-click → "Add note here"
- [ ] Drag sticky note (3px threshold); position persists after reopen
- [ ] Cmd+B bookmarks page (star fills gold); Cmd+B again removes
- [ ] Sidebar: lists all; filter pills; click navigates; double-click edits content; hover delete
- [ ] CRITICAL round-trip: close app, reopen PDF → all annotations still there (embedded in file)
- [ ] Auto-save: every 30s + Cmd+S silent

## AI panel
- [ ] Sidebar AI tab: empty state copy; settings (provider/model/key fields per provider; codex hides key)
- [ ] Settings persist across relaunch
- [ ] With codex provider (no key needed): send message → "Thinking…" → reply appears (needs codex CLI)
- [ ] Tool calls: ask "highlight X on page N" → highlight created + "Actions:" list in reply
- [ ] Conversation persists per document across tab switches and relaunch
- [ ] Clear conversation button empties

## Web mode
- [ ] Cmd+L or toolbar → URL prompt → webpage opens in reading mode as virtual pages
- [ ] Text selection highlights work on web pages; notes anchor; bookmark anchors to position
- [ ] Save webpage toggle → appears in welcome saved list; reload uses snapshot
- [ ] Export .vellumweb; reopen the file (Cmd+O) → imports with annotations
- [ ] In-page link click navigates in-tab (session rebinds)

## Cross-compat (spot check)
- [ ] A PDF annotated by the OLD Tauri app shows its highlights/notes/bookmarks in the port
