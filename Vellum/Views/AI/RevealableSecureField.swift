import AppKit
import SwiftUI

/// A secure text field with an eye toggle that reveals the value in plaintext.
/// Used for API-key entry so users can verify what they pasted. Both modes are
/// autofill-free AppKit fields (see `AutofillFreeKeyField`); swapping between a
/// stock SwiftUI field and an AppKit one let the system autofill helper attach
/// to the stock side and crash the app (see below).
struct RevealableSecureField: View {
    let placeholder: String
    @Binding var text: String

    @Environment(\.palette) private var palette
    @State private var isRevealed = false

    var body: some View {
        HStack(spacing: 6) {
            AutofillFreeKeyField(placeholder: placeholder, isSecure: !isRevealed, text: $text)
                // The AppKit field class differs per mode; rebuild it on toggle.
                .id(isRevealed)
                .controlSize(.small)

            Button {
                // Resign focus before the swap and defer it a turn: replacing
                // the field while it is first responder can leave the system
                // autofill overlay attached to a dead field, and AppKit aborts
                // the app the next time a popover window orders on screen
                // (NSRemoteView "expected (null)" assertion).
                NSApp.keyWindow?.makeFirstResponder(nil)
                DispatchQueue.main.async { isRevealed.toggle() }
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

/// Field classes that opt out of the system Passwords autofill. Stock SwiftUI
/// fields always spawn the SafariPlatformSupport completion helper on focus
/// (`.textContentType` does not prevent it — verified via `log stream`), and a
/// macOS 27 ViewBridge bug in that helper aborts the app whenever a popover
/// window orders on screen while the helper's remote view is stale (NSRemoteView
/// "expected (null)" assertion — the model-selector crash). These fields hold
/// API keys, not login passwords, so autofill is useless here anyway.
///
/// The `@objc(_isPasswordAutofillEnabled)` accessors shadow AppKit's private
/// autofill gate. If a macOS update renames the selector they silently become
/// inert (never called) — they cannot break.
private final class NoAutofillSecureTextField: NSSecureTextField {
    @objc(_isPasswordAutofillEnabled)
    var isPasswordAutofillEnabled: Bool { false }
}

private final class NoAutofillTextField: NSTextField {
    @objc(_isPasswordAutofillEnabled)
    var isPasswordAutofillEnabled: Bool { false }
}

/// SwiftUI wrapper for the autofill-free fields, styled to match a small
/// `.roundedBorder` SwiftUI `TextField`. `isSecure` picks the field class at
/// creation time — pair a change of it with `.id(...)` so the view is rebuilt.
private struct AutofillFreeKeyField: NSViewRepresentable {
    let placeholder: String
    let isSecure: Bool
    @Binding var text: String

    func makeNSView(context: Context) -> NSTextField {
        let field: NSTextField = isSecure ? NoAutofillSecureTextField() : NoAutofillTextField()
        field.placeholderString = placeholder
        field.bezelStyle = .roundedBezel
        field.controlSize = .small
        field.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        // Stretch/shrink with the surrounding HStack instead of sizing to text.
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            text.wrappedValue = field.stringValue
        }
    }
}
