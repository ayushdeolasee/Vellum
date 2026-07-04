import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct WelcomeScreen: View {
    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette

    @State private var recentDocuments = RecentFilesService.getRecent()
    @State private var savedPages: [WebLibraryEntry] = []
    @State private var urlInput = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                hero
                openControls
                urlControls

                if let error = appStore.error {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.destructive)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .frame(maxWidth: 448)
                        .background(palette.destructive.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.md)
                                .strokeBorder(palette.destructive.opacity(0.3))
                        }
                        .padding(.top, 20)
                }

                if !savedPages.isEmpty {
                    savedPagesSection
                        .padding(.top, 48)
                }

                if !recentDocuments.isEmpty {
                    recentSection
                        .padding(.top, 48)
                }
            }
            .frame(maxWidth: 672)
            .padding(.horizontal, 24)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.well)
        .task {
            if let pages = try? await appStore.sessions.listSavedWebpages() {
                guard !Task.isCancelled else { return }
                savedPages = pages
            }
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            Image(systemName: "doc.text")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(.tint)
                .frame(width: 64, height: 64)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.xxl))
                .padding(.bottom, 12)

            Wordmark(size: 36)

            Text("A quiet place to read, annotate, and think alongside your documents.")
                .font(.system(size: 14))
                .foregroundStyle(palette.mutedForeground)
                .padding(.top, 8)
        }
    }

    private var openControls: some View {
        HStack(spacing: 12) {
            TextButton(size: .lg, disabled: appStore.isLoading, action: openDocuments) {
                Image(systemName: "folder")
                    .font(.system(size: 18))
                Text(appStore.isLoading ? "Opening…" : "Open a PDF")
            }
            .accessibilityIdentifier("welcome.openPdf")

            HStack(spacing: 4) {
                Text("or press")
                Text("⌘O")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.sm))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.sm)
                            .strokeBorder(.separator)
                    }
            }
            .font(.system(size: 12))
            .foregroundStyle(palette.mutedForeground)
        }
        .padding(.top, 28)
    }

    private var urlControls: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 15))
                    .foregroundStyle(palette.mutedForeground)
                TextField("Or read a webpage — paste an article URL", text: $urlInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(palette.foreground)
                    .disabled(appStore.isLoading)
                    .onSubmit(openUrl)
                    .accessibilityIdentifier("welcome.urlField")
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            .glassEffect(.regular, in: .capsule)

            TextButton(
                disabled: appStore.isLoading || trimmedUrl.isEmpty,
                action: openUrl
            ) {
                Text("Open")
            }
            .accessibilityIdentifier("welcome.openUrl")
        }
        .frame(maxWidth: 448)
        .padding(.top, 16)
    }

    private var savedPagesSection: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Saved pages", systemImage: "archivebox")

            VStack(spacing: 8) {
                ForEach(savedPages, id: \.url) { page in
                    SavedPageRow(
                        page: page,
                        isLoading: appStore.isLoading,
                        onOpen: { Task { await appStore.openUrl(page.url) } },
                        onRemove: { removeSavedPage(page.url) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var recentSection: some View {
        VStack(spacing: 8) {
            SectionHeader(title: "Recently opened", systemImage: "clock")

            VStack(spacing: 8) {
                ForEach(recentDocuments, id: \.pdfPath) { entry in
                    RecentDocumentRow(
                        entry: entry,
                        isLoading: appStore.isLoading,
                        onOpen: { openRecent(entry) },
                        onRemove: { recentDocuments = RecentFilesService.remove(path: entry.pdfPath) }
                    )
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var trimmedUrl: String {
        urlInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func openUrl() {
        let value = trimmedUrl
        guard !value.isEmpty else { return }
        urlInput = ""
        Task { await appStore.openUrl(value) }
    }

    private func openRecent(_ entry: RecentDocument) {
        Task {
            if entry.kind == .web {
                await appStore.openUrl(entry.pdfPath)
            } else {
                await appStore.openFile(path: entry.pdfPath)
            }
        }
    }

    private func removeSavedPage(_ url: String) {
        savedPages.removeAll { $0.url == url }
        Task { try? await appStore.sessions.removeSavedWebpage(url: url) }
    }

    private func openDocuments() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        var types: [UTType] = [.pdf]
        if let archive = UTType(filenameExtension: "vellumweb") {
            types.append(archive)
        }
        panel.allowedContentTypes = types
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task { await appStore.openFiles(paths: paths) }
    }
}

private struct SectionHeader: View {
    let title: String
    let systemImage: String

    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
            Text(title.uppercased())
                .tracking(0.5)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(palette.mutedForeground)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SavedPageRow: View {
    let page: WebLibraryEntry
    let isLoading: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    private var displayName: String { RecentFilesService.webpageDisplayName(for: page.url) }
    private var displayTitle: String {
        let title = page.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? displayName : title
    }

    var body: some View {
        DocumentRow(
            icon: "globe",
            title: displayTitle,
            subtitle: displayName + (page.hasSnapshot ? " · available offline" : ""),
            tooltip: page.url,
            isLoading: isLoading,
            hovering: hovering,
            removeHelp: "Remove from saved pages",
            removeAccessibilityLabel: "Remove \(displayTitle) from saved pages",
            onOpen: onOpen,
            onRemove: onRemove
        )
        .onHover { hovering = $0 }
    }
}

private struct RecentDocumentRow: View {
    let entry: RecentDocument
    let isLoading: Bool
    let onOpen: () -> Void
    let onRemove: () -> Void

    @State private var hovering = false

    private var fileName: String {
        entry.kind == .web
            ? RecentFilesService.webpageDisplayName(for: entry.pdfPath)
            : RecentFilesService.fileName(for: entry.pdfPath)
    }

    private var displayTitle: String {
        let title = entry.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? fileName : title
    }

    private var subtitle: String {
        var pieces: [String] = []
        if displayTitle != fileName { pieces.append(fileName) }
        if entry.kind == .pdf, let count = entry.pageCount, count != 0 {
            pieces.append("\(count) \(count == 1 ? "page" : "pages")")
        }
        pieces.append(Self.formatOpenedDate(entry.openedAt))
        return pieces.joined(separator: " · ")
    }

    var body: some View {
        DocumentRow(
            icon: entry.kind == .web ? "globe" : "doc.text",
            title: displayTitle,
            subtitle: subtitle,
            tooltip: entry.pdfPath,
            isLoading: isLoading,
            hovering: hovering,
            removeHelp: "Remove \(fileName) from recent files",
            removeAccessibilityLabel: "Remove \(fileName) from recent files",
            onOpen: onOpen,
            onRemove: onRemove
        )
        .onHover { hovering = $0 }
    }

    private static func formatOpenedDate(_ openedAt: String) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = iso.date(from: openedAt) ?? ISO8601DateFormatter().date(from: openedAt)
        guard let date else { return "Recently opened" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

#Preview("Saved page rows") {
    VStack(spacing: 8) {
        DocumentRow(
            icon: "globe",
            title: "Example Domain",
            subtitle: "example.com · available offline",
            tooltip: "https://example.com",
            isLoading: false,
            hovering: true,
            removeHelp: "Remove from saved pages",
            removeAccessibilityLabel: "Remove",
            onOpen: {},
            onRemove: {}
        )
        DocumentRow(
            icon: "globe",
            title: "Jane Street Blog - Can you reverse engineer our neural network?",
            subtitle: "blog.janestreet.com/can-you-reverse-engineer-our-neural-network · available offline",
            tooltip: "https://blog.janestreet.com",
            isLoading: false,
            hovering: false,
            removeHelp: "Remove from saved pages",
            removeAccessibilityLabel: "Remove",
            onOpen: {},
            onRemove: {}
        )
    }
    .frame(width: 660)
    .padding(24)
    .background(Color(hex: "#1a1a1a"))
    .environment(\.palette, .dark)
    .preferredColorScheme(.dark)
}

#Preview("Hero wordmark") {
    VStack(spacing: 12) {
        Image(systemName: "doc.text")
            .font(.system(size: 30, weight: .regular))
            .foregroundStyle(.tint)
            .frame(width: 64, height: 64)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.xxl))
        Wordmark(size: 36)
    }
    .padding(40)
    .background(Color(hex: "#1a1a1a"))
    .environment(\.palette, .dark)
    .preferredColorScheme(.dark)
    .tint(ThemePalette.dark.primary)
}

private struct DocumentRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let tooltip: String
    let isLoading: Bool
    let hovering: Bool
    let removeHelp: String
    let removeAccessibilityLabel: String
    let onOpen: () -> Void
    let onRemove: () -> Void

    @Environment(\.palette) private var palette
    @State private var removeHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(hovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .frame(width: 36, height: 36)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.lg))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.lg)
                                .strokeBorder(.separator)
                        }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(palette.foreground)
                            .lineLimit(1)
                        Text(subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(palette.mutedForeground)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .opacity(isLoading ? 0.5 : 1)
            .help(tooltip)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 15))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(removeHovering ? AnyShapeStyle(palette.destructive) : AnyShapeStyle(.secondary))
                    .background(
                        removeHovering ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: Radius.md))
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .onHover { removeHovering = $0 }
            .help(removeHelp)
            .accessibilityLabel(removeAccessibilityLabel)
            // Optically matches the 16pt leading content inset (the glyph
            // sits inset within its 32pt hit target).
            .padding(.trailing, 12)
        }
        // Hover tint layered over the card material so the highlight shares
        // the card's rounded shape instead of squaring off at the edges.
        .background(
            hovering ? AnyShapeStyle(.quaternary.opacity(0.35)) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: Radius.xl))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.xl))
        .background(.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.xl))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.xl)
                .strokeBorder(.separator)
        }
    }
}
