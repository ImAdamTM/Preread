import Foundation
import GRDB

enum IntegrityChecker {
    /// Verifies that all cached articles still have their HTML files on disk.
    /// Resets any orphaned articles back to .pending and removes their CachedPage records.
    /// Also resets articles stuck in .fetching (orphaned by a mid-cache app kill).
    static func run() async {
        do {
            // Reset any articles stuck in .fetching back to .pending
            let stuckFetchingCount = try await DatabaseManager.shared.dbPool.write { db -> Int in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.fetching.rawValue)
                    .updateAll(db, Column("fetchStatus").set(to: ArticleFetchStatus.pending.rawValue))
            }
            if stuckFetchingCount > 0 {
                print("[IntegrityChecker] Reset \(stuckFetchingCount) article(s) stuck in fetching state.")
            }

            let cachedArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.cached.rawValue)
                    .fetchAll(db)
            }

            var resetCount = 0
            let fm = FileManager.default

            for var article in cachedArticles {
                let cachedPage = try await DatabaseManager.shared.dbPool.read { db in
                    try CachedPage
                        .filter(Column("articleID") == article.id)
                        .fetchOne(db)
                }

                guard let page = cachedPage else {
                    // No CachedPage record — reset article
                    article.fetchStatus = .pending
                    article.cachedAt = nil
                    article.cacheSizeBytes = nil
                    try await DatabaseManager.shared.dbPool.write { db in
                        try article.update(db)
                    }
                    resetCount += 1
                    continue
                }

                if !fm.fileExists(atPath: page.htmlPath) {
                    // HTML file missing — reset article and delete CachedPage
                    article.fetchStatus = .pending
                    article.cachedAt = nil
                    article.cacheSizeBytes = nil
                    try await DatabaseManager.shared.dbPool.write { db in
                        try CachedPage
                            .filter(Column("articleID") == article.id)
                            .deleteAll(db)
                        try article.update(db)
                    }
                    resetCount += 1
                }
            }

            if resetCount > 0 {
                print("[IntegrityChecker] Reset \(resetCount) article(s) with missing cache files.")
            }

            // Clean up shared assets no longer referenced by any article
            await PageCacheService.shared.cleanupOrphanedSharedAssets()
        } catch {
            print("[IntegrityChecker] Error during integrity check: \(error)")
        }
    }
}
