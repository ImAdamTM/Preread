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

// MARK: - Source

struct Source: Identifiable, Codable, FetchableRecord, PersistableRecord {
    /// Well-known UUID for the hidden "Saved Pages" source that holds force-added webpages.
    static let savedPagesID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

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

    /// Whether this source is hidden from the main sources list (e.g. the "Saved Pages" source).
    var isHidden: Bool { id == Source.savedPagesID }

    static let databaseTableName = "source"
}

extension Source {
    static let articles = hasMany(Article.self)
    var articles: QueryInterfaceRequest<Article> {
        request(for: Source.articles)
    }

    /// Deletes a source and all its data, preserving saved articles by moving
    /// them to the hidden "Saved Pages" source with attribution stamps.
    static func deleteWithCleanup(_ source: Source) async throws {
        // 1. Move saved articles to the hidden "Saved Pages" source so they
        //    survive the CASCADE delete that follows. Stamp original source
        //    info so attribution is preserved after the source is deleted.
        try await DatabaseManager.shared.dbPool.write { db in
            try db.execute(
                sql: """
                    UPDATE article
                    SET sourceID = ?,
                        originalSourceName = COALESCE(originalSourceName, ?),
                        originalSourceIconURL = COALESCE(originalSourceIconURL, ?)
                    WHERE sourceID = ? AND isSaved = 1
                    """,
                arguments: [Source.savedPagesID, source.title, source.iconURL, source.id]
            )
        }

        // 2. Delete cached files for unsaved articles (saved ones were moved)
        let articles = try await DatabaseManager.shared.dbPool.read { db in
            try Article
                .filter(Column("sourceID") == source.id)
                .fetchAll(db)
        }
        for article in articles {
            try? await PageCacheService.shared.deleteCachedArticle(article.id)
        }

        // 3. Delete cached source data (favicon, etc.)
        try? await PageCacheService.shared.deleteSourceCache(source.id)

        // 4. Delete source (cascades to remaining unsaved articles + cachedPages)
        _ = try await DatabaseManager.shared.dbPool.write { db in
            try Source.deleteOne(db, key: source.id)
        }
    }
}
