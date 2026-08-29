#if os(macOS)
import SwiftUI

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
        .frame(height: 460)
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
                        // the quit path cancels/drains it with the rest.
                        integrations.run { await integrations.sync(provider, forceFull: true) }
                    }
                    .disabled(state?.connection == .syncing)
                    Menu {
                        Button("Reconnect…") { connectProvider = provider }
                        Button("Disconnect…", role: .destructive) { disconnectProvider = provider }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .accessibilityLabel("More options for \(provider.name)")
                } else {
                    Button("Connect…") { connectProvider = provider }
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
