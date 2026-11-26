#if DEBUG && SCRATCHPAD_QUALIFICATION
import Foundation
import VellumCore

/// Linked only into the explicit qualification build. The harness creates this
/// one private directory in a fresh offline container with a read-only rootfs.
public actor ScratchpadQualification {
    private let folder: LocalFolderFileStore
    private var failNextNote: Bool

    private init(root: URL, failNextNote: Bool) {
        folder = LocalFolderFileStore(root: root)
        self.failNextNote = failNextNote
    }

    public static func storage(files: ReadOnlyLibraryFileStore) async -> ScratchpadStorage? {
        let root = files.root.url
        guard root.path == "/tmp/vellum-484-fixture",
              let marker = try? await files.root.readRegularFile(
                  root.appendingPathComponent(".scratchpad-qualification"), byteLimit: 32),
              marker == Data("disposable #484\n".utf8)
        else { return nil }

        let fixture = Self(root: root,
            failNextNote: ProcessInfo.processInfo.environment["VELLUM_484_PARTIAL_WRITE"] == "1")
        return ScratchpadStorage(files: files) { url, data, baseline in
            try await fixture.replace(url, data, baseline)
        }
    }

    private func replace(_ url: URL, _ data: Data, _ baseline: Data?) async throws -> Bool {
        if url.lastPathComponent == "scratchpad.md" {
            // Deliberately leave enough time to select another document in
            // Weston while the save is still owned by the original document.
            try await Task.sleep(for: .milliseconds(750))
            if failNextNote {
                failNextNote = false
                throw LibraryFileError.io("Injected failure before note publication.")
            }
        }
        return try await folder.replace(url, with: data, ifCurrent: baseline)
    }
}
#endif
