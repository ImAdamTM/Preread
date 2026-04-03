import Foundation
import GRDB

enum IntegrityChecker {
    /// Lightweight check that resets articles stuck in .fetching back to
    /// .pending. Called on foreground resume so the UI stops showing a
    /// spinner for articles whose cache task was interrupted (e.g. by a
    /// cancelled background task or app suspension).
    static func resetStaleFetchingArticles() async {
        do {
            let count = try await DatabaseManager.shared.dbPool.write { db -> Int in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.fetching.rawValue)
                    .updateAll(db, Column("fetchStatus").set(to: ArticleFetchStatus.pending.rawValue))
            }
            if count > 0 {
                print("[IntegrityChecker] Reset \(count) stale fetching article(s) on foreground.")
            }
        } catch {
            // Non-critical
        }
    }

    /// Verifies that all cached articles still have their HTML files on disk.
    /// Resets any orphaned articles back to .pending and removes their CachedPage records.
    /// Also resets articles stuck in .fetching (orphaned by a mid-cache app kill)
    /// and removes duplicate articles within the same source (same title, different URL).
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

            // Remove duplicate articles within the same source (same title).
            // Google News feeds can return the same article with different
            // redirect URLs across fetches, creating duplicates.
            await removeDuplicateArticles()

            let cachedArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(
                        Column("fetchStatus") == ArticleFetchStatus.cached.rawValue ||
                        Column("fetchStatus") == ArticleFetchStatus.partial.rawValue
                    )
                    .fetchAll(db)
            }

            var resetCount = 0

            for var article in cachedArticles {
                // Check whether actual cached HTML exists at the current
                // container path (computed dynamically). Don't rely on the
                // stored absolute htmlPath in CachedPage — it goes stale
                // when the simulator container UUID changes between builds.
                let hasContent = await PageCacheService.shared.hasCachedContent(for: article)

                if !hasContent {
                    // Content missing — reset article and delete CachedPage
                    article.fetchStatus = .pending
                    article.cachedAt = nil
                    article.cacheSizeBytes = nil
                    let snapshot = article
                    try await DatabaseManager.shared.dbPool.write { db in
                        try CachedPage
                            .filter(Column("articleID") == snapshot.id)
                            .deleteAll(db)
                        try snapshot.update(db)
                    }
                    resetCount += 1
                }
            }

            if resetCount > 0 {
                print("[IntegrityChecker] Reset \(resetCount) article(s) with missing cache files.")
            }

            // Delete orphaned saved-page articles (unsaved via a code path
            // that didn't fully clean up the Article + CachedPage records)
            await deleteOrphanedSavedPages()

            // Clean up shared assets no longer referenced by any article
            await PageCacheService.shared.cleanupOrphanedSharedAssets()
        } catch {
            print("[IntegrityChecker] Error during integrity check: \(error)")
        }
    }

    /// Deletes saved-page articles that were unsaved but not fully cleaned up.
    /// These have sourceID == savedPagesID and isSaved == false, meaning they
    /// no longer belong to any feed and serve no purpose.
    private static func deleteOrphanedSavedPages() async {
        do {
            let orphans = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == Source.savedPagesID)
                    .filter(Column("isSaved") == false)
                    .fetchAll(db)
            }

            guard !orphans.isEmpty else { return }

            for article in orphans {
                try? await PageCacheService.shared.deleteCachedArticle(article.id)
                _ = try? await DatabaseManager.shared.dbPool.write { db in
                    try Article.deleteOne(db, key: article.id)
                }
            }

            print("[IntegrityChecker] Deleted \(orphans.count) orphaned saved-page article(s).")
        } catch {
            print("[IntegrityChecker] Error cleaning orphaned saved pages: \(error)")
        }
    }

    /// Finds articles with the same title within the same source and removes
    /// duplicates, keeping the best copy (cached > partial > pending > failed,
    /// then oldest addedAt as tiebreaker).
    private static func removeDuplicateArticles() async {
        do {
            // Load all articles grouped by source, then find title collisions
            let allArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article.order(Column("addedAt")).fetchAll(db)
            }

            // Group by (sourceID, title)
            var grouped: [String: [Article]] = [:]
            for article in allArticles {
                let key = "\(article.sourceID.uuidString)|\(article.title)"
                grouped[key, default: []].append(article)
            }

            var removedCount = 0

            for (_, articles) in grouped {
                guard articles.count > 1 else { continue }

                // Pick the best article to keep: prefer cached content
                let keeper = articles.max { a, b in
                    statusPriority(a.fetchStatus) < statusPriority(b.fetchStatus)
                } ?? articles[0]

                let toRemove = articles.filter { $0.id != keeper.id }

                for article in toRemove {
                    try? await PageCacheService.shared.deleteCachedArticle(article.id)
                    _ = try await DatabaseManager.shared.dbPool.write { db in
                        try Article.deleteOne(db, key: article.id)
                    }
                    removedCount += 1
                }
            }

            if removedCount > 0 {
                print("[IntegrityChecker] Removed \(removedCount) duplicate article(s).")
            }
        } catch {
            print("[IntegrityChecker] Error removing duplicates: \(error)")
        }
    }

    /// Priority ranking for fetch statuses when choosing which duplicate to keep.
    /// Higher value = better (more worth keeping).
    private static func statusPriority(_ status: ArticleFetchStatus) -> Int {
        switch status {
        case .cached: return 4
        case .partial: return 3
        case .pending: return 2
        case .fetching: return 1
        case .failed: return 0
        }
    }
}
