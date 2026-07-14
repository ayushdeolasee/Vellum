import SwiftUI
import UIKit

/// A secure text field with an eye toggle that reveals the value in plaintext.
/// Used for API-key entry so users can verify what they pasted.
///
/// Backed by a single `UITextField` whose `isSecureTextEntry` flips on the eye
/// toggle — one field, so toggling reveal never loses the caret or the pasted
/// value the way swapping a SwiftUI `SecureField` for a `TextField` does.
///
/// The reveal state (`isRevealed`) is per-instance `@State`, and every call site
/// gives this view an `.id(provider)`. Changing provider therefore rebuilds the
/// view with `isRevealed == false`, so a revealed key never carries over to
/// another provider's field (never show another provider's key in plaintext).
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String

    @Environment(\.palette) private var palette
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            SecureTextFieldRep(placeholder: placeholder, isSecure: !isRevealed, text: $text)
                .frame(height: 30)

            Button {
                isRevealed.toggle()
            } label: {
                Image(systemName: isRevealed ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(palette.mutedForeground)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isRevealed ? "Hide API key" : "Show API key")
        }
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
    }
}

/// UITextField wrapper that toggles `isSecureTextEntry` in place. API keys are
/// not login passwords, so QuickType/autofill/autocorrect are all turned off.
private struct SecureTextFieldRep: UIViewRepresentable {
    let placeholder: String
    let isSecure: Bool
    @Binding var text: String

    func makeUIView(context: Context) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.font = .systemFont(ofSize: 15)
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.smartQuotesType = .no
        field.smartDashesType = .no
        field.smartInsertDeleteType = .no
        // Keep the system Passwords/keychain helper out of an API-key field.
        field.textContentType = .none
        field.clearButtonMode = .whileEditing
        field.isSecureTextEntry = isSecure
        field.addTarget(
            context.coordinator, action: #selector(Coordinator.editingChanged(_:)),
            for: .editingChanged)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateUIView(_ field: UITextField, context: Context) {
        if field.text != text { field.text = text }
        field.placeholder = placeholder
        if field.isSecureTextEntry != isSecure {
            // Flipping isSecureTextEntry while first responder can drop the whole
            // string on the next keystroke; re-seat the text to keep it intact.
            field.isSecureTextEntry = isSecure
            let existing = field.text
            field.text = nil
            field.text = existing
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject {
        private let text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        @objc func editingChanged(_ field: UITextField) {
            text.wrappedValue = field.text ?? ""
        }
    }
}
