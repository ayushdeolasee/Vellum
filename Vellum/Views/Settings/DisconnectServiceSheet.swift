import SwiftUI

struct DisconnectServiceSheet: View {
    let provider: IntegrationProvider
    @Environment(IntegrationsStore.self) private var integrations
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var deleteDownloads = false
    @State private var isDisconnecting = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Disconnect \(provider.name)?").font(.headline)
            Text("Vellum will remove the token from Keychain and delete this service’s cached library metadata.").foregroundStyle(.secondary)
            Toggle("Also delete downloaded PDFs", isOn: $deleteDownloads)
            Text(deleteDownloads ? "This permanently deletes managed PDFs, including Vellum annotations and reading metadata embedded in those files. Open PDFs must be closed first." : "Downloaded PDFs are kept by default and are never removed by synchronization.").font(.caption).foregroundStyle(deleteDownloads ? .red : .secondary)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction); Button("Disconnect", role: .destructive) { disconnect() }.keyboardShortcut(.defaultAction).disabled(isDisconnecting) }
        }.padding(24).frame(width: 420)
    }
    private func disconnect() { isDisconnecting = true; errorMessage = nil; let paths = Set(workspace.root.allLeaves().flatMap { $0.app.tabs.compactMap { $0.document?.kind == .pdf ? $0.document?.pdfPath : nil } }); Task { do { try await integrations.disconnect(provider: provider, deleteDownloads: deleteDownloads, openDocumentPaths: paths); dismiss() } catch { errorMessage = error.localizedDescription; isDisconnecting = false } } }
}
