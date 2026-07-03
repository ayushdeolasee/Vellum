import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TabBarView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Wordmark()
                .fixedSize()

            if !appStore.tabs.isEmpty {
                Rectangle()
                    .fill(palette.border)
                    .frame(width: 1, height: 20)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(appStore.tabs) { tab in
                        TabItem(
                            tab: tab,
                            isActive: tab.id == appStore.activeTabId,
                            onActivate: { appStore.activateTab(tab.id) },
                            onClose: { Task { await appStore.closeTab(tab.id) } }
                        )
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxWidth: .infinity)

            IconButton(help: "Open PDF in new tab", action: openPdf) {
                Image(systemName: "plus")
                    .font(.system(size: 16))
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 40)
        .background(palette.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
        }
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
    let isActive: Bool
    let onActivate: () -> Void
    let onClose: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var label: String {
        if let title = tab.document.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let fallback = tab.document.pdfPath
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
                    Image(systemName: "doc.text")
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? palette.primary : palette.mutedForeground)
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

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12))
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.mutedForeground)
            .opacity(hovering ? 1 : 0)
            .padding(.trailing, 4)
            .help("Close \(label)")
            .accessibilityLabel("Close \(label)")
        }
        .font(.system(size: 12))
        .foregroundStyle(isActive ? palette.foreground : palette.mutedForeground)
        .frame(minWidth: 128, idealWidth: 176, maxWidth: 224, minHeight: 28, maxHeight: 28)
        .background(isActive ? palette.surface : (hovering ? palette.accent : .clear))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(palette.borderStrong, lineWidth: 1)
            }
        }
        .shadow(color: isActive ? Color.black.opacity(0.08) : .clear, radius: 3, y: 1)
        .onHover { hovering = $0 }
        .help(tab.document.pdfPath)
        .overlay {
            MiddleClickView(action: onClose)
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

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let event = NSApp.currentEvent,
              event.type == .otherMouseDown || event.type == .otherMouseUp,
              event.buttonNumber == 2 else { return nil }
        return super.hitTest(point)
    }

    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseUp(with: event)
            return
        }
        action()
    }
}
