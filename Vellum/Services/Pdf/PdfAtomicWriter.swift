import Foundation
import VellumCore

enum PdfAtomicWriter {
    static func save(_ data: Data, toPath path: String) throws {
        try SessionServiceError.translatingPdfErrors {
            try PdfAtomicFile.save(data, toPath: path)
        }
    }
}
