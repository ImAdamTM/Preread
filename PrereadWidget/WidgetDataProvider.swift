import Foundation
import GRDB
import UIKit

/// Read-only data provider for the widget extension.
/// Opens the shared database in read-only mode to fetch articles, sources,
/// and load cached thumbnail/favicon images from disk.
struct WidgetDataProvider {
    private let dbQueue: DatabaseQueue

    init?() {
        let dbPath = ContainerPaths.databasePath
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        do {
            var config = Configuration()
            config.readonly = true
            dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
        } catch {
            return nil
        }
    }

    /// Fetches recent articles with thumbnails, newest first.
    /// If sourceID is nil, returns articles from all sources (excluding "Saved Pages").
    func fetchArticles(sourceID: UUID? = nil, limit: Int = 10, requireThumbnail: Bool = true) -> [(article: Article, sourceName: String)] {
        do {
            return try dbQueue.read { db in
                var sql = """
                    SELECT article.*, source.title AS sourceName
                    FROM article
                    INNER JOIN source ON source.id = article.sourceID
                    WHERE article.fetchStatus IN ('cached', 'partial')
                    """

                if requireThumbnail {
                    sql += " AND article.thumbnailURL IS NOT NULL"
                }

                var arguments: [DatabaseValueConvertible] = []

                if let sourceID {
                    sql += " AND article.sourceID = ?"
                    arguments.append(sourceID)
                } else {
                    sql += " AND article.sourceID != ?"
                    arguments.append(Source.savedPagesID)
                }

                sql += " ORDER BY COALESCE(article.publishedAt, article.addedAt) DESC LIMIT ?"
                arguments.append(limit)

                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(arguments))

                return rows.compactMap { row in
                    guard let article = try? Article(row: row) else { return nil }
                    let sourceName: String = row["sourceName"] ?? ""
                    return (article, sourceName)
                }
            }
        } catch {
            return []
        }
    }

    /// Loads the thumbnail image for an article from the shared container.
    func loadThumbnail(for articleID: UUID) -> UIImage? {
        let articleDir = ContainerPaths.articlesBaseURL
            .appendingPathComponent(articleID.uuidString, isDirectory: true)

        // Prefer the 600px thumbnail for widget display
        let thumbnailPath = articleDir.appendingPathComponent("thumbnail.jpg")
        if let data = try? Data(contentsOf: thumbnailPath),
           let image = UIImage(data: data) {
            return image
        }

        // Fall back to 240px thumb
        let thumbPath = articleDir.appendingPathComponent("thumb.jpg")
        if let data = try? Data(contentsOf: thumbPath),
           let image = UIImage(data: data) {
            return image
        }

        return nil
    }

    /// Loads the favicon for a source from the shared container.
    func loadFavicon(for sourceID: UUID) -> UIImage? {
        let path = ContainerPaths.sourcesBaseURL
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("favicon.png")
        guard let data = try? Data(contentsOf: path) else { return nil }
        return UIImage(data: data)
    }

    /// Fetches all user sources (excluding "Saved Pages") for the configuration picker.
    func fetchSources() -> [Source] {
        (try? dbQueue.read { db in
            try Source
                .filter(Column("id") != Source.savedPagesID)
                .order(Column("sortOrder"))
                .fetchAll(db)
        }) ?? []
    }

    /// Checks if a source with the given ID exists.
    func sourceExists(_ sourceID: UUID) -> Bool {
        (try? dbQueue.read { db in
            try Source.fetchOne(db, key: sourceID) != nil
        }) ?? false
    }
}
