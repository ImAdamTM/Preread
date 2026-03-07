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

            // Insert new articles (skip duplicates by articleURL)
            let newArticles = try await insertNewArticles(from: feed.items, sourceID: source.id)

            // Fetch all pending/failed/fetching articles for this source
            // (.fetching included to recover articles orphaned by a mid-cache kill)
            let articlesToCachce = try await DatabaseManager.shared.dbPool.read { db in
                try Article
                    .filter(Column("sourceID") == source.id)
                    .filter([
                        ArticleFetchStatus.pending.rawValue,
                        ArticleFetchStatus.failed.rawValue,
                        ArticleFetchStatus.fetching.rawValue
                    ].contains(Column("fetchStatus")))
                    .fetchAll(db)
            }

            // Cache each article, persisting status after each (interruptible)
            let cacheLevel = source.effectiveCacheLevel
            for (index, article) in articlesToCachce.enumerated() {
                try? await PageCacheService.shared.cacheArticle(article, cacheLevel: cacheLevel)
                HapticManager.articleCached()

                // Brief pause between articles to avoid rate-limiting from aggressive CDNs
                if index < articlesToCachce.count - 1 {
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
    private func insertNewArticles(from items: [FeedItem], sourceID: UUID) async throws -> [Article] {
        try await DatabaseManager.shared.dbPool.write { db in
            var inserted: [Article] = []
            for item in items {
                // Skip if articleURL already exists
                let exists = try Article
                    .filter(Column("articleURL") == item.url.absoluteString)
                    .fetchCount(db) > 0
                guard !exists else { continue }

                var article = Article(
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
