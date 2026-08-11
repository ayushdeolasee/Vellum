import SwiftUI
import WidgetKit

struct VellumWidgetShelfView: View {
    let title: String
    let systemImage: String
    let emptyMessage: String
    let items: [VellumWidgetItem]

    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            accessoryInline
        case .accessoryCircular:
            accessoryCircular
        case .accessoryRectangular:
            accessoryRectangular
        case .systemSmall:
            compactHome
        default:
            listHome
        }
    }

    private var first: VellumWidgetItem? { items.first }

    private var accessoryInline: some View {
        Label(first?.title ?? emptyMessage, systemImage: systemImage)
            .widgetURL(first?.deepLink)
    }

    private var accessoryCircular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 1) {
                Image(systemName: systemImage)
                    .font(.headline)
                Text(items.count, format: .number)
                    .font(.caption.bold())
                    .monospacedDigit()
            }
            .widgetAccentable()
        }
        .widgetURL(first?.deepLink)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(items.count) items")
    }

    private var accessoryRectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: systemImage)
                .font(.caption.bold())
                .widgetAccentable()
            Text(first?.title ?? emptyMessage)
                .font(.headline)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(first?.deepLink)
        .accessibilityElement(children: .combine)
    }

    private var compactHome: some View {
        VStack(alignment: .leading, spacing: 8) {
            VellumWidgetHeader(title: title, systemImage: systemImage, count: items.count)
            Spacer(minLength: 0)
            if let first {
                Image(systemName: first.systemImage)
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(first.title)
                    .font(.headline)
                    .lineLimit(3)
                if !first.subtitle.isEmpty {
                    Text(first.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                Label(emptyMessage, systemImage: "tray")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .widgetURL(first?.deepLink)
        .accessibilityElement(children: .combine)
    }

    private var listHome: some View {
        VStack(alignment: .leading, spacing: 10) {
            VellumWidgetHeader(title: title, systemImage: systemImage, count: items.count)
            if items.isEmpty {
                Spacer(minLength: 0)
                Label(emptyMessage, systemImage: "tray")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer(minLength: 0)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.prefix(maximumVisibleItems))) { item in
                        if let link = item.deepLink {
                            Link(destination: link) {
                                VellumWidgetRow(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var maximumVisibleItems: Int {
        family == .systemLarge ? 6 : 3
    }
}

private struct VellumWidgetHeader: View {
    let title: String
    let systemImage: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(.primary)
            Spacer(minLength: 4)
            Text(count, format: .number)
                .font(.caption.bold())
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .accessibilityLabel("\(count) items")
        }
    }
}

private struct VellumWidgetRow: View {
    let item: VellumWidgetItem

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.systemImage)
                .font(.body)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.subheadline.bold())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right")
                .font(.caption.bold())
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.title)
        .accessibilityValue(item.subtitle)
    }
}
