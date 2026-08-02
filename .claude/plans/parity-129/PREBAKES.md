# Pre-baked stages (parallel worktrees) — landing state

## Stage I / packet 8 (integrations, #137) — PRE-BAKED ✅
- Branch: `worktree-agent-a5dc17d09063ef791`
- Worktree: `/Users/ayushdeolasee/Developer/Vellum/.bare/.claude/worktrees/agent-a5dc17d09063ef791`
- Base: `6e548595` (Stage C; the agent corrected its worktree, which had wrongly been cut from main). 10 commits `f4dbf7c2..6b8ebb39`, 52 files, +5763/−6.
- Verified: clean build + 87 tests / 10 suites green (iPad mini A17 Pro, -only-testing). Full suite deferred to landing.
- Landing procedure (Stage I, after Stage H):
  1. Cherry-pick/apply the 10 commits onto ipad-app (expect drift in SettingsView [order 3→1→5→8; 8 last], WorkspaceStore, VellumApp_iOS, PaneView_iOS, PdfChrome_iOS, AiSettingsPanel, RevealableSecureField [packet 5 also merged it in Stage D]).
  2. Apply held-back seams per `LANDING-packet-8-integration-points.md` (in that worktree): ReadLaterSearchProvider.swift (register LAST in provider list; needs packet 3's Vellum/Services/Search/) and the 7 WelcomeScreen_iOS Home-switcher hunks (match packet 3's switcher control, NOT GlassSegmentedPicker, per the agent's open decision).
  3. project.yml: no-op (Stage A already landed the fixtures hunk byte-identically).
  4. Full suite gate + device checks per ROADMAP Stage I.
- Risks flagged for later: R1 KeychainStore never sets kSecAttrAccessible (locked-device sync reads nil → spurious disconnect; packet 9/Stage J follow-up), R4 revision-change PDF replacement discards embedded annotations (worse on iPad; consider follow-up issue).

## Stage G / packet 3 (Home/onboarding, #132) — PRE-BAKED ✅
- Branch: `worktree-agent-a0c6b5d6ed5c8540e`
- Worktree: `/Users/ayushdeolasee/Developer/Vellum/.bare/.claude/worktrees/agent-a0c6b5d6ed5c8540e`
- Base: `6e548595` (Stage C; agent corrected the wrong-base worktree same as Stage I's did). 6 commits `26bc6790..f51b5f18`, 33 files, +6286/−118.
- Verified: app builds + 121 tests / 8 suites green (iPad Air 13-inch M4, -only-testing). Full gate at landing.
- Landing procedure (Stage G, after Stage F): cherry-pick/apply the 6 commits; re-apply the 10 documented shared-file hunks (SettingsView — packet 3's structure WINS, land 3→1→5→8; VellumApp_iOS sheet sequencing; KeyboardShortcuts_iOS catalogue [expect mechanical conflict with packet 4's Stage F changes]; ShortcutRouter_iOS; VellumCommands_iOS; WorkspaceStore.SettingsSection; Controls.Keycap; WebLibrary.setTitle; PdfChrome_iOS SettingsSheet swap; Tests/ScratchDefaultsTrait). Full handoff detail in the agent's final report (task output a0c6b5d6ed5c8540e).
- Notables: HelpCenterView landed in phase C (compile dep); HomeNotifications_iOS.swift is new (keeps WalkthroughSettings verbatim); 2 real iOS sheet-layout bugs fixed (ScrollView sizeThatFits intrinsic height; 0.5pt Divider hairline) — tolerances untouched; SettingsNavigationTests defers 4 AiSettings.isConfigured tests to packet 5 (documented in-file, not a drop).

## Stage H / packet 2 (bundles, #131) — PRE-BAKED ✅
- Branch: `worktree-wf_488625fb-334-2`
- Worktree: `/Users/ayushdeolasee/Developer/Vellum/.bare/.claude/worktrees/wf_488625fb-334-2`
- Base: `4fbce459` (Stage E HEAD; agent corrected the wrong main-cut base — FOURTH pre-bake in a row to hit this, the worktree spawner systematically cuts from main). 11 commits `6e6be0e6..882006c0`.
- Verified: 189 tests / 14 suites green (iPad mini A17 Pro, -only-testing). Full gate at landing.
- NOTHING HELD BACK — every packet-2 hunk applied; agent verified none needed packet-4/7 context (packet 4 does not port awaitTeardowns(ofDocumentAt:) on the open path; packet 7 G4 leaves moreMenu's shape alone). `LANDING-packet-2-integration-points.md` (committed as 882006c0, delete at landing) is a conflict map, not a held-back list.
- Notables: packet 2 §4 adaptation 3 unnecessary (both deferred conversation-cap tests pass — packet 5 landed the surface in Stage D; packet text stale for reviewers). VellumBundle.write runs in Task.detached on iPad (deliberate divergence, for the PR body). Two tests write into the real DocumentImport.libraryDirectory (UUID-prefixed + teardown-cleaned; if a storage suite flakes at landing, look here first; clean fix = libraryDirectoryOverride seam, belongs to packet 1).
- Landing slot: right after Stage F. AppStore.swift edit order 1→4→2 is preserved because packet 4's hunks land with F before packet 2's land here.
- Lands with the full-suite gate + the Files-app clean-install device check (stale LaunchServices registrations from the old UTI persist until delete+reinstall).

## Rationale
G and I depend only on Stage B per ROADMAP's dependency graph; they were serialized only by worktree sharing. Pre-baked in parallel with Stage D to cut wall time; full-suite gates still run at landing in the main worktree.
