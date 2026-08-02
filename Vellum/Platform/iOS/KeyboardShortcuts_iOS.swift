#if os(iOS)
import SwiftUI
import UIKit

// The single source of truth for every hardware-keyboard shortcut on iPad
// (issue #40 — "Allow keyboard shortcuts same as mac on iPadOS").
//
// The table is deliberately plain data — no SwiftUI views, no stores, no
// UIKit responders — for two reasons:
//
//  1. It is consumed by TWO dispatch surfaces that must never drift apart:
//     `VellumCommands_iOS` (the SwiftUI `Commands` menu, which is what
//     populates the ⌘-hold discoverability HUD and the iPadOS 26 menu bar) and
//     the `UIKeyCommand`s installed on Vellum's UIKit document surfaces (see
//     `ShortcutRouter_iOS.swift`). Describing a shortcut once and projecting it
//     into both surfaces makes a mismatch structurally impossible.
//  2. Being view-free, it is directly unit-testable — `Tests/KeyboardShortcutsTests.swift`
//     pins the whole table so a future edit cannot silently drop or re-key a
//     shortcut that shipped on macOS.
//
// Parity reference: `Vellum/App/VellumCommands.swift` (the macOS menu) plus the
// local NSEvent monitor in `Vellum/App/ContentView.swift`, which on macOS picks
// up the handful of chords menus cannot express (Escape, bare `N`) and the ones
// a focused PDFView/WKWebView would otherwise swallow.

// MARK: - Modifiers

/// Framework-neutral modifier set. SwiftUI's `EventModifiers` and UIKit's
/// `UIKeyModifierFlags` both exist, but neither is usable as *the* table type:
/// the table has to project into both, and `EventModifiers` carries no
/// guaranteed `Hashable` conformance to assert against in tests. Owning the
/// type keeps the catalog independent of either framework's spelling.
struct VellumKeyModifiers: OptionSet, Hashable, Sendable {
    let rawValue: Int

    init(rawValue: Int) { self.rawValue = rawValue }

    static let command = VellumKeyModifiers(rawValue: 1 << 0)
    static let shift = VellumKeyModifiers(rawValue: 1 << 1)
    static let option = VellumKeyModifiers(rawValue: 1 << 2)
    static let control = VellumKeyModifiers(rawValue: 1 << 3)

    /// SwiftUI spelling, for `.keyboardShortcut(_:modifiers:)`.
    var eventModifiers: EventModifiers {
        var result: EventModifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        return result
    }

    /// UIKit spelling, for `UIKeyCommand(modifierFlags:)`. Note UIKit calls the
    /// Option key `.alternate`.
    var keyModifierFlags: UIKeyModifierFlags {
        var result: UIKeyModifierFlags = []
        if contains(.command) { result.insert(.command) }
        if contains(.shift) { result.insert(.shift) }
        if contains(.option) { result.insert(.alternate) }
        if contains(.control) { result.insert(.control) }
        return result
    }
}

// MARK: - Keys

/// The key half of a chord. Only the keys Vellum actually binds are modelled —
/// an open-ended `Character` case plus the three named keys we use — so an
/// invalid binding cannot be spelled.
enum VellumShortcutKey: Hashable, Sendable {
    case character(Character)
    case upArrow
    case downArrow
    case escape

    /// SwiftUI spelling.
    var keyEquivalent: KeyEquivalent {
        switch self {
        case .character(let character): KeyEquivalent(character)
        case .upArrow: .upArrow
        case .downArrow: .downArrow
        case .escape: .escape
        }
    }

    /// UIKit spelling. `UIKeyCommand` takes the *input string* the keyboard
    /// produces, with the arrow/escape keys spelled as sentinel constants.
    var keyCommandInput: String {
        switch self {
        case .character(let character): String(character)
        case .upArrow: UIKeyCommand.inputUpArrow
        case .downArrow: UIKeyCommand.inputDownArrow
        case .escape: UIKeyCommand.inputEscape
        }
    }
}

/// A key plus its modifiers — one physical chord.
struct VellumKeyCombo: Hashable, Sendable {
    let key: VellumShortcutKey
    let modifiers: VellumKeyModifiers

    init(_ key: VellumShortcutKey, _ modifiers: VellumKeyModifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    /// Convenience for the common `⌘<letter>` shape.
    init(_ character: Character, _ modifiers: VellumKeyModifiers = .command) {
        self.init(.character(character), modifiers)
    }
}

// MARK: - Actions

/// What a shortcut *does*, independent of which key runs it. This is the token
/// that travels from a key press to `VellumShortcutRouter`, so tests can assert
/// "⌘D is still wired to `bookmarkPage`" without touching a store.
enum VellumShortcutAction: Hashable, Sendable {
    // File
    case newTab
    case openFile
    case addWebpage
    case closeTab
    case printDocument
    case save
    // Find
    case find
    case findNext
    case findPrevious
    case dismiss
    // View
    case zoomIn
    case zoomOut
    case actualSize
    case toggleInspector
    /// Reveal one of the inspector's three panels (⌥⌘1/2/3, PR #120).
    case showSidebarTab(WorkspaceStore.SidebarTab)
    case splitRight
    case splitDown
    case mergePanes
    case closePane
    // Navigate
    case previousPage
    case nextPage
    case firstPage
    case lastPage
    case webBack
    case webForward
    case previousTab
    case nextTab
    /// 1-based tab index, matching the ⌘1…⌘9 labels.
    case showTab(Int)
    // Annotations
    case bookmarkPage
    case toggleNoteMode
    // Help. Neither is gated on document focus — someone who just closed their
    // last tab is exactly who wants them.
    case showHelp
    case showWalkthrough

    /// Stable string identity. `UIKeyCommand` can only round-trip a property
    /// list, not a Swift enum, so the responder-chain path ships this string in
    /// `propertyList` and resolves it back through the catalog on the way out.
    var identifier: String {
        switch self {
        case .newTab: "newTab"
        case .openFile: "openFile"
        case .addWebpage: "addWebpage"
        case .closeTab: "closeTab"
        case .printDocument: "printDocument"
        case .save: "save"
        case .find: "find"
        case .findNext: "findNext"
        case .findPrevious: "findPrevious"
        case .dismiss: "dismiss"
        case .zoomIn: "zoomIn"
        case .zoomOut: "zoomOut"
        case .actualSize: "actualSize"
        case .toggleInspector: "toggleInspector"
        case .showSidebarTab(let tab): "showSidebarTab.\(tab.accessibilityIdentifierStem)"
        case .splitRight: "splitRight"
        case .splitDown: "splitDown"
        case .mergePanes: "mergePanes"
        case .closePane: "closePane"
        case .previousPage: "previousPage"
        case .nextPage: "nextPage"
        case .firstPage: "firstPage"
        case .lastPage: "lastPage"
        case .webBack: "webBack"
        case .webForward: "webForward"
        case .previousTab: "previousTab"
        case .nextTab: "nextTab"
        case .showTab(let index): "showTab.\(index)"
        case .bookmarkPage: "bookmarkPage"
        case .toggleNoteMode: "toggleNoteMode"
        case .showHelp: "showHelp"
        case .showWalkthrough: "showWalkthrough"
        }
    }
}

// MARK: - Menu placement

/// Which menu a shortcut is surfaced in. On iPadOS these become the sections of
/// the ⌘-hold HUD and (on iPadOS 26) the real menu bar, so placement is the
/// discoverability story — a shortcut with no menu home is a shortcut nobody
/// finds.
enum VellumShortcutMenu: Hashable, Sendable {
    /// The standard File group (New Tab / Open / Close Tab / Print / Save).
    case file
    /// Appended after the standard text-editing group, like the Mac's Edit ▸ Find.
    case find
    /// Appended after the standard sidebar group: zoom, inspector, split panes.
    case view
    /// Vellum's own "Navigate" menu: pages, web history, tabs.
    case navigate
    /// Vellum's own "Annotations" menu.
    case annotations
    /// The standard Help group. Replaced wholesale, like the Mac's.
    case help
}

// MARK: - Shortcut

/// One row of the shortcut table.
struct VellumShortcut: Hashable, Sendable, Identifiable {
    /// What running this shortcut does.
    let action: VellumShortcutAction
    /// Menu title, reused as the `UIKeyCommand` title so the ⌘-hold HUD and the
    /// menu bar read identically.
    let title: String
    /// The chord shown in the menu.
    let combo: VellumKeyCombo
    /// Where the menu item lives.
    let menu: VellumShortcutMenu
    /// Extra chords that run the same action but are intentionally NOT shown in
    /// the menu (a menu item can only display one key equivalent, and a second
    /// item with the same title reads as a duplicate). Alternates are installed
    /// on the responder chain only — see `installOnDocumentSurface`.
    let alternates: [VellumKeyCombo]
    /// Whether this shortcut is ALSO installed as a `UIKeyCommand` on Vellum's
    /// UIKit document surfaces (`VellumPDFView`, `VellumWebView`).
    ///
    /// SwiftUI `.keyboardShortcut` menu commands sit at the very end of the
    /// responder chain, so a UIKit view that is first responder gets the key
    /// event first and can consume it — PDFKit and WebKit both ship their own
    /// key commands for finding, scrolling, zooming and history. macOS solves
    /// this with a local `NSEvent` monitor (`ContentView.handleKeyDown`); iPadOS
    /// has no equivalent hook, so instead we hang the same chord off the Vellum
    /// view that *owns* the surface. Being nearer the first responder, ours wins,
    /// and because UIKit stops at the first responder that handles the chord the
    /// menu copy does not also fire.
    ///
    /// Only set for chords a document surface plausibly claims. Shortcuts that
    /// nothing in PDFKit/WebKit competes for (⌘T, ⌘W, split management, ⌘1…⌘9)
    /// stay menu-only, which keeps the per-keystroke `keyCommands` array small
    /// and avoids shadowing anything unnecessarily.
    ///
    /// ⌘O / ⌘L / ⌘P are a judgement call worth spelling out: the macOS monitor
    /// DOES intercept them, because AppKit's PDFView and WKWebView implement
    /// `performKeyEquivalent` broadly enough to eat them. Their UIKit
    /// counterparts publish key commands rather than a catch-all hook, and
    /// neither publishes one for open / locate / print (UIKit's own ⌘P exists
    /// only for document-based apps, which Vellum is not — it is a plain
    /// `WindowGroup`). So they are left menu-only; if a future iOS release adds
    /// such a binding, the fix is one flag on these rows.
    let installOnDocumentSurface: Bool
    /// Whether the responder-chain copy sets `wantsPriorityOverSystemBehavior`,
    /// i.e. asks UIKit to prefer Vellum's binding over the system's own for the
    /// same chord.
    ///
    /// True for everything Vellum genuinely needs to win (⌘F must open Vellum's
    /// cross-format find bar, not WebKit's; ⌘↑ must page, not scroll-to-top).
    ///
    /// False for Escape, deliberately. A matched `UIKeyCommand` is consumed
    /// unconditionally on iOS, so Escape can never be as transparent here as it
    /// is on macOS — the AppKit monitor returns `false` for Escape and lets the
    /// event continue no matter what. Leaving the priority flag off is the
    /// closest achievable equivalent: the system keeps first claim on Escape for
    /// things like dismissing an edit-menu callout or a Full Keyboard Access
    /// interaction, and Vellum only sees it when nothing else wanted it.
    let overridesSystemBehavior: Bool

    var id: String { action.identifier }

    init(
        _ action: VellumShortcutAction,
        _ title: String,
        _ combo: VellumKeyCombo,
        menu: VellumShortcutMenu,
        alternates: [VellumKeyCombo] = [],
        installOnDocumentSurface: Bool = false,
        overridesSystemBehavior: Bool = true
    ) {
        self.action = action
        self.title = title
        self.combo = combo
        self.menu = menu
        self.alternates = alternates
        self.installOnDocumentSurface = installOnDocumentSurface
        self.overridesSystemBehavior = overridesSystemBehavior
    }
}

// MARK: - The table

enum VellumShortcutCatalog {
    /// Every shortcut, in menu order.
    ///
    /// Deliberately NOT ported from macOS:
    ///  • Sidebar text sizing (⌘+ / ⌘− while the pointer hovers the open side
    ///    panel). It is pointer-contextual — it only fires because AppKit can
    ///    ask "is the mouse over the sidebar right now" — and it doubles up the
    ///    document-zoom chord. On a touch-first iPad there is no dependable
    ///    hover state to disambiguate with, so ⌘+/⌘− mean document zoom only.
    ///  • Window management (New Window, Minimise, Cycle Windows). Those are
    ///    AppKit's standard menus rather than Vellum's own; iPadOS manages
    ///    windows through Stage Manager / the system multitasking UI.
    ///  • ⌘C / ⌘V / ⌘X / ⌘A / ⌘Z inside text. UIKit already implements these on
    ///    every text surface; shadowing them would break editing.
    static let all: [VellumShortcut] = file + find + view + navigate + annotations + help

    // MARK: File

    private static let file: [VellumShortcut] = [
        VellumShortcut(.newTab, "New Tab", VellumKeyCombo("t"), menu: .file),
        // ⌘O is safe to claim: `VellumCommands_iOS` installs this via
        // `CommandGroup(replacing: .importExport)`, which removes the system's
        // import/export group (and any key equivalent it carried) outright, so
        // there is exactly one owner of the chord.
        VellumShortcut(.openFile, "Open…", VellumKeyCombo("o"), menu: .file),
        VellumShortcut(.addWebpage, "Add Webpage…", VellumKeyCombo("l"), menu: .file),
        VellumShortcut(.closeTab, "Close Tab", VellumKeyCombo("w"), menu: .file),
        VellumShortcut(.printDocument, "Print…", VellumKeyCombo("p"), menu: .file),
        VellumShortcut(.save, "Save", VellumKeyCombo("s"), menu: .file),
    ]

    // MARK: Find

    private static let find: [VellumShortcut] = [
        // The find trio has to reach the document surfaces: WKWebView ships a
        // ⌘F find interaction and both WebKit and UITextView bind ⌘G / ⌘⇧G to
        // "find next/previous" in their own search UI, none of which knows about
        // Vellum's cross-format FindBar.
        VellumShortcut(.find, "Find…", VellumKeyCombo("f"), menu: .find, installOnDocumentSurface: true),
        VellumShortcut(
            .findNext, "Find Next", VellumKeyCombo("g"), menu: .find, installOnDocumentSurface: true),
        VellumShortcut(
            .findPrevious, "Find Previous", VellumKeyCombo("g", [.command, .shift]), menu: .find,
            installOnDocumentSurface: true),
        // Escape mirrors the macOS key monitor: close the find bar if it is up,
        // otherwise drop the annotation selection and leave note mode. It needs
        // BOTH surfaces — the menu copy is what fires while the find field holds
        // first responder (the field is a sibling of the document view, so the
        // document view's key commands are not in its responder chain).
        VellumShortcut(
            .dismiss, "Dismiss", VellumKeyCombo(.escape, []), menu: .find,
            installOnDocumentSurface: true, overridesSystemBehavior: false),
    ]

    // MARK: View

    private static let view: [VellumShortcut] = [
        // ⌘+ is the Mac's Zoom In and stays the menu chord for parity. On iPadOS
        // a `UIKeyCommand` matches the literal input string plus exact modifier
        // flags, so "+" only ever matches when Shift is also reported; ⌘= (the
        // unshifted key most people actually press) and ⌘⇧+ are registered as
        // responder-chain alternates so every spelling of "zoom in" works over a
        // document.
        VellumShortcut(
            .zoomIn, "Zoom In", VellumKeyCombo("+"), menu: .view,
            alternates: [VellumKeyCombo("="), VellumKeyCombo("+", [.command, .shift])],
            installOnDocumentSurface: true),
        VellumShortcut(
            .zoomOut, "Zoom Out", VellumKeyCombo("-"), menu: .view, installOnDocumentSurface: true),
        VellumShortcut(
            .actualSize, "Actual Size", VellumKeyCombo("0"), menu: .view,
            installOnDocumentSurface: true),
        VellumShortcut(
            .toggleInspector, "Toggle Inspector", VellumKeyCombo("s", [.command, .option]),
            menu: .view),
        // Split chords mirror macOS: they avoid the arrow keys, which ⌘⌥↑/↓
        // already use for First/Last Page. ⌘\ matches VS Code's "Split Editor".
        VellumShortcut(.splitRight, "Split Right", VellumKeyCombo("\\"), menu: .view),
        VellumShortcut(
            .splitDown, "Split Down", VellumKeyCombo("\\", [.command, .option]), menu: .view),
        VellumShortcut(
            .mergePanes, "Merge Panes", VellumKeyCombo("j", [.command, .option]), menu: .view),
        VellumShortcut(
            .closePane, "Close Pane", VellumKeyCombo("\\", [.command, .shift]), menu: .view),
    ] + WorkspaceStore.SidebarTab.allCases.map { tab in
        // ⌥⌘, not plain ⌘: ⌘1…⌘9 already switch TABS below, and a tab is what
        // most users reach for first. Generated from `allCases` so the chord
        // order can never drift from the switcher's left-to-right order.
        VellumShortcut(
            .showSidebarTab(tab), "Show \(tab.title)",
            // `SidebarTab.shortcutModifiers` is SwiftUI's `EventModifiers` (it
            // is shared verbatim with the macOS switcher). This table speaks
            // `VellumKeyModifiers`, which also has to reach UIKit — hence the
            // literal here rather than a conversion that would only ever have
            // one input.
            VellumKeyCombo(tab.shortcutDigit, [.command, .option]),
            menu: .view)
    }

    // MARK: Navigate

    private static let navigate: [VellumShortcut] = [
        // Every chord in this group is one a document surface competes for:
        // PDFView and WKWebView are scroll views, and UIKit binds ⌘↑/⌘↓ to
        // scroll-to-top/bottom, while WKWebView binds ⌘[ / ⌘] to its own
        // back/forward (which bypasses Vellum's session rebinding).
        VellumShortcut(
            .previousPage, "Previous Page", VellumKeyCombo(.upArrow, .command), menu: .navigate,
            installOnDocumentSurface: true),
        VellumShortcut(
            .nextPage, "Next Page", VellumKeyCombo(.downArrow, .command), menu: .navigate,
            installOnDocumentSurface: true),
        VellumShortcut(
            .firstPage, "First Page", VellumKeyCombo(.upArrow, [.command, .option]), menu: .navigate,
            installOnDocumentSurface: true),
        VellumShortcut(
            .lastPage, "Last Page", VellumKeyCombo(.downArrow, [.command, .option]), menu: .navigate,
            installOnDocumentSurface: true),
        VellumShortcut(
            .webBack, "Back", VellumKeyCombo("["), menu: .navigate, installOnDocumentSurface: true),
        VellumShortcut(
            .webForward, "Forward", VellumKeyCombo("]"), menu: .navigate,
            installOnDocumentSurface: true),
        VellumShortcut(
            .previousTab, "Show Previous Tab", VellumKeyCombo("[", [.command, .shift]),
            menu: .navigate, installOnDocumentSurface: true),
        VellumShortcut(
            .nextTab, "Show Next Tab", VellumKeyCombo("]", [.command, .shift]), menu: .navigate,
            installOnDocumentSurface: true),
    ] + tabSwitching

    /// ⌘1…⌘9. Titles are static ("Show Tab 3") rather than the Mac's live
    /// document titles: iPadOS builds its menu once per `Commands` evaluation
    /// and a stale title is worse than a positional one.
    private static let tabSwitching: [VellumShortcut] = (1...9).map { number in
        VellumShortcut(
            .showTab(number), "Show Tab \(number)",
            VellumKeyCombo(Character("\(number)")), menu: .navigate)
    }

    // MARK: Annotations

    private static let annotations: [VellumShortcut] = [
        VellumShortcut(.bookmarkPage, "Bookmark Page", VellumKeyCombo("d"), menu: .annotations),
        // Bare `N` carries no modifier, so it is menu-only on purpose: installing
        // it on the web surface would swallow the letter "n" whenever the user
        // types into a page's text field. The router additionally suppresses it
        // while any text input holds first responder.
        VellumShortcut(
            .toggleNoteMode, "Toggle Note Mode", VellumKeyCombo(.character("n"), []),
            menu: .annotations),
    ]

    // MARK: Help

    private static let help: [VellumShortcut] = [
        // Menu-only. ⌘? is not a chord PDFKit or WebKit competes for, and
        // neither of these targets a document surface anyway.
        //
        // `showWalkthrough` has no catalogue row: `VellumShortcut` requires a
        // combo and the walkthrough is deliberately unbound (main leaves it
        // unbound too). It is surfaced as a plain Button in the Help group of
        // `VellumCommands_iOS`.
        VellumShortcut(.showHelp, "Vellum Help", VellumKeyCombo("?"), menu: .help),
    ]

    // MARK: - Lookup

    private static let byAction: [VellumShortcutAction: VellumShortcut] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.action, $0) })

    private static let byIdentifier: [String: VellumShortcutAction] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.action.identifier, $0.action) })

    /// The shortcut bound to `action`, or nil if the table does not carry one.
    static subscript(action: VellumShortcutAction) -> VellumShortcut? { byAction[action] }

    /// Shortcuts belonging to one menu, in table order.
    static func shortcuts(in menu: VellumShortcutMenu) -> [VellumShortcut] {
        all.filter { $0.menu == menu }
    }

    /// Resolves the string identity a `UIKeyCommand` carried back to its action.
    static func action(forIdentifier identifier: String) -> VellumShortcutAction? {
        byIdentifier[identifier]
    }

    /// The shortcuts duplicated onto Vellum's UIKit document surfaces.
    static var documentSurfaceShortcuts: [VellumShortcut] {
        all.filter(\.installOnDocumentSurface)
    }

    /// Builds the `UIKeyCommand`s for the document surfaces. `action` is the
    /// selector on the hosting view; each command carries its shortcut's string
    /// identity in `propertyList` so one selector can serve the whole table.
    ///
    /// `@MainActor` because every UIKit member it touches is — `UIKeyCommand`'s
    /// initializer, `discoverabilityTitle` and `wantsPriorityOverSystemBehavior`
    /// are all main-actor isolated, so building the commands from a nonisolated
    /// context warns today and is an error under a stricter concurrency setting.
    /// Costs the callers nothing: both are already on the main actor (the
    /// `VellumShortcutResponder` extension via the `@MainActor` protocol, and the
    /// `@MainActor` test case).
    @MainActor
    static func documentSurfaceKeyCommands(action selector: Selector) -> [UIKeyCommand] {
        documentSurfaceShortcuts.flatMap { shortcut in
            ([shortcut.combo] + shortcut.alternates).enumerated().map { index, combo in
                let isPrimary = index == 0
                let command = UIKeyCommand(
                    title: shortcut.title,
                    action: selector,
                    input: combo.key.keyCommandInput,
                    modifierFlags: combo.modifiers.keyModifierFlags,
                    propertyList: shortcut.action.identifier)
                // Only the primary chord is advertised in the ⌘-hold HUD.
                // Alternates exist to make a chord people actually press work
                // (⌘= for Zoom In); listing them too would show the same title
                // three times, which is noise rather than discoverability.
                if isPrimary {
                    command.discoverabilityTitle = shortcut.title
                }
                // The whole point of these duplicates: beat PDFKit's/WebKit's
                // own bindings for the same chord instead of losing the race.
                command.wantsPriorityOverSystemBehavior = shortcut.overridesSystemBehavior
                return command
            }
        }
    }
}
#endif  // os(iOS)
