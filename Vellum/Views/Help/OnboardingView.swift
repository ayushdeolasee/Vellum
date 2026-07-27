import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @Environment(\.palette) private var palette
    @State private var selectedStep = 0

    private let steps = OnboardingStep.all

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 680, height: 500)
        .background(palette.background)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "book.pages")
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 36, height: 36)
                .glassEffect(.regular, in: .rect(cornerRadius: Radius.lg))

            VStack(alignment: .leading, spacing: 1) {
                Wordmark(size: 20)
                Text("A two-minute guide to reading in Vellum")
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground)
            }

            Spacer()

            Text("Step \(selectedStep + 1) of \(steps.count)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(palette.mutedForeground)
                .accessibilityLabel("Step \(selectedStep + 1) of \(steps.count)")
        }
        .padding(20)
    }

    private var content: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                    Button {
                        selectedStep = index
                    } label: {
                        HStack(spacing: 9) {
                            Image(systemName: step.icon)
                                .frame(width: 18)
                            Text(step.shortTitle)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 12, weight: index == selectedStep ? .semibold : .regular))
                        .foregroundStyle(index == selectedStep ? palette.primary : palette.mutedForeground)
                        .padding(.horizontal, 10)
                        .frame(height: 34)
                        .selectionSurface(
                            selected: index == selectedStep,
                            in: RoundedRectangle(cornerRadius: Radius.md),
                            palette: palette)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(step.shortTitle), step \(index + 1)")
                    .accessibilityAddTraits(index == selectedStep ? .isSelected : [])
                    .accessibilityIdentifier("onboarding.step.\(index + 1)")
                }
                Spacer()
            }
            .padding(16)
            .frame(width: 180)
            .background(palette.surfaceMuted)

            stepDetail(steps[selectedStep])
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func stepDetail(_ step: OnboardingStep) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: step.icon)
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.tint)
                    .frame(width: 58, height: 58)
                    .glassEffect(.regular, in: .rect(cornerRadius: Radius.xl))

                VStack(alignment: .leading, spacing: 7) {
                    Text(step.title)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                    Text(step.introduction)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 11) {
                    ForEach(step.points, id: \.self) { point in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(.tint)
                                .padding(.top, 2)
                                .accessibilityHidden(true)
                            Text(point)
                                .font(.system(size: 13))
                                .foregroundStyle(palette.foreground)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if let note = step.note {
                    Label(note, systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(palette.mutedForeground)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(palette.surfaceMuted, in: RoundedRectangle(cornerRadius: Radius.lg))
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding.detail.\(selectedStep + 1)")
    }

    private var footer: some View {
        HStack {
            Button("Skip tour") {
                onFinish()
            }
            .buttonStyle(.borderless)
            .foregroundStyle(palette.mutedForeground)
            .keyboardShortcut(.cancelAction)
            .accessibilityHint("Closes the tour. You can replay it from the Help menu.")
            .accessibilityIdentifier("onboarding.skip")

            Spacer()

            if selectedStep > 0 {
                Button("Back") {
                    selectedStep -= 1
                }
                .keyboardShortcut(.leftArrow, modifiers: [.command])
                .accessibilityIdentifier("onboarding.back")
            }

            Button(selectedStep == steps.count - 1 ? "Start reading" : "Next") {
                if selectedStep == steps.count - 1 {
                    onFinish()
                } else {
                    selectedStep += 1
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .keyboardShortcut(.rightArrow, modifiers: [.command])
            .accessibilityIdentifier(
                selectedStep == steps.count - 1 ? "onboarding.finish" : "onboarding.next")
        }
        .padding(16)
    }
}

struct OnboardingStep: Identifiable, Equatable {
    let id: String
    let shortTitle: String
    let title: String
    let icon: String
    let introduction: String
    let points: [String]
    let note: String?

    static let all: [OnboardingStep] = [
        OnboardingStep(
            id: "open",
            shortTitle: "Open",
            title: "Bring in something to read",
            icon: "doc.badge.plus",
            introduction: "Vellum keeps PDFs and webpages together in one quiet reading workspace.",
            points: [
                "Open one or more PDFs with ⌘O, or paste an article URL on a New Tab.",
                "Recent documents and webpages you keep are available from the Home library.",
                "Use the plus menu to add a tab without leaving what you are reading."
            ],
            note: nil),
        OnboardingStep(
            id: "annotate",
            shortTitle: "Annotate",
            title: "Mark the source, not a copy",
            icon: "highlighter",
            introduction: "Highlights, notes, and bookmarks stay attached to the document they came from.",
            points: [
                "Select text to highlight it, choose a color, or turn the selection into a note.",
                "Use the note tool for a thought that belongs at a specific place.",
                "Bookmark the current PDF page or webpage position with ⌘D, then jump back from Annotations."
            ],
            note: "Annotations are separate from the Scratchpad, which is best for longer working notes."),
        OnboardingStep(
            id: "ai",
            shortTitle: "AI & privacy",
            title: "AI is optional and explicit",
            icon: "sparkles",
            introduction: "Reading and annotation work without an AI provider. Configure one later in Settings ▸ AI.",
            points: [
                "Vellum sends only the prompt, attachments, and document excerpts needed for a request.",
                "Reference chips show what context will be included before you send.",
                "Your provider receives that request under its own privacy and retention policy."
            ],
            note: "Provider setup never blocks this tour or the core reading workflow."),
        OnboardingStep(
            id: "storage",
            shortTitle: "Storage",
            title: "Know what stays where",
            icon: "externaldrive",
            introduction: "Your source PDFs remain files you control; Vellum stores reading data alongside its local app data.",
            points: [
                "Choose local or iCloud storage for saved webpages and document data.",
                "Keeping a webpage offline stores a snapshot; a bookmark only records a reading position.",
                "Export creates a portable copy. Web archives and bundles with notes serve different purposes."
            ],
            note: "Settings ▸ Storage shows the active location, retention, and per-document usage."),
        OnboardingStep(
            id: "navigate",
            shortTitle: "Navigate",
            title: "Move quickly when the work grows",
            icon: "rectangle.split.2x1",
            introduction: "Tabs and panes let you compare sources without turning Vellum into a window-management exercise.",
            points: [
                "Use ⌘T for a New Tab, ⌘1–⌘9 to jump to a tab, and ⌘⇧[ or ⌘⇧] to cycle.",
                "Use ⌘\\ to split right and ⌘⌥\\ to split down.",
                "Search the current document with ⌘F. Open Vellum Help for the complete searchable feature and shortcut guide."
            ],
            note: "Replay this tour any time from Help ▸ Show Welcome Tour.")
    ]
}
