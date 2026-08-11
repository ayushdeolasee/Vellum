#if os(iOS)
import SwiftUI

/// The Settings sheet, in one place.
///
/// iPad has no Settings *scene* — `SettingsView` is presented as a sheet, and
/// it was presented from `PdfChrome_iOS` with a hand-rolled `NavigationStack` +
/// environment-injection block. #70 adds a second entry point (Home's gear
/// button), and two copies of that block would drift the moment either one
/// gained an environment object. So it lives here and both call sites use it.
///
/// The `.environment(...)` injections are load-bearing, not decoration: a
/// `.sheet` is a separate presentation host, so it does not reliably inherit
/// the WindowGroup's environment across the `UIHostingController` boundary.
/// Settings ▸ Storage reads the workspace directly (to exclude open documents
/// from cleanup), and the AI tab edits the workspace's dedicated settings store
/// rather than any one pane's conversation.
///
/// Which tab it opens on is `workspace.settingsSection` — set it *before*
/// presenting, and `SettingsView` routes straight to it.
struct SettingsSheet_iOS: View {
    @Environment(WorkspaceStore.self) private var workspace

    var body: some View {
        SettingsView()
            .environment(workspace)
            // Settings ▸ Integrations and both of its sheets read the store via
            // @Environment(IntegrationsStore.self), and a missing @Environment
            // observable is a fatalError, not a nil — so it has to be injected into
            // this separate presentation host too.
            .environment(workspace.integrations)
            .environment(workspace.settingsAi)
            .environment(workspace.openRouterCatalog)
            .environment(workspace.chatgptAuth)
            .presentationDetents([.large])
    }
}

/// Each visible bottom tab owns its navigation container. This keeps the
/// Settings title and Done action stable when the selected tab changes.
struct SettingsTabNavigation<Content: View>: View {
    @Environment(\.dismiss) private var dismiss
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
    }
}

enum SettingsNavigationDestination: Hashable {
    case storage
    case integrations

    init?(section: WorkspaceStore.SettingsSection) {
        switch section {
        case .storage: self = .storage
        case .integrations: self = .integrations
        case .general, .reading, .annotations, .ai: return nil
        }
    }

    var settingsSection: WorkspaceStore.SettingsSection {
        switch self {
        case .storage: .storage
        case .integrations: .integrations
        }
    }
}

/// A deliberate fifth tab replaces iOS's automatic TabView "More" screen.
/// Its rows are real NavigationLinks, so VoiceOver and touch both expose the
/// Storage and Integrations destinations as actions.
struct MoreSettingsNavigation: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsNavigationDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                Section {
                    NavigationLink(value: SettingsNavigationDestination.storage) {
                        Label("Storage", systemImage: "internaldrive")
                    }
                    .accessibilityIdentifier("settings.more.storage")

                    NavigationLink(value: SettingsNavigationDestination.integrations) {
                        Label("Integrations", systemImage: "link")
                    }
                    .accessibilityIdentifier("settings.more.integrations")
                } footer: {
                    Text("Manage stored data, storage location, and connected read-later services.")
                }
            }
            .formStyle(.grouped)
            .contentMargins(.bottom, 32, for: .scrollContent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsNavigationDestination.self) { destination in
                switch destination {
                case .storage:
                    StorageSettingsTab()
                        .navigationTitle("Storage")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                case .integrations:
                    IntegrationsSettingsTab()
                        .navigationTitle("Integrations")
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("Done") { dismiss() }
                            }
                        }
                }
            }
        }
        .onAppear {
            route(to: workspace.settingsSection)
        }
        .onChange(of: workspace.settingsSection) { _, section in
            route(to: section)
        }
        .onChange(of: path) { _, path in
            if let destination = path.last {
                workspace.settingsSection = destination.settingsSection
            }
        }
    }

    private func route(to section: WorkspaceStore.SettingsSection) {
        let destination = SettingsNavigationDestination(section: section)
        path = destination.map { [$0] } ?? []
    }
}
#endif
