import AppIntents
import Foundation
import GRDB
import WidgetKit

extension Source {
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

        // 5. Refresh widget timelines and push updated data to watch
        WidgetCenter.shared.reloadAllTimelines()
        WatchConnectivityManager.shared.pushArticlesToWatch()

        // 6. Update App Shortcuts so the deleted source is no longer offered
        PrereadShortcutsProvider.updateAppShortcutParameters()
    }
}
