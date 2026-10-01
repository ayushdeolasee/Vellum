import Foundation

struct VellumSystemRoute: Equatable, Hashable, Sendable {
    let shelf: VellumWidgetShelf
    let itemID: String

    static func isValidItemID(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}

/// A deliberately tiny URL grammar: `vellum://open/<shelf>?id=<sha256>`.
/// Paths, provider identifiers, and web addresses never cross the URL boundary.
enum VellumDeepLink {
    static var scheme: String { RuntimeProfile.current.urlScheme }
    static let host = "open"

    static func url(for route: VellumSystemRoute) -> URL? {
        guard VellumSystemRoute.isValidItemID(route.itemID) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/\(route.shelf.rawValue)"
        components.queryItems = [URLQueryItem(name: "id", value: route.itemID)]
        return components.url
    }

    static func parse(_ url: URL) -> VellumSystemRoute? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "id",
              let itemID = components.queryItems?.first?.value,
              VellumSystemRoute.isValidItemID(itemID)
        else { return nil }

        let pathParts = components.path.split(separator: "/")
        guard pathParts.count == 1,
              let shelf = VellumWidgetShelf(rawValue: String(pathParts[0]))
        else { return nil }

        return VellumSystemRoute(shelf: shelf, itemID: itemID)
    }
}
