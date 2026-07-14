import Foundation

// The split-screen layout model. A window shows a recursive tree of panes; each
// leaf is an independent tab group backed by its own store-triple (AppStore +
// AnnotationStore + AiStore), all sharing the one SessionService. Splits nest
// arbitrarily and carry free-form size ratios. See plans/split-screen-design.html.

enum SplitDirection: String, Codable, Sendable {
    case horizontal   // children laid out left→right
    case vertical     // children laid out top→bottom
}

/// One leaf pane: owns the per-pane document/viewport store and the annotation +
/// AI stores scoped to it. The viewers/overlays/toolbar consume these via
/// `@Environment`, so a pane just injects its own triple into its subtree.
@MainActor
final class PaneModel: Identifiable {
    let id: String
    let app: AppStore
    let annotations: AnnotationStore
    let ai: AiStore

    init(
        id: String = "pane-" + UUID().uuidString.lowercased(),
        sessions: SessionService,
        openRouterCatalog: OpenRouterCatalog,
        chatgptAuth: ChatGPTAuth
    ) {
        self.id = id
        let app = AppStore(sessions: sessions)
        let annotations = AnnotationStore(app: app)
        let ai = AiStore()
        ai.app = app
        ai.annotationStore = annotations
        ai.openRouterCatalog = openRouterCatalog
        ai.chatgptAuth = chatgptAuth
        self.app = app
        self.annotations = annotations
        self.ai = ai
    }
}

/// The pane tree: a leaf, or a split of two-or-more children with per-child size
/// weights. Value type (the leaves hold reference-type `PaneModel`s), so the
/// `WorkspaceStore` mutates layout by producing a new tree, which drives updates.
@MainActor
indirect enum PaneNode: Identifiable {
    case leaf(PaneModel)
    case split(id: String, direction: SplitDirection, children: [PaneNode], sizes: [Double])

    nonisolated var id: String {
        switch self {
        case .leaf(let pane): return pane.id
        case .split(let id, _, _, _): return id
        }
    }

    /// The `PaneModel` for `id`, searched depth-first, or nil.
    func leaf(id: String) -> PaneModel? {
        switch self {
        case .leaf(let pane):
            return pane.id == id ? pane : nil
        case .split(_, _, let children, _):
            for child in children {
                if let hit = child.leaf(id: id) { return hit }
            }
            return nil
        }
    }

    /// Id of the first leaf in tree order — the fallback when focus is lost.
    var firstLeafId: String {
        switch self {
        case .leaf(let pane): return pane.id
        case .split(_, _, let children, _): return children[0].firstLeafId
        }
    }

    /// Every leaf in tree order (left→right / top→bottom).
    func allLeaves() -> [PaneModel] {
        switch self {
        case .leaf(let pane): return [pane]
        case .split(_, _, let children, _): return children.flatMap { $0.allLeaves() }
        }
    }

    var isLeaf: Bool {
        if case .leaf = self { return true }
        return false
    }
}
