import Testing
import Foundation
@testable import Preread

// MARK: - Structural Validation

@Suite("Discover Feed Directory")
struct DiscoverFeedDirectoryTests {

    /// Loads discover_feeds.json from the app bundle (hosted tests) or project directory.
    static func loadDiscoverFeeds() throws -> [DiscoverFeed] {
        // Hosted tests: Bundle.main is the app bundle which contains the resource.
        if let url = Bundle.main.url(forResource: "discover_feeds", withExtension: "json") {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode([DiscoverFeed].self, from: data)
        }
        throw DiscoverFeedTestError.jsonNotFound
    }

    @Test("JSON loads and contains feeds")
    func jsonLoadsSuccessfully() throws {
        let feeds = try Self.loadDiscoverFeeds()
        #expect(feeds.count > 300, "Expected at least 300 feeds, got \(feeds.count)")
    }

    @Test("All feeds have valid feed URLs")
    func allFeedURLsAreValid() throws {
        let feeds = try Self.loadDiscoverFeeds()
        for feed in feeds {
            let url = URL(string: feed.feedURL)
            #expect(url != nil, "Invalid feed URL: \(feed.feedURL) for \(feed.name)")
            #expect(url?.scheme == "https", "Non-HTTPS feed URL: \(feed.feedURL) for \(feed.name)")
        }
    }

    @Test("All feeds have non-empty names")
    func allFeedNamesAreNonEmpty() throws {
        let feeds = try Self.loadDiscoverFeeds()
        for feed in feeds {
            #expect(!feed.name.isEmpty, "Empty name for feed: \(feed.feedURL)")
            #expect(!feed.name.lowercased().hasPrefix("blog feed"),
                    "Generic name '\(feed.name)' for \(feed.feedURL)")
            #expect(!feed.name.lowercased().hasPrefix("rss feed"),
                    "Generic name '\(feed.name)' for \(feed.feedURL)")
        }
    }

    @Test("All feeds have non-empty categories")
    func allFeedCategoriesAreNonEmpty() throws {
        let feeds = try Self.loadDiscoverFeeds()
        for feed in feeds {
            #expect(!feed.category.isEmpty, "Empty category for \(feed.name)")
        }
    }

    @Test("No duplicate feed URLs")
    func noDuplicateFeedURLs() throws {
        let feeds = try Self.loadDiscoverFeeds()
        var seen = Set<String>()
        for feed in feeds {
            let normalized = feed.feedURL.lowercased()
            #expect(seen.insert(normalized).inserted,
                    "Duplicate feed URL: \(feed.feedURL)")
        }
    }

    @Test("All IDs are unique")
    func allIDsAreUnique() throws {
        let feeds = try Self.loadDiscoverFeeds()
        var seen = Set<String>()
        for feed in feeds {
            #expect(seen.insert(feed.id).inserted,
                    "Duplicate ID: \(feed.id) for \(feed.name)")
        }
    }
}

// MARK: - Feed Parsing Validation

@Suite("Discover Feed Parsing")
struct DiscoverFeedParsingTests {
    let service = FeedService.shared

    /// Verifies a discover feed can be parsed by the same code path
    /// that runs when a user taps it in the app.
    private func assertDiscoverFeedParseable(_ feedURL: String, name: String) async throws {
        guard let url = URL(string: feedURL) else {
            Issue.record("Invalid URL: \(feedURL)")
            return
        }
        let feed = try await service.parseFeed(from: url)
        #expect(!feed.title.isEmpty, "\(name): feed title is empty")
        #expect(!feed.items.isEmpty, "\(name): feed has no items")
        for item in feed.items {
            #expect(!item.title.isEmpty, "\(name): item has empty title")
            #expect(item.url.scheme == "http" || item.url.scheme == "https",
                    "\(name): item URL has invalid scheme: \(item.url)")
        }
    }

    // MARK: - Custom feeds (hand-curated, must always work)

    @Test(.timeLimit(.minutes(1)))
    func parse_theVerge() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.theverge.com/rss/index.xml", name: "The Verge")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_engadget() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.engadget.com/rss.xml", name: "Engadget")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_wired() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.wired.com/feed/rss", name: "Wired")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_techCrunch() async throws {
        try await assertDiscoverFeedParseable(
            "https://techcrunch.com/feed/", name: "TechCrunch")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_macStories() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.macstories.net/feed/", name: "MacStories")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_daringFireball() async throws {
        try await assertDiscoverFeedParseable(
            "https://daringfireball.net/feeds/main", name: "Daring Fireball")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_nprNews() async throws {
        try await assertDiscoverFeedParseable(
            "https://feeds.npr.org/1001/rss.xml", name: "NPR News")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_polygon() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.polygon.com/rss/index.xml", name: "Polygon")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_avClub() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.avclub.com/rss.xml", name: "The A.V. Club")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_nature() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.nature.com/nature.rss", name: "Nature")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_hackingWithSwift() async throws {
        try await assertDiscoverFeedParseable(
            "https://www.hackingwithswift.com/articles/rss", name: "Hacking with Swift")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_sixColors() async throws {
        try await assertDiscoverFeedParseable(
            "https://feedpress.me/sixcolors", name: "Six Colors")
    }

    // MARK: - Sample from upstream OPML categories

    @Test(.timeLimit(.minutes(1)))
    func parse_9to5Mac() async throws {
        try await assertDiscoverFeedParseable(
            "https://9to5mac.com/feed/", name: "9to5Mac")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_arsTechnica() async throws {
        try await assertDiscoverFeedParseable(
            "https://feeds.arstechnica.com/arstechnica/index", name: "Ars Technica")
    }

    @Test(.timeLimit(.minutes(1)))
    func parse_bbcNews() async throws {
        try await assertDiscoverFeedParseable(
            "https://feeds.bbci.co.uk/news/rss.xml", name: "BBC News")
    }
}

// MARK: - Favicon Availability

@Suite("Discover Feed Favicons")
struct DiscoverFeedFaviconTests {
    let cacheService = PageCacheService.shared

    /// Verifies a favicon can be fetched from a site URL using the same
    /// code path that runs when displaying discover feed rows.
    private func assertFaviconAvailable(_ siteURLString: String, name: String) async throws {
        guard let siteURL = URL(string: siteURLString) else {
            Issue.record("\(name): invalid site URL: \(siteURLString)")
            return
        }
        let image = await cacheService.fetchFaviconImage(siteURL: siteURL)
        #expect(image != nil, "\(name): no favicon found for \(siteURLString)")
        if let image {
            #expect(image.size.width >= 16, "\(name): favicon too small (\(image.size.width)px)")
        }
    }

    // MARK: - Feeds that previously failed favicon loading

    @Test(.timeLimit(.minutes(1)))
    func favicon_bbcNews() async throws {
        try await assertFaviconAvailable("https://www.bbc.co.uk", name: "BBC News")
    }

    @Test(.timeLimit(.minutes(1)))
    func favicon_bbcNewsWorld() async throws {
        try await assertFaviconAvailable("https://www.bbc.co.uk/news/world", name: "BBC News World")
    }

    @Test(.timeLimit(.minutes(1)))
    func favicon_ndtv() async throws {
        try await assertFaviconAvailable("https://www.ndtv.com", name: "NDTV")
    }

    // MARK: - Verify siteURLs in discover_feeds.json point to real sites

    @Test("No discover feed siteURLs point to feed CDN domains")
    func siteURLs_notFeedCDNs() throws {
        let feeds = try DiscoverFeedDirectoryTests.loadDiscoverFeeds()
        let cdnDomains: Set<String> = [
            "feeds.feedburner.com", "feeds2.feedburner.com", "feedburner.com",
            "feedproxy.google.com", "feeds.feedblitz.com",
        ]
        let feedPrefixes = ["feeds.", "feeds2.", "rss.", "feed."]
        for feed in feeds {
            guard let siteURL = feed.siteURL,
                  let host = URL(string: siteURL)?.host?.lowercased() else { continue }
            let isCDN = cdnDomains.contains(host) ||
                feedPrefixes.contains(where: { host.hasPrefix($0) })
            #expect(!isCDN,
                    "\(feed.name): siteURL points to CDN/feed domain \(host)")
        }
    }

    // MARK: - Custom feeds (should all have working favicons)

    @Test(.timeLimit(.minutes(1)))
    func favicon_theVerge() async throws {
        try await assertFaviconAvailable("https://www.theverge.com", name: "The Verge")
    }

    @Test(.timeLimit(.minutes(1)))
    func favicon_engadget() async throws {
        try await assertFaviconAvailable("https://www.engadget.com", name: "Engadget")
    }

    @Test(.timeLimit(.minutes(1)))
    func favicon_arsTechnica() async throws {
        try await assertFaviconAvailable("https://arstechnica.com", name: "Ars Technica")
    }

    @Test(.timeLimit(.minutes(1)))
    func favicon_9to5Mac() async throws {
        try await assertFaviconAvailable("https://9to5mac.com", name: "9to5Mac")
    }

    @Test(.timeLimit(.minutes(1)))
    func favicon_avClub() async throws {
        try await assertFaviconAvailable("https://www.avclub.com", name: "The A.V. Club")
    }
}

// MARK: - Helpers

enum DiscoverFeedTestError: Error, CustomStringConvertible {
    case jsonNotFound

    var description: String {
        switch self {
        case .jsonNotFound:
            return "discover_feeds.json not found in test bundle or app bundle"
        }
    }
}
