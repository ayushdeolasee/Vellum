import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Recovery surface for losing synced-file versions that Vellum preserved.
/// Export first copies bytes through `StorageCoordinator`; the Files picker
/// never receives the coordinated archive URL itself.
struct StorageConflictsView: View {
    @Binding var conflicts: [StorageCoordinator.ArchivedConflict]

    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var exporting: Set<URL> = []
    @State private var pendingRestore: StorageCoordinator.ArchivedConflict?
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
                    Text("Changes from different devices could not be combined safely. The current copy stays in use until you choose. Keep it or restore a preserved copy; both copies remain recoverable.")
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Restore this preserved copy?",
                isPresented: Binding(get: { pendingRestore != nil },
                    set: { if !$0 { pendingRestore = nil } }),
                presenting: pendingRestore
            ) { conflict in
                Button("Restore Copy") { restore(conflict) }
                    .accessibilityIdentifier("storage.conflicts.confirmRestore")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Close the affected document first. Vellum preserves the current copy before restoring this one. Open drafts are never replaced.")
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
                Text(conflict.needsReview ? "Needs review" : "Reviewed — recovery copy kept")
                    .foregroundStyle(conflict.needsReview ? Color.orange : Color.secondary)
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
                if conflict.needsReview {
                    Button("Keep Current") { keepCurrent(conflict) }
                        .accessibilityIdentifier("storage.conflicts.keep.\(conflict.archiveName)")
                }
                Button("Restore Copy…") { pendingRestore = conflict }
                    .accessibilityIdentifier("storage.conflicts.restore.\(conflict.archiveName)")
            }
            .disabled(!exporting.isEmpty)
            .buttonStyle(.borderless)

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
            .disabled(!exporting.isEmpty)
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
                #if os(iOS)
                DocumentPickerCoordinator_iOS.shared.presentExport(urls: [localCopy])
                #else
                let panel = NSSavePanel()
                panel.nameFieldStringValue = conflict.archiveName
                guard await panel.begin() == .OK, let destination = panel.url else { return }
                try await Task.detached {
                    try Data(contentsOf: localCopy).write(to: destination, options: .atomic)
                }.value
                #endif
            } catch {
                errorMessage = "The preserved copy couldn't be exported. Try again while iCloud Drive is available."
            }
        }
    }

    private func keepCurrent(_ conflict: StorageCoordinator.ArchivedConflict) {
        guard exporting.insert(conflict.id).inserted else { return }
        errorMessage = nil
        Task {
            defer { exporting.remove(conflict.id) }
            do {
                try await workspace.keepCurrentForArchivedConflict(conflict)
                conflicts = await workspace.storageCoordinator.archivedConflicts()
            } catch { errorMessage = "The current copy couldn't be confirmed. Recovery copies remain available." }
        }
    }

    private func restore(_ conflict: StorageCoordinator.ArchivedConflict) {
        guard exporting.insert(conflict.id).inserted else { return }
        errorMessage = nil
        Task {
            defer { exporting.remove(conflict.id) }
            do {
                try await workspace.restoreArchivedConflict(conflict)
                conflicts = await workspace.storageCoordinator.archivedConflicts()
            } catch let error as WorkspaceStore.ConflictRecoveryError {
                errorMessage = error.localizedDescription
            } catch let error as StorageCoordinator.ArchivedConflictError {
                conflicts = await workspace.storageCoordinator.archivedConflicts()
                errorMessage = error.localizedDescription
            } catch {
                errorMessage = "The preserved copy couldn't be restored. Current and recovery copies remain available; try again when storage is accessible."
            }
        }
    }

    private func delete(_ conflict: StorageCoordinator.ArchivedConflict) {
        guard exporting.insert(conflict.id).inserted else { return }
        errorMessage = nil
        Task {
            defer { exporting.remove(conflict.id) }
            do {
                try await workspace.deleteArchivedConflict(conflict)
                conflicts.removeAll { $0.id == conflict.id }
                if conflicts.isEmpty { dismiss() }
            } catch {
                errorMessage = "The preserved copy couldn't be deleted. Try again while iCloud Drive is available."
            }
        }
    }
}
