#if os(iOS)
import SwiftUI

/// The explicit way back from immersive reading.
///
/// This replaces the old window-wide single-tap recognizer. A reader tap is
/// already meaningful to PDFKit and WebKit (links, selection, zoom and focus),
/// so it must never carry a second, unrelated chrome action. A small trailing
/// handle is discoverable, has one unambiguous result, and stays clear of both
/// vertical scrolling and the system's bottom-edge Home gesture.
struct ChromeRevealControl_iOS: View {
    var isActive: Bool
    var chromeVisible: Bool
    var action: () -> Void

    var body: some View {
        if isActive && !chromeVisible {
            Button("Show reader controls", systemImage: "slider.horizontal.3", action: action)
                .labelStyle(.iconOnly)
                .font(.title3.weight(.medium))
                .frame(
                    width: PhoneChromeLayout.buttonSide,
                    height: PhoneChromeLayout.buttonSide)
                .foregroundStyle(.primary)
                .glassEffect(.regular, in: .capsule)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
                .accessibilityLabel("Show reader controls")
                .accessibilityIdentifier("phone.reader.showChrome")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                .padding(.trailing, PhoneChromeLayout.edgeInset)
        }
    }
}
#endif
