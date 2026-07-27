import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all
    case pdf
    case web
    case saved

    var id: Self { self }

    var label: String {
        switch self {
        case .all: "All"
        case .pdf: "PDFs"
        case .web: "Web"
        case .saved: "Saved"
        }
    }
}

enum LibrarySort: String, CaseIterable {
    case recent
    case name

    var label: String {
        switch self {
        case .recent: "Recently opened"
        case .name: "Name"
        }
    }
}

enum LibraryRemovalTarget: Equatable {
    case recent
    case saved
}

struct LibraryItem: Identifiable, Hashable {
    let id: String
    let kind: DocumentKind
    let key: String
    let recordedRecentKey: String?
    let savedKey: String?
    let icon: String
    let title: String
    let subtitle: String
    let tooltip: String
    let canRevealInFinder: Bool
    let isSaved: Bool
    let isOffline: Bool
    fileprivate let recency: Date?
    fileprivate let sourceOrder: Int
    fileprivate let searchText: String
}

enum LibraryCatalog {
    static func removalTarget(
        for item: LibraryItem,
        activeFilter: LibraryFilter
    ) -> LibraryRemovalTarget? {
        if activeFilter == .saved, item.savedKey != nil {
            return .saved
        }
        if item.recordedRecentKey != nil {
            return .recent
        }
        if item.savedKey != nil {
            return .saved
        }
        return nil
    }

    static func items(
        recent: [RecentDocument],
        saved: [WebLibraryEntry],
        query: String,
        filter: LibraryFilter,
        sort: LibrarySort
    ) -> [LibraryItem] {
        let allItems = mergedItems(recent: recent, saved: saved)
        let terms = query
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)

        let filtered = allItems.filter { item in
            let includedByFilter = switch filter {
            case .all: true
            case .pdf: item.kind == .pdf
            case .web: item.kind == .web
            case .saved: item.isSaved
            }
            guard includedByFilter else { return false }
            guard terms.isEmpty == false else { return true }
            let searchable = item.searchText.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return terms.allSatisfy(searchable.contains)
        }

        switch sort {
        case .recent:
            return filtered.sorted {
                switch ($0.recency, $1.recency) {
                case let (left?, right?) where left != right:
                    return left > right
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                default:
                    return $0.sourceOrder < $1.sourceOrder
                }
            }
        case .name:
            return filtered.sorted {
                $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
    }

    private static func mergedItems(
        recent: [RecentDocument],
        saved: [WebLibraryEntry]
    ) -> [LibraryItem] {
        var savedByURL: [String: WebLibraryEntry] = [:]
        for page in saved {
            savedByURL[normalizedURL(page.url)] = page
        }

        var items: [LibraryItem] = []
        var representedSavedURLs = Set<String>()
        var representedRecentURLs = Set<String>()

        for (index, entry) in recent.enumerated() {
            if entry.kind == .web {
                let normalized = normalizedURL(entry.pdfPath)
                guard representedRecentURLs.insert(normalized).inserted else { continue }
                let savedPage = savedByURL[normalized]
                if savedPage != nil {
                    representedSavedURLs.insert(normalized)
                }
                items.append(webItem(recent: entry, saved: savedPage, sourceOrder: index))
            } else {
                items.append(pdfItem(entry, sourceOrder: index))
            }
        }

        for (index, page) in saved.enumerated() {
            let normalized = normalizedURL(page.url)
            guard representedSavedURLs.contains(normalized) == false else { continue }
            items.append(webItem(
                recent: nil,
                saved: page,
                sourceOrder: recent.count + index
            ))
        }
        return items
    }

    private static func pdfItem(_ entry: RecentDocument, sourceOrder: Int) -> LibraryItem {
        let fileName = RecentFilesService.fileName(for: entry.pdfPath)
        let title = displayTitle(entry.title, fallback: fileName)
        var details: [String] = []
        if title != fileName {
            details.append(fileName)
        }
        if let count = entry.pageCount, count > 0 {
            details.append("\(count) \(count == 1 ? "page" : "pages")")
        }
        details.append(formatOpenedDate(entry.openedAt))

        let resolvedPath = RecentFilesService.resolvedPath(for: entry)
        let onDisk = FileManager.default.fileExists(atPath: resolvedPath)
        let searchText = [title, fileName, entry.pdfPath, resolvedPath, details.joined(separator: " ")]
            .joined(separator: "\n")

        return LibraryItem(
            // A moved stamped PDF can temporarily have two recent records with
            // the same docId. Keep each visible row's identity path-specific.
            id: "pdf:\(entry.pdfPath)",
            kind: .pdf,
            key: resolvedPath,
            recordedRecentKey: entry.pdfPath,
            savedKey: nil,
            icon: "doc.text",
            title: title,
            subtitle: details.joined(separator: " · "),
            tooltip: resolvedPath,
            canRevealInFinder: onDisk,
            isSaved: false,
            isOffline: false,
            recency: parseDate(entry.openedAt),
            sourceOrder: sourceOrder,
            searchText: searchText
        )
    }

    private static func webItem(
        recent: RecentDocument?,
        saved: WebLibraryEntry?,
        sourceOrder: Int
    ) -> LibraryItem {
        let url = recent?.pdfPath ?? saved?.url ?? ""
        let displayName = RecentFilesService.webpageDisplayName(for: url)
        let title = displayTitle(
            nonemptyTitle(recent?.title) ?? nonemptyTitle(saved?.title),
            fallback: displayName
        )
        let host = URL(string: url)?.host ?? ""
        var details = [displayName]
        if let openedAt = recent?.openedAt {
            details.append(formatOpenedDate(openedAt))
        }
        let searchText = [
            title,
            recent?.title ?? "",
            saved?.title ?? "",
            displayName,
            host,
            url,
            saved?.url ?? "",
            details.joined(separator: " ")
        ]
            .joined(separator: "\n")

        return LibraryItem(
            id: "web:\(normalizedURL(url))",
            kind: .web,
            key: url,
            recordedRecentKey: recent?.pdfPath,
            savedKey: saved?.url,
            icon: "globe",
            title: title,
            subtitle: details.joined(separator: " · "),
            tooltip: url,
            canRevealInFinder: false,
            isSaved: saved != nil,
            isOffline: saved?.hasSnapshot == true,
            recency: recent.flatMap { parseDate($0.openedAt) }
                ?? saved.flatMap { page in page.savedAt.flatMap(parseDate) },
            sourceOrder: sourceOrder,
            searchText: searchText
        )
    }

    private static func displayTitle(_ title: String?, fallback: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func nonemptyTitle(_ title: String?) -> String? {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value.lowercased() }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        } else if components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        return components.string ?? value.lowercased()
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatOpenedDate(_ openedAt: String) -> String {
        guard let date = parseDate(openedAt) else { return "Recently opened" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}
