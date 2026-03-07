import Foundation
import GRDB

enum SourceRefreshState {
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

            // Insert up to 20 new articles per refresh (skip duplicates by articleURL)
            let newArticles = try await insertNewArticles(from: feed.items, sourceID: source.id, limit: 20)

            // Cache only the newly inserted articles
            let cacheLevel = source.effectiveCacheLevel
            for (index, article) in newArticles.enumerated() {
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                HapticManager.articleCached()

                // Brief pause between articles to avoid rate-limiting from aggressive CDNs
                if index < newArticles.count - 1 {
                    try? await Task.sleep(for: .milliseconds(200))
                }
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
