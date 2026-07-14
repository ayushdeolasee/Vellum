import SwiftUI

// Recursively renders the pane tree. A leaf becomes a PaneView; a split becomes
// a row/column of children separated by draggable dividers that rewrite the
// split's free-form size ratios in the WorkspaceStore.

struct PaneTreeView: View {
    let node: PaneNode

    var body: some View {
        switch node {
        case .leaf(let pane):
            PaneView(pane: pane)
        case .split(let id, let direction, let children, let sizes):
            SplitContainer(id: id, direction: direction, children: children, sizes: sizes)
        }
    }
}

private struct SplitContainer: View {
    let id: String
    let direction: SplitDirection
    let children: [PaneNode]
    let sizes: [Double]

    @Environment(WorkspaceStore.self) private var workspace
    @State private var dragBaseline: [Double]?

    private let dividerThickness: CGFloat = 8
    private let minPane: CGFloat = 240

    var body: some View {
        GeometryReader { geo in
            let axisLength = direction == .horizontal ? geo.size.width : geo.size.height
            let available = max(1, axisLength - dividerThickness * CGFloat(max(0, children.count - 1)))
            let total = sizes.reduce(0, +)
            let lengths = sizes.map { CGFloat($0 / (total <= 0 ? 1 : total)) * available }

            stack {
                ForEach(Array(children.enumerated()), id: \.element.id) { index, child in
                    PaneTreeView(node: child)
                        .frame(
                            width: direction == .horizontal ? lengths[index] : nil,
                            height: direction == .vertical ? lengths[index] : nil)

                    if index < children.count - 1 {
                        PaneDivider(direction: direction)
                            .gesture(dividerGesture(index: index, available: available))
                            .onTapGesture(count: 2) { resetPair(around: index) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func stack<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if direction == .horizontal {
            HStack(spacing: 0) { content() }
        } else {
            VStack(spacing: 0) { content() }
        }
    }

    private func dividerGesture(index: Int, available: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let baseline = dragBaseline ?? sizes
                if dragBaseline == nil { dragBaseline = sizes }
                guard available > 0, baseline.indices.contains(index + 1) else { return }
                let sum = baseline.reduce(0, +)
                let translation = direction == .horizontal ? value.translation.width : value.translation.height
                let deltaPct = Double(translation / available) * sum
                let pairSum = baseline[index] + baseline[index + 1]
                let minPct = Double(minPane / available) * sum
                var first = baseline[index] + deltaPct
                var second = baseline[index + 1] - deltaPct
                if first < minPct { first = minPct; second = pairSum - minPct }
                if second < minPct { second = minPct; first = pairSum - minPct }
                var next = baseline
                next[index] = first
                next[index + 1] = second
                workspace.setSizes(splitId: id, sizes: next)
            }
            .onEnded { _ in dragBaseline = nil }
    }

    private func resetPair(around index: Int) {
        guard sizes.indices.contains(index + 1) else { return }
        let pairSum = sizes[index] + sizes[index + 1]
        var next = sizes
        next[index] = pairSum / 2
        next[index + 1] = pairSum / 2
        workspace.setSizes(splitId: id, sizes: next)
    }
}

/// The draggable seam between two panes: a slim hit target with a hairline that
/// warms to the accent on hover. The drag/double-click gestures are attached by
/// the SplitContainer, which owns the geometry.
private struct PaneDivider: View {
    let direction: SplitDirection

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(hovering ? palette.primary : palette.border)
                .frame(
                    width: direction == .horizontal ? 2 : nil,
                    height: direction == .vertical ? 2 : nil)
        }
        .frame(
            width: direction == .horizontal ? 8 : nil,
            height: direction == .vertical ? 8 : nil)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .pointerStyle(direction == .horizontal ? .columnResize : .rowResize)
    }
}
