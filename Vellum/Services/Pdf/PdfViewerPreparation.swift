import PDFKit

enum PdfViewerPreparation {
    /// Use only on a freshly parsed, unmodified document before attaching a view.
    /// Inspect raw annotation entries first so plain pages stay lazy in PDFKit.
    /// The raw document does not reflect later in-memory annotation edits.
    @discardableResult
    static func stripAnnotations(
        from document: PDFDocument,
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
            for annotation in annotations {
                page.removeAnnotation(annotation)
            }
        }
        return handwritingPages
    }
}
