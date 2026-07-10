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

    /// In-flight optimistic creates, keyed by their temporary id. Each task
    /// resolves to the persisted id (nil if the create failed). Mutations that
    /// target a `temp-` id queue behind the create and retarget the real id —
    /// the backends can only resolve persisted ids.
    @ObservationIgnored private var pendingCreates: [String: Task<String?, Never>] = [:]

    /// Resolve an annotation id a mutation can act on: real ids pass through;
    /// `temp-` ids wait for their create to persist and return the swapped-in
    /// id, or nil when the create failed (nothing left to mutate).
    private func resolveId(_ id: String) async -> String? {
        guard id.hasPrefix("temp-") else { return id }
        guard let pending = pendingCreates[id] else { return nil }
        return await pending.value
    }

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
        // Edits against a still-optimistic row queue behind its create and
        // retarget the persisted id.
        var input = input
        guard let realId = await resolveId(input.id) else { return }
        input.id = realId
        guard app.activeTabId == sessionId else { return }
        // Optimistic update
        annotations = annotations.map { annotation in
            guard annotation.id == input.id else { return annotation }
            var next = annotation
            if let color = input.color { next.color = color }
            if let content = input.content { next.content = content }
            if let positionData = input.positionData { next.positionData = positionData }
            if let pageNumber = input.pageNumber { next.pageNumber = pageNumber }
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
        // Deleting a still-optimistic row waits for its create to persist, then
        // deletes the real record (the backends can't find a temp id).
        guard let id = await resolveId(id) else { return }
        guard app.activeTabId == sessionId else { return }
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
        // Optimistic create: render the annotation IMMEDIATELY with a temporary
        // id, then persist off the main path and reconcile the real id (or
        // revert) once the file write finishes. A full-file PDF rewrite can take
        // seconds on a large document; the user must never wait on that to SEE
        // their highlight/note — the same optimistic pattern update/delete use.
        let now = ISO8601DateFormatter.recentTimestamp.string(from: Date())
        let tempId = "temp-" + UUID().uuidString.lowercased()
        let optimistic = Annotation(
            id: tempId,
            type: input.type,
            pageNumber: input.pageNumber,
            color: input.color,
            content: input.content,
            positionData: input.positionData,
            createdAt: now,
            updatedAt: now)
        annotations.append(optimistic)

        pendingCreates[tempId] = Task { [weak self] in
            guard let self else { return nil }
            defer { self.pendingCreates[tempId] = nil }
            do {
                let persisted = try await self.sessions.createAnnotation(sessionId: sessionId, input: input)
                guard self.app.activeTabId == sessionId else { return persisted.id }
                // Swap the temp record for the persisted one (real id, server
                // defaults like the applied highlight color), keeping selection.
                if let index = self.annotations.firstIndex(where: { $0.id == tempId }) {
                    self.annotations[index] = persisted
                }
                if self.selectedAnnotationId == tempId {
                    self.selectedAnnotationId = persisted.id
                }
                return persisted.id
            } catch {
                NSLog("[annotation-store] Failed to create \(label): \(error)")
                guard self.app.activeTabId == sessionId else { return nil }
                self.annotations.removeAll { $0.id == tempId }
                if self.selectedAnnotationId == tempId {
                    self.selectedAnnotationId = nil
                }
                return nil
            }
        }
        return optimistic
    }
}
