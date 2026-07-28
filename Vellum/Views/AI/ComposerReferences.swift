import AppKit
import SwiftUI

// Chips shown above the composer input for each attached reference (selected
// text, highlight, snapshot, or an AI-reply quote). Removable; images show a
// small thumbnail.
//
// The read-only counterpart that stays with a message after it is sent is
// `SentReferenceChips`; the icon/label vocabulary both rows use lives on
// `AiReference` in that file so the two can't drift apart.

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
            Text(reference.chipLabel)
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
            Image(systemName: reference.chipIcon)
                .font(.system(size: 11))
                .foregroundStyle(palette.primary)
                .frame(width: 20, height: 20)
        }
    }

    private func decoded(_ snapshot: AiPageImageSnapshot) -> NSImage? {
        guard let data = Data(base64Encoded: snapshot.base64Data) else { return nil }
        return NSImage(data: data)
    }
}
