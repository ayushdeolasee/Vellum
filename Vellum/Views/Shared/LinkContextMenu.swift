#if os(macOS)
import AppKit
import SwiftUI

/// What a reader (article or PDF) does with a link the user clicked or
/// right-clicked. One place so both viewers apply the same scheme policy.
@MainActor
enum DocumentLinkActions {
    /// Only http(s) links are browsable in the sidebar browser. Everything else
    /// (mailto:, tel:, file:, javascript:, custom app schemes) is either handed to
    /// the system or ignored by the caller.
    static func isBrowsable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }

    /// Parses a URL string that crossed a page-script bridge. Untrusted input:
    /// anything that is not an absolute http(s) URL is rejected.
    static func browsableURL(from string: String?) -> URL? {
        guard let string, let url = URL(string: string), isBrowsable(url) else { return nil }
        return url
    }

    /// Plain left-click on a link: http(s) opens beside the document in the
    /// sidebar browser; the common external schemes go to their system handler.
    /// Returns false when nothing could take the link (the caller may fall back).
    @discardableResult
    static func activate(_ url: URL, workspace: WorkspaceStore?) -> Bool {
        if isBrowsable(url), let workspace {
            workspace.openInSidebarBrowser(url)
            return true
        }
        if let scheme = url.scheme?.lowercased(), ["mailto", "tel", "facetime"].contains(scheme) {
            NSWorkspace.shared.open(url)
            return true
        }
        return false
    }

    static func openInDefaultBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Writes both the URL type (so pasting into Finder/Safari/Mail treats it
    /// as a link) and plain text (so pasting into a text field gets the address).
    static func copy(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        pasteboard.setString(url.absoluteString, forType: .string)
    }
}

/// Right-click menu shared by the article and PDF viewers. With no link under
/// the pointer it collapses to the original single "Add note here" pill; over a
/// link it adds the three link actions above it.
struct DocumentContextMenuView: View {
    var linkURL: URL?
    var canAddNote: Bool = true
    var addNoteHelp: String = ""
    var onOpenInSidebar: () -> Void = {}
    var onOpenInDefaultBrowser: () -> Void = {}
    var onCopyLink: () -> Void = {}
    var onAddNote: () -> Void

    var body: some View {
        Group {
            if let linkURL {
                VStack(alignment: .leading, spacing: 0) {
                    Text(linkURL.host ?? linkURL.absoluteString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal, 13)
                        .padding(.top, 7)
                        .padding(.bottom, 3)
                        .frame(maxWidth: 260, alignment: .leading)
                        .help(linkURL.absoluteString)
                    DocumentContextMenuRow(
                        title: "Open in Integrated Browser", systemImage: "sidebar.right",
                        action: onOpenInSidebar)
                        .accessibilityIdentifier("documentLinkMenu.openInSidebar")
                    DocumentContextMenuRow(
                        title: "Open in Default Browser", systemImage: "safari",
                        action: onOpenInDefaultBrowser)
                        .accessibilityIdentifier("documentLinkMenu.openInDefaultBrowser")
                    DocumentContextMenuRow(
                        title: "Copy Link", systemImage: "link",
                        action: onCopyLink)
                        .accessibilityIdentifier("documentLinkMenu.copyLink")
                    Divider().padding(.vertical, 3)
                    DocumentContextMenuRow(
                        title: "Add note here", systemImage: "note.text",
                        iconColor: WebAmber.amber500, isEnabled: canAddNote,
                        action: onAddNote)
                        .help(addNoteHelp)
                }
                .padding(.vertical, 4)
                .fixedSize()
            } else {
                DocumentContextMenuRow(
                    title: "Add note here", systemImage: "note.text",
                    iconColor: WebAmber.amber500, isEnabled: canAddNote,
                    action: onAddNote)
                    .help(addNoteHelp)
                    // The single-action pill hugs its label.
                    .fixedSize()
            }
        }
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.lg))
    }
}

private struct DocumentContextMenuRow: View {
    let title: String
    let systemImage: String
    var iconColor: Color? = nil
    var isEnabled = true
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 13))
                    .foregroundStyle(iconColor ?? palette.mutedForeground)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.foreground)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            // Frame + contentShape inside the label so the whole row (not just
            // the glyph and text) is clickable.
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
        // Hover darkens the whole row edge to edge, behind the label.
        .background {
            if hovering && isEnabled {
                RoundedRectangle(cornerRadius: Radius.lg).fill(.black.opacity(0.25))
            }
        }
        .onHover { hovering = $0 }
    }
}
#endif
