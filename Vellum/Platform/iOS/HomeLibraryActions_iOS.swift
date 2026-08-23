#if os(iOS)
import SwiftUI

/// The "forget this / rename this" half of a Home screen, extracted so the iPad
/// library and the phone Home cannot diverge on it (#153 P4).
///
/// It is four things that have to agree with each other, which is why they are
/// one object rather than four pieces of view state:
///
///   * the rename sheet's subject;
///   * the destructive-removal confirmation (only `.saved` asks — see
///     `HomeSearchRemoval.requiresConfirmation`);
///   * the undo toast for the reversible one;
///   * the `UndoManager` registration that makes ⌘Z drive the *same*
///     transaction the toast does.
///
/// Ordering inside `perform(_:on:undoManager:)` is load-bearing and is the
/// reason this is not two separate call sites: the transaction is registered
/// synchronously, before the corpus reload, because `load()` is three disk walks
/// and a ⌘Z landing during it would pop whatever was on the undo stack
/// beforehand.
@MainActor
@Observable
final class HomeLibraryActions_iOS {
    /// The corpus these actions mutate. Held rather than passed per-call so the
    /// presentation modifier below needs only this one object.
    let store: HomeSearchStore

    /// The row whose rename sheet is open, if any.
    var renamingItem: HomeSearchItem?

    /// The removal waiting on its confirmation dialog, if any.
    private(set) var confirmingRemoval: PendingRemoval?

    /// Title for the confirmation, held separately and never cleared on
    /// dismissal: `confirmingRemoval` goes nil the instant the dialog starts
    /// closing, and reading it for the title (which is evaluated outside
    /// `presenting:`) would blank the heading mid-animation while the buttons
    /// and message still render.
    private(set) var confirmingTitle = ""

    /// The most recent undoable recents removal, shown as a toast.
    var undoableRemoval: HomeRecentRemovalTransaction?

    /// A destructive removal held back until the user confirms it. Carries the
    /// row as well as the action so the dialog can name what it is about to
    /// un-save.
    struct PendingRemoval {
        let item: HomeSearchItem
        let removal: HomeSearchRemoval
    }

    init(store: HomeSearchStore) {
        self.store = store
    }

    /// Context-menu actions are built here rather than inline in the row's
    /// argument list: a ternary between a closure literal and `nil` gives the
    /// type checker no way to resolve the closure's own body.
    func renameAction(for item: HomeSearchItem) -> (() -> Void)? {
        guard store.canRename(item) else { return nil }
        return { [weak self] in self?.renamingItem = item }
    }

    /// Every "forget this" action the row offers, already wired to either the
    /// confirmation dialog or the immediate path.
    ///
    /// `undoManager` is captured from the environment at build time because the
    /// closure fires from a context menu, where re-reading the environment is
    /// not possible.
    func removalActions(
        for item: HomeSearchItem,
        undoManager: UndoManager?
    ) -> [(removal: HomeSearchRemoval, action: () -> Void)] {
        store.removalOptions(for: item).map { removal in
            // The closure is annotated rather than inferred so the type checker
            // resolves its body independently of the surrounding `map`.
            let action: () -> Void = { [weak self] in
                guard let self else { return }
                // Issue #103: neither removal used to stop for anything. The
                // irreversible one now asks; the reversible one still fires on
                // the tap and offers undo (see `perform`).
                if removal.requiresConfirmation {
                    confirmingTitle = removal.confirmationTitle(for: item.title)
                    confirmingRemoval = PendingRemoval(item: item, removal: removal)
                } else {
                    perform(removal, on: item, undoManager: undoManager)
                }
            }
            return (removal, action)
        }
    }

    /// Dismissal of the confirmation dialog, whether by Cancel or by the
    /// destructive button.
    func clearConfirmation() {
        confirmingRemoval = nil
    }

    /// Do the removal and, when it produced something undoable, put it on the
    /// undo stack and raise the toast.
    func perform(
        _ removal: HomeSearchRemoval,
        on item: HomeSearchItem,
        undoManager: UndoManager?
    ) {
        switch removal {
        case .recent:
            // Registered synchronously, before the reload: `load()` rebuilds the
            // whole corpus, and a ⌘Z landing during it would pop whatever was on
            // the stack beforehand instead of this removal.
            let transaction = store.removeFromRecent(item)
            if let transaction {
                // SwiftUI only supplies `\.undoManager` where the environment
                // supports it; without one the removal simply stands. The toast
                // is offered either way.
                if let undoManager {
                    registerRecentRemovalUndo(transaction, store: store, undoManager: undoManager)
                }
                withAnimation { undoableRemoval = transaction }
            }
            Task { await store.load() }
        case .saved:
            Task { await store.removeFromSaved(item) }
        }
    }

    /// The toast's Undo button. Returns without clearing the toast when the
    /// removal has been overtaken (the document was re-opened), so the row the
    /// user is looking at is not silently duplicated.
    func undoRemoval(_ transaction: HomeRecentRemovalTransaction) {
        guard store.undoRecentRemoval(transaction) else { return }
        undoableRemoval = nil
        Task { await store.load() }
    }

    /// Drop this screen's undo registrations.
    ///
    /// `registerUndo(withTarget:)` does NOT retain its target, and the screens
    /// own `store` as `@State` — opening a document swaps the whole view out and
    /// deallocates it. Leaving the registration in place would leave a dead
    /// target on the undo stack, and an "Undo Remove from Recent" entry in a
    /// reader that has no recents list on screen. The undo's session is the
    /// screen's lifetime, so it leaves with it.
    func releaseUndoRegistrations(_ undoManager: UndoManager?) {
        undoManager?.removeAllActions(withTarget: store)
    }
}

// MARK: - Presentation

extension View {
    /// Mounts the rename sheet, the removal confirmation and the undo toast for
    /// a Home screen.
    ///
    /// - Parameter toastAlignment: where the undo toast sits. The iPad library
    ///   keeps it bottom-trailing under a wide column; the phone centres it,
    ///   because at 390pt a trailing toast reads as clipped rather than as
    ///   floating.
    func homeLibraryPresentations(
        _ actions: HomeLibraryActions_iOS,
        toastAlignment: Alignment = .bottomTrailing
    ) -> some View {
        modifier(HomeLibraryPresentations_iOS(actions: actions, toastAlignment: toastAlignment))
    }
}

private struct HomeLibraryPresentations_iOS: ViewModifier {
    let actions: HomeLibraryActions_iOS
    let toastAlignment: Alignment

    @Environment(\.palette) private var palette
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        @Bindable var actions = actions
        return content
            .overlay(alignment: toastAlignment) { undoToast }
            .onDisappear { actions.releaseUndoRegistrations(undoManager) }
            .sheet(item: $actions.renamingItem) { item in
                RenameDocumentSheet_iOS(
                    currentTitle: item.title,
                    // `subtitle` is the filename for a PDF and host+path for a
                    // page — exactly what the row falls back to with no override.
                    fallbackName: item.subtitle,
                    commit: { newTitle in
                        Task { await actions.store.rename(item, to: newTitle) }
                    })
            }
            .confirmationDialog(
                Text(actions.confirmingTitle),
                isPresented: Binding(
                    get: { actions.confirmingRemoval != nil },
                    set: { if !$0 { actions.clearConfirmation() } }),
                titleVisibility: .visible,
                presenting: actions.confirmingRemoval
            ) { pending in
                Button(pending.removal.confirmLabel, role: .destructive) {
                    actions.perform(pending.removal, on: pending.item, undoManager: undoManager)
                }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                if let message = pending.removal.confirmationMessage {
                    Text(message)
                }
            }
    }

    /// iOS has no Edit ▸ Undo without a hardware keyboard, so the undo the store
    /// registers would be reachable only by shake-to-undo or ⌘Z. This toast is
    /// the primary affordance; the `UndoManager` registration in `perform` stays,
    /// so both routes drive the same transaction.
    @ViewBuilder
    private var undoToast: some View {
        if let transaction = actions.undoableRemoval {
            HStack(spacing: 12) {
                Text("Removed from Recent")
                    .font(.system(size: 13))
                    .foregroundStyle(palette.foreground)
                Button("Undo") {
                    actions.undoRemoval(transaction)
                }
                .font(.system(size: 13, weight: .semibold))
                .accessibilityIdentifier("welcome.undoRemoval")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(palette.border)
            }
            .shadow(radius: 8, y: 2)
            .padding(20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityIdentifier("welcome.removalToast")
            .task(id: transaction) {
                try? await Task.sleep(for: .seconds(6))
                guard !Task.isCancelled else { return }
                withAnimation { actions.undoableRemoval = nil }
            }
        }
    }
}

// MARK: - Session undo

// Each step registers its counterpart, so ⌘Z / ⇧⌘Z alternate for as long as the
// screen lives. A step that reports `false` — the entry came back, or was never
// there — ends the chain rather than registering a counterpart that would
// silently do nothing.

@MainActor
private func registerRecentRemovalUndo(
    _ transaction: HomeRecentRemovalTransaction,
    store: HomeSearchStore,
    undoManager: UndoManager
) {
    undoManager.registerUndo(withTarget: store) { target in
        guard target.undoRecentRemoval(transaction) else { return }
        registerRecentRemovalRedo(transaction, store: target, undoManager: undoManager)
    }
    undoManager.setActionName("Remove from Recent")
}

@MainActor
private func registerRecentRemovalRedo(
    _ transaction: HomeRecentRemovalTransaction,
    store: HomeSearchStore,
    undoManager: UndoManager
) {
    undoManager.registerUndo(withTarget: store) { target in
        guard target.redoRecentRemoval(transaction) else { return }
        registerRecentRemovalUndo(transaction, store: target, undoManager: undoManager)
    }
    undoManager.setActionName("Remove from Recent")
}
#endif
