#if os(macOS) || os(iOS)
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A reader owner survives view disappearance until its tasks and resources drain.
struct EpubReaderView: View {
    let tabId: String
    let document: DocumentInfo
    let isActive: Bool
    @Environment(AppStore.self) private var app
    @Environment(AiStore.self) private var ai
    @Environment(AnnotationStore.self) private var annotations
    @Environment(ScratchpadStore.self) private var scratchpad
    @Environment(\.colorScheme) private var colorScheme
    @State private var reader = EpubReaderController()

    var body: some View {
        Group {
            if let session = app.sessions.documentSession(sessionId: tabId) as? EpubDocumentSession {
                VStack(spacing: 0) {
                    if let location = reader.location {
                        HStack(spacing: 0) {
                            EpubReaderBar(publication: session.publication, chapter: location.chapter,
                                go: { reader.go(chapter: $0, fragment: $1) })
                            #if os(iOS)
                            EpubReaderTools_iOS(reader: reader)
                            #endif
                            settingsMenu.padding(.trailing, 12)
                        }
                        .disabled(!isActive)
                        Divider()
                        EpubReaderSurface(reader: reader, session: session, location: location,
                            annotations: annotations.annotations, dark: colorScheme == .dark,
                            handwritingNotes: reader.handwritingNotes, pencilHighlighting: reader.pencilHighlighting)
                        if let anchor = reader.selectedAnchor, reader.isCurrent {
                            SelectionPopover(
                                selection: PdfTextSelection(text: anchor.quote,
                                    positionData: EpubReaderController.position(anchor),
                                    pageNumber: (session.publication.spineIndex(path: anchor.chapterHref) ?? location.chapter) + 1),
                                onClose: { reader.clearSelection() },
                                onEpubHighlight: { reader.annotate(type: .highlight, color: $0) },
                                onEpubNote: { reader.annotate(type: .note, note: $0) },
                                onEpubAI: { reader.askAI() },
                                onScratchpad: { reader.quoteToScratchpad() },
                                onHandwriting: handwritingAction(for: anchor),
                                initialNoteDraft: reader.selectionNoteDraft?.text,
                                onBeginNote: { reader.beginSelectionNote() },
                                onNoteDraftChange: { reader.updateSelectionNoteDraft($0, anchor: anchor) })
                            .id(anchor)
                            .padding(8)
                        }
                        if let notice = readerNotice {
                            Text(notice).font(.caption).foregroundStyle(.secondary).padding(8)
                        }
                    } else { ProgressView() }
                }
                .background(.background)
                .onAppear {
                    reader.bind(app: app, ai: ai, annotations: annotations, scratchpad: scratchpad,
                        session: session, tabId: tabId)
                    reader.activate(isActive)
                }
                .onChange(of: isActive) { _, active in reader.activate(active) }
                .onChange(of: app.activeDocumentBinding) { _, _ in reader.activate(isActive) }
                .onDisappear { reader.deactivate() }
            } else { EpubPendingReaderView(document: document) }
        }
        .accessibilityIdentifier("epub.reader")
    }

    private var settingsMenu: some View {
        Menu {
            Text("Font size")
            ForEach([12.0, 14, 16, 18, 20, 24, 28, 32, 36], id: \.self) { size in
                Button("\(Int(size)) pt\(reader.settings.fontSize == size ? " ✓" : "")") {
                    reader.changeSettings(fontSize: size, lineSpacing: reader.settings.lineSpacing)
                }
            }
            Divider()
            Text("Line spacing")
            ForEach([1.1, 1.3, 1.6, 1.9, 2.1, 2.4], id: \.self) { spacing in
                Button("\(spacing.formatted())\(reader.settings.lineSpacing == spacing ? " ✓" : "")") {
                    reader.changeSettings(fontSize: reader.settings.fontSize, lineSpacing: spacing)
                }
            }
        } label: {
            Image(systemName: "textformat.size")
                #if os(iOS)
                .frame(width: 44, height: 44).contentShape(Rectangle())
                #endif
        }
        #if os(macOS)
        .menuStyle(.borderlessButton)
        #endif
        .fixedSize()
        .help("Book typography")
        .accessibilityIdentifier("epub.settings")
    }

    private func handwritingAction(for anchor: EpubTextAnchor) -> (() -> Void)? {
        #if os(iOS)
        { reader.clearSelection(); reader.run { await reader.handwriting.create(anchor: anchor) } }
        #else
        nil
        #endif
    }

    private var readerNotice: String? {
        #if os(iOS)
        reader.handwriting.notice ?? reader.notice
        #else
        reader.notice
        #endif
    }
}

struct EpubReaderLocation: Equatable {
    var chapter: Int
    var progression: Double
    var fragment: String? = nil
    var anchor: EpubTextAnchor? = nil
    var request = UUID()
}

private struct EpubReaderBar: View {
    let publication: EpubPublication
    let chapter: Int
    let go: (Int, String?) -> Void

    private var chapterTitle: String {
        let path = publication.spine[chapter].path
        return Self.title(for: path, in: publication.toc) ?? "Chapter \(chapter + 1)"
    }

    private static func title(for path: String, in entries: [EpubPublication.TocEntry]) -> String? {
        for entry in entries {
            if entry.path == path { return entry.title }
            if let nested = title(for: path, in: entry.children) { return nested }
        }
        return nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                if publication.toc.isEmpty {
                    ForEach(publication.spine.indices, id: \.self) { index in
                        Button("Chapter \(index + 1)") { go(index, nil) }
                    }
                } else {
                    tocItems(publication.toc)
                }
            } label: {
                Label("Contents", systemImage: "list.bullet")
            }
            #if os(macOS)
            .menuStyle(.borderlessButton)
            #endif
            .fixedSize()
            .accessibilityIdentifier("epub.contents")

            Spacer()
            Text(chapterTitle)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(chapter + 1) of \(publication.spine.count)")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()

            Button { go(chapter - 1, nil) } label: {
                Image(systemName: "chevron.left")
                    #if os(iOS)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    #endif
            }
                .disabled(chapter == 0)
                .help("Previous chapter")
                .accessibilityIdentifier("epub.previousChapter")
            Button { go(chapter + 1, nil) } label: {
                Image(systemName: "chevron.right")
                    #if os(iOS)
                    .frame(width: 44, height: 44).contentShape(Rectangle())
                    #endif
            }
                .disabled(chapter >= publication.spine.count - 1)
                .help("Next chapter")
                .accessibilityIdentifier("epub.nextChapter")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private func tocItems(_ entries: [EpubPublication.TocEntry]) -> AnyView {
        AnyView(ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
            let target = entry.path.flatMap { publication.spineIndex(path: $0) }
            if entry.children.isEmpty {
                Button(entry.title) { if let target { go(target, entry.fragment) } }
                    .disabled(target == nil)
            } else {
                Menu(entry.title) {
                    if let target {
                        Button(entry.title) { go(target, entry.fragment) }
                        Divider()
                    }
                    tocItems(entry.children)
                }
            }
        })
    }
}

#if os(macOS)
final class EpubChapterWebView: WKWebView {
    var onChapterStep: ((Int) -> Void)?
    var readerActive = true
    private var keyMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeKeyMonitor()
        guard window != nil else { return }
        // Intercept before WebKit's content responder handles history navigation.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleChapterShortcut(event) == true ? nil : event
        }
    }

    func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    func handleChapterShortcut(_ event: NSEvent) -> Bool {
        if readerActive, let window, event.window === window, window.attachedSheet == nil,
           let responder = window.firstResponder as? NSView,
           responder === self || responder.isDescendant(of: self),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let onChapterStep {
            switch event.charactersIgnoringModifiers {
            case "[": onChapterStep(-1); return true
            case "]": onChapterStep(1); return true
            default: break
            }
        }
        return false
    }
}
#else
final class EpubChapterWebView: WKWebView {
    var onChapterStep: ((Int) -> Void)?
    var readerActive = true
    func removeKeyMonitor() {}
}
#endif

/// Serves archive resources of one open book under
/// `vellum-epub://book/<archive path>`, with a CSP that keeps book content
/// off the network and script-free.
@MainActor
final class EpubResourceSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "vellum-epub"
    nonisolated static let host = "book"
    nonisolated static let contentSecurityPolicy =
        "default-src 'none'; img-src vellum-epub: data:; media-src vellum-epub:; "
        + "font-src vellum-epub: data:; style-src vellum-epub: 'unsafe-inline'; script-src 'none'"

    let session: EpubDocumentSession
    private var active: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var cancelled: [Task<Void, Never>] = []

    init(session: EpubDocumentSession) {
        self.session = session
    }

    nonisolated static func url(for path: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + path
        return components.url ?? URL(string: "\(scheme)://\(host)/")!
    }

    nonisolated static func archivePath(for url: URL) -> String? {
        guard url.scheme == scheme, url.host == host else { return nil }
        let path = String(url.path.drop { $0 == "/" })
        return path.isEmpty ? nil : path
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        guard let url = task.request.url, let path = Self.archivePath(for: url) else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let mediaType = session.publication.manifestItem(path: path)?.mediaType
            ?? UTType(filenameExtension: (path as NSString).pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        active[id] = Task { [weak self, session] in
            let result: Result<Data, Error>
            do {
                result = .success(try await session.resourceData(at: path))
            } catch {
                result = .failure(error)
            }
            guard let self, self.active.removeValue(forKey: id) != nil, !Task.isCancelled else { return }
            switch result {
            case .success(let data):
                let response = HTTPURLResponse(
                    url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": mediaType,
                        "Content-Length": "\(data.count)",
                        "Content-Security-Policy": Self.contentSecurityPolicy,
                    ])!
                task.didReceive(response)
                task.didReceive(data)
                task.didFinish()
            case .failure:
                task.didFailWithError(URLError(.fileDoesNotExist))
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        if let task = active.removeValue(forKey: ObjectIdentifier(task)) {
            task.cancel(); cancelled.append(task)
        }
    }

    func cancelAll() {
        active.values.forEach { $0.cancel() }
        cancelled.append(contentsOf: active.values)
        active.removeAll()
    }

    func drain() async {
        cancelAll()
        for task in cancelled { await task.value }
        cancelled.removeAll()
    }
}
#endif
