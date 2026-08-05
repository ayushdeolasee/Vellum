import Foundation

/// One merged position entry that Home can actually open on this device.
///
/// Position files deliberately carry only a stable document key, not a path:
/// paths are device-local and putting one device's path in shared state would
/// make it look openable on every peer. Home therefore joins the merged
/// position view to its local search corpus before presenting a row.
struct ContinueReadingItem: Identifiable, Hashable, Sendable {
    let resume: ResumeEntry
    let document: HomeSearchItem

    var id: String { resume.key.rawValue }

    var title: String {
        let resumed = resume.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return resumed.isEmpty ? document.title : resumed
    }

    var progressLabel: String {
        guard let position = resume.position else { return "" }
        if let pageCount = position.pageCount, pageCount > 0 {
            return "Page \(position.page) of \(pageCount)"
        }
        if document.kind == .web, let fraction = position.scrollFraction {
            let percent = Int((min(1, max(0, fraction)) * 100).rounded())
            return "\(percent)% read"
        }
        return position.page > 1 ? "Page \(position.page)" : ""
    }

    var deviceLabel: String? {
        if let open = resume.openElsewhere.first {
            return "Open on \(open.name)"
        }
        guard let lastOpened = resume.lastOpenedOn else { return nil }
        return "From \(lastOpened.name)"
    }
}

/// Joins cross-device recents to documents that this installation can open.
///
/// A PDF can legitimately have more than one candidate key while it adopts a
/// stamped document id: its old path hash, its canonical storage-folder key,
/// and the hash of a stamped id. Checking all three is what lets a position
/// written before or after that transition resolve to the same Home item.
enum ContinueReadingResolver {
    static func resolve(
        _ recents: [ResumeEntry],
        in library: [HomeSearchItem],
        limit: Int = 3
    ) -> [ContinueReadingItem] {
        guard limit > 0 else { return [] }

        var documentsByKey: [DocumentKey: HomeSearchItem] = [:]
        for document in library
        where document.kind == .web || document.canRevealInFinder {
            for key in candidateKeys(for: document) where documentsByKey[key] == nil {
                documentsByKey[key] = document
            }
        }

        var seenDocuments: Set<String> = []
        var result: [ContinueReadingItem] = []
        for resume in recents {
            guard let document = documentsByKey[resume.key],
                  seenDocuments.insert(document.identity).inserted
            else { continue }
            result.append(ContinueReadingItem(resume: resume, document: document))
            if result.count == limit { break }
        }
        return result
    }

    private static func candidateKeys(for document: HomeSearchItem) -> Set<DocumentKey> {
        switch document.kind {
        case .web:
            var keys: Set<DocumentKey> = [
                DocumentPositionService.webKey(for: document.target.openKey)
            ]
            if let storageKey = document.storageKey,
               let key = DocumentKey(rawValue: "web:\(storageKey)") {
                keys.insert(key)
            }
            return keys

        case .pdf:
            var keys: Set<DocumentKey> = [.pdfPath(document.target.openKey)]
            if let storageKey = document.storageKey, !storageKey.isEmpty {
                // A canonical 64-character storage key may be a path/content
                // hash already; a UUID or content id is hashed by the position
                // store. Include both forms because the storage folder does not
                // encode which kind produced its name.
                if let alreadyHashed = DocumentKey(rawValue: "pdf:\(storageKey)") {
                    keys.insert(alreadyHashed)
                }
                keys.insert(.pdf(stableIdentifier: storageKey))
            }
            return keys
        }
    }
}
