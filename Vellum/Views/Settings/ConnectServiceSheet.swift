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
    /// Attempts can overlap (a superseded task is cancelled but still unwinding),
    /// so every state write is fenced on the attempt that owns the flag.
    @State private var validationGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) { Image(systemName: provider.symbol).font(.title2).foregroundStyle(.tint); VStack(alignment: .leading, spacing: 2) { Text("Connect \(provider.name)").font(.headline); Text(instructions).font(.caption).foregroundStyle(.secondary) } }
            RevealableSecureField(accessibilityLabel: "\(provider.name) access token", placeholder: "Paste access token", credentialName: "access token", text: $token).accessibilityIdentifier("integrations.connect.token")
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
        validationGeneration += 1
        let generation = validationGeneration
        validationError = nil
        isValidating = true
        // Store-owned (so quitting mid-validation can drain the keychain write)
        // but the handle is kept here too, because closing the sheet cancels it.
        connectionTask = integrations.run {
            // Released on EVERY exit path — including "cancelled after the token
            // was already accepted", which used to leave the sheet wedged. A
            // superseded attempt must not release the flag a newer one holds.
            defer { if generation == validationGeneration { isValidating = false } }
            do {
                try await integrations.connect(provider: provider, token: candidate)
                guard !Task.isCancelled, generation == validationGeneration else { return }
                resignAndDismiss()
            } catch is CancellationError {
                // Superseded or dismissed; nothing to report.
            } catch {
                guard generation == validationGeneration else { return }
                validationError = error.localizedDescription
            }
        }
    }
}
