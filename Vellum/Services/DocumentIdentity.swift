import Foundation
import CryptoKit

// Session-stable storage-key resolution for class-B/C stores (scratchpad, AI
// conversations, page-text cache, …). See plans/storage-design.html §3.
//
// The key is resolved per open and is stable for the life of a session:
//   - PDFs return DocumentInfo.docId once it has been read from — or lazily
//     stamped into — the file's /VellumDocId (nil until a mutation or
//     ensureDocumentId stamps one), otherwise a bare-hex sha256 of the
//     canonical pdf path, i.e. today's path-based identity.
//   - Web docs always carry docId (the sha256 URL hash) from open.
//
// Cross-session migration after a PDF acquires its stamp — moving a store's
// data from the path-key folder to the docId folder — is the responsibility of
// the consuming stores, NOT this resolver. It only answers "what key should I
// use right now." The sha256 hashing matches PageTextCache.pathKey /
// WebLibrary.pageKey byte-for-byte, so a store that keyed by pathKey before the
// stamp and by docId after can recognize and migrate the old folder.
enum DocumentIdentity {
    /// The storage key for a document this session: its docId, else the
    /// path-hash fallback (identical to PageTextCache.pathKey(pdfPath)).
    static func storageKey(for document: DocumentInfo) -> String {
        if let docId = document.docId, !docId.isEmpty {
            return docId
        }
        return sha256Hex(document.pdfPath)
    }

    /// Bare-hex sha256 of arbitrary bytes (full hash) — the read-only-PDF
    /// identity fallback ensureDocumentId uses when it cannot stamp the file.
    static func byteHash(_ data: Data) -> String {
        sha256Hex(data)
    }

    /// Bare-hex sha256 of a string's UTF-8 bytes.
    static func sha256Hex(_ string: String) -> String {
        sha256Hex(Data(string.utf8))
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
