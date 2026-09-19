import Foundation

/// The narrow URL route used by browser extensions to hand one webpage to Vellum.
enum VellumExternalWebLink {
    static let scheme = "vellum"
    static let host = "open-url"

    static func url(for webpage: URL) -> URL? {
        guard isSupported(webpage) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "url", value: webpage.absoluteString)]
        return components.url
    }

    static func parse(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == host,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.path.isEmpty,
              components.fragment == nil,
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "url",
              let value = components.queryItems?.first?.value,
              let webpage = URL(string: value),
              isSupported(webpage)
        else { return nil }

        return webpage
    }

    private static func isSupported(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil
        else { return false }
        return true
    }
}
