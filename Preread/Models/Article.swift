import Foundation
import GRDB

enum ArticleFetchStatus: String, Codable, Hashable, DatabaseValueConvertible {
    case pending
    case fetching
    case cached
    case partial
    case failed
}

struct Article: Identifiable, Codable, Hashable, FetchableRecord, PersistableRecord {
    var id: UUID
    var sourceID: UUID
    var title: String
    var articleURL: String
    var publishedAt: Date?
    var addedAt: Date
    var thumbnailURL: String?
    var cachedAt: Date?
    var fetchStatus: ArticleFetchStatus
    var isRead: Bool
    var isSaved: Bool
    var savedAt: Date?
    var originalSourceName: String?
    var originalSourceIconURL: String?
    var cacheSizeBytes: Int?
    var lastHTTPStatus: Int?
    var etag: String?
    var lastModified: String?
    var retryCount: Int

    static let databaseTableName = "article"
}

extension Article {
    static let source = belongsTo(Source.self)
    var source: QueryInterfaceRequest<Source> {
        request(for: Article.source)
    }

    static let cachedPage = hasOne(CachedPage.self)
    var cachedPage: QueryInterfaceRequest<CachedPage> {
        request(for: Article.cachedPage)
    }
}
