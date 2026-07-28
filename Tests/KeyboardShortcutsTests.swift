import UIKit
import XCTest
@testable import Vellum

// Pins the iPad hardware-keyboard shortcut table (issue #40). The catalog is the
// single source of truth for both dispatch surfaces — the SwiftUI `Commands`
// menu and the `UIKeyCommand`s installed on the PDF/Web views — so a golden test
// over the table is what stops a future edit from silently dropping, re-keying,
// or double-binding a shortcut that shipped on macOS.
//
// The expectations below are transcribed from the macOS menu
// (`Vellum/App/VellumCommands.swift`) and the macOS key monitor
// (`Vellum/App/ContentView.swift`), NOT from the iOS implementation — that is
// the point: the test fails if iPad drifts away from Mac parity.

@MainActor
final class KeyboardShortcutsTests: XCTestCase {

    /// (action, title, key, modifiers, menu) in menu order.
    ///
    /// `menu` is pinned too, not just the key: on iPadOS the menu a shortcut
    /// lands in *is* its discoverability — it decides where the item shows up in
    /// the ⌘-hold HUD and the menu bar — so silently moving a row between menus
    /// is as much a regression as re-keying it.
    private typealias Row = (
        action: VellumShortcutAction,
        title: String,
        key: VellumShortcutKey,
        modifiers: VellumKeyModifiers,
        menu: VellumShortcutMenu
    )

    private var expected: [Row] {
        var rows: [Row] = [
            // File
            (.newTab, "New Tab", .character("t"), .command, .file),
            (.openFile, "Open…", .character("o"), .command, .file),
            (.addWebpage, "Add Webpage…", .character("l"), .command, .file),
            (.closeTab, "Close Tab", .character("w"), .command, .file),
            (.printDocument, "Print…", .character("p"), .command, .file),
            (.save, "Save", .character("s"), .command, .file),
            // Find
            (.find, "Find…", .character("f"), .command, .find),
            (.findNext, "Find Next", .character("g"), .command, .find),
            (.findPrevious, "Find Previous", .character("g"), [.command, .shift], .find),
            (.dismiss, "Dismiss", .escape, [], .find),
            // View
            (.zoomIn, "Zoom In", .character("+"), .command, .view),
            (.zoomOut, "Zoom Out", .character("-"), .command, .view),
            (.actualSize, "Actual Size", .character("0"), .command, .view),
            (.toggleInspector, "Toggle Inspector", .character("s"), [.command, .option], .view),
            (.splitRight, "Split Right", .character("\\"), .command, .view),
            (.splitDown, "Split Down", .character("\\"), [.command, .option], .view),
            (.mergePanes, "Merge Panes", .character("j"), [.command, .option], .view),
            (.closePane, "Close Pane", .character("\\"), [.command, .shift], .view),
            // Navigate
            (.previousPage, "Previous Page", .upArrow, .command, .navigate),
            (.nextPage, "Next Page", .downArrow, .command, .navigate),
            (.firstPage, "First Page", .upArrow, [.command, .option], .navigate),
            (.lastPage, "Last Page", .downArrow, [.command, .option], .navigate),
            (.webBack, "Back", .character("["), .command, .navigate),
            (.webForward, "Forward", .character("]"), .command, .navigate),
            (.previousTab, "Show Previous Tab", .character("["), [.command, .shift], .navigate),
            (.nextTab, "Show Next Tab", .character("]"), [.command, .shift], .navigate),
        ]
        // ⌘1…⌘9 tab switching.
        for number in 1...9 {
            rows.append(
                (
                    .showTab(number), "Show Tab \(number)", .character(Character("\(number)")),
                    .command, .navigate
                )
            )
        }
        rows += [
            // Annotations
            (.bookmarkPage, "Bookmark Page", .character("d"), .command, .annotations),
            (.toggleNoteMode, "Toggle Note Mode", .character("n"), [], .annotations),
        ]
        return rows
    }

    // MARK: - The table itself

    func testCatalogMatchesTheMacShortcutTableExactly() {
        let actual = VellumShortcutCatalog.all
        XCTAssertEqual(
            actual.count, expected.count,
            "Shortcut count changed — a macOS shortcut was added or dropped.")

        for (index, row) in expected.enumerated() where index < actual.count {
            let shortcut = actual[index]
            XCTAssertEqual(shortcut.action, row.action, "Wrong action at index \(index)")
            XCTAssertEqual(shortcut.title, row.title, "Wrong title for \(row.action.identifier)")
            XCTAssertEqual(
                shortcut.combo.key, row.key, "Wrong key for \(row.action.identifier)")
            XCTAssertEqual(
                shortcut.combo.modifiers, row.modifiers,
                "Wrong modifiers for \(row.action.identifier)")
            XCTAssertEqual(
                shortcut.menu, row.menu,
                "\(row.action.identifier) moved to a different menu — it would appear "
                    + "somewhere else in the ⌘-hold HUD.")
        }
    }

    func testEveryActionIsBoundExactlyOnce() {
        let identifiers = VellumShortcutCatalog.all.map(\.action.identifier)
        XCTAssertEqual(
            Set(identifiers).count, identifiers.count,
            "Two rows bind the same action; the catalog lookup would drop one.")
    }

    func testNoChordIsBoundTwice() {
        // Primary chords AND responder-chain alternates share one keyboard, so
        // collisions are checked across both.
        let combos = VellumShortcutCatalog.all.flatMap { [$0.combo] + $0.alternates }
        XCTAssertEqual(
            Set(combos).count, combos.count,
            "The same chord is bound to two actions — dispatch would be ambiguous.")
    }

    func testEveryShortcutHasAMenuHome() {
        // Menu placement is the discoverability story on iPadOS: an item with no
        // menu never shows up in the ⌘-hold HUD or the menu bar.
        for shortcut in VellumShortcutCatalog.all {
            XCTAssertFalse(
                shortcut.title.isEmpty, "\(shortcut.action.identifier) has no title")
        }
        let menus = Set(VellumShortcutCatalog.all.map(\.menu))
        XCTAssertEqual(menus, [.file, .find, .view, .navigate, .annotations])
    }

    func testIdentifiersRoundTripThroughTheCatalog() {
        // The UIKeyCommand path can only carry a property list, so it ships the
        // identifier string and resolves it back on the way out.
        for shortcut in VellumShortcutCatalog.all {
            XCTAssertEqual(
                VellumShortcutCatalog.action(forIdentifier: shortcut.action.identifier),
                shortcut.action)
        }
        XCTAssertNil(VellumShortcutCatalog.action(forIdentifier: "notAShortcut"))
    }

    // MARK: - What we deliberately do NOT bind

    func testSystemTextEditingChordsAreNotShadowed() {
        // UIKit implements these on every text surface; shadowing any of them
        // would break editing inside the find field, the AI composer, and the
        // scratchpad.
        let reserved: Set<Character> = ["c", "v", "x", "a", "z"]
        for shortcut in VellumShortcutCatalog.all {
            for combo in [shortcut.combo] + shortcut.alternates {
                guard combo.modifiers == .command,
                      case .character(let character) = combo.key
                else { continue }
                XCTAssertFalse(
                    reserved.contains(character),
                    "⌘\(character) is a system text-editing chord and must stay unbound "
                        + "(claimed by \(shortcut.action.identifier)).")
            }
        }
    }

    func testOnlyNoteModeUsesABareKey() {
        // A modifier-less chord swallows a literal keystroke, so exactly one is
        // allowed (bare N, matching macOS) plus Escape, which types nothing.
        let bare = VellumShortcutCatalog.all.filter { $0.combo.modifiers.isEmpty }
        XCTAssertEqual(Set(bare.map(\.action)), [.toggleNoteMode, .dismiss])
    }

    // MARK: - Responder-chain (UIKeyCommand) projection

    func testDocumentSurfaceSetCoversTheChordsPdfKitAndWebKitClaim() {
        // These are the chords a focused PDFView/WKWebView has its own bindings
        // for; each must also be installed on Vellum's document surfaces or the
        // SwiftUI menu copy loses the dispatch race.
        let expectedActions: Set<VellumShortcutAction> = [
            .find, .findNext, .findPrevious, .dismiss,
            .zoomIn, .zoomOut, .actualSize,
            .previousPage, .nextPage, .firstPage, .lastPage,
            .webBack, .webForward, .previousTab, .nextTab,
        ]
        XCTAssertEqual(
            Set(VellumShortcutCatalog.documentSurfaceShortcuts.map(\.action)), expectedActions)
    }

    func testNoteModeIsNeverInstalledOnADocumentSurface() {
        // Bare N on the web surface would eat the letter "n" typed into a page's
        // text field.
        let noteMode = VellumShortcutCatalog[.toggleNoteMode]
        XCTAssertNotNil(noteMode)
        XCTAssertFalse(noteMode?.installOnDocumentSurface ?? true)
    }

    func testKeyCommandsCarryTheirActionAndBeatSystemBehaviour() {
        let selector = #selector(UIResponder.becomeFirstResponder)  // arbitrary, unused
        let commands = VellumShortcutCatalog.documentSurfaceKeyCommands(action: selector)

        // One command per primary chord plus one per alternate.
        let expectedCount = VellumShortcutCatalog.documentSurfaceShortcuts
            .reduce(0) { $0 + 1 + $1.alternates.count }
        XCTAssertEqual(commands.count, expectedCount)

        for command in commands {
            XCTAssertEqual(command.action, selector)
            guard let identifier = command.propertyList as? String,
                  let action = VellumShortcutCatalog.action(forIdentifier: identifier),
                  let shortcut = VellumShortcutCatalog[action]
            else {
                return XCTFail("Key command lost its action identifier")
            }
            XCTAssertEqual(
                command.wantsPriorityOverSystemBehavior, shortcut.overridesSystemBehavior,
                "\(identifier) has the wrong priority against system behaviour.")
            XCTAssertFalse(command.input?.isEmpty ?? true)
        }
    }

    func testEscapeDoesNotOverrideSystemBehaviour() {
        // A matched UIKeyCommand is consumed unconditionally on iOS, so Escape
        // can never be as transparent as the macOS NSEvent monitor (which always
        // lets the event continue). Not claiming priority is the closest
        // equivalent: the system keeps first claim on Escape for dismissing an
        // edit-menu callout or a Full Keyboard Access interaction.
        XCTAssertEqual(VellumShortcutCatalog[.dismiss]?.overridesSystemBehavior, false)

        // Everything else on the responder chain is there precisely to win.
        for shortcut in VellumShortcutCatalog.documentSurfaceShortcuts where shortcut.action != .dismiss {
            XCTAssertTrue(
                shortcut.overridesSystemBehavior,
                "\(shortcut.action.identifier) would lose to PDFKit/WebKit.")
        }
    }

    func testOnlyThePrimaryChordIsAdvertisedInTheDiscoverabilityHud() {
        // Alternates exist so a chord people actually press works (⌘= for Zoom
        // In); advertising them would list the same title three times.
        let commands = VellumShortcutCatalog.documentSurfaceKeyCommands(
            action: #selector(UIResponder.becomeFirstResponder))
        let titled = commands.filter { $0.discoverabilityTitle != nil }
        XCTAssertEqual(titled.count, VellumShortcutCatalog.documentSurfaceShortcuts.count)
        XCTAssertEqual(
            Set(titled.compactMap(\.discoverabilityTitle)).count, titled.count,
            "Two HUD entries share a title — an alternate leaked into the HUD.")
    }

    func testZoomInAcceptsTheUnshiftedEqualsKeyOverADocument() {
        // On iPadOS a UIKeyCommand matches the literal input string plus exact
        // modifier flags, so a lone "+" binding never fires for the key most
        // people actually press. The alternates cover both spellings.
        let zoomIn = VellumShortcutCatalog[.zoomIn]
        XCTAssertNotNil(zoomIn)
        XCTAssertTrue(zoomIn?.alternates.contains(VellumKeyCombo("=")) ?? false)
        XCTAssertTrue(
            zoomIn?.alternates.contains(VellumKeyCombo("+", [.command, .shift])) ?? false)
    }

    // MARK: - Framework bridging

    func testModifiersMapToUIKitFlags() {
        XCTAssertEqual(VellumKeyModifiers.command.keyModifierFlags, .command)
        XCTAssertEqual(VellumKeyModifiers.shift.keyModifierFlags, .shift)
        // UIKit spells Option "alternate" — an easy mapping to get wrong.
        XCTAssertEqual(VellumKeyModifiers.option.keyModifierFlags, .alternate)
        XCTAssertEqual(VellumKeyModifiers.control.keyModifierFlags, .control)
        XCTAssertEqual(
            VellumKeyModifiers([.command, .option]).keyModifierFlags, [.command, .alternate])
    }

    func testNamedKeysMapToUIKitInputStrings() {
        XCTAssertEqual(VellumShortcutKey.upArrow.keyCommandInput, UIKeyCommand.inputUpArrow)
        XCTAssertEqual(VellumShortcutKey.downArrow.keyCommandInput, UIKeyCommand.inputDownArrow)
        XCTAssertEqual(VellumShortcutKey.escape.keyCommandInput, UIKeyCommand.inputEscape)
        XCTAssertEqual(VellumShortcutKey.character("f").keyCommandInput, "f")
    }
}
