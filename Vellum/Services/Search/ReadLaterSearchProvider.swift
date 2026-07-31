import Foundation

// The read-later integrations' bridge into home search — the provider the
// engine's design anticipated (issue #62). `IntegrationsStore` (main actor)
// publishes its cached corpus into `ReadLaterSearchSource` after every change;
// the provider turns that snapshot into `HomeSearchItem`s on the engine's
// actor, so typing in the search field never waits on the main actor or the
// network. Snapshot mode, not live: the items are already synced and cached
// locally, so there is nothing to defer to the provider's own search for.

/// Holds the latest read-later corpus where both actors can reach it: the main
/// actor replaces it after a sync/move/disconnect, the search engine reads it
/// on reload.
actor ReadLaterSearchSource {
    private(set) var items: [ReadLaterItem] = []

    func replace(_ items: [ReadLaterItem]) {
        self.items = items
    }
}

/// Cached articles from every connected read-later account.
struct ReadLaterSearchProvider: HomeSearchProvider {
    let id = "read-later"
    let displayName = "Read Later"
    let source: ReadLaterSearchSource

    func items(matching _: String) async throws -> [HomeSearchItem] {
        let now = Date()
        // Registered LAST in the provider list, so when the user already has a
        // local copy of an article (recents, saved webpages, library) the
        // local row wins the dedupe and opens offline; this row only exists
        // for articles that live nowhere else on this Mac.
        return await source.items.map { item in
            let url = item.sourceURL.absoluteString
            let name = HomeSearchItemBuilder.host(of: url) ?? url
            return HomeSearchItem(
                id: "\(id):\(item.id)",
                identity: HomeSearchItemBuilder.identity(url, kind: .web),
                section: .readLater,
                kind: .web,
                target: .url(url),
                title: item.title,
                subtitle: item.author.map { "\($0) · \(name)" } ?? name,
                detail: HomeSearchDateLabel.short(for: item.savedAt, now: now),
                tooltip: url,
                date: item.savedAt,
                badges: [],
                canRevealInFinder: false,
                haystack: HomeSearchHaystack(
                    title: item.title,
                    name: name,
                    location: url,
                    // The provider's name makes "readwise" or "raindrop" a
                    // usable query; tags/author/excerpt are the fields those
                    // services themselves match on.
                    extra: ([item.provider.name, item.author ?? "", item.excerpt ?? ""]
                        + item.tags).joined(separator: " ")),
                // No local record to key on — a remote article only gains a
                // storage folder once the user opens it.
                storageKey: nil)
        }
    }
}
