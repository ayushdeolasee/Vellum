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
        }
    }

    private var label: String {
        switch reference.kind {
        case let .selection(text, page): return "“\(collapse(text))” · p.\(page)"
        case let .highlight(text, page): return "“\(collapse(text))” · p.\(page)"
        case let .region(_, page): return "Region · p.\(page)"
        case let .pageSnapshot(_, page): return "Page \(page)"
        case let .quote(text, _): return "“\(collapse(text))”"
        }
    }

    private func collapse(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
