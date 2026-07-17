import Foundation

/// Process-wide registry of PENDING /VellumDocId stamps, keyed by canonical PDF
/// path. When two sessions open the SAME file (e.g. the same PDF in two split
/// panes) and each lazily stamps a doc id on its first mutation, they must agree
/// on ONE id — otherwise the two `PdfDocumentIO` actors mint divergent UUIDs and
/// the document's class-B data (notes, AI conversations) splits across two
/// folders. This registry hands every stamper the SAME pending UUID for a path
/// until the stamp lands durably on disk, at which point the entry is cleared
/// (a later reader resolves the id straight from the file's /VellumDocId).
///
/// The map is guarded by a lock so it is safe to consult from inside the several
/// `PdfDocumentIO` actors that may be stamping concurrently. The critical
/// section is a tiny dictionary lookup — no I/O — so it never blocks meaningfully.
enum PdfDocIdRegistry {
    private static let lock = NSLock()
    // Guarded by `lock` on every access, so the unchecked annotation is sound.
    nonisolated(unsafe) private static var pending: [String: String] = [:]

    /// The pending UUID already assigned to `path`, or a freshly minted one
    /// recorded for the next caller. Both stampers racing on one path thus stamp
    /// the SAME id. The caller must `clear(forPath:)` once the stamp is durably
    /// on disk (or roll nothing back — leaving the entry lets the next attempt
    /// reuse the same id after a failed write).
    static func pendingOrAssign(forPath path: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let existing = pending[path] { return existing }
        let uuid = UUID().uuidString.lowercased()
        pending[path] = uuid
        return uuid
    }

    /// Drop the pending entry once the stamp is durably on disk (or the id was
    /// found already present in the file) — future readers resolve it from disk.
    static func clear(forPath path: String) {
        lock.lock()
        defer { lock.unlock() }
        pending.removeValue(forKey: path)
    }

    /// Test seam: forget every pending assignment so cases start from a clean map.
    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        pending.removeAll()
    }
}
