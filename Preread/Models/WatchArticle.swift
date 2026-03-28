import Foundation

/// Lightweight article model for Watch Connectivity transfer.
/// Shared between the main app (serialization) and watch app/widget (deserialization).
struct WatchArticle: Codable, Identifiable {
    let id: UUID
    let title: String
    let sourceName: String
    let publishedAt: Date?
    let readingMinutes: Int?
    let isRead: Bool
    let excerpt: String?
    let thumbnailData: Data?
    var isSaved: Bool
    let articleURL: String?

    init(id: UUID, title: String, sourceName: String, publishedAt: Date?, readingMinutes: Int?, isRead: Bool, excerpt: String? = nil, thumbnailData: Data? = nil, isSaved: Bool = false, articleURL: String? = nil) {
        self.id = id
        self.title = title
        self.sourceName = sourceName
        self.publishedAt = publishedAt
        self.readingMinutes = readingMinutes
        self.isRead = isRead
        self.excerpt = excerpt
        self.thumbnailData = thumbnailData
        self.isSaved = isSaved
        self.articleURL = articleURL
    }
}
