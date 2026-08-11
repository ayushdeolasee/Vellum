import SwiftUI
import WidgetKit

struct VellumWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: VellumWidgetSnapshot
}

struct VellumWidgetTimelineProvider: TimelineProvider {
    let shelf: VellumWidgetShelf

    func placeholder(in _: Context) -> VellumWidgetEntry {
        VellumWidgetEntry(date: .now, snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (VellumWidgetEntry) -> Void) {
        completion(entry(usePreviewWhenEmpty: context.isPreview))
    }

    func getTimeline(
        in _: Context,
        completion: @escaping (Timeline<VellumWidgetEntry>) -> Void
    ) {
        // The app explicitly reloads this widget kind only after its atomically
        // written snapshot changes. A periodic network/file walk here would
        // violate the extension boundary and waste the widget's launch budget.
        completion(Timeline(entries: [entry(usePreviewWhenEmpty: false)], policy: .never))
    }

    private func entry(usePreviewWhenEmpty: Bool) -> VellumWidgetEntry {
        let loaded = VellumWidgetSnapshotStore.resolve()?.load()
        let snapshot: VellumWidgetSnapshot
        if let loaded, !loaded.items(for: shelf).isEmpty {
            snapshot = loaded
        } else {
            snapshot = usePreviewWhenEmpty ? .preview : .empty()
        }
        return VellumWidgetEntry(date: snapshot.generatedAt, snapshot: snapshot)
    }
}

extension VellumWidgetSnapshot {
    fileprivate static var preview: Self {
        let recent = VellumWidgetItem(
            shelf: .recent,
            title: "Designing Data-Intensive Applications",
            subtitle: "Chapter 4",
            systemImage: "doc.text",
            date: .now,
            target: .file(path: "/preview/book.pdf", recordedPath: "/preview/book.pdf"))
        let readLater = VellumWidgetItem(
            shelf: .readLater,
            title: "A calm guide to local-first software",
            subtitle: "Readwise Reader",
            systemImage: "bookmark",
            date: .now,
            target: .readLater(itemID: "readwise:preview"))
        return Self(generatedAt: .now, recentDocuments: [recent], readLaterItems: [readLater])
    }
}
