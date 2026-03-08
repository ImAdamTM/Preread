import Foundation
import GRDB

enum SourceRefreshState: Equatable {
    case idle
    case refreshing
    case completed
    case failed
}

@MainActor
final class FetchCoordinator: ObservableObject {
    static let shared = FetchCoordinator()

    @Published var isFetching = false
    @Published var sourceStatuses: [UUID: SourceRefreshState] = [:]

    private let maxConcurrentSources = 3

    private init() {}

    // MARK: - Refresh all sources

    /// Refreshes all sources concurrently (max 3 at a time).
    /// Guards against duplicate calls — if already fetching, returns immediately.
    func refreshAllSources() async {
        guard !isFetching else { return }
        isFetching = true

        let sources: [Source]
        do {
            sources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("id") != Source.savedPagesID)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
            }
        } catch {
            isFetching = false
            return
        }

        // Reset statuses
        for source in sources {
            sourceStatuses[source.id] = .idle
        }

        await withTaskGroup(of: Void.self) { group in
            var iterator = sources.makeIterator()
            var active = 0

            // Seed initial batch
            while active < maxConcurrentSources, let source = iterator.next() {
                active += 1
                let sourceID = source.id
                group.addTask { [weak self] in
                    await self?.performRefresh(source)
                    // Only mark completed if performRefresh didn't already set .failed
                    await MainActor.run {
                        if self?.sourceStatuses[sourceID] != .failed {
                            self?.sourceStatuses[sourceID] = .completed
                        }
                    }
                }
                sourceStatuses[source.id] = .refreshing
            }

            // As each completes, launch next
            for await _ in group {
                active -= 1
                if let source = iterator.next() {
                    active += 1
                    let sourceID = source.id
                    group.addTask { [weak self] in
                        await self?.performRefresh(source)
                        await MainActor.run {
                            if self?.sourceStatuses[sourceID] != .failed {
                                self?.sourceStatuses[sourceID] = .completed
                            }
                        }
                    }
                    sourceStatuses[source.id] = .refreshing
                }
            }
        }

        isFetching = false
        HapticManager.allRefreshComplete()
    }

    // MARK: - Refresh .onOpen sources (called at app launch)

    /// Refreshes only sources whose fetchFrequency is .onOpen.
    func refreshOnOpenSources() async {
        do {
            let onOpenSources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("fetchFrequency") == FetchFrequency.onOpen.rawValue)
                    .fetchAll(db)
            }
            for source in onOpenSources {
                sourceStatuses[source.id] = .refreshing
                await performRefresh(source)
                sourceStatuses[source.id] = .completed
            }
        } catch {
            // Non-critical
        }
    }

    // MARK: - Refresh stale .automatic sources (called at app launch)

    /// Refreshes .automatic sources that haven't been checked recently.
    /// Uses a 1-hour staleness threshold — if background tasks ran on time,
    /// this is a no-op. Acts as a safety net when background execution is delayed.
    func refreshStaleAutoSources() async {
        let staleThreshold: TimeInterval = 60 * 60 // 1 hour
        do {
            let staleSources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("fetchFrequency") == FetchFrequency.automatic.rawValue)
                    .fetchAll(db)
            }.filter { source in
                guard let lastFetched = source.lastFetchedAt else { return true }
                return Date().timeIntervalSince(lastFetched) > staleThreshold
            }
            for source in staleSources {
                sourceStatuses[source.id] = .refreshing
                await performRefresh(source)
                sourceStatuses[source.id] = .completed
            }
        } catch {
            // Non-critical
        }
    }

    // MARK: - Refresh single source (user-initiated, no guard)

    /// Refreshes a single source. Always runs even if a bulk refresh is in progress.
    func refreshSingleSource(_ source: Source) async {
        sourceStatuses[source.id] = .refreshing
        await performRefresh(source)
        sourceStatuses[source.id] = .completed
    }

    // MARK: - Core refresh logic

    private func performRefresh(_ source: Source) async {
        var source = source

        // Mark source as fetching
        source.fetchStatus = .fetching
        try? await saveSource(&source)

        do {
            // Parse feed for new items
            guard let feedURL = URL(string: source.feedURL) else {
                source.fetchStatus = .error
                try? await saveSource(&source)
                return
            }

            let feed = try await FeedService.shared.parseFeed(from: feedURL, siteURL: source.siteURL.flatMap { URL(string: $0) })

            // The article limit determines the "refresh window" — how many of
            // the feed's newest items we consider on each refresh.
            // Full-page caching is much heavier, so the window is smaller.
            let currentCacheLevel = source.effectiveCacheLevel
            let articleLimit = currentCacheLevel == .full ? 10 : 20

            // Sort feed items newest-first so the window is always chronological,
            // regardless of the order the RSS feed provides them in.
            // Items without a date are treated as very old so dated items take priority.
            // Deduplicate by URL before taking the window so duplicates in the feed
            // don't reduce the number of articles we process.
            var seenURLs = Set<String>()
            let uniqueSortedItems = feed.items
                .sorted { a, b in
                    (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
                }
                .filter { seenURLs.insert($0.url.absoluteString).inserted }
            let feedWindow = Array(uniqueSortedItems.prefix(articleLimit))

            // Build a lookup of existing articles by URL for the feed window
            let feedURLs = feedWindow.map(\.url.absoluteString)
            let existingArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .filter(feedURLs.contains(Column("articleURL")))
                    .fetchAll(db)
            }
            let existingByURL = Dictionary(existingArticles.map { ($0.articleURL, $0) }, uniquingKeysWith: { first, _ in first })

            // Also find any saved articles that were detached to "Saved Pages"
            // (e.g. after the source was deleted then re-added)
            let detachedArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == Source.savedPagesID)
                    .filter(Column("isSaved") == true)
                    .filter(feedURLs.contains(Column("articleURL")))
                    .fetchAll(db)
            }
            let detachedByURL = Dictionary(detachedArticles.map { ($0.articleURL, $0) }, uniquingKeysWith: { first, _ in first })

            var needsCaching: [Article] = []

            for item in feedWindow {
                let urlString = item.url.absoluteString

                if var existing = existingByURL[urlString] {
                    // Article already in DB under this source — check if it needs re-caching
                    switch existing.fetchStatus {
                    case .pending, .failed:
                        // Already needs caching
                        needsCaching.append(existing)

                    case .fetching:
                        // Currently being cached by another task — skip
                        break

                    case .cached, .partial:
                        // Check for missing files on disk
                        let hasContent = await PageCacheService.shared.hasCachedContent(for: existing)
                        if !hasContent {
                            existing.etag = nil
                            existing.lastModified = nil
                            existing.fetchStatus = .pending
                            try await DatabaseManager.shared.dbPool.write { db in
                                try existing.update(db)
                            }
                            needsCaching.append(existing)
                        } else {
                            // Check for cache level mismatch
                            let cachedPage = try await DatabaseManager.shared.dbPool.read { db in
                                try CachedPage.fetchOne(db, key: existing.id)
                            }
                            if let cachedPage, cachedPage.cacheLevelUsed != currentCacheLevel {
                                existing.etag = nil
                                existing.lastModified = nil
                                existing.fetchStatus = .pending
                                try await DatabaseManager.shared.dbPool.write { db in
                                    try existing.update(db)
                                }
                                needsCaching.append(existing)
                            }
                        }
                    }
                } else if let detached = detachedByURL[urlString] {
                    // Saved article was detached to "Saved Pages" — re-attach to this source
                    let articleID = detached.id
                    let newSourceID = source.id
                    try await DatabaseManager.shared.dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE article SET sourceID = ? WHERE id = ?",
                            arguments: [newSourceID, articleID]
                        )
                    }
                } else {
                    // New article — insert it
                    let article = Article(
                        id: UUID(),
                        sourceID: source.id,
                        title: item.title,
                        articleURL: urlString,
                        publishedAt: item.publishedAt,
                        addedAt: Date(),
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
                    do {
                        try await DatabaseManager.shared.dbPool.write { db in
                            try article.insert(db)
                        }
                        needsCaching.append(article)
                    } catch {
                        // Duplicate URL or other insert failure — skip this item
                    }
                }
            }

            let uncachedArticles = needsCaching

            let cacheLevel = source.effectiveCacheLevel
            for (index, article) in uncachedArticles.enumerated() {
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                HapticManager.articleCached()

                // Brief pause between articles to avoid rate-limiting from aggressive CDNs
                if index < uncachedArticles.count - 1 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }

            // Clean up shared assets that are no longer referenced by any article
            // (e.g. after downgrading from full to standard cache level)
            if !uncachedArticles.isEmpty {
                await PageCacheService.shared.cleanupOrphanedSharedAssets()
            }

            // Prune articles that exceed the user's per-source cap
            await pruneExcessArticles(for: source.id)

            // Update source
            source.lastFetchedAt = Date()
            source.fetchStatus = .idle
            try? await saveSource(&source)

        } catch {
            source.fetchStatus = .error
            try? await saveSource(&source)
            sourceStatuses[source.id] = .failed
        }
    }

    // MARK: - Retry pending/failed articles

    /// Retries all pending or failed articles for a source.
    /// Called when the user opens a feed so stale failures get resolved
    /// without waiting for the next scheduled refresh.
    /// Shows the refresh spinner in the hero while working.
    func retryFailedArticles(for source: Source) async {
        let cacheLevel = source.effectiveCacheLevel
        let retryLimit = cacheLevel == .full ? 10 : 20
        let articlesToRetry: [Article]
        do {
            articlesToRetry = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .filter([ArticleFetchStatus.pending.rawValue,
                             ArticleFetchStatus.failed.rawValue]
                        .contains(Column("fetchStatus")))
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(retryLimit)
                    .fetchAll(db)
            }
        } catch {
            return
        }

        guard !articlesToRetry.isEmpty else { return }

        sourceStatuses[source.id] = .refreshing

        for (index, var article) in articlesToRetry.enumerated() {
            // Clear stale conditional headers so we always get a fresh
            // response (the cached files may be gone after a rebuild).
            if article.etag != nil || article.lastModified != nil {
                article.etag = nil
                article.lastModified = nil
                try? await DatabaseManager.shared.dbPool.write { db in
                    try article.update(db)
                }
            }

            try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel, forceReprocess: true)

            if index < articlesToRetry.count - 1 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        sourceStatuses[source.id] = .completed
    }

    // MARK: - Helpers

    /// Inserts new articles from feed items, skipping any whose URL already exists.
    /// - Parameter limit: Maximum number of new articles to insert (0 = unlimited).
    func insertNewArticles(from items: [FeedItem], sourceID: UUID, limit: Int = 0) async throws -> [Article] {
        try await DatabaseManager.shared.dbPool.write { db in
            var inserted: [Article] = []
            for item in items {
                if limit > 0, inserted.count >= limit { break }

                // Check if the article already exists anywhere
                if let existing = try Article
                    .filter(Column("articleURL") == item.url.absoluteString)
                    .fetchOne(db) {
                    // If it's a saved article detached to "Saved Pages", re-attach it
                    if existing.sourceID == Source.savedPagesID, existing.isSaved {
                        var reattached = existing
                        reattached.sourceID = sourceID
                        try reattached.update(db)
                        inserted.append(reattached)
                    }
                    // Otherwise it already belongs to a source — skip
                    continue
                }

                let article = Article(
                    id: UUID(),
                    sourceID: sourceID,
                    title: item.title,
                    articleURL: item.url.absoluteString,
                    publishedAt: item.publishedAt,
                    addedAt: Date(),
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
                inserted.append(article)
            }
            return inserted
        }
    }

    // MARK: - Pruning

    /// Removes the oldest articles for a source that exceed the user's
    /// per-source article limit. Saved articles are moved to the hidden
    /// "Saved Pages" source (detached) rather than deleted.
    private func pruneExcessArticles(for sourceID: UUID) async {
        let limit = UserDefaults.standard.integer(forKey: "articleLimit")
        let articleLimit = limit > 0 ? limit : 100 // default 100

        do {
            // Fetch ALL articles beyond the cap (saved and unsaved)
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

            // Move saved articles to the hidden "Saved Pages" source,
            // stamping original source info for attribution.
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

            // Delete cached files for unsaved articles
            for article in toDelete {
                try? await PageCacheService.shared.deleteCachedArticle(article.id)
            }

            // Delete the unsaved article records
            if !toDelete.isEmpty {
                let deleteIDs = toDelete.map(\.id)
                _ = try await DatabaseManager.shared.dbPool.write { db in
                    try Article
                        .filter(deleteIDs.contains(Column("id")))
                        .deleteAll(db)
                }
            }
        } catch {
            // Non-critical — pruning can retry next refresh
        }
    }

    private func saveSource(_ source: inout Source) async throws {
        try await DatabaseManager.shared.dbPool.write { db in
            try source.update(db)
        }
    }
}
