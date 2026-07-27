import SwiftUI

struct HelpCenterView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.palette) private var palette
    @State private var query = ""

    private var filteredTopics: [HelpTopic] {
        HelpTopic.search(query)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if filteredTopics.isEmpty {
                ContentUnavailableView.search(text: query)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityIdentifier("help.noResults")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filteredTopics) { topic in
                            topicCard(topic)
                        }
                    }
                    .padding(20)
                }
                .accessibilityIdentifier("help.results")
            }
        }
        .frame(minWidth: 560, idealWidth: 680, minHeight: 480, idealHeight: 640)
        .background(palette.well)
        .searchable(text: $query, placement: .toolbar, prompt: "Search features and shortcuts")
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 20))
                .foregroundStyle(.tint)
                .frame(width: 42, height: 42)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))

            VStack(alignment: .leading, spacing: 2) {
                Text("Vellum Help")
                    .font(.system(size: 22, weight: .semibold))
                Text("Features, concepts, and keyboard shortcuts")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
            }

            Spacer()

            Button {
                openWindow(id: "onboarding")
            } label: {
                Label("Show Welcome Tour", systemImage: "play.circle")
            }
            .buttonStyle(.glass)
            .accessibilityIdentifier("help.replayTour")
        }
        .padding(20)
        .background(palette.background)
    }

    private func topicCard(_ topic: HelpTopic) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: topic.icon)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(topic.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if let shortcut = topic.shortcut {
                    Text(shortcut)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: Radius.sm))
                        .accessibilityLabel("Keyboard shortcut \(shortcut)")
                }
            }

            Text(topic.summary)
                .font(.system(size: 13))
                .foregroundStyle(palette.mutedForeground)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.surface, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(palette.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("help.topic.\(topic.id)")
    }
}

struct HelpTopic: Identifiable, Equatable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let shortcut: String?
    let keywords: [String]

    fileprivate var searchableText: String {
        ([title, summary, shortcut ?? ""] + keywords).joined(separator: " ").lowercased()
    }

    static func search(_ query: String) -> [HelpTopic] {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return all }
        return all.filter { topic in terms.allSatisfy(topic.searchableText.contains) }
    }

    static let all: [HelpTopic] = [
        HelpTopic(id: "open-pdf", title: "Open a PDF", icon: "doc",
                  summary: "Open one or several PDF files into tabs.",
                  shortcut: "⌘O", keywords: ["file", "import"]),
        HelpTopic(id: "open-web", title: "Open a webpage", icon: "globe",
                  summary: "Open the Add Webpage sheet and enter an article URL.",
                  shortcut: "⌘L", keywords: ["url", "article", "browser", "add webpage", "sheet"]),
        HelpTopic(id: "new-tab", title: "New Tab", icon: "plus.rectangle.on.rectangle",
                  summary: "Open Home in a new tab without closing the current document.",
                  shortcut: "⌘T", keywords: ["home", "library"]),
        HelpTopic(id: "find", title: "Find in document", icon: "magnifyingglass",
                  summary: "Search the current PDF or webpage. Find next with ⌘G and previous with ⌘⇧G.",
                  shortcut: "⌘F", keywords: ["search", "text"]),
        HelpTopic(id: "bookmark", title: "Bookmark position", icon: "bookmark",
                  summary: "Remember the current PDF page or visible webpage position.",
                  shortcut: "⌘D", keywords: ["save", "position", "annotation"]),
        HelpTopic(id: "highlight-note", title: "Highlights and notes", icon: "highlighter",
                  summary: "Select source text to highlight it or attach a note. Use the inspector to review and jump back.",
                  shortcut: nil, keywords: ["annotation", "color", "comment"]),
        HelpTopic(id: "inspector", title: "Show or hide the inspector", icon: "sidebar.right",
                  summary: "Open Annotations, AI, and Scratchpad beside the document.",
                  shortcut: "⌘⌥S", keywords: ["sidebar", "annotations", "ai", "scratchpad"]),
        HelpTopic(id: "split-right", title: "Split pane right", icon: "rectangle.split.2x1",
                  summary: "Place another document beside the focused pane for comparison.",
                  shortcut: "⌘\\", keywords: ["compare", "pane"]),
        HelpTopic(id: "split-down", title: "Split pane down", icon: "rectangle.split.1x2",
                  summary: "Place another document below the focused pane.",
                  shortcut: "⌘⌥\\", keywords: ["compare", "pane"]),
        HelpTopic(id: "switch-tabs", title: "Switch tabs", icon: "rectangle.on.rectangle",
                  summary: "Jump directly with ⌘1–⌘9, or cycle with ⌘⇧[ and ⌘⇧].",
                  shortcut: "⌘1–⌘9", keywords: ["cycle", "next", "previous"]),
        HelpTopic(id: "web-storage", title: "Saved and offline webpages", icon: "externaldrive",
                  summary: "Keeping a webpage offline stores a snapshot. A bookmark only stores your reading position.",
                  shortcut: nil, keywords: ["storage", "snapshot", "saved", "library", "icloud"]),
        HelpTopic(id: "export", title: "Export and portability", icon: "square.and.arrow.up",
                  summary: "Export a web archive or a Vellum bundle with notes when you need a portable copy.",
                  shortcut: nil, keywords: ["archive", "bundle", "notes", "offline"]),
        HelpTopic(id: "ai-privacy", title: "AI context and privacy", icon: "sparkles",
                  summary: "AI is optional. Requests include recent conversation and automatic document context: title, visible-page metadata, current-page text and annotations, and a current-page image when applicable. Chips show only extra context you attach. Your provider handles the request under its policy.",
                  shortcut: nil, keywords: ["provider", "transmitted", "settings", "context", "conversation", "annotations", "image", "attachments"]),
        HelpTopic(id: "settings", title: "Settings", icon: "gearshape",
                  summary: "Choose appearance, reading, annotation, AI, and storage defaults.",
                  shortcut: "⌘,", keywords: ["preferences", "provider", "storage"])
    ]
}
