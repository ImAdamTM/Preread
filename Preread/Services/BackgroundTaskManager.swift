import UIKit
import BackgroundTasks
import GRDB
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
        } catch {
            print("[BackgroundTaskManager] Failed to schedule refresh: \(error)")
        }
    }

    static func scheduleProcessing() {
        let request = BGProcessingTaskRequest(identifier: processingTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 60) // 1 hour
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundTaskManager] Failed to schedule processing: \(error)")
        }
    }

    // MARK: - Refresh handler (~30s budget: parse feeds + cache new articles)

    private static func handleRefreshTask(_ task: BGAppRefreshTask) {
        // Re-submit next request immediately
        scheduleRefresh()

        let workTask = Task {
            await refreshFeeds()
        }

        task.expirationHandler = {
            workTask.cancel()
        }

        Task {
            await workTask.value
            WidgetCenter.shared.reloadAllTimelines()
            task.setTaskCompleted(success: true)
        }
    }

    /// Pending item waiting to be cached during background refresh.
    private struct PendingItem {
        let feedItem: FeedItem
        let source: Source
    }

    /// Parses all source feeds, then round-robin caches new articles across
    /// sources so no single source monopolises the time budget. An article is
    /// only committed to the database once it has been successfully cached,
    /// so the user never sees uncached placeholder rows in their feed.
    private static func refreshFeeds() async {
        guard !NetworkMonitor.shouldSkipForWiFiOnly else { return }
        do {
            let sources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("id") != Source.savedPagesID)
                    .filter(Column("fetchFrequency") == FetchFrequency.automatic.rawValue)
                    .fetchAll(db)
            }

            // Phase 1: Parse all feeds (fast) and collect new items per source.
            // Re-attach any saved articles that were detached.
            var queues: [[PendingItem]] = []

            for var source in sources {
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

                    source.lastFetchedAt = Date()
                    source.fetchStatus = .idle
                    try await DatabaseManager.shared.dbPool.write { db in
                        try source.update(db)
                    }
                } catch {
                    source.fetchStatus = .error
                    try? await DatabaseManager.shared.dbPool.write { db in
                        try source.update(db)
                    }
                }
            }

            // Phase 2: Round-robin cache one article from each source at a
            // time, so every source gets fair treatment within the budget.
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

                    // Insert temporarily so cacheArticle can find & update it
                    try await DatabaseManager.shared.dbPool.write { db in
                        try article.insert(db)
                    }

                    let cacheLevel = pending.source.effectiveCacheLevel
                    do {
                        try await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                    } catch {
                        // Caching failed — remove so it doesn't appear uncached
                        _ = try? await DatabaseManager.shared.dbPool.write { db in
                            try Article.deleteOne(db, key: article.id)
                        }
                        try? await PageCacheService.shared.deleteCachedArticle(article.id)
                    }
                }
            }

            // Phase 3: Prune excess articles for each source that got new items
            let affectedSourceIDs = Set(queues.flatMap { $0.map(\.source.id) })
            for sourceID in affectedSourceIDs {
                await Self.pruneExcessArticles(for: sourceID)
            }
        } catch {
            print("[BackgroundTaskManager] Refresh feeds error: \(error)")
        }
    }

    // MARK: - Processing handler (heavy caching, power + WiFi)

    private static func handleProcessingTask(_ task: BGProcessingTask) {
        // Re-submit next request immediately
        scheduleProcessing()

        let workTask = Task {
            await cachePendingArticles()
        }

        task.expirationHandler = {
            workTask.cancel()
        }

        Task {
            await workTask.value
            WidgetCenter.shared.reloadAllTimelines()
            task.setTaskCompleted(success: true)
        }
    }

    /// Removes the oldest articles for a source that exceed the user's
    /// per-source article limit. Saved articles are moved to the hidden
    /// "Saved Pages" source (detached) rather than deleted.
    private static func pruneExcessArticles(for sourceID: UUID) async {
        let limit = UserDefaults.standard.integer(forKey: "articleLimit")
        let articleLimit = limit > 0 ? limit : 25

        do {
            let excessArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == sourceID)
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

    /// Caches pending articles one at a time (interruptible), newest first.
    private static func cachePendingArticles() async {
        guard !NetworkMonitor.shouldSkipForWiFiOnly else { return }
        do {
            let pendingArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.pending.rawValue)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .fetchAll(db)
            }

            for article in pendingArticles {
                // Check for cancellation between articles
                guard !Task.isCancelled else { return }

                // Look up the source for its cache level
                let source = try await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchOne(db, key: article.sourceID)
                }

                let cacheLevel = source?.effectiveCacheLevel ?? .standard
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
            }
        } catch {
            print("[BackgroundTaskManager] Cache pending articles error: \(error)")
        }
    }
}
