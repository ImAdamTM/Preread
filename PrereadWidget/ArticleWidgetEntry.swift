import WidgetKit
import UIKit

struct ArticleWidgetEntry: TimelineEntry {
    let date: Date
    let articles: [WidgetArticle]
    let configuration: SelectSourceIntent

    var isEmpty: Bool { articles.isEmpty }
}

struct WidgetArticle: Identifiable {
    let id: UUID
    let title: String
    let sourceName: String
    let publishedAt: Date?
    let readingMinutes: Int?
    let thumbnailImage: UIImage?
    let faviconImage: UIImage?
    let deepLinkURL: URL
}
