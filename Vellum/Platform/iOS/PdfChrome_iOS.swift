#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

// iPad reading chrome: a touch-first Liquid Glass toolbar (page nav, zoom, find,
// note tool, bookmark, sidebar, more), a tab strip, and the sidebar content —
// the iPad analogue of the macOS VellumToolbar / TabBarView. Tap targets are
// 44pt; low-frequency file actions collect in a "More" menu.

// MARK: - Toolbar

struct PdfToolbar_iOS: View {
    var ink: InkController_iOS
    var onOpenFile: () -> Void
    var onAddWebpage: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.palette) private var palette

    @State private var pageFieldText = ""
    @State private var showPageJump = false
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var toolbarWidth: CGFloat = 0

    /// Web offline-copy state and both export state machines, shared verbatim
    /// with the phone reader's More menu (`DocumentExportActions_iOS`, #153 P5).
    /// It used to live here as five `@State` properties; the phone needs the
    /// same three actions and a second copy of a serialized, generation-guarded
    /// toggle is a bug waiting to be fixed on one surface only.
    @State private var exportActions = DocumentExportActions_iOS()
    @State private var showExportBundle = false

    private var isWeb: Bool { appStore.document?.kind == .web }
    // The pods have fixed 44pt targets, so when the sidebar squeezes the row
    // the lowest-value pods yield instead of clipping at the edges: the zoom
    // pod first (pinch still works for PDFs and web pages; More keeps the
    // commands), then annotation tools, page-step chevrons, and finally page
    // navigation plus Sidebar.
    private var showZoomPod: Bool { toolbarWidth == 0 || toolbarWidth >= 840 }
    // DELIBERATE DIVERGENCE FROM macOS (#115 review, #129 packet 7 §2.10 G5).
    // The Mac toolbar splits `[< >]` and `[1 / N]` into two separate glass
    // capsules. The iPad keeps them in ONE pod, `[< 1/N >]`, for two reasons:
    //
    //  * cost. A second capsule spends ~16pt on its own horizontal padding plus
    //    the inter-pod gap, in a row that already has to shed the zoom pod at
    //    840pt and these very chevrons at 590pt. Mouse-sized 32pt targets can
    //    afford the split; 44pt ones cannot.
    //  * meaning. The Mac's page indicator is an inline editable text field —
    //    a control in its own right. The iPad's is a *tap target that opens the
    //    jump alert*, i.e. a third way to do exactly what the two chevrons
    //    beside it do, so it belongs in their cluster.
    //
    // When the chevrons drop out below 590pt the pod degrades to `[1/N]`, which
    // is still the same one semantic cluster — "page navigation".
    private var showPageChevrons: Bool { toolbarWidth == 0 || toolbarWidth >= 590 }
    private var showActionsPod: Bool { toolbarWidth == 0 || toolbarWidth >= 660 }
    // At the 240pt pane floor, Close (52), Help + Settings + More (144), the
    // spacer and HStack gaps (20), and horizontal insets (24) use exactly 240pt.
    // Navigation and Sidebar return together once their widest compact form fits;
    // every hidden action remains available from More.
    private var showNavigationAndSidebar: Bool {
        toolbarWidth == 0 || toolbarWidth >= 400
    }
    private var isBookmarked: Bool {
        findCurrentBookmark(
            annotations: annotationStore.annotations,
            docKind: appStore.document?.kind,
            currentPage: appStore.currentPage,
            webVisibleBookmarks: appStore.webVisibleBookmarks
        ) != nil
    }

    // GROUPING, VERIFIED ON iPadOS 26 (#129 packet 7 §2.10 item 2).
    //
    // main's toolbar has to switch the system's shared background off
    // (`.sharedBackgroundVisibility(.hidden)` on the containing `ToolbarItem`)
    // or AppKit wraps the whole HStack in one more capsule and the pods read as
    // a single blob. There is no counterpart to disable here, and the reason is
    // worth writing down so nobody goes looking for one:
    //
    //  * this row is NOT a system `.toolbar` — `PaneView_iOS.content` puts it in
    //    a bare `VStack(spacing: 0)` above the viewer — so no toolbar chrome
    //    ever wraps it;
    //  * on iPadOS, sibling `.glassEffect` capsules only fuse when they are
    //    inside a `GlassEffectContainer` and closer together than its `spacing`.
    //    This row deliberately has no container, so each pod samples and renders
    //    its own capsule and nothing can merge. That is the native expression of
    //    main's `.hidden`, and it is why the 8pt inter-pod gap below is safe.
    //
    // If a `GlassEffectContainer` is ever added here (it buys one shared
    // sampling pass), it MUST be `spacing: 0` — anything larger re-creates the
    // blob main spent a review round removing.
    var body: some View {
        HStack(spacing: 8) {
            // Leading pod: close current tab (return to library when last).
            GlassToolPod(label: "Tab") {
                GlassToolButton(system: "chevron.backward", label: "Close") {
                    if let id = appStore.activeTabId {
                        Task { await appStore.closeTab(id) }
                    }
                }
            }

            if showNavigationAndSidebar {
                if isWeb {
                    GlassToolPod(label: "Page history") {
                        GlassToolButton(system: "arrow.left", label: "Back") {
                            webHistory(-1)
                        }
                        GlassToolButton(system: "arrow.right", label: "Forward") {
                            webHistory(1)
                        }
                    }
                } else {
                    GlassToolPod(label: "Page navigation") {
                        if showPageChevrons {
                            GlassToolButton(system: "chevron.left", label: "Previous page") {
                                appStore.goToPage(appStore.currentPage - 1)
                            }
                        }
                        pageField
                        if showPageChevrons {
                            GlassToolButton(system: "chevron.right", label: "Next page") {
                                appStore.goToPage(appStore.currentPage + 1)
                            }
                        }
                    }
                }
            }

            if showZoomPod {
                GlassToolPod(label: "Zoom controls") {
                    GlassToolButton(system: "minus.magnifyingglass", label: "Zoom out") {
                        appStore.zoomOut()
                    }
                    Button {
                        appStore.setZoom(1.0)
                        appStore.zoomToHandler?(1.0)
                    } label: {
                        Text("\(Int((appStore.zoom * 100).rounded()))%")
                            .font(.system(size: 14, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(palette.foreground)
                            .frame(minWidth: 52, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    // Label-width pill (`width: nil`): this slot is 52-72pt wide
                    // depending on how many digits the zoom has, so a fixed 40pt
                    // capsule would sit visibly narrower than its own text.
                    .buttonStyle(ToolbarPressStyle(width: nil))
                    .accessibilityLabel("Reset zoom to 100%")
                    GlassToolButton(system: "plus.magnifyingglass", label: "Zoom in") {
                        appStore.zoomIn()
                    }
                }
            }

            Spacer(minLength: 4)

            if showActionsPod {
                GlassToolPod(label: "Annotation tools") {
                    GlassToolButton(system: "magnifyingglass", label: "Find") {
                        appStore.findVisible ? appStore.hideFind() : appStore.showFind()
                    }
                    GlassToolButton(
                        system: "note.text", label: "Sticky note tool",
                        active: appStore.mode == .note
                    ) {
                        ink.isActive = false
                        appStore.setMode(appStore.mode == .note ? .view : .note)
                    }
                    if !isWeb {
                        GlassToolButton(
                            system: "pencil.tip.crop.circle", label: "Apple Pencil ink",
                            active: ink.isActive
                        ) {
                            if !ink.isActive { appStore.setMode(.view) }
                            ink.isActive.toggle()
                        }
                    }
                    GlassToolButton(
                        system: isBookmarked ? "bookmark.fill" : "bookmark",
                        label: isBookmarked ? "Remove bookmark" : "Bookmark",
                        tint: isBookmarked ? palette.gold : nil
                    ) {
                        Task { await annotationStore.toggleBookmark() }
                    }
                }
            }

            GlassToolPod(label: "Panel and document actions") {
                GlassToolButton(system: "questionmark.circle", label: "Help") {
                    showHelp = true
                }
                GlassToolButton(system: "gearshape", label: "Settings") {
                    workspace.settingsSection = .general
                    showSettings = true
                }
                if showNavigationAndSidebar {
                    GlassToolButton(
                        system: "sidebar.right", label: "Toggle sidebar",
                        active: workspace.sidebarOpen
                    ) {
                        workspace.sidebarOpen.toggle()
                    }
                }
                moreMenu
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            toolbarWidth = width
        }
        .alert("Go to page", isPresented: $showPageJump) {
            TextField("Page", text: $pageFieldText)
                .keyboardType(.numberPad)
            Button("Go", action: commitPageField)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a page number (1–\(appStore.numPages)).")
        }
        // Extracted to `SettingsSheet_iOS` so this and Home's gear button
        // present the identical sheet — including the environment injections a
        // `.sheet` does not reliably inherit across the UIHostingController
        // boundary — and cannot drift apart.
        .sheet(isPresented: $showSettings) { SettingsSheet_iOS() }
        .sheet(isPresented: $showHelp) { HelpCenterView_iOS() }
        .sheet(isPresented: $showExportBundle) {
            ExportBundleSheet_iOS(
                title: appStore.document?.title,
                isWeb: isWeb
            ) { includeConversations in
                exportActions.startBundleExport(
                    app: appStore, ai: aiStore, includeConversations: includeConversations)
            }
        }
    }

    /// Tappable "p / N" indicator that opens a jump prompt.
    ///
    /// main hides the `/ N` `Text` from VoiceOver (`.accessibilityHidden(true)`)
    /// because on AppKit the counter is a sibling of the editable page field and
    /// would otherwise be announced as a second element, reading the digits
    /// twice. There is no counterpart here and there must not be one: both
    /// `Text`s live inside a single `Button` label, so SwiftUI already merges
    /// them into one accessibility element, and the explicit `accessibilityLabel`
    /// below replaces their combined description outright. Hiding the second
    /// `Text` would be a no-op at best and, if the label were ever dropped,
    /// would silently lose the page count.
    private var pageField: some View {
        Button {
            pageFieldText = String(appStore.currentPage)
            showPageJump = true
        } label: {
            HStack(spacing: 4) {
                Text("\(appStore.currentPage)")
                    .foregroundStyle(palette.foreground)
                Text("/ \(appStore.numPages)")
                    .foregroundStyle(palette.mutedForeground)
            }
            .font(.system(size: 15, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 10)
            .frame(minWidth: 64, minHeight: 44)
            .contentShape(Rectangle())
        }
        // Label-width pill: four-digit page counts widen this slot well past
        // the 40pt icon pill.
        .buttonStyle(ToolbarPressStyle(width: nil))
        .accessibilityLabel("Page \(appStore.currentPage) of \(appStore.numPages). Tap to jump.")
    }

    private var moreMenu: some View {
        Menu {
            if !showNavigationAndSidebar {
                if isWeb {
                    Button { webHistory(-1) } label: {
                        Label("Back", systemImage: "arrow.left")
                    }
                    Button { webHistory(1) } label: {
                        Label("Forward", systemImage: "arrow.right")
                    }
                } else {
                    Button { appStore.goToPage(appStore.currentPage - 1) } label: {
                        Label("Previous Page", systemImage: "chevron.left")
                    }
                    Button {
                        pageFieldText = String(appStore.currentPage)
                        showPageJump = true
                    } label: {
                        Label("Go to Page…", systemImage: "number")
                    }
                    Button { appStore.goToPage(appStore.currentPage + 1) } label: {
                        Label("Next Page", systemImage: "chevron.right")
                    }
                }
                Button {
                    workspace.sidebarOpen.toggle()
                } label: {
                    Label(
                        workspace.sidebarOpen ? "Hide Sidebar" : "Show Sidebar",
                        systemImage: "sidebar.right")
                }
                Divider()
            } else if !isWeb, !showPageChevrons {
                Button { appStore.goToPage(appStore.currentPage - 1) } label: {
                    Label("Previous Page", systemImage: "chevron.left")
                }
                Button { appStore.goToPage(appStore.currentPage + 1) } label: {
                    Label("Next Page", systemImage: "chevron.right")
                }
                Divider()
            }
            // When the pane is too narrow to show the actions pod, its controls
            // live here so Find / Note / Ink / Bookmark stay reachable.
            if !showActionsPod {
                Button {
                    appStore.findVisible ? appStore.hideFind() : appStore.showFind()
                } label: { Label("Find", systemImage: "magnifyingglass") }
                Button {
                    ink.isActive = false
                    appStore.setMode(appStore.mode == .note ? .view : .note)
                } label: {
                    Label(
                        appStore.mode == .note ? "Exit Sticky Note Tool" : "Sticky Note",
                        systemImage: "note.text")
                }
                if !isWeb {
                    Button {
                        if !ink.isActive { appStore.setMode(.view) }
                        ink.isActive.toggle()
                    } label: {
                        Label(
                            ink.isActive ? "Exit Apple Pencil Ink" : "Apple Pencil Ink",
                            systemImage: "pencil.tip.crop.circle")
                    }
                }
                Button {
                    Task { await annotationStore.toggleBookmark() }
                } label: {
                    Label(
                        isBookmarked ? "Remove Bookmark" : "Bookmark",
                        systemImage: isBookmarked ? "bookmark.fill" : "bookmark")
                }
                Divider()
            }
            Button(action: onOpenFile) { Label("Open File…", systemImage: "folder") }
            Button(action: onAddWebpage) { Label("Add Webpage…", systemImage: "globe") }
            if !isWeb {
                Button {
                    if let id = appStore.activeTabId {
                        Task { try? await appStore.sessions.saveFile(sessionId: id) }
                    }
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
            }
            if isWeb {
                Button {
                    exportActions.toggleSavedPage(app: appStore, ai: aiStore)
                } label: {
                    Label(
                        exportActions.pageSaved ? "Remove Offline Copy" : "Save for Offline Use",
                        systemImage: exportActions.pageSaved
                            ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityIdentifier("toolbar.saveForOffline")
                Button {
                    exportActions.exportVellumweb(app: appStore, ai: aiStore)
                } label: {
                    Label("Export a Copy…", systemImage: "square.and.arrow.up")
                }
                .disabled(exportActions.exporting)
            }
            // Offered for BOTH PDF and web documents. Shorter title than the
            // Mac's "Export Vellum Bundle with Notes…" — it reads better in a
            // compact iPad menu — but the accessibility identifier is identical
            // so shared automation matches.
            if appStore.document != nil {
                Button { showExportBundle = true } label: {
                    Label("Export with Notes…", systemImage: "arrow.up.doc")
                }
                .disabled(exportActions.exportingBundle)
                .accessibilityIdentifier("toolbar.exportWithNotes")
            }
            if !showZoomPod {
                Divider()
                Button { appStore.zoomIn() } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                Button { appStore.zoomOut() } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                Button {
                    appStore.setZoom(1.0)
                    appStore.zoomToHandler?(1.0)
                } label: {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
            }
            Divider()
            // Split-screen: this menu belongs to a pane, and tapping it focuses
            // that pane (the pane's touch catcher fires first), so the focused-
            // pane operations below always target the pane the menu lives in.
            Button {
                workspace.splitFocused(.horizontal)
            } label: { Label("Split Right", systemImage: "rectangle.split.2x1") }
            Button {
                workspace.splitFocused(.vertical)
            } label: { Label("Split Down", systemImage: "rectangle.split.1x2") }
            if workspace.isSplit {
                Button {
                    workspace.mergeAll()
                } label: { Label("Merge Panes", systemImage: "rectangle") }
                Button {
                    workspace.closePane(workspace.focusedPaneId)
                } label: { Label("Close Pane", systemImage: "xmark.rectangle") }
            }
            // Only for a document that maps back to a read-later item — the
            // reader's route to refiling an article without leaving it.
            if let path = appStore.document?.pdfPath,
               let item = integrations.readLaterItem(forOpenDocumentPath: path) {
                Divider()
                MoveToCollectionMenu(item: item, integrations: integrations)
            }
        } label: {
            // DO NOT port main's ZStack trick here (#129 packet 7 §2.10 G4).
            // On AppKit a menu control paints its own hover highlight *beneath*
            // any attached background, so main draws the glyph and the pill as
            // ZStack siblings and drops the `Menu` itself to `.opacity(0.02)` as
            // a transparent-but-still-hit-testable target. UIKit menus paint no
            // such highlight under an attached background, so copying that would
            // buy nothing and make this glyph 2% opaque. The system's own
            // menu-open highlight is the touch feedback; `contentShape` below
            // keeps the whole 44pt slot tappable, which is the part that matters.
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(palette.foreground)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More actions")
        // Toolbar state (offline-copy flag) resets whenever the active tab or
        // its backing document changes.
        .task(id: DocumentKey_iOS(appStore)) {
            await exportActions.loadSavedState(app: appStore, for: DocumentKey_iOS(appStore))
        }
    }

    /// In-page history for web tabs — same channel the macOS toolbar uses.
    private func webHistory(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }

    private func commitPageField() {
        let trimmed = pageFieldText.trimmingCharacters(in: .whitespaces)
        if let page = Int(trimmed) {
            appStore.goToPage(page)
        }
        pageFieldText = String(appStore.currentPage)
    }
}

/// The `.vellum` export options. macOS puts this one checkbox in the save
/// panel's accessoryView; iOS has no save panel, so the choice is made in a
/// sheet and the finished bundle is handed to the Files export picker.
struct ExportBundleSheet_iOS: View {
    var title: String?
    var isWeb: Bool
    var onExport: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    // Conversations are semi-private: sharing them is explicit, so OFF.
    @State private var includeConversations = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Include AI conversation", isOn: $includeConversations)
                        .accessibilityIdentifier("export.includeConversation")
                } header: {
                    Text("Include")
                } footer: {
                    Text("The \(isWeb ? "page" : "document"), your notes and their images, and "
                         + "your highlights are always included. The AI conversation is not, "
                         + "unless you turn it on.")
                }
            }
            .navigationTitle("Export with Notes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Export") { onExport(includeConversations); dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - Glass tool primitives

// GEOMETRY, AND WHY IT IS NOT main's (#129 packet 7 §2.10 G5).
//
// The Mac toolbar is built for a cursor: 32x35 hit frames, a 32x26 interaction
// pill, 35pt capsules. Those numbers are measurements, not a design, and they
// do not survive a finger. The iPad's rhythm is deliberately larger and is the
// hard floor for this file:
//
//   button slot   44 x 44   (HIG minimum; never shrink to match main)
//   press pill    40 x 36   (inset inside the slot so it reads as sitting
//                            *within* the pod's glass, not filling it)
//   pod capsule   48pt tall, 4pt horizontal padding, 2pt between buttons
//   between pods  8pt
//
// Everything else about the language is main's and is kept: one capsule per
// semantic cluster, an accessibility container per capsule, monochrome glyphs,
// hit area = the whole slot, and a single shared interaction backdrop shape.

/// The shared interaction backdrop for every toolbar button — the touch
/// analogue of the macOS toolbar's hover pill (main PR #115). One shape
/// everywhere so the nine controls read as one system.
///
/// `Color.primary` is deliberate and *concrete*, NOT the hierarchical `.primary`
/// shape style: the hierarchical one resolves against the button label's
/// `foregroundStyle`, which on macOS rendered the bookmark's pill at ~40%
/// strength through its gold tint. The bookmark button here carries the same
/// gold `tint`, so the same trap applies.
///
/// `width: nil` lets the pill track its label instead — used by the two
/// text buttons (zoom percentage, page indicator), whose slots are wider than
/// an icon's and grow with the digit count.
private struct ToolbarPressBackdrop: View {
    let visible: Bool
    var width: CGFloat? = 40
    var strength: Double = 0.10
    var body: some View {
        Capsule()
            .fill(Color.primary.opacity(visible ? strength : 0))
            .frame(width: width, height: 36)
    }
}

/// Reports `isPressed` so the shared backdrop can render it. `.plain` alone
/// gives no touch feedback at all, and `.borderless`/`.bordered` bring back
/// system chrome that fights the pod's glass.
///
/// iPadOS has no hover, so this replaces main's `.onHover` pill outright rather
/// than supplementing it — there is nothing to port on the hover side.
private struct ToolbarPressStyle: ButtonStyle {
    var width: CGFloat? = 40
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background { ToolbarPressBackdrop(visible: configuration.isPressed, width: width) }
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A Liquid Glass capsule that groups related buttons into one pod.
struct GlassToolPod<Content: View>: View {
    /// VoiceOver name for the whole capsule. Applied OUTSIDE `.glassEffect()`:
    /// the glass wraps its content in one more accessibility group, and a label
    /// applied inside it never surfaces — the group then falls back to
    /// inheriting its first child's description ("Previous page" announced for
    /// every cluster, as measured on macOS in PR #115). Required, not defaulted,
    /// so a new pod cannot be added without naming itself.
    var label: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 2) { content() }
            .padding(.horizontal, 4)
            .frame(height: 48)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }
}

/// A 44pt touch icon button; tints/fills when active.
struct GlassToolButton: View {
    let system: String
    let label: String
    var active = false
    var tint: Color? = nil
    var disabled = false
    let action: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: 44, height: 44)
                .background {
                    if active {
                        // The selected state stays a Button with a stronger
                        // persistent fill rather than a Toggle: a Toggle brings
                        // its own system chrome back (the squished press shape
                        // this pass removes) and its selected state cannot be
                        // drawn through the shared backdrop.
                        //
                        // Active keeps `palette.primary` (the app accent). That
                        // is the iPad's selected-state convention and — unlike
                        // the hierarchical `.primary` shape style — it is not
                        // resolved through the label's `foregroundStyle`, so the
                        // gold-bookmark dilution that forced macOS onto
                        // `Color.primary` does not apply. Same Capsule as the
                        // press pill, same 40x36, so the two states share a
                        // silhouette instead of a circle fighting a capsule.
                        Capsule().fill(palette.primary.opacity(0.16))
                            .frame(width: 40, height: 36)
                    }
                }
                // Rectangle, not Circle: the hit area is the whole slot. A
                // circular shape inscribed in 44x44 throws away the corners —
                // ~21% of the nominal target — which is exactly the "hit-tests
                // only the glyph" failure main measured at 6.5pt-wide chevrons.
                .contentShape(Rectangle())
        }
        .buttonStyle(ToolbarPressStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.35 : 1)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
    }

    private var foreground: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return active ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground)
    }
}

// MARK: - Tab strip

struct TabStrip_iOS: View {
    /// The pane this strip belongs to — carried in the tab drag payload so a
    /// drop on another pane knows where the tab came from.
    let paneId: String
    var onNewTab: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var joinTargeted = false
    @State private var showingOverview = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(appStore.tabs) { tab in
                        TabChip_iOS(tab: tab, paneId: paneId, isActive: tab.id == appStore.activeTabId)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }

            // Both trailing controls sit OUTSIDE the ScrollView. `+` used to be
            // inside it, which meant it scrolled away once a pane held enough
            // tabs to overflow — the one moment the overview is most useful.
            // (iPad-only fix; the macOS strip already pins them.)
            Button { showingOverview.toggle() } label: {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Show all tabs")
            .accessibilityIdentifier("tabBar.overview")
            .popover(isPresented: $showingOverview) {
                TabOverview_iOS(
                    tabs: workspace.allTabs,
                    onActivate: { tab in
                        workspace.activateWorkspaceTab(paneId: tab.paneId, tabId: tab.tab.id)
                        showingOverview = false
                    },
                    onClose: { tab in
                        Task { await workspace.closeWorkspaceTab(paneId: tab.paneId, tabId: tab.tab.id) }
                    }
                )
                .environment(workspace)
            }

            Button(action: onNewTab) {
                Image(systemName: "plus")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(palette.mutedForeground)
                    // 44pt, matching the chips beside it: this was the one
                    // control in the reading chrome under the HIG minimum.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("New tab")
            .accessibilityIdentifier("tabBar.newTab")
            .padding(.trailing, 8)
        }
        .background(.bar)
        // Dropping a tab onto this strip moves it into this pane's group. When
        // it empties the source pane, that pane collapses — this is how you undo
        // a split: drag one pane's tab into the other pane's tab strip.
        .background {
            if joinTargeted && workspace.draggingTab != nil {
                Rectangle().fill(palette.primary.opacity(0.16))
            }
        }
        .onDrop(of: [.vellumTab], isTargeted: $joinTargeted) { providers in
            guard let provider = providers.first else { return false }
            let targetPane = paneId
            let workspace = self.workspace
            _ = provider.loadDataRepresentation(for: .vellumTab) { data, _ in
                guard let data,
                      let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data) else { return }
                Task { @MainActor in
                    workspace.moveTab(tabId: payload.tabId, from: payload.paneId, to: targetPane)
                    workspace.endTabDrag()
                }
            }
            return true
        }
    }
}

private struct TabChip_iOS: View {
    let tab: PdfTab
    let paneId: String
    let isActive: Bool

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    /// The tab whose rename sheet is open — nil the rest of the time.
    @State private var renamingTab: PdfTab?

    /// Kept as the chip's OWN derivation rather than routing through
    /// `TabPresentation.title(for:)`: this prettifies an untitled webpage's URL
    /// into a host/slug, which main's helper does not. See the note on
    /// `TabPresentation` for why the overview uses the other one (packet 4
    /// §2.12.1 — smaller blast radius, and the two agree for every PDF).
    private var title: String {
        if let doc = tab.document {
            if doc.kind == .web {
                return RecentFilesService.webpageDisplayName(for: doc.pdfPath)
            }
            return doc.title ?? RecentFilesService.fileName(for: doc.pdfPath)
        }
        return "New Tab"
    }

    /// An interaction this tab armed and has not finished — note placement, a
    /// queued AI reply, or a drag-to-crop destination. All three now travel with
    /// the tab (§2.1), so the dot stays truthful while another tab is on screen.
    private var hasPendingAction: Bool {
        tab.mode != .view || tab.pendingNoteContent != nil || tab.regionCaptureTarget != nil
    }

    private var isLastTab: Bool { appStore.tabs.last?.id == tab.id }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: { appStore.activateTab(tab.id) }) {
                HStack(spacing: 6) {
                    Image(systemName: tab.document?.kind == .web ? "globe" : "doc.text")
                        .font(.system(size: 12))
                        .foregroundStyle(
                            isActive ? AnyShapeStyle(palette.primary) : AnyShapeStyle(.secondary))
                    Text(title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        .lineLimit(1)
                        .foregroundStyle(isActive ? palette.foreground : palette.mutedForeground)
                        .frame(maxWidth: 160)
                    if hasPendingAction {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("tabBar.tab.\(tab.id)")
            // Concatenated, not replaced: the selected state is what VoiceOver
            // uses to tell the current tab from the rest.
            .accessibilityValue(
                [isActive ? "Selected" : "", hasPendingAction ? "Action pending" : ""]
                    .filter { !$0.isEmpty }
                    .joined(separator: ", "))

            Button {
                Task { await appStore.closeTab(tab.id) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(title)")
            .accessibilityIdentifier("tabBar.close.\(tab.id)")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(height: 44)
        .selectionSurface(selected: isActive, in: Capsule(), palette: palette)
        // Long-press lifts the chip into a drag; dropping on another pane's
        // strip joins that group, dropping on a pane edge splits it.
        .onDrag {
            let payload = TabDragPayload(paneId: paneId, tabId: tab.id)
            workspace.beginTabDrag(payload)
            let provider = NSItemProvider()
            if let data = try? JSONEncoder().encode(payload) {
                provider.registerDataRepresentation(
                    forTypeIdentifier: UTType.vellumTab.identifier, visibility: .ownProcess
                ) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        }
        // ONE context menu. Two `.contextMenu` modifiers on the same view do not
        // compose — the outer replaces the inner — so rename and the tab
        // management actions have to be built together here.
        //
        // ⚠ `.contextMenu` and `.onDrag` both key off long-press on iOS. They
        // coexist (drag = press-then-move, menu = press-and-hold), but dragging
        // a tab between panes is the iPad's only way to split or unsplit, so
        // that gesture is the one to re-check after touching either.
        .contextMenu {
            // Rename lives here rather than on the toolbar's title field: that
            // field shows the FILENAME for a PDF and the URL for a page, so
            // editing it would read as renaming the file or navigating. The tab
            // is the one place the document's title is actually rendered.
            if tab.document != nil {
                Button("Rename…") { renamingTab = tab }
            }
            Button("Duplicate") { Task { await appStore.duplicateTab(tab.id) } }
                .disabled(tab.document?.kind == .pdf)
            Button("Move to New Pane") {
                workspace.splitWithTab(
                    tabId: tab.id, from: paneId, target: paneId,
                    direction: .horizontal, before: false)
            }
            .disabled(appStore.tabs.count < 2)

            Divider()

            // No "Reveal in Finder" counterpart — iPadOS has none, and a
            // Files-app reveal is a different feature, not a substitute.
            if tab.document?.kind == .web {
                Button("Copy Link") { UIPasteboard.general.string = tab.document?.pdfPath }
            }

            Divider()

            Button("Close Tab", role: .destructive) {
                Task { await appStore.closeTab(tab.id) }
            }
            Button("Close Others") { Task { await appStore.closeOtherTabs(keeping: tab.id) } }
                .disabled(appStore.tabs.count < 2)
            Button("Close Tabs to Right") { Task { await appStore.closeTabsToRight(of: tab.id) } }
                .disabled(isLastTab)
        }
        .sheet(item: $renamingTab) { renaming in
            RenameDocumentSheet_iOS(
                currentTitle: renaming.document?.title ?? "",
                fallbackName: TabPresentation.fallbackName(for: renaming),
                commit: { newTitle in
                    Task { await appStore.renameDocument(tabId: renaming.id, title: newTitle) }
                })
        }
    }
}

// MARK: - Tab overview (all tabs, every pane)

/// Searchable list of every open tab in the window, across panes. Reached from
/// the strip's `rectangle.stack` button.
private struct TabOverview_iOS: View {
    let tabs: [WorkspaceTab]
    let onActivate: (WorkspaceTab) -> Void
    let onClose: (WorkspaceTab) -> Void

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var query = ""

    private var filteredTabs: [WorkspaceTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tabs }
        return tabs.filter {
            TabPresentation.title(for: $0.tab)
                .localizedStandardContains(needle)
                || TabPresentation.typeLabel(for: $0.tab)
                .localizedStandardContains(needle)
                || $0.paneLabel.localizedStandardContains(needle)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("All Tabs")
                .font(.headline)

            TextField("Search tabs", text: $query)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("tabOverview.search")

            if filteredTabs.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(filteredTabs) { tab in
                            row(tab)
                        }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
        .padding(14)
        // macOS pins this at 360. On iPad the popover has to survive a compact
        // Split View pane, so it states an ideal instead of a fixed width — and
        // `.presentationCompactAdaptation(.popover)` keeps it a popover rather
        // than letting it become a full-screen sheet there.
        .frame(minWidth: 360, idealWidth: 380)
        .presentationCompactAdaptation(.popover)
    }

    @ViewBuilder
    private func row(_ tab: WorkspaceTab) -> some View {
        HStack(spacing: 8) {
            Button { onActivate(tab) } label: {
                HStack(spacing: 8) {
                    Image(systemName: TabPresentation.iconName(for: tab.tab))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TabPresentation.title(for: tab.tab))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(tab.paneLabel) · \(TabPresentation.typeLabel(for: tab.tab))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if isFocusedActive(tab) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(palette.primary)
                            .accessibilityLabel("Current tab")
                    }
                    if isPending(tab) {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                // 10pt of vertical padding around a two-line title clears the
                // 44pt touch minimum without the row looking airy.
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(TabPresentation.title(for: tab.tab)), "
                    + "\(tab.paneLabel), \(TabPresentation.typeLabel(for: tab.tab))"
                    + (isPending(tab) ? ", action pending" : ""))
            .accessibilityIdentifier("tabOverview.tab.\(tab.id)")

            Button { onClose(tab) } label: {
                Image(systemName: "xmark")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close \(TabPresentation.title(for: tab.tab))")
            .accessibilityIdentifier("tabOverview.close.\(tab.id)")
        }
        .padding(.horizontal, 8)
        .background(
            isFocusedActive(tab) ? palette.primary.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private func isPending(_ tab: WorkspaceTab) -> Bool {
        tab.tab.mode != .view || tab.tab.pendingNoteContent != nil || tab.tab.regionCaptureTarget != nil
    }

    private func isFocusedActive(_ tab: WorkspaceTab) -> Bool {
        tab.paneId == workspace.focusedPaneId && tab.tab.id == workspace.focusedPane.app.activeTabId
    }
}

// MARK: - Sidebar content (hosted by the adaptive inspector)

struct SidebarContent_iOS: View {
    enum Presentation: Equatable {
        case column
        case phoneSheet
    }

    /// The focused pane's ink controller, from the registry — nil only in the
    /// instant before that pane has appeared, so the Handwriting section just
    /// skips rendering rather than holding a stale controller.
    var ink: InkController_iOS?
    var presentation: Presentation = .column
    var onTabSelected: ((WorkspaceStore.SidebarTab) -> Void)? = nil

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotations
    @Environment(\.palette) private var palette

    // "Has this tab ever been revealed?" latches. The sidebar is open by
    // default (WorkspaceStore.sidebarOpen == true) and restoreFromDisk reopens
    // the last document within a few frames of launch, so this view's body ran
    // during the app's *initial frame*. Building all three panels there charged
    // launch for work the user couldn't even see on the default `.annotations`
    // tab: AiPanel_iOS.body plus AiAttributedRenderer, and — the expensive one —
    // ScratchpadLiveEditor.makeUIView -> ScratchpadWebView.init, ~56ms spent
    // spawning a WebKit content process (measured in an Instruments App Launch
    // trace). Gating construction on these latches defers that cost to the
    // first time each tab is actually selected.
    //
    // They only ever flip false -> true, never back, so the mounted-panel
    // behaviour documented on the ZStack below is preserved exactly. Their
    // first frame is a small progress view; the expensive panel is mounted by
    // that view's task on the following update. This lets the tab selection
    // paint immediately instead of making a tap look ignored while WebKit or
    // the AI transcript is being constructed.
    //
    // Plain @State (not a store): this is per-view presentation bookkeeping,
    // discarded with the view and mutated only by view tasks on the main
    // actor. Nothing here needs its own store or persistence.
    @State private var hasShownAi = false
    @State private var hasShownScratchpad = false

    var body: some View {
        let handwritingPages = ink?.handwritingPages ?? []
        VStack(spacing: 0) {
            InspectorTabSwitcher(
                selection: Binding(
                    get: { workspace.sidebarTab },
                    set: { selectTab($0) }))
            .padding(.horizontal, InspectorLayout.switcherHorizontalPadding)
            .padding(.vertical, InspectorLayout.switcherVerticalPadding)
            Divider()
            // Once revealed, a panel stays mounted; only visibility toggles as
            // the tab changes. Keeping them alive (rather than switching, which
            // destroys the inactive ones) preserves each panel's transient view
            // state across tab flips — the scratchpad editor's caret/scroll/
            // selection in its live-preview WebView (a reload on every visit
            // would flash and lose the caret), and the AI panel's scroll/
            // composer draft. The persisted text itself already survives via the
            // stores; this keeps the *view* state the stores don't hold.
            //
            // Annotations is unconditional: it's the default tab and costs
            // nothing beyond plain SwiftUI rows. AI and Scratchpad are built
            // lazily on first reveal (see the latches above) because their
            // bodies are what dragged WebKit and the AI renderer into launch.
            ZStack {
                panel(.annotations) {
                    if presentation == .phoneSheet,
                       annotations.annotations.isEmpty,
                       handwritingPages.isEmpty {
                        ContentUnavailableView {
                            Label("No annotations yet", systemImage: "highlighter")
                        } description: {
                            Text("Select text to highlight it, or start a sticky note on the page.")
                        } actions: {
                            Button("Start a sticky note", systemImage: "note.text") {
                                app.setMode(.note)
                                workspace.setInspectorPresented(false)
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .accessibilityIdentifier("phone.inspector.annotations.empty")
                    } else {
                        VStack(spacing: 0) {
                            InkPagesSection_iOS(pages: handwritingPages)
                            AnnotationSidebar()
                        }
                    }
                }
                if hasShownAi {
                    panel(.ai) { AiPanel_iOS() }
                } else if workspace.sidebarTab == .ai {
                    ProgressView("Preparing AI…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("sidebar.ai.loading")
                        .task {
                            await Task.yield()
                            guard !Task.isCancelled, workspace.sidebarTab == .ai else { return }
                            hasShownAi = true
                        }
                }
                if hasShownScratchpad {
                    panel(.scratchpad) { ScratchpadPanel() }
                } else if workspace.sidebarTab == .scratchpad {
                    ProgressView("Preparing Scratchpad…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityIdentifier("sidebar.scratchpad.loading")
                        .task {
                            await Task.yield()
                            guard !Task.isCancelled, workspace.sidebarTab == .scratchpad else { return }
                            hasShownScratchpad = true
                        }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(palette.surface)
    }

    /// Selects immediately. A first-time AI/Scratchpad destination initially
    /// renders its progress view above, then mounts the expensive panel on the
    /// following update.
    private func selectTab(_ tab: WorkspaceStore.SidebarTab) {
        if let onTabSelected {
            onTabSelected(tab)
        } else {
            workspace.sidebarTab = tab
        }
    }

    /// Wraps a sidebar panel so only the active tab is visible, hit-testable,
    /// and exposed to accessibility — the inactive panels stay mounted but
    /// inert (mirrors macOS `WindowChrome.panel`).
    @ViewBuilder
    private func panel<Content: View>(
        _ tab: WorkspaceStore.SidebarTab,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let isActive = workspace.sidebarTab == tab
        content()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
    }
}

/// Handwritten-ink summary for the annotations sidebar: one jump-to-page row
/// per inked page. Ink lives outside the shared Annotation model (it's stored
/// as native /Ink in the PDF), so this section derives straight from the
/// display document.
private struct InkPagesSection_iOS: View {
    var pages: [Int]

    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    var body: some View {
        if !pages.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Handwriting")
                    .font(.caption.bold())
                    .foregroundStyle(palette.mutedForeground)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(pages, id: \.self) { page in
                            Button {
                                appStore.goToPage(page)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "pencil.and.scribble")
                                        .font(.system(size: 11))
                                        .foregroundStyle(palette.primary)
                                    Text("p. \(page)")
                                        .font(.caption.weight(.medium))
                                        .monospacedDigit()
                                        .foregroundStyle(palette.foreground)
                                }
                                .padding(.horizontal, 12)
                                .frame(minWidth: 44, minHeight: 44)
                                .background(palette.muted, in: Capsule())
                                .overlay(Capsule().strokeBorder(palette.border))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Handwriting on page \(page). Tap to jump.")
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
#endif
