#if os(iOS)
import SwiftUI

// The iPhone reader's chrome (#153 P5): two floating glass capsule bars over a
// full-bleed document, a legibility scrim behind them, and an immersive mode
// driven by document taps and directional scrolling, with no reveal affordance.
//
// The iPad's `PdfToolbar_iOS` is a docked row that OWNS a strip of the pane; on
// a 390pt screen a docked row is a tax paid on every page. So the phone floats
// its controls instead, in the same `GlassToolPod` / `GlassToolButton` language
// (the 44pt slot and the 48pt capsule are the iPad's numbers and are not
// re-derived here — see `PdfChrome_iOS`'s geometry note), and gets the strip
// back after deliberate travel toward later content.

// MARK: - Geometry

/// Every number the phone chrome uses, in one place.
///
/// This exists so `PhoneChromeLayoutTests` can assert against the layout the
/// bars actually use rather than against a copy of it. The last time a layout
/// suite in this repo mirrored a dozen padding constants it went two points out
/// of date and failed pointing at the wrong file (`WalkthroughLayoutTests`'s
/// header says so at length). Nothing below may be inlined at a call site.
enum PhoneChromeLayout {
    /// Height of a glass capsule. Same 48pt as `GlassToolPod` — deliberately
    /// the same value rather than a second opinion about it.
    static let capsuleHeight: CGFloat = 48

    /// A touch slot. HIG minimum, and the floor every interactive element in
    /// the chrome is measured against.
    static let buttonSide: CGFloat = 44

    /// Gap between two capsules in the same bar.
    static let podGap: CGFloat = 8

    /// One-button GlassToolPod width: 44pt target + 4pt padding per side.
    static let singleButtonPodWidth: CGFloat = buttonSide + 8

    /// Distance from the screen edge to the outermost capsule.
    static let edgeInset: CGFloat = 8

    /// Gap between a bar and the safe-area edge it hugs. Small on purpose: the
    /// safe area already holds the status bar and the home indicator away.
    static let barEdgeGap: CGFloat = 6

    /// How far a bar slides toward its edge while fading out. Just enough to
    /// read as leaving rather than blinking.
    static let slide: CGFloat = 10

    /// Chrome show/hide duration.
    static let animationDuration: Double = 0.22

    /// The one animation for everything that fades with the chrome — bars and
    /// scrim alike, so they can never drift apart mid-transition.
    static var animation: Animation { .easeOut(duration: animationDuration) }

    /// Scrim depth behind the top bar. The gradient's opaque end is at the
    /// screen edge and it reaches zero by this depth.
    static let topScrimHeight: CGFloat = 132

    /// Scrim depth behind the bottom bar. Taller than the top's because the
    /// bottom bar is taller in practice (three capsules and the home indicator
    /// beneath them).
    static let bottomScrimHeight: CGFloat = 148

    /// Peak opacity of either scrim, at the screen edge.
    static let scrimOpacity: Double = 0.34

    /// The shortest screen this shell claims to support: iPhone SE (2nd/3rd
    /// gen) at 375×667. Everything narrower is out of contract.
    static let shortestSupportedScreenHeight: CGFloat = 667

    /// Narrowest supported width, same device.
    static let narrowestSupportedWidth: CGFloat = 375

    /// The most of the page the chrome may darken. Above roughly a third, the
    /// scrim stops being a legibility aid and becomes a vignette the reader
    /// notices — and on a 667pt screen the two gradients are the largest thing
    /// competing with the text.
    static let maxScrimCoverage: Double = 0.45

    /// Fraction of a screen of `height` that the two scrims cover.
    static func scrimCoverage(screenHeight: CGFloat) -> Double {
        guard screenHeight > 0 else { return 1 }
        return Double((topScrimHeight + bottomScrimHeight) / screenHeight)
    }

    /// Vertical space one bar occupies, capsule plus its edge gap. What a bar's
    /// hosted height is measured against.
    static var barHeight: CGFloat { capsuleHeight + barEdgeGap }
}

// MARK: - Chrome

/// The whole reader chrome: scrim, top bar, find bar, bottom bar — mounted by
/// `PhoneShell_iOS` as a sibling of the live-tab stack (NOT as an overlay on
/// it). The stack ignores the safe area so the hosted `PDFView`'s frame never
/// depends on insets that a presented sheet changes; the chrome must respect
/// the safe area, and an overlay on an ignoring view inherits the ignoring
/// geometry. Siblings in a `ZStack` keep both properties.
struct PhoneReaderChrome_iOS: View {
    var shell: PhoneShellStore
    var onOpenFile: () -> Void
    var onAddWebpage: () -> Void

    @Environment(AppStore.self) private var app

    var body: some View {
        ZStack {
            // Behind everything, and bleeding past the safe area — the scrim's
            // whole job is to darken the page under the status bar and the home
            // indicator, which is exactly where the safe area is not.
            PhoneChromeScrim(visible: shell.chromeVisible)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                PhoneReaderTopBar(shell: shell)
                // The find bar is a docked row even here: it owns the keyboard
                // while it is up, and a floating capsule that the keyboard can
                // cover is not a find bar. It rides with the chrome because
                // `hideFind()` is reachable from its own Done button.
                if app.findVisible {
                    FindBar()
                        .padding(.top, PhoneChromeLayout.barEdgeGap)
                }
                Spacer(minLength: 0)
                PhoneReaderBottomBar(
                    shell: shell, onOpenFile: onOpenFile, onAddWebpage: onAddWebpage)
            }
            .opacity(shell.chromeVisible ? 1 : 0)
            // Hidden chrome must not eat taps meant for the page, and must not
            // be reachable by VoiceOver either — an announced-but-invisible
            // toolbar is worse than no toolbar.
            .allowsHitTesting(shell.chromeVisible)
            .accessibilityHidden(!shell.chromeVisible)
        }
        .animation(PhoneChromeLayout.animation, value: shell.chromeVisible)
    }
}

// MARK: - Scrim

/// Top and bottom gradients that make glass capsules legible over a white PDF
/// page. Not decoration: `.glassEffect` samples what is behind it, and what is
/// behind it here is paper — without the scrim a white capsule sits on white
/// with a hairline border, and the icons inside it lose their contrast floor.
///
/// It fades with the chrome, on the chrome's own animation, because a scrim
/// that outlived the bars would read as a rendering bug.
struct PhoneChromeScrim: View {
    var visible: Bool

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(
                colors: [
                    Color.black.opacity(PhoneChromeLayout.scrimOpacity),
                    Color.black.opacity(0),
                ],
                startPoint: .top, endPoint: .bottom)
                .frame(height: PhoneChromeLayout.topScrimHeight)
            Spacer(minLength: 0)
            LinearGradient(
                colors: [
                    Color.black.opacity(0),
                    Color.black.opacity(PhoneChromeLayout.scrimOpacity),
                ],
                startPoint: .top, endPoint: .bottom)
                .frame(height: PhoneChromeLayout.bottomScrimHeight)
        }
        .opacity(visible ? 1 : 0)
        // A gradient over the document must never intercept a touch — the whole
        // page under it is still the reader's to scroll, select and tap.
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Top bar

/// Back to Home and the document's name. Chrome visibility is driven by direct
/// document interaction, so this bar carries no dedicated Hide button.
///
/// The title is here rather than in the bottom bar because it is the one piece
/// of chrome that answers "where am I", and it pairs with the control that
/// leaves. It is a `Text`, not a button: on the phone there is no second thing
/// tapping a title could mean.
struct PhoneReaderTopBar: View {
    var shell: PhoneShellStore

    @Environment(AppStore.self) private var app
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: PhoneChromeLayout.podGap) {
            GlassToolPod(label: "Navigation") {
                GlassToolButton(system: "chevron.left", label: "Home") {
                    shell.showHome()
                }
                .accessibilityIdentifier("phone.reader.home")
            }

            titleCapsule

            // Mirror the one-button Home pod without adding a control. A
            // flexible Spacer has zero intrinsic width here and shifts the
            // title toward the trailing edge.
            Color.clear
                .frame(
                    width: PhoneChromeLayout.singleButtonPodWidth,
                    height: PhoneChromeLayout.capsuleHeight)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, PhoneChromeLayout.edgeInset)
        .padding(.top, PhoneChromeLayout.barEdgeGap)
    }

    /// `.middle` truncation, not `.tail`: phone-sized titles are dominated by
    /// long PDF filenames and article headlines whose distinguishing half is at
    /// the END ("Attention Is All You Need — Revised.pdf"). Dropping the middle
    /// keeps both ends, which is what makes two similar documents tellable
    /// apart at 200pt.
    private var titleCapsule: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(palette.foreground)
            .lineLimit(1)
            .truncationMode(.middle)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 14)
            .frame(height: PhoneChromeLayout.capsuleHeight)
            .frame(maxWidth: .infinity)
            .glassEffect(.regular, in: .capsule)
            .accessibilityIdentifier("phone.reader.title")
            .accessibilityLabel(title.isEmpty ? "Untitled document" : title)
    }

    private var title: String {
        let raw = app.document?.title ?? ""
        return raw.isEmpty ? "Untitled" : raw
    }
}

// MARK: - Bottom bar

/// The phone-width variant of `GlassToolPod`.
///
/// The shared iPad pod leaves 4pt at each edge and 2pt between controls. Seven
/// web-reader controls cannot fit at 375pt with that desktop-like breathing
/// room, even though their 44pt hit targets do. This variant removes only the
/// decorative interior gaps; target geometry and capsule height stay exactly
/// the same.
private struct PhoneGlassToolPod<Content: View>: View {
    var label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: 0) { content() }
            .padding(.horizontal, 2)
            .frame(height: PhoneChromeLayout.capsuleHeight)
            .glassEffect(.regular, in: .capsule)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(label)
    }
}

/// Everything the reader reaches for with a thumb: where they are in the
/// document, the two annotation tools the phone exposes, and the three ways out
/// (inspector, tabs, more).
///
/// Deliberately absent, per the phase contract: split items (there is one pane
/// by construction, D4), the ink toggle (iPad-made ink renders read-only here),
/// and the zoom pod (the phone reader is fit-width by #152, so an absolute zoom
/// percentage is not a thing the reader owns any more).
struct PhoneReaderBottomBar: View {
    var shell: PhoneShellStore
    var onOpenFile: () -> Void
    var onAddWebpage: () -> Void

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotations
    @Environment(AiStore.self) private var ai
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette

    @State private var pageFieldText = ""
    @State private var showPageJump = false
    @State private var showSettings = false
    @State private var showHelp = false
    @State private var showExportBundle = false
    /// The same object the iPad toolbar holds — see `DocumentExportActions_iOS`
    /// for why the offline-copy toggle and the two exports are shared rather
    /// than retyped here.
    @State private var exportActions = DocumentExportActions_iOS()

    private var isWeb: Bool { app.document?.kind == .web }

    private var isBookmarked: Bool {
        findCurrentBookmark(
            annotations: annotations.annotations,
            docKind: app.document?.kind,
            currentPage: app.currentPage,
            webVisibleBookmarks: app.webVisibleBookmarks
        ) != nil
    }

    var body: some View {
        HStack(spacing: PhoneChromeLayout.podGap) {
            positionPod
            Spacer(minLength: PhoneChromeLayout.podGap)
            markPod
            actionPod
        }
        .padding(.horizontal, PhoneChromeLayout.edgeInset)
        .padding(.bottom, PhoneChromeLayout.barEdgeGap)
        .alert("Go to page", isPresented: $showPageJump) {
            TextField("Page", text: $pageFieldText)
                .keyboardType(.numberPad)
            Button("Go", action: commitPageField)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Enter a page number (1–\(app.numPages)).")
        }
        .sheet(isPresented: $showSettings) { SettingsSheet_iOS() }
        .sheet(isPresented: $showHelp) { HelpCenterView_iOS() }
        .sheet(isPresented: $showExportBundle) {
            ExportBundleSheet_iOS(title: app.document?.title, isWeb: isWeb) { includeConversations in
                exportActions.startBundleExport(
                    app: app, ai: ai, includeConversations: includeConversations)
            }
        }
        // Offline-copy state resets whenever the active tab or its backing
        // document changes — same key the iPad toolbar uses.
        .task(id: DocumentKey_iOS(app)) {
            await exportActions.loadSavedState(app: app, for: DocumentKey_iOS(app))
        }
    }

    /// Where the reader is: the page indicator for PDFs (tap to jump), in-page
    /// history for web pages. One slot, because a web page has no page number
    /// and a PDF has no back button.
    @ViewBuilder
    private var positionPod: some View {
        if isWeb {
            PhoneGlassToolPod(label: "Page history") {
                GlassToolButton(
                    system: "arrow.left", label: "Back", disabled: !canGoBack
                ) { webHistory(-1) }
                GlassToolButton(
                    system: "arrow.right", label: "Forward", disabled: !canGoForward
                ) { webHistory(1) }
            }
        } else {
            PhoneGlassToolPod(label: "Page navigation") {
                Button {
                    pageFieldText = String(app.currentPage)
                    showPageJump = true
                } label: {
                    Text("\(app.currentPage) / \(app.numPages)")
                        .font(.subheadline.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                        // Fixed-width on purpose: a 10,000-page scan must not
                        // push More off a 375pt screen. The label scales within
                        // its slot while VoiceOver receives the full value.
                        .frame(width: 64, height: PhoneChromeLayout.buttonSide)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("phone.reader.page")
                .accessibilityLabel("Page \(app.currentPage) of \(app.numPages). Tap to jump.")
            }
        }
    }

    /// The two annotation tools the phone exposes. Ink is not among them: the
    /// phone has no Pencil, and iPad-made strokes render read-only.
    private var markPod: some View {
        PhoneGlassToolPod(label: "Marks") {
            GlassToolButton(
                system: isBookmarked ? "bookmark.fill" : "bookmark",
                label: isBookmarked ? "Remove bookmark" : "Bookmark",
                tint: isBookmarked ? palette.gold : nil
            ) {
                Task { await annotations.toggleBookmark() }
            }
            .accessibilityIdentifier("phone.reader.bookmark")
            GlassToolButton(
                system: "note.text", label: "Sticky note tool", active: app.mode == .note
            ) {
                app.setMode(app.mode == .note ? .view : .note)
            }
            .accessibilityIdentifier("phone.reader.note")
        }
    }

    private var actionPod: some View {
        PhoneGlassToolPod(label: "Panels and actions") {
            GlassToolButton(
                system: "sidebar.right", label: "Notes, AI and scratchpad",
                active: shell.inspectorPresented
            ) {
                shell.setInspectorPresented(!shell.inspectorPresented)
            }
            .accessibilityIdentifier("phone.reader.inspector")

            GlassToolButton(system: "square.on.square", label: tabsLabel) {
                // P7 mounts the `.fullScreenCover` bound to this flag; the
                // wiring is final either way, so it lands with the button it
                // belongs to rather than being rediscovered a packet later.
                shell.presentSwitcher()
            }
            .accessibilityIdentifier("phone.reader.tabs")

            moreMenu
        }
    }

    private var tabsLabel: String {
        let count = app.tabs.count
        return count == 1 ? "1 open document" : "\(count) open documents"
    }

    /// Low-frequency document actions. Same contents as the iPad's More menu
    /// minus the split items and the ink toggle, plus the three things the phone
    /// has nowhere else to put: Help, Settings and Close Document.
    private var moreMenu: some View {
        Menu("More actions", systemImage: "ellipsis") {
            Button {
                app.findVisible ? app.hideFind() : app.showFind()
            } label: { Label("Find", systemImage: "magnifyingglass") }

            // The phone's "table of contents". Vellum has no separate outline
            // surface — the annotations panel IS the contents list (bookmarks,
            // notes, highlights, and the handwriting page jumps), so this routes
            // there rather than inventing a second navigator that would have to
            // be kept in step with it.
            Button {
                shell.revealInspector(.annotations)
            } label: { Label("Contents & Notes", systemImage: "list.bullet") }

            Divider()

            Button(action: onOpenFile) { Label("Open File…", systemImage: "folder") }
            Button(action: onAddWebpage) { Label("Add Webpage…", systemImage: "globe") }

            if !isWeb {
                Button {
                    if let id = app.activeTabId {
                        Task { try? await app.sessions.saveFile(sessionId: id) }
                    }
                } label: { Label("Save", systemImage: "square.and.arrow.down") }
            }
            if isWeb {
                Button {
                    exportActions.toggleSavedPage(app: app, ai: ai)
                } label: {
                    Label(
                        exportActions.pageSaved ? "Remove Offline Copy" : "Save for Offline Use",
                        systemImage: exportActions.pageSaved
                            ? "arrow.down.circle.fill" : "arrow.down.circle")
                }
                .accessibilityIdentifier("toolbar.saveForOffline")
                Button {
                    exportActions.exportVellumweb(app: app, ai: ai)
                } label: { Label("Export a Copy…", systemImage: "square.and.arrow.up") }
                .disabled(exportActions.exporting)
            }
            if app.document != nil {
                Button { showExportBundle = true } label: {
                    Label("Export with Notes…", systemImage: "arrow.up.doc")
                }
                .disabled(exportActions.exportingBundle)
                // Identical identifier to the iPad's, so shared automation
                // matches on both shells.
                .accessibilityIdentifier("toolbar.exportWithNotes")
            }

            Divider()

            Button {
                workspace.settingsSection = .general
                showSettings = true
            } label: { Label("Settings…", systemImage: "gearshape") }
            Button { showHelp = true } label: { Label("Help", systemImage: "questionmark.circle") }

            Divider()

            // Closing the last tab routes Home — `didCloseTab` is what knows
            // that, so the shell store decides rather than this menu.
            Button(role: .destructive) {
                guard let id = app.activeTabId else { return }
                Task {
                    await app.closeTab(id)
                    shell.didCloseTab()
                }
            } label: { Label("Close Document", systemImage: "xmark") }
        }
        .labelStyle(.iconOnly)
        .font(.title3.weight(.medium))
        .foregroundStyle(palette.foreground)
        .frame(width: PhoneChromeLayout.buttonSide, height: PhoneChromeLayout.buttonSide)
        .contentShape(Rectangle())
        .accessibilityLabel("More actions")
        .accessibilityIdentifier("phone.reader.more")
    }

    private var activeWebController: WebViewerController_iOS? {
        guard let tabId = app.activeTabId,
              let runtime = workspace.existingLiveTabRuntime(for: tabId),
              !runtime.isEvicted,
              runtime.webController.hasWebView
        else { return nil }
        return runtime.webController
    }

    private var canGoBack: Bool { activeWebController?.canGoBack ?? false }
    private var canGoForward: Bool { activeWebController?.canGoForward ?? false }

    /// In-page history for web tabs — same channel both other toolbars use.
    private func webHistory(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }

    private func commitPageField() {
        let trimmed = pageFieldText.trimmingCharacters(in: .whitespaces)
        if let page = Int(trimmed) {
            app.goToPage(page)
        }
        pageFieldText = String(app.currentPage)
    }
}
#endif
