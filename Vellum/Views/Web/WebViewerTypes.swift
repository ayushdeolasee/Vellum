import Foundation
import SwiftUI

// Shared state types for the web-viewer annotation UI, used by both the
// macOS controller (WebViewerView.swift) and the iOS controller
// (Platform/iOS/WebViewerView_iOS.swift). Kept unconditional (no #if
// os(macOS) gate) so both platforms compile against the same definitions.

extension Notification.Name {
    /// Ask the active web viewer to run history.go(delta) inside the page
    /// (window.__webHistory in the original). userInfo: ["delta": Int].
    static let vellumWebHistory = Notification.Name("vellum.web-history")
}

/// Text-quote anchor for a note placed at a point in the page.
struct WebNoteAnchor {
    var start: Int
    var end: Int
    var text: String
    var prefix: String?
    var suffix: String?
    var pageNumber: Int
}

struct WebSelection {
    var text: String
    var pageNumber: Int
    var positionData: PositionData
}

struct WebNoteComposerState {
    var point: CGPoint
    var anchor: WebNoteAnchor
    var openedAt: Date
}

struct WebContextMenuState {
    var point: CGPoint
    var anchor: WebNoteAnchor?
    var openedAt: Date
}

struct WebNoteViewerState {
    var id: String
    var point: CGPoint
    var openedAt: Date
}

struct WebHighlightEditorState {
    var id: String
    var point: CGPoint
    var openedAt: Date
}
