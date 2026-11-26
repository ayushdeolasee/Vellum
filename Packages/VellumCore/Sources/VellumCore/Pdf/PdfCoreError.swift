public enum PdfCoreError: Error, Equatable {
    case invalidDocument(String)
    case io(String)
}
