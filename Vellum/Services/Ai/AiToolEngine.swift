import Foundation

struct AiToolArguments: Codable, Sendable {
    var pageNumber: Double?
    var text: String?
    var color: String?
    var x: Double?
    var y: Double?
}

struct AiToolAction: Codable, Sendable {
    var tool: String
    var args: AiToolArguments
}

@MainActor
final class AiToolEngine {
    static let maxActions = 5
    static let defaultPageWidth = 612.0
    static let defaultPageHeight = 792.0

    private unowned let store: AiStore
    private unowned let app: AppStore
    private unowned let annotations: AnnotationStore

    init(store: AiStore, app: AppStore, annotations: AnnotationStore) {
        self.store = store
        self.app = app
        self.annotations = annotations
    }

    func run(_ action: AiToolAction, sessionIdAtStart: String, actionCount: Int) async -> String {
        if actionCount >= Self.maxActions {
            return "Skipped: action limit reached for this response."
        }
        if app.activeTabId != sessionIdAtStart {
            return "Skipped: the active document changed before this action ran."
        }
        do {
            return try await execute(action)
        } catch {
            return "Action failed: \(String(describing: error))"
        }
    }

    private func execute(_ action: AiToolAction) async throws -> String {
        switch action.tool {
        case "goToPage":
            let page = clampPage(action.args.pageNumber)
            app.goToPage(page)
            return "Navigated to page \(page)."

        case "addNote":
            let page = clampPage(action.args.pageNumber)
            let text = action.args.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return "Skipped addNote: empty text." }
            let position = PositionData(
                rects: [AnnotationRect(
                    x: sanitizeNonNegative(action.args.x, fallback: 72),
                    y: sanitizeNonNegative(action.args.y, fallback: 96),
                    width: 0,
                    height: 0
                )],
                pageWidth: Self.defaultPageWidth,
                pageHeight: Self.defaultPageHeight,
                selectedText: nil,
                startOffset: nil,
                endOffset: nil,
                prefix: nil,
                suffix: nil,
                viewportOffset: nil
            )
            _ = await annotations.addNote(CreateAnnotationInput(
                type: .note,
                pageNumber: page,
                color: nil,
                content: text,
                positionData: position
            ))
            return "Added note on page \(page)."

        case "addHighlight":
            let requestedPage = clampPage(action.args.pageNumber)
            let query = action.args.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else { return "Skipped addHighlight: no text provided to locate." }
            let color = sanitizeColor(action.args.color)
            let isWeb = app.document?.kind == .web
            let located: LocatedText?
            if isWeb {
                located = await store.locateWebTextHandler?(requestedPage, query)
            } else {
                located = await store.locatePdfTextHandler?(requestedPage, query)
            }
            guard var located,
                  isWeb || !located.positionData.rects.isEmpty else {
                return "Skipped addHighlight: couldn't find \"\(query)\" on page \(requestedPage)."
            }
            let resolvedPage = isWeb ? clampPage(Double(located.pageNumber)) : requestedPage
            if isWeb { located.positionData.selectedText = query }
            _ = await annotations.addHighlight(CreateAnnotationInput(
                type: .highlight,
                pageNumber: resolvedPage,
                color: color,
                content: nil,
                positionData: located.positionData
            ))
            return "Highlighted \"\(query)\" on page \(resolvedPage)."

        default:
            return "Skipped unknown tool: \(action.tool)."
        }
    }

    private func clampPage(_ value: Double?) -> Int {
        let total = app.numPages
        let fallback = total > 0 ? app.currentPage : 1
        guard let value, value.isFinite else { return max(1, fallback) }
        guard total > 0 else { return 1 }
        return min(total, max(1, Int(value.rounded())))
    }

    private func sanitizeNonNegative(_ value: Double?, fallback: Double) -> Double {
        guard let value, value.isFinite else { return fallback }
        return max(0, value)
    }

    private func sanitizeColor(_ value: String?) -> String {
        guard let value else { return WorkspaceStore.storedDefaultHighlightColor() }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^#(?:[0-9a-f]{3}|[0-9a-f]{4}|[0-9a-f]{6}|[0-9a-f]{8})$|^(?:rgb|rgba|hsl|hsla)\([^)]*\)$|^[a-z]+$"#
        guard trimmed.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else {
            return WorkspaceStore.storedDefaultHighlightColor()
        }
        return trimmed
    }
}
