import Foundation

/// Drawing coordinates belong to this fixed sheet, never the reflowing chapter.
struct EpubHandwritingNote: Codable, Equatable, Identifiable, Sendable {
    var id: String = UUID().uuidString.lowercased()
    var anchor: EpubTextAnchor
    var drawing: Data = Data()
    var canvasWidth: Double = 900
    var canvasHeight: Double = 1200
    var updatedAt: Date = Date()

    var isValid: Bool {
        UUID(uuidString: id) != nil && drawing.count <= 4 * 1024 * 1024
            && canvasWidth.isFinite && canvasHeight.isFinite
            && (300...2400).contains(canvasWidth) && (300...3200).contains(canvasHeight)
            && !anchor.quote.isEmpty && anchor.quote.utf16.count <= 8192
            && anchor.chapterHref.utf16.count <= 2048 && !anchor.chapterHref.isEmpty
            && anchor.prefix.utf16.count <= 256 && anchor.suffix.utf16.count <= 256
    }
}

struct EpubHandwritingStorage: Sendable {
    let document: DocumentInfo
    let coordinator: StorageCoordinator?

    private struct Record: Codable {
        var version = 1
        let docId: String
        var notes: [EpubHandwritingNote] = []
    }

    func notes() async throws -> [EpubHandwritingNote] {
        try await access { $0.sorted { $0.updatedAt > $1.updatedAt } }
    }

    func save(_ note: EpubHandwritingNote) async throws {
        guard note.isValid else { throw EpubAnnotationError.limitExceeded }
        try await access { notes in
            if let index = notes.firstIndex(where: { $0.id == note.id }) { notes[index] = note }
            else {
                guard notes.count < 500 else { throw EpubAnnotationError.limitExceeded }
                notes.append(note)
            }
        }
    }

    func delete(id: String) async throws {
        try await access { $0.removeAll { $0.id == id } }
    }

    private func access<T: Sendable>(
        _ operation: @escaping @Sendable (inout [EpubHandwritingNote]) throws -> T
    ) async throws -> T {
        let docId = DocumentIdentity.storageKey(for: document)
        return try await DocumentDataStore.withEpubHandwriting(document: document, coordinator: coordinator) { data in
            guard data == nil || data!.count <= 32 * 1024 * 1024 else { throw EpubAnnotationError.limitExceeded }
            var record: Record
            do { record = try data.map { try JSONDecoder().decode(Record.self, from: $0) } ?? Record(docId: docId) }
            catch { throw EpubAnnotationError.invalidSidecar }
            guard record.version == 1, record.docId == docId, record.notes.count <= 500,
                  record.notes.allSatisfy(\.isValid), Set(record.notes.map(\.id)).count == record.notes.count
            else { throw EpubAnnotationError.invalidSidecar }
            let before = record.notes
            let result = try operation(&record.notes)
            guard before != record.notes else { return (nil, result) }
            let bytes = try JSONEncoder().encode(record)
            guard bytes.count <= 32 * 1024 * 1024 else { throw EpubAnnotationError.limitExceeded }
            return (bytes, result)
        }
    }
}
