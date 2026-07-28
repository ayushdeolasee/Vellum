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

        // The full option list used to be spelled out here too. It was cut on
        // review as more detail than a first read needs, and now lives in the
        // Help centre's retention topic — where HelpTopicContentTests pins it
        // to StorageHousekeeping.monthOptions instead. This page only has to
        // stay honest that the window is adjustable.
        let mentionsSetting = storage?.points.contains {
            $0.text.contains("Settings ▸ Storage")
        } ?? false
        XCTAssertTrue(mentionsSetting, "storage page no longer points at the setting")
    }

    func testStoragePageNeverClaimsConversationsArePermanent() {
        // AI conversations are the one thing on this page that the app DOES
        // shorten by itself: every saveConversation runs through
        // AiPersistence.limit, which keeps only the last
        // maxMessagesPerDocument messages and persists the truncated list.
        //
        // An earlier draft stated the cap outright ("trimmed to the last 120
        // messages"). That was true, but it is an internal number, and the
        // review asked for the copy to stop reciting implementation limits — so
        // conversations are simply not listed among the things Vellum keeps.
        // What must never come back is the ORIGINAL claim, which put them in
        // the "only you delete these" list and was flatly false. That is the
        // regression this test exists to catch; the assertion is on the lie,
        // not on the phrasing that replaced it.
        XCTAssertEqual(AiPersistence.maxMessagesPerDocument, 120)

        let storage = pages.first { $0.id == "storage" }
        XCTAssertNotNil(storage)

        let keptForever = storage?.points.first { $0.text.contains("Kept indefinitely") }
        XCTAssertNotNil(keptForever, "storage page no longer says what it keeps")
        XCTAssertFalse(
            keptForever?.text.lowercased().contains("conversation") ?? true,
            """
            The storage page lists AI conversations among the things kept \
            indefinitely, but AiPersistence.limit trims every save to the last \
            \(AiPersistence.maxMessagesPerDocument) messages and writes the trimmed list to \
            disk. Either drop them from that list or state the cap.
            """)
        XCTAssertFalse(
            keptForever?.text.contains("Only you delete") ?? true,
            "storage page claims AI conversations are never trimmed")
    }
}
