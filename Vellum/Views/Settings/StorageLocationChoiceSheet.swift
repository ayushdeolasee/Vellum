import AppKit
import SwiftUI

// First-launch storage-location choice (and the shared apply/relocate runner
// Settings reuses). The choice is explicit about the tradeoff: iCloud syncs
// everything (offline copies AND highlights/notes/reading positions); a custom
// folder holds only the offline copies while reading state stays local; This
// Mac keeps the pre-existing Application Support layout.

/// Applies a storage-location change: persist the preference, then move the
/// store in the background. The pending-relocation marker makes an interrupted
/// move resume at next launch.
///
/// Every relocation in the app — the launch sweep and each user change — goes
/// through here, because they all move the same files and share one resume
/// marker. Two passes running at once would race on both.
@MainActor
enum WebStorageRelocator {
    /// Back-to-back moves chain (each awaits the previous one), and
    /// only the newest change may clear the shared resume marker.
    private static var relocationChain: Task<Void, Never>?
    private static var relocationGeneration = 0

    /// Queue relocation work behind whatever is already in flight.
    @discardableResult
    private static func enqueue(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let prior = relocationChain
        let task = Task.detached(priority: .utility) {
            await prior?.value
            await work()
        }
        relocationChain = task
        return task
    }

    /// Launch pass: resume an interrupted move and fold in legacy-local strays.
    /// Awaits its turn on the chain — the first-launch sheet can hand us a new
    /// destination while this is still queued — and awaits completion, since
    /// callers go on to walk the store this sweep is still moving.
    static func sweepAtLaunch() async {
        await enqueue { WebStorageMigrator.sweepAtLaunch() }.value
    }

    static func apply(mode: WebStorageMode, customPath: String? = nil) {
        let previous = WebStorageSettings.chosenMode ?? .local
        let previousCustomPath = UserDefaults.standard.string(forKey: WebStorageSettings.customPathKey)
        let source = WebStorageLayout.resolve(mode: previous, storeDir: WebLibrary.storeDir)
        let sourceReachable = previous == .local || WebStorageSettings.root(for: previous) != nil

        WebStorageMigrator.recordPendingRelocation(mode: previous, customPath: previousCustomPath)
        WebStorageSettings.setMode(mode, customPath: customPath)
        // Capture the destination now, from the mode just set — resolving it
        // inside the task could pick up a newer change's mode.
        let destination = WebLibrary.activeLayout

        guard sourceReachable else {
            // Nothing can move while the old root is unreachable (iCloud
            // signed out, folder unmounted). Keep the marker: the launch
            // sweep migrates the stranded files when the root comes back.
            return
        }

        relocationGeneration += 1
        let generation = relocationGeneration
        enqueue {
            guard WebStorageMigrator.relocate(from: source, to: destination) else { return }
            await MainActor.run {
                if generation == relocationGeneration {
                    WebStorageMigrator.clearPendingRelocation()
                }
            }
        }
    }

    /// Folder picker for the custom mode; returns the chosen path or nil.
    static func pickCustomFolder() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Vellum will keep offline copies of your web pages in this folder."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }
}

/// One-time sheet shown at first launch after updating to (or installing) a
/// build with configurable storage.
struct StorageLocationChoiceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    private var icloudAvailable: Bool { WebStorageSettings.icloudVellumRoot != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where should Vellum keep your library?")
                    .font(.title2.weight(.semibold))
                Text("Vellum stores offline copies of web pages, plus your highlights, notes, and reading positions. You can change this anytime in Settings ▸ Storage.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            choiceCard(
                title: "Use iCloud Drive",
                badge: icloudAvailable ? "Recommended" : nil,
                systemImage: "icloud",
                description: icloudAvailable
                    ? "Everything — offline copies, highlights, notes, and reading positions — lives in iCloud Drive ▸ Vellum and syncs across your Macs."
                    : "iCloud Drive isn't available on this Mac. Sign in to iCloud and enable iCloud Drive to use this option.",
                disabled: !icloudAvailable,
                identifier: "storageChoice.icloud"
            ) {
                WebStorageRelocator.apply(mode: .icloud)
                dismiss()
            }

            choiceCard(
                title: "Choose a Folder…",
                badge: nil,
                systemImage: "folder",
                description: "Offline copies go in a folder you pick. Your highlights, notes, and reading positions stay on this Mac and won't sync.",
                disabled: false,
                identifier: "storageChoice.custom"
            ) {
                guard let path = WebStorageRelocator.pickCustomFolder() else { return }
                WebStorageRelocator.apply(mode: .custom, customPath: path)
                dismiss()
            }

            choiceCard(
                title: "Keep on This Mac",
                badge: nil,
                systemImage: "internaldrive",
                description: "Everything stays in Vellum's private app folder. No syncing.",
                disabled: false,
                identifier: "storageChoice.local"
            ) {
                WebStorageRelocator.apply(mode: .local)
                dismiss()
            }
        }
        .padding(24)
        .frame(width: 480)
        // .contain keeps each option button its own AX element with its own
        // identifier — without it the container id shadows all three buttons
        // (same gotcha as the Storage rows in SettingsView).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("storageChoice.sheet")
    }

    private func choiceCard(
        title: String,
        badge: String?,
        systemImage: String,
        description: String,
        disabled: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(disabled ? AnyShapeStyle(.tertiary) : AnyShapeStyle(palette.primary))
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.body.weight(.medium))
                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(palette.primary.opacity(0.15), in: Capsule())
                                .foregroundStyle(palette.primary)
                        }
                    }
                    Text(description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
        .accessibilityIdentifier(identifier)
    }
}
