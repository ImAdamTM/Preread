import Foundation
import GRDB

// MARK: - Supporting enums

enum CacheLevel: String, Codable, CaseIterable, DatabaseValueConvertible {
    case textOnly
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

// MARK: - Source

struct Source: Identifiable, Codable, FetchableRecord, PersistableRecord {
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
    var sortOrder: Int

    /// Returns the per-source cache level, defaulting to .standard.
    var effectiveCacheLevel: CacheLevel {
        cacheLevel ?? .standard
    }

    /// Returns the per-source appearance mode, defaulting to .system.
    var effectiveAppearanceMode: AppearanceMode {
        appearanceMode ?? .system
    }

    static let databaseTableName = "source"
}

extension Source {
    static let articles = hasMany(Article.self)
    var articles: QueryInterfaceRequest<Article> {
        request(for: Source.articles)
    }
}
