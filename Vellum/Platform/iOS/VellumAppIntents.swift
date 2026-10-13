#if os(iOS) || os(macOS)
import AppIntents

struct VellumDocumentEntity: AppEntity, Hashable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Vellum Document"
    static let defaultQuery = VellumDocumentQuery()

    let id: String
    let shelf: VellumWidgetShelf
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }

    init(item: VellumWidgetItem) {
        id = item.id
        shelf = item.shelf
        title = item.title
        subtitle = item.subtitle
    }
}

struct VellumDocumentQuery: EntityQuery {
    func entities(for identifiers: [VellumDocumentEntity.ID]) async throws
        -> [VellumDocumentEntity]
    {
        guard let snapshot = await Task.detached(priority: .userInitiated, operation: {
            VellumWidgetSnapshotStore.resolve()?.load()
        }).value else { return [] }
        let requested = Set(identifiers)
        return snapshot.allItems.lazy
            .filter { requested.contains($0.id) }
            .map(VellumDocumentEntity.init)
    }

    func suggestedEntities() async throws -> [VellumDocumentEntity] {
        guard let snapshot = await Task.detached(priority: .userInitiated, operation: {
            VellumWidgetSnapshotStore.resolve()?.load()
        }).value else { return [] }
        return snapshot.allItems.map(VellumDocumentEntity.init)
    }
}

struct ContinueInVellumIntent: AppIntent {
    static let title: LocalizedStringResource = "Continue Reading in Vellum"
    static let description = IntentDescription(
        "Open a recent document or read-later item in Vellum.")
    #if os(macOS)
    static let supportedModes: IntentModes = .foreground
    #else
    static let openAppWhenRun = true
    #endif

    @Parameter(title: "Document")
    var document: VellumDocumentEntity

    init() {}

    init(document: VellumDocumentEntity) {
        self.document = document
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let route = VellumSystemRoute(shelf: document.shelf, itemID: document.id)
        guard let snapshot = await Task.detached(priority: .userInitiated, operation: {
            VellumWidgetSnapshotStore.resolve()?.load()
        }).value,
              snapshot.item(for: route) != nil
        else {
            return .result(dialog: "That document is no longer in your Vellum shortcuts.")
        }

        try Task.checkCancellation()
        #if os(macOS)
        guard await VellumSystemRouteHandoff.shared.submit(route) else {
            return .result(dialog: "Vellum is closing. Try again when it has finished.")
        }
        #else
        await VellumSystemRouteHandoff.shared.submit(route)
        #endif
        return .result(dialog: "Opening \(document.title) in Vellum.")
    }
}

struct VellumAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ContinueInVellumIntent(),
            phrases: [
                "Continue reading in \(.applicationName)",
                "Open a document in \(.applicationName)",
            ],
            shortTitle: "Continue Reading",
            systemImageName: "book.pages")
    }
}
#endif
