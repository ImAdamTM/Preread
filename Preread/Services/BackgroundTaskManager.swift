import UIKit
import BackgroundTasks
import GRDB
import os.log
import WidgetKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BackgroundTaskManager.registerTasks()
        return true
    }
}

enum BackgroundTaskManager {
    static let refreshTaskID = "com.preread.refresh"
    static let processingTaskID = "com.preread.process"

    private static let logger = Logger(subsystem: "com.preread", category: "BackgroundTaskManager")

    // MARK: - Registration (called from AppDelegate)

    static func registerTasks() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: refreshTaskID, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            handleRefreshTask(task)
        }

        BGTaskScheduler.shared.register(forTaskWithIdentifier: processingTaskID, using: nil) { task in
            guard let task = task as? BGProcessingTask else { return }
            handleProcessingTask(task)
        }
    }

    // MARK: - Scheduling

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60) // 15 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled refresh task")
        } catch {
            logger.error("Failed to schedule refresh: \(error.localizedDescription)")
        }
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            logger.info("Scheduled processing task")
        } catch {
            logger.error("Failed to schedule processing: \(error.localizedDescription)")
        }
    }

    // MARK: - Refresh handler (~30s budget: parse feeds + insert articles)

    private static func handleRefreshTask(_ task: BGAppRefreshTask) {
        logger.info("Refresh task started")
        // Re-submit next request immediately
        scheduleRefresh()

        let workTask = Task {
            await refreshFeeds()
        }

        task.expirationHandler = {
            logger.warning("Refresh task expired by system")
            workTask.cancel()
        }

        Task {
            await workTask.value
            WidgetCenter.shared.reloadAllTimelines()
            WatchConnectivityManager.shared.pushArticlesToWatch()
            logger.info("Refresh task completed")
            task.setTaskCompleted(success: true)
        }
    }

    /// Pending item waiting to be cached during background refresh.
    private struct PendingItem {
        let feedItem: FeedItem
        let source: Source
    }

    /// Parses all source feeds and inserts new articles as `.pending`.
    /// This is intentionally lightweight — no page caching happens here so the
    /// work can complete within the ~30-second BGAppRefreshTask budget.
    /// The heavier processing task handles the actual caching afterwards.
    private static func refreshFeeds() async {
        guard !NetworkMonitor.shouldSkipForWiFiOnly else {
            logger.info("Skipping refresh — WiFi-only mode and not on WiFi")
            return
        }
        do {
            let sources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("id") != Source.savedPagesID)
                    .filter(Column("fetchFrequency") == FetchFrequency.automatic.rawValue)
                    .fetchAll(db)
            }

            logger.info("Refreshing \(sources.count) automatic sources")

            // Phase 1: Parse all feeds (fast) and collect new items per source.
            // Re-attach any saved articles that were detached.
            var queues: [[PendingItem]] = []

            for source in sources {
                guard !Task.isCancelled else { return }
                guard let feedURL = URL(string: source.feedURL) else { continue }

                do {
                    let feed = try await FeedService.shared.parseFeed(
                        from: feedURL,
                        siteURL: source.siteURL.flatMap { URL(string: $0) }
                    )

                    var newItems: [PendingItem] = []
                    var seenTitles = Set<String>()

                    // Sort newest first so the round-robin picks the most
                    // recent article from each source first.
                    let sortedItems = feed.items.sorted {
                        ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast)
                    }

                    for item in sortedItems {
                        // Skip duplicate titles (Google News feeds can contain
                        // the same article with different redirect URLs)
                        guard seenTitles.insert(item.title).inserted else { continue }

                        // Skip URLs that are clearly not articles (login pages,
                        // auth endpoints, account portals, etc.)
                        guard !FetchCoordinator.isNonArticleURL(item.url) else { continue }

                        let existing = try await DatabaseManager.shared.dbPool.read { db in
                            try Article
                                .filter(Column("articleURL") == item.url.absoluteString)
                                .fetchOne(db)
                        }

                        if let existing {
                            // Re-attach saved articles from "Saved Pages"
                            if existing.sourceID == Source.savedPagesID, existing.isSaved {
                                try await DatabaseManager.shared.dbPool.write { db in
                                    var reattached = existing
                                    reattached.sourceID = source.id
                                    try reattached.update(db)
                                }
                            }
                            continue
                        }

                        // Also check by title within the same source to catch
                        // Google News URL rotation between fetches
                        let titleExists = try await DatabaseManager.shared.dbPool.read { db in
                            try Article
                                .filter(Column("sourceID") == source.id)
                                .filter(Column("title") == item.title)
                                .fetchCount(db) > 0
                        }
                        if titleExists { continue }

                        newItems.append(PendingItem(feedItem: item, source: source))
                    }

                    if !newItems.isEmpty {
                        queues.append(newItems)
                    }
                } catch {
                    logger.warning("Feed parse failed for \(source.title): \(error.localizedDescription)")
                }
            }

            // Phase 2: Insert discovered articles as .pending (no caching).
            // Round-robin so every source gets fair treatment in case the
            // task is cancelled partway through.
            var insertedCount = 0
            var indices = Array(repeating: 0, count: queues.count)
            var remaining = true

            while remaining {
                guard !Task.isCancelled else { return }
                remaining = false

                for queueIndex in queues.indices {
                    guard !Task.isCancelled else { return }
                    let itemIndex = indices[queueIndex]
                    guard itemIndex < queues[queueIndex].count else { continue }
                    remaining = true

                    let pending = queues[queueIndex][itemIndex]
                    indices[queueIndex] += 1

                    let article = Article(
                        id: UUID(),
                        sourceID: pending.source.id,
                        title: pending.feedItem.title,
                        articleURL: pending.feedItem.url.absoluteString,
                        publishedAt: pending.feedItem.publishedAt,
                        addedAt: Date(),
                        thumbnailURL: pending.feedItem.thumbnailURL?.absoluteString,
                        cachedAt: nil,
                        fetchStatus: .pending,
                        isRead: false,
                        isSaved: false,
                        originalSourceName: pending.feedItem.sourceName,
                        cacheSizeBytes: nil,
                        lastHTTPStatus: nil,
                        etag: nil,
                        lastModified: nil,
                        retryCount: 0
                    )

                    try await DatabaseManager.shared.dbPool.write { db in
                        try article.insert(db)
                    }
                    insertedCount += 1
                }
            }

            logger.info("Inserted \(insertedCount) new articles as pending")

            // Phase 3: Prune excess articles for each source that got new items
            let affectedSourceIDs = Set(queues.flatMap { $0.map(\.source.id) })
            for sourceID in affectedSourceIDs {
                await Self.pruneExcessArticles(for: sourceID)
                await Self.pruneExcessPendingArticles(for: sourceID)
            }
        } catch {
            logger.error("Refresh feeds error: \(error.localizedDescription)")
        }
    }

    // MARK: - Processing handler (heavy caching, power + WiFi)

    private static func handleProcessingTask(_ task: BGProcessingTask) {
        logger.info("Processing task started")
        // Re-submit next request immediately
        scheduleProcessing()

        let workTask = Task {
            await cachePendingArticles()
        }

        task.expirationHandler = {
            logger.warning("Processing task expired by system")
            workTask.cancel()
        }

        Task {
            await workTask.value
            WidgetCenter.shared.reloadAllTimelines()
            WatchConnectivityManager.shared.pushArticlesToWatch()
            logger.info("Processing task completed")
            task.setTaskCompleted(success: true)
        }
    }

    /// Removes the oldest articles for a source that exceed the user's
    /// per-source article limit. Saved articles are moved to the hidden
    /// "Saved Pages" source (detached) rather than deleted.
    ///
    /// Uncached articles (pending/fetching/failed) don't count toward the
    /// cap — they remain as opportunistic and get pruned once cached.
    private static func pruneExcessArticles(for sourceID: UUID) async {
        let limit = UserDefaults.standard.integer(forKey: "articleLimit")
        let articleLimit = limit > 0 ? limit : 25

        do {
            let excessArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == sourceID)
                    .filter([ArticleFetchStatus.cached.rawValue,
                             ArticleFetchStatus.partial.rawValue]
                        .contains(Column("fetchStatus")))
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(Int.max, offset: articleLimit)
                    .fetchAll(db)
            }

            guard !excessArticles.isEmpty else { return }

            let toDelete = excessArticles.filter { !$0.isSaved }
            let toDetach = excessArticles.filter { $0.isSaved }

            if !toDetach.isEmpty {
                let source = try await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchOne(db, key: sourceID)
                }
                let detachIDs = toDetach.map(\.id)
                _ = try await DatabaseManager.shared.dbPool.write { db in
                    for id in detachIDs {
                        try db.execute(
                            sql: """
                                UPDATE article
                                SET sourceID = ?,
                                    originalSourceName = COALESCE(originalSourceName, ?),
                                    originalSourceIconURL = COALESCE(originalSourceIconURL, ?)
                                WHERE id = ?
                                """,
                            arguments: [Source.savedPagesID, source?.title, source?.iconURL, id]
                        )
                    }
                }
            }

            for article in toDelete {
                try? await PageCacheService.shared.deleteCachedArticle(article.id)
            }

            if !toDelete.isEmpty {
                let deleteIDs = toDelete.map(\.id)
                _ = try await DatabaseManager.shared.dbPool.write { db in
                    try Article
                        .filter(deleteIDs.contains(Column("id")))
                        .deleteAll(db)
                }
            }
        } catch {
            // Non-critical
        }
    }

    /// Removes the oldest uncached articles (pending/fetching/failed) for a
    /// source that exceed the user's per-source article limit. This prevents
    /// unbounded growth of pending articles that never get cached (e.g. due
    /// to persistent network issues or sites that require JavaScript).
    private static func pruneExcessPendingArticles(for sourceID: UUID) async {
        let limit = UserDefaults.standard.integer(forKey: "articleLimit")
        let pendingLimit = limit > 0 ? limit : 25

        do {
            let excess = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == sourceID)
                    .filter([ArticleFetchStatus.pending.rawValue,
                             ArticleFetchStatus.fetching.rawValue,
                             ArticleFetchStatus.failed.rawValue]
                        .contains(Column("fetchStatus")))
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(Int.max, offset: pendingLimit)
                    .fetchAll(db)
            }

            guard !excess.isEmpty else { return }

            let deleteIDs = excess.map(\.id)
            _ = try await DatabaseManager.shared.dbPool.write { db in
                try Article
                    .filter(deleteIDs.contains(Column("id")))
                    .deleteAll(db)
            }
        } catch {
            // Non-critical
        }
    }

    /// Caches pending articles one at a time (interruptible), newest first.
    private static func cachePendingArticles() async {
        guard !NetworkMonitor.shouldSkipForWiFiOnly else {
            logger.info("Skipping pending caching — WiFi-only mode and not on WiFi")
            return
        }
        do {
            let pendingArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.pending.rawValue)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .fetchAll(db)
            }

            logger.info("Caching \(pendingArticles.count) pending articles")
            var cachedCount = 0

            for article in pendingArticles {
                // Check for cancellation between articles
                guard !Task.isCancelled else {
                    logger.info("Caching cancelled after \(cachedCount) articles")
                    return
                }

                // Look up the source for its cache level
                let source = try await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchOne(db, key: article.sourceID)
                }

                let cacheLevel = source?.effectiveCacheLevel ?? .standard
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                cachedCount += 1
            }

            logger.info("Finished caching \(cachedCount) articles")
        } catch {
            logger.error("Cache pending articles error: \(error.localizedDescription)")
        }
    }
}
