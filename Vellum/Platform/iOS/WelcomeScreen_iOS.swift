#if os(iOS)
import SwiftUI
import UniformTypeIdentifiers

/// The iPad library / start screen: the parchment identity, primary open
/// actions, and a grid of recent documents. Shown full-screen when no tabs are
/// open and, in `compact` form, as the content of an active "start tab".
struct WelcomeLibrary_iOS: View {
    var onOpen: () -> Void
    var onAddWebpage: () -> Void
    var compact = false

    @Environment(AppStore.self) private var appStore
    @Environment(\.palette) private var palette
    @State private var recents = RecentFilesService.getRecent()

    private let columns = [GridItem(.adaptive(minimum: 240, maximum: 320), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(spacing: compact ? 24 : 36) {
                header
                actions
                if !recents.isEmpty {
                    recentsSection
                }
            }
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, compact ? 32 : 72)
            .padding(.bottom, 48)
        }
        .background(palette.background.ignoresSafeArea())
        .onAppear { recents = RecentFilesService.getRecent() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Wordmark(size: compact ? 40 : 60)
            Text("AI-powered reading for iPad")
                .font(compact ? .headline : .title3)
                .foregroundStyle(palette.mutedForeground)
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            TextButton(variant: .primary, size: .lg, action: onOpen) {
                Label("Open a PDF", systemImage: "doc.badge.plus")
            }
            TextButton(variant: .secondary, size: .lg, action: onAddWebpage) {
                Label("Add Webpage", systemImage: "globe")
            }
        }
    }

    private var recentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(palette.mutedForeground)
                .frame(maxWidth: .infinity, alignment: .leading)
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(recents, id: \.pdfPath) { item in
                    RecentCard_iOS(item: item) { open(item) }
                }
            }
        }
    }

    private func open(_ item: RecentDocument) {
        if item.kind == .web {
            Task { await appStore.openUrl(item.pdfPath) }
        } else {
            Task { await appStore.openFiles(paths: [item.pdfPath]) }
        }
    }
}

private struct RecentCard_iOS: View {
    let item: RecentDocument
    let action: () -> Void

    @Environment(\.palette) private var palette

    private var displayName: String {
        let base = item.kind == .web
            ? RecentFilesService.webpageDisplayName(for: item.pdfPath)
            : RecentFilesService.fileName(for: item.pdfPath)
        let trimmed = item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? base : trimmed
    }

    private var onDisk: Bool {
        item.kind == .web || FileManager.default.fileExists(atPath: item.pdfPath)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: item.kind == .web ? "globe" : "doc.text.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(palette.primary)
                    .frame(width: 40, height: 40)
                    .background(palette.primary.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md))
                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.lg)
                    .strokeBorder(palette.border, lineWidth: 1)
            )
            .opacity(onDisk ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(!onDisk)
        .accessibilityLabel(displayName)
    }

    private var subtitle: String {
        if item.kind == .web { return RecentFilesService.webpageDisplayName(for: item.pdfPath) }
        if let count = item.pageCount, count > 0 { return "\(count) pages" }
        return "PDF"
    }
}
#endif
