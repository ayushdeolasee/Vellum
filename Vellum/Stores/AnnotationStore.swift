import Foundation
import Observation

// Annotation list + selection for the current document — port of
// src/stores/annotation-store.ts. Optimistic updates with reload/revert on
// failure; every await is guarded so a stale session can't clobber state.

/// The bookmark the toggle button/shortcut acts on. PDF bookmarks are per
/// page; web bookmarks anchor to a text position, so "current" means a
/// bookmark whose anchor is on screen right now. Web bookmarks from before
/// point anchoring existed have no offsets and fall back to page matching.
func findCurrentBookmark(
    annotations: [Annotation],
    docKind: DocumentKind?,
    currentPage: Int,
    webVisibleBookmarks: [String]
) -> Annotation? {
    annotations.first { annotation in
        guard annotation.type == .bookmark else { return false }
        if docKind == .web, annotation.positionData?.startOffset != nil {
            // The content script re-anchors each bookmark against the live DOM
            // and reports the ones actually on screen. Stored offsets come from
            // the session that created them, so comparing them to the current
            // visible text span drifts after restarts — and a span covers whole
            // virtual pages, which lit the star for an entire short article.
            return webVisibleBookmarks.contains(annotation.id)
        }
        return annotation.pageNumber == currentPage
    }
}

struct CapturedWebPosition: Sendable {
    var pageNumber: Int
    var positionData: PositionData
}

@MainActor
@Observable
final class AnnotationStore {
    private let app: AppStore
    private var sessions: SessionService { app.sessions }

    /// All annotations for the current document.
    private(set) var annotations: [Annotation] = []
    private(set) var isLoading = false
    private(set) var selectedAnnotationId: String?

    /// Registered by the web viewer to capture the current reading position
    /// for a point bookmark (window.__captureWebPosition in the original).
    var captureWebPositionHandler: (() async -> CapturedWebPosition?)?

    init(app: AppStore) {
        self.app = app
    }

    func loadAnnotations() async {
        guard let sessionId = app.activeTabId else {
            annotations = []
            isLoading = false
            selectedAnnotationId = nil
            return
        }
        isLoading = true
        do {
            let loaded = try await sessions.getAnnotations(sessionId: sessionId, pageNumber: nil)
            if app.activeTabId == sessionId {
                annotations = loaded
                isLoading = false
                selectedAnnotationId = nil
            }
        } catch {
            NSLog("[annotation-store] Failed to load annotations: \(error)")
            if app.activeTabId == sessionId {
                isLoading = false
            }
        }
    }

    @discardableResult
    func addHighlight(_ input: CreateAnnotationInput) async -> Annotation? {
        var input = input
        input.type = .highlight
        return await create(input, label: "highlight")
    }

    @discardableResult
    func addNote(_ input: CreateAnnotationInput) async -> Annotation? {
        var input = input
        input.type = .note
        return await create(input, label: "note")
    }

    @discardableResult
    func addBookmark(pageNumber: Int, positionData: PositionData? = nil) async -> Annotation? {
        let input = CreateAnnotationInput(
            type: .bookmark,
            pageNumber: pageNumber,
            color: nil,
            content: nil,
            positionData: positionData
        )
        return await create(input, label: "bookmark")
    }

    /// Add or remove the bookmark at the current reading position.
    func toggleBookmark() async {
        guard let doc = app.document else { return }
        let existing = findCurrentBookmark(
            annotations: annotations,
            docKind: doc.kind,
            currentPage: app.currentPage,
            webVisibleBookmarks: app.webVisibleBookmarks
        )
        if let existing {
            await deleteAnnotation(id: existing.id)
            return
        }
        if doc.kind == .web, let capture = captureWebPositionHandler,
           let captured = await capture() {
            await addBookmark(pageNumber: captured.pageNumber, positionData: captured.positionData)
            return
        }
        await addBookmark(pageNumber: app.currentPage)
    }

    func updateAnnotation(_ input: UpdateAnnotationInput) async {
        guard let sessionId = app.activeTabId else { return }
        // Optimistic update
        annotations = annotations.map { annotation in
            guard annotation.id == input.id else { return annotation }
            var next = annotation
            if let color = input.color { next.color = color }
            if let content = input.content { next.content = content }
            if let positionData = input.positionData { next.positionData = positionData }
            next.updatedAt = ISO8601DateFormatter.recentTimestamp.string(from: Date())
            return next
        }
        do {
            let updated = try await sessions.updateAnnotation(sessionId: sessionId, input: input)
            if !updated {
                throw SessionServiceError.invalidDocument("Annotation \(input.id) was not found")
            }
        } catch {
            NSLog("[annotation-store] Failed to update annotation: \(error)")
            // Reload on failure to revert optimistic update
            if app.activeTabId == sessionId {
                await loadAnnotations()
            }
        }
    }

    func deleteAnnotation(id: String) async {
        guard let sessionId = app.activeTabId else { return }
        // Optimistic delete
        let previous = annotations
        annotations = annotations.filter { $0.id != id }
        if selectedAnnotationId == id {
            selectedAnnotationId = nil
        }
        do {
            let deleted = try await sessions.deleteAnnotation(sessionId: sessionId, id: id)
            if !deleted {
                throw SessionServiceError.invalidDocument("Annotation \(id) was not found")
            }
        } catch {
            NSLog("[annotation-store] Failed to delete annotation: \(error)")
            // Revert on failure
            if app.activeTabId == sessionId {
                annotations = previous
            }
        }
    }

    func selectAnnotation(_ id: String?) {
        selectedAnnotationId = id
    }

    func clearAnnotations() {
        annotations = []
        selectedAnnotationId = nil
    }

    func annotationsForPage(_ pageNumber: Int) -> [Annotation] {
        annotations.filter { $0.pageNumber == pageNumber }
    }

    private func create(_ input: CreateAnnotationInput, label: String) async -> Annotation? {
        guard let sessionId = app.activeTabId else { return nil }
        do {
            let annotation = try await sessions.createAnnotation(sessionId: sessionId, input: input)
            if app.activeTabId == sessionId {
                annotations.append(annotation)
                return annotation
            }
            return nil
        } catch {
            NSLog("[annotation-store] Failed to create \(label): \(error)")
            return nil
        }
    }
}
