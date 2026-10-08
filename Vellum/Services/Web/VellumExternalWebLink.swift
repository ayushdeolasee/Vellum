import Foundation

/// The narrow URL route used by browser extensions to hand one webpage to Vellum.
enum VellumExternalWebLink {
    static var scheme: String { RuntimeProfile.current.urlScheme }
    static let host = "open-url"
    static let saveHost = "save-url"

    static func url(for webpage: URL, saveToLibrary: Bool = false) -> URL? {
        guard isSupported(webpage) else { return nil }

        var components = URLComponents()
        components.scheme = scheme
        components.host = saveToLibrary ? saveHost : host
        components.queryItems = [URLQueryItem(name: "url", value: webpage.absoluteString)]
        return components.url
    }

    static func parse(_ url: URL) -> URL? {
        parse(url, expectedHost: host)
    }

    static func parseSavedURL(_ url: URL) -> URL? {
        parse(url, expectedHost: saveHost)
    }

    private static func parse(_ url: URL, expectedHost: String) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == scheme,
              components.host?.lowercased() == expectedHost,
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
              let host = url.host, !host.isEmpty
        else { return false }
        return true
    }
}
