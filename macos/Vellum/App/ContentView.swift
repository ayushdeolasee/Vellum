import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var keyMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            TabBarView()

            if appStore.document == nil {
                ToolbarView()
                WelcomeScreen()
            } else {
                ToolbarView(
                    sidebarOpen: appStore.sidebarOpen,
                    onToggleSidebar: { appStore.sidebarOpen.toggle() }
                )

                HStack(spacing: 0) {
                    documentViewer
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if appStore.sidebarOpen {
                        sidebar
                            .frame(width: 320)
                            .frame(maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.background)
        .task(id: documentIdentity) {
            annotationStore.clearAnnotations()
            aiStore.clearDocumentContext()
            guard appStore.document?.pdfPath != nil else { return }
            await annotationStore.loadAnnotations()
            guard !Task.isCancelled else { return }
            aiStore.loadConversationForDocument(appStore.document)
        }
        .task(id: autosaveIdentity) {
            guard let identity = autosaveIdentity else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                guard !Task.isCancelled,
                      appStore.activeTabId == identity.tabId,
                      appStore.document != nil else { return }
                try? await appStore.sessions.saveFile(sessionId: identity.tabId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .vellumAnnotationsUpdated)) { _ in
            guard appStore.document != nil else { return }
            Task { await annotationStore.loadAnnotations() }
        }
        .onAppear(perform: installKeyMonitor)
        .onDisappear(perform: removeKeyMonitor)
    }

    @ViewBuilder
    private var documentViewer: some View {
        if appStore.document?.kind == .web {
            WebViewerView()
                .id(appStore.activeTabId)
        } else {
            PdfViewerView()
                .id(appStore.activeTabId)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                SidebarSegment(
                    title: "Annotations",
                    systemImage: "message",
                    selected: appStore.sidebarTab == .annotations,
                    action: { appStore.sidebarTab = .annotations }
                )
                SidebarSegment(
                    title: "AI",
                    systemImage: "sparkles",
                    selected: appStore.sidebarTab == .ai,
                    action: { appStore.sidebarTab = .ai }
                )
            }
            .padding(4)
            .background(palette.muted)
            .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
            .padding(8)

            Divider().overlay(palette.border)

            Group {
                if appStore.sidebarTab == .annotations {
                    AnnotationSidebar()
                } else {
                    AiPanel()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background(palette.background)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(palette.border)
                .frame(width: 1)
        }
    }

    private var documentIdentity: DocumentIdentity {
        DocumentIdentity(tabId: appStore.activeTabId, path: appStore.document?.pdfPath)
    }

    private var autosaveIdentity: AutosaveIdentity? {
        guard let tabId = appStore.activeTabId, appStore.document != nil else { return nil }
        return AutosaveIdentity(tabId: tabId, path: appStore.document?.pdfPath)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleKeyDown(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    /// Returns true when the event matches a Vellum shortcut and must not be
    /// passed on to AppKit.
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let command = modifiers.contains(.command)
        let key = (event.charactersIgnoringModifiers ?? "").lowercased()

        if command && key == "o" {
            openDocuments()
            return true
        }
        if command && key == "l" {
            NotificationCenter.default.post(name: .vellumAddWebpage, object: nil)
            return true
        }
        if command && key == "s" {
            if let sessionId = appStore.activeTabId {
                Task { try? await appStore.sessions.saveFile(sessionId: sessionId) }
            }
            return true
        }
        if command && key == "w" {
            Task { await appStore.closeFile() }
            return true
        }
        if command, key.count == 1, let number = Int(key), (1...9).contains(number) {
            let index = number - 1
            guard appStore.tabs.indices.contains(index) else { return false }
            appStore.activateTab(appStore.tabs[index].id)
            return true
        }
        if command && key == "=" {
            appStore.zoomIn()
            return true
        }
        if command && key == "-" {
            appStore.zoomOut()
            return true
        }
        if command && key == "b" {
            if appStore.document != nil {
                Task { await annotationStore.toggleBookmark() }
            }
            return true
        }
        if key == "\u{1b}" || event.keyCode == 53 {
            guard !isTextInputFirstResponder else { return false }
            annotationStore.selectAnnotation(nil)
            appStore.setMode(.view)
            return false
        }
        if !command && !modifiers.contains(.control) && key == "n" {
            guard !isTextInputFirstResponder, appStore.document != nil else { return false }
            appStore.setMode(appStore.mode == .note ? .view : .note)
            return true
        }
        return false
    }

    private var isTextInputFirstResponder: Bool {
        guard let responder = NSApp.keyWindow?.firstResponder else { return false }
        return responder is NSTextView || responder is NSTextField || responder is NSSearchField
    }

    private func openDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = Self.documentContentTypes
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await appStore.openFiles(paths: paths) }
    }

    private static var documentContentTypes: [UTType] {
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") {
            types.append(archive)
        }
        return types
    }
}

private struct DocumentIdentity: Hashable {
    var tabId: String?
    var path: String?
}

private struct AutosaveIdentity: Hashable {
    var tabId: String
    var path: String?
}

private struct SidebarSegment: View {
    let title: String
    let systemImage: String
    let selected: Bool
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                Text(title)
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .foregroundStyle(selected || hovering ? palette.foreground : palette.mutedForeground)
            .background(selected ? palette.surface : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Radius.md))
            .shadow(color: selected ? Color.black.opacity(0.08) : .clear, radius: 1, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
