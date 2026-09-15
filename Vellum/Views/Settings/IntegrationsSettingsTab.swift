#if os(iOS)
import SwiftUI

/// The Integrations tab of the settings sheet: auto-refresh scheduling plus one
/// row per read-later provider (connect / sync / reconnect / disconnect).
///
/// Touch rebuild of `main:Vellum/Views/Settings/IntegrationsSettingsTab.swift`.
/// Same information, same store calls, same user-visible strings and the same
/// accessibility identifiers — only the controls are re-hosted for a finger:
/// `.menuStyle(.borderlessButton)` does not exist on iOS, and every tappable
/// affordance needs a 44pt target with the frame INSIDE the label.
struct IntegrationsSettingsTab: View {
    @Environment(IntegrationsStore.self) private var integrations
    @State private var connectProvider: IntegrationProvider?
    @State private var disconnectProvider: IntegrationProvider?

    var body: some View {
        Form {
            Section {
                Toggle("Refresh automatically", isOn: Binding(
                    get: { integrations.autoRefreshEnabled },
                    set: { integrations.setAutoRefresh($0) }))
                LabeledContent("Schedule", value: "Every 30 minutes")
            } header: {
                Text("Refresh")
            } footer: {
                Text("Connected services refresh when stale. Sync Now performs a complete authoritative traversal.")
            }

            Section {
                Toggle("Download for offline reading", isOn: Binding(
                    get: { integrations.offlineReadingEnabled },
                    set: { integrations.setOfflineReading($0) }))
                    .accessibilityIdentifier("integrations.offlineReading")
            } header: {
                Text("Offline reading")
            } footer: {
                Text("Articles and PDFs from your read-later queue are downloaded in the background so they open without a connection. A downloaded copy is kept for 14 days; reading it starts another 14, and annotating it keeps it for good.")
            }

            Section("Read-later services") {
                ForEach(IntegrationProvider.allCases) { provider in
                    providerRow(provider)
                }
            }

            if integrations.providers[.raindrop]?.isConnected == true {
                Section {
                    Picker("Default folder", selection: Binding(
                        get: { integrations.defaultCollectionID(for: .raindrop) },
                        set: { integrations.setDefaultRaindropCollectionID($0) })) {
                        Text("All folders").tag(String?.none)
                        ForEach(integrations.providers[.raindrop]?.collections ?? []) { collection in
                            Text(String(repeating: "  ", count: collection.depth) + collection.title)
                                .tag(Optional(collection.id))
                        }
                    }
                    .accessibilityIdentifier("integrations.raindrop.defaultFolder")
                } header: {
                    Text("Raindrop.io")
                } footer: {
                    Text("Vellum opens this folder first. You can still change the folder from Home filters.")
                }
            }
        }
        .formStyle(.grouped)
        #if os(iOS)
        .contentMargins(.bottom, settingsBottomNavigationClearance, for: .scrollContent)
        #endif
        // No `.frame(height: 460)`: on iPad the settings sheet fills its own
        // presentation, and pinning a height would strand the last row.
        .sheet(item: $connectProvider) { ConnectServiceSheet(provider: $0) }
        .sheet(item: $disconnectProvider) { DisconnectServiceSheet(provider: $0) }
    }

    private func providerRow(_ provider: IntegrationProvider) -> some View {
        let state = integrations.providers[provider]
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: provider.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                    Text(status(state))
                        .font(.caption)
                        .foregroundStyle(color(state))
                        .lineLimit(2)
                }
                Spacer()
                if state?.connection == .syncing || state?.connection == .connecting {
                    ProgressView().controlSize(.small)
                }
                if state?.isConnected == true {
                    Button("Sync Now") {
                        // Store-owned task: the handle outlives this row, and
                        // the scene-background drain cancels/joins it with the
                        // rest of the store's work.
                        integrations.run { await integrations.sync(provider, forceFull: true) }
                    }
                    .buttonStyle(.bordered)
                    .frame(minHeight: 44)
                    .disabled(state?.connection == .syncing)

                    Menu {
                        Button("Reconnect…") { connectProvider = provider }
                        Button("Disconnect…", role: .destructive) { disconnectProvider = provider }
                    } label: {
                        // The frame and contentShape belong INSIDE the label:
                        // a Menu's hit region is its label's, so sizing the
                        // Menu itself would leave a glyph-sized tap target.
                        Image(systemName: "ellipsis.circle")
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More options for \(provider.name)")
                } else {
                    Button("Connect…") { connectProvider = provider }
                        .buttonStyle(.bordered)
                        .frame(minHeight: 44)
                }
            }
            if let state, state.isConnected {
                HStack {
                    Text("Cached items: \(state.items.count)")
                    Spacer()
                    if let date = state.lastSuccessfulSync {
                        Text("Last sync: \(date.formatted(.relative(presentation: .named)))")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }

    private func status(_ state: IntegrationProviderViewState?) -> String {
        guard let state else { return "Not connected" }
        if let value = state.statusMessage { return value }
        switch state.connection {
        case .disconnected: return "Not connected"
        case .connecting: return "Checking token…"
        case .connected: return "Connected"
        case .syncing: return "Syncing…"
        case .tokenRejected: return "Token rejected — reconnect required"
        case .offlineCache: return "Offline — showing cached items"
        case .failed(let value): return value
        }
    }

    private func color(_ state: IntegrationProviderViewState?) -> Color {
        switch state?.connection {
        case .tokenRejected, .failed: return .red
        case .offlineCache: return .orange
        default: return .secondary
        }
    }
}
#endif
