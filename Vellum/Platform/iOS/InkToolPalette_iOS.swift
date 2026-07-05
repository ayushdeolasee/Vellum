#if os(iOS)
import SwiftUI

/// Floating Liquid Glass ink palette: tool (pen / highlighter / eraser), color,
/// width, undo, clear, and Done. Sits at the bottom so it never covers the top
/// of the page being annotated.
struct InkToolPalette_iOS: View {
    @Bindable var ink: InkController_iOS
    var onDone: () -> Void

    @Environment(\.palette) private var palette

    /// The width-slot dot currently showing its size popover (full variant).
    @State private var openSlot: Int?
    /// Whether the compact cycle dot's size popover is showing.
    @State private var showCompactPopover = false

    private var colors: [Color] {
        ink.tool == .highlighter ? InkPalette.highlighterColors : InkPalette.penColors
    }

    var body: some View {
        // The full row outgrows the PDF column when the sidebar is open, so a
        // compact variant (single cycling width dot) takes over instead of
        // letting the capsule clip at the edges.
        ViewThatFits(in: .horizontal) {
            paletteRow(compact: false)
            paletteRow(compact: true)
        }
    }

    private func paletteRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 10) {
            toolGroup
            divider
            if ink.tool != .eraser {
                colorRow
                divider
            }
            if compact {
                widthCycleButton
            } else {
                widthRow
            }
            if ink.tool == .eraser {
                divider
                eraserModeRow(compact: compact)
            }
            divider
            actionRow
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, 8)
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }

    /// Compact width control: one dot showing the current size; tap cycles
    /// through the slots, long-press opens the size popover for the current
    /// slot.
    private var widthCycleButton: some View {
        Button {
            ink.cycleWidthSlot()
        } label: {
            Circle()
                .fill(palette.foreground)
                .frame(width: dotSize(ink.activeWidth), height: dotSize(ink.activeWidth))
                .frame(width: 34, height: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stroke width — tap to cycle, touch and hold to adjust")
        .onLongPressGesture {
            showCompactPopover = true
        }
        .popover(isPresented: $showCompactPopover) {
            sizePopover(slot: ink.activeSlot)
        }
    }

    private var toolGroup: some View {
        HStack(spacing: 4) {
            toolButton(.pen, system: "pencil.tip", label: "Pen")
            toolButton(.highlighter, system: "highlighter", label: "Highlighter")
            toolButton(.eraser, system: "eraser", label: "Eraser")
        }
    }

    private func toolButton(_ tool: InkTool, system: String, label: String) -> some View {
        let selected = ink.tool == tool
        return Button {
            ink.tool = tool
        } label: {
            Image(systemName: system)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground))
                .frame(width: 40, height: 40)
                .background {
                    if selected { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var colorRow: some View {
        HStack(spacing: 6) {
            ForEach(colors, id: \.self) { color in
                let selected = colorsEqual(ink.activeColor, color)
                Button {
                    ink.activeColor = color
                    ink.bumpTool()
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
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Ink color"))
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    /// The three width dots for the active tool (pen / highlighter / eraser).
    /// Tapping an unselected dot selects that slot; tapping the already-
    /// selected dot opens a popover to customize its size.
    private var widthRow: some View {
        HStack(spacing: 6) {
            ForEach(Array(ink.activeWidths.enumerated()), id: \.offset) { index, w in
                let selected = index == ink.activeSlot
                Button {
                    if selected {
                        openSlot = index
                    } else {
                        ink.selectWidthSlot(index)
                    }
                } label: {
                    Circle()
                        .fill(palette.foreground)
                        .frame(width: dotSize(w), height: dotSize(w))
                        .frame(width: 34, height: 34)
                        .background {
                            if selected { Circle().fill(palette.primary.opacity(0.16)) }
                        }
                        .contentShape(Circle())
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
                .fill(ink.tool == .eraser ? AnyShapeStyle(.secondary) : AnyShapeStyle(ink.activeColor))
                .frame(width: previewSize(forSlot: slot), height: previewSize(forSlot: slot))
                .frame(width: 60, height: 60)
            Slider(
                value: Binding(
                    get: { widthValue(forSlot: slot) },
                    set: { ink.setWidth($0, forSlot: slot) }
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
        ink.activeWidths.indices.contains(slot) ? ink.activeWidths[slot] : ink.activeWidth
    }

    private func previewSize(forSlot slot: Int) -> CGFloat {
        min(48, max(3, widthValue(forSlot: slot) * (ink.tool == .highlighter ? 1.0 : 2.2)))
    }

    private var widthRange: ClosedRange<Double> {
        switch ink.tool {
        case .pen: 1...14
        case .highlighter: 6...40
        case .eraser: 6...60
        }
    }

    private var toolLabel: String {
        switch ink.tool {
        case .pen: "Pen"
        case .highlighter: "Highlighter"
        case .eraser: "Eraser"
        }
    }

    /// Pixel (bitmap) vs object (vector) eraser mode. Shown next to the width
    /// dots only while the eraser is the active tool.
    private func eraserModeRow(compact: Bool) -> some View {
        HStack(spacing: compact ? 2 : 4) {
            eraserModeButton(.pixel, system: "eraser", label: "Pixel eraser", size: compact ? 36 : 40)
            eraserModeButton(.object, system: "eraser.line.dashed", label: "Object eraser", size: compact ? 36 : 40)
        }
    }

    private func eraserModeButton(_ mode: EraserMode, system: String, label: String, size: CGFloat) -> some View {
        let selected = ink.eraserMode == mode
        return Button {
            ink.eraserMode = mode
            ink.bumpTool()
        } label: {
            Image(systemName: system)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(selected ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground))
                .frame(width: size, height: size)
                .background {
                    if selected { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var actionRow: some View {
        HStack(spacing: 4) {
            fingerToggle
            paletteButton("arrow.uturn.backward", label: "Undo", enabled: ink.canUndo) { ink.undo() }
            paletteButton("arrow.uturn.forward", label: "Redo", enabled: ink.canRedo) { ink.redo() }
            paletteButton("trash", label: "Clear page", enabled: true) { ink.clearCurrentPage() }
            Button(action: onDone) {
                Text("Done")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.primaryForeground)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(palette.primary, in: Capsule())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Done inking")
        }
    }

    /// Allow drawing with a finger (Pencil-only is the default so a finger
    /// keeps scrolling/zooming the document under the ink layer).
    private var fingerToggle: some View {
        let on = ink.allowFingerDrawing
        return Button {
            ink.allowFingerDrawing.toggle()
        } label: {
            Image(systemName: "hand.draw")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(on ? AnyShapeStyle(palette.primary) : AnyShapeStyle(palette.foreground))
                .frame(width: 40, height: 40)
                .background {
                    if on { Circle().fill(palette.primary.opacity(0.16)) }
                }
                .contentShape(Circle())
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
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private var divider: some View {
        Rectangle().fill(.quaternary).frame(width: 1, height: 28)
    }

    private func dotSize(_ w: CGFloat) -> CGFloat {
        let scale: CGFloat = ink.tool == .highlighter ? 0.5 : (ink.tool == .eraser ? 0.5 : 1.6)
        return min(24, max(6, w * scale))
    }

    private func colorsEqual(_ a: Color, _ b: Color) -> Bool {
        UIColor(a).cgColor == UIColor(b).cgColor
    }
}
#endif
