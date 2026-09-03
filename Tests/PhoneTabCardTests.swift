#if os(iOS)
import Foundation
import SwiftUI
import Testing
import UIKit

@testable import Vellum

// The phone tab switcher's content, decided as values (#153 P7).
//
// `PhoneTabCardBuilder` is a pure function over `[PdfTab]` plus a residency
// predicate, which is what lets the whole switcher be checked without a
// simulator: ordering, the title fallbacks, the current-card flag, the honest
// evicted state — and the rule that matters most, that describing forty tabs
// must not bring forty `LiveTabRuntime`s into existence.

@MainActor
@Suite
struct PhoneTabCardTests {

    // MARK: - Ordering and identity

    @Test("Cards follow the tab list exactly — same order, same ids, no cap")
    func cardsMirrorTheTabList() {
        let tabs = [
            tab(id: "a", document: pdf(path: "/docs/Alpha.pdf", title: "Alpha")),
            tab(id: "b", document: web(url: "https://example.com/post")),
            tab(id: "c", document: pdf(path: "/docs/Gamma.pdf", title: "Gamma")),
        ]

        let cards = PhoneTabCardBuilder.cards(
            tabs: tabs, activeTabId: "b", isResident: { _ in true })

        #expect(cards.map(\.id) == ["a", "b", "c"])
        #expect(cards.map(\.kind) == [.pdf, .web, .pdf])
    }

    @Test("A hundred and twenty open documents produce a hundred and twenty cards")
    func theSwitcherDoesNotTruncate() {
        // The grid is lazy, so the long tail costs a value per tab and not a
        // view. A cap would strand the tabs it dropped: still open, still
        // counted in the bar, and no longer reachable from anywhere.
        let tabs = (0..<120).map { index in
            tab(id: "t\(index)", document: pdf(path: "/docs/\(index).pdf", title: nil))
        }

        let cards = PhoneTabCardBuilder.cards(
            tabs: tabs, activeTabId: "t0", isResident: { _ in false })

        #expect(cards.count == 120)
        #expect(cards.last?.id == "t119")
    }

    @Test("Exactly the active tab is current, and nothing is current when none is active")
    func theCurrentCardIsTheActiveTab() {
        let tabs = [
            tab(id: "a", document: pdf(path: "/docs/A.pdf", title: "A")),
            tab(id: "b", document: pdf(path: "/docs/B.pdf", title: "B")),
        ]

        let cards = PhoneTabCardBuilder.cards(
            tabs: tabs, activeTabId: "b", isResident: { _ in true })
        #expect(cards.filter(\.isCurrent).map(\.id) == ["b"])

        let none = PhoneTabCardBuilder.cards(
            tabs: tabs, activeTabId: nil, isResident: { _ in true })
        #expect(none.allSatisfy { !$0.isCurrent })
    }

    // MARK: - Titles

    @Test("A document's own title wins; otherwise the compact display name; otherwise Untitled")
    func titleFallbacksInOrder() {
        // Titled.
        #expect(
            PhoneTabCardBuilder.title(for: tab(
                id: "1", document: pdf(path: "/docs/paper-final-v3.pdf", title: "On Reading")))
                == "On Reading")

        // Untitled PDF: the filename, not the path.
        #expect(
            PhoneTabCardBuilder.title(for: tab(
                id: "2", document: pdf(path: "/docs/deep/paper.pdf", title: nil)))
                == "paper.pdf")

        // Whitespace is not a title.
        #expect(
            PhoneTabCardBuilder.title(for: tab(
                id: "3", document: pdf(path: "/docs/paper.pdf", title: "   ")))
                == "paper.pdf")

        // Untitled webpage: host + path, never the raw URL — at 180pt wide a
        // URL truncates to its scheme.
        #expect(
            PhoneTabCardBuilder.title(for: tab(
                id: "4", document: web(url: "https://example.com/notes/one/")))
                == "example.com/notes/one")

        // A start tab. The phone never mints one (D1), but a restored or
        // iPad-written workspace can still contain one and the switcher shows
        // it rather than dropping it.
        #expect(PhoneTabCardBuilder.title(for: tab(id: "5", document: nil)) == "Untitled")
    }

    @Test("The subtitle carries provenance, and degrades rather than repeating the title")
    func subtitleNeverRestatesTheTitle() {
        // Title and filename differ: show where it came from.
        #expect(
            PhoneTabCardBuilder.subtitle(for: tab(
                id: "1", document: pdf(path: "/docs/paper.pdf", title: "On Reading")))
                == "paper.pdf")

        // Untitled PDF: the title already IS the filename, so two identical
        // lines would read as a rendering bug.
        #expect(
            PhoneTabCardBuilder.subtitle(for: tab(
                id: "2", document: pdf(path: "/docs/paper.pdf", title: nil)))
                == "PDF")

        #expect(
            PhoneTabCardBuilder.subtitle(for: tab(
                id: "3", document: web(url: "https://example.com/post")))
                == "Webpage")

        #expect(
            PhoneTabCardBuilder.subtitle(for: tab(
                id: "4", document: web(url: "https://example.com/post", title: "A Post")))
                == "example.com/post")
    }

    @Test("Repeated instances of one source receive distinct, non-persisted ordinals")
    func duplicateSourcesAreDistinguishable() {
        let sharedURL = "https://example.com/post"
        let tabs = [
            tab(id: "first", document: web(url: sharedURL, title: "A Post")),
            tab(id: "other", document: web(url: "https://example.com/other", title: "A Post")),
            tab(id: "second", document: web(url: sharedURL, title: "A Post")),
        ]

        let cards = PhoneTabCardBuilder.cards(
            tabs: tabs, activeTabId: "first", isResident: { _ in false })

        #expect(cards.map(\.duplicateLabel) == ["Duplicate 1 of 2", nil, "Duplicate 2 of 2"])
        #expect(cards[0].title == cards[2].title)
        #expect(cards[0].subtitle == cards[2].subtitle)
    }

    @Test("The page label appears only for PDFs whose page count is known")
    func pageLabelIsPdfOnlyAndOnlyWhenKnown() {
        var pdfTab = tab(id: "1", document: pdf(path: "/docs/A.pdf", title: "A"))
        pdfTab.currentPage = 7
        pdfTab.numPages = 210
        #expect(PhoneTabCardBuilder.pageLabel(for: pdfTab) == "7 / 210")
        #expect(PhoneTabCardBuilder.previewPageNumber(for: pdfTab) == 7)
        #expect(PhoneTabCardBuilder.thumbnailPath(for: pdfTab) == "/docs/A.pdf")

        // Mid-open: "1 / 0" is a number that is simply wrong.
        var opening = pdfTab
        opening.numPages = 0
        #expect(PhoneTabCardBuilder.pageLabel(for: opening) == nil)
        #expect(PhoneTabCardBuilder.previewPageNumber(for: opening) == nil)

        // A webpage has no pages.
        var webTab = tab(id: "2", document: web(url: "https://example.com/post"))
        webTab.numPages = 3
        #expect(PhoneTabCardBuilder.pageLabel(for: webTab) == nil)
        #expect(PhoneTabCardBuilder.previewPageNumber(for: webTab) == nil)
        #expect(PhoneTabCardBuilder.thumbnailPath(for: webTab) == nil)

        #expect(PhoneTabCardBuilder.pageLabel(for: tab(id: "3", document: nil)) == nil)
    }

    // MARK: - Residency

    @Test("Residency comes from the injected predicate, per tab")
    func residencyIsAskedPerTab() {
        let tabs = [
            tab(id: "hot", document: pdf(path: "/docs/A.pdf", title: "A")),
            tab(id: "cold", document: pdf(path: "/docs/B.pdf", title: "B")),
        ]

        var asked: [String] = []
        let cards = PhoneTabCardBuilder.cards(tabs: tabs, activeTabId: "hot") { id in
            asked.append(id)
            return id == "hot"
        }

        #expect(asked == ["hot", "cold"])
        #expect(cards.first(where: { $0.id == "hot" })?.isResident == true)
        #expect(cards.first(where: { $0.id == "cold" })?.isResident == false)
    }

    @Test("Building cards allocates no live-tab runtimes and disturbs no residency")
    func buildingCardsDoesNotAllocateRuntimes() {
        // THE RULE OF THIS PACKET. `WorkspaceStore.liveTabRuntime(for:)` mints a
        // runtime for any tab that lacks one, so asking it once per card would
        // bring the entire window into existence every time the switcher was
        // drawn — on the idiom with the smallest residency budget in the app.
        // The predicate below is the one `PhoneTabSwitcher_iOS` uses: two pure
        // reads, neither of which creates anything.
        let workspace = WorkspaceStore(sessions: DocumentSessionManager(), layout: .singlePane)
        let tabs = (0..<40).map { index in
            tab(id: "t\(index)", document: pdf(path: "/docs/\(index).pdf", title: nil))
        }

        let before = workspace.residency.residentTabCount
        let cards = PhoneTabCardBuilder.cards(tabs: tabs, activeTabId: "t0") { id in
            guard let runtime = workspace.existingLiveTabRuntime(for: id),
                  !runtime.isEvicted else { return false }
            return workspace.residency.isResident(tabId: id)
        }

        #expect(cards.count == 40)
        #expect(workspace.residency.residentTabCount == before)
        // And no runtime was conjured on the side: every tab is still unknown
        // to the workspace after describing all forty of them.
        #expect(tabs.allSatisfy { workspace.existingLiveTabRuntime(for: $0.id) == nil })
        #expect(cards.allSatisfy { !$0.isResident })
    }

    @Test("Tab card labels grow rather than staying tiny at accessibility sizes")
    func cardLabelsRespondToDynamicType() throws {
        let card = try #require(
            PhoneTabCardBuilder.cards(
                tabs: [tab(
                    id: "dynamic-type",
                    document: pdf(
                        path: "/docs/a-long-source-name.pdf",
                        title: "A deliberately long document title for layout"))],
                activeTabId: "dynamic-type",
                isResident: { _ in false })
                .first)

        let normal = cardHeight(card, dynamicTypeSize: .large)
        let accessible = cardHeight(card, dynamicTypeSize: .accessibility5)
        #expect(
            accessible > normal,
            "tab card labels are not responding to the user's Dynamic Type setting")
    }

    @Test("Accessibility text switches the tab grid to one readable column")
    func accessibilityLayoutUsesOneColumn() {
        #expect(PhoneTabSwitcherLayout.columnCount(for: .large) == 2)
        #expect(PhoneTabSwitcherLayout.columnCount(for: .accessibility1) == 1)
        #expect(PhoneTabSwitcherLayout.columnCount(for: .accessibility5) == 1)
        #expect(PhoneTabSwitcherLayout.accessibilityPreviewHeight <= 160)
    }

    // MARK: - Fixtures

    private func tab(id: String, document: DocumentInfo?) -> PdfTab {
        PdfTab(
            id: id,
            document: document,
            currentPage: 1,
            numPages: document?.pageCount ?? 0,
            zoom: 1,
            visiblePages: [],
            webVisibleRange: nil,
            webVisibleBookmarks: [],
            mode: .view)
    }

    private func pdf(path: String, title: String?) -> DocumentInfo {
        DocumentInfo(kind: .pdf, pdfPath: path, title: title, pageCount: 4, lastPage: 1)
    }

    private func web(url: String, title: String? = nil) -> DocumentInfo {
        DocumentInfo(kind: .web, pdfPath: url, title: title, pageCount: nil, lastPage: nil)
    }

    private func cardHeight(
        _ card: PhoneTabCard,
        dynamicTypeSize: DynamicTypeSize
    ) -> CGFloat {
        let width: CGFloat = 336
        let host = UIHostingController(
            rootView: PhoneTabCardView(
                card: card,
                palette: .light,
                thumbnailRevision: 0,
                loadThumbnail: { nil },
                open: {},
                close: {})
                .dynamicTypeSize(dynamicTypeSize))
        host.view.frame = CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude)
        return host.sizeThatFits(
            in: CGSize(width: width, height: UIView.layoutFittingCompressedSize.height)
        ).height
    }
}
#endif
