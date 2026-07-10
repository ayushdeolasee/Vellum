#if os(macOS)
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
                            onClose: { Task { await appStore.closeTab(tab.id) } }
                        )
                    }
                }
                .padding(.vertical, 5)
            }
            .frame(maxWidth: .infinity)

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

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var isStart: Bool { tab.document == nil }

    private var iconName: String {
        guard let document = tab.document else { return "plus.square" }
        return document.kind == .web ? "globe" : "doc.text"
    }

    private var label: String {
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
            .opacity(hovering ? 1 : 0)
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

#endif  // os(macOS) — iPad reference; see Platform/iOS
