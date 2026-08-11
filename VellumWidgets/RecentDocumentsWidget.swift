import SwiftUI
import WidgetKit

struct RecentDocumentsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: VellumWidgetKind.recentDocuments,
            provider: VellumWidgetTimelineProvider(shelf: .recent)
        ) { entry in
            VellumWidgetShelfView(
                title: "Recent",
                systemImage: "clock.arrow.circlepath",
                emptyMessage: "Open something in Vellum",
                items: entry.snapshot.recentDocuments)
            .containerBackground(for: .widget) {
                Color(.systemBackground)
            }
        }
        .configurationDisplayName("Recent Documents")
        .description("Continue with documents you recently opened in Vellum.")
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryInline, .accessoryCircular, .accessoryRectangular,
        ])
    }
}
