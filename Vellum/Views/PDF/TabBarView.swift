import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    /// The pane this strip belongs to — carried in the tab drag payload so a drop
    /// on another pane knows where the tab came from.
    let paneId: String

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var joinTargeted = false
    @State private var showingOverview = false

    var body: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                // Semantic fills, not glass: the tab strip is chrome, so the
                // active tab uses the shared SelectionStyle surface rather than
                // stacking its own glass pane on the `.bar` material.
                HStack(spacing: 4) {
                    ForEach(appStore.tabs) { tab in
                        TabItem(
                            tab: tab,
                            paneId: paneId,
                            isActive: tab.id == appStore.activeTabId,
                            onActivate: { appStore.activateTab(tab.id) },
                            onClose: { Task { await appStore.closeTab(tab.id) } },
                            onCloseOthers: { Task { await appStore.closeOtherTabs(keeping: tab.id) } },
                            onCloseRight: { Task { await appStore.closeTabsToRight(of: tab.id) } },
                            onDuplicate: { Task { await appStore.duplicateTab(tab.id) } },
                            onMoveToNewPane: {
                                workspace.splitWithTab(
                                    tabId: tab.id, from: paneId, target: paneId,
                                    direction: .horizontal, before: false)
                            }
                        )
                    }
                }
                .padding(.vertical, 5)
            }
            .frame(maxWidth: .infinity)

            Button {
                showingOverview.toggle()
            } label: {
                Image(systemName: "rectangle.stack")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.accessoryBar)
            .help("Show all tabs")
            .accessibilityLabel("Show all tabs")
            .accessibilityIdentifier("tabBar.overview")
            .popover(isPresented: $showingOverview, arrowEdge: .bottom) {
                TabOverview(
                    tabs: appStore.tabs,
                    activeTabId: appStore.activeTabId,
                    onActivate: {
                        appStore.activateTab($0)
                        showingOverview = false
                    },
                    onClose: { id in Task { await appStore.closeTab(id) } }
                )
            }

            Menu {
                Button("Open PDF…", action: openPdf)
                Button("Open Webpage…") {
                    NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            } primaryAction: {
                appStore.newStartTab()
            }
            .menuIndicator(.hidden)
            .menuStyle(.button)
            .buttonStyle(.accessoryBar)
            .fixedSize()
            .help("New tab — click for a new tab, or choose Open PDF / Open Webpage")
            .accessibilityLabel("New tab")
            .accessibilityIdentifier("tabBar.newTab")
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 38)
        .background(.bar)
        // Dropping a tab onto this strip moves it into this pane's group. When
        // it empties the source pane, that pane collapses — this is how you undo
        // a split: drag one pane's tab into the other pane's tab bar.
        .background {
            if joinTargeted {
                Rectangle().fill(palette.primary.opacity(0.16))
            }
        }
        .overlay(alignment: .bottom) {
            Divider()
        }
        .onDrop(of: [.vellumTab], isTargeted: joinTargetedBinding) { providers in
            guard let provider = providers.first else { return false }
            let targetPane = paneId
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

    /// `isTargeted` only reflects hover while a drag is live; combined with the
    /// authoritative `draggingTab` flag it never sticks after a cancelled drag.
    private var joinTargetedBinding: Binding<Bool> {
        Binding(get: { joinTargeted && workspace.draggingTab != nil }, set: { joinTargeted = $0 })
    }

    private func openPdf() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await appStore.openFiles(paths: paths) }
    }
}

private struct TabItem: View {
    let tab: PdfTab
    let paneId: String
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void
    let onCloseOthers: () -> Void
    let onCloseRight: () -> Void
    let onDuplicate: () -> Void
    let onMoveToNewPane: () -> Void

    @Environment(AppStore.self) private var appStore
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var hasPendingAction: Bool {
        tab.mode != .view || (isActive && appStore.pendingNoteContent != nil)
    }

    private var iconName: String {
        TabPresentation.iconName(for: tab)
    }

    private var label: String {
        TabPresentation.title(for: tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onActivate) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    Text(label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if hasPendingAction {
                        Circle()
                            .fill(.orange)
                            .frame(width: 6, height: 6)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.leading, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityAddTraits(isActive ? [.isButton, .isSelected] : .isButton)
            .accessibilityIdentifier("tabBar.tab.\(tab.id)")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(hovering || isActive ? 1 : 0)
            .padding(.trailing, 4)
            .help("Close \(label)")
            .accessibilityLabel("Close \(label)")
            .accessibilityIdentifier("tabBar.close.\(tab.id)")
        }
        .font(.system(size: 12))
        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .frame(minWidth: 128, idealWidth: 176, maxWidth: 224, minHeight: 28, maxHeight: 28)
        .selectionSurface(
            selected: isActive,
            hovering: hovering,
            in: RoundedRectangle(cornerRadius: Radius.md),
            palette: palette)
        .onHover { hovering = $0 }
        .help(tab.document?.pdfPath ?? "New Tab")
        .overlay {
            MiddleClickView(action: onClose)
        }
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
        .contextMenu {
            Button("Duplicate") { onDuplicate() }
                .disabled(tab.document?.kind == .pdf)
            Button("Move to New Pane") { onMoveToNewPane() }
                .disabled(appStore.tabs.count < 2)

            Divider()

            if tab.document?.kind == .web {
                Button("Copy Link") { copyLink() }
            } else if tab.document?.kind == .pdf {
                Button("Reveal in Finder") { revealPdf() }
            }

            Divider()

            Button("Close") { onClose() }
            Button("Close Others") { onCloseOthers() }
                .disabled(appStore.tabs.count < 2)
            Button("Close Tabs to Right") { onCloseRight() }
                .disabled(isLastTab)
        }
        .accessibilityValue(hasPendingAction ? "Action pending" : "")
    }

    private var isLastTab: Bool {
        appStore.tabs.last?.id == tab.id
    }

    private func copyLink() {
        guard let value = tab.document?.pdfPath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func revealPdf() {
        guard let path = tab.document?.pdfPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

private struct TabOverview: View {
    let tabs: [PdfTab]
    let activeTabId: String?
    let onActivate: (String) -> Void
    let onClose: (String) -> Void

    @Environment(AppStore.self) private var appStore
    @State private var query = ""

    private var filteredTabs: [PdfTab] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return tabs }
        return tabs.filter {
            TabPresentation.title(for: $0)
                .localizedStandardContains(needle)
                || TabPresentation.typeLabel(for: $0)
                .localizedStandardContains(needle)
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
                            HStack(spacing: 8) {
                                Button {
                                    onActivate(tab.id)
                                } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: TabPresentation.iconName(for: tab))
                                            .foregroundStyle(.secondary)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(TabPresentation.title(for: tab))
                                                .lineLimit(2)
                                                .frame(maxWidth: .infinity, alignment: .leading)
                                            Text(TabPresentation.typeLabel(for: tab))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        if tab.id == activeTabId {
                                            Image(systemName: "checkmark")
                                                .foregroundStyle(.tint)
                                                .accessibilityLabel("Current tab")
                                        }
                                        if isPending(tab) {
                                            Circle()
                                                .fill(.orange)
                                                .frame(width: 6, height: 6)
                                                .accessibilityHidden(true)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "\(TabPresentation.title(for: tab)), "
                                        + "\(TabPresentation.typeLabel(for: tab))"
                                        + (isPending(tab) ? ", action pending" : ""))
                                .accessibilityIdentifier("tabOverview.tab.\(tab.id)")

                                Button {
                                    onClose(tab.id)
                                } label: {
                                    Image(systemName: "xmark")
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                                .help("Close \(TabPresentation.title(for: tab))")
                                .accessibilityLabel("Close \(TabPresentation.title(for: tab))")
                                .accessibilityIdentifier("tabOverview.close.\(tab.id)")
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .background(
                                tab.id == activeTabId
                                    ? Color.accentColor.opacity(0.12)
                                    : Color.clear,
                                in: RoundedRectangle(cornerRadius: Radius.md))
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private func isPending(_ tab: PdfTab) -> Bool {
        tab.mode != .view || (tab.id == activeTabId && appStore.pendingNoteContent != nil)
    }
}

enum TabPresentation {
    static func title(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "New Tab" }
        if let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let fallback = document.pdfPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? ""
        if fallback.lowercased().hasSuffix(".pdf") {
            return String(fallback.dropLast(4))
        }
        return fallback.isEmpty ? "Untitled" : fallback
    }

    static func typeLabel(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "New Tab" }
        return document.kind == .web ? "Webpage" : "PDF"
    }

    static func iconName(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "plus.square" }
        return document.kind == .web ? "globe" : "doc.text"
    }
}

private struct MiddleClickView: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> MiddleClickNSView {
        MiddleClickNSView(action: action)
    }

    func updateNSView(_ nsView: MiddleClickNSView, context: Context) {
        nsView.action = action
    }
}

private final class MiddleClickNSView: NSView {
    var action: () -> Void

    init(action: @escaping () -> Void) {
        self.action = action
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private var monitor: Any?

    /// Invisible to hit testing — a local monitor handles the middle button,
    /// since middle-clicks otherwise dispatch through views that ignore them.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { [weak self] event in
            guard let self, event.buttonNumber == 2,
                  event.window === self.window,
                  self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            else { return event }
            self.action()
            return nil
        }
    }
    // No deinit cleanup needed: viewDidMoveToWindow(window == nil) removes the
    // monitor when the tab leaves the hierarchy, before deallocation.
}
