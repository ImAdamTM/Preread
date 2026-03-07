import UIKit
import BackgroundTasks
import GRDB

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

    // MARK: - Refresh handler (~30s budget: feed parsing only, no caching)

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
            task.setTaskCompleted(success: true)
        }
    }

    /// Parses all source feeds, inserts new articles as .pending, then caches
    /// a few articles opportunistically if time remains within the ~30s budget.
    private static func refreshFeeds() async {
        do {
            let sources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("fetchFrequency") == FetchFrequency.automatic.rawValue)
                    .fetchAll(db)
            }

            for var source in sources {
                guard !Task.isCancelled else { return }
                guard let feedURL = URL(string: source.feedURL) else { continue }

                do {
                    let feed = try await FeedService.shared.parseFeed(
                        from: feedURL,
                        siteURL: source.siteURL.flatMap { URL(string: $0) }
                    )

                    // Insert new articles
                    try await DatabaseManager.shared.dbPool.write { db in
                        for item in feed.items {
                            let exists = try Article
                                .filter(Column("articleURL") == item.url.absoluteString)
                                .fetchCount(db) > 0
                            guard !exists else { continue }

                            var article = Article(
                                id: UUID(),
                                sourceID: source.id,
                                title: item.title,
                                articleURL: item.url.absoluteString,
                                publishedAt: item.publishedAt,
                                thumbnailURL: item.thumbnailURL?.absoluteString,
                                cachedAt: nil,
                                fetchStatus: .pending,
                                isRead: false,
                                isSaved: false,
                                cacheSizeBytes: nil,
                                lastHTTPStatus: nil,
                                etag: nil,
                                lastModified: nil
                            )
                            try article.insert(db)
                        }
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

            // Opportunistically cache a few pending articles with remaining time
            guard !Task.isCancelled else { return }
            let pending = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.pending.rawValue)
                    .limit(5)
                    .fetchAll(db)
            }
            for article in pending {
                guard !Task.isCancelled else { return }
                let source = try await DatabaseManager.shared.dbPool.read { db in
                    try Source.fetchOne(db, key: article.sourceID)
                }
                let cacheLevel = source?.effectiveCacheLevel ?? .standard
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
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
            task.setTaskCompleted(success: true)
        }
    }

    /// Caches pending articles one at a time (interruptible).
    private static func cachePendingArticles() async {
        do {
            let pendingArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("fetchStatus") == ArticleFetchStatus.pending.rawValue)
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
