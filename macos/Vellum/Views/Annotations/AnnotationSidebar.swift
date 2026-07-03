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
                                editText: $editText,
                                editFieldFocused: $editFieldFocused,
                                onSelect: { navigate(to: annotation) },
                                onStartEdit: { startEditing(annotation) },
                                onSaveEdit: { saveEdit(annotation.id) },
                                onCancelEdit: { cancelEdit() },
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
                        .background(palette.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay {
                            RoundedRectangle(cornerRadius: 3)
                                .strokeBorder(palette.borderStrong, lineWidth: 1)
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
                .foregroundStyle(palette.mutedForeground)

            FilterPill(
                title: "All · \(annotationStore.annotations.count)",
                selected: filter == nil,
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
                        action: { filter = type }
                    )
                }
            }

            Spacer(minLength: 0)
        }
        .padding(10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(palette.border).frame(height: 1)
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
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? palette.primaryForeground : palette.mutedForeground)
            .background(selected ? palette.primary : (hovering ? palette.accent : palette.muted))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct AnnotationRow: View {
    let annotation: Annotation
    let selected: Bool
    let editing: Bool
    @Binding var editText: String
    var editFieldFocused: FocusState<Bool>.Binding
    let onSelect: () -> Void
    let onStartEdit: () -> Void
    let onSaveEdit: () -> Void
    let onCancelEdit: () -> Void
    let onDelete: () -> Void

    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.palette) private var palette
    @State private var hovering = false

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
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.mutedForeground)

                if let selectedText = annotation.positionData?.selectedText,
                   !selectedText.isEmpty {
                    Text("“\(selectedText)”")
                        .font(.system(size: 14).italic())
                        .foregroundStyle(palette.mutedForeground)
                        .lineLimit(2)
                        .padding(.top, 4)
                }

                if editing {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
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
                        .font(.system(size: 14))
                        .foregroundStyle(palette.foreground)
                        .lineLimit(3)
                        .padding(.top, 4)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2, perform: onStartEdit)
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
            .opacity(hovering ? 1 : 0)
            .help("Delete annotation")
            .accessibilityLabel("Delete annotation")
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
            Circle()
                .fill(themeStore.highlightRenderColor(for: annotation.color))
                .frame(width: 16, height: 16)
                .overlay {
                    Circle().strokeBorder(palette.borderStrong, lineWidth: 1)
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
