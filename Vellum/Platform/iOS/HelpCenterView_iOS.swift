#if os(iOS)
import SwiftUI

/// The searchable Help centre — the walkthrough's counterpart for people who
/// already know what Vellum is and just want to look something up.
///
/// macOS declares this as its own `Window` scene so it can sit open beside a
/// document. **iOS adds no extra scenes** (standing decision), so `HelpScene`
/// is not ported and this is presented as a sheet: from Home's `?` button and
/// from the shortcut router's ⌘?. A sheet also works from a document context,
/// which the window did too.
///
/// It reuses the walkthrough's vocabulary rather than inventing a second one —
/// same `Keycap` for shortcuts, same palette, same `Radius` scale — so moving
/// between the walkthrough and Help does not feel like moving between two apps.
struct HelpCenterView_iOS: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette
    @State private var query = ""
    /// Set when the user asks for the walkthrough, and acted on in
    /// `onDisappear`. See `openWalkthrough`.
    @State private var pendingWalkthrough = false

    private var results: [HelpTopic] { HelpTopic.search(query) }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Vellum Help")
                .navigationBarTitleDisplayMode(.inline)
                // No `placement:` — main's `.toolbar` placement is macOS-only
                // and the iOS default (below the title) is what we want.
                .searchable(text: $query, prompt: "Search features and shortcuts")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        // The one cross-link between the two surfaces. Someone
                        // who lands here first should be able to find the tour.
                        Button("Walkthrough", action: openWalkthrough)
                            .accessibilityIdentifier("help.openWalkthrough")
                    }
                }
        }
        .presentationDetents([.large])
        .accessibilityIdentifier("help.window")
        .onDisappear {
            // One sheet at a time: both this and the walkthrough are presented
            // from `VellumApp_iOS`'s root, and posting while Help is still up
            // would be silently dropped by iOS. Posting from `onDisappear`
            // means the dismissal has genuinely completed first.
            guard pendingWalkthrough else { return }
            pendingWalkthrough = false
            NotificationCenter.default.post(name: .vellumShowWalkthrough, object: nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        if results.isEmpty {
            ContentUnavailableView.search(text: query)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("help.noResults")
        } else {
            ScrollView(.vertical) {
                // Lazy because the catalogue is filtered live as the user
                // types: rebuilding every card on each keystroke is the one
                // thing that would make the search feel slow.
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(results) { topic in
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

    private func openWalkthrough() {
        pendingWalkthrough = true
        dismiss()
    }
}
#endif
