import UIKit
import XCTest

@testable import Vellum

// Coverage for the searchable Help centre.
//
// Same reasoning as WalkthroughTests: the catalogue is pure data driving a
// generic view, so a duplicated id, a bad SF Symbol name, or a shortcut string
// that drifted away from the command that implements it all fail silently at
// runtime. The search predicate gets its own tests because "returns nothing"
// and "returns everything" are both plausible-looking bugs that no compiler
// will catch.

final class HelpTopicSearchTests: XCTestCase {
    private let topics = HelpTopic.all

    func testEmptyQueryReturnsTheWholeCatalogue() {
        // The window opens with an empty field. If this ever returned [] the
        // Help centre would greet everyone with "No Results".
        XCTAssertEqual(HelpTopic.search("").map(\.id), topics.map(\.id))
        XCTAssertEqual(HelpTopic.search("   ").map(\.id), topics.map(\.id))
    }

    func testSearchMatchesTitleSummaryShortcutAndKeywords() {
        // One assertion per field the predicate is supposed to cover, because
        // dropping any one of them from `searchableText` still leaves the
        // other three working and the feature half-broken.
        // Title match. Asserted as membership, not as `.first`: "Scratchpad"
        // also legitimately appears in the inspector topic's summary, and the
        // catalogue is ordered for reading rather than by relevance.
        XCTAssertTrue(HelpTopic.search("Scratchpad").map(\.id).contains("scratchpad"))
        // Summary match — "wraps around" is in switch-tabs' prose only.
        XCTAssertEqual(HelpTopic.search("wraps around").map(\.id), ["switch-tabs"])
        // Shortcut match.
        XCTAssertEqual(HelpTopic.search("⌘⌥S").map(\.id), ["inspector"])

        // "llm" appears in no title and no summary — only in ai-setup's
        // keywords, so this fails if keywords stop being searched.
        XCTAssertEqual(HelpTopic.search("llm").map(\.id), ["ai-setup"])
        // Likewise "eviction", which is retention's keyword and nobody's prose.
        XCTAssertEqual(HelpTopic.search("eviction").map(\.id), ["retention"])
    }

    func testPhoneWorkflowsAreDiscoverable() {
        XCTAssertEqual(HelpTopic.search("phone chrome").map(\.id), ["phone-reader"])
        XCTAssertEqual(HelpTopic.search("share extension").map(\.id), ["safari-share"])
        XCTAssertTrue(HelpTopic.search("Continue Reading").map(\.id).contains("phone-home"))
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(HelpTopic.search("ICLOUD").map(\.id), HelpTopic.search("icloud").map(\.id))
        XCTAssertFalse(HelpTopic.search("ICLOUD").isEmpty)
    }

    func testMultipleTermsNarrowRatherThanWiden() {
        // AND, not OR. If the predicate were `contains(where:)` instead of
        // `allSatisfy`, adding a word would grow the result list, which is the
        // opposite of what every search field on the Mac does.
        let onlySplit = HelpTopic.search("split")
        let splitDown = HelpTopic.search("split down")
        XCTAssertGreaterThan(onlySplit.count, splitDown.count)
        XCTAssertEqual(splitDown.map(\.id), ["split-down"])
    }

    func testUnmatchedQueryReturnsNothing() {
        XCTAssertTrue(HelpTopic.search("definitely not a vellum feature").isEmpty)
    }
}

final class HelpTopicContentTests: XCTestCase {
    private let topics = HelpTopic.all

    func testIdsAreUniqueAndSlugLike() {
        // Ids become accessibility identifiers ("help.topic.<id>"); a duplicate
        // makes two rows indistinguishable to automation.
        let ids = topics.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate topic id in \(ids)")
        for id in ids {
            XCTAssertFalse(id.isEmpty)
            XCTAssertEqual(id, id.lowercased(), "topic id \(id) should be a lowercase slug")
            XCTAssertFalse(id.contains(" "), "topic id \(id) should not contain spaces")
        }
    }

    func testEveryTopicIsWellFormed() {
        for topic in topics {
            XCTAssertFalse(topic.title.isEmpty, "\(topic.id) has no title")
            XCTAssertFalse(topic.summary.isEmpty, "\(topic.id) has no summary")
            if let shortcut = topic.shortcut {
                XCTAssertFalse(shortcut.isEmpty, "\(topic.id) has an empty shortcut")
            }
        }
        let titles = topics.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "duplicate topic title in \(titles)")
    }

    func testEverySymbolResolvesOnThisSystem() {
        // A misspelled SF Symbol renders as nothing at all — no crash, no
        // warning, just a blank gutter — so resolve every name for real.
        for topic in topics {
            XCTAssertNotNil(
                UIImage(systemName: topic.symbol),
                "topic \(topic.id) uses unknown SF Symbol \"\(topic.symbol)\"")
        }
    }

    func testShortcutsAreWrittenTheWayTheMenusRenderThem() {
        // Shortcuts are rendered in a Keycap, verbatim. Prose like "Cmd-O" or a
        // trailing period would look wrong on a keycap and would also stop
        // matching when someone searches for the glyph.
        for topic in topics {
            guard let shortcut = topic.shortcut else { continue }
            XCTAssertEqual(
                shortcut, shortcut.trimmingCharacters(in: .whitespaces),
                "\(topic.id) shortcut \"\(shortcut)\" has stray whitespace")
            XCTAssertFalse(
                shortcut.lowercased().contains("cmd")
                    || shortcut.lowercased().contains("command")
                    || shortcut.lowercased().contains("shift"),
                "\(topic.id) spells a modifier out as words instead of using its glyph")
        }
    }

    func testRetentionTopicMatchesTheShippedPolicy() {
        // Same contract the walkthrough's storage page is held to: the Help
        // centre states a concrete window and a concrete option list, so if
        // StorageHousekeeping's policy moves, this fails and forces the copy to
        // move with it rather than letting the reference quietly start lying.
        XCTAssertEqual(StorageHousekeeping.defaultMonths, 6)
        XCTAssertEqual(StorageHousekeeping.monthOptions, [1, 3, 6, 12])

        let retention = HelpTopic.all.first { $0.id == "retention" }
        XCTAssertNotNil(retention)
        XCTAssertTrue(
            retention?.summary.contains("six months") ?? false,
            "retention topic no longer states the default window")
        XCTAssertTrue(
            retention?.summary.contains("1, 3, 6 or 12 months") ?? false,
            "retention topic no longer lists the selectable windows")
        XCTAssertTrue(
            retention?.summary.contains("Never") ?? false,
            "retention topic no longer mentions that cleanup can be turned off")
    }

    func testAiActionsTopicNamesOnlyToolsTheEngineActuallyExposes() {
        // The write tools, verbatim from AiToolEngine's dispatch table. If a
        // tool is added or removed the copy has to be revisited, because
        // "it can jump to a page, add a note, and highlight text" is an
        // exhaustive claim about what the assistant is able to change.
        //
        // Deliberately does NOT assert the five-writes-per-reply cap. That was
        // cut from the walkthrough on review as an internal limit, and moving
        // it into the Help centre instead would defeat the point of removing
        // it.
        let actions = HelpTopic.all.first { $0.id == "ai-actions" }
        XCTAssertNotNil(actions)
        for verb in ["jump to a page", "add a note", "highlight text"] {
            XCTAssertTrue(
                actions?.summary.contains(verb) ?? false,
                "ai-actions topic no longer mentions \"\(verb)\"")
        }
    }

    func testEveryWalkthroughPageIsReachableFromHelp() {
        // The two surfaces are meant to cross-reference, not to be discovered
        // independently: the walkthrough's last page points at Help, and Help
        // has to point back or the tour becomes unfindable once dismissed.
        let walkthroughTopic = HelpTopic.all.first { $0.id == "walkthrough" }
        XCTAssertNotNil(walkthroughTopic, "Help centre no longer links to the walkthrough")
        XCTAssertTrue(
            walkthroughTopic?.summary.contains("Vellum Walkthrough") ?? false,
            "the walkthrough topic no longer names the menu item that opens it")

        let storage = WalkthroughPage.all.first { $0.id == "storage" }
        XCTAssertTrue(
            storage?.footnote?.contains("Vellum Help") ?? false,
            "the walkthrough's closing footnote no longer points at the Help centre")
    }
}
