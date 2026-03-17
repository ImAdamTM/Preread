import Foundation
import GRDB

struct CachedPage: Identifiable, Codable, FetchableRecord, PersistableRecord {
    /// Uses articleID as the primary key (one cached page per article).
    var articleID: UUID
    var htmlPath: String
    var assetManifest: [String]
    var cachedAt: Date
    var totalSizeBytes: Int
    var isTruncated: Bool
    var cacheLevelUsed: CacheLevel

    var id: UUID { articleID }

    static let databaseTableName = "cachedPage"
}

extension CachedPage {
    static let article = belongsTo(Article.self, using: ForeignKey(["articleID"]))
    var article: QueryInterfaceRequest<Article> {
        request(for: CachedPage.article)
    }
}
