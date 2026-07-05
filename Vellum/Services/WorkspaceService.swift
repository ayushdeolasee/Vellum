import Foundation

// Disk model + persistence for the split-screen layout. The pane tree (shape,
// per-split ratios, each pane's tabs, active tab, focus) is encoded to JSON and
// stored in UserDefaults — the same idiom as RecentFilesService. Session ids are
// NOT persisted (they're ephemeral dictionary keys); documents are restored by
// path/URL with fresh sessions on the next launch.

/// One persisted tab. `document == nil` marks a start (new-tab) page. Transient
/// viewport data (numPages, visiblePages, web ranges) is intentionally dropped —
/// it's recomputed when the document reloads.
struct TabDescriptor: Codable, Equatable {
    var document: DocumentInfo?
    var currentPage: Int
    var zoom: Double
    var mode: InteractionMode

    enum CodingKeys: String, CodingKey {
        case document, currentPage = "current_page", zoom, mode
    }
}

/// Persisted pane tree, mirroring `PaneNode` without the live store references.
indirect enum PaneNodeDTO: Codable, Equatable {
    case leaf(tabs: [TabDescriptor], activeTabIndex: Int?)
    case split(direction: SplitDirection, children: [PaneNodeDTO], sizes: [Double])

    private enum Kind: String, Codable { case leaf, split }
    private enum CodingKeys: String, CodingKey {
        case kind, tabs, activeTabIndex = "active_tab_index", direction, children, sizes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .leaf:
            self = .leaf(
                tabs: try container.decode([TabDescriptor].self, forKey: .tabs),
                activeTabIndex: try container.decodeIfPresent(Int.self, forKey: .activeTabIndex))
        case .split:
            let direction = try container.decode(SplitDirection.self, forKey: .direction)
            let children = try container.decode([PaneNodeDTO].self, forKey: .children)
            let sizes = try container.decode([Double].self, forKey: .sizes)
            // Reject malformed splits so a hand-edited/corrupted blob resets to a
            // fresh workspace instead of crashing later (firstLeafId force-indexes
            // children[0]; SplitContainer indexes sizes against children).
            guard children.count >= 2, children.count == sizes.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .children, in: container,
                    debugDescription: "split node requires >= 2 children matching sizes.count")
            }
            self = .split(direction: direction, children: children, sizes: sizes)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let tabs, let activeTabIndex):
            try container.encode(Kind.leaf, forKey: .kind)
            try container.encode(tabs, forKey: .tabs)
            try container.encodeIfPresent(activeTabIndex, forKey: .activeTabIndex)
        case .split(let direction, let children, let sizes):
            try container.encode(Kind.split, forKey: .kind)
            try container.encode(direction, forKey: .direction)
            try container.encode(children, forKey: .children)
            try container.encode(sizes, forKey: .sizes)
        }
    }
}

struct WorkspaceState: Codable, Equatable {
    var root: PaneNodeDTO
    /// Index of the focused pane within the tree's leaves in traversal order.
    var focusedLeafIndex: Int

    enum CodingKeys: String, CodingKey {
        case root, focusedLeafIndex = "focused_leaf_index"
    }
}

enum WorkspaceService {
    private static let storageKey = "vellum.workspace"

    static func save(_ state: WorkspaceState) {
        guard let data = try? JSONEncoder().encode(state),
              let json = String(data: data, encoding: .utf8) else { return }
        UserDefaults.standard.set(json, forKey: storageKey)
    }

    static func load() -> WorkspaceState? {
        guard let json = UserDefaults.standard.string(forKey: storageKey),
              let data = json.data(using: .utf8),
              let state = try? JSONDecoder().decode(WorkspaceState.self, from: data) else {
            return nil
        }
        return state
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }
}
