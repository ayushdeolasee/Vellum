import AppKit
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
    var completionPrice: Double? = nil
    var created: Int?
}

enum ModelSort: String, CaseIterable, Identifiable {
    case pinned = "Pinned"
    case name = "Name"
    case price = "Price"
    case context = "Context"
    var id: String { rawValue }

    /// Sensible default direction when a sort mode is first selected.
    /// Pinned/Name → A–Z, Price → cheapest first, Context → largest first.
    var defaultAscending: Bool {
        switch self {
        case .pinned, .name, .price: return true
        case .context: return false
        }
    }
}

/// Vision-capability filter for the picker.
enum ImageFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case withImage = "With image"
    case noImage = "No image"
    var id: String { rawValue }
}

/// Tool/function-calling capability filter for the picker.
enum ToolsFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case withTools = "With tools"
    case noTools = "No tools"
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
    // Persisted so the picker reopens to the last-used sort tab + direction.
    @AppStorage("modelSelector.sort") private var sortRaw = ModelSort.name.rawValue
    @AppStorage("modelSelector.ascending") private var ascending = ModelSort.name.defaultAscending
    @State private var providerFilter: String?
    @State private var imageFilter: ImageFilter = .all
    @State private var toolsFilter: ToolsFilter = .all
    @State private var freeOnly = false
    // Bumped on every pin toggle to force an immediate re-render (see togglePin).
    @State private var pinRefresh = 0

    /// The active sort, bridged over the persisted raw string. Falls back to
    /// `.name` when the stored value can't be parsed.
    private var sort: ModelSort {
        get { ModelSort(rawValue: sortRaw) ?? .name }
        nonmutating set { sortRaw = newValue.rawValue }
    }

    private var sortBinding: Binding<ModelSort> {
        Binding(get: { sort }, set: { sort = $0 })
    }

    var body: some View {
        Button {
            onOpen?()
            // If a text field is focused (typically the API-key SecureField
            // above this control), its system autofill/completion overlay tears
            // down in the same runloop turn as this click. Presenting the
            // popover in that turn races the teardown inside AppKit's
            // ViewBridge and aborts the app (NSRemoteView "expected (null)"
            // assertion). Resign focus first, then present on the next turn.
            NSApp.keyWindow?.makeFirstResponder(nil)
            DispatchQueue.main.async { isPresented = true }
        } label: {
            triggerLabel
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popover.frame(width: 400, height: 470)
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
            if filtered.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if sort == .pinned {
                            // Everything shown is already pinned — render flat.
                            ForEach(filtered) { row($0) }
                        } else {
                            if !pinnedOptions.isEmpty {
                                sectionHeader("Pinned")
                                ForEach(pinnedOptions) { row($0) }
                                sectionHeader("All models")
                            }
                            ForEach(unpinnedOptions) { row($0) }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    // Rebuild rows when a pin toggles so the star fill and the
                    // pinned/all-models split refresh right away (a moved row
                    // would otherwise be reused with its stale star).
                    .id(pinRefresh)
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

            HStack(spacing: 6) {
                Picker("", selection: sortBinding) {
                    ForEach(ModelSort.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: sortRaw) { _, newValue in
                    ascending = (ModelSort(rawValue: newValue) ?? .name).defaultAscending
                }

                Button {
                    ascending.toggle()
                } label: {
                    Image(systemName: ascending ? "arrow.up" : "arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 26, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(palette.surfaceMuted))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(ascending ? "Sorted low → high" : "Sorted high → low")
            }

            if !availableProviders.isEmpty {
                VStack(spacing: 6) {
                    HStack(spacing: 6) {
                        providerMenu
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 6) {
                        imageMenu
                        toolsMenu
                        freeChip
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(12)
    }

    private var providerMenu: some View {
        Menu {
            menuItem("All providers", selected: providerFilter == nil) { providerFilter = nil }
            Divider()
            ForEach(availableProviders, id: \.slug) { provider in
                menuItem("\(provider.name) (\(provider.count))",
                         selected: providerFilter == provider.slug) {
                    providerFilter = provider.slug
                }
            }
        } label: {
            filterChip(
                icon: "building.2",
                text: providerFilter.map(Self.providerDisplayName) ?? "All providers",
                active: providerFilter != nil
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var imageMenu: some View {
        Menu {
            ForEach(ImageFilter.allCases) { option in
                menuItem(option.rawValue, selected: imageFilter == option) {
                    imageFilter = option
                }
            }
        } label: {
            filterChip(
                icon: "photo",
                text: imageFilter == .all ? "Image" : imageFilter.rawValue,
                active: imageFilter != .all
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var toolsMenu: some View {
        Menu {
            ForEach(ToolsFilter.allCases) { option in
                menuItem(option.rawValue, selected: toolsFilter == option) {
                    toolsFilter = option
                }
            }
        } label: {
            filterChip(
                icon: "wrench.and.screwdriver",
                text: toolsFilter == .all ? "Tools" : toolsFilter.rawValue,
                active: toolsFilter != .all
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var freeChip: some View {
        Button {
            freeOnly.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "gift").font(.system(size: 9))
                Text("Free").lineLimit(1)
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(freeOnly ? palette.primary : palette.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(freeOnly ? palette.primary.opacity(0.12) : palette.surfaceMuted)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(freeOnly ? palette.primary.opacity(0.4) : palette.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    @ViewBuilder
    private func menuItem(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private func filterChip(icon: String, text: String, active: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 7))
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(active ? palette.primary : palette.mutedForeground)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(active ? palette.primary.opacity(0.12) : palette.surfaceMuted)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(active ? palette.primary.opacity(0.4) : palette.border, lineWidth: 1)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Spacer()
            if isLoading {
                ProgressView()
                Text("Loading models…").foregroundStyle(palette.mutedForeground)
            } else if options.isEmpty {
                Text("No models found").foregroundStyle(palette.mutedForeground)
            } else if sort == .pinned && pinned.isEmpty {
                Image(systemName: "star")
                    .font(.system(size: 18))
                    .foregroundStyle(palette.mutedForeground)
                Text("No pinned models yet").foregroundStyle(palette.mutedForeground)
                Text("Tap the star on a model to pin it.")
                    .font(.system(size: 10))
                    .foregroundStyle(palette.mutedForeground)
            } else {
                Text("No models match your filters").foregroundStyle(palette.mutedForeground)
                Button("Clear filters") {
                    query = ""
                    providerFilter = nil
                    imageFilter = .all
                    toolsFilter = .all
                    freeOnly = false
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.primary)
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
        let isPinned = pinned.contains(option.id)
        // The star and the row body are SIBLING buttons — not nested — so the
        // star's tap toggles the pin without the row's select firing, and its
        // fill/color reliably re-renders when the pin state flips.
        return HStack(spacing: 8) {
            Button {
                togglePin(option.id)
            } label: {
                Image(systemName: isPinned ? "star.fill" : "star")
                    .font(.system(size: 11))
                    .foregroundStyle(isPinned ? Color.yellow : palette.mutedForeground)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                selection = option.id
                isPresented = false
            } label: {
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.name).lineLimit(1).foregroundStyle(palette.foreground)
                        HStack(spacing: 6) {
                            if let subtitle = subtitle(option) {
                                Text(subtitle).lineLimit(1).foregroundStyle(palette.mutedForeground)
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
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 5).fill(isSelected ? palette.primary.opacity(0.14) : Color.clear)
        )
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
        // `pinned` is a manual closure-Binding over AiStore, which doesn't
        // invalidate this view on its own — bump local state so the star fill
        // and pinned/all-models sections update immediately on tap.
        pinRefresh &+= 1
    }

    private var filtered: [AiModelOption] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var base = options
        // On the Pinned tab, only pinned models are shown.
        if sort == .pinned {
            base = base.filter { pinned.contains($0.id) }
        }
        if let providerFilter {
            base = base.filter { Self.providerSlug($0.id) == providerFilter }
        }
        switch imageFilter {
        case .all: break
        case .withImage: base = base.filter(\.supportsVision)
        case .noImage: base = base.filter { !$0.supportsVision }
        }
        switch toolsFilter {
        case .all: break
        case .withTools: base = base.filter(\.supportsTools)
        case .noTools: base = base.filter { !$0.supportsTools }
        }
        if freeOnly {
            base = base.filter(Self.isFree)
        }
        if !q.isEmpty {
            base = base.filter {
                $0.id.lowercased().contains(q) || $0.name.lowercased().contains(q)
            }
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
        case .pinned, .name:
            let comparison = a.name.localizedCaseInsensitiveCompare(b.name)
            if comparison == .orderedSame {
                return a.id < b.id // deterministic tie-break for duplicate display names
            }
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        case .price:
            return numericCompare(Self.priceKey(a), Self.priceKey(b))
        case .context:
            // contextLength is optional; treat nil as unknown.
            return numericCompare(a.contextLength.map(Double.init), b.contextLength.map(Double.init))
        }
    }

    /// Direction-aware compare that always sinks unknown values (`nil`) to the
    /// bottom — in both ascending and descending order — so "no price" /
    /// "no context" rows never crowd the top of a sorted list.
    private func numericCompare(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case let (x?, y?): return ascending ? x < y : x > y
        case (nil, _?): return false   // a unknown → after b
        case (_?, nil): return true    // b unknown → a first
        case (nil, nil): return false
        }
    }

    /// Usable prompt price, or nil when OpenRouter reports no real price — that
    /// includes the `-1` sentinel it returns for variable-priced auto-routers.
    private static func priceKey(_ option: AiModelOption) -> Double? {
        guard let price = option.promptPrice, price >= 0 else { return nil }
        return price
    }

    /// A model is "free" only when both input AND output pricing are free; a
    /// free-input/paid-output model still bills the user. Shared by the free-only
    /// filter and the subtitle label so they never disagree.
    private static func isFree(_ option: AiModelOption) -> Bool {
        option.promptPrice == 0 && (option.completionPrice ?? 0) <= 0
    }

    // MARK: - Providers

    /// Providers present in the current option set, most popular first, each
    /// with a display name and model count. Derived from OpenRouter ids of the
    /// form `provider/model`; empty for built-in providers (bare ids).
    private var availableProviders: [(slug: String, name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for option in options {
            guard let slug = Self.providerSlug(option.id) else { continue }
            counts[slug, default: 0] += 1
        }
        return counts
            .map { (slug: $0.key, name: Self.providerDisplayName($0.key), count: $0.value) }
            .sorted { lhs, rhs in
                let lRank = Self.providerRank[lhs.slug] ?? Int.max
                let rRank = Self.providerRank[rhs.slug] ?? Int.max
                if lRank != rRank { return lRank < rRank }
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    /// Provider slug from an OpenRouter id (`anthropic/claude-3.5` → `anthropic`).
    private static func providerSlug(_ id: String) -> String? {
        guard let slash = id.firstIndex(of: "/") else { return nil }
        let slug = String(id[..<slash])
        return slug.isEmpty ? nil : slug
    }

    /// Popularity ranking so the biggest labs surface at the top of the filter.
    private static let providerRank: [String: Int] = [
        "anthropic": 0, "openai": 1, "google": 2, "meta-llama": 3,
        "deepseek": 4, "mistralai": 5, "x-ai": 6, "qwen": 7,
        "cohere": 8, "perplexity": 9, "microsoft": 10, "nvidia": 11,
    ]

    private static let providerNames: [String: String] = [
        "openai": "OpenAI", "x-ai": "xAI", "meta-llama": "Meta",
        "mistralai": "Mistral", "deepseek": "DeepSeek", "nvidia": "NVIDIA",
        "qwen": "Qwen", "google": "Google", "anthropic": "Anthropic",
    ]

    private static func providerDisplayName(_ slug: String) -> String {
        if let name = providerNames[slug] { return name }
        return slug.capitalized
    }

    private func subtitle(_ option: AiModelOption) -> String? {
        var parts: [String] = []
        if let context = option.contextLength {
            parts.append("\(context / 1000)K ctx")
        }
        if let price = option.promptPrice {
            if price < 0 {
                // OpenRouter returns -1 for variable-priced auto-routers.
                parts.append("variable price")
            } else if Self.isFree(option) {
                parts.append("free")
            } else {
                // per-token USD → per-million tokens.
                let input = price * 1_000_000
                if let completion = option.completionPrice, completion >= 0,
                   completion != price {
                    let output = completion * 1_000_000
                    parts.append("$\(Self.priceString(input))/$\(Self.priceString(output)) per M")
                } else {
                    parts.append("$\(Self.priceString(input))/M")
                }
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Compact per-million price: drops noisy trailing zeros ("$3" not "$3.00")
    /// while keeping meaningful fractions ("$0.25").
    private static func priceString(_ value: Double) -> String {
        if value == value.rounded() {
            return String(format: "%.0f", value)
        }
        // Up to 2 decimals, trimming a trailing zero (e.g. 0.50 → 0.5).
        var s = String(format: "%.2f", value)
        if s.hasSuffix("0") { s.removeLast() }
        return s
    }
}
