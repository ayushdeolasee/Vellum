import SwiftUI
import WidgetKit

struct ReadLaterWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: VellumWidgetKind.readLater,
            provider: VellumWidgetTimelineProvider(shelf: .readLater)
        ) { entry in
            VellumWidgetShelfView(
                title: "Read Later",
                systemImage: "bookmark",
                emptyMessage: "Your queue is clear",
                items: entry.snapshot.readLaterItems)
            .containerBackground(for: .widget) {
                Color(.systemBackground)
            }
        }
        .configurationDisplayName("Read Later")
        .description("Open the newest items from your read-later queue.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryInline, .accessoryCircular, .accessoryRectangular,
        ])
    }
}
