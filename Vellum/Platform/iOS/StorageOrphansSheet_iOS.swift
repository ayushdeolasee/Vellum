#if os(iOS)
import SwiftUI

/// Compact recovery surface for moved PDFs and legacy, not-yet-adopted data.
/// Relink and deletion remain owned by `StorageSettingsTab`; this sheet only
/// presents those existing operations and their confirmations.
struct StorageOrphansSheet_iOS: View {
    let orphanRows: [StorageInventory.DocumentRow]
    let legacyRows: [LegacyRow]
    let relinkFailures: [String: String]
    let onRelink: (StorageInventory.DocumentRow) -> Void
    let onDeleteOrphan: (StorageInventory.DocumentRow) -> Void
    let onDeleteLegacy: (LegacyRow) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var pendingOrphanDelete: StorageInventory.DocumentRow?
    @State private var pendingLegacyDelete: LegacyRow?

    var body: some View {
        NavigationStack {
            List {
                if !orphanRows.isEmpty {
                    Section("Moved or missing documents") {
                        ForEach(orphanRows) { row in
                            StorageOrphanRow_iOS(
                                row: row,
                                failureMessage: relinkFailures[row.key],
                                onRelink: { onRelink(row) },
                                onDelete: { pendingOrphanDelete = row })
                        }
                    }
                }

                if !legacyRows.isEmpty {
                    Section("Older Vellum data") {
                        ForEach(legacyRows) { row in
                            StorageLegacyRow_iOS(
                                row: row,
                                onDelete: { pendingLegacyDelete = row })
                        }
                    }
                }
            }
            .navigationTitle("Orphans & Unlinked")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                Text("A missing file may only be offloaded from iCloud or on a disconnected drive. Nothing here is deleted automatically.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
            .confirmationDialog(
                pendingOrphanDelete.map { "Delete data for \"\($0.title)\"?" } ?? "",
                isPresented: bindingFor($pendingOrphanDelete),
                presenting: pendingOrphanDelete
            ) { row in
                Button("Delete Data", role: .destructive) { onDeleteOrphan(row) }
                    .accessibilityIdentifier("storage.confirmOrphanDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The original file couldn't be found, so this can't be reconnected. Deleting removes its notes, attachments and AI chat permanently. If the file is only on an unplugged drive or offloaded from iCloud, relink it instead. This cannot be undone.")
            }
            .confirmationDialog(
                pendingLegacyDelete.map {
                    "Delete \($0.kindLabel.lowercased()) for \"\($0.displayLabel)\"?"
                } ?? "",
                isPresented: bindingFor($pendingLegacyDelete),
                presenting: pendingLegacyDelete
            ) { row in
                Button("Delete", role: .destructive) { onDeleteLegacy(row) }
                    .accessibilityIdentifier("storage.confirmLegacyDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This is data from an older version that hasn't been migrated to a document yet. Deleting it is permanent and cannot be undone.")
            }
        }
        .accessibilityIdentifier("storage.orphansSheet")
    }

    private func bindingFor<T>(_ pending: Binding<T?>) -> Binding<Bool> {
        Binding(
            get: { pending.wrappedValue != nil },
            set: { if !$0 { pending.wrappedValue = nil } })
    }
}

struct StorageOrphanRow_iOS: View {
    @Environment(\.palette) private var palette
    let row: StorageInventory.DocumentRow
    let failureMessage: String?
    let onRelink: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("Original file not found", systemImage: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(palette.gold)
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .accessibilityIdentifier("storageOrphan.relinkFailure.\(row.key)")
                }
            }
            Spacer()
            Text(row.totalBytes.formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Relink…", action: onRelink)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("storageOrphan.relink.\(row.key)")
            Button("Delete data for \(row.title)", systemImage: "trash", role: .destructive) {
                onDelete()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("storageOrphan.delete.\(row.key)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storageOrphan.\(row.key)")
    }
}

struct StorageLegacyRow_iOS: View {
    let row: LegacyRow
    let onDelete: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Not yet migrated · \(row.kindLabel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(Int64(row.bytes).formatted(.byteCount(style: .file)))
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("Delete \(row.kindLabel) for \(row.displayLabel)", systemImage: "trash", role: .destructive) {
                onDelete()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .accessibilityIdentifier("storageLegacy.delete.\(row.id)")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storageLegacy.\(row.id)")
    }
}
#endif
