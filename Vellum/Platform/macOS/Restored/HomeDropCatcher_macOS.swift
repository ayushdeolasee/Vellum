#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Click-through native destination so dropping over Home's search field also
/// opens the item instead of inserting its path or message into the field.
struct HomeDropCatcher: NSViewRepresentable {
    var enabled: Bool
    var onTargeted: (Bool) -> Void
    var onDrop: ([NSItemProvider]) -> Bool

    func makeNSView(context: Context) -> HomeDropView { HomeDropView() }

    func updateNSView(_ view: HomeDropView, context: Context) {
        view.onTargeted = onTargeted
        view.onDrop = onDrop
        if enabled { view.registerForDraggedTypes(HomeDropView.types) }
        else { view.unregisterDraggedTypes() }
    }
}

final class HomeDropView: NSView {
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .URL, .string, .rtf, .html]
    var onTargeted: (Bool) -> Void = { _ in }
    var onDrop: ([NSItemProvider]) -> Bool = { _ in false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let superview, superview.subviews.last !== self else { return }
        superview.addSubview(self, positioned: .above, relativeTo: nil)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let accepts = sender.draggingPasteboard.availableType(from: Self.types) != nil
        onTargeted(accepts)
        return accepts ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { draggingEntered(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onTargeted(false) }
    override func draggingEnded(_ sender: NSDraggingInfo) { onTargeted(false) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        onTargeted(false)
        return onDrop(Self.providers(from: sender.draggingPasteboard))
    }

    static func providers(from pasteboard: NSPasteboard) -> [NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).map { item in
            let provider = NSItemProvider()
            for type in Self.types where item.types.contains(type) {
                guard let data = item.data(forType: type) else { continue }
                let identifier = type == .string ? UTType.plainText.identifier : type.rawValue
                provider.registerDataRepresentation(forTypeIdentifier: identifier, visibility: .all) { completion in
                    completion(data, nil)
                    return nil
                }
            }
            return provider
        }
    }
}
#endif
