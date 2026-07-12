import SwiftUI

/// A secure text field with an eye toggle that reveals the value in plaintext.
/// Used for API-key entry so users can verify what they pasted. Swaps between a
/// `SecureField` and a `TextField` on toggle, preserving the same binding.
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String

    @Environment(\.palette) private var palette
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if isRevealed {
                    TextField(placeholder, text: $text)
                } else {
                    SecureField(placeholder, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.small)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isRevealed ? "Hide API key" : "Show API key")
            .accessibilityLabel(isRevealed ? "Hide API key" : "Show API key")
        }
    }
}
