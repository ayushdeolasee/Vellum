import SwiftUI

enum InspectorLayout {
    /// Below this width the inspector content becomes cramped enough to make the
    /// AI composer and annotation rows difficult to use.
    static let minimumWidth: CGFloat = 280
    static let idealWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 700

    /// Full titles fit comfortably at the default inspector width. At the
    /// minimum width, icons keep every destination visible without truncation.
    static let fullLabelsMinimumWidth: CGFloat = 320
    static let iconsMinimumWidth: CGFloat = 170

    enum Presentation: Equatable {
        case fullLabels
        case icons
        case menu
    }

    static func presentation(for width: CGFloat) -> Presentation {
        if width >= fullLabelsMinimumWidth { return .fullLabels }
        if width >= iconsMinimumWidth { return .icons }
        return .menu
    }
}

extension WorkspaceStore.SidebarTab: Identifiable {
    var id: Self { self }

    var title: String {
        switch self {
        case .annotations: "Annotations"
        case .ai: "AI"
        case .scratchpad: "Scratchpad"
        }
    }

    var systemImage: String {
        switch self {
        case .annotations: "highlighter"
        case .ai: "sparkles"
        case .scratchpad: "note.text"
        }
    }
}

/// Responsive navigation for the inspector's three persistent panels.
///
/// This intentionally lives inside the inspector instead of its window toolbar:
/// AppKit may collapse toolbar items into an overflow menu at narrow window
/// widths, and the synthesized overflow previously exposed only one section.
/// Keeping the control here guarantees that all destinations remain reachable.
struct InspectorTabSwitcher: View {
    @Binding var selection: WorkspaceStore.SidebarTab

    var body: some View {
        GeometryReader { proxy in
            switch InspectorLayout.presentation(for: proxy.size.width) {
            case .fullLabels:
                segmentedControl(showTitles: true)
            case .icons:
                segmentedControl(showTitles: false)
            case .menu:
                compactMenu
            }
        }
        .frame(height: 30)
        .accessibilityElement(children: .contain)
    }

    private func segmentedControl(showTitles: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(WorkspaceStore.SidebarTab.allCases) { tab in
                let isSelected = selection == tab
                Button {
                    withAnimation(.snappy) {
                        selection = tab
                    }
                } label: {
                    if showTitles {
                        Label(tab.title, systemImage: tab.systemImage)
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    } else {
                        Label(tab.title, systemImage: tab.systemImage)
                            .labelStyle(.iconOnly)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .background {
                    if isSelected {
                        Capsule()
                            .fill(.quaternary)
                            .overlay {
                                Capsule().strokeBorder(.separator, lineWidth: 1)
                            }
                    }
                }
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier("sidebarTab.\(tab.title)")
            }
        }
        .font(.callout)
        .padding(2)
        .background(.quaternary.opacity(0.35), in: Capsule())
    }

    private var compactMenu: some View {
        Menu {
            ForEach(WorkspaceStore.SidebarTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label {
                        Text(tab.title)
                    } icon: {
                        Image(systemName: selection == tab ? "checkmark" : tab.systemImage)
                    }
                }
                .accessibilityIdentifier("sidebarTab.\(tab.title)")
            }
        } label: {
            Label(selection.title, systemImage: selection.systemImage)
                .frame(maxWidth: .infinity)
        }
        .menuStyle(.borderlessButton)
        .accessibilityLabel("Inspector section")
        .accessibilityValue(selection.title)
        .accessibilityIdentifier("sidebarTab.menu")
    }
}
