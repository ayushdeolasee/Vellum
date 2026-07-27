import AppKit
import SwiftUI

// Chips shown above the composer input for each attached reference (selected
// text, highlight, snapshot, or an AI-reply quote). Removable; images show a
// small thumbnail.

struct ReferenceChipRow: View {
    let references: [AiReference]
    let onRemove: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(references) { reference in
                    ReferenceChip(reference: reference, onRemove: { onRemove(reference.id) })
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: 40)
    }
}

/// Immutable provenance shown beneath a sent user message. Unlike composer
/// chips these have no remove affordance because they describe what was already
/// sent, not what will be sent next.
struct SentReferenceChipRow: View {
    let references: [AiMessageReference]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(references) { reference in
                    SentReferenceChip(reference: reference)
                }
            }
            .padding(.horizontal, 2)
        }
        .frame(maxHeight: 34)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Reference delivery for this message")
    }
}

private struct SentReferenceChip: View {
    let reference: AiMessageReference

    @Environment(\.palette) private var palette

    var body: some View {
        Label {
            Text(summary)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: icon)
        }
        .font(.system(size: 11))
        .foregroundStyle(isSent ? palette.mutedForeground : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.35), in: Capsule())
        .overlay { Capsule().strokeBorder(palette.border) }
        .accessibilityLabel(accessibilitySummary)
    }

    private var summary: String {
        let source = reference.documentTitle.flatMap { $0.isEmpty ? nil : $0 }
        let locator = reference.page.map { "p.\($0)" }
        return [reference.label, locator, source, deliverySummary].compactMap { $0 }.joined(separator: " · ")
    }

    private var accessibilitySummary: String {
        let page = reference.page.map { ", page \($0)" } ?? ""
        let document = reference.documentTitle.map { ", from \($0)" } ?? ""
        return "\(reference.kind.accessibilityName): \(reference.label)\(page)\(document), \(deliveryAccessibilitySummary)"
    }

    private var icon: String {
        guard isSent else { return "exclamationmark.triangle" }
        return switch reference.kind {
        case .selection: "text.quote"
        case .highlight: "highlighter"
        case .region: "square.dashed"
        case .pageSnapshot: "doc.richtext"
        case .quote: "quote.bubble"
        case .image: "photo"
        }
    }

    private var isSent: Bool {
        reference.delivery == .sent
    }

    private var deliverySummary: String? {
        switch reference.delivery {
        case .sent: nil
        case .omittedBudget: "Not sent: context limit"
        case .omittedUnsupportedImage: "Not sent: model cannot read images"
        }
    }

    private var deliveryAccessibilitySummary: String {
        switch reference.delivery {
        case .sent: "sent"
        case .omittedBudget: "not sent because the context limit was reached"
        case .omittedUnsupportedImage: "not sent because the selected model cannot read images"
        }
    }
}

private extension AiMessageReference.Kind {
    var accessibilityName: String {
        switch self {
        case .selection: "Text selection"
        case .highlight: "Highlight"
        case .region: "Document region"
        case .pageSnapshot: "Page snapshot"
        case .quote: "Assistant quote"
        case .image: "Attached image"
        }
    }
}

private struct ReferenceChip: View {
    let reference: AiReference
    let onRemove: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(label)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 150)
                .foregroundStyle(palette.foreground)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 14, height: 14)
                    .background(hovering ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .accessibilityLabel("Remove reference")
        }
        .padding(.leading, 4)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(palette.border) }
    }

    @ViewBuilder
    private var leading: some View {
        if let image = reference.image, let nsImage = decoded(image) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
        } else {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(palette.primary)
                .frame(width: 20, height: 20)
        }
    }

    private func decoded(_ snapshot: AiPageImageSnapshot) -> NSImage? {
        guard let data = Data(base64Encoded: snapshot.base64Data) else { return nil }
        return NSImage(data: data)
    }

    private var icon: String {
        switch reference.kind {
        case .selection: return "text.quote"
        case .highlight: return "highlighter"
        case .region: return "square.dashed"
        case .pageSnapshot: return "doc.richtext"
        case .quote: return "quote.bubble"
        case .image: return "photo"
        }
    }

    private var label: String {
        switch reference.kind {
        case let .selection(text, page): return "“\(collapse(text))” · p.\(page)"
        case let .highlight(text, page): return "“\(collapse(text))” · p.\(page)"
        case let .region(_, page): return "Region · p.\(page)"
        case let .pageSnapshot(_, page): return "Page \(page)"
        case let .quote(text, _): return "“\(collapse(text))”"
        case let .image(_, name): return name
        }
    }

    private func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
