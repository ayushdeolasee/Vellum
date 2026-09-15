#if os(iOS)
import SwiftUI

/// Floating Liquid Glass ink palette: tool (pen / highlighter / eraser), color,
/// width, undo, clear, and Done. Sits at the bottom so it never covers the top
/// of the page being annotated.
struct InkToolPalette_iOS: View {
    var host: any InkPaletteHost
    private var state: InkToolState { host.toolState }
    var onDone: () -> Void = {}

    @Environment(\.palette) private var palette

    /// The width-slot dot currently showing its size popover (full variant).
    @State private var openSlot: Int?
    /// Whether the compact cycle dot's size popover is showing.
    @State private var showCompactPopover = false

    private var colors: [Color] {
        switch state.tool {
        case .highlighter, .textHighlight: InkPalette.highlighterColors
        case .pen, .eraser: InkPalette.penColors
        }
    }

    var body: some View {
        if state.tool == .textHighlight {
            HStack(spacing: 8) {
                Label("Select text", systemImage: "character.cursor.ibeam")
                    .font(.system(size: 15, weight: .medium))
                actionRow
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
            .accessibilityHint("Drag the Apple Pencil across text, then choose Highlight, Note, or Ask AI.")
        } else {
            ViewThatFits(in: .horizontal) {
                paletteRow(compact: false)
                paletteRow(compact: true)
            }
        }
    }

    private func paletteRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            toolGroup
            if state.tool != .eraser {
                divider
                colorRow(compact: compact)
            }
            if state.tool != .textHighlight {
                divider
                if compact {
                    widthCycleButton
                } else {
                    widthRow
                }
            }
            if state.tool == .eraser {
                divider
                eraserModeRow(compact: compact)
            }
            divider
            actionRow
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, 6)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// Compact width control: one dot showing the current size; tap cycles
    /// through the slots, long-press opens the size popover for the current
    /// slot.
    private var widthCycleButton: some View {
        Button {
            state.cycleWidthSlot()
        } label: {
            Circle()
                .fill(palette.foreground)
                .frame(width: dotSize(state.activeWidth), height: dotSize(state.activeWidth))
                .frame(width: 34, height: 34)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stroke width — tap to cycle, touch and hold to adjust")
        .onLongPressGesture {
            showCompactPopover = true
        }
        .popover(isPresented: $showCompactPopover) {
            sizePopover(slot: state.activeSlot)
        }
    }

    private var toolGroup: some View {
        HStack(spacing: 0) {
            toolButton(.pen, system: "pencil.tip", label: "Pen")
            toolButton(.highlighter, system: "highlighter", label: "Freehand highlighter")
            toolButton(.eraser, system: "eraser", label: "Eraser")
        }
    }

    private func toolButton(_ tool: InkTool, system: String, label: String) -> some View {
        let selected = state.tool == tool
        return Button {
            state.tool = tool
        } label: {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground))
                .frame(width: 40, height: 40)
                .background {
                    if selected { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Preset swatches plus the custom color well. Full rows show every preset;
    /// compact freehand rows show three because their color well reaches more.
    private func colorRow(compact: Bool) -> some View {
        let shown = compact ? Array(colors.prefix(3)) : colors
        return HStack(spacing: 0) {
            ForEach(shown, id: \.self) { color in
                let selected = colorsEqual(state.activeColor, color)
                Button {
                    state.activeColor = color
                    state.bumpTool()
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 26, height: 26)
                        .overlay(Circle().strokeBorder(palette.border, lineWidth: 1))
                        .overlay {
                            if selected {
                                Circle().stroke(palette.primary, lineWidth: 2).padding(-3)
                            }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(accessibilityLabel(for: color)))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
            if state.tool != .textHighlight {
                customColorPicker
            }
        }
    }

    private var customColorPicker: some View {
        let isCustom = !colors.contains { colorsEqual(state.activeColor, $0) }
        return ColorPicker(
            "Custom ink color",
            selection: Binding(
                get: { state.activeColor },
                set: { state.activeColor = $0; state.bumpTool() }
            ),
            supportsOpacity: state.tool == .highlighter
        )
        .labelsHidden()
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .overlay {
            if isCustom {
                Circle()
                    .stroke(palette.primary, lineWidth: 2)
                    .frame(width: 32, height: 32)
            }
        }
        .accessibilityLabel(Text("Custom ink color"))
    }

    /// The three width dots for the active tool (pen / highlighter / eraser).
    /// Tapping an unselected dot selects that slot; tapping the already-
    /// selected dot opens a popover to customize its size.
    private var widthRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(state.activeWidths.enumerated()), id: \.offset) { index, w in
                let selected = index == state.activeSlot
                Button {
                    if selected {
                        openSlot = index
                    } else {
                        state.selectWidthSlot(index)
                    }
                } label: {
                    Circle()
                        .fill(palette.foreground)
                        .frame(width: dotSize(w), height: dotSize(w))
                        .frame(width: 34, height: 34)
                        .background {
                            if selected { Circle().fill(palette.primary.opacity(0.16)) }
                        }
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(toolLabel) size, \(String(format: "%.1f", w)) points"))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                .popover(isPresented: Binding(
                    get: { openSlot == index },
                    set: { if !$0 { openSlot = nil } }
                )) {
                    sizePopover(slot: index)
                }
            }
        }
    }

    /// Size popover: title, live preview, slider over the tool's sensible
    /// range, and a numeric readout. Edits the given slot for the active tool.
    private func sizePopover(slot: Int) -> some View {
        let range = widthRange
        return VStack(spacing: 12) {
            Text("\(toolLabel) size")
                .font(.system(size: 14, weight: .semibold))
            Circle()
                .fill(state.tool == .eraser ? AnyShapeStyle(.secondary) : AnyShapeStyle(state.activeColor))
                .frame(width: previewSize(forSlot: slot), height: previewSize(forSlot: slot))
                .frame(width: 60, height: 60)
            Slider(
                value: Binding(
                    get: { widthValue(forSlot: slot) },
                    set: { state.setWidth($0, forSlot: slot) }
                ),
                in: range
            )
            .frame(width: 180)
            Text(String(format: "%.1f pt", widthValue(forSlot: slot)))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(16)
        .presentationCompactAdaptation(.popover)
    }

    private func widthValue(forSlot slot: Int) -> CGFloat {
        state.activeWidths.indices.contains(slot) ? state.activeWidths[slot] : state.activeWidth
    }

    private func previewSize(forSlot slot: Int) -> CGFloat {
        min(48, max(3, widthValue(forSlot: slot) * (state.tool == .highlighter ? 1.0 : 2.2)))
    }

    private var widthRange: ClosedRange<Double> {
        switch state.tool {
        case .pen: 1...14
        case .highlighter: 6...40
        case .textHighlight: 1...1
        case .eraser: 6...60
        }
    }

    private var toolLabel: String {
        switch state.tool {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .textHighlight: "Text highlight"
        case .eraser: "Eraser"
        }
    }

    /// Pixel (bitmap) vs object (vector) eraser mode. Shown next to the width
    /// dots only while the eraser is the active tool.
    private func eraserModeRow(compact: Bool) -> some View {
        HStack(spacing: 0) {
            eraserModeButton(.pixel, system: "eraser", label: "Pixel eraser", size: compact ? 36 : 40)
            eraserModeButton(.object, system: "eraser.line.dashed", label: "Object eraser", size: compact ? 36 : 40)
        }
    }

    private func eraserModeButton(_ mode: EraserMode, system: String, label: String, size: CGFloat) -> some View {
        let selected = state.eraserMode == mode
        return Button {
            state.eraserMode = mode
            state.bumpTool()
        } label: {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground))
                .frame(width: size, height: size)
                .background {
                    if selected { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            if state.tool != .textHighlight {
                fingerToggle
                paletteButton("arrow.uturn.backward", label: "Undo", enabled: host.canUndo) { host.undo() }
                paletteButton("arrow.uturn.forward", label: "Redo", enabled: host.canRedo) { host.redo() }
                paletteButton("trash", label: "Clear page", enabled: true) { host.clearCurrentPage() }
            }
            Button { host.done(); onDone() } label: {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryForeground)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(palette.primary, in: Capsule())
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(state.tool == .textHighlight ? "Done selecting text" : "Done inking")
        }
    }

    /// Allow drawing with a finger (Pencil-only is the default so a finger
    /// keeps scrolling/zooming the document under the ink layer).
    private var fingerToggle: some View {
        let on = state.allowFingerDrawing
        return Button {
            state.allowFingerDrawing.toggle()
        } label: {
            Image(systemName: "hand.draw")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground))
                .frame(width: 40, height: 40)
                .background {
                    if on { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(on ? "Finger drawing on" : "Finger drawing off")
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }

    private func paletteButton(_ system: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(enabled ? AnyShapeStyle(palette.foreground) : AnyShapeStyle(.tertiary))
                .frame(width: 40, height: 40)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 28)
    }

    private func dotSize(_ w: CGFloat) -> CGFloat {
        let scale: CGFloat = state.tool == .pen ? 1.6 : 0.5
        return min(24, max(6, w * scale))
    }

    private func colorsEqual(_ a: Color, _ b: Color) -> Bool {
        UIColor(a).cgColor == UIColor(b).cgColor
    }

    private func accessibilityLabel(for color: Color) -> String {
        if state.tool == .highlighter || state.tool == .textHighlight,
           let index = InkPalette.highlighterColors.firstIndex(where: {
               colorsEqual($0, color)
           })
        {
            return "\(HIGHLIGHT_COLORS[index].name) highlight color"
        }
        return "Ink color"
    }
}
#endif
