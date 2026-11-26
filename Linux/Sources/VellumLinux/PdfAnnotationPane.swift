import CShell
import Foundation
import LinuxReader
import VellumCore

/// Captures the selected document's conditional write capability at page bind time.
typealias PdfConditionalReplace = @Sendable (_ original: Data, _ edited: Data) async throws -> Bool

enum PdfAnnotationIdentity {
    case unverified, ready, requiresAbsentStamp
}

private struct AnnotationPage: Sendable {
    let text: ExtractedPageText?
    let records: [Annotation]
    let restriction: String?

    @concurrent
    static func load(_ data: Data, index: Int, requiringAbsentDocumentID: Bool) async -> Self {
        async let text = try? PdfiumDocument.readText(in: data, at: index)
        let eligibility = PdfEditEligibility.classify(data, requiringAbsentDocumentID: requiringAbsentDocumentID)
        var restriction: String?
        var records: [Annotation] = []
        do {
            switch eligibility {
            case .editable: break
            case .readOnly(let reason):
                restriction = reason.localizedDescription
                switch reason {
                case .inspectionLimit: try PdfEditEligibility.validateForReading(data)
                case .conflictingDocumentID: break // The current revision passed structural inspection.
                default: throw reason
                }
            }
            records = try PdfAnnotationPureReader.annotations(on: index + 1, in: data, now: "")
                .filter { $0.type != .bookmark }
        } catch {
            restriction = restriction ?? "Could not read this page’s annotation records."
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
    private var restoringPick = false
    private var mutate: ((PdfAnnotationEdit) -> Void)?
    private var saving = false
    private var carryComment = false
    private var admissionError: String?
    private(set) var pending: Task<Bool, Never>?

    var hasDraft: Bool {
        guard let panel, !saving else { return false }
        return String(cString: pdf_annotations_content(panel)) != (picked?.content ?? "")
    }

    func showDraft() {
        guard let panel else { return }
        pdf_annotations_show_discard(panel, true)
        refresh("Save the comment or discard its changes before leaving.")
    }

    // Called synchronously before any navigation, including normal window close.
    // The replacement keeps its captured file and baseline even after detach.
    func detach() -> Task<Bool, Never>? {
        if let panel { pdf_annotations_bind(panel, nil, nil) }
        panel = nil
        page = nil
        position = nil
        picked = nil
        mutate = nil
        return pending
    }

    func bind(window: OpaquePointer, bytes: Data, index: Int, info: PdfiumPageInfo,
              replace: PdfConditionalReplace?, storageKey: String?, identity: PdfAnnotationIdentity, recoveredComment: String?, reload: @escaping (String) -> Void,
              publish: @escaping (Data, Bool) -> Void) async {
        let panel = reader_pdf_annotations(window)!
        pdf_annotations_reset(panel)
        let page = await AnnotationPage.load(bytes, index: index,
                                             requiringAbsentDocumentID: replace != nil && identity == .requiresAbsentStamp)
        guard !Task.isCancelled else { return }
        self.panel = panel
        self.page = page
        width = info.widthPt
        height = info.heightPt
        number = index + 1
        admissionError = replace != nil && identity == .unverified ? "Could not verify the shared PDF identity. Reopen the folder to edit." : nil
        carryComment = recoveredComment?.isEmpty == false
        saving = false
        if let replace, page.restriction == nil, admissionError == nil {
            mutate = { [weak self] edit in
                guard let self, !self.saving, self.admissionError == nil else { return }
                self.saving = true
                self.refresh("Saving annotation…")
                self.pending = Task {
                    do {
                        let result = try await Self.save(edit, bytes: bytes, storageKey: storageKey, replace: replace)
                        let visible = self.panel != nil
                        self.pending = nil
                        self.saving = false
                        publish(result, visible)
                        return true
                    } catch {
                        self.pending = nil
                        self.saving = false
                        guard self.panel != nil else {
                            FileHandle.standardError.write(Data("PDF annotation save failed: \(error)\n".utf8))
                            return false
                        }
                        if error is ChangedPDF || (error as? LibraryFileError) == .retryable {
                            reload(String(cString: pdf_annotations_content(panel)))
                        } else if let reason = error as? PdfReadOnlyReason {
                            self.admissionError = reason.localizedDescription
                            reader_show_status(window, reason.localizedDescription)
                            self.refresh("The original is still open.")
                        } else if case PdfCoreError.invalidDocument(let reason) = error {
                            self.refresh("Could not save the annotation. \(reason)")
                        } else {
                            self.refresh("Could not save the annotation. \(error.localizedDescription)")
                        }
                        return false
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
        if let recoveredComment {
            pdf_annotations_set_content(panel, recoveredComment)
            refresh("Reopened the latest PDF after a conflicting save. Select a location to reapply your comment.")
        } else {
            refresh(nil)
        }
        if replace != nil, let reason = admissionError ?? page.restriction { reader_show_status(window, "Read only · \(reason)") }
    }

    private struct ChangedPDF: Error {}
    @concurrent
    private static func save(_ edit: PdfAnnotationEdit, bytes: Data, storageKey: String?, replace: PdfConditionalReplace) async throws -> Data {
        let edited = try PdfAnnotationIncrement.applying(edit, to: bytes, now: Date().ISO8601Format(),
                                                        preservingStorageKey: storageKey)
        if let storageKey, try await PdfiumDocument.openingInfo(in: edited).stableIdentifier != storageKey {
            throw PdfCoreError.invalidDocument("The shared PDF identity could not be preserved.")
        }
        guard try await replace(bytes, edited) else { throw ChangedPDF() }
        return edited
    }

    private func handle(_ action: PdfAnnotationAction, x: Double, y: Double, endX: Double, endY: Double) {
        guard let page, let panel, !saving else { return }
        switch action {
        case PDF_DRAG, PDF_FIND:
            if picked != nil && hasDraft { showDraft(); return }
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
            if picked != nil && hasDraft { showDraft(); return }
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
            guard !restoringPick else { return }
            let index = Int(pdf_annotations_picked(panel))
            if hasDraft && !carryComment {
                restoringPick = true
                pdf_annotations_pick(panel, Int32(page.records.firstIndex { $0.id == picked?.id } ?? -1))
                restoringPick = false
                showDraft()
                return
            }
            picked = page.records.indices.contains(index) ? page.records[index] : nil
            position = picked?.positionData
            if !carryComment { pdf_annotations_set_content(panel, picked?.content ?? "") }
            carryComment = false
            refresh(nil)
        case PDF_HIGHLIGHT, PDF_NOTE:
            guard picked == nil, admissionError == nil else { return }
            let isHighlight = action == PDF_HIGHLIGHT
            guard !isHighlight || position?.selectedText?.isEmpty == false else { return }
            let content = String(cString: pdf_annotations_content(panel))
            mutate?(.create(.init(type: isHighlight ? .highlight : .note, pageNumber: number,
                                  content: content.isEmpty ? nil : content, positionData: position ?? anchor(x: 0.5, y: 0.5),
                                  id: UUID().uuidString.lowercased())))
        case PDF_UPDATE:
            if let picked { mutate?(.update(.init(id: picked.id, content: String(cString: pdf_annotations_content(panel))))) }
        case PDF_DISCARD:
            pdf_annotations_set_content(panel, picked?.content ?? "")
            carryComment = false
            pdf_annotations_show_discard(panel, false)
            refresh(nil)
        case PDF_DELETE:
            if let picked { mutate?(.delete(id: picked.id)) }
        default: break
        }
    }

    private func anchor(x: Double, y: Double) -> PositionData {
        PositionData(rects: [.init(x: x * width, y: y * height, width: 0, height: 0)], pageWidth: width, pageHeight: height)
    }

    private func refresh(_ message: String?) {
        guard let page, let panel else { return }
        let writable = mutate != nil && !saving && admissionError == nil
        pdf_annotations_controls(panel, writable && picked == nil && position?.selectedText?.isEmpty == false,
                                 writable && picked == nil, writable && picked != nil)
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
        else if !writable {
            hint = page.records.isEmpty ? "Drag or find text to select it." : "Choose a page annotation to read its comment."
        }
        else if page.text?.lines.isEmpty != false { hint = "No selectable text. Click to place a note, or add one at page center." }
        else { hint = "Drag or find text to highlight. Click to place a note, or add one at page center." }
        let reason = admissionError ?? page.restriction ?? (mutate == nil ? "Library editing is off." : nil)
        pdf_annotations_message(panel, reason.map { "Read only · \($0) \(hint)" } ?? hint)
    }
}
