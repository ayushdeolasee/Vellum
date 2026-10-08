#if os(iOS)
import SwiftUI
import UIKit

/// A value snapshot: lookup never rereads another tab's live selection.
struct DictionarySelection_iOS: Identifiable {
    let id = UUID()
    let term: String

    init?(_ selection: String) {
        let text = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        term = text
    }
}

/// Hosted by the reader, rather than its transient selection popover.
struct DictionarySheet_iOS: UIViewControllerRepresentable {
    let term: String

    func makeUIViewController(context: Context) -> UIReferenceLibraryViewController {
        UIReferenceLibraryViewController(term: term)
    }

    func updateUIViewController(_ controller: UIReferenceLibraryViewController, context: Context) {}
}
#endif
