#if os(iOS)
import SwiftUI
import UIKit

/// SwiftUI's onDrop does not override UITextField's built-in text insertion.
/// Keep the native field (focus, keyboard, selection) and take over only drops.
struct HomeTextDropHandler: UIViewRepresentable {
    @Environment(AppStore.self) private var app
    @Environment(WorkspaceStore.self) private var workspace
    var onOpened: () -> Void = {}

    func makeUIView(context: Context) -> HomeTextDropView { HomeTextDropView() }

    func updateUIView(_ view: HomeTextDropView, context: Context) {
        view.receive = { providers in
            guard workspace.draggingTab == nil else { return }
            let accepted = providers.filter(HomeDrop.accepts)
            guard !accepted.isEmpty else { return }
            workspace.openHomeDrop(accepted, in: app, onOpened: onOpened)
        }
        view.install()
    }

    static func dismantleUIView(_ view: HomeTextDropView, coordinator: ()) { view.uninstall() }
}

final class HomeTextDropView: UIView, UITextDropDelegate {
    var receive: ([NSItemProvider]) -> Void = { _ in }
    private weak var field: UITextField?
    private weak var previousDelegate: (any UITextDropDelegate)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { uninstall() }
        else { DispatchQueue.main.async { [weak self] in self?.install() } }
    }

    func install() {
        guard window != nil else { return }
        var ancestor = superview
        while let container = ancestor {
            if let candidate = Self.textField(in: container) {
                guard candidate.textDropDelegate !== self else { return }
                uninstall()
                field = candidate
                previousDelegate = candidate.textDropDelegate
                candidate.textDropDelegate = self
                return
            }
            ancestor = container.superview
        }
    }

    func uninstall() {
        if field?.textDropDelegate === self { field?.textDropDelegate = previousDelegate }
        field = nil
        previousDelegate = nil
    }

    private static func textField(in view: UIView) -> UITextField? {
        if let field = view as? UITextField { return field }
        return view.subviews.lazy.compactMap { textField(in: $0) }.first
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                          proposalForDrop drop: any UITextDropRequest) -> UITextDropProposal {
        let accepts = drop.dropSession.items.contains { HomeDrop.accepts($0.itemProvider) }
        let proposal = UITextDropProposal(operation: accepts ? .copy : .cancel)
        proposal.dropPerformer = .delegate
        proposal.useFastSameViewOperations = false
        return proposal
    }

    func textDroppableView(_ textDroppableView: UIView & UITextDroppable,
                          willPerformDrop drop: any UITextDropRequest) {
        receive(drop.dropSession.items.map(\.itemProvider))
    }
}

extension View {
    func homeTextDrop(onOpened: @escaping () -> Void = {}) -> some View {
        background(HomeTextDropHandler(onOpened: onOpened).frame(width: 0, height: 0))
    }
}
#endif
