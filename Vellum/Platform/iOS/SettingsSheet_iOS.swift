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
/// presenting, and `SettingsView`'s `TabView` binds straight to it.
struct SettingsSheet_iOS: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SettingsView()
                .navigationTitle("Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .environment(workspace)
        .environment(workspace.settingsAi)
        .environment(workspace.openRouterCatalog)
        .environment(workspace.chatgptAuth)
        .presentationDetents([.large])
    }
}
#endif
