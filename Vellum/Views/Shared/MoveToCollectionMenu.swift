import SwiftUI

/// Submenu that files a read-later item into another collection (Raindrop
/// folder or Readwise Reader location). Used from the welcome-screen library's
/// context menu and from the toolbar overflow menu while the page is open.
///
/// The store is injected explicitly rather than read from `@Environment`:
/// context-menu and toolbar-menu content can be built outside the owning
/// view's environment on some macOS versions, and a missing observable
/// environment value is a fatalError, not a nil.
///
/// An inline Picker (not checkmark-Labels next to plain Text) gives native
/// menu alignment, a real checkmark on the current location, and a VoiceOver
/// selection announcement for free.
struct MoveToCollectionMenu: View {
    let item: ReadLaterItem
    let integrations: IntegrationsStore

    var body: some View {
        let targets = integrations.moveTargets(for: item.provider)
        if !targets.isEmpty {
            Menu("Move To") {
                Picker("Move To", selection: selection(in: targets)) {
                    ForEach(targets) { collection in
                        Text(indentedTitle(collection))
                            .accessibilityLabel(collection.title)
                            .tag(Optional(collection.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .disabled(integrations.inFlightMoves.contains(item.id))
            .accessibilityIdentifier("integrations.moveMenu")
        }
    }

    private func selection(in targets: [ReadLaterCollection]) -> Binding<String?> {
        Binding(
            get: { targets.first(where: { item.collectionIDs.contains($0.id) })?.id },
            set: { id in
                guard let target = targets.first(where: { $0.id == id }) else { return }
                // Store-owned task, not a bare `Task` whose handle dies with the
                // menu: the quit path drains the refile the user just asked for.
                integrations.beginMove(item, to: target)
            }
        )
    }

    private func indentedTitle(_ collection: ReadLaterCollection) -> String {
        String(repeating: "    ", count: collection.depth) + collection.title
    }
}
