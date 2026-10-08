#if os(macOS)
import Foundation

/// Owns every Mac snapshot write so quit can drain it. Resolution and file I/O
/// run on the publisher actor; UI-only and hosted-test runs never open App Group.
@MainActor
final class VellumMacWidgetSnapshotController {
    private let enabled: Bool
    private let publisher: VellumWidgetSnapshotPublisher
    private var publishTask: Task<Void, Never>?
    private var isTerminating = false

    init() {
        enabled = !TestEnvironment.isHostedTestProcess && RuntimeProfile.current.syncEnabled
        publisher = VellumWidgetSnapshotPublisher(resolvingStore: { .resolve() })
    }

    func requestPublish(workspace: WorkspaceStore) {
        guard enabled, !isTerminating else { return }
        let previous = publishTask
        previous?.cancel()
        publishTask = Task { @MainActor in
            // Join any previous writer before requesting the next projection.
            await previous?.value
            guard !Task.isCancelled else { return }
            await workspace.awaitMaintenance()
            guard !Task.isCancelled else { return }
            await workspace.integrations.start()
            guard !Task.isCancelled else { return }
            await publisher.publish(readLaterItems: workspace.integrations.searchableItems)
        }
    }

    func beginTermination() {
        isTerminating = true
        publishTask?.cancel()
    }

    /// Called after external/system opens and integration persistence drain.
    func flushForTermination(workspace: WorkspaceStore) async {
        await publishTask?.value
        publishTask = nil
        guard enabled else { return }
        await publisher.publish(readLaterItems: workspace.integrations.searchableItems)
    }

    func cancelTermination(workspace: WorkspaceStore) {
        isTerminating = false
        requestPublish(workspace: workspace)
    }
}
#endif
