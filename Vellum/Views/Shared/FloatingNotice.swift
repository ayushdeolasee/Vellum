import SwiftUI

struct FloatingNotice: View {
    let message: String
    let progress: Double?
    let isActive: Bool
    var isSuccess: Bool = false
    var accessibilityID: String = "integrations.downloadNotice"
    let dismiss: () -> Void

    @Environment(\.palette) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(message).font(.system(size: 12)).foregroundStyle(palette.foreground).lineLimit(2)
                Spacer(minLength: 8)
                // The frame and contentShape must live INSIDE the label: on a
                // .plain button, applied outside they change layout only and the
                // hit region stays the bare glyph (root CLAUDE.md hit-target rule).
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            if isActive {
                if let progress { ProgressView(value: progress).progressViewStyle(.linear) }
                else { ProgressView().controlSize(.small) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: 340)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(.separator) }
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityIdentifier(accessibilityID)
    }

    private var symbol: String {
        if isActive { return "arrow.down.circle.fill" }
        return isSuccess ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    private var tint: Color {
        if isActive { return .accentColor }
        return isSuccess ? palette.success : palette.destructive
    }
}
