#if os(iOS)
import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Token-paste connection sheet for a read-later provider.
///
/// Touch rebuild of `main:Vellum/Views/Settings/ConnectServiceSheet.swift`. The
/// concurrency shape is carried over untouched — it is the part that was hard to
/// get right — and only the chrome is re-hosted: a NavigationStack with
/// Cancel/Connect toolbar items instead of a fixed-width VStack with a trailing
/// button row.
///
/// Keychain-only token paste, deliberately: neither provider gets an OAuth flow.
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
        NavigationStack {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: provider.symbol).font(.title2).foregroundStyle(.tint)
                    Text(instructions).font(.caption).foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    RevealableSecureField(
                        accessibilityLabel: "\(provider.name) access token",
                        placeholder: "Paste access token", credentialName: "access token",
                        text: $token)
                        .accessibilityIdentifier("integrations.connect.token")
                    // Typing a 40-character token on a tablet is miserable; the
                    // pasteboard is how this field is actually filled.
                    if UIPasteboard.general.hasStrings {
                        Button {
                            token = UIPasteboard.general.string ?? token
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .accessibilityLabel("Paste access token")
                    }
                }

                Link("Open \(provider.name) token instructions", destination: helpURL).font(.caption)

                if let validationError {
                    Text(validationError).font(.caption).foregroundStyle(.red)
                        .accessibilityIdentifier("integrations.connect.error")
                }

                Spacer(minLength: 0)
            }
            .padding(20)
            .navigationTitle("Connect \(provider.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { resignAndDismiss() }
                        .keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isValidating ? "Connecting…" : "Connect") { connect() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(trimmed.isEmpty || isValidating)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onDisappear { connectionTask?.cancel(); connectionTask = nil }
    }

    private var trimmed: String { token.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var instructions: String { switch provider { case .readwise: "Use a Readwise Reader access token."; case .raindrop: "Use a Raindrop.io v1 test token." } }
    private var helpURL: URL { switch provider { case .readwise: URL(string: "https://readwise.io/access_token")!; case .raindrop: URL(string: "https://app.raindrop.io/settings/integrations")! } }

    /// The keyboard has to be down before the sheet dismisses, or the dismissal
    /// animates over a live keyboard. macOS resigned first responder through
    /// `NSApp.keyWindow`; the UIKit equivalent is a nil-targeted resign, which
    /// works regardless of which responder inside the representable holds focus.
    private func resignAndDismiss() {
        connectionTask?.cancel(); connectionTask = nil
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        dismiss()
    }

    private func connect() {
        let candidate = trimmed
        guard !candidate.isEmpty else { return }
        connectionTask?.cancel()
        validationGeneration += 1
        let generation = validationGeneration
        validationError = nil
        isValidating = true
        // Store-owned (so backgrounding mid-validation can drain the keychain
        // write) but the handle is kept here too, because closing the sheet
        // cancels it.
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
#endif
