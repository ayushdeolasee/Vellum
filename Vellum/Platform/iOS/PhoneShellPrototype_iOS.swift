#if os(iOS)
import PDFKit
import SwiftUI
import UIKit

// ============================================================================
// THROWAWAY PROTOTYPE — iPhone (compact width) navigation shell.
//
// This file exists to make the phone navigation grammar visible for a design
// discussion. Nothing here is wired to the real stores beyond what PDFKit needs
// to render: every list, annotation, chat message and tab card is fake data
// held in @State. Do not build on it; the shipping version should re-derive
// these screens from WorkspaceStore / AppStore properly.
//
// The four surfaces under discussion:
//   Home     — search-first, a LIST of recents / saved pages / read-later.
//   Reader   — one full-screen document, Liquid Glass chrome that auto-hides.
//   Inspector— a .sheet with [.medium, .large] detents, not a sidebar.
//   Tabs     — Safari-style 2-column card switcher.
// ============================================================================

// MARK: - Root gate

/// Branches the app root on horizontal size class. Compact (iPhone portrait)
/// gets the prototype phone shell; regular keeps the untouched iPad shell.
struct RootShell_iOS: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        if horizontalSizeClass == .compact {
            PhoneShellPrototype_iOS()
        } else {
            ContentView_iOS()
        }
    }
}

// MARK: - Fake library data

struct PhoneProtoDoc: Identifiable, Equatable {
    enum Kind: String {
        case paper, article, readLater

        var symbol: String {
            switch self {
            case .paper: "doc.text.fill"
            case .article: "globe"
            case .readLater: "clock.fill"
            }
        }
    }

    let id = UUID()
    let title: String
    let byline: String
    let kind: Kind
    let meta: String
    let hue: Double
}

enum PhoneProtoLibrary {
    static let all: [PhoneProtoDoc] = [
        .init(title: "Attention Is All You Need",
              byline: "Vaswani et al. · NeurIPS 2017",
              kind: .paper, meta: "15 pages · p.7", hue: 0.62),
        .init(title: "Deep Residual Learning for Image Recognition",
              byline: "He, Zhang, Ren, Sun",
              kind: .paper, meta: "12 pages · p.3", hue: 0.05),
        .init(title: "The Bitter Lesson",
              byline: "incompleteideas.net",
              kind: .article, meta: "Saved 2 days ago", hue: 0.10),
        .init(title: "A Mathematical Theory of Communication",
              byline: "Claude E. Shannon · 1948",
              kind: .paper, meta: "55 pages · p.21", hue: 0.55),
        .init(title: "Designing Data-Intensive Applications — Ch. 5",
              byline: "Martin Kleppmann",
              kind: .paper, meta: "38 pages · p.12", hue: 0.30),
        .init(title: "How Discord Stores Trillions of Messages",
              byline: "discord.com/blog",
              kind: .article, meta: "Saved last week", hue: 0.75),
        .init(title: "Denoising Diffusion Probabilistic Models",
              byline: "Ho, Jain, Abbeel",
              kind: .paper, meta: "25 pages · unread", hue: 0.48),
        .init(title: "The Unreasonable Effectiveness of Mathematics",
              byline: "Eugene Wigner · 1960",
              kind: .readLater, meta: "Added Tuesday", hue: 0.85),
        .init(title: "Notes on Structured Concurrency",
              byline: "vorpus.org",
              kind: .readLater, meta: "Added Tuesday", hue: 0.18),
        .init(title: "Chinchilla: Training Compute-Optimal LLMs",
              byline: "Hoffmann et al.",
              kind: .paper, meta: "30 pages · p.4", hue: 0.40),
        .init(title: "What Every Programmer Should Know About Memory",
              byline: "Ulrich Drepper",
              kind: .readLater, meta: "Added last month", hue: 0.68),
        .init(title: "Reflections on Trusting Trust",
              byline: "Ken Thompson · Turing Award Lecture",
              kind: .article, meta: "Saved last month", hue: 0.93),
    ]

    static var recents: [PhoneProtoDoc] { Array(all[0..<5]) }
    static var saved: [PhoneProtoDoc] { all.filter { $0.kind == .article } }
    static var readLater: [PhoneProtoDoc] { all.filter { $0.kind == .readLater } }
    /// The fake "open tabs" for the card switcher.
    static var openTabs: [PhoneProtoDoc] { Array(all[0..<6]) }
}

// MARK: - Shell

private enum PhoneProtoScreen {
    case home
    case reader(PhoneProtoDoc)
}

/// Prototype root. Owns which of the two full-screen surfaces is mounted and
/// whether the tab switcher is covering them.
struct PhoneShellPrototype_iOS: View {
    @Environment(WorkspaceStore.self) private var workspace
    @Environment(ThemeStore.self) private var themeStore
    @Environment(\.palette) private var palette
    @Environment(\.colorScheme) private var colorScheme

    @State private var screen: PhoneProtoScreen = .home
    @State private var showTabs = false
    @State private var showSettings = false
    /// Debug launch hooks so a headless simulator can be screenshotted in each
    /// state without synthesizing touches (same spirit as VELLUM_AUTOOPEN_*).
    @State private var readerStartsImmersive = false
    @State private var readerAutoInspector: PhoneInspectorTab?

    private var pane: PaneModel { workspace.focusedPane }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            switch screen {
            case .home:
                PhoneHomePrototype_iOS(
                    onOpen: { open($0) },
                    onTabs: { showTabs = true },
                    onSettings: { showSettings = true })
                .transition(.opacity)
            case .reader(let doc):
                PhoneReaderPrototype_iOS(
                    doc: doc,
                    startsImmersive: readerStartsImmersive,
                    autoInspector: readerAutoInspector,
                    onHome: { withAnimation(.snappy) { screen = .home } },
                    onTabs: { showTabs = true })
                .transition(.opacity)
            }
        }
        // The focused pane's store-triple, injected as an ancestor of everything
        // — PdfKitView_iOS reads AppStore/WorkspaceStore out of the environment.
        .environment(pane.app)
        .environment(pane.annotations)
        .environment(pane.ai)
        .environment(pane.scratchpad)
        .fullScreenCover(isPresented: $showTabs) {
            PhoneTabSwitcher_iOS(
                current: currentDoc,
                onSwitch: { doc in
                    showTabs = false
                    open(doc)
                },
                onNewTab: {
                    showTabs = false
                    withAnimation(.snappy) { screen = .home }
                },
                onDismiss: { showTabs = false })
        }
        .sheet(isPresented: $showSettings) {
            PhoneSettingsSheet_iOS()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: colorScheme, initial: true) { _, scheme in
            themeStore.systemAppearanceChanged(isDark: scheme == .dark)
        }
        #if DEBUG
        .task { applyLaunchState() }
        #endif
    }

    private var currentDoc: PhoneProtoDoc? {
        if case .reader(let doc) = screen { return doc }
        return nil
    }

    private func open(_ doc: PhoneProtoDoc) {
        withAnimation(.snappy) { screen = .reader(doc) }
    }

    #if DEBUG
    /// VELLUM_PROTO_STATE = home | reader | immersive | inspector | tabs
    private func applyLaunchState() {
        guard let state = ProcessInfo.processInfo.environment["VELLUM_PROTO_STATE"] else { return }
        let doc = PhoneProtoLibrary.all[0]
        switch state {
        case "reader":
            screen = .reader(doc)
        case "immersive":
            readerStartsImmersive = true
            screen = .reader(doc)
        case "inspector":
            readerAutoInspector = .ai
            screen = .reader(doc)
        case "tabs":
            showTabs = true
        default:
            break
        }
    }
    #endif
}

// MARK: - Home (search-first)

/// Search field pinned at the top, then one scrolling LIST of everything the
/// reader might want to reopen. Deliberately not a grid: on a phone the title
/// is the only thing that identifies a paper, and a grid starves it of width.
struct PhoneHomePrototype_iOS: View {
    var onOpen: (PhoneProtoDoc) -> Void
    var onTabs: () -> Void
    var onSettings: () -> Void

    @Environment(\.palette) private var palette
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    section("Continue Reading", PhoneProtoLibrary.recents)
                    section("Saved Pages", PhoneProtoLibrary.saved)
                    section("Read Later", PhoneProtoLibrary.readLater)
                }
                .padding(.bottom, 32)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .background(palette.background.ignoresSafeArea())
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Wordmark(size: 30)
            Spacer(minLength: 8)
            GlassToolPod {
                GlassToolButton(system: "square.on.square", label: "Tabs", action: onTabs)
                GlassToolButton(system: "gearshape", label: "Settings", action: onSettings)
            }
            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 14 }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(palette.mutedForeground)
            TextField("Search papers, pages, highlights", text: $query)
                .font(.system(size: 17))
                .foregroundStyle(palette.foreground)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 17))
                        .foregroundStyle(palette.mutedForeground)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, -12)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func section(_ title: String, _ docs: [PhoneProtoDoc]) -> some View {
        let filtered = docs.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
        }
        if !filtered.isEmpty {
            HStack {
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(palette.mutedForeground)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 8)

            ForEach(filtered) { doc in
                Button { onOpen(doc) } label: {
                    PhoneLibraryRow(doc: doc)
                }
                .buttonStyle(.plain)
                if doc.id != filtered.last?.id {
                    Divider()
                        .overlay(palette.border)
                        .padding(.leading, 76)
                }
            }
        }
    }
}

private struct PhoneLibraryRow: View {
    let doc: PhoneProtoDoc
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: Radius.md)
                    .fill(Color(hue: doc.hue, saturation: 0.30, brightness: 0.92))
                Image(systemName: doc.kind.symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(hue: doc.hue, saturation: 0.75, brightness: 0.42))
            }
            .frame(width: 44, height: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(doc.title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(doc.byline)
                    .font(.system(size: 13))
                    .foregroundStyle(palette.mutedForeground)
                    .lineLimit(1)
                Text(doc.meta)
                    .font(.system(size: 12))
                    .foregroundStyle(palette.mutedForeground.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(palette.mutedForeground.opacity(0.6))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Reader (full-screen, one document)

/// One document, no splits. The real PDFKit representable (PdfKitView_iOS) is
/// mounted so the design discussion sees genuine PDFKit layout at 390pt, with
/// the phone chrome floating over it.
struct PhoneReaderPrototype_iOS: View {
    let doc: PhoneProtoDoc
    var startsImmersive = false
    var autoInspector: PhoneInspectorTab?
    var onHome: () -> Void
    var onTabs: () -> Void

    @Environment(AppStore.self) private var app
    @Environment(AnnotationStore.self) private var annotationStore
    @Environment(AiStore.self) private var aiStore
    @Environment(\.palette) private var palette

    @State private var controller = PdfViewerControlleriOS()
    @State private var ink = InkController_iOS()
    @State private var pdf: PDFDocument?
    @State private var chromeVisible = true
    @State private var inspectorTab: PhoneInspectorTab = .annotations
    @State private var inspectorPresented = false
    @State private var bookmarked = false

    /// US Letter width in points — what PhoneProtoPdf renders at.
    private static let letterPageWidth: CGFloat = 612

    var body: some View {
        GeometryReader { geo in
            ZStack {
                palette.well.ignoresSafeArea()

                if let pdf {
                    PdfKitView_iOS(controller: controller, document: pdf, ink: ink)
                        .ignoresSafeArea()
                        // Simultaneous so PDFKit keeps its own scroll / selection /
                        // double-tap-zoom recognizers; this only adds the
                        // immersive-mode toggle on a plain single tap.
                        .simultaneousGesture(
                            TapGesture().onEnded {
                                withAnimation(.snappy(duration: 0.22)) { chromeVisible.toggle() }
                            })
                } else {
                    ProgressView().controlSize(.large)
                }

                VStack(spacing: 0) {
                    topBar
                    Spacer(minLength: 0)
                    bottomBar
                }
                .opacity(chromeVisible ? 1 : 0)
                .animation(.snappy(duration: 0.22), value: chromeVisible)
                .allowsHitTesting(chromeVisible)
            }
            // FINDING: PdfKitView_iOS sets `autoScales = false` and drives
            // scaleFactor purely from AppStore.zoom, which the iPad shell leaves
            // at 1.0 (one point per PDF point). That's fine at 1024pt, but a
            // Letter page is 612pt wide, so at 390pt the page overhangs the
            // screen and the reader opens mid-column. The phone needs a
            // fit-width default; the shipping version should teach the viewer a
            // real fit-width mode rather than poking the zoom like this.
            .onChange(of: geo.size.width, initial: true) { _, width in
                guard width > 0 else { return }
                app.setZoom(width / Self.letterPageWidth)
            }
        }
        .statusBarHidden(!chromeVisible)
        .task { await loadPdf() }
        .sheet(isPresented: $inspectorPresented) {
            PhoneInspectorSheet_iOS(tab: $inspectorTab, docTitle: doc.title)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack(spacing: 8) {
            GlassToolPod {
                GlassToolButton(system: "chevron.backward", label: "Library", action: onHome)
            }
            Text(doc.title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.foreground)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 14)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            // Page indicator — tap target is the whole capsule.
            GlassToolPod {
                Text("\(app.currentPage) / \(max(app.numPages, 1))")
                    .font(.system(size: 14, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(palette.foreground)
                    .frame(minWidth: 58, minHeight: 44)
                    .contentShape(Rectangle())
            }

            GlassToolPod {
                GlassToolButton(
                    system: bookmarked ? "bookmark.fill" : "bookmark",
                    label: "Bookmark",
                    tint: bookmarked ? palette.gold : nil
                ) { bookmarked.toggle() }
                GlassToolButton(system: "note.text", label: "Sticky note") {}
            }

            Spacer(minLength: 0)

            GlassToolPod {
                GlassToolButton(system: "sidebar.right", label: "Inspector") {
                    inspectorPresented = true
                }
                GlassToolButton(system: "square.on.square", label: "Tabs", action: onTabs)
                Menu {
                    Button("Share…", systemImage: "square.and.arrow.up") {}
                    Button("Find in Document", systemImage: "magnifyingglass") {}
                    Button("Table of Contents", systemImage: "list.bullet.indent") {}
                    Divider()
                    Button("Close Document", systemImage: "xmark", action: onHome)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(palette.foreground)
                        .frame(width: 44, height: 44)
                        .contentShape(Circle())
                }
                .accessibilityLabel("More")
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    // MARK: PDF

    private func loadPdf() async {
        chromeVisible = !startsImmersive
        if let autoInspector {
            inspectorTab = autoInspector
            inspectorPresented = true
        }
        guard pdf == nil else { return }
        let title = doc.title
        let byline = doc.byline
        let prepared = await Task.detached(priority: .userInitiated) {
            PhoneProtoPdf.make(title: title, byline: byline)
        }.value
        guard let document = prepared.document else { return }
        controller.adopt(
            document: document,
            app: app,
            annotationStore: annotationStore,
            ai: aiStore,
            initialPage: 1)
        ink.pdfController = controller
        ink.app = app
        ink.isActive = false
        app.setNumPages(document.pageCount)
        pdf = document
    }
}

// MARK: - Runtime-generated PDF

/// PDFDocument isn't Sendable; this one is created inside the detached task and
/// never touched off-main afterwards.
private struct PreparedProtoPdf: @unchecked Sendable {
    let document: PDFDocument?
}

private enum PhoneProtoPdf {
    private static let body = """
    Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod \
    tempor incididunt ut labore et dolore magna aliqua. Ut enim ad minim veniam, \
    quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo \
    consequat. Duis aute irure dolor in reprehenderit in voluptate velit esse \
    cillum dolore eu fugiat nulla pariatur.
    """

    private static let body2 = """
    Excepteur sint occaecat cupidatat non proident, sunt in culpa qui officia \
    deserunt mollit anim id est laborum. Sed ut perspiciatis unde omnis iste \
    natus error sit voluptatem accusantium doloremque laudantium, totam rem \
    aperiam, eaque ipsa quae ab illo inventore veritatis et quasi architecto \
    beatae vitae dicta sunt explicabo.
    """

    static func make(title: String, byline: String) -> PreparedProtoPdf {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let margin: CGFloat = 64
        let contentWidth = bounds.width - margin * 2
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)

        let data = renderer.pdfData { context in
            for page in 1...4 {
                context.beginPage()
                UIColor.white.setFill()
                UIRectFill(bounds)
                var y: CGFloat = margin

                if page == 1 {
                    y += draw(title, font: .systemFont(ofSize: 22, weight: .bold),
                              color: .black, x: margin, y: y, width: contentWidth,
                              alignment: .center)
                    y += 8
                    y += draw(byline, font: .systemFont(ofSize: 12),
                              color: .darkGray, x: margin, y: y, width: contentWidth,
                              alignment: .center)
                    y += 24
                    y += draw("Abstract", font: .systemFont(ofSize: 13, weight: .semibold),
                              color: .black, x: margin, y: y, width: contentWidth,
                              alignment: .natural)
                    y += 6
                }

                for index in 0..<4 {
                    y += draw("\(page).\(index + 1)  Section heading",
                              font: .systemFont(ofSize: 13, weight: .semibold),
                              color: .black, x: margin, y: y, width: contentWidth,
                              alignment: .natural)
                    y += 6
                    y += draw(index.isMultiple(of: 2) ? body : body2,
                              font: .systemFont(ofSize: 11),
                              color: .black, x: margin, y: y, width: contentWidth,
                              alignment: .justified)
                    y += 14
                    if y > bounds.height - margin - 80 { break }
                }

                _ = draw("\(page)", font: .systemFont(ofSize: 10), color: .gray,
                         x: margin, y: bounds.height - margin + 12,
                         width: contentWidth, alignment: .center)
            }
        }
        return PreparedProtoPdf(document: PDFDocument(data: data))
    }

    @discardableResult
    private static func draw(
        _ string: String, font: UIFont, color: UIColor,
        x: CGFloat, y: CGFloat, width: CGFloat, alignment: NSTextAlignment
    ) -> CGFloat {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2.5
        paragraph.alignment = alignment
        let attributed = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let options: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let measured = attributed.boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: options, context: nil)
        let height = ceil(measured.height)
        attributed.draw(
            with: CGRect(x: x, y: y, width: width, height: height),
            options: options, context: nil)
        return height
    }
}

// MARK: - Inspector sheet

enum PhoneInspectorTab: String, CaseIterable, Identifiable {
    case annotations, ai, scratchpad
    var id: String { rawValue }
    var label: String {
        switch self {
        case .annotations: "Annotations"
        case .ai: "AI"
        case .scratchpad: "Scratchpad"
        }
    }
}

/// The iPad's inspector sidebar, restated as a detented sheet. Medium is the
/// "glance" state (skim highlights, read one AI answer); large is the working
/// state. The segmented switcher stays pinned so the sheet never loses its
/// identity when it grows.
struct PhoneInspectorSheet_iOS: View {
    @Binding var tab: PhoneInspectorTab
    let docTitle: String

    @Environment(\.palette) private var palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $tab) {
                ForEach(PhoneInspectorTab.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)

            Divider().overlay(palette.border)

            switch tab {
            case .annotations: annotations
            case .ai: ai
            case .scratchpad: scratchpad
            }
        }
        .background(palette.background)
    }

    // MARK: Annotations

    private struct FakeHighlight: Identifiable {
        let id = UUID()
        let page: Int
        let color: KeyPath<ThemePalette, Color>
        let text: String
        let note: String?
    }

    private var fakeHighlights: [FakeHighlight] {
        [
            .init(page: 1, color: \.highlightYellow,
                  text: "The dominant sequence transduction models are based on complex recurrent or convolutional neural networks.",
                  note: "Framing — worth quoting."),
            .init(page: 2, color: \.highlightBlue,
                  text: "We propose a new simple network architecture, the Transformer, based solely on attention mechanisms.",
                  note: nil),
            .init(page: 3, color: \.highlightGreen,
                  text: "Experiments on two machine translation tasks show these models to be superior in quality.",
                  note: "Check the BLEU numbers against Table 2."),
            .init(page: 3, color: \.highlightPink,
                  text: "Self-attention, sometimes called intra-attention, relates different positions of a single sequence.",
                  note: nil),
            .init(page: 4, color: \.highlightPurple,
                  text: "We also show that the Transformer generalizes well to other tasks.",
                  note: nil),
        ]
    }

    private var annotations: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(fakeHighlights) { highlight in
                    HStack(alignment: .top, spacing: 12) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(palette[keyPath: highlight.color])
                            .frame(width: 4)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Page \(highlight.page)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(palette.mutedForeground)
                            Text(highlight.text)
                                .font(.system(size: 14))
                                .foregroundStyle(palette.foreground)
                            if let note = highlight.note {
                                Text(note)
                                    .font(.system(size: 13))
                                    .italic()
                                    .foregroundStyle(palette.mutedForeground)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(palette.border).padding(.leading, 34)
                }
            }
            .padding(.bottom, 24)
        }
    }

    // MARK: AI

    private var ai: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Context: \(docTitle) · pages 1–4")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(palette.mutedForeground)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(palette.muted, in: .capsule)
                        .frame(maxWidth: .infinity, alignment: .center)

                    bubble(
                        "What's the core claim of section 3.2, in one sentence?",
                        isUser: true)
                    bubble(
                        """
                        Section 3.2 argues that scaled dot-product attention is \
                        preferable to additive attention because it can be \
                        implemented as a single matrix multiply — far faster and \
                        more memory-efficient in practice — with the 1/√d_k scaling \
                        factor added to keep the softmax out of its \
                        vanishing-gradient regime for large key dimensions.
                        """,
                        isUser: false)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 16)
            }

            composer
        }
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(text)
                .font(.system(size: 14))
                .foregroundStyle(isUser ? palette.primaryForeground : palette.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser ? palette.primary : palette.surface,
                    in: .rect(cornerRadius: Radius.xl))
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xl)
                        .strokeBorder(isUser ? .clear : palette.border, lineWidth: 1))
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .font(.system(size: 17))
                .foregroundStyle(palette.mutedForeground)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
            Text("Ask about this page…")
                .font(.system(size: 15))
                .foregroundStyle(palette.mutedForeground)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(palette.primary.opacity(0.4))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .padding(.horizontal, 8)
        .background(palette.surface)
        .overlay(alignment: .top) { Divider().overlay(palette.border) }
    }

    // MARK: Scratchpad

    private var scratchpad: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("""
                # Reading notes

                - Attention replaces recurrence entirely — no sequential \
                dependency, so the whole sequence trains in parallel.
                - Positional encodings are sinusoidal, not learned. Ask why.
                - Multi-head = h parallel projections into d_k; concatenate, \
                project back. Cheap because each head is narrow.

                > "…based solely on attention mechanisms, dispensing with \
                recurrence and convolutions entirely."

                TODO: sketch the encoder block and compare to the ResNet paper's \
                residual + norm ordering.
                """)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(palette.foreground)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
        }
        .background(palette.surfaceMuted)
    }
}

// MARK: - Settings sheet (stub)

struct PhoneSettingsSheet_iOS: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Appearance") {
                    LabeledContent("Theme", value: "System")
                    LabeledContent("Page background", value: "Parchment")
                }
                Section("Reading") {
                    LabeledContent("Default zoom", value: "Fit width")
                    LabeledContent("Two-finger note tap", value: "On")
                }
                Section("AI") {
                    LabeledContent("Model", value: "Claude Opus 4.5")
                    LabeledContent("Context", value: "Visible pages")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Tab switcher (Safari-style cards)

/// Two-column card grid. Each card is a fake thumbnail (a tinted page block
/// with skeleton text lines) plus the document title beneath it, so the switcher
/// reads at a glance instead of forcing a title-only list.
struct PhoneTabSwitcher_iOS: View {
    var current: PhoneProtoDoc?
    var onSwitch: (PhoneProtoDoc) -> Void
    var onNewTab: () -> Void
    var onDismiss: () -> Void

    @Environment(\.palette) private var palette

    private let columns = [
        GridItem(.flexible(), spacing: 14),
        GridItem(.flexible(), spacing: 14),
    ]

    var body: some View {
        ZStack {
            palette.well.ignoresSafeArea()

            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(PhoneProtoLibrary.openTabs) { doc in
                        Button { onSwitch(doc) } label: {
                            TabCard(doc: doc, isCurrent: doc.id == current?.id)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 64)
                .padding(.bottom, 150)
            }

            VStack {
                HStack {
                    Text("\(PhoneProtoLibrary.openTabs.count) Documents")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, 16)
                        .frame(height: 48)
                        .glassEffect(.regular, in: .capsule)
                    Spacer()
                }
                .padding(.horizontal, 12)
                Spacer()
                HStack {
                    GlassToolPod {
                        GlassToolButton(system: "plus", label: "New tab", action: onNewTab)
                    }
                    Spacer()
                    Button("Done", action: onDismiss)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(palette.foreground)
                        .padding(.horizontal, 18)
                        .frame(height: 48)
                        .glassEffect(.regular, in: .capsule)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }

    private struct TabCard: View {
        let doc: PhoneProtoDoc
        let isCurrent: Bool
        @Environment(\.palette) private var palette

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: Radius.xl)
                        .fill(Color(hue: doc.hue, saturation: 0.16, brightness: 0.98))
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color(hue: doc.hue, saturation: 0.55, brightness: 0.55))
                            .frame(height: 8)
                            .frame(maxWidth: .infinity)
                        ForEach(0..<9, id: \.self) { row in
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(Color.black.opacity(0.16))
                                .frame(height: 3.5)
                                .padding(.trailing, row.isMultiple(of: 4) ? 34 : 0)
                        }
                    }
                    .padding(14)
                }
                .frame(height: 190)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.xl)
                        .strokeBorder(
                            isCurrent ? palette.primary : palette.border,
                            lineWidth: isCurrent ? 2.5 : 1))
                .overlay(alignment: .topTrailing) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.45))
                        .padding(8)
                }

                Text(doc.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(palette.foreground)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
#endif
