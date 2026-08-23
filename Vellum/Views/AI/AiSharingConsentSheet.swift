import SwiftUI

struct AiSharingConsentSheet: View {
    let provider: AiProvider
    let model: String
    let onAllow: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Vellum needs your permission before it sends document content to \(provider.displayName) to generate a reply or carry out an AI action.")
                }

                Section("Vellum may send") {
                    disclosureRow("Your prompt and recent AI conversation", symbol: "text.bubble")
                    disclosureRow("Document title, page text, annotations, and visible page numbers", symbol: "doc.text")
                    disclosureRow("Selected references and page images when needed", symbol: "photo")
                    disclosureRow("Other page excerpts and tool results when you ask the assistant to search", symbol: "magnifyingglass")
                }

                Section("How \(provider.displayName) handles it") {
                    Text(provider.dataHandlingSummary(model: model))
                    Link("Read \(provider.displayName)'s policy", destination: provider.privacyPolicyURL)
                    if let dataRulesURL = provider.currentDataRulesURL {
                        Link("Check the current model data rules", destination: dataRulesURL)
                    }
                }

                Section {
                    Link("Read Vellum's privacy policy", destination: VellumPrivacyPolicy.url)
                } footer: {
                    Text("Your API key stays in Apple Keychain and is sent only to authenticate with the selected service. You can stop future sharing in Settings. Revoking permission cannot delete data a provider already received.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Share with \(provider.displayName)?")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not Now") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Allow and Send") {
                        AiSharingConsent.grant(for: provider)
                        dismiss()
                        onAllow()
                    }
                    .accessibilityIdentifier("aiConsent.allowAndSend")
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 600)
        #endif
        .accessibilityIdentifier("aiConsent.sheet")
    }

    private func disclosureRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
    }
}
