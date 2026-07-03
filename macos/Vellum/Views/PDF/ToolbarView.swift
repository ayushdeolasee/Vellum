import SwiftUI

// STUB — replaced by the chrome module (see macos/specs/SPECS-app-shell.md and
// SPECS-pdf-viewing.md "Toolbar"). Signature frozen: ContentView passes the
// sidebar state; welcome screen renders it without the sidebar props.
struct ToolbarView: View {
    var sidebarOpen: Bool? = nil
    var onToggleSidebar: (() -> Void)? = nil

    var body: some View {
        Color.clear.frame(height: 44)
    }
}
