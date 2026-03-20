import Foundation
import GRDB

// MARK: - Supporting enums

enum CacheLevel: String, Codable, CaseIterable, DatabaseValueConvertible {
    case standard
    case full
}

enum FetchFrequency: String, Codable, CaseIterable, DatabaseValueConvertible {
    case manual
    case onOpen
    case automatic
}

enum SourceFetchStatus: String, Codable, DatabaseValueConvertible {
    case idle
    case fetching
    case error
}

enum AppearanceMode: String, Codable, CaseIterable, DatabaseValueConvertible {
    case system
    case light
    case dark
}

enum SourceLayout: String, Codable, CaseIterable, DatabaseValueConvertible {
    case list
    case cards
    case carousel
}

// MARK: - Source

struct Source: Identifiable, Codable, FetchableRecord, PersistableRecord {
    /// Well-known UUID for the hidden "Saved Pages" source that holds force-added webpages.
    static let savedPagesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    static let maxSources = 20

    var id: UUID
    var title: String
    var feedURL: String
    var siteURL: String?
    var iconURL: String?
    var addedAt: Date
    var lastFetchedAt: Date?
    var fetchFrequency: FetchFrequency
    var fetchStatus: SourceFetchStatus
    var cacheLevel: CacheLevel?
    var appearanceMode: AppearanceMode?
    var layout: SourceLayout?
    var homeLayout: SourceLayout?
    var sortOrder: Int

    /// Returns the per-source cache level, defaulting to .standard.
    var effectiveCacheLevel: CacheLevel {
        cacheLevel ?? .standard
    }

    /// Returns the per-source appearance mode, defaulting to .system.
    var effectiveAppearanceMode: AppearanceMode {
        appearanceMode ?? .system
    }

    /// Returns the per-source layout, defaulting to .list.
    var effectiveLayout: SourceLayout {
        layout ?? .list
    }

    /// Returns the per-source home layout, defaulting to .list.
    var effectiveHomeLayout: SourceLayout {
        homeLayout ?? .list
    }

    /// Whether this source is hidden from the main sources list (e.g. the "Saved Pages" source).
    var isHidden: Bool { id == Source.savedPagesID }

    /// Whether this source is a topic/search feed (e.g. Google News) where
    /// articles come from multiple different websites.
    var isTopicFeed: Bool {
        feedURL.contains("news.google.com")
    }

    static let databaseTableName = "source"
}

extension Source {
    static let articles = hasMany(Article.self)
    var articles: QueryInterfaceRequest<Article> {
        request(for: Source.articles)
    }

}
