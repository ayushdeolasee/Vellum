import AppKit
import XCTest
@testable import Vellum

// Coverage for the first-run walkthrough (issue #49): the once-only first-run
// flag, and the well-formedness of the page content the sheet renders.
//
// The content tests exist because the walkthrough is pure data driving a
// generic view — a bad SF Symbol name or a duplicated page id fails silently at
// runtime (an invisible gutter, a transition that never fires) instead of
// crashing, so the checks have to happen here.

final class WalkthroughSettingsTests: XCTestCase {
    /// The test host shares UserDefaults with the real app, so restore whatever
    /// the developer running the suite already had rather than clearing it and
    /// re-showing them the walkthrough at their next launch.
    private var priorValue: Any?

    override func setUp() {
        super.setUp()
        priorValue = UserDefaults.standard.object(forKey: WalkthroughSettings.seenKey)
        UserDefaults.standard.removeObject(forKey: WalkthroughSettings.seenKey)
    }

    override func tearDown() {
        if let priorValue {
            UserDefaults.standard.set(priorValue, forKey: WalkthroughSettings.seenKey)
        } else {
            UserDefaults.standard.removeObject(forKey: WalkthroughSettings.seenKey)
        }
        super.tearDown()
    }

    func testFreshInstallNeedsFirstRun() {
        XCTAssertTrue(WalkthroughSettings.needsFirstRun)
        XCTAssertFalse(WalkthroughSettings.hasSeenWalkthrough)
    }

    func testMarkSeenFlipsTheFlagExactlyOnce() {
        // The return value is the observable half of the once-only contract:
        // the first call owns the transition, every later call is a no-op.
        XCTAssertTrue(WalkthroughSettings.markSeen())
        XCTAssertFalse(WalkthroughSettings.markSeen())
        XCTAssertFalse(WalkthroughSettings.markSeen())

        XCTAssertTrue(WalkthroughSettings.hasSeenWalkthrough)
        XCTAssertFalse(WalkthroughSettings.needsFirstRun)
    }

    func testSeenStateIsReadBackFromUserDefaults() {
        // Guards the launch gate specifically: VellumApp reads this in a fresh
        // process, so the flag has to survive as a plain persisted bool rather
        // than as in-memory state.
        WalkthroughSettings.markSeen()
        XCTAssertTrue(UserDefaults.standard.bool(forKey: WalkthroughSettings.seenKey))
        XCTAssertFalse(WalkthroughSettings.needsFirstRun)
    }
}

final class WalkthroughContentTests: XCTestCase {
    private let pages = WalkthroughPage.all

    func testHasPagesAndEndsOnStorage() {
        XCTAssertFalse(pages.isEmpty)
        // The storage page answers the question the issue was actually filed
        // about, and carries the "reopen from Help" footnote, so it has to stay
        // last — the footnote assertion below depends on it.
        XCTAssertEqual(pages.last?.id, "storage")
    }

    func testPageIdsAreUniqueAndSlugLike() {
        // Ids become accessibility identifiers ("walkthrough.dot.<id>") and the
        // .id() that drives the page transition; a duplicate breaks both.
        let ids = pages.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate page id in \(ids)")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertEqual(id, id.lowercased(), "page id \(id) should be a lowercase slug")
            XCTAssertFalse(id.contains(" "), "page id \(id) should not contain spaces")
        }
    }

    func testEveryPageIsWellFormed() {
        for page in pages {
            XCTAssertFalse(page.title.isEmpty, "\(page.id) has no title")
            XCTAssertFalse(page.summary.isEmpty, "\(page.id) has no summary")
            // Two bullets isn't worth a page; more than five stops being
            // skimmable and overflows the sheet's fixed height.
            XCTAssertGreaterThanOrEqual(page.points.count, 3, "\(page.id) has too few points")
            XCTAssertLessThanOrEqual(page.points.count, 5, "\(page.id) has too many points")

            for point in page.points {
                XCTAssertFalse(point.text.isEmpty, "empty point text on \(page.id)")
                if let shortcut = point.shortcut {
                    XCTAssertFalse(shortcut.isEmpty, "empty shortcut on \(page.id)")
                }
            }

            let texts = page.points.map(\.text)
            XCTAssertEqual(Set(texts).count, texts.count, "duplicate point text on \(page.id)")
        }
    }

    func testOnlyTheFinalPageHasAFootnote() {
        // The footnote tells the user how to get back here, so it belongs at
        // the end and nowhere else.
        for page in pages.dropLast() {
            XCTAssertNil(page.footnote, "\(page.id) should not carry a footnote")
        }
        XCTAssertNotNil(pages.last?.footnote)
    }

    func testEverySymbolResolvesOnThisSystem() {
        // A misspelled SF Symbol renders as nothing at all — no crash, no
        // warning, just a blank gutter — so resolve every name for real.
        for page in pages {
            XCTAssertNotNil(
                NSImage(systemSymbolName: page.symbol, accessibilityDescription: nil),
                "page \(page.id) uses unknown SF Symbol \"\(page.symbol)\"")
            for point in page.points {
                XCTAssertNotNil(
                    NSImage(systemSymbolName: point.symbol, accessibilityDescription: nil),
                    "page \(page.id) uses unknown SF Symbol \"\(point.symbol)\"")
            }
        }
    }

    func testStoragePageMatchesTheShippedRetentionDefault() {
        // The copy states a concrete number of months. If the default retention
        // policy ever changes, this fails and forces the sentence to change
        // with it, rather than letting onboarding quietly start lying.
        XCTAssertEqual(StorageHousekeeping.defaultMonths, 6)
        let storage = pages.first { $0.id == "storage" }
        let mentionsWindow = storage?.points.contains { $0.text.contains("six months") } ?? false
        XCTAssertTrue(mentionsWindow, "storage page no longer states the default retention window")

        // The copy also names the selectable windows; keep them in step with
        // the picker the Storage tab actually offers.
        XCTAssertEqual(StorageHousekeeping.monthOptions, [1, 3, 6, 12])
        let mentionsOptions = storage?.points.contains { $0.text.contains("1, 3, 6 or 12 months") } ?? false
        XCTAssertTrue(mentionsOptions, "storage page no longer lists the selectable retention windows")
    }

    func testStoragePageStatesTheConversationCap() {
        // AI conversations are the one thing on this page that the app DOES
        // shorten by itself: every saveConversation runs through
        // AiPersistence.limit, which keeps only the last
        // maxMessagesPerDocument messages and persists the truncated list. The
        // copy names that number, so pin it — if the cap moves, the sentence
        // has to move with it.
        XCTAssertEqual(AiPersistence.maxMessagesPerDocument, 120)
        let storage = pages.first { $0.id == "storage" }
        let statesCap = storage?.points.contains { $0.text.contains("120 messages") } ?? false
        XCTAssertTrue(statesCap, "storage page no longer states the AI conversation cap")

        // Guard the inverse too: conversations must not be listed among the
        // things only the user deletes, which is what the page claimed before
        // the cap was noticed.
        let overclaims = storage?.points.contains {
            $0.text.contains("AI conversations") && $0.text.contains("Only you delete")
        } ?? false
        XCTAssertFalse(overclaims, "storage page claims AI conversations are never trimmed")
    }
}
