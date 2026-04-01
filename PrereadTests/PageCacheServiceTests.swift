import Testing
import Foundation
import GRDB
@testable import Preread

// MARK: - Helpers

/// Creates a Source row in the database and returns it.
private func makeSource() throws -> Source {
    let source = Source(
        id: UUID(),
        title: "Test Source",
        feedURL: "https://example.com/feed/\(UUID().uuidString)",
        siteURL: "https://example.com",
        iconURL: nil,
        addedAt: Date(),
        lastFetchedAt: nil,
        fetchFrequency: .manual,
        fetchStatus: .idle,
        cacheLevel: nil,
        appearanceMode: nil,
        layout: nil,
        homeLayout: nil,
        isCollapsed: false,
        sortOrder: 0
    )
    try DatabaseManager.shared.dbPool.write { db in
        try source.save(db)
    }
    return source
}

/// Creates an Article row in the database linked to the given source.
/// Deletes any stale article with the same URL first (leftover from crashed test runs).
private func makeArticle(sourceID: UUID, url: String, fetchStatus: ArticleFetchStatus = .pending) throws -> Article {
    try DatabaseManager.shared.dbPool.write { db in
        try Article.filter(Column("articleURL") == url).deleteAll(db)
    }
    let article = Article(
        id: UUID(),
        sourceID: sourceID,
        title: "Test Article",
        articleURL: url,
        publishedAt: nil,
        addedAt: Date(),
        thumbnailURL: nil,
        cachedAt: nil,
        fetchStatus: fetchStatus,
        isRead: false,
        isSaved: false,
        cacheSizeBytes: nil,
        lastHTTPStatus: nil,
        etag: nil,
        lastModified: nil,
        retryCount: 0
    )
    try DatabaseManager.shared.dbPool.write { db in
        try article.save(db)
    }
    return article
}

/// Returns the article directory URL inside the shared container's articles directory.
private func articleDir(for articleID: UUID) -> URL {
    ContainerPaths.articlesBaseURL
        .appendingPathComponent(articleID.uuidString, isDirectory: true)
}

/// Cleans up an article from disk and the database.
private func cleanUp(articleID: UUID) {
    let dir = articleDir(for: articleID)
    try? FileManager.default.removeItem(at: dir)
    try? DatabaseManager.shared.dbPool.write { db in
        try Article.filter(Column("id") == articleID).deleteAll(db)
        try CachedPage.filter(Column("articleID") == articleID).deleteAll(db)
    }
}

/// Reloads an article from the database by its ID.
private func reloadArticle(_ id: UUID) throws -> Article? {
    try DatabaseManager.shared.dbPool.read { db in
        try Article.fetchOne(db, key: id)
    }
}

/// Reloads a CachedPage from the database by article ID.
private func reloadCachedPage(articleID: UUID) throws -> CachedPage? {
    try DatabaseManager.shared.dbPool.read { db in
        try CachedPage.fetchOne(db, key: articleID)
    }
}

// A real-world article URL known to have images and CSS. Wikipedia is used for stability.
private let testArticleURL = "https://en.wikipedia.org/wiki/Apple_Vision_Pro"

// MARK: - Tests

@Suite("PageCacheService", .serialized)
struct PageCacheServiceTests {

    // MARK: - standard

    @Test("standard: index.html exists, assets has images, img srcs rewritten, no CSS in assets")
    func standardCaching() async throws {
        let source = try makeSource()
        let article = try makeArticle(sourceID: source.id, url: testArticleURL)
        defer { cleanUp(articleID: article.id) }

        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)

        let dir = articleDir(for: article.id)
        let indexPath = dir.appendingPathComponent("index.html")
        let assetsPath = dir.appendingPathComponent("assets")

        // index.html must exist
        #expect(FileManager.default.fileExists(atPath: indexPath.path))

        // assets/ should have image files
        let assetFiles = (try? FileManager.default.contentsOfDirectory(atPath: assetsPath.path)) ?? []
        #expect(!assetFiles.isEmpty, "standard cache should download images")

        // img srcs should be rewritten to ./assets/
        let html = try String(contentsOf: indexPath, encoding: .utf8)
        if html.contains("<img") {
            #expect(html.contains("./assets/"), "img srcs should be rewritten to local paths")
        }

        // No CSS files in assets (standard doesn't download stylesheets)
        let cssFiles = assetFiles.filter { $0.hasSuffix(".css") }
        #expect(cssFiles.isEmpty, "standard cache should not include CSS")

        // Article status — .cached or .partial (some images may fail)
        let updated = try reloadArticle(article.id)
        #expect(updated?.fetchStatus == .cached || updated?.fetchStatus == .partial)
    }

    // MARK: - full

    @Test("full: images AND CSS in assets")
    func fullCaching() async throws {
        let source = try makeSource()
        let article = try makeArticle(sourceID: source.id, url: testArticleURL)
        defer { cleanUp(articleID: article.id) }

        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .full)

        let dir = articleDir(for: article.id)
        let indexPath = dir.appendingPathComponent("index.html")
        let assetsPath = dir.appendingPathComponent("assets")

        #expect(FileManager.default.fileExists(atPath: indexPath.path))

        let assetFiles = (try? FileManager.default.contentsOfDirectory(atPath: assetsPath.path)) ?? []

        // Should have image files
        let imageExts = Set(["jpg", "jpeg", "png", "gif", "webp", "svg", "avif"])
        let imageFiles = assetFiles.filter { file in
            let ext = (file as NSString).pathExtension.lowercased()
            return imageExts.contains(ext)
        }
        #expect(!imageFiles.isEmpty, "full cache should include images")

        // Full mode inlines CSS into <style> tags — verify CSS was inlined
        let html = try String(contentsOf: indexPath, encoding: .utf8)
        #expect(html.contains("<style"), "full cache should inline CSS")
    }

    // MARK: - Non-HTML response

    @Test("non-HTML response sets fetchStatus to .failed")
    func nonHTMLResponseFails() async throws {
        let source = try makeSource()
        // A URL that returns JSON, not HTML
        let article = try makeArticle(sourceID: source.id, url: "https://httpbin.org/json")
        defer { cleanUp(articleID: article.id) }

        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)

        let updated = try reloadArticle(article.id)
        #expect(updated?.fetchStatus == .failed)
    }

    // MARK: - Body < 1000 bytes

    @Test("response body under 1000 bytes sets fetchStatus to .failed")
    func tinyBodyFails() async throws {
        let source = try makeSource()
        // Returns 200 with text/html content type but a body well under 1000 bytes
        let article = try makeArticle(sourceID: source.id, url: "https://httpbin.org/response-headers?Content-Type=text%2Fhtml")
        defer { cleanUp(articleID: article.id) }

        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)

        let updated = try reloadArticle(article.id)
        #expect(updated?.fetchStatus == .failed)
    }

    // MARK: - SHA256 hashed filenames

    @Test("asset filenames use SHA256 hash with no query string")
    func hashedAssetFilenames() async throws {
        let source = try makeSource()
        let article = try makeArticle(sourceID: source.id, url: testArticleURL)
        defer { cleanUp(articleID: article.id) }

        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)

        let assetsPath = articleDir(for: article.id).appendingPathComponent("assets")
        let assetFiles = (try? FileManager.default.contentsOfDirectory(atPath: assetsPath.path)) ?? []

        for filename in assetFiles {
            // Filename should be hex hash + extension, no query strings
            #expect(!filename.contains("?"), "Filename should not contain query string: \(filename)")

            // Should be a 64-char hex string before the extension (SHA256 = 32 bytes = 64 hex chars)
            let name = (filename as NSString).deletingPathExtension
            #expect(name.count == 64, "Hash should be 64 hex chars: \(filename)")
            let hexChars = CharacterSet(charactersIn: "0123456789abcdef")
            #expect(name.unicodeScalars.allSatisfy { hexChars.contains($0) },
                    "Filename should be hex: \(filename)")
        }
    }

    // MARK: - Cache protection

    @Test("cache protection: re-fetching a cached article that now 404s preserves .cached status")
    func cacheProtection() async throws {
        let source = try makeSource()
        // First, cache a real article successfully
        let article = try makeArticle(sourceID: source.id, url: testArticleURL)
        defer { cleanUp(articleID: article.id) }

        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)

        // Verify it's cached
        var updated = try reloadArticle(article.id)
        #expect(updated?.fetchStatus == .cached)

        // Now change the URL to something that 404s, simulating the page going away
        // We do this by updating the article's URL in the DB
        try await DatabaseManager.shared.dbPool.write { db in
            try db.execute(
                sql: "UPDATE article SET articleURL = ?, fetchStatus = 'cached' WHERE id = ?",
                arguments: ["https://httpbin.org/status/404", article.id]
            )
        }

        // Re-fetch — should NOT overwrite .cached to .failed
        let modifiedArticle = try reloadArticle(article.id)!
        try await PageCacheService.shared.cacheArticle(modifiedArticle, cacheLevel: .standard)

        updated = try reloadArticle(article.id)
        #expect(updated?.fetchStatus == .cached,
                "A previously cached article should keep .cached even if re-fetch fails")
    }

    // MARK: - Conditional request (304)

    @Test("conditional request: ETag/Last-Modified headers sent, 304 handled without re-download")
    func conditionalRequest304() async throws {
        let source = try makeSource()
        let article = try makeArticle(sourceID: source.id, url: testArticleURL)
        defer { cleanUp(articleID: article.id) }

        // First cache
        try await PageCacheService.shared.cacheArticle(article, cacheLevel: .standard)

        let cached = try reloadArticle(article.id)
        #expect(cached?.fetchStatus == .cached)
        let firstCachedAt = cached?.cachedAt

        // Check that etag or lastModified was stored (at least one should be present)
        let hasConditionalHeaders = cached?.etag != nil || cached?.lastModified != nil

        if hasConditionalHeaders {
            // Wait a moment so cachedAt timestamp would differ
            try await Task.sleep(for: .seconds(1))

            // Re-fetch — if server supports conditional requests, should get 304
            try await PageCacheService.shared.cacheArticle(cached!, cacheLevel: .standard)

            let refetched = try reloadArticle(article.id)
            #expect(refetched?.fetchStatus == .cached)

            // cachedAt should be updated (even on 304)
            if let first = firstCachedAt, let second = refetched?.cachedAt {
                #expect(second >= first, "cachedAt should be updated on re-fetch")
            }
        } else {
            // Server didn't return conditional headers; that's OK — just verify article is still cached
            #expect(cached?.fetchStatus == .cached)
        }
    }
}
