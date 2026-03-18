import Foundation
import GRDB
import WidgetKit
import WatchConnectivity

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
    @Published var startupComplete = false
    @Published var savedArticlesVersion = 0

    /// The source currently being viewed by the user. When set, foreground
    /// stale-source refreshes prioritise this source and defer the rest.
    var activeSourceID: UUID?

    /// Sources whose refresh was deferred because the user was viewing a
    /// specific feed when the app returned to foreground.
    private var deferredStaleSources: [Source] = []

    private let maxConcurrentSources = 3

    private init() {}

    // MARK: - Refresh all sources

    /// Refreshes all sources using a three-phase pipeline:
    /// 1. Parse feeds + insert articles (concurrent, max 3 at a time)
    /// 2. Priority-cache the 5 newest uncached articles per source (round-robin)
    /// 3. Backfill-cache remaining uncached articles (round-robin)
    ///
    /// This ensures the home screen (which shows 5 articles per source) updates
    /// quickly, while the full article cap is cached in the background.
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

        await refreshSourcesWithPriority(sources, skipBackfill: true)

        isFetching = false
        notifyExtensions()
        HapticManager.allRefreshComplete()
    }

    // MARK: - Refresh .onOpen sources (called at app launch)

    /// Refreshes only sources whose fetchFrequency is .onOpen.
    func refreshOnOpenSources() async {
        guard !NetworkMonitor.shouldSkipForWiFiOnly else { return }
        do {
            let onOpenSources = try await DatabaseManager.shared.dbPool.read { db in
                try Source
                    .filter(Column("fetchFrequency") == FetchFrequency.onOpen.rawValue)
                    .fetchAll(db)
            }
            guard !onOpenSources.isEmpty else { return }
            await refreshSourcesWithPriority(onOpenSources, skipBackfill: true)
        } catch {
            // Non-critical
        }
    }

    // MARK: - Refresh stale .automatic sources (called on foreground resume)

    /// Refreshes .automatic sources that haven't been checked recently.
    /// Uses a 1-hour staleness threshold — if background tasks ran on time,
    /// this is a no-op. Acts as a safety net when background execution is delayed.
    ///
    /// When the user is viewing a specific source (`activeSourceID` is set),
    /// only that source is refreshed immediately. The remaining stale sources
    /// are deferred until `refreshDeferredStaleSources()` is called (typically
    /// when navigating back to the home screen).
    func refreshStaleAutoSources() async {
        guard !NetworkMonitor.shouldSkipForWiFiOnly else { return }
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
            guard !staleSources.isEmpty else { return }

            if let activeID = activeSourceID {
                // User is viewing a specific feed — refresh only that source now
                let (active, deferred) = staleSources.reduce(into: ([Source](), [Source]())) { result, source in
                    if source.id == activeID {
                        result.0.append(source)
                    } else {
                        result.1.append(source)
                    }
                }
                deferredStaleSources = deferred
                if !active.isEmpty {
                    // User is viewing this source — do a full refresh including backfill
                    await refreshSourcesWithPriority(active, skipBackfill: false)
                }
            } else {
                // On home screen — refresh everything
                deferredStaleSources = []
                await refreshSourcesWithPriority(staleSources, skipBackfill: true)
            }
        } catch {
            // Non-critical
        }
    }

    /// Refreshes sources that were deferred because the user was viewing a
    /// specific feed when the app last returned to foreground. No-op if empty.
    func refreshDeferredStaleSources() async {
        let deferred = deferredStaleSources
        deferredStaleSources = []
        guard !deferred.isEmpty else { return }
        await refreshSourcesWithPriority(deferred, skipBackfill: true)
    }

    // MARK: - Refresh single source (user-initiated, no guard)

    /// Refreshes a single source. Always runs even if a bulk refresh is in progress.
    /// Uses priority caching (top 5 first, then backfill).
    func refreshSingleSource(_ source: Source) async {
        sourceStatuses[source.id] = .refreshing

        let result = await parseFeedAndPrepareArticles(source)
        guard let result else {
            sourceStatuses[source.id] = .failed
            return
        }

        let cacheLevel = source.effectiveCacheLevel
        let priority = Array(result.needsCaching.prefix(visibleArticleCount))
        let backfill = Array(result.needsCaching.dropFirst(visibleArticleCount))

        // Cache priority articles first
        for (index, article) in priority.enumerated() {
            let result = try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
            if result == .contentUpdated {
                HapticManager.articleCached()
            }
            if index < priority.count - 1 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        // Then backfill
        for (index, article) in backfill.enumerated() {
            let result = try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
            if result == .contentUpdated {
                HapticManager.articleCached()
            }
            if index < backfill.count - 1 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        // Post-cache cleanup
        if !result.needsCaching.isEmpty {
            await PageCacheService.shared.cleanupOrphanedSharedAssets()
        }
        await pruneExcessArticles(for: source.id)
        await pruneExcessPendingArticles(for: source.id)

        sourceStatuses[source.id] = .completed
    }

    // MARK: - Three-phase refresh pipeline

    /// The number of articles visible on the home screen per source.
    /// These are prioritised during multi-source refreshes.
    private let visibleArticleCount = 5

    /// Maximum number of automatic cache retries before an article is
    /// left as .failed until the user manually re-fetches it.
    private let maxAutoRetries = 2

    /// Result of parsing a feed and preparing articles for caching.
    private struct FeedParseResult {
        let source: Source
        let needsCaching: [Article]  // sorted newest-first
    }

    /// Three-phase refresh for multiple sources:
    /// 1. Parse all feeds concurrently and insert/update articles in DB
    /// 2. Round-robin cache the top N (visible) articles across all sources
    /// 3. Round-robin cache remaining articles across all sources (skipped when `skipBackfill` is true)
    ///
    /// Foreground refreshes pass `skipBackfill: true` so only the 5 visible
    /// articles per source are cached. Backfill happens when the user navigates
    /// into a specific feed, or via background tasks.
    private func refreshSourcesWithPriority(_ sources: [Source], skipBackfill: Bool = false) async {
        // Reset statuses
        for source in sources {
            sourceStatuses[source.id] = .refreshing
        }

        // ── Phase 1: Parse feeds concurrently ──
        var parseResults: [FeedParseResult] = []

        await withTaskGroup(of: FeedParseResult?.self) { group in
            var iterator = sources.makeIterator()
            var active = 0

            // Seed initial batch
            while active < maxConcurrentSources, let source = iterator.next() {
                active += 1
                group.addTask { [weak self] in
                    await self?.parseFeedAndPrepareArticles(source)
                }
            }

            // As each completes, collect result and launch next
            for await result in group {
                active -= 1
                if let result {
                    parseResults.append(result)
                }
                if let source = iterator.next() {
                    active += 1
                    group.addTask { [weak self] in
                        await self?.parseFeedAndPrepareArticles(source)
                    }
                }
            }
        }

        // Mark sources that failed parsing (no result returned)
        let parsedSourceIDs = Set(parseResults.map(\.source.id))
        for source in sources where !parsedSourceIDs.contains(source.id) {
            sourceStatuses[source.id] = .failed
        }

        // ── Phase 2: Priority-cache top 5 per source (round-robin) ──
        var priorityQueues: [(source: Source, articles: [Article])] = parseResults.map { result in
            (result.source, Array(result.needsCaching.prefix(visibleArticleCount)))
        }

        await roundRobinCache(queues: &priorityQueues)

        // ── Phase 3: Backfill remaining articles (round-robin) ──
        // Skipped for foreground refreshes — backfill happens when the user
        // navigates into a specific feed (or via background tasks).
        if !skipBackfill {
            var backfillQueues: [(source: Source, articles: [Article])] = parseResults.map { result in
                (result.source, Array(result.needsCaching.dropFirst(visibleArticleCount)))
            }

            await roundRobinCache(queues: &backfillQueues)
        }

        // ── Post-cache cleanup ──
        let hasAnyCaching = parseResults.contains { !$0.needsCaching.isEmpty }
        if hasAnyCaching {
            await PageCacheService.shared.cleanupOrphanedSharedAssets()
        }

        for result in parseResults {
            await pruneExcessArticles(for: result.source.id)
            await pruneExcessPendingArticles(for: result.source.id)
            if sourceStatuses[result.source.id] != .failed {
                sourceStatuses[result.source.id] = .completed
            }
        }
    }

    /// Caches articles round-robin across sources: one article from each source
    /// in turn, repeating until all queues are exhausted.
    /// Haptics only fire when content actually changed (not 304) and only for
    /// articles in the currently-viewed source (or all when on the home screen).
    private func roundRobinCache(queues: inout [(source: Source, articles: [Article])]) async {
        var indices = Array(repeating: 0, count: queues.count)
        var remaining = true

        while remaining {
            remaining = false
            for queueIndex in queues.indices {
                let itemIndex = indices[queueIndex]
                guard itemIndex < queues[queueIndex].articles.count else { continue }
                remaining = true

                let article = queues[queueIndex].articles[itemIndex]
                let source = queues[queueIndex].source
                let cacheLevel = source.effectiveCacheLevel
                indices[queueIndex] += 1

                let result = try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)

                // Only fire haptic if content actually changed and user can see it
                if result == .contentUpdated,
                   activeSourceID == nil || activeSourceID == source.id {
                    HapticManager.articleCached()
                }

                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    // MARK: - Feed parsing (phase 1 of refresh)

    /// Parses a source's feed, inserts new articles, identifies articles needing
    /// caching, and updates the source's lastFetchedAt. Returns nil on failure.
    private func parseFeedAndPrepareArticles(_ source: Source) async -> FeedParseResult? {
        var source = source

        source.fetchStatus = .fetching
        try? await saveSource(&source)

        do {
            guard let feedURL = URL(string: source.feedURL) else {
                source.fetchStatus = .error
                try? await saveSource(&source)
                return nil
            }

            let feed = try await FeedService.shared.parseFeed(from: feedURL, siteURL: source.siteURL.flatMap { URL(string: $0) })

            let currentCacheLevel = source.effectiveCacheLevel
            let articleLimit = currentCacheLevel == .full ? 10 : 20

            var seenURLs = Set<String>()
            var seenTitles = Set<String>()
            let uniqueSortedItems = feed.items
                .sorted { a, b in
                    (a.publishedAt ?? .distantPast) > (b.publishedAt ?? .distantPast)
                }
                .filter { item in
                    // Deduplicate by URL and by title (Google News feeds can
                    // contain the same article with different redirect URLs)
                    let urlNew = seenURLs.insert(item.url.absoluteString).inserted
                    let titleNew = seenTitles.insert(item.title).inserted
                    return urlNew && titleNew
                }
            let feedWindow = Array(uniqueSortedItems.prefix(articleLimit))

            let feedURLs = feedWindow.map(\.url.absoluteString)
            let feedTitles = feedWindow.map(\.title)
            let sourceID = source.id
            let existingArticles = try await DatabaseManager.shared.dbPool.read { db in
                // Match by URL or title so Google News redirect URL changes
                // don't cause duplicate articles
                try Article
                    .filter(Column("sourceID") == sourceID)
                    .filter(
                        feedURLs.contains(Column("articleURL")) ||
                        feedTitles.contains(Column("title"))
                    )
                    .fetchAll(db)
            }
            let existingByURL = Dictionary(existingArticles.map { ($0.articleURL, $0) }, uniquingKeysWith: { first, _ in first })
            let existingByTitle = Dictionary(existingArticles.map { ($0.title, $0) }, uniquingKeysWith: { first, _ in first })

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

                // Skip URLs that are clearly not articles (login pages,
                // auth endpoints, account portals, etc.)
                if Self.isNonArticleURL(item.url) {
                    // If this non-article URL was already inserted in a
                    // previous refresh, remove it now so it stops showing
                    // in the feed (e.g. accounts.nintendo.com auth pages).
                    if let existing = existingByURL[urlString] ?? existingByTitle[item.title] {
                        try? await PageCacheService.shared.deleteCachedArticle(existing.id)
                        _ = try? await DatabaseManager.shared.dbPool.write { db in
                            try existing.delete(db)
                        }
                    }
                    continue
                }

                if let existing = existingByURL[urlString] ?? existingByTitle[item.title] {
                    switch existing.fetchStatus {
                    case .pending, .failed:
                        // Skip articles that have already failed too many times
                        if existing.retryCount < self.maxAutoRetries {
                            needsCaching.append(existing)
                        }

                    case .fetching:
                        // Article was left at .fetching by an interrupted cache
                        // attempt (app killed, timeout, etc.). Reset it so this
                        // refresh can retry it.
                        if existing.retryCount < self.maxAutoRetries {
                            var updated = existing
                            updated.fetchStatus = .pending
                            let snapshot = updated
                            try? await DatabaseManager.shared.dbPool.write { db in
                                try snapshot.update(db)
                            }
                            needsCaching.append(snapshot)
                        }

                    case .cached, .partial:
                        let hasContent = await PageCacheService.shared.hasCachedContent(for: existing)
                        if !hasContent {
                            try? await PageCacheService.shared.deleteCachedArticle(existing.id)
                            var updated = existing
                            updated.etag = nil
                            updated.lastModified = nil
                            updated.fetchStatus = .pending
                            let snapshot = updated
                            try await DatabaseManager.shared.dbPool.write { db in
                                try snapshot.update(db)
                            }
                            needsCaching.append(snapshot)
                        } else {
                            let cachedPage = try await DatabaseManager.shared.dbPool.read { db in
                                try CachedPage.fetchOne(db, key: existing.id)
                            }
                            if let cachedPage, cachedPage.cacheLevelUsed != currentCacheLevel {
                                var updated = existing
                                updated.etag = nil
                                updated.lastModified = nil
                                updated.fetchStatus = .pending
                                let snapshot = updated
                                try await DatabaseManager.shared.dbPool.write { db in
                                    try snapshot.update(db)
                                }
                                needsCaching.append(snapshot)
                            }
                        }
                    }
                } else if let detached = detachedByURL[urlString] {
                    let articleID = detached.id
                    let newSourceID = source.id
                    try await DatabaseManager.shared.dbPool.write { db in
                        try db.execute(
                            sql: "UPDATE article SET sourceID = ? WHERE id = ?",
                            arguments: [newSourceID, articleID]
                        )
                    }
                } else {
                    // Resolve Google News redirect URLs to real article URLs
                    // before inserting, so we never store news.google.com URLs.
                    let resolvedURLString: String
                    if let itemURL = URL(string: urlString),
                       PageCacheService.isGoogleNewsURL(itemURL) {
                        let resolved = await PageCacheService.shared.resolveGoogleNewsURL(itemURL)
                        if resolved != itemURL {
                            let resolvedURL = resolved.absoluteString
                            let alreadyExists = try? await DatabaseManager.shared.dbPool.read { db in
                                try Article
                                    .filter(Column("articleURL") == resolvedURL)
                                    .fetchCount(db) > 0
                            }
                            if alreadyExists == true { continue }
                            resolvedURLString = resolvedURL
                        } else {
                            // Resolution failed — skip this article entirely
                            // rather than inserting a broken Google News URL
                            continue
                        }
                    } else {
                        resolvedURLString = urlString
                    }

                    let sourceIDForInsert = source.id
                    let article = Article(
                        id: UUID(),
                        sourceID: sourceIDForInsert,
                        title: item.title,
                        articleURL: resolvedURLString,
                        publishedAt: item.publishedAt,
                        addedAt: Date(),
                        thumbnailURL: item.thumbnailURL?.absoluteString,
                        cachedAt: nil,
                        fetchStatus: .pending,
                        isRead: false,
                        isSaved: false,
                        originalSourceName: item.sourceName,
                        cacheSizeBytes: nil,
                        lastHTTPStatus: nil,
                        etag: nil,
                        lastModified: nil,
                        retryCount: 0
                    )
                    do {
                        try await DatabaseManager.shared.dbPool.write { db in
                            try article.insert(db)
                        }
                        needsCaching.append(article)
                    } catch {
                        // Duplicate URL or other insert failure — skip
                    }
                }
            }

            // Update source timestamp
            source.lastFetchedAt = Date()
            source.fetchStatus = .idle
            try? await saveSource(&source)

            return FeedParseResult(source: source, needsCaching: needsCaching)

        } catch {
            source.fetchStatus = .error
            try? await saveSource(&source)
            sourceStatuses[source.id] = .failed
            return nil
        }
    }

    // MARK: - Backfill articles for a viewed source

    /// Caches uncached articles beyond the top 5 for a source.
    /// Called when the user navigates into a specific feed, since foreground
    /// refreshes only cache the 5 visible articles per source.
    func backfillArticles(for source: Source) async {
        let cacheLevel = source.effectiveCacheLevel
        let articleLimit = cacheLevel == .full ? 10 : 20
        let uncachedArticles: [Article]
        do {
            uncachedArticles = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .filter([ArticleFetchStatus.pending.rawValue,
                             ArticleFetchStatus.fetching.rawValue]
                        .contains(Column("fetchStatus")))
                    .filter(Column("retryCount") < self.maxAutoRetries)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(articleLimit)
                    .fetchAll(db)
            }
        } catch {
            return
        }

        guard !uncachedArticles.isEmpty else { return }

        for (index, article) in uncachedArticles.enumerated() {
            if let url = URL(string: article.articleURL), Self.isNonArticleURL(url) {
                continue
            }

            let result = try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
            if result == .contentUpdated {
                HapticManager.articleCached()
            }

            if index < uncachedArticles.count - 1 {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        await pruneExcessArticles(for: source.id)
        await pruneExcessPendingArticles(for: source.id)
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
                             ArticleFetchStatus.failed.rawValue,
                             ArticleFetchStatus.fetching.rawValue]
                        .contains(Column("fetchStatus")))
                    .filter(Column("retryCount") < self.maxAutoRetries)
                    .order(SQL("COALESCE(publishedAt, addedAt)").sqlExpression.desc)
                    .limit(retryLimit)
                    .fetchAll(db)
            }
        } catch {
            return
        }

        guard !articlesToRetry.isEmpty else { return }

        sourceStatuses[source.id] = .refreshing

        for (index, article) in articlesToRetry.enumerated() {
            // Skip non-article URLs (auth pages etc.) that slipped in
            // before filtering was added to the main refresh path.
            if let url = URL(string: article.articleURL), Self.isNonArticleURL(url) {
                try? await PageCacheService.shared.deleteCachedArticle(article.id)
                _ = try? await DatabaseManager.shared.dbPool.write { db in
                    try article.delete(db)
                }
                continue
            }

            // Clear stale conditional headers so we always get a fresh
            // response (the cached files may be gone after a rebuild).
            var articleToCache = article
            if articleToCache.etag != nil || articleToCache.lastModified != nil {
                articleToCache.etag = nil
                articleToCache.lastModified = nil
                let snapshot = articleToCache
                try? await DatabaseManager.shared.dbPool.write { db in
                    try snapshot.update(db)
                }
            }

            try? await PageCacheService.shared.cacheArticle(articleToCache, cacheLevel: cacheLevel, forceReprocess: true)

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
            var seenTitles = Set<String>()
            for item in items {
                if limit > 0, inserted.count >= limit { break }

                // Skip URLs that are clearly not articles (login pages,
                // auth endpoints, account portals, etc.)
                guard !Self.isNonArticleURL(item.url) else { continue }

                // Skip duplicate titles (Google News feeds can contain
                // the same article with different redirect URLs)
                guard seenTitles.insert(item.title).inserted else { continue }

                // Check if the article already exists anywhere (by URL or
                // by title within the same source — Google News feeds can
                // return the same article with different redirect URLs)
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

                // Also check by title within the same source to catch
                // Google News URL rotation
                if try Article
                    .filter(Column("sourceID") == sourceID)
                    .filter(Column("title") == item.title)
                    .fetchCount(db) > 0 {
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
                    originalSourceName: item.sourceName,
                    cacheSizeBytes: nil,
                    lastHTTPStatus: nil,
                    etag: nil,
                    lastModified: nil,
                    retryCount: 0
                )
                try article.insert(db)
                inserted.append(article)
            }
            return inserted
        }
    }

    // MARK: - Pruning

    /// Removes the oldest **cached** articles for a source that exceed the
    /// user's per-source article limit. Saved articles are moved to the
    /// hidden "Saved Pages" source (detached) rather than deleted.
    ///
    /// Uncached articles (pending/fetching/failed) don't count toward the
    /// cap. They remain in the DB as opportunistic — they'll cache when
    /// connectivity allows and get pruned on a future pass once cached.
    /// This prevents a feed refresh from deleting readable articles to
    /// make room for articles that haven't finished downloading yet.
    private func pruneExcessArticles(for sourceID: UUID) async {
        let limit = UserDefaults.standard.integer(forKey: "articleLimit")
        let articleLimit = limit > 0 ? limit : 25 // default 25

        do {
            // Only count cached/partial articles against the cap.
            // Pending/fetching/failed articles are invisible to pruning.
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

    /// Removes the oldest uncached articles (pending/fetching/failed) for a
    /// source that exceed the user's per-source article limit. This prevents
    /// unbounded growth of pending articles that never get cached.
    private func pruneExcessPendingArticles(for sourceID: UUID) async {
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
            // Non-critical — pruning can retry next refresh
        }
    }

    private func saveSource(_ source: inout Source) async throws {
        let snapshot = source
        try await DatabaseManager.shared.dbPool.write { db in
            try snapshot.update(db)
        }
    }

    // MARK: - URL filtering

    /// Returns true if the URL is clearly not an article and should be
    /// excluded from the feed. Matches generic patterns like login pages,
    /// auth endpoints, and account portals — not site-specific selectors.
    nonisolated static func isNonArticleURL(_ url: URL) -> Bool {
        let path = url.path.lowercased()
        let host = url.host?.lowercased() ?? ""

        // Hosts that are entirely auth/account subdomains
        let authHostPrefixes = ["accounts.", "account.", "auth.", "login.", "signin.", "sso."]
        if authHostPrefixes.contains(where: { host.hasPrefix($0) }) {
            return true
        }

        // Path segments that indicate non-article pages
        let authPathSegments = [
            "/login", "/signin", "/sign-in", "/signup", "/sign-up",
            "/register", "/auth", "/oauth", "/sso",
            "/password", "/forgot-password", "/reset-password",
            "/logout", "/signout", "/sign-out",
            "/subscribe", "/subscription", "/checkout", "/payment",
            "/unsubscribe", "/preferences/notifications",
        ]
        for segment in authPathSegments {
            if path == segment || path.hasPrefix(segment + "/") || path.hasPrefix(segment + "?") {
                return true
            }
        }

        // Query parameters that indicate redirected auth flows
        let authQueryParams = ["post_login_redirect", "redirect_uri", "return_to", "login_challenge"]
        if let query = url.query?.lowercased() {
            for param in authQueryParams {
                if query.contains(param + "=") {
                    return true
                }
            }
        }

        return false
    }

    /// Reloads widget timelines and pushes latest data to Apple Watch.
    private func notifyExtensions() {
        WidgetCenter.shared.reloadAllTimelines()
        WatchConnectivityManager.shared.pushArticlesToWatch()
    }
}
