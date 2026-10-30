#if os(macOS) || os(iOS)
import Foundation
import Observation
import WebKit

@MainActor @Observable
final class EpubReaderController {
    private(set) var location: EpubReaderLocation?
    private(set) var selection: EpubTextAnchor?
    private var selectionNoteDrafts: [EpubTextAnchor: String] = [:]
    var selectedAnchor: EpubTextAnchor? { selection }
    var selectionNoteDraft: EpubSelectionNoteDraft? {
        guard let selection, let text = selectionNoteDrafts[selection] else { return nil }
        return EpubSelectionNoteDraft(anchor: selection, text: text)
    }
    private(set) var unresolved: Set<String> = []
    var notice: String?
    var settings = EpubReaderSettings.load()
    private(set) var searchResults: [EpubSearchResult] = []
    private(set) var searchIndex = 0
    private(set) var searchTruncated = false
    private(set) var active = false
    private var app: AppStore?
    private var ai: AiStore?
    private var annotations: AnnotationStore?
    private var scratchpad: ScratchpadStore?
    private(set) var binding: DocumentBinding?
    private(set) var session: EpubDocumentSession?
    weak var webView: WKWebView?
    var drainResources: (() async -> Void)?
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var activation = UUID()
    private var registeredAI = false
    private let handlerToken = UUID()
    #if os(iOS)
    let handwriting = EpubHandwritingController_iOS()
    #endif
    var pencilHighlighting = false
    var pencilHighlightColor = WorkspaceStore.storedDefaultHighlightColor()
    var handwritingNotes: [EpubHandwritingNote] {
        #if os(iOS)
        handwriting.notes
        #else
        []
        #endif
    }

    var isCurrent: Bool {
        active && binding != nil && app?.activeDocumentBinding == binding
    }

    func bind(app: AppStore, ai: AiStore, annotations: AnnotationStore, scratchpad: ScratchpadStore,
              session: EpubDocumentSession, tabId: String) {
        guard binding == nil, let binding = app.documentBinding(for: tabId) else { return }
        self.app = app; self.ai = ai; self.annotations = annotations; self.scratchpad = scratchpad
        self.session = session; self.binding = binding
        #if os(iOS)
        handwriting.bind(session: session)
        #endif
        app.registerEpubReader(binding: binding, deactivate: { [weak self] in self?.deactivate() },
            drain: { [self] in await drain() }, close: { [self] in await close() })
    }

    func activate(_ enabled: Bool) {
        guard enabled, let app, let session, let binding, app.activeDocumentBinding == binding else {
            deactivate(); return
        }
        active = true
        #if os(iOS)
        handwriting.readerActive = true
        #endif
        if !registeredAI { registeredAI = ai?.registerEpubSession(session, binding: binding) == true }
        app.epubHandlerOwner = binding
        app.epubHandlerToken = handlerToken
        app.scrollToPageHandler = { [weak self] page in self?.go(chapter: page - 1) }
        app.scrollToEpubAnchorHandler = { [weak self] anchor, chapter in self?.go(chapter: chapter - 1, anchor: anchor) }
        app.referenceEpubAnnotationHandler = { [weak self] annotation in
            guard let anchor = annotation.positionData?.epubAnchor else { return }
            self?.askAI(anchor: anchor, chapter: annotation.pageNumber, highlight: annotation.type == .highlight)
        }
        app.findQueryHandler = { [weak self] query in self?.search(query) }
        app.findStepHandler = { [weak self] step in self?.stepSearch(step) }
        app.findClearHandler = { [weak self] in self?.clearSearch() }
        annotations?.captureEpubPositionHandler = { [weak self] in
            guard let self, self.isCurrent, let anchor = self.selectedAnchor ?? self.app?.tab(id: binding.tabId)?.epubLocation?.textAnchor,
                  let chapter = self.session?.publication.spineIndex(path: anchor.chapterHref) else { return nil }
            return CapturedWebPosition(pageNumber: chapter + 1, positionData: Self.position(anchor))
        }
        if let pending = app.takePendingEpubCitation(binding: binding) {
            go(chapter: pending.chapterNumber - 1, anchor: pending.anchor)
        } else if location == nil {
            let generation = activation
            run { [self] in
                let saved = await app.epubResumeLocation(tabId: binding.tabId)
                guard isCurrent, activation == generation, location == nil else { return }
                let chapter = saved.flatMap { session.publication.spineIndex(path: $0.chapterHref) }
                    ?? max(0, min(session.publication.spine.count - 1, (app.tab(id: binding.tabId)?.currentPage ?? 1) - 1))
                location = EpubReaderLocation(chapter: chapter, progression: saved?.progression ?? 0,
                    anchor: saved?.textAnchor)
            }
        } else if !app.findQuery.isEmpty { search(app.findQuery) }
    }

    func deactivate() {
        active = false; activation = UUID()
        #if os(iOS)
        handwriting.readerActive = false
        handwriting.isPresented = false
        #endif
        if selectionNoteDraft == nil { selection = nil }
        searchGeneration = UUID(); tasks.values.forEach { $0.cancel() }
        if let binding {
            if registeredAI { ai?.unregisterEpubSession(binding: binding); registeredAI = false }
            if app?.epubHandlerOwner == binding, app?.epubHandlerToken == handlerToken {
                app?.epubHandlerOwner = nil
                app?.epubHandlerToken = nil
                app?.scrollToPageHandler = nil; app?.scrollToEpubAnchorHandler = nil
                app?.referenceEpubAnnotationHandler = nil
                app?.findQueryHandler = nil; app?.findStepHandler = nil; app?.findClearHandler = nil
                annotations?.captureEpubPositionHandler = nil
            }
        }
    }

    /// Reader work may join persistence but never awaits tab teardown itself.
    @discardableResult func drain() async -> Bool {
        while !tasks.isEmpty { for task in Array(tasks.values) { await task.value } }
        await ai?.awaitCancelledRequests()
        #if os(iOS)
        return await handwriting.flushPendingInkAndWait()
        #else
        return true
        #endif
    }

    @discardableResult func close() async -> Bool {
        deactivate()
        guard await drain() else { return false }
        await drainResources?()
        webView = nil
        return true
    }

    func run(_ work: @escaping @MainActor () async -> Void) {
        let id = UUID()
        tasks[id] = Task { [self] in
            defer { tasks[id] = nil }
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    func go(chapter: Int, fragment: String? = nil, anchor: EpubTextAnchor? = nil) {
        guard isCurrent, let session, let binding, session.publication.spine.indices.contains(chapter) else { return }
        guard anchor == nil || anchor?.chapterHref == session.publication.spine[chapter].path else { return }
        selection = nil; notice = nil
        location = EpubReaderLocation(chapter: chapter, progression: 0, fragment: fragment, anchor: anchor)
        app?.setEpubLocation(tabId: binding.tabId, chapter: chapter + 1, progression: 0, anchor: anchor)
    }

    func progress(_ message: EpubReaderMessage) {
        guard isCurrent, let location, let binding, let value = message.value else { return }
        app?.setEpubLocation(tabId: binding.tabId, chapter: location.chapter + 1, progression: value, anchor: message.anchor)
    }

    func receive(_ message: EpubReaderMessage) {
        guard isCurrent, let location, let session, message.token == location.request.uuidString,
              message.href == session.publication.spine[location.chapter].path else { return }
        switch message.type {
        #if os(iOS)
        case "pencilHighlight":
            guard pencilHighlighting, let anchor = message.anchor else { return }
            selection = anchor
            annotate(type: .highlight, color: pencilHighlightColor)
        #endif
        case "progress": progress(message)
        case "selection":
            if message.anchor != nil || selectionNoteDraft == nil { selection = message.anchor }
        case "annotation":
            #if os(iOS)
            if let id = message.id, id.hasPrefix("ink:"),
               let note = handwriting.notes.first(where: { "ink:" + $0.id == id }) {
                run { [self] in await handwriting.open(note) }
                return
            }
            #endif
            guard let id = message.id, annotations?.annotations.contains(where: { $0.id == id }) == true else { return }
            annotations?.selectAnnotation(id, scrollIntoView: false)
            app?.workspace?.revealSidebarTab(.annotations)
        case "unresolved":
            unresolved = Set((message.unresolved ?? []).filter { !$0.hasPrefix("ink:") })
            annotations?.unresolvedEpubAnnotationIds = unresolved
        case "unresolvedLocation": notice = "This passage could not be located unambiguously. Showing the saved chapter position."
        default: break
        }
    }

    func changeSettings(fontSize: Double, lineSpacing: Double) {
        settings = EpubReaderSettings(fontSize: fontSize, lineSpacing: lineSpacing)
        settings.save()
    }

    static func position(_ anchor: EpubTextAnchor) -> PositionData {
        PositionData(rects: [], pageWidth: 0, pageHeight: 0, selectedText: anchor.quote, epubAnchor: anchor)
    }

    func annotate(type: AnnotationType, color: String? = nil, note: String? = nil) {
        guard isCurrent, let anchor = selectedAnchor, let location, let annotations, let session,
              let chapter = session.publication.spineIndex(path: anchor.chapterHref) else { return }
        let request = location.request
        let input = CreateAnnotationInput(type: type, pageNumber: chapter + 1, color: color,
            content: note, positionData: Self.position(anchor))
        clearSelection()
        run { [self] in
            guard isCurrent, self.location?.request == request else { return }
            let annotation = type == .highlight ? await annotations.addHighlight(input) : await annotations.addNote(input)
            guard isCurrent, self.location?.request == request else { return }
            if let annotation, type == .note {
                annotations.selectAnnotation(annotation.id, scrollIntoView: false)
                app?.workspace?.revealSidebarTab(.annotations)
            }
        }
    }

    func askAI(anchor: EpubTextAnchor? = nil, chapter: Int? = nil, highlight: Bool = false) {
        // Capture the composer identity before any asynchronous selection work.
        guard isCurrent, let ai, let target = ai.currentReferenceTarget(), let location,
              let anchor = anchor ?? selectedAnchor else { return }
        let request = location.request
        let chapter = chapter ?? session?.publication.spineIndex(path: anchor.chapterHref).map { $0 + 1 } ?? location.chapter + 1
        clearSelection()
        run { [self] in
            guard isCurrent, self.location?.request == request else { return }
            let added = await ai.addEpubReference(anchor: anchor, chapterNumber: chapter, highlight: highlight, target: target)
            guard isCurrent, self.location?.request == request else { return }
            if !added { notice = "The passage could not be attached to the current AI conversation." }
        }
    }

    func quoteToScratchpad() {
        guard isCurrent, let anchor = selectedAnchor, let scratchpad, scratchpad.editorAcceptsChanges else { return }
        let quote = anchor.quote.components(separatedBy: .newlines).map { "> \($0)" }.joined(separator: "\n")
        scratchpad.text += (scratchpad.text.isEmpty ? "" : "\n\n") + quote + "\n"
        clearSelection()
    }

    func beginSelectionNote() {
        guard isCurrent, let anchor = selection else { return }
        if selectionNoteDrafts[anchor] == nil { selectionNoteDrafts[anchor] = "" }
        #if os(iOS)
        webView?.endEditing(true)
        #endif
    }

    func updateSelectionNoteDraft(_ text: String, anchor: EpubTextAnchor) {
        guard isCurrent, selectionNoteDrafts[anchor] != nil else { return }
        selectionNoteDrafts[anchor] = text
    }

    func clearSelection() {
        if let selection { selectionNoteDrafts.removeValue(forKey: selection) }
        selection = nil
    }

    private func clearSearch() {
        searchGeneration = UUID(); searchTask?.cancel(); searchTask = nil
        searchResults = []; searchIndex = 0; searchTruncated = false
        if isCurrent { app?.setFindSearching(false); app?.setFindResults(count: 0, current: 0); app?.setFindTruncated(false) }
    }

    private func search(_ query: String) {
        clearSearch()
        guard isCurrent, let session, !query.isEmpty else { return }
        let generation = searchGeneration
        app?.setFindSearching(true)
        let id = UUID()
        let task = Task { [self] in
            defer { tasks[id] = nil }
            do {
                let response = try await session.search(query: query, limit: 500)
                guard !Task.isCancelled, isCurrent, searchGeneration == generation else { return }
                searchResults = response.results; searchTruncated = response.truncated
                app?.setFindSearching(false); app?.setFindTruncated(response.truncated)
                app?.setFindResults(count: searchResults.count, current: searchResults.isEmpty ? 0 : 1)
                if let first = searchResults.first { go(chapter: first.chapterNumber - 1, anchor: first.anchor) }
            } catch {
                guard !Task.isCancelled, isCurrent, searchGeneration == generation else { return }
                app?.setFindSearching(false); notice = error.localizedDescription
            }
        }
        tasks[id] = task; searchTask = task
    }

    private func stepSearch(_ step: Int) {
        guard isCurrent, !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + step % searchResults.count + searchResults.count) % searchResults.count
        let result = searchResults[searchIndex]
        go(chapter: result.chapterNumber - 1, anchor: result.anchor)
        app?.setFindResults(count: searchResults.count, current: searchIndex + 1)
    }
}

struct EpubSelectionNoteDraft {
    let anchor: EpubTextAnchor
    var text: String
}
#endif
