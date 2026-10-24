import Foundation

enum EpubAnnotationError: LocalizedError, Equatable {
    case invalidAnchor
    case invalidChapter
    case duplicateID
    case invalidSidecar
    case limitExceeded

    var errorDescription: String? {
        switch self {
        case .invalidAnchor: "This passage could not be located unambiguously. Select it again before saving."
        case .invalidChapter: "This chapter is no longer available."
        case .duplicateID: "This annotation already exists."
        case .invalidSidecar: "The book's annotation data could not be read. It has been kept unchanged."
        case .limitExceeded: "This book's annotations exceed the supported size limit."
        }
    }
}

/// No cached records: every edit merges against the latest docId-keyed bytes.
struct EpubAnnotationStorage: Sendable {
    let document: DocumentInfo
    let coordinator: StorageCoordinator?

    private struct Record: Codable {
        var version = 1
        var docId: String
        var annotations: [Annotation] = []

        enum CodingKeys: String, CodingKey {
            case version, annotations
            case docId = "doc_id"
        }
    }

    func annotations(pageNumber: Int? = nil) async throws -> [Annotation] {
        try await access { records in
            Annotation.sortedForDisplay(records.filter { pageNumber == nil || $0.pageNumber == pageNumber })
        }
    }

    func create(_ annotation: Annotation) async throws -> Annotation {
        try await access { records in
            guard !records.contains(where: { $0.id == annotation.id }) else { throw EpubAnnotationError.duplicateID }
            guard records.count < 10_000 else { throw EpubAnnotationError.limitExceeded }
            records.append(annotation)
            return annotation
        }
    }

    func update(_ input: UpdateAnnotationInput) async throws -> Bool {
        try await access { records in
            guard let index = records.firstIndex(where: { $0.id == input.id }) else { return false }
            if let color = input.color { records[index].color = color }
            if let content = input.content { records[index].content = content }
            if let position = input.positionData { records[index].positionData = position }
            if let page = input.pageNumber { records[index].pageNumber = page }
            if let pinned = input.isPinned { records[index].isPinned = pinned }
            records[index].updatedAt = ISO8601DateFormatter().string(from: Date())
            return true
        }
    }

    func delete(id: String) async throws -> Bool {
        try await access { records in
            let before = records.count
            records.removeAll { $0.id == id }
            return records.count != before
        }
    }

    private func access<T: Sendable>(
        _ operation: @escaping @Sendable (inout [Annotation]) throws -> T
    ) async throws -> T {
        let docId = DocumentIdentity.storageKey(for: document)
        return try await DocumentDataStore.withEpubAnnotations(document: document, coordinator: coordinator) { data in
            guard data == nil || data!.count <= 4 * 1024 * 1024 else { throw EpubAnnotationError.limitExceeded }
            var record = try data.map { try JSONDecoder().decode(Record.self, from: $0) } ?? Record(docId: docId)
            guard record.version == 1, record.docId == docId else { throw EpubAnnotationError.invalidSidecar }
            let before = record.annotations
            let result = try operation(&record.annotations)
            guard record.annotations != before else { return (nil, result) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let bytes = try encoder.encode(record)
            guard bytes.count <= 4 * 1024 * 1024 else { throw EpubAnnotationError.limitExceeded }
            return (bytes, result)
        }
    }
}
