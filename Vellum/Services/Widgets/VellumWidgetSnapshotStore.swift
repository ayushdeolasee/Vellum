import Foundation

/// Reads and atomically replaces one known file in the App Group. In
/// particular, there is no directory enumeration for the widget to inherit.
struct VellumWidgetSnapshotStore: Sendable {
    static let appGroupIdentifier = "group.com.ayushdeolasee.vellum"
    static let filename = "widget-snapshot-v1.json"

    let fileURL: URL

    static func resolve() -> Self? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier)
        else { return nil }
        return Self(fileURL: container.appending(path: filename))
    }

    func load() -> VellumWidgetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? Self.decoder.decode(VellumWidgetSnapshot.self, from: data),
              snapshot.isValid
        else { return nil }
        return snapshot
    }

    @discardableResult
    func save(_ snapshot: VellumWidgetSnapshot) throws -> Bool {
        guard snapshot.isValid else { throw VellumWidgetSnapshotStoreError.invalidSnapshot }
        if let current = load(),
           current.recentDocuments == snapshot.recentDocuments,
           current.readLaterItems == snapshot.readLaterItems
        {
            return false
        }
        let data = try Self.encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        return true
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum VellumWidgetSnapshotStoreError: Error, Equatable {
    case invalidSnapshot
}
