import SwiftUI

/// Identity of the Help centre scene, shared by the `Window` that declares it
/// and the menu command that opens it so the id is spelled once.
enum HelpScene {
    static let windowId = "vellum.help"
    static let title = "Vellum Help"
}

/// The searchable Help centre — the walkthrough's counterpart for people who
/// already know what Vellum is and just want to look something up.
///
/// A window rather than a sheet, and deliberately so: the whole point of a
/// reference is to sit open beside the document while you use the thing it
/// describes. A sheet would be modal, which would make it useless for exactly
/// the case it exists for.
///
/// It reuses the walkthrough's vocabulary rather than inventing a second one —
/// same `Keycap` for shortcuts, same palette, same `Radius` scale — so moving
/// between Help ▸ Vellum Walkthrough and Help ▸ Vellum Help does not feel like
/// moving between two apps.
struct HelpCenterView: View {
    @Environment(\.palette) private var palette
    @State private var query = ""

    private var results: [HelpTopic] { HelpTopic.search(query) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            body(for: results)
        }
        .frame(minWidth: 520, minHeight: 420)
        .searchable(
            text: $query,
            placement: .toolbar,
            prompt: "Search features and shortcuts")
        .accessibilityIdentifier("help.window")
    }

    // MARK: - Chrome

    /// Same wordmark-plus-label strip the walkthrough opens with, so the two
    /// help surfaces are visibly the same family.
    private var header: some View {
        HStack(spacing: 8) {
            Wordmark(size: 14)
            Text("Help")
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)

            Spacer(minLength: 12)

            // The one cross-link between the two surfaces. Someone who lands
            // here first should be able to find the tour without going back to
            // the menu bar.
            TextButton(variant: .secondary, size: .sm, action: openWalkthrough) {
                Text("Walkthrough")
            }
            .accessibilityIdentifier("help.openWalkthrough")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func body(for topics: [HelpTopic]) -> some View {
        if topics.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("help.noResults")
        } else {
            ScrollView(.vertical) {
                // Lazy because the catalogue is filtered live as the user
                // types: rebuilding every card on each keystroke is the one
                // thing that would make the search feel slow.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(topics) { topic in
                        row(topic)
                    }
                }
                .padding(20)
            }
            .accessibilityIdentifier("help.results")
        }
    }

    private func row(_ topic: HelpTopic) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: topic.symbol)
                .font(.system(size: 14))
                .foregroundStyle(.tint)
                // Same fixed gutter as the walkthrough's bullets, so titles
                // line up down the list whatever each symbol's width is.
                .frame(width: 18, alignment: .center)
                .padding(.top, 1)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(topic.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(palette.foreground)

                    if let shortcut = topic.shortcut {
                        Keycap(keys: shortcut)
                    }

                    Spacer(minLength: 0)
                }

                Text(topic.summary)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
                    .lineSpacing(2)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        // .contain, not the default: without it the row's identifier shadows
        // the Keycap's "Keyboard shortcut ⌘O" label, which is the part a
        // VoiceOver user is here for.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("help.topic.\(topic.id)")
    }

    /// Routed through the same notification the Help menu and the welcome
    /// screen post, because the walkthrough sheet's presentation state belongs
    /// to the main window and this view is in a different scene entirely.
    private func openWalkthrough() {
        NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
    }
}

#Preview("Help centre") {
    HelpCenterView()
        .environment(\.palette, .light)
        .tint(ThemePalette.light.primary)
        .frame(width: 640, height: 620)
}

#Preview("Help centre (dark)") {
    HelpCenterView()
        .environment(\.palette, .dark)
        .preferredColorScheme(.dark)
        .tint(ThemePalette.dark.primary)
        .frame(width: 640, height: 620)
}
