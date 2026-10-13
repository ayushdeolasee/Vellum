import PDFKit

/// Prepared off-main, then owned exclusively by the native viewer on main.
/// PDFKit's password UI calls this override. Keep its successful credential only
/// for this document's lifetime so detached readers can unlock their own copies.
final class PdfViewerDocument: PDFDocument {
    private(set) var privateCopyPassword: String?

    override func unlock(withPassword password: String) -> Bool {
        // PDFKit returns true even for a bogus password once already unlocked.
        // Such a call must not replace the credential that opened the source.
        guard isLocked else { return super.unlock(withPassword: password) }
        let previous = privateCopyPassword
        // The unlock notification can be posted synchronously inside super.
        privateCopyPassword = password
        let unlocked = super.unlock(withPassword: password)
        if !unlocked { privateCopyPassword = previous }
        return unlocked
    }
}

enum PdfViewerPreparation {
    enum PrivateDocumentError: Error { case unavailable, locked }

    /// Only call off-main. Never copy or serialize the document attached to a
    /// PDFView; construct an independent reader from its retained source bytes.
    static func privateDocument(data: Data, password: String?) throws -> PDFDocument {
        guard let document = PDFDocument(data: data) else { throw PrivateDocumentError.unavailable }
        if document.isLocked {
            guard let password, document.unlock(withPassword: password) else {
                throw PrivateDocumentError.locked
            }
        }
        return document
    }

    /// Use only on a freshly parsed, unmodified document before attaching a view.
    /// Inspect raw annotation entries first so plain pages stay lazy in PDFKit.
    /// The raw document does not reflect later in-memory annotation edits.
    /// Preservation and the 1-based handwriting summary are independent: native
    /// ink may remain read-only without being owned by an editable ink overlay.
    @discardableResult
    static func stripAnnotations(
        from document: PDFDocument,
        preserving shouldPreserve: (PDFAnnotation) -> Bool,
        isHandwriting: (PDFAnnotation) -> Bool = { _ in false }
    ) -> [Int] {
        let raw = document.documentRef
        var handwritingPages: [Int] = []
        for index in 0..<document.pageCount {
            if let dictionary = raw?.page(at: index + 1)?.dictionary {
                var annotations: CGPDFObjectRef?
                if !CGPDFDictionaryGetObject(dictionary, "Annots", &annotations) {
                    continue
                }
            }
            // Missing raw page information falls back to PDFKit. Existing
            // entries, including indirect arrays, take the original path.
            guard let page = document.page(at: index) else { continue }
            let annotations = page.annotations
            if annotations.contains(where: isHandwriting) {
                handwritingPages.append(index + 1)
            }
            for annotation in annotations where !shouldPreserve(annotation) {
                page.removeAnnotation(annotation)
            }
        }
        return handwritingPages
    }
}
