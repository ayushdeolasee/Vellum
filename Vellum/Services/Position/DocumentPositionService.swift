import Foundation

/// App-facing facade over the per-device position store. It keeps document-key
/// resolution in one place so open/close/background paths can record reading
/// state without learning the position-store wire format.
struct DocumentPositionService: Sendable {
    let store: PositionStore
    private let beforeRecordMoved: (@Sendable (ReadingPosition) async -> Void)?

    init(
        storage: any PositionStorage = FilePositionStorage(),
        device: DeviceIdentity = .current(),
        clock: PositionClock = SystemPositionClock(),
        timer: PositionTimer = TaskPositionTimer(),
        policy: CoalescePolicy = .default,
        beforeRecordMoved: (@Sendable (ReadingPosition) async -> Void)? = nil
    ) {
        store = PositionStore(
            storage: storage,
            device: device,
            clock: clock,
            timer: timer,
            policy: policy)
        self.beforeRecordMoved = beforeRecordMoved
    }

    init(
        store: PositionStore,
        beforeRecordMoved: (@Sendable (ReadingPosition) async -> Void)? = nil
    ) {
        self.store = store
        self.beforeRecordMoved = beforeRecordMoved
    }

    func key(for document: DocumentInfo) -> DocumentKey? {
        Self.key(for: document)
    }

    static func key(for document: DocumentInfo) -> DocumentKey? {
        switch document.kind {
        case .web:
            if let docId = document.docId,
               DocumentKey(rawValue: "web:\(docId)") != nil {
                return DocumentKey(rawValue: "web:\(docId)")
            }
            let normalized = (try? WebUrl.normalize(document.pdfPath)) ?? document.pdfPath
            return .web(normalizedURL: normalized)
        case .pdf:
            if let docId = document.docId, !docId.isEmpty {
                return .pdf(stableIdentifier: docId)
            }
            return .pdfPath(document.pdfPath)
        }
    }

    static func webKey(for url: String) -> DocumentKey {
        let normalized = (try? WebUrl.normalize(url)) ?? url
        return .web(normalizedURL: normalized)
    }

    func recordOpened(document: DocumentInfo, tabOrdinal: Int?) async {
        guard let key = key(for: document) else { return }
        await store.record(.opened(title: document.title, tabOrdinal: tabOrdinal), for: key)
    }

    func recordTitle(document: DocumentInfo, title: String) async {
        guard let key = key(for: document) else { return }
        await store.record(.titled(title), for: key)
    }

    func recordMoved(document: DocumentInfo, position: ReadingPosition) async {
        guard let key = key(for: document) else { return }
        await beforeRecordMoved?(position)
        await store.record(.moved(position), for: key)
    }

    func recordClosed(document: DocumentInfo) async {
        guard let key = key(for: document) else { return }
        await store.record(.closed, for: key)
    }

    func resumePosition(for document: DocumentInfo) async -> ReadingPosition? {
        guard let key = key(for: document) else { return nil }
        return await store.resume(for: key)?.position
    }

    func lastOpened(for document: DocumentInfo) async -> Date? {
        guard let key = key(for: document) else { return nil }
        return await store.resume(for: key)?.openedAt
    }

    func lastOpenedForWebURL(_ url: String) async -> Date? {
        let normalized = (try? WebUrl.normalize(url)) ?? url
        return await store.resume(for: .web(normalizedURL: normalized))?.openedAt
    }

    func lastOpenedByWebKey() async -> [String: Date] {
        await store.webLastOpenedByKey()
    }

    func flush() async {
        await store.flush()
    }
}
