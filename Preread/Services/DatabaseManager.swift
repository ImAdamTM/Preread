import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    let dbPool: DatabasePool

    private init() {
        do {
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let prereadDir = appSupport.appendingPathComponent("preread", isDirectory: true)

            if !fileManager.fileExists(atPath: prereadDir.path) {
                try fileManager.createDirectory(at: prereadDir, withIntermediateDirectories: true)
            }

            // Exclude from iCloud backup
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            var mutableDir = prereadDir
            try mutableDir.setResourceValues(resourceValues)

            let dbPath = prereadDir.appendingPathComponent("preread.db").path
            dbPool = try DatabasePool(path: dbPath)

            var migrator = DatabaseMigrator()
            Self.registerMigrations(&migrator)
            try migrator.migrate(dbPool)
        } catch {
            fatalError("DatabaseManager failed to initialise: \(error)")
        }
    }

    private static func registerMigrations(_ migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1-create-tables") { db in
            // source table
            try db.create(table: "source") { t in
                t.primaryKey("id", .text).notNull()
                t.column("title", .text).notNull()
                t.column("feedURL", .text).notNull().unique()
                t.column("siteURL", .text)
                t.column("iconURL", .text)
                t.column("addedAt", .datetime).notNull()
                t.column("lastFetchedAt", .datetime)
                t.column("fetchFrequency", .text).notNull().defaults(to: "automatic")
                t.column("fetchStatus", .text).notNull().defaults(to: "idle")
                t.column("cacheLevel", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // article table
            try db.create(table: "article") { t in
                t.primaryKey("id", .text).notNull()
                t.column("sourceID", .text).notNull()
                    .references("source", onDelete: .cascade)
                t.column("title", .text).notNull()
                t.column("articleURL", .text).notNull().unique()
                t.column("publishedAt", .datetime)
                t.column("thumbnailURL", .text)
                t.column("cachedAt", .datetime)
                t.column("fetchStatus", .text).notNull().defaults(to: "pending")
                t.column("isRead", .boolean).notNull().defaults(to: false)
                t.column("cacheSizeBytes", .integer)
                t.column("lastHTTPStatus", .integer)
                t.column("etag", .text)
                t.column("lastModified", .text)
            }

            // cachedPage table
            try db.create(table: "cachedPage") { t in
                t.primaryKey("articleID", .text).notNull()
                    .references("article", onDelete: .cascade)
                t.column("htmlPath", .text).notNull()
                t.column("assetManifest", .text).notNull().defaults(to: "[]")
                t.column("cachedAt", .datetime).notNull()
                t.column("totalSizeBytes", .integer).notNull().defaults(to: 0)
                t.column("isTruncated", .boolean).notNull().defaults(to: false)
                t.column("cacheLevelUsed", .text).notNull()
            }
        }

        migrator.registerMigration("v2-appearance-mode") { db in
            try db.alter(table: "source") { t in
                t.add(column: "appearanceMode", .text)
            }
        }

        migrator.registerMigration("v3-article-isSaved") { db in
            try db.alter(table: "article") { t in
                t.add(column: "isSaved", .boolean).notNull().defaults(to: false)
            }
        }

        migrator.registerMigration("v4-dark-html-path") { db in
            try db.alter(table: "cachedPage") { t in
                t.add(column: "darkHtmlPath", .text)
            }
        }

        migrator.registerMigration("v5-remove-textOnly-cache-level") { db in
            try db.execute(sql: "UPDATE source SET cacheLevel = 'standard' WHERE cacheLevel = 'textOnly'")
            try db.execute(sql: "UPDATE cachedPage SET cacheLevelUsed = 'standard' WHERE cacheLevelUsed = 'textOnly'")
        }
    }
}
