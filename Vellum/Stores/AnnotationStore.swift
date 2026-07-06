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

        // Optimistic create: render the annotation immediately with a stable,
        // caller-supplied id/timestamp, then persist in the background. Embedding
        // an annotation is a full read-modify-write of the whole PDF (seconds on
        // a textbook, off the main thread), so awaiting it before the note/
        // highlight appeared made the tool look frozen for the whole write.
        var input = input
        let id = input.id ?? UUID().uuidString.lowercased()
        let now = PdfDates.rfc3339Now()
        input.id = id
        input.createdAt = now
        let optimistic = Annotation(
            id: id,
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color ?? resolvedDefaultColor(for: input.type),
            content: input.content,
            positionData: input.positionData,
            createdAt: now,
            updatedAt: now)
        annotations.append(optimistic)

        // Persist in the background and return the optimistic record NOW, so the
        // caller can open the note editor / reset the tool immediately instead of
        // waiting out the whole-file rewrite.
        Task { [weak self] in
            do {
                let saved = try await self?.sessions.createAnnotation(sessionId: sessionId, input: input)
                guard let self, let saved, self.app.activeTabId == sessionId else { return }
                // Reconcile in place (same id, so the SwiftUI row/editor is
                // preserved) with the authoritative record — but never clobber
                // note text the user may have typed while the write was in flight.
                if let index = self.annotations.firstIndex(where: { $0.id == id }) {
                    if saved.type == .note {
                        self.annotations[index].color = saved.color
                        self.annotations[index].positionData = saved.positionData
                    } else {
                        self.annotations[index] = saved
                    }
                }
            } catch {
                NSLog("[annotation-store] Failed to create \(label): \(error)")
                // Roll back the optimistic insert.
                if let self, self.app.activeTabId == sessionId {
                    self.annotations.removeAll { $0.id == id }
                }
            }
        }
        return optimistic
    }

    /// The default color the backend would assign when the caller passes none,
    /// so the optimistic record matches what persistence writes.
    private func resolvedDefaultColor(for type: AnnotationType) -> String? {
        switch type {
        case .highlight: return AppStore.storedDefaultHighlightColor()
        case .note, .bookmark: return nil
        }
    }
}
