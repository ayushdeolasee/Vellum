import SwiftUI

struct AnnotationSidebar: View {
    @Environment(AppStore.self) private var appStore
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(\.palette) private var palette

    @State private var filter: AnnotationType?
    @State private var editingId: String?
    @State private var editText = ""
    @FocusState private var editFieldFocused: Bool

    var body: some View {
        if annotationStore.annotations.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                filterBar
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredAnnotations) { annotation in
                            AnnotationRow(
                                annotation: annotation,
                                selected: annotationStore.selectedAnnotationId == annotation.id,
                                editing: editingId == annotation.id,
                                fontSize: appStore.sidebarFontSize,
                                editText: $editText,
                                editFieldFocused: $editFieldFocused,
                                onSelect: { navigate(to: annotation) },
                                onStartEdit: { startEditing(annotation) },
                                onSaveEdit: { saveEdit(annotation.id) },
                                onCancelEdit: { cancelEdit() },
                                onChangeColor: { color in changeColor(annotation, to: color) },
                                onDelete: {
                                    Task { await annotationStore.deleteAnnotation(id: annotation.id) }
                                }
                            )
                        }
                    }
                    .padding(6)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "highlighter")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 48, height: 48)
                .background(palette.muted)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(palette.border, lineWidth: 1)
                }

            VStack(spacing: 4) {
                Text("No annotations yet")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.foreground)

                HStack(spacing: 3) {
                    Text("Select text on the page to highlight it, or press")
                    Text("N")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 2)
                        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 3))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(.separator)
                        }
                    Text("to drop a note.")
                }
                .font(.system(size: 12))
                .foregroundStyle(palette.mutedForeground)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            FilterPill(
                title: "All · \(annotationStore.annotations.count)",
                selected: filter == nil,
                accessibilityLabel: "All annotations",
                accessibilityIdentifier: "annotationFilter.all",
                action: { filter = nil }
            )

            ForEach([AnnotationType.highlight, .note, .bookmark], id: \.self) { type in
                let count = count(for: type)
                if count > 0 {
                    FilterPill(
                        title: String(count),
                        systemImage: symbol(for: type),
                        selected: filter == type,
                        help: typeLabel(for: type),
                        accessibilityLabel: "\(typeLabel(for: type)), \(count)",
                        accessibilityIdentifier: "annotationFilter.\(typeLabel(for: type).lowercased())",
                        action: { filter = type }
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var filteredAnnotations: [Annotation] {
        guard let filter else { return annotationStore.annotations }
        return annotationStore.annotations.filter { $0.type == filter }
    }

    private func count(for type: AnnotationType) -> Int {
        annotationStore.annotations.reduce(0) { $0 + ($1.type == type ? 1 : 0) }
    }

    private func navigate(to annotation: Annotation) {
        annotationStore.selectAnnotation(annotation.id)
        if appStore.document?.kind == .web,
           annotation.type != .highlight,
           let position = annotation.positionData,
           position.startOffset != nil,
           appStore.scrollToWebPositionHandler?(position, annotation.pageNumber) == true {
            return
        }
        appStore.goToPage(annotation.pageNumber)
        appStore.scrollToPageHandler?(annotation.pageNumber)
    }

    /// Recolor a highlight in place — deliberately no selectAnnotation /
    /// navigation, so the viewer never jumps to the highlight.
    private func changeColor(_ annotation: Annotation, to color: String) {
        let input = UpdateAnnotationInput(
            id: annotation.id,
            color: color,
            content: nil,
            positionData: nil
        )
        Task { await annotationStore.updateAnnotation(input) }
    }

    private func startEditing(_ annotation: Annotation) {
        editingId = annotation.id
        editText = annotation.content ?? ""
        Task {
            await Task.yield()
            editFieldFocused = true
        }
    }

    private func saveEdit(_ id: String) {
        let input = UpdateAnnotationInput(
            id: id,
            color: nil,
            content: editText,
            positionData: nil
        )
        editingId = nil
        editFieldFocused = false
        Task { await annotationStore.updateAnnotation(input) }
    }

    private func cancelEdit() {
        editingId = nil
        editFieldFocused = false
    }
}

private struct FilterPill: View {
    let title: String
    var systemImage: String? = nil
    let selected: Bool
    var help: String = ""
    var accessibilityLabel: String? = nil
    var accessibilityIdentifier: String? = nil
    let action: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 12))
                }
                Text(title)
            }
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .foregroundStyle(
                selected
                    ? AnyShapeStyle(palette.primaryForeground)
                    : AnyShapeStyle(hovering ? .primary : .secondary))
            .background(
                selected
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.quaternary.opacity(hovering ? 0.8 : 0.5)),
                in: Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(accessibilityLabel ?? (help.isEmpty ? title : help))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(accessibilityIdentifier ?? "annotationFilter.\(title)")
    }
}

private struct AnnotationRow: View {
    let annotation: Annotation
    let selected: Bool
    let editing: Bool
    let fontSize: Double
    @Binding var editText: String
    var editFieldFocused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onStartEdit: () -> Void
    let onSaveEdit: () -> Void
    let onCancelEdit: () -> Void
    let onChangeColor: (String) -> Void
    let onDelete: () -> Void

    @Environment(\.palette) private var palette
    @State private var hovering = false
    @State private var colorPickerOpen = false

    /// Meta line / quote scale with the body size, keeping their ratio.
    private var metaSize: Double { max(9, fontSize - 3) }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            marker
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(typeLabel(for: annotation.type).uppercased())
                        .tracking(0.5)
                    Text("·")
                    Text("p.\(annotation.pageNumber)")
                }
                .font(.system(size: metaSize, weight: .medium))
                .foregroundStyle(palette.mutedForeground)

                if let selectedText = annotation.positionData?.selectedText,
                   !selectedText.isEmpty {
                    Text("“\(selectedText)”")
                        .font(.system(size: fontSize).italic())
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(2)
                        .padding(.top, 4)
                }

                if editing {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(size: fontSize))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(palette.muted)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                        .overlay {
                            RoundedRectangle(cornerRadius: Radius.sm)
                                .strokeBorder(palette.primary, lineWidth: 1)
                        }
                        .focused(editFieldFocused)
                        .onSubmit(onSaveEdit)
                        .onExitCommand(perform: onCancelEdit)
                        .padding(.top, 4)
                } else if let content = annotation.content, !content.isEmpty {
                    Text(content)
                        .font(.system(size: fontSize))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(3)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                        .highPriorityGesture(
                            TapGesture(count: 2).onEnded { onStartEdit() }
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 14))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.mutedForeground)
            .opacity(hovering || selected ? 1 : 0)
            .help("Delete annotation")
            .accessibilityLabel("Delete annotation")
            .accessibilityIdentifier("annotationRow.delete")
        }
        .padding(10)
        .background((selected || hovering) ? palette.accent : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(selected ? palette.borderStrong : .clear, lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var marker: some View {
        if annotation.type == .highlight, annotation.color != nil {
            // The circle doubles as a color picker. The tap must be a
            // highPriorityGesture: a plain Button here still lets the row's
            // own onTapGesture fire, which selects the row and scrolls the
            // viewer to the highlight — exactly what this picker must avoid.
            Circle()
                .fill(Color(hex: annotation.color ?? "#fef08a"))
                .frame(width: 16, height: 16)
                .overlay {
                    Circle().strokeBorder(palette.borderStrong, lineWidth: 1)
                }
                .padding(3)
                .contentShape(Circle())
                .highPriorityGesture(
                    TapGesture().onEnded { colorPickerOpen = true }
                )
                .padding(-3)
                .help("Change highlight color")
                .accessibilityLabel("Change highlight color")
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("annotationRow.changeColor")
            .popover(isPresented: $colorPickerOpen, arrowEdge: .bottom) {
                HStack(spacing: 6) {
                    ForEach(HIGHLIGHT_COLORS) { color in
                        HighlightSwatchButton(
                            color: color,
                            size: 20,
                            isCurrent: annotation.color == color.value,
                            helpText: "Set highlight color: \(color.name)"
                        ) {
                            colorPickerOpen = false
                            onChangeColor(color.value)
                        }
                    }
                }
                .padding(10)
            }
        } else {
            Image(systemName: symbol(for: annotation.type))
                .font(.system(size: 16))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 16, height: 16)
        }
    }
}

private func symbol(for type: AnnotationType) -> String {
    switch type {
    case .highlight: "highlighter"
    case .note: "message"
    case .bookmark: "bookmark"
    }
}

private func typeLabel(for type: AnnotationType) -> String {
    switch type {
    case .highlight: "Highlights"
    case .note: "Notes"
    case .bookmark: "Bookmarks"
    }
}
