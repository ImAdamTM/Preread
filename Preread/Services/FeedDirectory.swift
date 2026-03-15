import Foundation
import GRDB

/// Provides access to the bundled feed discovery directory.
/// Loads feeds lazily from `discover_feeds.json` in the app bundle.
final class FeedDirectory: @unchecked Sendable {
    static let shared = FeedDirectory()

    // MARK: - Public data

    /// All discover feeds, loaded lazily on first access.
    private(set) lazy var allFeeds: [DiscoverFeed] = loadFeeds()

    /// Topic categories (non-country), sorted by curated priority.
    private(set) lazy var categories: [CategoryInfo] = buildCategories(isCountry: false)

    /// Country categories, sorted alphabetically by name.
    private(set) lazy var countries: [CategoryInfo] = buildCategories(isCountry: true)

    struct CategoryInfo: Identifiable, Hashable {
        let id: String
        let name: String
        let feedCount: Int
        let icon: String
    }

    // MARK: - Search

    /// Fuzzy search across name, tags, description, and category.
    /// Returns results ranked by match quality, capped at `limit`.
    func search(_ query: String, limit: Int = 20) -> [DiscoverFeed] {
        let terms = query.lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var scored: [(feed: DiscoverFeed, score: Int)] = []

        for feed in allFeeds {
            let nameLower = feed.name.lowercased()
            var score = 0

            for term in terms {
                // Name prefix match (strongest signal)
                if nameLower.hasPrefix(term) {
                    score += 100
                } else if nameLower.contains(term) {
                    score += 80
                }

                // Tag prefix match
                for tag in feed.tags {
                    if tag.lowercased().hasPrefix(term) {
                        score += 60
                        break
                    }
                }

                // Category match
                if feed.category.lowercased().contains(term) {
                    score += 40
                }

                // Country match
                if let country = feed.country, country.lowercased().contains(term) {
                    score += 40
                }

                // Description match (weakest signal)
                if feed.description.lowercased().contains(term) {
                    score += 20
                }
            }

            if score > 0 {
                scored.append((feed, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.feed)
    }

    // MARK: - Category filtering

    /// Returns feeds in a given category, sorted alphabetically.
    func feeds(in category: String) -> [DiscoverFeed] {
        allFeeds
            .filter { $0.category == category }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Subscription check

    /// Returns the set of normalized feed URLs that the user is already subscribed to.
    /// URLs are normalized so that trivial differences (scheme, www prefix, trailing slash)
    /// don't prevent matching against discover feed entries.
    func subscribedFeedURLs() -> Set<String> {
        do {
            return try DatabaseManager.shared.dbPool.read { db in
                let urls = try String.fetchAll(db, sql: "SELECT feedURL FROM source")
                return Set(urls.map { Self.normalizeURL($0) })
            }
        } catch {
            return []
        }
    }

    /// Returns the set of normalized site URLs from the user's subscribed sources.
    /// This catches cases where a discover feed has a different feed URL path
    /// than what the user added (e.g. polygon.com/feed vs polygon.com/rss/index.xml)
    /// while still allowing multiple feeds from the same domain (e.g. BBC Science vs BBC World)
    /// because their siteURLs differ.
    func subscribedSiteURLs() -> Set<String> {
        do {
            return try DatabaseManager.shared.dbPool.read { db in
                let siteURLs = try String.fetchAll(db, sql: "SELECT siteURL FROM source WHERE siteURL IS NOT NULL")
                return Set(siteURLs.map { Self.normalizeURL($0) })
            }
        } catch {
            return []
        }
    }

    /// Normalizes a feed URL for comparison: lowercases host, strips www., removes trailing slash,
    /// and drops the scheme so that http and https variants match.
    static func normalizeURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString.lowercased()
        }
        // Drop scheme
        components.scheme = nil
        // Lowercase and strip www.
        if let host = components.host?.lowercased() {
            components.host = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
        // Remove trailing slash from path
        if components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        // Remove fragment
        components.fragment = nil
        return components.string ?? urlString.lowercased()
    }

    /// Finds the existing Source whose feedURL matches the given URL after normalization,
    /// or whose siteURL matches the discover feed's siteURL (for different feed URL paths
    /// serving the same content, e.g. polygon.com/feed vs polygon.com/rss/index.xml).
    func findExistingSource(feedURL: String, siteURL: String? = nil) -> Source? {
        let normalized = Self.normalizeURL(feedURL)
        let normalizedSite = siteURL.map { Self.normalizeURL($0) }
        do {
            return try DatabaseManager.shared.dbPool.read { db in
                let sources = try Source.fetchAll(db)
                // First try exact feed URL match
                if let match = sources.first(where: { Self.normalizeURL($0.feedURL) == normalized }) {
                    return match
                }
                // Fall back to siteURL match (catches same-site different-feed-path)
                guard let normalizedSite else { return nil }
                return sources.first { source in
                    guard let sourceSite = source.siteURL else { return false }
                    return Self.normalizeURL(sourceSite) == normalizedSite
                }
            }
        } catch {
            return nil
        }
    }

    // MARK: - Private

    private func loadFeeds() -> [DiscoverFeed] {
        guard let url = Bundle.main.url(forResource: "discover_feeds", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let feeds = try? JSONDecoder().decode([DiscoverFeed].self, from: data)
        else { return [] }
        return feeds
    }

    private func buildCategories(isCountry: Bool) -> [CategoryInfo] {
        let grouped = Dictionary(grouping: allFeeds, by: \.category)
        let filtered = grouped.filter { (_, feeds) in
            let hasCountry = feeds.contains { $0.country != nil }
            return isCountry ? hasCountry : !hasCountry
        }
        return filtered
            .map { (category, feeds) in
                let icon: String
                if isCountry {
                    icon = Self.countryIcons[category] ?? "globe"
                } else {
                    icon = Self.categoryIcons[category] ?? "square.grid.2x2"
                }
                return CategoryInfo(
                    id: category,
                    name: category,
                    feedCount: feeds.count,
                    icon: icon
                )
            }
            .sorted {
                if isCountry {
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                } else {
                    let aIndex = Self.categoryOrder.firstIndex(of: $0.name) ?? Int.max
                    let bIndex = Self.categoryOrder.firstIndex(of: $1.name) ?? Int.max
                    if aIndex != bIndex { return aIndex < bIndex }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
    }

    /// Curated display order for topic categories — broad appeal first, niche later.
    /// Categories not in this list appear at the end, sorted alphabetically.
    private static let categoryOrder: [String] = [
        "News",
        "Tech",
        "Apple",
        "Science",
        "Gaming",
        "Sports",
        "Business & Economy",
        "Startups",
        "Programming",
        "iOS Development",
        "Android Development",
        "Web Development",
        "UI / UX",
        "Food",
        "Music",
        "Movies",
        "Television",
        "Books",
        "Travel",
        "Space",
        "Photography",
        "Cars",
        "Fashion",
        "Beauty",
        "Architecture",
        "Interior design",
        "DIY",
        "Funny",
        "Football",
        "Tennis",
        "Cricket",
        "Android",
        "Personal finance",
        "History",
    ]

    private static let categoryIcons: [String: String] = [
        "News": "newspaper",
        "Programming": "chevron.left.forwardslash.chevron.right",
        "Food": "fork.knife",
        "Android Development": "apps.iphone",
        "Cars": "car",
        "iOS Development": "iphone",
        "Android": "apps.iphone",
        "Gaming": "gamecontroller",
        "Apple": "apple.logo",
        "Funny": "face.smiling",
        "Architecture": "building.2",
        "Tech": "desktopcomputer",
        "Photography": "camera",
        "UI / UX": "paintpalette",
        "Movies": "film",
        "DIY": "hammer",
        "Business & Economy": "chart.line.uptrend.xyaxis",
        "Startups": "lightbulb",
        "Fashion": "tshirt",
        "Music": "music.note",
        "Books": "book",
        "Tennis": "tennisball",
        "Space": "sparkles",
        "Web Development": "globe",
        "Travel": "airplane",
        "Sports": "sportscourt",
        "Television": "tv",
        "Beauty": "sparkle",
        "Football": "soccerball",
        "Cricket": "cricket.ball",
        "Science": "atom",
        "History": "clock.arrow.circlepath",
        "Personal finance": "dollarsign.circle",
        "Interior design": "sofa",
    ]

    private static let countryIcons: [String: String] = [
        "United States": "globe.americas",
        "Canada": "globe.americas",
        "Mexico": "globe.americas",
        "Brazil": "globe.americas",
        "United Kingdom": "globe.europe.africa",
        "Ireland": "globe.europe.africa",
        "France": "globe.europe.africa",
        "Germany": "globe.europe.africa",
        "Italy": "globe.europe.africa",
        "Spain": "globe.europe.africa",
        "Poland": "globe.europe.africa",
        "Ukraine": "globe.europe.africa",
        "Russia": "globe.europe.africa",
        "Nigeria": "globe.europe.africa",
        "South Africa": "globe.europe.africa",
        "India": "globe.asia.australia",
        "Pakistan": "globe.asia.australia",
        "Bangladesh": "globe.asia.australia",
        "Iran": "globe.asia.australia",
        "Japan": "globe.asia.australia",
        "Philippines": "globe.asia.australia",
        "Indonesia": "globe.asia.australia",
        "Australia": "globe.asia.australia",
        "Hong Kong SAR China": "globe.asia.australia",
        "Myanmar (Burma)": "globe.asia.australia",
    ]
}
