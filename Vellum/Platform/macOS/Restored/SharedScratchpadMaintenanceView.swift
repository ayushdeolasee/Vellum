#if os(macOS)
import SwiftUI

struct SharedScratchpadMaintenanceView: View {
    typealias Inventory = ScratchpadAttachmentCleanup.Inventory

    private struct Selection {
        let document: Inventory.Document
        var batch: Inventory.Document.Batch? = nil
    }

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var inventory: Inventory?
    @State private var selection: Selection?
    @State private var message: String?
    @State private var errorMessage: String?
    @State private var isWorking = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Scratchpad Attachments").font(.title2.bold())
                Text("Close the affected document before moving or restoring its images.")
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            Divider()
            List {
                if let inventory {
                    cleanupSection(inventory.documents.filter(\.hasAttachments))
                    recoverySection(inventory.documents.filter { !$0.batches.isEmpty })
                }
                if let message {
                    Label(message, systemImage: "checkmark.circle")
                        .accessibilityIdentifier("storage.scratchpad.result")
                }
                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("storage.scratchpad.error")
                }
            }
            Divider()
            HStack {
                Button("Refresh") { Task { await reload() } }
                    .disabled(isWorking)
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isWorking)
            }
            .padding(16)
        }
        .frame(width: 540, height: 420)
        .interactiveDismissDisabled(isWorking)
        .task { await reload() }
        .confirmationDialog(
            selection?.batch == nil ? "Move unused attachments to recovery?" : "Restore this batch?",
            isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } }),
            presenting: selection
        ) { selected in
            Button(selected.batch == nil ? "Move to Recovery" : "Restore Batch") { run(selected) }
                .accessibilityIdentifier("storage.scratchpad.confirm")
            Button("Cancel", role: .cancel) {}
        } message: { selected in
            if selected.batch == nil {
                Text("Vellum checks the current and preserved notes for “\(selected.document.title)”. An offline device may still need an image that is moved. You can restore it from Recovery here.")
            } else {
                Text("Files return to their original names for “\(selected.document.title)”. Any file whose name is already in use stays in recovery.")
            }
        }
        .accessibilityIdentifier("storage.scratchpad.sheet")
    }

    private func cleanupSection(_ documents: [Inventory.Document]) -> some View {
        Section("Cleanup") {
            if documents.isEmpty {
                Text("No shared documents with scratchpad attachments.").foregroundStyle(.secondary)
            }
            ForEach(documents) { document in
                HStack {
                    Text(document.title).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Clean Up…") { selection = Selection(document: document) }
                        .disabled(isWorking)
                        .accessibilityIdentifier("storage.scratchpad.cleanup.\(document.id)")
                }
            }
        }
    }

    private func recoverySection(_ documents: [Inventory.Document]) -> some View {
        Section {
            if documents.isEmpty {
                Text("No attachments in recovery.").foregroundStyle(.secondary)
            }
            ForEach(documents) { document in
                ForEach(document.batches) { batch in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(document.title).lineLimit(1).truncationMode(.middle)
                            Text("\(fileCount(batch.files.count)) · Moved \(batch.movedAt.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Restore Batch…") { selection = Selection(document: document, batch: batch) }
                            .disabled(isWorking)
                            .accessibilityIdentifier("storage.scratchpad.restore.\(batch.id)")
                    }
                }
            }
        } header: {
            Text("Recovery")
        } footer: {
            Text("Files are kept in .vellum/trash/scratchpad-attachments inside the shared folder.")
        }
    }

    private func reload() async {
        isWorking = true
        errorMessage = nil
        await loadInventory()
        isWorking = false
    }

    private func loadInventory() async {
        do {
            inventory = try await ScratchpadAttachmentCleanup.inventory(coordinator: workspace.storageCoordinator)
        } catch {
            inventory = nil
            self.errorMessage = self.errorMessage ?? "The shared folder could not be read. Check that it is available, then refresh."
        }
    }

    private func run(_ selected: Selection) {
        guard !isWorking, let inventory else { return }
        isWorking = true
        message = nil
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                if let batch = selected.batch {
                    let result = try await workspace.restoreSharedScratchpadBatch(
                        named: batch.id, forKey: selected.document.id, inventory: inventory)
                    message = result.keptInRecovery == 0
                        ? "Restored \(fileCount(result.restored))."
                        : "Restored \(fileCount(result.restored)). \(result.keptInRecovery) stayed in recovery because their names are already in use."
                } else {
                    let batch = try await workspace.cleanSharedScratchpadAttachments(
                        forKey: selected.document.id, inventory: inventory)
                    message = batch == nil
                        ? "No unused attachments were found in this selection."
                        : "Unused attachments were moved to Recovery. Select this document’s batch below to restore them."
                }
            } catch ScratchpadAttachmentCleanup.CleanupError.documentOpen {
                errorMessage = "Close the affected document and finish pending saves, then try again."
            } catch ScratchpadAttachmentCleanup.CleanupError.partialCleanup(_, _) {
                errorMessage = "Cleanup stopped early. Files already moved are available in Recovery."
            } catch let failure as WorkspaceStore.ConflictRecoveryError {
                errorMessage = failure.localizedDescription
            } catch {
                errorMessage = selected.batch == nil
                    ? "Cleanup could not finish safely. Refresh to see what is available in this shared folder."
                    : "The batch could not be fully restored. Remaining files are still shown in Recovery when the folder is available."
            }
            await loadInventory()
        }
    }

    private func fileCount(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count) files"
    }
}
#endif
