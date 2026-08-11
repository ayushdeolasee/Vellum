import SwiftUI
import UniformTypeIdentifiers

// Drag-and-drop plumbing for tabs. Dragging a tab carries a small payload
// identifying its source pane + tab; dropping onto a pane either moves the tab
// into that group (center) or splits the pane along an edge, carrying the tab
// into a new pane. Zones are computed live from the pointer so drop targets can
// highlight during the drag (via a DropDelegate, which reports live location).

extension UTType {
    static let vellumTab = UTType(exportedAs: "com.vellum.tab")
}

struct TabDragPayload: Codable {
    var paneId: String
    var tabId: String
}

/// Which region of a pane the pointer is over during a drag.
enum DropZone: Equatable {
    case center, left, right, top, bottom

    /// Edge band thickness as a fraction of the pane; inside it → split, else center.
    private static let edge = 0.25

    static func at(_ location: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let fx = location.x / size.width
        let fy = location.y / size.height
        let left = fx, right = 1 - fx, top = fy, bottom = 1 - fy
        let nearest = min(left, right, top, bottom)
        if nearest >= edge { return .center }
        if nearest == left { return .left }
        if nearest == right { return .right }
        if nearest == top { return .top }
        return .bottom
    }
}

/// Receives tab drops on a pane. Tracks the hovered zone for highlighting and
/// performs the move/split on drop. SwiftUI invokes DropDelegate callbacks on the
/// main thread; `assumeIsolated` bridges that to the main-actor stores.
struct PaneDropDelegate: DropDelegate {
    let paneId: String
    let size: CGSize
    let workspace: WorkspaceStore
    @Binding var activeZone: DropZone?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.vellumTab])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            activeZone = DropZone.at(info.location, in: size)
            noteDragActivity()
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        MainActor.assumeIsolated {
            activeZone = DropZone.at(info.location, in: size)
            noteDragActivity()
        }
        return DropProposal(operation: .move)
    }

    /// On iOS the workspace's drag watchdog needs periodic proof the drag is
    /// still alive (macOS polls the mouse button instead).
    @MainActor
    private func noteDragActivity() {
        #if os(iOS)
        workspace.noteDragActivity()
        #endif
    }

    func dropExited(info: DropInfo) {
        MainActor.assumeIsolated { activeZone = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = DropZone.at(info.location, in: size)
        MainActor.assumeIsolated { activeZone = nil }
        guard let provider = info.itemProviders(for: [.vellumTab]).first else { return false }
        let target = paneId
        let workspace = self.workspace
        _ = provider.loadDataRepresentation(for: .vellumTab) { data, _ in
            guard let data,
                  let payload = try? JSONDecoder().decode(TabDragPayload.self, from: data) else { return }
            Task { @MainActor in
                Self.apply(payload, zone: zone, target: target, workspace: workspace)
            }
        }
        return true
    }

    @MainActor
    private static func apply(_ payload: TabDragPayload, zone: DropZone, target: String, workspace: WorkspaceStore) {
        defer { workspace.endTabDrag() }
        switch zone {
        case .center:
            workspace.moveTab(tabId: payload.tabId, from: payload.paneId, to: target)
        case .left:
            workspace.splitWithTab(tabId: payload.tabId, from: payload.paneId, target: target, direction: .horizontal, before: true)
        case .right:
            workspace.splitWithTab(tabId: payload.tabId, from: payload.paneId, target: target, direction: .horizontal, before: false)
        case .top:
            workspace.splitWithTab(tabId: payload.tabId, from: payload.paneId, target: target, direction: .vertical, before: true)
        case .bottom:
            workspace.splitWithTab(tabId: payload.tabId, from: payload.paneId, target: target, direction: .vertical, before: false)
        }
    }
}

/// The translucent overlay that previews where a dropped tab will land.
struct DropZoneOverlay: View {
    let zone: DropZone?
    let palette: ThemePalette

    var body: some View {
        GeometryReader { geo in
            if let zone {
                let rect = frame(for: zone, in: geo.size)
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(palette.primary.opacity(0.20))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.md)
                            .strokeBorder(palette.primary.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .overlay(alignment: .center) {
                        Text(zone == .center ? "Move here" : "New split")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(palette.primaryForeground)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(palette.primary))
                            .position(x: rect.midX, y: rect.midY)
                    }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: zone)
    }

    private func frame(for zone: DropZone, in size: CGSize) -> CGRect {
        let inset: CGFloat = size.width * 0.16
        switch zone {
        case .center:
            return CGRect(x: inset, y: inset, width: size.width - inset * 2, height: size.height - inset * 2)
        case .left:
            return CGRect(x: 0, y: 0, width: size.width / 2, height: size.height)
        case .right:
            return CGRect(x: size.width / 2, y: 0, width: size.width / 2, height: size.height)
        case .top:
            return CGRect(x: 0, y: 0, width: size.width, height: size.height / 2)
        case .bottom:
            return CGRect(x: 0, y: size.height / 2, width: size.width, height: size.height / 2)
        }
    }
}
