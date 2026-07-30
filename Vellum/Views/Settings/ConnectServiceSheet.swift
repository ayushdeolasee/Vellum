import AppKit
import SwiftUI

struct ConnectServiceSheet: View {
    let provider: IntegrationProvider
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var isValidating = false
    @State private var validationError: String?
    @State private var connectionTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) { Image(systemName: provider.symbol).font(.title2).foregroundStyle(.tint); VStack(alignment: .leading, spacing: 2) { Text("Connect \(provider.name)").font(.headline); Text(instructions).font(.caption).foregroundStyle(.secondary) } }
            RevealableSecureField(placeholder: "Paste access token", credentialName: "access token", text: $token).accessibilityIdentifier("integrations.connect.token")
            Link("Open \(provider.name) token instructions", destination: helpURL).font(.caption)
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red).accessibilityIdentifier("integrations.connect.error") }
            HStack { Spacer(); Button("Cancel", role: .cancel) { resignAndDismiss() }.keyboardShortcut(.cancelAction); Button(isValidating ? "Connecting…" : "Connect") { connect() }.keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty || isValidating) }
        }.padding(24).frame(width: 430)
            .onDisappear { connectionTask?.cancel(); connectionTask = nil }
    }
    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var instructions: String { switch provider { case .readwise: "Use a Readwise Reader access token."; case .raindrop: "Use a Raindrop.io v1 test token." } }
    private var helpURL: URL { switch provider { case .readwise: URL(string: "https://readwise.io/access_token")!; case .raindrop: URL(string: "https://app.raindrop.io/settings/integrations")! } }
    private func resignAndDismiss() { connectionTask?.cancel(); connectionTask = nil; NSApp.keyWindow?.makeFirstResponder(nil); dismiss() }
    private func connect() {
        let candidate = trimmed
        guard !candidate.isEmpty else { return }
        connectionTask?.cancel()
        validationError = nil
        isValidating = true
        connectionTask = Task {
            do {
                try await integrations.connect(provider: provider, token: candidate)
                guard !Task.isCancelled else { return }
                resignAndDismiss()
            } catch is CancellationError {
                isValidating = false
            } catch {
                validationError = error.localizedDescription
                isValidating = false
                connectionTask = nil
            }
        }
    }
}
