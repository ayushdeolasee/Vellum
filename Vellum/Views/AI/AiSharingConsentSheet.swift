import SwiftUI

struct AiSharingConsentSheet: View {
    let provider: AiProvider
    let onAllow: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Before Vellum sends this request to \(provider.consentDisplayName), it needs your permission to share its contents.")
                }

                Section("What will be sent") {
                    Text("Your prompt, document title and page text, annotations, conversation history, and any attached images.")
                }

                Section {
                    Text("You can reset this permission later in AI Settings.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share with \(provider.consentDisplayName)?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Allow & Send") {
                        AiSharingConsent.grant(for: provider)
                        dismiss()
                        onAllow()
                    }
                    .accessibilityIdentifier("aiConsent.allowAndSend")
                }
            }
        }
        #if os(macOS)
        .frame(width: 460, height: 320)
        #endif
        .accessibilityIdentifier("aiConsent.sheet")
    }
}
