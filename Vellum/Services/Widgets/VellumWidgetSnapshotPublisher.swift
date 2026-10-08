#if os(iOS) || os(macOS)
import Foundation
import WidgetKit

/// App-side producer for the extension's compact projection. All library and
/// provider access stays here; only the finished value crosses into App Group.
actor VellumWidgetSnapshotPublisher {
    private let resolveStore: @Sendable () -> VellumWidgetSnapshotStore?
    private var generation = 0

    init(store: VellumWidgetSnapshotStore? = .resolve()) {
        resolveStore = { store }
    }

    /// Mac resolves its App Group on this actor rather than during UI startup.
    init(resolvingStore: @escaping @Sendable () -> VellumWidgetSnapshotStore?) {
        resolveStore = resolvingStore
    }

    func publish(readLaterItems: [ReadLaterItem], now: Date = .now) async {
        generation += 1
        let requestGeneration = generation
        guard !Task.isCancelled, let store = resolveStore() else { return }
        let recents = (try? await RecentDocumentsSearchProvider().items(matching: "")) ?? []
        guard !Task.isCancelled, generation == requestGeneration else { return }
        let snapshot = VellumWidgetSnapshotFactory.make(
            recents: recents,
            readLater: readLaterItems,
            now: now)
        guard (try? store.save(snapshot)) == true else { return }
        WidgetCenter.shared.reloadTimelines(ofKind: VellumWidgetKind.recentDocuments)
        WidgetCenter.shared.reloadTimelines(ofKind: VellumWidgetKind.readLater)
    }
}

enum VellumWidgetSnapshotFactory {
    static func make(
        recents: [HomeSearchItem],
        readLater: [ReadLaterItem],
        now: Date = .now
    ) -> VellumWidgetSnapshot {
        let recentItems = recents
            .filter { $0.section == .recents && !$0.badges.contains(.missing) }
            .prefix(VellumWidgetSnapshot.maximumItemsPerShelf)
            .map { item in
                VellumWidgetItem(
                    shelf: .recent,
                    title: item.title,
                    subtitle: item.subtitle,
                    systemImage: item.systemImage,
                    date: item.date,
                    target: item.target.widgetTarget)
            }

        let readLaterItems = readLater
            .sorted { lhs, rhs in
                lhs.savedAt == rhs.savedAt ? lhs.id < rhs.id : lhs.savedAt > rhs.savedAt
            }
            .prefix(VellumWidgetSnapshot.maximumItemsPerShelf)
            .map { item in
                VellumWidgetItem(
                    shelf: .readLater,
                    title: item.title,
                    subtitle: item.author ?? item.provider.name,
                    systemImage: item.kind == .pdf ? "doc.text" : "bookmark",
                    date: item.savedAt,
                    target: .readLater(itemID: item.id))
            }

        return VellumWidgetSnapshot(
            generatedAt: now,
            recentDocuments: Array(recentItems),
            readLaterItems: Array(readLaterItems))
    }
}

extension HomeSearchTarget {
    fileprivate var widgetTarget: VellumWidgetOpenTarget {
        switch self {
        case .file(let path, let recordedPath): .file(path: path, recordedPath: recordedPath)
        case .url(let url): .url(url)
        }
    }
}

#endif
