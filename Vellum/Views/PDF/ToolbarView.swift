import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Native unified-toolbar content (Liquid Glass on macOS 26+). Groups are
// separated with ToolbarSpacer so each cluster reads as its own glass pod.
struct VellumToolbar: ToolbarContent {
    @Environment(AppStore.self) private var appStore

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var hasDocument: Bool { appStore.document != nil }

    // Three stable regions, shared by PDF and web tabs so nothing familiar
    // moves when the tab type changes:
    //   • LEADING (.navigation): the same navigation slot — web back/forward or
    //     PDF page controls — plus PDF-only reading controls (zoom).
    //   • CENTER (.principal): the quiet document title/address and its explicit
    //     document-action disclosure. .principal is genuinely centered by the
    //     window, so it never shifts with the leading cluster's width.
    //   • TRAILING: bookmark, note, inspector, and one overflow Menu containing
    //     low-frequency actions owned by the current document.
    // Low-use actions no longer each claim a glass circle, which is what
    // produced the "pill soup".
    var body: some ToolbarContent {
        // LEADING — navigation. The PDF clusters are drawn as explicit glass
        // capsules inside ONE item (PdfLeadingControls) because, measured live
        // on macOS 26 (PR #115), the system refuses every native route to
        // three separate pods here:
        //   • adjacent `.navigation` items merge into one capsule with
        //     system-picked sub-boundaries (it glued zoom-out to the page
        //     counter);
        //   • `ToolbarSpacer(.fixed, placement: .navigation)` is a runtime
        //     no-op in this region (it DOES work in the trailing region);
        //   • empty fixed-width items get absorbed into the neighboring
        //     capsule instead of splitting it;
        //   • a text-labeled button (the 100% reset) never shares a capsule
        //     with its neighbors, so the zoom trio shatters;
        //   • ControlGroup children escape `.navigation` entirely and reflow
        //     into the trailing region as overlapping circles.
        // The web history pod is left native: a single two-button group
        // renders as one clean capsule without help.
        ToolbarItemGroup(placement: .navigation) {
            if hasDocument, isWeb {
                WebHistoryButtons()
            }
        }

        if hasDocument, !isWeb {
            ToolbarItem(placement: .navigation) {
                PdfLeadingControls()
            }
            // Without this the system wraps the whole HStack in one more
            // capsule and the three custom pods read as one blob again.
            .sharedBackgroundVisibility(.hidden)
        }

        // CENTER — quiet title/address, genuinely centered and not pretending
        // to be an editable pill.
        if hasDocument {
            ToolbarItem(placement: .principal) {
                DocumentTitleField()
            }
        }

        // TRAILING — same custom-capsule construct as the leading cluster.
        // These were native pods until the hover pass: with the buttons
        // switched to .borderless (for the shared hover backdrop), the system
        // pod sized itself differently from the leading capsules — 36pt tall
        // vs 35, an 18.5pt inter-pod gap vs 10.5 (measured) — so the trailing
        // side draws its own capsules too, guaranteeing identical geometry.
        // Item order is the same for PDF and web tabs.
        //
        // Home has no current document, so it shows none of this — including
        // no document-action menu. Updates are not put here as a substitute:
        // Home's own header already carries Check for Updates / Install
        // Update (#70), and the app menu carries them for when a document is
        // open.
        if hasDocument {
            ToolbarItem {
                HStack(spacing: 8) {
                    HStack(spacing: 2) {
                        BookmarkButton()
                        NoteToolToggle()
                    }
                    .padding(.horizontal, 6)
                    .glassEffect()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Annotation tools")

                    HStack(spacing: 2) {
                        SidebarToggleButton()
                        OverflowMenu()
                    }
                    .padding(.horizontal, 6)
                    .glassEffect()
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Panel and document actions")
                }
            }
            .sharedBackgroundVisibility(.hidden)
        }
    }
}

// MARK: - Add webpage sheet

/// Sheet for the Add Webpage flow (⌘L). A popover anchored to the toolbar
/// button could detach and land at the edge of another display — see the
/// audit's P0 "Add Webpage popover" finding. A sheet is always centered over
/// the owning window, so it can't escape onto another screen. It also sidesteps
/// the @FocusState-in-NSToolbar gotcha since the field now lives in a normal
/// window-hosted view instead of a toolbar item.
struct AddWebpageSheet: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlInput = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Webpage")
                .font(.headline)
            Text("Paste an article URL to open it in reading mode.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            TextField("https://…", text: $urlInput)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($fieldFocused)
                .onSubmit(submit)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Open", action: submit)
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(urlInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            urlInput = ""
            fieldFocused = true
        }
    }

    private func submit() {
        let value = urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        dismiss()
        Task { await appStore.openUrl(value) }
    }
}

/// In-page history for web tabs (window.__webHistory in the original).
private struct WebHistoryButtons: View {
    var body: some View {
        Button {
            go(-1)
        } label: {
            Label("Back", systemImage: "arrow.left")
        }
        .help("Back — go to the previous page in this tab's history")
        .accessibilityIdentifier("toolbar.webBack")

        Button {
            go(1)
        } label: {
            Label("Forward", systemImage: "arrow.right")
        }
        .help("Forward — go to the next page in this tab's history")
        .accessibilityIdentifier("toolbar.webForward")
    }

    private func go(_ delta: Int) {
        NotificationCenter.default.post(
            name: .vellumWebHistory, object: nil, userInfo: ["delta": delta])
    }
}

// MARK: - Page navigation

/// The three leading clusters — [< >] [page x / N] [− 100% +] — each drawn as
/// its own glass capsule. See the body of VellumToolbar for why these capsules
/// are custom instead of system pods.
private struct PdfLeadingControls: View {
    var body: some View {
        // 8pt spacing renders as the same ~11pt gap the system leaves between
        // its own trailing pods (measured). The explicit
        // `.accessibilityElement(children: .contain)` on each capsule stops
        // the cluster from collapsing into one AX element whose first child's
        // label ("Previous page") gets announced for every control (measured
        // with VoiceOver's AXDescription).
        HStack(spacing: 8) {
            // The accessibility container + label go OUTSIDE .glassEffect():
            // the glass wraps its content in one more AX group, and labels
            // applied inside it never surface — the group then inherits its
            // first child's description ("Previous page" on every cluster,
            // measured).
            HStack(spacing: 2) {
                PageStepButtons()
            }
            .padding(.horizontal, 6)
            .glassEffect()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Page navigation")

            PageIndicator()
                .frame(height: 35)
                .glassEffect()
                // On the outermost wrapper, where the previousPage tooltip
                // otherwise leaks in as this container's AXHelp (measured).
                .help("Current page — type a page number and press Return")

            HStack(spacing: 2) {
                ZoomControls()
            }
            .padding(.horizontal, 6)
            .glassEffect()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Zoom controls")
        }
    }
}

/// The shared hover/active backdrop for toolbar buttons: a pill (32×26 on
/// icon buttons, label-width on text buttons) centered in the button's slot
/// with an even inset from the capsule edges. One shape everywhere —
/// PR #115 review asked for oval/pill, consistent, and fitting the capsule;
/// the system's own hover stretches to the button's full bounds and reads as
/// squished.
private struct ToolbarHoverBackdrop: View {
    let visible: Bool
    var strength: Double = 0.12
    var width: CGFloat? = 32

    var body: some View {
        Capsule()
            // Concrete Color.primary, NOT the hierarchical .primary: the
            // hierarchical style resolves against the button label's
            // foregroundStyle, which rendered the bookmark's pill at ~40%
            // strength through its gold style (measured +7 vs +20).
            .fill(Color.primary.opacity(visible ? strength : 0))
            .frame(width: width, height: 26)
    }
}

/// Icon button sized for the custom capsules. The frame + contentShape INSIDE
/// the label closure is what makes the whole 32×35 area clickable — borderless
/// buttons otherwise hit-test only the glyph (#112; measured 6.5pt-wide chevron
/// targets in the first cut of this cluster).
private struct CapsuleIconButton: View {
    let title: String
    let systemImage: String
    let identifier: String
    let helpText: String
    var isDisabled = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 35)
                .background {
                    ToolbarHoverBackdrop(visible: hovering && !isDisabled)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        // Borderless buttons tint their labels with the accent color, which
        // made the zoom cluster read as selected/links next to the monochrome
        // system pods.
        .tint(.primary)
        .disabled(isDisabled)
        .onHover { hovering = $0 }
        .help(helpText)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The previous/next steppers, one pod — the "< >" entity, separate from the
/// page counter next to it (PR #115 review).
private struct PageStepButtons: View {
    @Environment(AppStore.self) private var appStore

    var body: some View {
        CapsuleIconButton(
            title: "Previous page",
            systemImage: "chevron.left",
            identifier: "toolbar.previousPage",
            helpText: "Previous page — or type a page number in the field",
            isDisabled: appStore.currentPage <= 1
        ) {
            appStore.goToPage(appStore.currentPage - 1)
        }

        CapsuleIconButton(
            title: "Next page",
            systemImage: "chevron.right",
            identifier: "toolbar.nextPage",
            helpText: "Next page — or type a page number in the field",
            isDisabled: appStore.currentPage >= appStore.numPages
        ) {
            appStore.goToPage(appStore.currentPage + 1)
        }
    }
}

/// The "page x of N" counter, its own pod between the steppers and zoom.
private struct PageIndicator: View {
    @Environment(AppStore.self) private var appStore

    @State private var pageInput = "1"

    var body: some View {
        HStack(spacing: 5) {
            PageNumberField(
                text: $pageInput,
                totalPages: appStore.numPages,
                onCommit: commitPageInput,
                onCancel: { pageInput = String(appStore.currentPage) }
            )
            .frame(width: 36, height: 21)
            Text("/ \(appStore.numPages)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // The total is announced by the field's label; as its own AX
                // element this text got the cluster's first-child description
                // ("Previous page") and its label displaced the rendered value.
                .accessibilityHidden(true)
        }
        .font(.system(size: 12))
        // Breathing room between the field/count and the glass pod's rounded
        // ends — flush content gets visually clipped by the capsule curvature.
        .padding(.horizontal, 10)
        .onChange(of: appStore.currentPage) { _, page in
            pageInput = String(page)
        }
        // Restored sessions start on last_page — sync on tab/doc switch too.
        .task(id: DocumentKey(appStore)) {
            pageInput = String(appStore.currentPage)
        }
    }

    private func commitPageInput() {
        guard let page = Int(pageInput), (1...appStore.numPages).contains(page) else {
            pageInput = String(appStore.currentPage)
            return
        }
        appStore.goToPage(page)
    }
}

/// AppKit-backed page field. SwiftUI's TextField cannot produce the wanted
/// rendering inside the glass capsule: .roundedBorder draws the focus ring
/// (a blue oval overflowing the capsule — PR #115 review) which
/// .focusEffectDisabled() does not remove, and .plain renders the digits at
/// half brightness with no modifier reaching its text color. NSTextField
/// exposes both as direct property sets.
private struct PageNumberField: NSViewRepresentable {
    @Binding var text: String
    let totalPages: Int
    let onCommit: () -> Void
    let onCancel: () -> Void

    /// Clicking into an NSTextField places a caret; SwiftUI's TextField
    /// selected the content, so typing replaced it. Without this, a click +
    /// "4" on page 1 yields "14" — appended, invalid, silently reverted
    /// (measured). Select-all after every click restores replace-on-type.
    final class SelectAllTextField: NSTextField {
        override func mouseDown(with event: NSEvent) {
            super.mouseDown(with: event)
            if let editor = currentEditor(), editor.selectedRange.length == 0 {
                editor.selectAll(nil)
            }
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommit: onCommit, onCancel: onCancel)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = SelectAllTextField(string: text)
        field.focusRingType = .none
        field.isBordered = false
        field.drawsBackground = false
        field.alignment = .center
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        field.setAccessibilityIdentifier("toolbar.pageField")
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onCommit = onCommit
        // Never clobber what the user is mid-typing.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
        field.setAccessibilityLabel("Page number, of \(totalPages) pages")
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onCommit: () -> Void
        var onCancel: () -> Void

        init(
            text: Binding<String>,
            onCommit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onCommit = onCommit
            self.onCancel = onCancel
        }

        // Return commits AND drops focus; Escape abandons the edit (the
        // binding holds live keystrokes, so the caller supplies the restore
        // value). Both must blur: while the field stays first responder,
        // clicks go to the field editor and never reach the select-all
        // mouseDown override, so a second entry appends (measured: "41").
        func control(
            _ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                onCommit()
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            default:
                return false
            }
            control.stringValue = text.wrappedValue
            control.window?.makeFirstResponder(nil)
            return true
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }

        // Fires on both Return and focus loss — the two commit paths the
        // SwiftUI version needed onSubmit + FocusState tracking for.
        func controlTextDidEndEditing(_ notification: Notification) {
            onCommit()
            // Show the committed (possibly reverted) value even while the
            // field keeps focus — updateNSView deliberately skips syncing
            // whenever an editor is active, so an out-of-range entry would
            // otherwise sit in the field forever (measured: "141" in a
            // 12-page document survived Return).
            if let field = notification.object as? NSTextField,
               field.stringValue != text.wrappedValue {
                field.stringValue = text.wrappedValue
            }
        }
    }
}

// MARK: - Zoom

private struct ZoomControls: View {
    @Environment(AppStore.self) private var appStore

    @State private var hoveringReset = false

    var body: some View {
        CapsuleIconButton(
            title: "Zoom out",
            systemImage: "minus.magnifyingglass",
            identifier: "toolbar.zoomOut",
            helpText: "Zoom out (⌘−)"
        ) {
            appStore.zoomOut()
        }

        Button(action: resetZoom) {
            Text("\(Int((appStore.zoom * 100).rounded()))%")
                .font(.system(size: 12))
                .monospacedDigit()
                .frame(minWidth: 40)
                .frame(height: 35)
                .background {
                    // nil width: track the label, which grows past 40 at
                    // three-digit zoom levels.
                    ToolbarHoverBackdrop(visible: hoveringReset, width: nil)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .onHover { hoveringReset = $0 }
        .help("Reset zoom to 100%")
        .accessibilityLabel("Reset zoom to 100%")
        .accessibilityIdentifier("toolbar.resetZoom")

        CapsuleIconButton(
            title: "Zoom in",
            systemImage: "plus.magnifyingglass",
            identifier: "toolbar.zoomIn",
            helpText: "Zoom in (⌘+)"
        ) {
            appStore.zoomIn()
        }
    }

    private func resetZoom() {
        if let zoomToHandler = appStore.zoomToHandler {
            zoomToHandler(1)
        } else {
            appStore.setZoom(1)
        }
    }
}

// MARK: - Annotation tools

private struct BookmarkButton: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var isBookmarked: Bool {
        findCurrentBookmark(
            annotations: annotationStore.annotations,
            docKind: appStore.document?.kind,
            currentPage: appStore.currentPage,
            webVisibleBookmarks: appStore.webVisibleBookmarks
        ) != nil
    }

    @State private var hovering = false

    var body: some View {
        Button {
            Task { await annotationStore.toggleBookmark() }
        } label: {
            Label(
                isBookmarked ? "Remove Bookmark Position" : "Bookmark Position",
                systemImage: isBookmarked ? "bookmark.fill" : "bookmark"
            )
            .foregroundStyle(isBookmarked ? AnyShapeStyle(palette.gold) : AnyShapeStyle(.primary))
            .labelStyle(.iconOnly)
            .frame(width: 32, height: 35)
            .background {
                ToolbarHoverBackdrop(visible: hovering)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .onHover { hovering = $0 }
        .help(
            isBookmarked
                ? "Remove Bookmark Position (⌘D)"
                : (isWeb
                    ? "Bookmark Position (⌘D) — saves this reading position"
                    : "Bookmark Position (⌘D) — saves this page in Annotations"))
        .accessibilityAddTraits(isBookmarked ? .isSelected : [])
        .accessibilityIdentifier("toolbar.bookmark")
    }
}

private struct NoteToolToggle: View {
    @Environment(AppStore.self) private var appStore

    @State private var hovering = false

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var isActive: Bool { appStore.mode == .note }

    // A Button with an explicit active fill instead of a .button-styled
    // Toggle: the toggle's system chrome brings back the squished hover/press
    // shape this pass removes, and its selected state cannot be drawn through
    // the shared backdrop.
    var body: some View {
        Button {
            appStore.setMode(isActive ? .view : .note)
        } label: {
            Label("Sticky note tool", systemImage: "note.text")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 35)
                .background {
                    ToolbarHoverBackdrop(
                        visible: isActive || hovering,
                        strength: isActive ? 0.22 : 0.12)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .onHover { hovering = $0 }
        .help(
            isWeb
                ? "Sticky note tool (N) — click in the page to attach a note to the text there"
                : "Sticky note tool (N) — click on the page to place a note")
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("toolbar.noteTool")
    }
}

// MARK: - Overflow menu

/// Low-frequency actions owned by the current document. Global actions and tab
/// creation deliberately live on Home / in the File menu, not here.
private struct OverflowMenu: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AiStore.self) private var aiStore

    @State private var hovering = false
    @State private var pageSaved = false
    @State private var exporting = false
    /// Separate guard for the Vellum bundle flow so it can't double-fire or
    /// conflict with the web-only archive-export guard above.
    @State private var exportingBundle = false
    /// Serializes save/remove so a rapid Remove can't finish before a slow
    /// Save's archive write and get its deletion undone by it.
    @State private var saveToggleTask: Task<Void, Never>?
    /// Identifies the newest queued toggle, so a superseded one's failure can't
    /// revert the toolbar to a state the user has already toggled away from.
    @State private var saveToggleGeneration = 0

    private var isWeb: Bool { appStore.document?.kind == .web }
    private var hasDocument: Bool { appStore.document != nil }

    private var menuControl: some View {
        Menu {
            if hasDocument, !isWeb {
                Section {
                    Button(action: savePdf) {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    Button(action: savePdfAs) {
                        Label("Save As…", systemImage: "doc.on.doc")
                    }
                }
            }

            if hasDocument, isWeb {
                Section {
                    Button(action: toggleSavedPage) {
                        Label(
                            pageSaved ? "Remove Offline Copy" : "Keep Offline",
                            systemImage: pageSaved ? "arrow.down.circle.fill" : "arrow.down.circle")
                    }
                    .accessibilityIdentifier("toolbar.saveForOffline")
                    Button(action: exportVellumweb) {
                        Label("Export Web Archive…", systemImage: "square.and.arrow.up")
                    }
                    .disabled(exporting)
                }
            }

            if hasDocument {
                Section {
                    Button(action: exportWithNotes) {
                        Label("Export Vellum Bundle with Notes…", systemImage: "arrow.up.doc")
                    }
                    .disabled(exportingBundle)
                    .accessibilityIdentifier("toolbar.exportWithNotes")
                }
            }

        } label: {
            // A transparent click target: the menu control draws its own
            // system hover under any backdrop attached to it — measured as a
            // double-strength 28pt blob that survived both .borderless and
            // .plain — so the visible glyph and pill render as ZStack
            // siblings below, and the whole Menu sits at 2% opacity (not 0:
            // fully transparent views stop hit-testing). The dropdown itself
            // is a separate window, unaffected by this opacity.
            Color.clear
                .frame(width: 32, height: 35)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .opacity(0.02)
        .help("More actions for this document")
        .accessibilityLabel("Document actions")
        .accessibilityIdentifier("toolbar.overflowMenu")
    }

    var body: some View {
        ZStack {
            ToolbarHoverBackdrop(visible: hovering)
            Label("More", systemImage: "ellipsis")
                // Icon-only keeps the glyph the same size as the neighboring
                // buttons; a text-bearing label can outgrow the toolbar
                // height and clip against its bottom edge.
                .labelStyle(.iconOnly)
                .foregroundStyle(.primary)
            menuControl
        }
        .frame(width: 32, height: 35)
        .onHover { hovering = $0 }
        .task(id: DocumentKey(appStore)) {
            await loadSavedState(for: DocumentKey(appStore))
        }
    }

    // MARK: File

    private func savePdf() {
        guard let sessionId = appStore.activeTabId else { return }
        Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
    }

    private func savePdfAs() {
        DocumentActionPresenter.savePdfAs(appStore: appStore)
    }

    // MARK: Web library

    private func loadSavedState(for identity: DocumentKey) async {
        pageSaved = false
        guard isWeb, let sessionId = appStore.activeTabId else { return }
        let saved = (try? await appStore.sessions.getWebpageSaved(sessionId: sessionId)) ?? false
        if DocumentKey(appStore) == identity {
            pageSaved = saved
        }
    }

    /// Save = create an offline snapshot, then mark the page kept. The button
    /// only reports an offline copy after the archive was actually written.
    /// Remove = un-keep and delete the offline copy; the record — highlights,
    /// notes, reading position — always survives.
    private func toggleSavedPage() {
        guard let identity = appStore.activeWebDocumentActionIdentity() else { return }
        let next = !pageSaved
        pageSaved = next
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        let prior = saveToggleTask
        saveToggleGeneration += 1
        let generation = saveToggleGeneration
        saveToggleTask = Task {
            await prior?.value
            guard appStore.isCurrentWebDocument(identity) else { return }
            do {
                if next {
                    let archived = try await appStore.sessions.archiveWebpageDefault(
                        sessionId: identity.sessionId, pages: pages, expectedUrl: identity.url)
                    // A navigation can reuse the session id while this awaits.
                    // Never let an old action mark the new URL as saved.
                    guard appStore.isCurrentWebDocument(identity) else { return }
                    guard archived else {
                        throw SessionServiceError.io("The webpage changed before its offline copy could be created.")
                    }
                    try await appStore.sessions.setWebpageSaved(sessionId: identity.sessionId, saved: true)
                    guard appStore.isCurrentWebDocument(identity) else { return }
                } else {
                    try await appStore.sessions.setWebpageSaved(sessionId: identity.sessionId, saved: false)
                    guard appStore.isCurrentWebDocument(identity) else { return }
                }
            } catch {
                // If archiving fails, undo any membership change so Saved and
                // offline availability cannot diverge. Only the newest toggle
                // owns visible state or its error message.
                guard appStore.isCurrentWebDocument(identity) else { return }
                if next {
                    try? await appStore.sessions.setWebpageSaved(sessionId: identity.sessionId, saved: false)
                    // The rollback itself can suspend; do not update a page
                    // that rebounded to a different URL while it ran.
                    guard appStore.isCurrentWebDocument(identity) else { return }
                }
                if appStore.isCurrentWebDocument(identity), generation == saveToggleGeneration {
                    pageSaved = !next
                    appStore.error = "Keep Offline failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Export the active webpage as a .vellumweb archive (Toolbar.tsx export flow).
    private func exportVellumweb() {
        guard !exporting,
              let sessionId = appStore.activeTabId,
              appStore.document?.kind == .web else { return }

        let slug = slugifiedTitle()
        let panel = NSSavePanel()
        if let archive = UTType(filenameExtension: "vellumweb") {
            panel.allowedContentTypes = [archive]
        }
        panel.nameFieldStringValue = "\(slug).vellumweb"
        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        exporting = true
        Task {
            defer { exporting = false }
            _ = try? await appStore.sessions.exportVellumweb(
                sessionId: sessionId, destPath: destination.path, pages: pages)
        }
    }

    /// Export the active document as a `.vellum` bundle — the document plus its
    /// scratchpad + attachments, and (opt-in checkbox, default OFF) the AI
    /// conversation. Available for BOTH PDF and web tabs.
    private func exportWithNotes() {
        guard !exportingBundle,
              let sessionId = appStore.activeTabId,
              let document = appStore.document else { return }

        let panel = NSSavePanel()
        if let bundleType = UTType(filenameExtension: "vellum") {
            panel.allowedContentTypes = [bundleType]
        }
        panel.nameFieldStringValue = "\(slugifiedTitle()).vellum"
        // Conversations are semi-private (design §5): sharing them is explicit,
        // so the checkbox defaults OFF.
        let checkbox = NSButton(checkboxWithTitle: "Include AI conversation", target: nil, action: nil)
        checkbox.state = .off
        checkbox.setAccessibilityIdentifier("export.includeConversation")
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 40))
        checkbox.frame = NSRect(x: 18, y: 8, width: 244, height: 24)
        accessory.addSubview(checkbox)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let includeConversations = checkbox.state == .on
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }

        exportingBundle = true
        Task {
            defer { exportingBundle = false }
            try? await buildBundle(
                sessionId: sessionId,
                document: document,
                destination: destination,
                includeConversations: includeConversations,
                pages: pages)
        }
    }

    /// Assemble the bundle content: durable id (lazily stamped), the document
    /// bytes (PDF as-is / a fresh .vellumweb for web), and the class-B sidecar
    /// pulled from DocumentDataStore by storage key.
    private func buildBundle(
        sessionId: String,
        document: DocumentInfo,
        destination: URL,
        includeConversations: Bool,
        pages: [WebPageText]
    ) async throws {
        // The sidecar currently lives under this session's storage key — resolve
        // it BEFORE the stamp changes DocumentInfo.docId.
        let pullKey = DocumentIdentity.storageKey(for: document)
        // Durable id for the manifest (stamps a writable PDF; byte-hash fallback
        // for an unwritable one; URL hash for web).
        let durableId = (try? await appStore.sessions.ensureDocumentId(sessionId: sessionId))
            ?? pullKey
        await appStore.syncDocumentId(sessionId: sessionId)

        let documentData: Data
        let documentFile: String
        if document.kind == .web {
            // Reuse the session's .vellumweb writer rather than duplicating it.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString.lowercased()).vellumweb")
            _ = try await appStore.sessions.exportVellumweb(
                sessionId: sessionId, destPath: tmp.path, pages: pages)
            documentData = try Data(contentsOf: tmp)
            try? FileManager.default.removeItem(at: tmp)
            documentFile = "\(slugifiedTitle()).vellumweb"
        } else {
            // Read AFTER the stamp so the exported PDF carries /VellumDocId.
            documentData = try await appStore.sessions.readPdfBytes(sessionId: sessionId)
            let name = (document.pdfPath as NSString).lastPathComponent
            documentFile = VellumBundle.safeName(name) ?? "document.pdf"
        }

        let scratchpad = DocumentDataStore.loadScratchpad(forKey: pullKey)
        let attachments = loadAttachments(forKey: pullKey)
        let conversations = includeConversations
            ? DocumentDataStore.loadConversationsData(forKey: pullKey)
            : nil

        let content = VellumBundle.Content(
            kind: document.kind,
            docId: durableId,
            documentFile: documentFile,
            documentData: documentData,
            title: document.title,
            scratchpad: scratchpad.isEmpty ? nil : scratchpad,
            attachments: attachments,
            conversations: conversations)
        try VellumBundle.write(content, to: destination)
    }

    /// Read the document's attachments as (bare filename, bytes) pairs.
    private func loadAttachments(forKey key: String) -> [(name: String, data: Data)] {
        let dir = DocumentDataStore.attachmentsDir(forKey: key)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else {
            return []
        }
        var out: [(name: String, data: Data)] = []
        for name in names.sorted() {
            if let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
                out.append((name, data))
            }
        }
        return out
    }

    /// Slug for the export default filename: lowercased title, non-alphanumeric
    /// runs collapsed to "-", trimmed, max 60 chars, fallback "article".
    private func slugifiedTitle() -> String {
        let title = appStore.document?.title ?? ""
        var slug = ""
        var lastWasDash = false
        for scalar in title.lowercased().unicodeScalars {
            if (scalar.value >= 97 && scalar.value <= 122)
                || (scalar.value >= 48 && scalar.value <= 57) {
                slug.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash, !slug.isEmpty {
                slug.append("-")
                lastWasDash = true
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.count > 60 {
            slug = String(slug.prefix(60))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "article" : slug
    }
}

/// Centered informational title plus a conventional disclosure for document
/// actions. The label itself has no hidden click or double-click behavior.
private struct DocumentTitleField: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AiStore.self) private var aiStore

    /// Transient status text shown in place of the title (e.g. "URL copied").
    @State private var feedback: String?
    @State private var feedbackTask: Task<Void, Never>?

    private var isWeb: Bool { appStore.document?.kind == .web }

    var body: some View {
        HStack(spacing: 2) {
            Text(feedback ?? displayText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 120, idealWidth: isWeb ? 360 : 240, maxWidth: isWeb ? 420 : 300)
                .accessibilityLabel(feedback ?? displayText)
                .accessibilityIdentifier("toolbar.documentTitle")

            Menu {
                if isWeb {
                    Button(action: copyURL) {
                        Label("Copy URL", systemImage: "doc.on.doc")
                    }
                    Button(action: exportWebArchive) {
                        Label("Export Web Archive…", systemImage: "square.and.arrow.up")
                    }
                } else {
                    Button(action: revealInFinder) {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    Button {
                        DocumentActionPresenter.savePdfAs(appStore: appStore)
                    } label: {
                        Label("Save As…", systemImage: "doc.on.doc")
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 28)
            }
            .menuIndicator(.hidden)
            .accessibilityLabel("Document actions for \(displayText)")
            .accessibilityIdentifier("toolbar.documentTitleActions")
        }
        .padding(.horizontal, 6)
        .frame(minHeight: 30)
        .help("Document title and actions")
    }

    private var displayText: String {
        guard let path = appStore.document?.pdfPath else { return "" }
        if isWeb {
            if path.hasPrefix("https://") { return String(path.dropFirst(8)) }
            if path.hasPrefix("http://") { return String(path.dropFirst(7)) }
            return path
        }
        return (path as NSString).lastPathComponent
    }

    private func showFeedback(_ text: String) {
        feedbackTask?.cancel()
        feedback = text
        feedbackTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            feedback = nil
        }
    }

    private func copyURL() {
        guard let path = appStore.document?.pdfPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showFeedback("URL copied")
    }

    private func revealInFinder() {
        guard let path = appStore.document?.pdfPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func exportWebArchive() {
        guard let sessionId = appStore.activeTabId else { return }
        let panel = NSSavePanel()
        if let archive = UTType(filenameExtension: "vellumweb") {
            panel.allowedContentTypes = [archive]
        }
        panel.nameFieldStringValue = "article.vellumweb"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let pages = aiStore.pageTexts
            .sorted { $0.key < $1.key }
            .map { WebPageText(number: $0.key, text: $0.value) }
        Task {
            do {
                _ = try await appStore.sessions.exportVellumweb(
                    sessionId: sessionId, destPath: destination.path, pages: pages)
                showFeedback("Exported")
            } catch {
                showFeedback("Export failed")
            }
        }
    }
}

/// Native Save As presentation shared by the document disclosure and the
/// current-document overflow menu.
@MainActor
private enum DocumentActionPresenter {
    static func savePdfAs(appStore: AppStore) {
        guard let sessionId = appStore.activeTabId,
              let sourcePath = appStore.document?.pdfPath else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (sourcePath as NSString).lastPathComponent
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task {
            do {
                try await appStore.savePdfAs(tabId: sessionId, destination: destination)
            } catch {
                appStore.error = "Save As failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Sidebar

private struct SidebarToggleButton: View {
    @Environment(WorkspaceStore.self) private var workspace

    @State private var hovering = false

    var body: some View {
        Button {
            workspace.sidebarOpen.toggle()
        } label: {
            Label(
                workspace.sidebarOpen ? "Hide side panel" : "Show side panel",
                systemImage: "sidebar.trailing")
                .labelStyle(.iconOnly)
                .frame(width: 32, height: 35)
                .background {
                    ToolbarHoverBackdrop(visible: hovering)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .tint(.primary)
        .onHover { hovering = $0 }
        .help(
            workspace.sidebarOpen
                ? "Hide side panel (⌘⌥S)"
                : "Show side panel (⌘⌥S) — annotations and AI chat")
        .accessibilityAddTraits(workspace.sidebarOpen ? .isSelected : [])
        .accessibilityIdentifier("toolbar.sidebarToggle")
    }
}

/// Identity of the active document — toolbar state (page field, export, saved
/// flag) resets whenever the tab or backing file changes.
private struct DocumentKey: Hashable {
    var tabId: String?
    var path: String?

    @MainActor
    init(_ appStore: AppStore) {
        tabId = appStore.activeTabId
        path = appStore.document?.pdfPath
    }
}
