import Foundation

protocol ReadwiseServing: Sendable {
    func validate(token: String) async throws
    func page(token: String, cursor: String?, updatedAfter: Date?, limit: Int) async throws -> IntegrationPage
    func rawSourceURL(token: String, itemID: String) async throws -> URL?
    func moveItem(token: String, itemID: String, locationVendorID: String) async throws
}

struct ReadwiseClient: ReadwiseServing, Sendable {
    private let http: ReadLaterHTTPClient
    private let baseURL: URL
    init(http: ReadLaterHTTPClient, baseURL: URL = URL(string: "https://readwise.io")!) { self.http = http; self.baseURL = baseURL }

    static let locationCollections = ["new", "later", "shortlist", "archive", "feed"].enumerated().map {
        ReadLaterCollection(provider: .readwise, vendorID: $0.element, title: $0.element.capitalized, sortIndex: $0.offset)
    }

    /// Locations a document can be moved into. The Reader v3 update endpoint
    /// documents `location` as one of new/later/archive/feed (verified against
    /// the live docs, 2026-07-26): "shortlist" is only a *list-filter* value,
    /// so offering it would 400. "feed" is accepted by the API but excluded
    /// deliberately — filing a document back into the RSS firehose isn't a
    /// destination Reader's own UI offers.
    static let moveTargetLocationIDs: Set<String> = ["new", "later", "archive"]

    func validate(token: String) async throws {
        var request = URLRequest(url: baseURL.appending(path: "api/v2/auth/")); request.httpMethod = "GET"; request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        _ = try await http.perform(request, provider: .readwise, acceptedStatus: 204...204, idempotent: true)
    }

    func page(token: String, cursor: String?, updatedAfter: Date?, limit: Int = 100) async throws -> IntegrationPage {
        var components = URLComponents(url: baseURL.appending(path: "api/v3/list/"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor { query.append(.init(name: "pageCursor", value: cursor)) }
        if let updatedAfter { query.append(.init(name: "updatedAfter", value: ISO8601DateFormatter.integrationString(from: updatedAfter))) }
        components.queryItems = query
        // `URLComponents` leaves "+" bare in query values; Readwise (Django)
        // decodes bare "+" as a space, so an opaque cursor containing one comes
        // back mangled, the service re-serves page 1, and the engine's
        // no-progress guard fails a perfectly healthy sync.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = components.url else { throw IntegrationError.invalidResponse }
        var request = URLRequest(url: url); request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        return try Self.mapPage((try await http.perform(request, provider: .readwise, idempotent: true)).data)
    }

    func rawSourceURL(token: String, itemID: String) async throws -> URL? {
        var components = URLComponents(url: baseURL.appending(path: "api/v3/list/"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "id", value: itemID), .init(name: "withRawSourceUrl", value: "true"), .init(name: "limit", value: "1")]
        guard let url = components.url else { throw IntegrationError.invalidResponse }
        var request = URLRequest(url: url); request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        let object = try JSONSerialization.jsonObject(with: (try await http.perform(request, provider: .readwise, idempotent: true)).data) as? [String: Any]
        let value = ((object?["results"] as? [[String: Any]])?.first)?["raw_source_url"] as? String
        return value.flatMap(URL.init(string:)).flatMap(ReadLaterItem.validHTTPURL)
    }

    func moveItem(token: String, itemID: String, locationVendorID: String) async throws {
        guard Self.moveTargetLocationIDs.contains(locationVendorID) else { throw IntegrationError.unsupportedDestination }
        guard Self.isValidVendorID(itemID) else { throw IntegrationError.invalidResponse }
        var request = URLRequest(url: baseURL.appending(path: "api/v3/update/\(itemID)/"))
        request.httpMethod = "PATCH"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["location": locationVendorID])
        _ = try await http.perform(request, provider: .readwise, idempotent: true)
    }

    /// Provider-supplied item ids are interpolated into the URL path below; reject anything
    /// outside the charset Readwise actually emits so a hostile id (e.g. "../auth") can't
    /// retarget the request via `URL.appending(path:)`'s "/" handling.
    static func isValidVendorID(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func mapPage(_ data: Data) throws -> IntegrationPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let records = object["results"] as? [Any] else { throw IntegrationError.malformedData }
        var items: [ReadLaterItem] = []; var skipped = 0
        for record in records {
            do { let dto = try JSONDecoder().decode(ReadwiseItemDTO.self, from: JSONSerialization.data(withJSONObject: record)); if let item = dto.item { items.append(item) } else { skipped += 1 } } catch { skipped += 1 }
        }
        let next = ((object["nextPageCursor"] ?? object["next_page_cursor"]) as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .init(items: items, nextCursor: next?.isEmpty == false ? next : nil, hasMore: next?.isEmpty == false, skippedRecordCount: skipped, responseWasEmpty: records.isEmpty)
    }
}

private struct ReadwiseItemDTO: Decodable {
    let id: String; let sourceURL: String?; let title: String?; let author: String?; let summary: String?; let category: String?; let imageURL: String?; let location: String?; let tags: [String]; let updatedAt: String?; let savedAt: String?; let createdAt: String?
    enum CodingKeys: String, CodingKey { case id, title, author, summary, category, location, tags; case sourceURL = "source_url"; case imageURL = "image_url"; case updatedAt = "updated_at"; case savedAt = "saved_at"; case createdAt = "created_at" }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(String.self, forKey: .id); sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL); title = try c.decodeIfPresent(String.self, forKey: .title); author = try c.decodeIfPresent(String.self, forKey: .author); summary = try c.decodeIfPresent(String.self, forKey: .summary); category = try c.decodeIfPresent(String.self, forKey: .category); imageURL = try c.decodeIfPresent(String.self, forKey: .imageURL); location = try c.decodeIfPresent(String.self, forKey: .location); updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt); savedAt = try c.decodeIfPresent(String.self, forKey: .savedAt); createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt)
        if let object = try? c.decode([String: JSONValue].self, forKey: .tags) { tags = Array(object.keys) } else { tags = (try? c.decode([String].self, forKey: .tags)) ?? [] }
    }
    var item: ReadLaterItem? {
        let kind = ReadLaterKind(rawValue: category?.lowercased() ?? "") ?? .other; let source = sourceURL.flatMap(URL.init(string:)); let locationID = location.map { ReadLaterCollection.id(provider: .readwise, vendorID: $0.lowercased()) }
        return ReadLaterItem(provider: .readwise, vendorID: id, sourceURL: source, title: title, author: author, excerpt: summary, kind: kind, tags: tags, collectionIDs: locationID.map { [$0] } ?? [], thumbnailURL: imageURL.flatMap(URL.init(string:)), savedAt: IntegrationDateParser.parse(savedAt ?? createdAt), updatedAt: IntegrationDateParser.parse(updatedAt), pdfRetrieval: kind == .pdf ? .readwiseItem(id: id) : nil)
    }
}

private enum JSONValue: Decodable { case value
    init(from decoder: Decoder) throws { _ = try? decoder.singleValueContainer().decode(String.self); self = .value }
}

enum IntegrationDateParser { static func parse(_ value: String?) -> Date? { guard let value else { return nil }; let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.date(from: value) ?? ISO8601DateFormatter().date(from: value) } }
extension ISO8601DateFormatter { static func integrationString(from date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: date) } }
