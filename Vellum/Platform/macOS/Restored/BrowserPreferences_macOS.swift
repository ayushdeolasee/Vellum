#if os(macOS)
import Foundation
import WebKit

enum BrowserSearchEngine: String, CaseIterable {
    case duckDuckGo, google, bing

    static let defaultsKey = "browser.searchEngine"

    static var current: Self {
        Self(rawValue: AppDefaults.current.string(forKey: defaultsKey) ?? "") ?? .duckDuckGo
    }

    var label: String {
        switch self {
        case .duckDuckGo: "DuckDuckGo"
        case .google: "Google"
        case .bing: "Bing"
        }
    }

    func searchURL(for query: String) -> URL? {
        let base: String
        switch self {
        case .duckDuckGo: base = "https://duckduckgo.com/"
        case .google: base = "https://www.google.com/search"
        case .bing: base = "https://www.bing.com/search"
        }
        var components = URLComponents(string: base)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

/// Every companion page, including recreated controllers and login pop-ups,
/// uses the same profile. WebKit owns cookies and site-issued login tokens.
@MainActor
enum BrowserWebsiteData {
    static let store: WKWebsiteDataStore = {
        if TestEnvironment.storageRoot != nil { return .nonPersistent() }
        return .default()
    }()

    static let didClear = Notification.Name("vellum.browser-website-data-cleared")
}
#endif
