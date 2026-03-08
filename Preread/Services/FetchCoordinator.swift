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
                try Source.order(Column("sortOrder")).fetchAll(db)
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
                    await MainActor.run {
                        self?.sourceStatuses[sourceID] = .completed
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
                            self?.sourceStatuses[sourceID] = .completed
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

            var needsCaching: [Article] = []

            for item in feedWindow {
                let urlString = item.url.absoluteString

                if var existing = existingByURL[urlString] {
                    // Article already in DB — check if it needs re-caching
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

            // Update source
            source.lastFetchedAt = Date()
            source.fetchStatus = .idle
            try? await saveSource(&source)

        } catch {
            source.fetchStatus = .error
            try? await saveSource(&source)
            await MainActor.run { [source] in
                sourceStatuses[source.id] = .failed
            }
        }
    }

    // MARK: - Helpers

    /// Inserts new articles from feed items, skipping any whose URL already exists.
    /// - Parameter limit: Maximum number of new articles to insert (0 = unlimited).
    func insertNewArticles(from items: [FeedItem], sourceID: UUID, limit: Int = 0) async throws -> [Article] {
        try await DatabaseManager.shared.dbPool.write { db in
            var inserted: [Article] = []
            for item in items {
                if limit > 0, inserted.count >= limit { break }

                // Skip if articleURL already exists
                let exists = try Article
                    .filter(Column("articleURL") == item.url.absoluteString)
                    .fetchCount(db) > 0
                guard !exists else { continue }

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

    private func saveSource(_ source: inout Source) async throws {
        try await DatabaseManager.shared.dbPool.write { db in
            try source.update(db)
        }
    }
}
