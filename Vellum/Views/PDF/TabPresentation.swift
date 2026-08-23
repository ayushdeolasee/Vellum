import Foundation

/// How a tab names and pictures itself, in one nonisolated place so the tab
/// strip, the tab overview and the rename sheet all agree.
///
/// On main this lives at the bottom of `TabBarView.swift`. The iPad keeps it in
/// its own file because that whole file is inside `#if os(macOS)` (a parity
/// reference — see `Platform/iOS/PdfChrome_iOS.swift` for the live strip), and
/// these helpers have to be reachable from the iOS build.
///
/// ⚠ `title(for:)` is deliberately NOT what `TabChip_iOS` shows for a WEB tab.
/// The chip runs `RecentFilesService.webpageDisplayName(for:)`, which prettifies
/// a URL into a host/slug; this falls back to the raw last path component the
/// way main does. Packet 4 §2.12.1 offers both options and prefers the smaller
/// blast radius: the chip keeps its own derivation, and `TabPresentation` backs
/// the OVERVIEW and the rename sheet's placeholder. The two surfaces therefore
/// agree for PDFs (both end up at the document title, or the filename minus
/// `.pdf`) and differ for an untitled webpage, where the chip is friendlier.
enum TabPresentation {
    static func title(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "New Tab" }
        if let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        return fallbackName(for: tab)
    }

    /// The name to show when a document carries no title of its own: its file
    /// name, minus a `.pdf` extension. Lives here — nonisolated, beside the
    /// other presentation helpers — so both the strip and the overview can use
    /// it without hopping actors.
    static func fallbackName(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "New Tab" }
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
