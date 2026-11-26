import Foundation
import LinuxReader
import VellumCore

/// A device-local recovery version contains only the composer and turns that
/// were entered with shared editing enabled. Restoring it never grants editing.
actor ChatRecovery {
    struct Snapshot: Codable, Equatable, Sendable {
        var draft = ""
        var turns: [ConversationText] = []
    }

    private var versions: ReaderDraftRecovery
    private let document: String
    private var original = Snapshot()

    init(root: RootDirectory, document: String) {
        versions = ReaderDraftRecovery(root: root)
        self.document = document
    }

    func restore(root: RootDirectory) async throws -> Snapshot {
        do {
            if let bytes = try await versions.load(document: document, kind: "chat") {
                original = try JSONDecoder().decode(Snapshot.self, from: bytes)
            }
            return original
        } catch {
            // A future or unreadable version must survive a new draft.
            versions = ReaderDraftRecovery(root: root)
            throw error
        }
    }

    func keep(_ snapshot: Snapshot) async throws {
        guard snapshot != original else { return }
        if snapshot == Snapshot() {
            try await versions.remove(document: document, kind: "chat")
        } else {
            try await versions.save(JSONEncoder().encode(snapshot), document: document, kind: "chat")
        }
        original = snapshot
    }
}
