import SwiftUI

/// One selectable model, unified across providers. Built-in provider models
/// carry no pricing/context metadata; OpenRouter models carry all of it.
struct AiModelOption: Identifiable, Equatable {
    var id: String
    var name: String
    var supportsVision: Bool
    var supportsTools: Bool
    var contextLength: Int?
    var promptPrice: Double?
    var created: Int?
}

enum ModelSort: String, CaseIterable, Identifiable {
    case name = "Name"
    case priceAsc = "Price"
    case contextDesc = "Context"
    case recent = "Newest"
    var id: String { rawValue }
}

/// Searchable, sortable, pinnable model picker. Replaces the plain `Picker`
/// across every provider; scales to OpenRouter's large catalog. Presented as a
/// popover so it works both inside the AI side panel and the Settings window.
struct ModelSelector: View {
    let options: [AiModelOption]
    @Binding var selection: String
    @Binding var pinned: [String]
    var isLoading = false
    var onOpen: (() -> Void)?

    @Environment(\.palette) private var palette
    @State private var isPresented = false
    @State private var query = ""
    @State private var sort: ModelSort = .name

    var body: some View {
        Button {
            isPresented = true
            onOpen?()
        } label: {
            triggerLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover.frame(width: 340, height: 380)
        }
    }

    private var selectedOption: AiModelOption? {
        options.first { $0.id == selection }
    }

    private var triggerLabel: some View {
        HStack(spacing: 6) {
            Text(selectedOption?.name ?? (selection.isEmpty ? "Select a model" : selection))
                .lineLimit(1)
                .foregroundStyle(selection.isEmpty ? palette.mutedForeground : palette.foreground)
            if let option = selectedOption, !(option.supportsVision && option.supportsTools) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(palette.gold)
                    .font(.system(size: 10))
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9))
                .foregroundStyle(palette.mutedForeground)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1)
        )
    }

    // MARK: - Popover

    private var popover: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if options.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if !pinnedOptions.isEmpty {
                            sectionHeader("Pinned")
                            ForEach(pinnedOptions) { row($0) }
                            sectionHeader("All models")
                        }
                        ForEach(unpinnedOptions) { row($0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(palette.surface)
        .font(.system(size: 12))
    }

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(palette.mutedForeground)
                // Empty label + prompt so grouped-Form styling (inherited by the
                // popover in the Settings window) can't render "Search models"
                // as a trailing form label.
                TextField("", text: $query, prompt: Text("Search models"))
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(palette.surfaceMuted))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))

            Picker("", selection: $sort) {
                ForEach(ModelSort.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            if isLoading {
                ProgressView()
                Text("Loading models…").foregroundStyle(palette.mutedForeground)
            } else {
                Text("No models found").foregroundStyle(palette.mutedForeground)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(palette.mutedForeground)
            .padding(.horizontal, 6)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private func row(_ option: AiModelOption) -> some View {
        let isSelected = option.id == selection
        return Button {
            selection = option.id
            isPresented = false
        } label: {
            HStack(spacing: 8) {
                Button {
                    togglePin(option.id)
                } label: {
                    Image(systemName: pinned.contains(option.id) ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(pinned.contains(option.id) ? palette.gold : palette.mutedForeground)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).lineLimit(1).foregroundStyle(palette.foreground)
                    HStack(spacing: 6) {
                        if let subtitle = subtitle(option) {
                            Text(subtitle).foregroundStyle(palette.mutedForeground)
                        }
                        if !option.supportsVision { badge("no image") }
                        if !option.supportsTools { badge("no actions") }
                    }
                    .font(.system(size: 10))
                }
                Spacer(minLength: 4)
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(palette.primary)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5).fill(isSelected ? palette.primary.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(palette.gold)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(palette.gold.opacity(0.15)))
    }

    // MARK: - Data

    private func togglePin(_ id: String) {
        if let index = pinned.firstIndex(of: id) {
            pinned.remove(at: index)
        } else {
            pinned.append(id)
        }
    }

    private var filtered: [AiModelOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = q.isEmpty ? options : options.filter {
            $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
        }
        return base.sorted(by: sortComparator)
    }

    private var pinnedOptions: [AiModelOption] {
        filtered.filter { pinned.contains($0.id) }
    }

    private var unpinnedOptions: [AiModelOption] {
        pinnedOptions.isEmpty ? filtered : filtered.filter { !pinned.contains($0.id) }
    }

    private func sortComparator(_ a: AiModelOption, _ b: AiModelOption) -> Bool {
        switch sort {
        case .name:
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        case .priceAsc:
            return (a.promptPrice ?? .greatestFiniteMagnitude) < (b.promptPrice ?? .greatestFiniteMagnitude)
        case .contextDesc:
            return (a.contextLength ?? 0) > (b.contextLength ?? 0)
        case .recent:
            return (a.created ?? 0) > (b.created ?? 0)
        }
    }

    private func subtitle(_ option: AiModelOption) -> String? {
        var parts: [String] = []
        if let context = option.contextLength {
            parts.append("\(context / 1000)K ctx")
        }
        if let price = option.promptPrice {
            if price == 0 {
                parts.append("free")
            } else {
                // per-token USD → per-million tokens.
                parts.append(String(format: "$%.2f/M", price * 1_000_000))
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
