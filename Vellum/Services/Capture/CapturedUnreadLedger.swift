import Foundation

/// Device-local "New" state for pages imported through the share extension.
///
/// This deliberately does not live in `WebPageRecord`: opening an article must
/// not rewrite its coordinated/iCloud sidecar or contend with annotation saves.
/// The ledger stores only opaque web storage keys, so it contains no URLs or
/// article metadata and remains valid when the library changes location.
actor CapturedUnreadLedger {
    static let shared = CapturedUnreadLedger()

    private let defaults: UserDefaults
    private let defaultsKey: String

    init(
        suiteName: String? = nil,
        defaultsKey: String = "capture.unread-web-keys"
    ) {
        defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
        self.defaultsKey = defaultsKey
    }

    func markUnread(forKey key: String) {
        guard !key.isEmpty else { return }
        var keys = unreadKeys()
        guard keys.insert(key).inserted else { return }
        defaults.set(Array(keys).sorted(), forKey: defaultsKey)
    }

    func markOpened(document: DocumentInfo) {
        guard document.kind == .web else { return }
        clearUnread(forKey: WebLibrary.pageKey(document.pdfPath))
    }

    func clearUnread(forKey key: String) {
        var keys = unreadKeys()
        guard keys.remove(key) != nil else { return }
        defaults.set(Array(keys).sorted(), forKey: defaultsKey)
    }

    func isUnread(forKey key: String) -> Bool {
        unreadKeys().contains(key)
    }

    private func unreadKeys() -> Set<String> {
        Set(defaults.stringArray(forKey: defaultsKey) ?? [])
    }
}

extension Notification.Name {
    /// A durable capture became visible in the web library. Home listens only
    /// to re-index its snapshot; the unread state itself remains in the ledger.
    static let vellumCapturedLibraryChanged =
        Notification.Name("vellum.captured-library-changed")
}
