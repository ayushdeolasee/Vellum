#if os(iOS)
import Foundation

/// One card in the phone's tab switcher (#153 P7).
///
/// A value, not a view model: everything the grid draws is decided here, so the
/// switcher's content is testable without mounting a `LazyVGrid` and without a
/// simulator. `Equatable` so SwiftUI can skip a card whose description did not
/// change while its neighbours did (a page turn in the current tab must not
/// redraw forty cards).
///
/// `kind` is optional for the same reason `PdfTab.document` is: a start tab has
/// no document. The phone never mints one (D1 — Home is a route, so
/// `newStartTab()` is never called), but a session restored from disk or an
/// iPad-written workspace can still contain one, and a switcher that crashed or
/// silently dropped a tab it did not expect would be worse than one that shows
/// it honestly.
struct PhoneTabCard: Identifiable, Equatable, Sendable {
    /// The tab id — the same string `AppStore.activateTab`/`closeTab` take, so
    /// a card's actions need nothing else.
    let id: String

    /// What the document calls itself, with the fallbacks below applied.
    let title: String

    /// Where it came from: a host/slug for a webpage, a filename for a PDF —
    /// and the type label when that would only repeat the title.
    let subtitle: String

    /// `nil` for a start tab.
    let kind: DocumentKind?

    /// Compact position, e.g. `"7 / 210"`. `nil` for webpages (no pages) and
    /// for PDFs whose page count is not known yet.
    let pageLabel: String?

    /// The tab the reader is showing. Exactly one card carries this, and it is
    /// the one that gets the ring.
    let isCurrent: Bool

    /// Whether the tab is still backed by live native state. `false` means the
    /// residency policy has released it (or it has never been opened in this
    /// session) and tapping the card pays a reload — which the card says so
    /// out loud rather than pretending the switch will be instant.
    let isResident: Bool
}

/// Builds the switcher's cards from the tab list.
///
/// ## The rule this type exists to enforce
///
/// Residency is asked through the `isResident` predicate the caller supplies,
/// and the shell supplies one built from `WorkspaceStore.existingLiveTabRuntime(for:)`
/// plus `TabResidencyManager.isResident(tabId:)`. It must NEVER be
/// `WorkspaceStore.liveTabRuntime(for:)`: that call *mints* a runtime for any
/// tab that does not have one (see the comment at `WorkspaceStore.swift:298`),
/// so asking it once per card would allocate a `LiveTabRuntime` for every tab in
/// the window every time the switcher was drawn — the exact opposite of what a
/// switcher over a phone-sized residency budget is for.
///
/// Keeping the question behind a closure is what makes that testable: the suite
/// passes its own predicate and asserts the resident-tab count is unchanged
/// across a build.
enum PhoneTabCardBuilder {
    /// Cards in `tabs` order — the order the user has been arranging all along.
    /// There is deliberately no cap and no truncation: forty open documents is a
    /// state the app supports, and a switcher that quietly stopped listing them
    /// would strand the ones it dropped (they are still open, still resident,
    /// and no longer reachable). The grid is lazy, so the cost of the long tail
    /// is a value per tab, not a view.
    static func cards(
        tabs: [PdfTab],
        activeTabId: String?,
        isResident: (String) -> Bool
    ) -> [PhoneTabCard] {
        tabs.map { tab in
            PhoneTabCard(
                id: tab.id,
                title: title(for: tab),
                subtitle: subtitle(for: tab),
                kind: tab.document?.kind,
                pageLabel: pageLabel(for: tab),
                isCurrent: tab.id == activeTabId,
                isResident: isResident(tab.id))
        }
    }

    /// The document's own title when it has a usable one, then the same
    /// compact display names the tab strip and Home use — a filename for a PDF,
    /// `host/path` for a webpage — and "Untitled" when even that is empty.
    ///
    /// `RecentFilesService`'s helpers rather than `TabPresentation.title(for:)`
    /// for one reason: they prettify a webpage's URL into `host/path`, which
    /// main's helper does not, and a column of raw URLs at 180pt wide truncates
    /// to the scheme. `TabChip_iOS` made the same choice for the same reason.
    static func title(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "Untitled" }
        if let title = document.title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        let fallback = document.kind == .web
            ? RecentFilesService.webpageDisplayName(for: document.pdfPath)
            : RecentFilesService.fileName(for: document.pdfPath)
        return fallback.isEmpty ? "Untitled" : fallback
    }

    /// The provenance line. When it would only restate the title (a PDF whose
    /// title *is* its filename, which is most of them) it degrades to the type
    /// label instead — two identical lines of text read as a rendering bug.
    static func subtitle(for tab: PdfTab) -> String {
        guard let document = tab.document else { return "Nothing open" }
        let typeLabel = document.kind == .web ? "Webpage" : "PDF"
        let source = document.kind == .web
            ? RecentFilesService.webpageDisplayName(for: document.pdfPath)
            : RecentFilesService.fileName(for: document.pdfPath)
        if source.isEmpty || source == title(for: tab) { return typeLabel }
        return source
    }

    /// `"7 / 210"`. PDFs only, and only once the page count is known: `"1 / 0"`
    /// during the first frames of an open is a number that is simply wrong.
    static func pageLabel(for tab: PdfTab) -> String? {
        guard let document = tab.document, document.kind != .web else { return nil }
        guard tab.numPages > 0 else { return nil }
        return "\(tab.currentPage) / \(tab.numPages)"
    }
}
#endif
