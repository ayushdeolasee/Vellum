import Foundation

protocol RaindropServing: Sendable {
    func validate(token: String) async throws
    func collections(token: String) async throws -> [ReadLaterCollection]
    func page(token: String, page: Int, perPage: Int) async throws -> IntegrationPage
    func moveItem(token: String, itemID: String, collectionVendorID: String) async throws
}

struct RaindropClient: RaindropServing, Sendable {
    private let http: ReadLaterHTTPClient; private let baseURL: URL
    init(http: ReadLaterHTTPClient, baseURL: URL = URL(string: "https://api.raindrop.io")!) { self.http = http; self.baseURL = baseURL }
    func validate(token: String) async throws { var request = URLRequest(url: baseURL.appending(path: "rest/v1/user")); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); _ = try await http.perform(request, provider: .raindrop) }
    func collections(token: String) async throws -> [ReadLaterCollection] {
        async let roots = collectionRequest(token: token, path: "rest/v1/collections")
        async let children = collectionRequest(token: token, path: "rest/v1/collections/childrens")
        return try Self.flattenCollections(await roots + children)
    }
    func page(token: String, page: Int, perPage: Int = 50) async throws -> IntegrationPage {
        var components = URLComponents(url: baseURL.appending(path: "rest/v1/raindrops/0"), resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "page", value: String(page)), .init(name: "perpage", value: String(perPage)), .init(name: "sort", value: "-created")]
        var request = URLRequest(url: components.url!); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try Self.mapPage((try await http.perform(request, provider: .raindrop)).data, page: page, perPage: perPage)
    }
    func moveItem(token: String, itemID: String, collectionVendorID: String) async throws {
        guard let collection = Int64(collectionVendorID) else { throw IntegrationError.unsupportedDestination }
        var request = URLRequest(url: baseURL.appending(path: "rest/v1/raindrop/\(itemID)"))
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["collection": ["$id": collection]])
        let data = (try await http.perform(request, provider: .raindrop)).data
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["result"] as? Bool == true else { throw IntegrationError.invalidResponse }
    }
    private func collectionRequest(token: String, path: String) async throws -> [RaindropCollectionDTO] { var request = URLRequest(url: baseURL.appending(path: path)); request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization"); let object = try JSONSerialization.jsonObject(with: (try await http.perform(request, provider: .raindrop)).data) as? [String: Any]; guard let values = object?["items"] else { throw IntegrationError.malformedData }; return try JSONDecoder().decode([RaindropCollectionDTO].self, from: JSONSerialization.data(withJSONObject: values)) }
    static func mapPage(_ data: Data, page: Int, perPage: Int) throws -> IntegrationPage {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let records = object["items"] as? [Any] else { throw IntegrationError.malformedData }
        var items: [ReadLaterItem] = []; var skipped = 0
        for record in records { do { let dto = try JSONDecoder().decode(RaindropItemDTO.self, from: JSONSerialization.data(withJSONObject: record)); if let item = dto.item { items.append(item) } else { skipped += 1 } } catch { skipped += 1 } }
        let terminal = records.count < perPage
        return .init(items: items, nextCursor: terminal ? nil : String(page + 1), hasMore: !terminal, skippedRecordCount: skipped, responseWasEmpty: records.isEmpty)
    }
    static func flattenCollections(_ values: [RaindropCollectionDTO]) -> [ReadLaterCollection] {
        let unique = Dictionary(values.map { ($0.id.stringValue, $0) }, uniquingKeysWith: { first, _ in first }); let grouped = Dictionary(grouping: unique.values) { $0.parentID?.stringValue }; var result: [ReadLaterCollection] = []; var visited: Set<String> = []
        func append(_ parent: String?, _ depth: Int) { for child in (grouped[parent] ?? []).sorted(by: { $0.sort == $1.sort ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.sort > $1.sort }) where visited.insert(child.id.stringValue).inserted { result.append(.init(provider: .raindrop, vendorID: child.id.stringValue, title: child.title, parentID: child.parentID.map { "raindrop:collection:\($0.stringValue)" }, depth: depth, sortIndex: result.count)); append(child.id.stringValue, depth + 1) } }
        append(nil, 0); for orphan in unique.values.sorted(by: { $0.title < $1.title }) where visited.insert(orphan.id.stringValue).inserted { result.append(.init(provider: .raindrop, vendorID: orphan.id.stringValue, title: orphan.title, sortIndex: result.count)) }; return result
    }
}

struct LosslessStringID: Codable, Hashable, Sendable { let stringValue: String; init(from decoder: Decoder) throws { let c = try decoder.singleValueContainer(); if let value = try? c.decode(String.self) { stringValue = value } else if let value = try? c.decode(Int64.self) { stringValue = String(value) } else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "Expected string or integer id") } }; func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(stringValue) } }
struct RaindropCollectionDTO: Decodable { let id: LosslessStringID; let title: String; let parentID: LosslessStringID?; let sort: Int; enum CodingKeys: String, CodingKey { case id = "_id", title, parentID = "parent", sort }; init(from decoder: Decoder) throws { let c = try decoder.container(keyedBy: CodingKeys.self); id = try c.decode(LosslessStringID.self, forKey: .id); title = try c.decodeIfPresent(String.self, forKey: .title) ?? "Untitled collection"; parentID = try c.decodeIfPresent(RaindropCollectionReference.self, forKey: .parentID)?.id; sort = try c.decodeIfPresent(Int.self, forKey: .sort) ?? 0 } }
private struct RaindropItemDTO: Decodable { let id: LosslessStringID; let link: String?; let title: String?; let excerpt: String?; let created: String?; let lastUpdate: String?; let cover: String?; let type: String?; let file: RaindropFileDTO?; let tags: [String]; let collection: RaindropCollectionReference?
    enum CodingKeys: String, CodingKey { case id = "_id", link, title, excerpt, created, lastUpdate, cover, type, file, tags, collection }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(LosslessStringID.self, forKey: .id); link = try c.decodeIfPresent(String.self, forKey: .link); title = try c.decodeIfPresent(String.self, forKey: .title); excerpt = try c.decodeIfPresent(String.self, forKey: .excerpt); created = try c.decodeIfPresent(String.self, forKey: .created); lastUpdate = try c.decodeIfPresent(String.self, forKey: .lastUpdate); cover = try c.decodeIfPresent(String.self, forKey: .cover); type = try c.decodeIfPresent(String.self, forKey: .type); file = try c.decodeIfPresent(RaindropFileDTO.self, forKey: .file); tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []; collection = try c.decodeIfPresent(RaindropCollectionReference.self, forKey: .collection)
    }
    var item: ReadLaterItem? { let url = link.flatMap(URL.init(string:)); let raw = type?.lowercased() ?? ""; let mime = file?.type?.lowercased() ?? ""; let kind: ReadLaterKind = raw.contains("pdf") || mime == "application/pdf" || url?.pathExtension.lowercased() == "pdf" ? .pdf : raw.contains("video") ? .video : .article; return ReadLaterItem(provider: .raindrop, vendorID: id.stringValue, sourceURL: url, title: title, excerpt: excerpt, kind: kind, tags: tags, collectionIDs: collection.map { ["raindrop:collection:\($0.id.stringValue)"] } ?? [], thumbnailURL: cover.flatMap(URL.init(string:)), savedAt: IntegrationDateParser.parse(created), updatedAt: IntegrationDateParser.parse(lastUpdate), pdfRetrieval: kind == .pdf ? url.map(PDFRetrievalStrategy.raindropURL) : nil) }
}
private struct RaindropFileDTO: Decodable { let type: String? }
private struct RaindropCollectionReference: Decodable { let id: LosslessStringID; enum CodingKeys: String, CodingKey { case id = "$id" }; init(from decoder: Decoder) throws { if let single = try? LosslessStringID(from: decoder) { id = single } else { id = try decoder.container(keyedBy: CodingKeys.self).decode(LosslessStringID.self, forKey: .id) } } }
