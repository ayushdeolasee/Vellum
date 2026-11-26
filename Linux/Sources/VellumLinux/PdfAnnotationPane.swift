import CShell
import Foundation
import LinuxReader
import VellumCore

/// Captures the selected document's conditional write capability at page bind time.
typealias PdfConditionalReplace = @Sendable (_ original: Data, _ edited: Data) async throws -> Bool

private struct AnnotationPage: Sendable {
    let text: ExtractedPageText?
    let records: [Annotation]
    let restriction: String?

    @concurrent
    static func load(_ data: Data, index: Int) async -> Self {
        async let text = try? PdfiumDocument.readText(in: data, at: index)
        let records: [Annotation]
        let restriction: String?
        switch PdfEditEligibility.classify(data) {
        case .editable:
            do {
                records = try PdfAnnotationPureReader.annotations(on: index + 1, in: data, now: "")
                    .filter { $0.type != .bookmark }
                restriction = nil
            } catch {
                records = []
                restriction = "Could not read this page’s annotation records."
            }
        case .readOnly(let reason):
            records = []
            switch reason {
            case .unsupportedXref: restriction = "This PDF uses an unsupported cross-reference format."
            case .encrypted: restriction = "This PDF is encrypted."
            case .signed: restriction = "This PDF contains a digital signature."
            case .nonzeroGeneration: restriction = "This PDF uses unsupported object generations."
            case .malformed: restriction = "The original PDF structure could not be verified."
            case .ambiguousAnnotation: restriction = "The PDF has ambiguous annotation identities."
            case .unsupportedGeometry: restriction = "This PDF has unsupported page geometry."
            }
        }
        return await Self(text: text, records: records, restriction: restriction)
    }
}

@MainActor
final class PdfAnnotationPane {
    private var page: AnnotationPage?
    private var panel: OpaquePointer?
    private var number = 0
    private var width = 0.0
    private var height = 0.0
    private var position: PositionData?
    private var picked: Annotation?
    private var mutate: ((PdfAnnotationEdit) -> Void)?
    private var reload: (() -> Void)?
    private var saving = false
    private var stale = false
    private var pending: Task<Void, Never>?

    // Called synchronously before any navigation, including normal window close.
    // The replacement keeps its captured file and baseline even after detach.
    func detach() -> Task<Void, Never>? {
        if let panel { pdf_annotations_bind(panel, nil, nil) }
        panel = nil
        page = nil
        position = nil
        picked = nil
        mutate = nil
        reload = nil
        return pending
    }

    func bind(window: OpaquePointer, bytes: Data, index: Int, info: PdfiumPageInfo,
              replace: PdfConditionalReplace?, reload: @escaping () -> Void,
              publish: @escaping (Data, Bool) -> Void) async {
        let panel = reader_pdf_annotations(window)!
        pdf_annotations_reset(panel)
        let page = await AnnotationPage.load(bytes, index: index)
        guard !Task.isCancelled else { return }
        self.panel = panel
        self.page = page
        self.reload = reload
        width = info.widthPt
        height = info.heightPt
        number = index + 1
        stale = false
        saving = false
        if let replace, page.restriction == nil {
            mutate = { [weak self] edit in
                guard let self, !self.saving, !self.stale else { return }
                self.saving = true
                self.refresh("Saving annotation…")
                self.pending = Task {
                    do {
                        let result = try await Self.save(edit, bytes: bytes, replace: replace)
                        let visible = self.panel != nil
                        self.pending = nil
                        self.saving = false
                        publish(result, visible)
                    } catch {
                        self.pending = nil
                        self.saving = false
                        guard self.panel != nil else {
                            FileHandle.standardError.write(Data("PDF annotation save failed: \(error)\n".utf8))
                            return
                        }
                        self.stale = error is ChangedPDF || (error as? LibraryFileError) == .retryable
                        self.refresh(self.stale
                            ? "The PDF changed or could not be replaced. Reload it before editing."
                            : "Could not save the annotation. \(error.localizedDescription)")
                    }
                }
            }
        }
        for (i, record) in page.records.enumerated() {
            let label = record.content?.isEmpty == false ? record.content : record.positionData?.selectedText
            let excerpt = (label ?? "").replacingOccurrences(of: "\n", with: " ").prefix(22)
            pdf_annotations_add(panel, "\(i + 1). \(record.type == .note ? "Note" : "Highlight") \(excerpt)")
        }
        pdf_annotations_bind(panel, { action, x, y, endX, endY, context in
            MainActor.assumeIsolated {
                let pane = Unmanaged<PdfAnnotationPane>.fromOpaque(context!).takeUnretainedValue()
                pane.handle(action, x: x, y: y, endX: endX, endY: endY)
            }
        }, Unmanaged.passUnretained(self).toOpaque())
        refresh(nil)
        if mutate != nil { reader_pdf_editable(window) }
    }

    private struct ChangedPDF: Error {}
    @concurrent
    private static func save(_ edit: PdfAnnotationEdit, bytes: Data, replace: PdfConditionalReplace) async throws -> Data {
        let edited = try PdfAnnotationIncrement.applying(edit, to: bytes, now: Date().ISO8601Format())
        guard try await replace(bytes, edited) else { throw ChangedPDF() }
        return edited
    }

    private func handle(_ action: PdfAnnotationAction, x: Double, y: Double, endX: Double, endY: Double) {
        guard let page, let panel, !saving else { return }
        switch action {
        case PDF_DRAG, PDF_FIND:
            let selection: PdfTextLocatorPortable.Selection?
            if action == PDF_FIND {
                let query = String(cString: pdf_annotations_query(panel))
                selection = page.text.flatMap { PdfTextLocatorPortable.locate(query: query, in: $0) }
            } else {
                selection = page.text.flatMap {
                    let g = $0.geometry
                    return PdfTextLocatorPortable.selection(in: $0, fromX: x * g.displayWidth, y: y * g.displayHeight,
                                                           toX: endX * g.displayWidth, y: endY * g.displayHeight)
                }
            }
            pdf_annotations_pick(panel, -1)
            position = selection?.positionData
            refresh(position == nil ? "No text selected." : nil)
        case PDF_POINT:
            if let i = page.records.lastIndex(where: { record in
                guard let pos = record.positionData else { return false }
                let px = x * pos.pageWidth, py = y * pos.pageHeight
                return pos.rects.contains { r in
                    let w = record.type == .note ? 18 : r.width, h = record.type == .note ? 18 : r.height
                    return px >= r.x && px <= r.x + w && py >= r.y && py <= r.y + h
                }
            }) {
                pdf_annotations_pick(panel, Int32(i))
            } else {
                pdf_annotations_pick(panel, -1)
                position = anchor(x: x, y: y)
                refresh("Note location selected.")
            }
        case PDF_PICK:
            let index = Int(pdf_annotations_picked(panel))
            picked = page.records.indices.contains(index) ? page.records[index] : nil
            position = picked?.positionData
            pdf_annotations_set_content(panel, picked?.content ?? "")
            refresh(nil)
        case PDF_HIGHLIGHT, PDF_NOTE:
            guard picked == nil, !stale else { return }
            let isHighlight = action == PDF_HIGHLIGHT
            guard !isHighlight || position?.selectedText?.isEmpty == false else { return }
            let content = String(cString: pdf_annotations_content(panel))
            mutate?(.create(.init(type: isHighlight ? .highlight : .note, pageNumber: number,
                                  content: content.isEmpty ? nil : content, positionData: position ?? anchor(x: 0.5, y: 0.5),
                                  id: UUID().uuidString.lowercased())))
        case PDF_UPDATE:
            if let picked { mutate?(.update(.init(id: picked.id, content: String(cString: pdf_annotations_content(panel))))) }
        case PDF_DELETE:
            if let picked { mutate?(.delete(id: picked.id)) }
        case PDF_RELOAD:
            reload?()
        default: break
        }
    }

    private func anchor(x: Double, y: Double) -> PositionData {
        PositionData(rects: [.init(x: x * width, y: y * height, width: 0, height: 0)], pageWidth: width, pageHeight: height)
    }

    private func refresh(_ message: String?) {
        guard let page, let panel else { return }
        let writable = mutate != nil && !saving && !stale
        pdf_annotations_controls(panel, writable && picked == nil && position?.selectedText?.isEmpty == false,
                                 writable && picked == nil, writable && picked != nil, stale)
        pdf_annotations_clear_rects(panel)
        if let pos = position {
            for r in pos.rects {
                pdf_annotations_rect(panel, r.x / pos.pageWidth, r.y / pos.pageHeight,
                                     r.width / pos.pageWidth, r.height / pos.pageHeight)
            }
        }
        let hint: String
        if let message { hint = message }
        else if let selected = position?.selectedText { hint = selected }
        else if let picked { hint = "Selected \(picked.type.rawValue)." }
        else if page.text?.lines.isEmpty != false { hint = "No selectable text. Click to place a note, or add one at page center." }
        else { hint = "Drag or find text to highlight. Click to place a note, or add one at page center." }
        let reason = page.restriction ?? (mutate == nil ? "Library editing is off." : nil)
        pdf_annotations_message(panel, reason.map { "Read only · \($0) \(hint)" } ?? hint)
    }
}
