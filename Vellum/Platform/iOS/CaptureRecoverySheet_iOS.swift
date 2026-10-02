#if os(iOS)
import SwiftUI

/// The device-local share inbox stays usable while saving is unavailable.
struct CaptureRecoverySheet_iOS: View {
    let ingestion: CaptureIngestion
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var entries: [CaptureInbox.RecoveryEntry] = []
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var errorMessage: String?
    @State private var pendingDelete: CaptureInbox.RecoveryEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if isLoading { ProgressView("Loading captures…") }
                    else if entries.isEmpty && errorMessage == nil { Text("All captures have been saved or removed.") }
                    ForEach(entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.title).font(.headline).lineLimit(2)
                            if let url = entry.sourceURL {
                                Text(url).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Text(entry.status).font(.caption).foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: entry.byteCount, countStyle: .file))
                                .font(.caption2).foregroundStyle(.secondary)
                            HStack {
                                if entry.canRetry {
                                    Button("Retry") { retry(entry) }
                                        .accessibilityIdentifier("capture.recovery.retry")
                                }
                                Button("Export Copy…") { export(entry) }
                                    .accessibilityIdentifier("capture.recovery.export")
                                Spacer()
                                Button("Delete", role: .destructive) { pendingDelete = entry }
                                    .accessibilityIdentifier("capture.recovery.delete")
                            }
                            .buttonStyle(.borderless)
                            .disabled(isWorking)
                        }
                        .accessibilityElement(children: .contain)
                    }
                } footer: {
                    Text("Captures are kept until saved or explicitly deleted. At 256 MB or 1,000 captures, new shares are refused while existing captures remain available.")
                }
                if isWorking { ProgressView("Working…") }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.orange)
                        .accessibilityIdentifier("capture.recovery.error")
                }
            }
            .navigationTitle("Unsaved Captures")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await reload() }
            .confirmationDialog("Delete this capture copy?",
                isPresented: Binding(get: { pendingDelete != nil },
                    set: { if !$0 { pendingDelete = nil } }), presenting: pendingDelete
            ) { entry in
                Button("Delete Capture", role: .destructive) { delete(entry) }
                    .accessibilityIdentifier("capture.recovery.confirmDelete")
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This permanently removes the capture copy after any active save finishes. Pages already saved to your library remain there. Export a copy first if you need it.")
            }
        }
        .accessibilityIdentifier("capture.recovery.sheet")
    }

    private func reload() async {
        defer { isLoading = false }
        do { entries = try await ingestion.recoveryEntries() }
        catch { errorMessage = error.localizedDescription }
    }

    private func retry(_ entry: CaptureInbox.RecoveryEntry) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            await workspace.startStorageCoordinator()
            do {
                let report = try await ingestion.retry(entry)
                if report.retained > 0 {
                    errorMessage = "Some captures could not be saved yet. They are kept here; retry when the page and your storage are available."
                }
            } catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }

    private func export(_ entry: CaptureInbox.RecoveryEntry) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do {
                let copy = try await ingestion.export(entry)
                DocumentPickerCoordinator_iOS.shared.presentExport(urls: [copy])
            } catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }

    private func delete(_ entry: CaptureInbox.RecoveryEntry) {
        guard !isWorking else { return }
        isWorking = true
        errorMessage = nil
        Task {
            defer { isWorking = false }
            do { try await ingestion.delete(entry) }
            catch { errorMessage = error.localizedDescription }
            await reload()
        }
    }
}
#endif
