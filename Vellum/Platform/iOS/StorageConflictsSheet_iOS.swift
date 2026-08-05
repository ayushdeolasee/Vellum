#if os(iOS)
import SwiftUI

/// Recovery surface for losing synced-file versions that Vellum preserved.
/// Export first copies bytes through `StorageCoordinator`; the Files picker
/// never receives the coordinated archive URL itself.
struct StorageConflictsSheet_iOS: View {
    @Binding var conflicts: [StorageCoordinator.ArchivedConflict]

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: Set<URL> = []
    @State private var pendingDelete: StorageCoordinator.ArchivedConflict?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(conflicts) { conflict in
                        conflictRow(conflict)
                    }
                } footer: {
                    Text("Vellum kept these copies when a sync conflict could not be merged safely. Export a copy before deleting it if you may need to recover its contents.")
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("storage.conflicts.error")
                    }
                }
            }
            .navigationTitle("Sync Conflicts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                pendingDelete.map { "Delete preserved copy of \"\($0.displayName)\"?" } ?? "",
                isPresented: Binding(
                    get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }),
                presenting: pendingDelete
            ) { conflict in
                Button("Delete Preserved Copy", role: .destructive) {
                    delete(conflict)
                }
                .accessibilityIdentifier("storage.conflicts.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently removes the preserved losing version. Export it first if you may need its contents.")
            }
        }
        .accessibilityIdentifier("storage.conflicts.sheet")
    }

    private func conflictRow(_ conflict: StorageCoordinator.ArchivedConflict) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(conflict.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Preserved \(conflict.detectedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(conflict.archiveName)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            HStack {
                Button("Export Copy…", systemImage: "square.and.arrow.up") {
                    export(conflict)
                }
                .disabled(exporting.contains(conflict.id))
                .accessibilityIdentifier("storage.conflicts.export.\(conflict.archiveName)")

                Spacer()

                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDelete = conflict
                }
                .accessibilityIdentifier("storage.conflicts.delete.\(conflict.archiveName)")
            }
            .buttonStyle(.borderless)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storage.conflicts.row.\(conflict.archiveName)")
    }

    private func export(_ conflict: StorageCoordinator.ArchivedConflict) {
        guard exporting.insert(conflict.id).inserted else { return }
        errorMessage = nil
        Task {
            defer { exporting.remove(conflict.id) }
            do {
                let localCopy = try await workspace.storageCoordinator
                    .exportArchivedConflict(conflict)
                DocumentPickerCoordinator_iOS.shared.presentExport(urls: [localCopy])
            } catch {
                errorMessage = "The preserved copy couldn't be exported. Try again while iCloud Drive is available."
            }
        }
    }

    private func delete(_ conflict: StorageCoordinator.ArchivedConflict) {
        errorMessage = nil
        Task {
            do {
                try await workspace.storageCoordinator.deleteArchivedConflict(conflict)
                conflicts.removeAll { $0.id == conflict.id }
                if conflicts.isEmpty { dismiss() }
            } catch {
                errorMessage = "The preserved copy couldn't be deleted. Try again while iCloud Drive is available."
            }
        }
    }
}
#endif
