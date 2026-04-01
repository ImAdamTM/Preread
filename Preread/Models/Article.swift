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
    var readingMinutes: Int?
    var rssContentHTML: String?

    static let databaseTableName = "article"
}

extension Article {
    /// Returns a display-friendly origin for the article.
    /// Prefers the RSS `<source>` publisher name when available,
    /// otherwise extracts a clean domain from the article URL.
    var displayDomain: String? {
        if let name = originalSourceName, !name.isEmpty {
            return name
        }
        guard let url = URL(string: articleURL),
              var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host = String(host.dropFirst(4)) }
        return host
    }

    static let source = belongsTo(Source.self)
    var source: QueryInterfaceRequest<Source> {
        request(for: Article.source)
    }

    static let cachedPage = hasOne(CachedPage.self)
    var cachedPage: QueryInterfaceRequest<CachedPage> {
        request(for: Article.cachedPage)
    }
}
